#if DEBUG
import AppKit
import SwiftUI

/// `swift run TotemStatus --preview [--disconnected]` opens the panel in a window with sample data.
enum DebugPreview {
    @MainActor static var window: NSWindow?
    @MainActor static var initialLayer = 0

    @MainActor static func showIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--preview") else { return }
        let model = KeyboardModel()
        if args.contains("--disconnected") {
            model.setPreview(connected: false, isWindows: false, layer: 0, batteries: [], charging: [])
        } else {
            model.applyPreviewState(isWindows: args.contains("--win"))
        }
        let w: NSWindow
        if args.contains("--battery") {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
            w.toolbarStyle = .unified
            let host = NSHostingView(rootView: BatteryHistoryWindow(model: model, history: model.history))
            host.sceneBridgingOptions = .all
            w.contentView = host
        } else if args.contains("--layout") {
            if let i = args.firstIndex(of: "--layer"), i + 1 < args.count, let l = Int(args[i + 1]) {
                DebugPreview.initialLayer = l
            }
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 460),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
            w.toolbarStyle = .unified
            let host = NSHostingView(rootView: LayoutWindow(model: model))
            host.sceneBridgingOptions = .all
            w.contentView = host
        } else {
            w = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: MenuView(model: model).fixedSize())
        }
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

extension KeyboardModel {
    func applyPreviewState(isWindows: Bool) {
        setPreview(connected: true, isWindows: isWindows, layer: isWindows ? 1 : 0,
                   batteries: [64, 18], charging: [false, false])
        setPreview(voltages: [4120, 3720], usbPowered: [true, false], rssi: [-58, -81])
        history.setPreview(Self.sampleHistory())
        keyStats.setPreview(Self.sampleKeyCounts(), since: Date().addingTimeInterval(-12 * 24 * 3600))
    }

    /// A week of made-up readings: left charges on USB yesterday, right slowly discharges.
    static func sampleHistory() -> [BatterySample] {
        var out: [BatterySample] = []
        let now = Date()
        for i in stride(from: 7 * 24 * 6, through: 0, by: -1) {
            let date = now.addingTimeInterval(-Double(i) * 600)
            let h = Double(i) / 6
            let rightMv = 3720 + Int(h * 1.6) + Int.random(in: -6...6)
            out.append(BatterySample(date: date, side: .right, mv: rightMv,
                                     level: max(0, min(100, 18 + Int(h / 6))), external: false))
            let usb = h < 26 && h > 22
            let leftMv = usb ? 4150 : (h <= 22 ? 4180 - Int((22 - h) * 2.5) : 3900 + Int((h - 26) * 0.9))
            out.append(BatterySample(date: date, side: .left, mv: leftMv + Int.random(in: -6...6),
                                     level: usb ? 70 : (h <= 22 ? 98 - Int((22 - h) * 1.5) : 66 + Int((h - 26) / 5)),
                                     external: usb))
        }
        return out.sorted { $0.date < $1.date }
    }

    static func sampleKeyCounts() -> [Int] {
        let weights = [2, 9, 14, 10, 6, 12, 16, 22, 18, 8, 3, 4, 6, 8, 2, 30, 12, 9, 7, 5, 4, 3, 2, 5, 11, 2, 3,
                       26, 1, 25, 6, 14, 9, 16, 20, 40, 18, 7]
        return weights.map { $0 * 412 + Int.random(in: 0...200) }
    }
}
#endif
