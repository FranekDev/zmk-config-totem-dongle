import Foundation
import IOKit.hid
import ServiceManagement
import SwiftUI

/// Protocol shared with modules/totem_status/src/totem_status.c
enum TotemProtocol {
    static let magic: UInt8 = 0xA7
    static let cmdGetState: UInt8 = 0x01
    static let cmdSetOS: UInt8 = 0x02
    static let cmdToggleOS: UInt8 = 0x03
    static let reportState: UInt8 = 0x81
    static let headerLength = 10
}

/// Layer names from config/totem.keymap (index = layer number).
let layerNames = ["BASE", "WIN", "NAV", "SYM", "ADJ", "ARR", "WIN_SYM", "WIN_ADJ"]

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var isWindows = false
    @Published private(set) var highestLayer = 0
    @Published private(set) var batteries: [Int] = []
    @Published private(set) var lastUpdate: Date?
    /// Per peripheral slot: true while the battery level is rising (= charging).
    @Published private(set) var charging: [Bool] = []

    /// Peripheral slot order on the dongle depends on pairing order, so let the user swap them.
    @AppStorage("swapHalves") var swapHalves = false {
        willSet { objectWillChange.send() }
    }

    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let hid = KeyboardHID()
    /// The device that answered with our magic byte (other raw-HID keyboards may match too).
    private var keyboard: IOHIDDevice?
    private var pollTimer: Timer?
    private var chargeTrackers: [Int: ChargeTracker] = [:]

    init() {
        hid.onDeviceAdded = { [weak self] device in
            MainActor.assumeIsolated {
                // Give the device a moment after enumeration, then ask for state.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.hid.send([TotemProtocol.magic, TotemProtocol.cmdGetState], to: device)
                }
            }
        }
        hid.onDeviceRemoved = { [weak self] device in
            MainActor.assumeIsolated {
                guard let self, device == self.keyboard else { return }
                self.keyboard = nil
                self.connected = false
                self.batteries = []
                self.charging = []
                self.chargeTrackers = [:]
            }
        }
        hid.onReport = { [weak self] device, bytes in
            MainActor.assumeIsolated { self?.handle(bytes, from: device) }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.updateCharging()
            }
        }
    }

    // MARK: - Derived values

    var leftBattery: Int? { battery(at: swapHalves ? 1 : 0) }
    var rightBattery: Int? { battery(at: swapHalves ? 0 : 1) }

    var lowestBattery: Int? {
        [leftBattery, rightBattery].compactMap { $0 }.filter { $0 > 0 }.min()
    }

    var activeLayerName: String {
        highestLayer < layerNames.count ? layerNames[highestLayer] : "Layer \(highestLayer)"
    }

    var leftCharging: Bool { isCharging(at: swapHalves ? 1 : 0) }
    var rightCharging: Bool { isCharging(at: swapHalves ? 0 : 1) }

    private func battery(at slot: Int) -> Int? {
        slot < batteries.count ? batteries[slot] : nil
    }

    private func isCharging(at slot: Int) -> Bool {
        slot < charging.count ? charging[slot] : false
    }

    // MARK: - Commands

    func refresh() {
        for device in hid.devices {
            hid.send([TotemProtocol.magic, TotemProtocol.cmdGetState], to: device)
        }
    }

    func setWindows(_ windows: Bool) {
        guard let keyboard else { return }
        hid.send([TotemProtocol.magic, TotemProtocol.cmdSetOS, windows ? 1 : 0], to: keyboard)
    }

    func toggleOS() {
        guard let keyboard else { return }
        hid.send([TotemProtocol.magic, TotemProtocol.cmdToggleOS], to: keyboard)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("TotemStatus: launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Reports

    private func handle(_ r: [UInt8], from device: IOHIDDevice) {
        guard r.count >= TotemProtocol.headerLength,
              r[0] == TotemProtocol.magic,
              r[1] == TotemProtocol.reportState else { return }

        keyboard = device
        connected = true
        isWindows = r[3] != 0
        highestLayer = Int(r[4])
        let count = Int(r[9])
        let end = min(TotemProtocol.headerLength + count, r.count)
        batteries = r[TotemProtocol.headerLength..<end].map { Int($0) }
        lastUpdate = Date()
        for (slot, level) in batteries.enumerated() {
            chargeTrackers[slot, default: ChargeTracker()].record(level)
        }
        updateCharging()
    }

    private func updateCharging() {
        let now = Date()
        let value = batteries.indices.map { chargeTrackers[$0]?.isCharging(now: now) ?? false }
        if value != charging { charging = value }
    }
}

/// ZMK only forwards the battery percentage of the halves, not the charger status,
/// so charging is inferred from the level trend: it counts as charging once the level
/// has risen by a few points and stops when it drops or stops rising for a while.
struct ChargeTracker {
    static let minRise = 3
    static let staleAfter: TimeInterval = 20 * 60

    private var previous: Int?
    private var low: Int?
    private var lastRise: Date?

    mutating func record(_ level: Int, now: Date = Date()) {
        guard level > 0 else {  // 0 = half disconnected
            self = ChargeTracker()
            return
        }
        defer { previous = level }
        guard let prev = previous else {
            low = level
            return
        }
        if level > prev {
            lastRise = now
        } else if level < prev - 1 {
            // Clear drop (small wobble of 1 is voltage noise): discharging again.
            lastRise = nil
            low = level
        }
        low = min(low ?? level, level)
    }

    func isCharging(now: Date = Date()) -> Bool {
        guard let lastRise, let low, let previous else { return false }
        return previous - low >= Self.minRise && now.timeIntervalSince(lastRise) < Self.staleAfter
    }
}
