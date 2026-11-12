import Foundation
import UserNotifications

/// Low battery and "half went dark" notifications.
@MainActor
final class Notifier {
    static let lowLevel = 15
    /// Re-arm the low battery warning once the half is charged past this.
    static let rearmLevel = 25
    /// A half that disconnects at or below this is most likely flat, not switched off.
    static let flatLevel = 20

    private struct SideState {
        var lowWarned = false
        var connected = false
        var lastLevel: Int?
    }

    private var state: [Side: SideState] = [:]
    /// UNUserNotificationCenter crashes outside an .app bundle (`swift run`).
    private let available = Bundle.main.bundleIdentifier != nil

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Call on every report while the dongle is connected.
    func update(side: Side, connected: Bool, level: Int?, external: Bool, enabled: Bool) {
        var s = state[side] ?? SideState()
        defer { state[side] = s }

        if s.connected && !connected {
            if enabled, let last = s.lastLevel, last <= Self.flatLevel {
                post(id: "disconnected-\(side.rawValue)",
                     title: "\(side.name) połówka rozłączona",
                     body: "Ostatnio miała \(last)% baterii, więc pewnie się rozładowała. Podłącz ją do ładowania.")
            }
        }
        s.connected = connected
        guard connected, let level else { return }
        s.lastLevel = level

        if external || level >= Self.rearmLevel {
            s.lowWarned = false
        } else if level <= Self.lowLevel && !s.lowWarned {
            s.lowWarned = true
            if enabled {
                post(id: "low-\(side.rawValue)",
                     title: "\(side.name) połówka: \(level)% baterii",
                     body: "Niedługo się rozładuje. Podłącz ją do ładowania (wyłącznik w pozycji ON).")
            }
        }
    }

    /// Dongle unplugged: forget connection states so replugging doesn't look like a disconnect.
    func reset() {
        for side in Side.allCases {
            state[side]?.connected = false
        }
    }

    private func post(id: String, title: String, body: String) {
        guard available else {
            NSLog("TotemStatus notification: \(title) – \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
