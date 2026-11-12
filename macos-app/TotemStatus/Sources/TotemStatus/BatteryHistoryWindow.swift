import Charts
import SwiftUI

/// Series colors: categorical slots 1 (blue) and 2 (orange), with separate dark-mode steps.
extension Side {
    var color: Color {
        let (light, dark): (UInt32, UInt32) = self == .left ? (0x2A78D6, 0x3987E5) : (0xEB6834, 0xD95926)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct BatteryHistoryWindow: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var history: BatteryHistory
    /// No @State: the command line toolchain lacks the SwiftUI macro plugin.
    final class ViewState: ObservableObject {
        @Published var range: Range = .week
        @Published var selected: Date?
    }
    @StateObject private var state = ViewState()
    private var range: Range { state.range }

    enum Range: String, CaseIterable, Identifiable {
        case day = "24 h", week = "7 dni", month = "30 dni"
        var id: Self { self }
        var seconds: TimeInterval {
            switch self {
            case .day: 24 * 3600
            case .week: 7 * 24 * 3600
            case .month: 30 * 24 * 3600
            }
        }
    }

    /// A continuous stretch of one half: split on gaps and on switching between battery and USB.
    private struct Segment: Identifiable {
        let id: String
        let side: Side
        let external: Bool
        let points: [BatterySample]
    }

    private var since: Date { Date().addingTimeInterval(-range.seconds) }

    private var segments: [Segment] {
        var result: [Segment] = []
        for side in Side.allCases {
            var current: [BatterySample] = []
            func flush() {
                if let first = current.first {
                    result.append(Segment(id: "\(side.rawValue)-\(result.count)", side: side,
                                          external: first.external, points: current))
                }
                current = []
            }
            for s in history.samples(for: side, since: since) where s.mv > 0 {
                if let last = current.last,
                   s.external != last.external || s.date.timeIntervalSince(last.date) > 3600 {
                    flush()
                }
                current.append(s)
            }
            flush()
        }
        return result
    }

    var body: some View {
        let segments = segments
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ForEach(Side.allCases, id: \.self) { side in
                    SideTile(side: side, model: model, history: history)
                }
            }
            if segments.isEmpty {
                ContentUnavailableView("Brak danych", systemImage: "chart.xyaxis.line",
                                       description: Text("Historia zbiera się, gdy aplikacja działa, a połówki raportują napięcie."))
                    .frame(maxHeight: .infinity)
            } else {
                chart(segments)
                legend
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Zakres", selection: $state.range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .navigationTitle("Historia baterii")
    }

    private func chart(_ segments: [Segment]) -> some View {
        Chart {
            ForEach(segments) { seg in
                ForEach(seg.points, id: \.date) { p in
                    LineMark(x: .value("Czas", p.date),
                             y: .value("Napięcie", Double(p.mv) / 1000),
                             series: .value("Odcinek", seg.id))
                        .foregroundStyle(by: .value("Połówka", seg.side.name))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round,
                                               dash: seg.external ? [3, 4] : []))
                        .interpolationMethod(.monotone)
                }
            }
            if let selected = state.selected {
                RuleMark(x: .value("Czas", selected))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(date: selected, values: nearest(to: selected, in: segments))
                    }
                ForEach(nearest(to: selected, in: segments), id: \.side) { p in
                    PointMark(x: .value("Czas", p.date), y: .value("Napięcie", Double(p.mv) / 1000))
                        .foregroundStyle(p.side.color)
                        .symbolSize(64)
                }
            }
        }
        .chartForegroundStyleScale([Side.left.name: Side.left.color, Side.right.name: Side.right.color])
        .chartLegend(.hidden)
        .chartYScale(domain: 3.3...4.25)
        .chartXScale(domain: since...Date())
        .chartYAxis {
            AxisMarks(position: .leading, values: [3.4, 3.6, 3.8, 4.0, 4.2]) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(d.formatted(.number.precision(.fractionLength(1))) + " V")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: range == .day ? .dateTime.hour().minute()
                                                     : .dateTime.day().month(.abbreviated))
            }
        }
        .chartXSelection(value: $state.selected)
        .frame(maxHeight: .infinity)
    }

    private var legend: some View {
        HStack(spacing: 18) {
            ForEach(Side.allCases, id: \.self) { side in
                HStack(spacing: 6) {
                    Capsule().fill(side.color).frame(width: 14, height: 3)
                    Text("\(side.name) połówka")
                }
            }
            HStack(spacing: 6) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 1.5))
                    p.addLine(to: CGPoint(x: 14, y: 1.5))
                }
                .stroke(.secondary, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .frame(width: 14, height: 3)
                Text("na kablu (napięcie ładowarki, nie baterii)")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// The sample of each half closest to `date` (within the visible stretch).
    private func nearest(to date: Date, in segments: [Segment]) -> [BatterySample] {
        Side.allCases.compactMap { side in
            segments.filter { $0.side == side }.flatMap(\.points)
                .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                .flatMap { abs($0.date.timeIntervalSince(date)) < range.seconds / 40 ? $0 : nil }
        }
    }
}

private struct Tooltip: View {
    let date: Date
    let values: [BatterySample]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .font(.system(size: 11, weight: .semibold))
            ForEach(values, id: \.side) { p in
                HStack(spacing: 6) {
                    Circle().fill(p.side.color).frame(width: 7, height: 7)
                    Text(p.side.name)
                    Spacer(minLength: 10)
                    Text((Double(p.mv) / 1000).formatted(.number.precision(.fractionLength(2))) + " V")
                        .monospacedDigit()
                    Text(p.external ? "~\(p.level)%" : "\(p.level)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11))
        .padding(8)
        .frame(minWidth: 170)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

private struct SideTile: View {
    let side: Side
    @ObservedObject var model: KeyboardModel
    @ObservedObject var history: BatteryHistory

    var body: some View {
        let left = side == .left
        let connected = left ? model.leftConnected : model.rightConnected
        let reading = model.reading(for: side)
        let level = reading?.level
        let external = reading.map { $0.estimated } ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Capsule().fill(side.color).frame(width: 10, height: 3)
                Text("\(side.name) połówka").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if connected, let level {
                Text(external ? "~\(level)%" : "\(level)%")
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                Text(detail(external: external))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("—").font(.system(size: 26, weight: .semibold)).foregroundStyle(.tertiary)
                Text("Rozłączona").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quinary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    private func detail(external: Bool) -> String {
        if external { return "Na kablu, poziom szacowany z czasu ładowania" }
        if let t = history.estimatedRemaining(for: side) { return "Zostało \(formatRemaining(t))" }
        return "Szacunek czasu po kilku godzinach na baterii"
    }
}
