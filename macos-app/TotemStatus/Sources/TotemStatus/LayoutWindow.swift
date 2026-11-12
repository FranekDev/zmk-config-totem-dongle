import SwiftUI

final class LayoutViewState: ObservableObject {
    @Published var layer: Int
    @Published var windows: Bool

    init(layer: Int = 0, windows: Bool = false) {
        self.layer = layer
        self.windows = windows
    }
}

struct LayoutWindow: View {
    @ObservedObject var model: KeyboardModel
    @StateObject private var state: LayoutViewState

    init(model: KeyboardModel) {
        self.model = model
        var layer = 0
#if DEBUG
        layer = DebugPreview.initialLayer
#endif
        _state = StateObject(wrappedValue: LayoutViewState(layer: layer, windows: model.isWindows))
    }

    var body: some View {
        Group {
            if let keymap = Keymap.shared {
                content(keymap)
            } else {
                ContentUnavailableView("Brak keymapy", systemImage: "keyboard",
                                       description: Text("Przebuduj apkę przez build-app.sh."))
            }
        }
        .frame(minWidth: 760, minHeight: 380)
        .onChange(of: model.isWindows) { _, windows in state.windows = windows }
    }

    @ViewBuilder
    private func content(_ keymap: Keymap) -> some View {
        VStack(spacing: 14) {
            KeyboardCanvas(keymap: keymap,
                           keys: keymap.resolve(layer: state.layer, windows: state.windows),
                           windows: state.windows)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            Legend(layerCount: min(keymap.browsableLayers.count, 9))
                .padding(.bottom, 16)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Warstwa", selection: $state.layer) {
                    ForEach(keymap.browsableLayers, id: \.self) { i in
                        Text(keymap.layers[i].name).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("System", selection: $state.windows) {
                    Image(systemName: "apple.logo").help("macOS").tag(false)
                    Image(systemName: "pc").help("Windows").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .navigationTitle("Układ klawiszy")
        .background(LayerShortcuts(layers: keymap.browsableLayers, selection: $state.layer))
    }
}

/// ⌘1…⌘9 switch layers.
private struct LayerShortcuts: View {
    let layers: [Int]
    @Binding var selection: Int

    var body: some View {
        ZStack {
            ForEach(Array(layers.prefix(9).enumerated()), id: \.offset) { pos, layer in
                Button("") { selection = layer }
                    .keyboardShortcut(KeyEquivalent(Character("\(pos + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct Legend: View {
    let layerCount: Int

    var body: some View {
        HStack(spacing: 18) {
            item(swatch: AnyView(RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    .overlay(Text("A").font(.system(size: 9)).foregroundStyle(.tertiary))),
                 text: "z warstwy niżej")
            item(swatch: AnyView(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)),
                 text: "przytrzymaj, by włączyć tę warstwę")
            item(swatch: AnyView(Text("⇧").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)),
                 text: "przy przytrzymaniu")
            Text("⌘1–⌘\(layerCount) zmienia warstwę")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func item(swatch: AnyView, text: String) -> some View {
        HStack(spacing: 6) {
            swatch.frame(width: 16, height: 16)
            Text(text)
        }
    }
}

// MARK: - Keyboard

private struct KeyboardCanvas: View {
    let keymap: Keymap
    let keys: [Keymap.ResolvedKey]
    let windows: Bool

    private var bounds: CGRect {
        keymap.layout.reduce(CGRect.null) { acc, k in
            acc.union(rotatedFrame(k))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let b = bounds
            let scale = min(geo.size.width / b.width, geo.size.height / b.height)
            let offset = CGPoint(x: (geo.size.width - b.width * scale) / 2 - b.minX * scale,
                                 y: (geo.size.height - b.height * scale) / 2 - b.minY * scale)
            ZStack(alignment: .topLeading) {
                ForEach(keymap.layout.indices, id: \.self) { i in
                    let k = keymap.layout[i]
                    let rotate = k.rot != 0
                    let anchor = rotate
                        ? UnitPoint(x: (k.rx - k.x) / k.w, y: (k.ry - k.y) / k.h)
                        : .center
                    KeyCap(key: keys[i], windows: windows, unit: 100 * scale)
                        .frame(width: k.w * scale, height: k.h * scale)
                        .rotationEffect(.degrees(k.rot), anchor: anchor)
                        .position(x: offset.x + (k.x + k.w / 2) * scale,
                                  y: offset.y + (k.y + k.h / 2) * scale)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(bounds.width / bounds.height, contentMode: .fit)
        .animation(.smooth(duration: 0.2), value: keys.map { $0.binding?.tap ?? "" })
    }

    /// Axis-aligned bounds of a key after rotating around (rx, ry).
    private func rotatedFrame(_ k: Keymap.PhysicalKey) -> CGRect {
        let rect = CGRect(x: k.x, y: k.y, width: k.w, height: k.h)
        guard k.rot != 0 else { return rect }
        let t = CGAffineTransform(translationX: k.rx, y: k.ry)
            .rotated(by: k.rot * .pi / 180)
            .translatedBy(x: -k.rx, y: -k.ry)
        return rect.applying(t)
    }
}

private struct KeyCap: View {
    let key: Keymap.ResolvedKey
    let windows: Bool
    /// Size of a 1u key in points.
    let unit: CGFloat

    private let inset: CGFloat = 0.06

    var body: some View {
        let b = key.binding
        ZStack {
            RoundedRectangle(cornerRadius: unit * 0.16, style: .continuous)
                .fill(fill)
            RoundedRectangle(cornerRadius: unit * 0.16, style: .continuous)
                .strokeBorder(key.activator ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: key.activator ? 2 : 1)

            if let b {
                VStack(spacing: unit * 0.02) {
                    KeyLabel(text: b.tap ?? "", windows: windows)
                        .font(.system(size: unit * tapSize(b), weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                    if let hold = b.hold {
                        KeyLabel(text: hold, windows: windows)
                            .font(.system(size: unit * 0.17, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                .foregroundStyle(key.inherited ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .padding(unit * 0.08)
            }
        }
        .padding(unit * inset)
        .help(b?.desc ?? "")
    }

    private var fill: AnyShapeStyle {
        if key.activator { return AnyShapeStyle(Color.accentColor.opacity(0.18)) }
        if key.inherited || key.binding == nil { return AnyShapeStyle(.quinary) }
        if key.binding?.kind == "system" { return AnyShapeStyle(Color.orange.opacity(0.16)) }
        return AnyShapeStyle(.quaternary)
    }

    private func tapSize(_ b: Keymap.Binding) -> CGFloat {
        let plain = (b.tap ?? "").replacingOccurrences(of: #"\{[^}]*\}"#, with: "X",
                                                        options: .regularExpression)
        return plain.count <= 1 ? 0.30 : plain.count <= 3 ? 0.22 : 0.17
    }
}

/// Renders "{sf:name}" as SF Symbols and "{gui}"/"{alt}"/"{ctrl}"/"{shift}" per OS.
private struct KeyLabel: View {
    let text: String
    let windows: Bool

    var body: some View {
        segments.reduce(Text("")) { acc, seg in Text("\(acc)\(seg)") }
    }

    private var segments: [Text] {
        var result: [Text] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            if open > rest.startIndex { result.append(Text(String(rest[..<open]))) }
            let token = rest[rest.index(after: open)..<close]
            if token.hasPrefix("sf:") {
                result.append(Text(Image(systemName: String(token.dropFirst(3)))))
            } else {
                rest = rest[rest.index(after: close)...]
                // Windows modifiers are words: "Ctrl+PgUp" instead of "CtrlPgUp".
                let joiner = windows && token != "shift" && !rest.isEmpty ? "+" : ""
                result.append(Text(modifier(String(token)) + joiner))
                continue
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { result.append(Text(String(rest))) }
        return result
    }

    private func modifier(_ m: String) -> String {
        switch (m, windows) {
        case ("gui", false): return "⌘"
        case ("gui", true): return "Win"
        case ("alt", false): return "⌥"
        case ("alt", true): return "Alt"
        case ("ctrl", false): return "⌃"
        case ("ctrl", true): return "Ctrl"
        case ("shift", _): return "⇧"
        default: return m
        }
    }
}
