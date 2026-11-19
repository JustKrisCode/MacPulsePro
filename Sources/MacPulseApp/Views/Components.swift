import Charts
import MacPulseCore
import SwiftUI

extension Severity {
    var color: Color {
        switch self { case .ok: .green; case .info: .blue; case .warning: .orange; case .critical: .red }
    }
}

extension CleanupClass {
    var color: Color {
        switch self { case .safe: .green; case .review: .orange; case .protected: .blue; case .unknown: .gray }
    }
    var label: String { rawValue.uppercased() }
}

extension ThermalState {
    var color: Color { switch self { case .nominal: .green; case .fair: .yellow; case .serious: .orange; case .critical: .red } }
    var title: String { rawValue.capitalized }
}

extension MemoryPressure {
    var color: Color { switch self { case .normal: .green; case .warning: .orange; case .critical: .red; case .unknown: .gray } }
}

func usageColor(_ v: Double?) -> Color {
    guard let v else { return .gray }
    return v >= 90 ? .red : v >= 70 ? .orange : .accentColor
}

struct SeverityDot: View {
    let severity: Severity
    var body: some View {
        Circle().fill(severity.color).frame(width: 8, height: 8)
            .accessibilityLabel(severity.rawValue)
    }
}

struct ProvenanceBadge: View {
    let provenance: Provenance
    var body: some View {
        Text(provenance.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(.secondary)
            .help(help)
    }
    var background: Color {
        switch provenance { case .measured: .green.opacity(0.15); case .measuredUndocumented: .teal.opacity(0.15)
        case .estimated, .inferred: .orange.opacity(0.15); case .unavailable: .gray.opacity(0.15) }
    }
    var help: String {
        switch provenance {
        case .measured: "Read from a documented macOS interface."
        case .measuredUndocumented: "A real value read from IORegistry driver statistics; not a documented Apple API."
        case .estimated: "Calculated from measured values."
        case .inferred: "Rule-based inference — may be wrong."
        case .unavailable: "Not obtainable without private APIs or administrator rights."
        }
    }
}

struct ClassBadge: View {
    let cls: CleanupClass
    var body: some View {
        Text(cls.label).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(cls.color.opacity(0.18), in: Capsule())
            .foregroundStyle(cls.color)
    }
}

struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct RingGauge: View {
    let value: Double?
    let label: String
    var caption: String?
    var color: Color?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: CGFloat(min(100, max(0, value ?? 0)) / 100))
                    .stroke(color ?? usageColor(value), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 76, height: 76)
            Text(label).font(.subheadline.weight(.medium))
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.map { "\(Int($0)) percent" } ?? "unavailable")
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var provenance: Provenance?
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
            if let provenance { ProvenanceBadge(provenance: provenance) }
        }
        .font(.callout)
    }
}

struct SeriesPoint: Identifiable {
    let date: Date
    let value: Double
    var series: String = "value"
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}

struct TimeSeriesChart: View {
    let points: [SeriesPoint]
    var yDomain: ClosedRange<Double>?
    var color: Color = .accentColor
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var height: CGFloat = 160

    var body: some View {
        if points.count < 2 {
            ContentUnavailableView("Collecting data…", systemImage: "chart.xyaxis.line",
                                   description: Text("History appears after a few samples."))
                .frame(height: height)
        } else {
            Chart(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Value", p.value), stacking: .unstacked)
                    .foregroundStyle(by: .value("Series", p.series))
                    .opacity(0.18)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(range: palette)
            .chartLegend(Set(points.map(\.series)).count > 1 ? .visible : .hidden)
            .chartYScale(domain: yDomain ?? autoDomain)
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)) } } } }
            .chartPlotStyle { $0.clipped() }
            .frame(height: height)
            .accessibilityLabel("Time series chart")
        }
    }

    var palette: [Color] { [color] + [Color.orange, .teal, .pink, .purple, .blue].filter { $0 != color } }

    var autoDomain: ClosedRange<Double> {
        let vals = points.map(\.value)
        let lo = min(0, vals.min() ?? 0), hi = max(vals.max() ?? 1, lo + 1)
        return lo...(hi * 1.08)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.largeTitle.weight(.semibold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HistoryRangePicker: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Picker("Range", selection: $model.historyRange) {
            ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .help(model.store == nil ? "History database unavailable" : "Ranges beyond this session use the background monitor's history")
    }
}

struct ScrollPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(24)
                .frame(maxWidth: 1200, alignment: .leading)
        }
    }
}

struct RecommendationRow: View {
    let rec: Recommendation
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(rec.detail)
                Text("Expected effect: \(rec.expectedEffect)").foregroundStyle(.secondary)
                ForEach(rec.evidence, id: \.self) { e in
                    Label(e, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Tag("Confidence \(rec.confidence.rawValue)")
                    Tag("Benefit \(rec.benefit.rawValue)")
                    Tag("Risk \(rec.risk.rawValue)")
                    Tag("Effort \(rec.effort.rawValue)")
                    Tag(rec.reversible ? "Reversible" : "Not reversible")
                }
                if let hint = rec.actionHint {
                    Text("CLI: \(hint)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                SeverityDot(severity: rec.severity)
                Text(rec.title).fontWeight(.medium)
                Spacer()
                Text(rec.confidence.rawValue + " confidence").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
