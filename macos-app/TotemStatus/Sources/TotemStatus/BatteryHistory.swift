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
        if let last = samples.last(where: { $0.side == side }),
           now.timeIntervalSince(last.date) < Self.minInterval,
           last.level == level, last.external == external, abs(last.mv - mv) < 20 {
            return
        }
        samples.append(BatterySample(date: now, side: side, mv: mv, level: level, external: external))
        samples.removeAll { now.timeIntervalSince($0.date) > Self.keep }
        save()
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
