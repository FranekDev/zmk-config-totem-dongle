import AppKit
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
    static let cmdGetKeyStats: UInt8 = 0x04
    static let reportState: UInt8 = 0x81
    static let reportKeyStats: UInt8 = 0x82
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
    /// Per peripheral slot: whether the half is connected to the dongle.
    @Published private(set) var halvesConnected: [Bool] = []
    /// Per peripheral slot: battery voltage in millivolts, 0 = unknown (protocol v4).
    @Published private(set) var voltages: [Int] = []
    /// Per peripheral slot: half runs on USB power (protocol v5). Its battery reading is then
    /// the charger's voltage rather than the cell's, so the % is only approximate.
    @Published private(set) var usbPowered: [Bool] = []
    /// Per peripheral slot: the charger is charging the cell; nil when the half doesn't
    /// report it (protocol v7). On USB and not charging means the cell is full.
    @Published private(set) var chargerActive: [Bool?] = []
    /// Per peripheral slot: RSSI of the half's link in dBm, 0 = unknown (protocol v6).
    @Published private(set) var rssi: [Int] = []
    @Published private(set) var lastUpdate: Date?
    /// Per peripheral slot: true while the battery level is rising (= charging).
    @Published private(set) var charging: [Bool] = []

    /// Peripheral slot of the left half. Slot order on the dongle follows pairing order, so
    /// the dongle learns it from the first key press on a half (protocol v3). The last known
    /// value is remembered for when the dongle restarts and doesn't know it yet.
    @Published private(set) var leftSlot: Int = KeyboardModel.storedLeftSlot
    private static let leftSlotKey = "leftSlot"
    private static var storedLeftSlot: Int {
        let d = UserDefaults.standard
        if d.object(forKey: leftSlotKey) != nil { return d.integer(forKey: leftSlotKey) }
        return d.bool(forKey: "swapHalves") ? 1 : 0  // value of the old manual setting
    }

    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Switch the keyboard to macOS mode when the dongle connects or the Mac wakes up.
    @Published var autoMacMode = UserDefaults.standard.object(forKey: "autoMacMode") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoMacMode, forKey: "autoMacMode")
            if autoMacMode, isWindows { setWindows(false) }
        }
    }
    @Published var showLayerInMenuBar = UserDefaults.standard.object(forKey: "showLayerInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLayerInMenuBar, forKey: "showLayerInMenuBar") }
    }
    @Published var notificationsEnabled = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notifications")
            if notificationsEnabled { notifier.requestAuthorization() }
        }
    }

    let history = BatteryHistory()
    let keyStats = KeyStats()
    private let notifier = Notifier()
    /// Set by a wake from sleep: the next state report applies the auto macOS mode.
    private var wokeUp = false
    /// Auto macOS mode applies until then: the dongle boots in Windows mode, which may land
    /// a moment after its first report (CONFIG_TOTEM_STATUS_BOOT_WIN).
    private var autoMacUntil = Date.distantPast
    private var wakeObserver: NSObjectProtocol?

    /// Key stats arrive in chunks, one request per chunk.
    private struct StatsFetch {
        var chunk: UInt8 = 0
        var bootId: UInt32 = 0
        var counts: [UInt32] = []
        let started = Date()
    }
    private var statsFetch: StatsFetch?

    private let hid = KeyboardHID()
    /// The device that answered with our magic byte (other raw-HID keyboards may match too).
    private var keyboard: IOHIDDevice?
    private var pollTimer: Timer?
    private var chargeTrackers: [Int: ChargeTracker] = [:]
    /// Start of the charge during which the charger gave up on a half, see reading(for:).
    private var stalledCharges: [Side: Date] = [:]
    /// When each half (re)connected. Its first readings can be off (taken during boot, or
    /// while the cell recovers from the charger), so they stay out of the history and
    /// the notifications for a moment.
    private var connectedSince: [Side: Date] = [:]
    static let settleTime: TimeInterval = 12

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
                self.halvesConnected = []
                self.voltages = []
                self.usbPowered = []
                self.chargerActive = []
                self.rssi = []
                self.statsFetch = nil
                self.notifier.reset()
                self.charging = []
                self.chargeTrackers = [:]
                self.connectedSince = [:]
            }
        }
        hid.onReport = { [weak self] device, bytes in
            MainActor.assumeIsolated { self?.handle(bytes, from: device) }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.updateCharging()
                self?.fetchKeyStats()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wokeUp = true
                self?.refresh()
            }
        }
        if notificationsEnabled { notifier.requestAuthorization() }
    }

    // MARK: - Derived values

    var leftBattery: Int? { battery(at: leftSlot) }
    var rightBattery: Int? { battery(at: 1 - leftSlot) }

    var leftVoltage: Int? { voltage(at: leftSlot) }
    var rightVoltage: Int? { voltage(at: 1 - leftSlot) }

    var leftConnected: Bool { isConnected(at: leftSlot) }
    var rightConnected: Bool { isConnected(at: 1 - leftSlot) }

    var lowestBattery: Int? {
        batteries.indices.filter { isConnected(at: $0) }.map { batteries[$0] }.min()
    }

    var activeLayerName: String {
        highestLayer < layerNames.count ? layerNames[highestLayer] : "Layer \(highestLayer)"
    }

    var leftCharging: Bool { isCharging(at: leftSlot) }
    var rightCharging: Bool { isCharging(at: 1 - leftSlot) }

    var leftOnUSB: Bool { isOnUSB(at: leftSlot) }
    var rightOnUSB: Bool { isOnUSB(at: 1 - leftSlot) }

    /// What to show as the level of a half.
    struct LevelReading {
        let level: Int
        /// Estimated (on a cable), not measured.
        let estimated: Bool
        /// On a cable with the charger done.
        let full: Bool
        /// On a cable, but the charger stopped long before the cell could be full: the
        /// cell takes no charge (bad cell or connection, power switch off).
        var stalled = false
    }

    func reading(for side: Side) -> LevelReading? {
        let slot = slot(for: side)
        guard isConnected(at: slot), let level = battery(at: slot) else { return nil }
        guard isOnUSB(at: slot) || isCharging(at: slot) else {
            return LevelReading(level: level, estimated: false, full: false)
        }
        let active = slot < chargerActive.count ? chargerActive[slot] : nil
        // Charger done: no current flows, so the voltage is the cell's own again. The
        // charger also reads "done" for a moment right after the cable goes in.
        if active == false, let start = history.chargeStart(for: side), Date().timeIntervalSince(start) > 15 {
            // A real charge takes its time: "done" within minutes of an empty cell means the
            // charger gave up, and the high voltage is its own, not the cell's.
            if let base = history.chargeBase(for: side),
               Double(base) + Date().timeIntervalSince(start) / 60 * BatteryHistory.defaultChargeRate < 85 {
                stalledCharges[side] = start
                return LevelReading(level: base, estimated: true, full: false, stalled: true)
            }
            return LevelReading(level: level, estimated: false, full: true)
        }
        // A charger without a cell it can charge keeps starting and giving up: once it gave
        // up, the whole time on this cable counts as not charging.
        if let start = history.chargeStart(for: side), stalledCharges[side] == start,
           let base = history.chargeBase(for: side) {
            return LevelReading(level: base, estimated: true, full: false, stalled: true)
        }
        return LevelReading(level: history.chargeEstimate(for: side) ?? level, estimated: true, full: false)
    }

    var leftRSSI: Int? { signal(at: leftSlot) }
    var rightRSSI: Int? { signal(at: 1 - leftSlot) }

    func slot(for side: Side) -> Int { side == .left ? leftSlot : 1 - leftSlot }

    /// Layer name for the menu bar: nil on the base layers (BASE / WIN).
    var menuBarLayerName: String? {
        guard connected, highestLayer > 1, highestLayer < layerNames.count else { return nil }
        let name = layerNames[highestLayer]
        return name.hasPrefix("WIN_") ? String(name.dropFirst(4)) : name
    }

    private func battery(at slot: Int) -> Int? {
        slot < batteries.count ? batteries[slot] : nil
    }

    private func voltage(at slot: Int) -> Int? {
        slot < voltages.count && voltages[slot] > 0 ? voltages[slot] : nil
    }

    private func isConnected(at slot: Int) -> Bool {
        slot < halvesConnected.count ? halvesConnected[slot] : false
    }

    private func isCharging(at slot: Int) -> Bool {
        slot < charging.count ? charging[slot] : false
    }

    private func isOnUSB(at slot: Int) -> Bool {
        slot < usbPowered.count ? usbPowered[slot] : false
    }

    private func signal(at slot: Int) -> Int? {
        slot < rssi.count && rssi[slot] != 0 ? rssi[slot] : nil
    }

    // MARK: - Commands

    func refresh() {
        for device in hid.devices {
            hid.send([TotemProtocol.magic, TotemProtocol.cmdGetState], to: device)
        }
    }

    /// Asks the dongle for its key press counters (one chunk at a time, see handleKeyStats).
    func fetchKeyStats() {
        guard let keyboard else { return }
        if let f = statsFetch, Date().timeIntervalSince(f.started) < 5 { return }
        statsFetch = StatsFetch()
        hid.send([TotemProtocol.magic, TotemProtocol.cmdGetKeyStats, 0], to: keyboard)
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

#if DEBUG
    private static var previewLocked = false

    func setPreview(connected: Bool, isWindows: Bool, layer: Int, batteries: [Int], charging: [Bool]) {
        Self.previewLocked = true
        self.connected = connected
        self.isWindows = isWindows
        self.highestLayer = layer
        self.batteries = batteries
        self.halvesConnected = batteries.map { $0 > 0 }
        self.charging = charging
    }

    func setPreview(voltages: [Int], usbPowered: [Bool], rssi: [Int]) {
        self.voltages = voltages
        self.usbPowered = usbPowered
        self.rssi = rssi
    }
#endif

    // MARK: - Reports

    private func handle(_ r: [UInt8], from device: IOHIDDevice) {
#if DEBUG
        if Self.previewLocked { return }
#endif
        guard r.count >= TotemProtocol.headerLength, r[0] == TotemProtocol.magic else { return }
        switch r[1] {
        case TotemProtocol.reportState: handleState(r, from: device)
        case TotemProtocol.reportKeyStats: handleKeyStats(r, from: device)
        default: break
        }
    }

    private func handleKeyStats(_ r: [UInt8], from device: IOHIDDevice) {
        guard var f = statsFetch, device == keyboard else { return }
        let bootId = UInt32(r[2]) | UInt32(r[3]) << 8 | UInt32(r[4]) << 16 | UInt32(r[5]) << 24
        let total = Int(r[6]), first = Int(r[7]), count = Int(r[8])
        guard count > 0, first == f.counts.count, 9 + 4 * count <= r.count,
              f.chunk == 0 || bootId == f.bootId else {
            statsFetch = nil  // out of sync (or dongle rebooted mid-fetch): try again next time
            return
        }
        f.bootId = bootId
        for i in 0..<count {
            let o = 9 + 4 * i
            f.counts.append(UInt32(r[o]) | UInt32(r[o + 1]) << 8 | UInt32(r[o + 2]) << 16 | UInt32(r[o + 3]) << 24)
        }
        if f.counts.count >= total {
            keyStats.apply(bootId: bootId, current: f.counts)
            statsFetch = nil
        } else {
            f.chunk += 1
            statsFetch = f
            hid.send([TotemProtocol.magic, TotemProtocol.cmdGetKeyStats, f.chunk], to: device)
        }
    }

    private func handleState(_ r: [UInt8], from device: IOHIDDevice) {
        let firstReport = keyboard == nil
        keyboard = device
        connected = true
        isWindows = r[3] != 0
        highestLayer = Int(r[4])
        let count = Int(r[9])
        let end = min(TotemProtocol.headerLength + count, r.count)
        batteries = r[TotemProtocol.headerLength..<end].map { Int($0) }
        if r[2] >= 2, end < r.count {
            // v2: explicit connection bitmask, so a 0% half is not mistaken for a disconnected one.
            let mask = r[end]
            halvesConnected = batteries.indices.map { mask & (1 << $0) != 0 }
        } else {
            halvesConnected = batteries.map { $0 > 0 }
        }
        if r[2] >= 3, end + 1 < r.count, r[end + 1] < 2, Int(r[end + 1]) != leftSlot {
            leftSlot = Int(r[end + 1])
            UserDefaults.standard.set(leftSlot, forKey: Self.leftSlotKey)
        }
        let voltageOffset = end + 2
        if r[2] >= 4, voltageOffset + 2 * count <= r.count {
            voltages = (0..<count).map {
                Int(r[voltageOffset + 2 * $0]) | Int(r[voltageOffset + 2 * $0 + 1]) << 8
            }
        } else {
            voltages = []
        }
        let usbOffset = voltageOffset + 2 * count
        if r[2] >= 5, usbOffset < r.count {
            let mask = r[usbOffset]
            usbPowered = (0..<count).map { mask & (1 << $0) != 0 }
        } else {
            usbPowered = []
        }
        let chargeOffset = usbOffset + 1 + count
        if r[2] >= 7, chargeOffset < r.count {
            let mask = r[chargeOffset]
            chargerActive = (0..<count).map { mask & (0x10 << $0) != 0 ? mask & (1 << $0) != 0 : nil }
        } else {
            chargerActive = []
        }
        let rssiOffset = usbOffset + 1
        if r[2] >= 6, rssiOffset + count <= r.count {
            rssi = (0..<count).map { Int(Int8(bitPattern: r[rssiOffset + $0])) }
        } else {
            rssi = []
        }
        lastUpdate = Date()
        for (slot, level) in batteries.enumerated() {
            chargeTrackers[slot, default: ChargeTracker()]
                .record(halvesConnected[slot] ? level : nil)
        }
        updateCharging()
        recordSides()

        if firstReport || wokeUp {
            autoMacUntil = Date().addingTimeInterval(5)
        }
        wokeUp = false
        if autoMacMode && isWindows && Date() < autoMacUntil {
            autoMacUntil = .distantPast  // once: a later manual switch to Windows stays
            setWindows(false)
        }
        if firstReport { fetchKeyStats() }
    }

    /// Battery history and notifications, per physical half.
    private func recordSides() {
        for side in Side.allCases {
            let slot = slot(for: side)
            let connected = isConnected(at: slot)
            // Right after a half connects the dongle reports 0% until it has read the battery;
            // a real 0% comes with a voltage (halves with the voltage service).
            let level = battery(at: slot).flatMap { $0 > 0 || voltage(at: slot) != nil ? $0 : nil }
            let external = isOnUSB(at: slot) || isCharging(at: slot)
            if !connected {
                connectedSince[side] = nil
            } else if connectedSince[side] == nil {
                connectedSince[side] = Date()
                // Reports only come on changes: make sure one follows the settle time.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime + 1) { [weak self] in
                    self?.refresh()
                }
            }
            let settling = connectedSince[side].map { Date().timeIntervalSince($0) < Self.settleTime } ?? false
            notifier.update(side: side, connected: connected, level: connected && !settling ? level : nil,
                            external: external, enabled: notificationsEnabled)
            if connected, !settling, let level {
                history.record(side: side, mv: voltage(at: slot) ?? 0, level: level, external: external)
            }
        }
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

    mutating func record(_ level: Int?, now: Date = Date()) {
        guard let level else {  // half disconnected
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
