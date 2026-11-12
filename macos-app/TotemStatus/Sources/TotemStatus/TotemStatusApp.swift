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
                // Opening the panel makes the dongle read both halves again.
                .onAppear { model.refresh() }
        } label: {
            // The TOTEM face, plus the active layer while it isn't a base layer.
            HStack(spacing: 4) {
                Image(nsImage: TotemIcon.menuBarImage(dimmed: !model.connected))
                if model.showLayerInMenuBar, let layer = model.menuBarLayerName {
                    Text(layer)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Układ klawiszy", id: "layout") {
            LayoutWindow(model: model)
        }
        .defaultSize(width: 980, height: 460)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Historia baterii", id: "battery") {
            BatteryHistoryWindow(model: model, history: model.history)
        }
        .defaultSize(width: 720, height: 420)
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

    private func showBattery() {
        openWindow(id: "battery")
        NSApp.activate()
    }

    private func batteryRow(_ side: Side) -> some View {
        let left = side == .left
        let reading = model.reading(for: side)
        return BatteryRow(name: left ? "Lewa" : "Prawa",
                          level: reading?.level,
                          estimated: reading?.estimated ?? false,
                          full: reading?.full ?? false,
                          voltage: left ? model.leftVoltage : model.rightVoltage,
                          connected: left ? model.leftConnected : model.rightConnected,
                          charging: left ? model.leftCharging : model.rightCharging,
                          onUSB: left ? model.leftOnUSB : model.rightOnUSB,
                          remaining: model.history.estimatedRemaining(for: side),
                          rssi: left ? model.leftRSSI : model.rightRSSI)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HeaderView(model: model)

                if model.connected {
                    Section(title: "Tryb") { ModePicker(model: model) }
                    Section(title: "Bateria") {
                        VStack(spacing: 2) {
                            batteryRow(.left)
                            batteryRow(.right)
                            Button(action: showBattery) {
                                ListRow(symbol: "chart.xyaxis.line", tint: .accentColor,
                                        title: "Historia baterii",
                                        subtitle: "Napięcie obu połówek w czasie") {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(.rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("b")
                        }
                    }
                } else {
                    EmptyStateView()
                }

                Section(title: "Klawiatura") {
                    Button(action: showLayout) {
                        ListRow(symbol: "keyboard", tint: .accentColor, title: "Układ klawiszy",
                                subtitle: "Warstwy i mapa naciśnięć") {
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
                        SettingRow(title: "Uruchamiaj przy logowaniu", symbol: "power",
                                   isOn: Binding(get: { model.launchAtLogin },
                                                 set: { model.setLaunchAtLogin($0) }))
                        SettingRow(title: "Tryb macOS po podłączeniu", symbol: "apple.logo",
                                   subtitle: "Też po wybudzeniu Maca",
                                   isOn: $model.autoMacMode)
                        SettingRow(title: "Warstwa w pasku menu", symbol: "menubar.rectangle",
                                   isOn: $model.showLayerInMenuBar)
                        SettingRow(title: "Powiadomienia o baterii", symbol: "bell",
                                   isOn: $model.notificationsEnabled)
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
struct ListRow<Accessory: View>: View {
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
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        // Wrap instead of truncating: the menu bar panel is narrow.
                        .fixedSize(horizontal: false, vertical: true)
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
    /// Measured, or estimated while on a cable.
    let level: Int?
    var estimated: Bool = false
    /// On a cable with the charger done.
    var full: Bool = false
    let voltage: Int?
    let connected: Bool
    let charging: Bool
    /// On USB the charger drives the battery pin, so the reading is not the cell's real level.
    var onUSB: Bool = false
    /// Estimated time left on battery.
    var remaining: TimeInterval? = nil
    /// Link RSSI in dBm.
    var rssi: Int? = nil

    /// Older half firmware doesn't report USB power: a rising level (charging) means a cable too.
    private var approximate: Bool { (onUSB || charging) && !full }

    var body: some View {
        ListRow(symbol: symbol, tint: tint, title: name, subtitle: subtitle) {
            if let level, connected {
                HStack(spacing: 8) {
                    if let rssi { SignalBars(rssi: rssi) }
                    LevelBar(fraction: Double(level) / 100, tint: tint)
                        .opacity(approximate ? 0.45 : 1)
                    Text(approximate ? "~\(level)%" : "\(level)%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(approximate ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .contentShape(.rect(cornerRadius: 10))
        .help(details)
    }

    /// Everything about the half in full, for the tooltip.
    private var details: String {
        var lines = ["\(name) połówka"]
        guard connected else { return (lines + ["Rozłączona z donglem"]).joined(separator: "\n") }
        lines.append("Stan: \(status)")
        if let level { lines.append("Poziom: \(approximate ? "~" : "")\(level)%") }
        if let voltage {
            lines.append("Napięcie: " + (Double(voltage) / 1000).formatted(.number.precision(.fractionLength(2))) + " V")
        }
        if approximate {
            lines.append(estimated
                ? "Poziom szacowany: ostatni odczyt na baterii plus czas ładowania. Na kablu napięcie jest ładowarki, nie baterii; dokładny poziom zobaczysz po odpięciu kabla."
                : "Na kablu odczyt pokazuje napięcie ładowarki, nie baterii. Prawdziwy poziom zobaczysz po odpięciu kabla.")
        } else if let remaining {
            lines.append("Zostało: \(formatRemaining(remaining))")
        } else {
            lines.append("Czas pracy oszacuję po kilku godzinach na baterii")
        }
        if let rssi { lines.append("Sygnał do dongla: \(rssi) dBm (\(SignalBars.quality(rssi)))") }
        return lines.joined(separator: "\n")
    }

    private var subtitle: String {
        guard connected else { return "Rozłączona" }
        var parts = [status]
        if !approximate, let remaining { parts.append(formatRemaining(remaining)) }
        if let voltage {
            parts.append((Double(voltage) / 1000).formatted(.number.precision(.fractionLength(2))) + " V")
        }
        return parts.joined(separator: " · ")
    }

    private var status: String {
        if full { return "Naładowana" }
        if onUSB { return "Ładuje" }
        if charging { return "Ładuje" }
        if let level, level == 0 { return "Naładuj baterię" }
        if let level, level <= 20 { return "Niski poziom" }
        return "Na baterii"
    }

    private var symbol: String {
        guard let level, connected else { return "battery.0percent" }
        if full { return "battery.100percent.bolt" }
        if onUSB { return "powerplug" }
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
        if full { return .green }
        if onUSB { return .blue }
        if charging { return .green }
        if level <= 20 { return .red }
        if level <= 40 { return .orange }
        return .green
    }
}

/// Link quality of a half: 3 bars ≥ -65 dBm, 2 ≥ -75, 1 ≥ -85, else weak.
private struct SignalBars: View {
    let rssi: Int

    private var fraction: Double {
        rssi >= -65 ? 1 : rssi >= -75 ? 0.66 : rssi >= -85 ? 0.33 : 0
    }

    static func quality(_ rssi: Int) -> String {
        rssi >= -65 ? "bardzo dobry" : rssi >= -75 ? "dobry" : rssi >= -85 ? "słaby" : "bardzo słaby"
    }

    var body: some View {
        Image(systemName: "cellularbars", variableValue: fraction)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fraction <= 0.33 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
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
    var subtitle: String? = nil
    let isOn: Binding<Bool>

    var body: some View {
        ListRow(symbol: symbol, tint: .secondary, title: title, subtitle: subtitle) {
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

/// Drives the short "I got your ⌘R" animation in the footer.
private final class RefreshFeedback: ObservableObject {
    @Published var tick = 0
    @Published var flash = false

    func fire() {
        tick += 1
        withAnimation(.easeOut(duration: 0.05)) { flash = true }
        let current = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.tick == current else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.flash = false }
        }
    }
}

private struct ActionBar: View {
    @ObservedObject var model: KeyboardModel
    @StateObject private var feedback = RefreshFeedback()

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.refresh()
                feedback.fire()
            } label: {
                ActionLabel(title: "Odśwież", keys: ["⌘", "R"],
                            symbol: "arrow.clockwise", trigger: feedback.tick, flash: feedback.flash)
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
    var symbol: String? = nil
    var trigger: Int = 0
    var flash: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(flash ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .symbolEffect(.rotate.clockwise.byLayer, options: .speed(3), value: trigger)
            }
            Text(title).font(.system(size: 12))
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(flash ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.quaternary.opacity(0.7)),
                                    in: .rect(cornerRadius: 4))
                        .scaleEffect(flash ? 0.88 : 1)
                }
            }
        }
    }
}
