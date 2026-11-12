import SwiftUI

@main
struct TotemStatusApp: App {
    @StateObject private var model = KeyboardModel()

    init() {
        // Menu bar only, no Dock icon (also when run outside the .app bundle).
        NSApplication.shared.setActivationPolicy(.accessory)
#if DEBUG
        DispatchQueue.main.async { DebugPreview.showIfRequested() }
#endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // Only the TOTEM face; everything else lives in the panel.
            Image(nsImage: TotemIcon.menuBarImage(dimmed: !model.connected))
        }
        .menuBarExtraStyle(.window)

        Window("Układ klawiszy", id: "layout") {
            LayoutWindow(model: model)
        }
        .defaultSize(width: 980, height: 460)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

// MARK: - Panel

struct MenuView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.openWindow) private var openWindow

    private func showLayout() {
        openWindow(id: "layout")
        NSApp.activate()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HeaderView(model: model)

                if model.connected {
                    Section(title: "Tryb") { ModePicker(model: model) }
                    Section(title: "Bateria") {
                        VStack(spacing: 2) {
                            BatteryRow(name: "Lewa połówka", level: model.leftBattery,
                                       connected: model.leftConnected, charging: model.leftCharging)
                            BatteryRow(name: "Prawa połówka", level: model.rightBattery,
                                       connected: model.rightConnected, charging: model.rightCharging)
                        }
                    }
                } else {
                    EmptyStateView()
                }

                Section(title: "Klawiatura") {
                    Button(action: showLayout) {
                        ListRow(symbol: "keyboard", tint: .accentColor, title: "Układ klawiszy",
                                subtitle: "Podgląd wszystkich warstw") {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("k")
                }

                Section(title: "Ustawienia") {
                    VStack(spacing: 2) {
                        SettingRow(title: "Zamień lewą i prawą", symbol: "arrow.left.arrow.right",
                                   isOn: Binding(get: { model.swapHalves },
                                                 set: { model.swapHalves = $0 }))
                        SettingRow(title: "Uruchamiaj przy logowaniu", symbol: "power",
                                   isOn: Binding(get: { model.launchAtLogin },
                                                 set: { model.setLaunchAtLogin($0) }))
                    }
                }
            }
            .padding(14)

            ActionBar(model: model)
        }
        .frame(width: 320)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: TotemIcon.menuBarImage(height: 18))
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 1) {
                Text("Totem").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.connected ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.connected {
                Text(model.activeLayerName)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .help("Aktywna warstwa")
            }
        }
    }

    private var statusText: String {
        model.connected ? "Połączono przez dongle" : "Nie wykryto dongla"
    }
}

// MARK: - Mode

private struct ModePicker: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                tile("macOS", symbol: "apple.logo", selected: !model.isWindows) {
                    model.setWindows(false)
                }
                tile("Windows", symbol: "pc", selected: model.isWindows) {
                    model.setWindows(true)
                }
            }
        }
    }

    private func tile(_ title: String, symbol: String, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 20)
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(.rect(cornerRadius: 14))
            .glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                         in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.25), value: selected)
    }
}

// MARK: - Rows

/// Raycast-style list row: rounded icon tile, title + subtitle, trailing accessory.
private struct ListRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.15), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quinary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

private struct BatteryRow: View {
    let name: String
    let level: Int?
    let connected: Bool
    let charging: Bool

    var body: some View {
        ListRow(symbol: symbol, tint: tint, title: name, subtitle: subtitle) {
            if let level, connected {
                HStack(spacing: 8) {
                    LevelBar(fraction: Double(level) / 100, tint: tint)
                    Text("\(level)%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private var subtitle: String {
        if !connected { return "Rozłączona" }
        if charging { return "Ładuje" }
        if let level, level == 0 { return "Bateria prawie pusta — naładuj" }
        if let level, level <= 20 { return "Niski poziom baterii" }
        return "Na baterii"
    }

    private var symbol: String {
        guard let level, connected else { return "battery.0percent" }
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var tint: Color {
        guard let level, connected else { return .secondary }
        if charging { return .green }
        if level <= 20 { return .red }
        if level <= 40 { return .orange }
        return .green
    }
}

private struct LevelBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(tint.gradient)
                .frame(width: max(4, 56 * min(max(fraction, 0), 1)))
        }
        .frame(width: 56, height: 5)
    }
}

private struct SettingRow: View {
    let title: String
    let symbol: String
    let isOn: Binding<Bool>

    var body: some View {
        ListRow(symbol: symbol, tint: .secondary, title: title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: TotemIcon.menuBarImage(height: 30))
                .renderingMode(.template)
                .foregroundStyle(.tertiary)
            Text("Podłącz dongle")
                .font(.system(size: 13, weight: .semibold))
            Text("Dongle musi mieć firmware z modułem totem_status.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

// MARK: - Action bar (Raycast-style footer)

private struct ActionBar: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        HStack(spacing: 4) {
            Button { model.refresh() } label: {
                ActionLabel(title: "Odśwież", keys: ["⌘", "R"])
            }
            .keyboardShortcut("r")

            Spacer()

            Button { NSApplication.shared.terminate(nil) } label: {
                ActionLabel(title: "Zakończ", keys: ["⌘", "Q"])
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.accessoryBar)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quinary.opacity(0.6))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct ActionLabel: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12))
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 4))
                }
            }
        }
    }
}
