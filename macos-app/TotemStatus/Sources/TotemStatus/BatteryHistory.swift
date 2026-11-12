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
        if !external { learnChargeRate(side: side, level: level, now: now) }
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

    /// On a cable the reading is the charger's voltage, so the level is estimated instead:
    /// the last reading on battery plus the time on the cable times the charge rate.
    /// nil when the half isn't on a cable or there is no reading on battery to start from.
    func chargeEstimate(for side: Side, now: Date = Date()) -> Int? {
        let all = samples.filter { $0.side == side }
        guard let session = chargeSession(in: all, endingAt: all.count), all.last?.external == true else {
            return nil
        }
        let minutes = now.timeIntervalSince(session.start) / 60
        return min(99, session.base + Int(minutes * chargeRate(for: side)))
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

    /// Percent per minute. Starts from a typical value (50 mA into a ~110 mAh cell) and is
    /// corrected after each charge from what the half reads once it is back on battery.
    func chargeRate(for side: Side) -> Double {
        let stored = UserDefaults.standard.double(forKey: Self.rateKey(side))
        return stored > 0 ? stored : Self.defaultChargeRate
    }

    static let defaultChargeRate = 0.7
    private static func rateKey(_ side: Side) -> String { "chargeRate.\(side.rawValue)" }
    private var learnedSessions: [Side: Date] = [:]

    private struct ChargeSession {
        let base: Int
        let start: Date
        let end: Date
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
        return ChargeSession(base: all[b].level, start: all[first].date, end: all[end - 1].date)
    }

    /// Called with a reading on battery: once the cell has rested after a charge, compare
    /// what it gained with the time on the cable and adjust the rate.
    private func learnChargeRate(side: Side, level: Int, now: Date) {
        let all = samples.filter { $0.side == side }
        guard let lastExternal = all.lastIndex(where: { $0.external }),
              let session = chargeSession(in: all, endingAt: lastExternal + 1),
              learnedSessions[side] != session.start else { return }
        let rested = now.timeIntervalSince(session.end)
        guard rested >= 60 else { return }
        learnedSessions[side] = session.start
        let minutes = session.end.timeIntervalSince(session.start) / 60
        guard rested < 15 * 60, minutes >= 5 else { return }
        let measured = Double(max(0, level - session.base)) / minutes
        let rate = min(3, max(0.05, (chargeRate(for: side) + measured) / 2))
        UserDefaults.standard.set(rate, forKey: Self.rateKey(side))
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

/// "~9 dni", "~1 dzień", "~14 h", "<1 h".
func formatRemaining(_ t: TimeInterval) -> String {
    let hours = t / 3600
    if hours < 1 { return "<1 h" }
    if hours < 48 { return "~\(Int(hours.rounded())) h" }
    let days = Int((hours / 24).rounded())
    return days == 1 ? "~1 dzień" : "~\(days) dni"
}
