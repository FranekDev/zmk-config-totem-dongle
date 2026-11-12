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
            Image(nsImage: TotemIcon.menuBarImage(dimmed: !model.connected))
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

    private func batteryRow(_ side: Side) -> BatteryRow {
        let left = side == .left
        let reading = model.reading(for: side)
        return BatteryRow(name: left ? "Lewa" : "Prawa",
                          left: left,
                          level: reading?.level,
                          estimated: reading?.estimated ?? false,
                          full: reading?.full ?? false,
                          stalled: reading?.stalled ?? false,
                          toFull: reading?.toFull,
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
                            let tiles = [batteryRow(.left), batteryRow(.right)]
                            let notes = tiles.contains { $0.hasTrailing }
                            ForEach(tiles.indices, id: \.self) { i in
                                tiles[i].withNote(reserved: notes)
                            }
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

/// Raycast-style list row: bare tinted icon, title + subtitle, trailing accessory.
struct ListRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
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

/// Whether a battery row is opened to show its details.
final class ExpandState: ObservableObject {
    @Published var open = false

    init() {
        #if DEBUG
        open = CommandLine.arguments.contains("--expanded")
        #endif
    }
}

private struct BatteryRow: View {
    let name: String
    let left: Bool
    /// Keep the note's column, so the rows match when only one of them has a note.
    var reserveNote = false
    /// Measured, or estimated while on a cable.
    let level: Int?
    var estimated: Bool = false
    /// On a cable with the charger done.
    var full: Bool = false
    /// On a cable, but the charger stopped though the cell can't be full yet.
    var stalled: Bool = false
    /// Estimated time until charged.
    var toFull: TimeInterval? = nil
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

    @StateObject var expand = ExpandState()

    func withNote(reserved: Bool) -> BatteryRow {
        var row = self
        row.reserveNote = reserved
        return row
    }

    var body: some View {
        // One line per half: which one, its level as a bar and a number, then what's next
        // (time left, or the state when it needs attention). The colour carries the state.
        // A click opens the rest underneath.
        VStack(spacing: 8) {
            summary
            if expand.open { detailsList }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.quinary.opacity(0.5), in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { expand.open.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) połówka")
        .accessibilityHint(detailLines.dropFirst().joined(separator: "\n"))
        .accessibilityAddTraits(.isButton)
    }

    private var summary: some View {
        HStack(spacing: 8) {
            HalfIcon(left: left)
                .foregroundStyle(tint)
                .frame(width: 26, height: 20)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 13))
                .frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let level, connected {
                        Capsule()
                            .fill(tint.gradient)
                            .frame(width: max(4, geo.size.width * Double(level) / 100))
                    }
                }
            }
            .frame(height: 4)
            Text(percent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(connected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
            if reserveNote {
                // Kept even when this half has nothing to say, so the bars of both rows match.
                HStack(spacing: 3) {
                    if let badge, connected {
                        Image(systemName: badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                    }
                    if let note {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(width: 70, alignment: .trailing)
            }
            // Says the row opens: voltage, signal and the rest are a click away.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expand.open ? 90 : 0))
        }
    }

    /// Something to show after the level: a mark, a note, or both.
    var hasTrailing: Bool { note != nil || (connected && badge != nil) }

    /// What the summary line doesn't already say: label left, value right, then a footnote.
    private var detailsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !connected {
                detailRow("Stan") { Text("Rozłączona z donglem") }
            } else {
                if let voltageText { detailRow("Napięcie") { Text(voltageText) } }
                if let time { detailRow(time.label) { Text(time.value) } }
                if let rssi {
                    detailRow("Sygnał") {
                        HStack(spacing: 4) {
                            SignalBars(rssi: rssi)
                            Text("\(rssi) dBm")
                        }
                    }
                    .help("Sygnał do dongla: \(SignalBars.quality(rssi))")
                }
                if let footnote {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: footnote.warning ? "exclamationmark.triangle" : "info.circle")
                            .foregroundStyle(footnote.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        Text(footnote.short)
                            .foregroundStyle(footnote.warning ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10))
                    .padding(.top, 2)
                    .help(footnote.full)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Under the name, past the icon.
        .padding(.leading, 34)
    }

    private func detailRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value().monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private var voltageText: String? {
        voltage.map { (Double($0) / 1000).formatted(.number.precision(.fractionLength(2))) + " V" }
    }

    /// Time to full on a cable, else time left on battery.
    private var time: (label: String, value: String)? {
        if stalled { return nil }
        if approximate { return toFull.map { ("Do pełna", formatToFull($0)) } }
        return remaining.map { ("Zostało", formatRemaining($0)) }
    }

    /// The caveat about the numbers above: one line in the row, in full in its tooltip
    /// and for VoiceOver.
    private var footnote: (short: String, full: String, warning: Bool)? {
        if stalled {
            let text = "Ładowarka przestała ładować, choć bateria była prawie pusta, więc pokazuję ostatni poziom na baterii. Bateria nie przyjmuje ładunku: sprawdź wyłącznik (ON), lutowanie przewodów baterii i samo ogniwo."
            return (text, text, true)
        }
        if approximate {
            return estimated
                ? ("Poziom szacowany z napięcia; dokładny po odpięciu kabla.",
                   "Poziom szacowany z napięcia podczas ładowania (na kablu jest ono wyższe niż samej baterii); dokładny poziom zobaczysz po odpięciu kabla.",
                   false)
                : ("Na kablu to napięcie ładowarki; prawdziwy poziom po odpięciu kabla.",
                   "Na kablu odczyt pokazuje napięcie ładowarki, nie baterii. Prawdziwy poziom zobaczysz po odpięciu kabla.",
                   false)
        }
        if remaining == nil {
            let text = "Czas pracy oszacuję po kilku godzinach na baterii."
            return (text, text, false)
        }
        return nil
    }

    /// Everything about the half in full, for VoiceOver.
    private var detailLines: [String] {
        var lines = ["\(name) połówka"]
        guard connected else { return lines + ["Rozłączona z donglem"] }
        lines.append("Stan: \(status)")
        if let level { lines.append("Poziom: \(approximate ? "~" : "")\(level)%") }
        if let voltageText { lines.append("Napięcie: \(voltageText)") }
        if let time { lines.append("\(time.label): \(time.value)") }
        if let footnote { lines.append(footnote.full) }
        if let rssi { lines.append("Sygnał do dongla: \(rssi) dBm (\(SignalBars.quality(rssi)))") }
        return lines
    }

    private var percent: String {
        guard let level, connected else { return "—" }
        return approximate ? "~\(level)%" : "\(level)%"
    }

    /// Under the level: the time left (to full on a cable, where the bolt says so, else on
    /// battery), or the state when that needs attention. The rest is in the tooltip.
    var note: String? {
        guard connected else { return "Rozłączona" }
        if stalled { return "Nie ładuje" }
        if full { return "Naładowana" }
        if approximate { return toFull.map { Self.plain(formatToFull($0)) } }
        if let level, level == 0 { return "Naładuj" }
        if let level, level <= 20 { return "Niski poziom" }
        return remaining.map { Self.plain(formatRemaining($0)) }
    }

    /// Without the "~": the grey text reads as an estimate as it is.
    private static func plain(_ text: String) -> String {
        text.hasPrefix("~") ? String(text.dropFirst()) : text
    }

    /// Small mark by the level: on a cable, or a problem.
    private var badge: String? {
        if stalled { return "exclamationmark.triangle.fill" }
        if full { return "checkmark" }
        if onUSB || charging { return "bolt.fill" }
        return nil
    }

    private var status: String {
        if stalled { return "Nie ładuje się" }
        if full { return "Naładowana" }
        if onUSB { return "Ładuje" }
        if charging { return "Ładuje" }
        if let level, level == 0 { return "Naładuj baterię" }
        if let level, level <= 20 { return "Niski poziom" }
        return "Na baterii"
    }

    private var tint: Color {
        guard let level, connected else { return .secondary }
        if stalled { return .orange }
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

/// Both halves of the keyboard as a tiny glyph, the one in question solid and the other faint.
private struct HalfIcon: View {
    let left: Bool

    var body: some View {
        Canvas { context, size in
            let key = 2.6, gap = 0.9, pitch = key + gap
            let half = 3 * key + 2 * gap, between = 2.6
            let x0 = (size.width - 2 * half - between) / 2
            let y0 = (size.height - 4 * key - 3 * gap) / 2
            for side in 0..<2 {
                let origin = x0 + Double(side) * (half + between)
                var keys = Path()
                for column in 0..<3 {
                    // Columns step down towards the outer edge, like the real halves.
                    let outward = side == 0 ? 2 - column : column
                    for row in 0..<3 {
                        keys.addRoundedRect(in: CGRect(x: origin + Double(column) * pitch,
                                                       y: y0 + Double(row) * pitch + Double(outward) * 0.6,
                                                       width: key, height: key),
                                            cornerSize: CGSize(width: 0.7, height: 0.7))
                    }
                }
                // Thumb keys on the inner side.
                for thumb in 0..<2 {
                    let column = side == 0 ? 2 - thumb : thumb
                    keys.addRoundedRect(in: CGRect(x: origin + Double(column) * pitch,
                                                   y: y0 + 3 * pitch + Double(thumb) * 0.6 + 0.4,
                                                   width: key, height: key),
                                        cornerSize: CGSize(width: 0.7, height: 0.7))
                }
                var layer = context
                layer.opacity = (side == 0) == left ? 1 : 0.3
                layer.fill(keys, with: .foreground)
            }
        }
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
