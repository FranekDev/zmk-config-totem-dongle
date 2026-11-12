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
        if args.contains("--layout") {
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
                   batteries: [64, 18], charging: [true, false])
    }
}
#endif
