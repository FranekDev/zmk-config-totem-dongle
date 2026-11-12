import SwiftUI

@main
struct TotemStatusApp: App {
    @StateObject private var model = KeyboardModel()

    init() {
        // Menu bar only, no Dock icon (also when run outside the .app bundle).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        if model.connected {
            Image(nsImage: TotemIcon.statusImage(
                symbol: model.isWindows ? "pc" : "apple.logo",
                batteries: [(model.leftBattery, model.leftCharging),
                            (model.rightBattery, model.rightCharging)]))
        } else {
            Image(nsImage: TotemIcon.statusImage(symbol: nil, dimmed: true))
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: TotemIcon.menuBarImage(height: 14))
                Text("Totem").font(.headline)
                Spacer()
                Circle()
                    .fill(model.connected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(model.connected ? "Połączono" : "Brak dongla")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.connected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tryb").font(.caption).foregroundStyle(.secondary)
                    Picker("Tryb", selection: Binding(
                        get: { model.isWindows },
                        set: { model.setWindows($0) }
                    )) {
                        Label("macOS", systemImage: "apple.logo").tag(false)
                        Label("Windows", systemImage: "pc").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bateria").font(.caption).foregroundStyle(.secondary)
                    BatteryRow(name: "Lewa", level: model.leftBattery, charging: model.leftCharging)
                    BatteryRow(name: "Prawa", level: model.rightBattery, charging: model.rightCharging)
                }

                HStack {
                    Text("Aktywna warstwa").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.activeLayerName).monospaced()
                }
                .font(.caption)
            } else {
                Text("Podłącz dongle z firmware obsługującym raw HID (totem_status).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Zamień lewą i prawą", isOn: $model.swapHalves)
            Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            HStack {
                Button("Odśwież") { model.refresh() }
                Spacer()
                Button("Zakończ") { NSApplication.shared.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 280)
    }
}

struct BatteryRow: View {
    let name: String
    let level: Int?
    let charging: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 26)
            Text(name)
            Spacer()
            if let level, level > 0 {
                if charging {
                    Text("ładuje").font(.caption).foregroundStyle(.green)
                }
                Text("\(level)%").monospacedDigit()
            } else {
                Text("rozłączona").foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        guard let level, level > 0 else { return "battery.0percent" }
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var color: Color {
        guard let level, level > 0 else { return .secondary }
        if charging { return .green }
        return level <= 20 ? .red : .primary
    }
}
