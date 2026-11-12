import Foundation

enum Side: String, Codable, CaseIterable {
    case left, right

    var name: String { self == .left ? "Lewa" : "Prawa" }
}

struct BatterySample: Codable {
    let date: Date
    let side: Side
    /// 0 = unknown (half without the voltage service).
    let mv: Int
    let level: Int
    /// On USB or visibly charging: the reading is the charger's, not the cell's.
    let external: Bool
}

/// Battery readings of both halves over time, kept on disk for the chart and the runtime estimate.
@MainActor
final class BatteryHistory: ObservableObject {
    static let keep: TimeInterval = 30 * 24 * 3600
    /// One sample per this interval unless something changes.
    static let minInterval: TimeInterval = 10 * 60

    @Published private(set) var samples: [BatterySample] = []

    private let url: URL

    init(filename: String = "battery-history.json") {
        url = AppSupport.directory.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([BatterySample].self, from: data) {
            samples = decoded
        }
    }

    func record(side: Side, mv: Int, level: Int, external: Bool, now: Date = Date()) {
        if !external { learnFromCharge(side: side, mv: mv, level: level, now: now) }
        if let last = samples.last(where: { $0.side == side }),
           now.timeIntervalSince(last.date) < Self.minInterval,
           last.level == level, last.external == external, abs(last.mv - mv) < 20 {
            return
        }
        samples.append(BatterySample(date: now, side: side, mv: mv, level: level, external: external))
        samples.removeAll { now.timeIntervalSince($0.date) > Self.keep }
        save()
    }

    // MARK: - Level while charging

    /// On a cable the reading is the cell's voltage plus what the charge current adds, so
    /// the level is estimated instead: from that voltage less the charger's part where the
    /// half reports voltages (this follows the charge as it really goes, whatever the port
    /// gives), else from the time on the cable times the learned charge rate.
    /// nil when the half isn't on a cable or there is no reading on battery to start from.
    func chargeEstimate(for side: Side, now: Date = Date()) -> Int? {
        let all = samples.filter { $0.side == side }
        guard let session = chargeSession(in: all, endingAt: all.count), all.last?.external == true else {
            return nil
        }
        return min(99, Int(chargeLevel(session, side: side, now: now)))
    }

    /// Time until the charger is done, nil when the half isn't on a cable or there is no
    /// reading on battery to start from. From the estimated level and the rate of this
    /// charge up to where the charger starts holding its top voltage, plus the tail from
    /// there, whose length is learned from charges that ran to the end.
    func timeToFull(for side: Side, now: Date = Date()) -> TimeInterval? {
        let all = samples.filter { $0.side == side }
        guard let session = chargeSession(in: all, endingAt: all.count), all.last?.external == true else {
            return nil
        }
        let tail = tailMinutes(for: side)
        if let start = constantVoltageStart(session) {
            return max(0, tail - now.timeIntervalSince(start) / 60) * 60
        }
        let level = chargeLevel(session, side: side, now: now)
        let top = tailLevel(session, side: side)
        if level < top { return ((top - level) / sessionRate(session, side: side) + tail) * 60 }
        return tail * max(0, 99 - level) / (99 - top) * 60
    }

    /// The level at which the charger starts holding its top voltage.
    private func tailLevel(_ session: ChargeSession, side: Side) -> Double {
        guard session.baseMv > 0 else { return Self.taperStart }
        let level = Self.lipoLevel(mv: Double(Self.constantVoltage) - chargeOffset(session, side: side))
        return min(95, max(60, level))
    }

    /// How long the charger holds its top voltage until it is done (minutes).
    func tailMinutes(for side: Side) -> Double { stored(Self.tailKey(side), default: 60) }

    /// Since when the charger has been holding its top voltage, nil before that.
    private func constantVoltageStart(_ session: ChargeSession) -> Date? {
        // The first reading comes a moment after the cable goes in and can be a stale one.
        let readings = Array(session.onCable.dropFirst())
        let recent = readings.suffix(3).map(\.mv).sorted()
        guard !recent.isEmpty, recent[recent.count / 2] >= Self.constantVoltage else { return nil }
        var first = readings.count - 1
        while first > 0, readings[first - 1].mv >= Self.constantVoltage { first -= 1 }
        return readings[first].date
    }

    /// Called while the charger reports it is done: a charge that ran through the tail
    /// shows how long the tail takes on this half.
    func chargerDone(side: Side, now: Date = Date()) {
        let all = samples.filter { $0.side == side }
        guard all.last?.external == true, let session = chargeSession(in: all, endingAt: all.count),
              learnedTails[side] != session.start, let start = constantVoltageStart(session) else { return }
        learnedTails[side] = session.start
        let minutes = now.timeIntervalSince(start) / 60
        // Shorter is a charger that gave up, longer a cable left in after the charge.
        guard (10...180).contains(minutes) else { return }
        UserDefaults.standard.set((tailMinutes(for: side) + minutes) / 2, forKey: Self.tailKey(side))
    }

    private func chargeLevel(_ session: ChargeSession, side: Side, now: Date) -> Double {
        let minutes = now.timeIntervalSince(session.start) / 60
        return voltageLevel(session, side: side, now: now)
            ?? Self.projectedLevel(base: Double(session.base), minutes: minutes,
                                   rate: sessionRate(session, side: side))
    }

    /// The charge rate of this charge: the learned one, scaled by how the voltage jump at
    /// plug-in (which grows with the charge current) compares to the usual jump, so a port
    /// that gives more or less current is accounted for from the start.
    private func sessionRate(_ session: ChargeSession, side: Side) -> Double {
        let rate = chargeRate(for: side)
        let usual = UserDefaults.standard.double(forKey: Self.stepKey(side))
        guard let step = session.step, usual > 0 else { return rate }
        return rate * min(2, max(0.5, step / usual))
    }

    /// The level from the voltage on the cable, nil without voltages.
    private func voltageLevel(_ session: ChargeSession, side: Side, now: Date) -> Double? {
        guard session.baseMv > 0, session.onCable.allSatisfy({ $0.mv > 0 }) else { return nil }
        let base = Double(session.base)
        let offset = chargeOffset(session, side: side)
        // The first reading comes a moment after the cable goes in and can be a stale one.
        let readings = Array(session.onCable.dropFirst())
        var level = base
        if let start = constantVoltageStart(session) {
            // The voltage says nothing more: the rest goes by time, fast at first and
            // slowing as the current tapers off.
            let top = tailLevel(session, side: side)
            let left = 1 - min(1, now.timeIntervalSince(start) / 60 / tailMinutes(for: side))
            level = max(base, top) + (99 - max(base, top)) * (1 - left * left)
        } else if !readings.isEmpty {
            let recent = readings.suffix(3).map(\.mv).sorted()
            level = Self.lipoLevel(mv: Double(recent[recent.count / 2]) - offset)
        }
        // A cell doesn't lose charge on a cable, nor gain it faster than the charger can give.
        let minutes = now.timeIntervalSince(session.start) / 60
        return min(max(level, base), base + 2 + minutes * 2 * Self.fastestChargeRate)
    }

    /// What the charge current adds to the cell's voltage (mV). Measured for this charge as
    /// the jump when the cable went in, so it follows the current this port gives, times
    /// how much it grows over a charge on this half (learned when the cable comes out).
    private func chargeOffset(_ session: ChargeSession, side: Side) -> Double {
        if let step = session.step { return step * stored(Self.gainKey(side), default: 1) }
        return stored(Self.offsetKey(side), default: 110)
    }

    private func stored(_ key: String, default value: Double) -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : value
    }

    /// Reading on the cable from which the charger holds a constant voltage.
    static let constantVoltage = 4130

    /// Resting voltage -> level, the curve the halves use (battery_lipo.c).
    static func lipoLevel(mv: Double) -> Double {
        let curve: [(mv: Double, pct: Double)] = [
            (4200, 100), (4150, 95), (4110, 90), (4080, 85), (4020, 80), (3980, 75), (3950, 70),
            (3910, 65), (3870, 60), (3850, 55), (3840, 50), (3820, 45), (3800, 40), (3790, 35),
            (3770, 30), (3750, 25), (3730, 20), (3710, 15), (3690, 10), (3610, 5), (3300, 0),
        ]
        if mv >= curve[0].mv { return 100 }
        for i in 1..<curve.count where mv >= curve[i].mv {
            let hi = curve[i - 1], lo = curve[i]
            return lo.pct + (mv - lo.mv) * (hi.pct - lo.pct) / (hi.mv - lo.mv)
        }
        return 0
    }

    /// Above this level the charger switches to constant voltage and the current tapers off.
    static let taperStart = 80.0

    /// Level after `minutes` on the cable: linear at `rate` %/min up to taperStart, then an
    /// exponential approach to 100 (the rate shrinks with what is left to fill).
    static func projectedLevel(base: Double, minutes: Double, rate: Double) -> Double {
        let span = 100 - taperStart
        var from = base, t = minutes
        if from < taperStart {
            let linear = (taperStart - from) / rate
            if t <= linear { return from + rate * t }
            from = taperStart
            t -= linear
        }
        return 100 - (100 - from) * exp(-rate * t / span)
    }

    /// The rate under which projectedLevel gives `level`, by bisection (it grows with the rate).
    static func rateFor(base: Double, minutes: Double, level: Double) -> Double {
        var lo = 0.05, hi = 3.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if projectedLevel(base: base, minutes: minutes, rate: mid) < level { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// The level on battery right before the current charge, nil when not on a cable.
    func chargeBase(for side: Side) -> Int? {
        let all = samples.filter { $0.side == side }
        guard all.last?.external == true else { return nil }
        return chargeSession(in: all, endingAt: all.count)?.base
    }

    /// When the current charge began, nil when not on a cable.
    func chargeStart(for side: Side) -> Date? {
        let all = samples.filter { $0.side == side }
        guard all.last?.external == true else { return nil }
        return chargeSession(in: all, endingAt: all.count)?.start
    }

    /// Percent per minute below taperStart. Starts from what the halves measured (~0.45 %/min,
    /// less than 50 mA into ~110 mAh would suggest) and is corrected after each charge from
    /// what the half reads once it is back on battery.
    func chargeRate(for side: Side) -> Double {
        let stored = UserDefaults.standard.double(forKey: Self.rateKey(side))
        return stored > 0 ? stored : Self.defaultChargeRate
    }

    static let defaultChargeRate = 0.45
    /// Fastest plausible charge, for telling a real charge from a charger that gave up.
    static let fastestChargeRate = 0.7
    private static func rateKey(_ side: Side) -> String { "chargeRate.\(side.rawValue)" }
    private static func tailKey(_ side: Side) -> String { "chargeTail.\(side.rawValue)" }
    private var learnedTails: [Side: Date] = [:]
    private static func stepKey(_ side: Side) -> String { "chargeStep.\(side.rawValue)" }
    private static func gainKey(_ side: Side) -> String { "chargeGain.\(side.rawValue)" }
    private static func offsetKey(_ side: Side) -> String { "chargeOffset.\(side.rawValue)" }
    private var learnedSessions: [Side: Date] = [:]

    private struct ChargeSession {
        let base: Int
        /// Voltage on battery before the cable went in, 0 = unknown.
        let baseMv: Int
        let start: Date
        let end: Date
        let onCable: ArraySlice<BatterySample>

        /// The jump in voltage when the cable went in (mV), nil when unknown or implausible
        /// (a stale reading, a charger that can't charge the cell).
        var step: Double? {
            guard baseMv > 0, let first = onCable.first, first.mv > 0 else { return nil }
            let step = Double(first.mv - baseMv)
            return (40...200).contains(step) ? step : nil
        }
    }

    /// The run of on-cable samples right before index `end`, with the level on battery before it.
    private func chargeSession(in all: [BatterySample], endingAt end: Int) -> ChargeSession? {
        var first = end
        while first > 0, all[first - 1].external { first -= 1 }
        guard first < end else { return nil }
        // The level on battery before the cable went in. A reading taken a moment before the
        // cable was noticed may already be the charger's: skip those.
        var b = first - 1
        while b >= 0, all[b].external || all[first].date.timeIntervalSince(all[b].date) < 3 { b -= 1 }
        guard b >= 0 else { return nil }
        return ChargeSession(base: all[b].level, baseMv: all[b].mv, start: all[first].date,
                             end: all[end - 1].date, onCable: all[first..<end])
    }

    /// Called with a reading on battery: the first one after a charge (even a brief unplug,
    /// which reads the cell itself) shows what the cell gained on the cable and how far the
    /// voltage on the cable was above the cell's, so the estimate is corrected towards it.
    private func learnFromCharge(side: Side, mv: Int, level: Int, now: Date) {
        let all = samples.filter { $0.side == side }
        guard let lastExternal = all.lastIndex(where: { $0.external }),
              let session = chargeSession(in: all, endingAt: lastExternal + 1),
              learnedSessions[side] != session.start else { return }
        // A reading a moment after the cable is out may still be the charger's.
        guard now.timeIntervalSince(session.end) >= 3 else { return }
        learnedSessions[side] = session.start
        let minutes = session.end.timeIntervalSince(session.start) / 60
        learnChargeOffset(session, side: side, mv: mv, minutes: minutes, now: now)
        // Too short to tell from 1 % steps, or long since unplugged, or no gain (the charger
        // gave up), or close to full where the level says little about the rate.
        guard now.timeIntervalSince(session.end) < 30 * 60, minutes >= 5,
              level > session.base, level < 97 else { return }
        let measured = Self.rateFor(base: Double(session.base), minutes: minutes, level: Double(level))
        let weight = min(0.8, minutes / 90)
        let rate = min(3, max(0.05, chargeRate(for: side) * (1 - weight) + measured * weight))
        UserDefaults.standard.set(rate, forKey: Self.rateKey(side))
        // The voltage jump the learned rate goes with, see sessionRate.
        if let step = session.step {
            let usual = stored(Self.stepKey(side), default: step)
            UserDefaults.standard.set(usual * (1 - weight) + step * weight, forKey: Self.stepKey(side))
        }
    }

    /// What the charge current added to the voltage by the end of the charge, and how that
    /// compares to the jump at its start.
    private func learnChargeOffset(_ session: ChargeSession, side: Side, mv: Int, minutes: Double, now: Date) {
        let recent = session.onCable.dropFirst().suffix(3).map(\.mv).sorted()
        // Needs a settled charge below the charger's top voltage and a prompt reading after it.
        guard mv > 0, minutes >= 10, now.timeIntervalSince(session.end) < 5 * 60, !recent.isEmpty,
              recent[0] > 0, recent[recent.count - 1] < Self.constantVoltage else { return }
        let offset = Double(recent[recent.count / 2] - mv)
        guard (40...250).contains(offset) else { return }
        let defaults = UserDefaults.standard
        defaults.set((stored(Self.offsetKey(side), default: offset) + offset) / 2, forKey: Self.offsetKey(side))
        if let step = session.step {
            let gain = min(1.6, max(0.7, offset / step))
            defaults.set((stored(Self.gainKey(side), default: gain) + gain) / 2, forKey: Self.gainKey(side))
        }
    }

    func samples(for side: Side, since: Date) -> [BatterySample] {
        samples.filter { $0.side == side && $0.date >= since }
    }

    /// Time left on battery, from the slope of the current discharge (level over time).
    /// nil while on USB, right after a charge, or when there isn't enough data yet.
    func estimatedRemaining(for side: Side, now: Date = Date()) -> TimeInterval? {
        let all = samples.filter { $0.side == side }
        guard let latest = all.last, !latest.external,
              now.timeIntervalSince(latest.date) < 2 * 3600 else { return nil }

        // Walk back over the current discharge: stop at USB/charging or a clear rise
        // (a charge the half didn't flag, e.g. older firmware).
        var run: [BatterySample] = []
        for s in all.reversed() {
            if s.external { break }
            if let newer = run.last, s.level + 2 < newer.level { break }
            if now.timeIntervalSince(s.date) > 7 * 24 * 3600 { break }
            run.append(s)
        }
        run.reverse()
        guard let first = run.first, latest.date.timeIntervalSince(first.date) >= 3 * 3600,
              first.level - latest.level >= 2 else { return nil }

        // Least squares fit of level (%) against time (hours).
        let xs = run.map { $0.date.timeIntervalSince(first.date) / 3600 }
        let ys = run.map { Double($0.level) }
        let n = Double(run.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
        }
        guard sxx > 0 else { return nil }
        let perHour = sxy / sxx
        guard perHour < 0 else { return nil }
        return Double(latest.level) / -perHour * 3600
    }

#if DEBUG
    /// In memory only: the preview never writes the real history file.
    func setPreview(_ samples: [BatterySample]) { self.samples = samples }
#endif

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum AppSupport {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TotemStatus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// "~2 h 10 min", "~45 min", "<5 min": time until charged, to 5 minutes.
func formatToFull(_ t: TimeInterval) -> String {
    let minutes = Int((t / 300).rounded()) * 5
    if minutes < 5 { return "<5 min" }
    if minutes < 60 { return "~\(minutes) min" }
    return minutes % 60 == 0 ? "~\(minutes / 60) h" : "~\(minutes / 60) h \(minutes % 60) min"
}

/// "~9 dni", "~1 dzień", "~14 h", "<1 h".
func formatRemaining(_ t: TimeInterval) -> String {
    let hours = t / 3600
    if hours < 1 { return "<1 h" }
    if hours < 48 { return "~\(Int(hours.rounded())) h" }
    let days = Int((hours / 24).rounded())
    return days == 1 ? "~1 dzień" : "~\(days) dni"
}
