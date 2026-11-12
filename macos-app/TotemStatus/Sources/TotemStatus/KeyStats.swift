import Foundation

/// Press count per key position, summed across dongle reboots and kept on disk.
/// The dongle reports cumulative counts since its boot plus a random boot id, so
/// the app adds only what changed since the last fetch.
@MainActor
final class KeyStats: ObservableObject {
    private struct Stored: Codable {
        var counts: [Int]
        var since: Date
        var bootId: UInt32
        var lastSeen: [UInt32]
    }

    @Published private(set) var counts: [Int] = []
    @Published private(set) var since = Date()

    private var bootId: UInt32 = 0
    private var lastSeen: [UInt32] = []
    private let url = AppSupport.directory.appendingPathComponent("key-stats.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            counts = s.counts
            since = s.since
            bootId = s.bootId
            lastSeen = s.lastSeen
        }
    }

    var total: Int { counts.reduce(0, +) }
    var max: Int { counts.max() ?? 0 }

    func count(at position: Int) -> Int { position < counts.count ? counts[position] : 0 }

    /// Applies one complete set of dongle counters.
    func apply(bootId newBoot: UInt32, current: [UInt32]) {
        let sameBoot = newBoot == bootId && lastSeen.count == current.count
        if counts.count < current.count {
            counts += Array(repeating: 0, count: current.count - counts.count)
        }
        for (i, c) in current.enumerated() {
            let base = sameBoot ? lastSeen[i] : 0
            let delta = c >= base ? Int(c - base) : Int(c)
            if delta > 0 { counts[i] += delta }
        }
        bootId = newBoot
        lastSeen = current
        save()
    }

    func reset() {
        counts = Array(repeating: 0, count: counts.count)
        since = Date()
        save()
    }

#if DEBUG
    /// In memory only: the preview never writes the real stats file.
    func setPreview(_ counts: [Int], since: Date) {
        self.counts = counts
        self.since = since
    }
#endif

    private func save() {
        let s = Stored(counts: counts, since: since, bootId: bootId, lastSeen: lastSeen)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
