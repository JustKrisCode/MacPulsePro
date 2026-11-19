import MacPulseCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollPage {
            if let s = model.snapshot {
                HStack(alignment: .top) {
                    SectionHeader(title: "Overview",
                                  subtitle: "\(s.system.chip) · macOS \(s.system.osVersion) · \(Format.memory(s.system.physicalMemory)) · up \(Format.duration(s.system.uptimeSeconds))")
                    if let h = model.health { HealthBadge(report: h) }
                }
                HStack(spacing: 16) {
                    Card {
                        HStack(spacing: 28) {
                            RingGauge(value: s.cpu?.total, label: "CPU", caption: s.cpu.map { "load \(String(format: "%.1f", $0.loadAverage.first ?? 0))" })
                            RingGauge(value: s.memory.map { Double($0.used) / Double(max($0.physical, 1)) * 100 }, label: "Memory",
                                      caption: s.memory.map { "pressure \($0.pressure.rawValue)" }, color: s.memory?.pressure.color)
                            RingGauge(value: s.gpu.utilization.value, label: "GPU", caption: s.gpu.utilization.value == nil ? "unavailable" : "device")
                            RingGauge(value: s.volume.map { 100 - $0.freePercent }, label: "Disk", caption: s.volume.map { "\(Format.bytes($0.available)) free" })
                            VStack(spacing: 6) {
                                Image(systemName: "thermometer.medium").font(.system(size: 30)).foregroundStyle(s.thermal.state.color)
                                    .frame(width: 76, height: 76)
                                Text("Thermal").font(.subheadline.weight(.medium))
                                Text(s.thermal.state.title).font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "CPU — last 10 minutes", systemImage: "cpu") {
                        TimeSeriesChart(points: model.recentLive.compactMap { h in h.cpu.map { SeriesPoint(date: h.timestamp, value: $0) } },
                                        yDomain: 0...100, format: { "\(Int($0))%" }, height: 130)
                    }
                    Card(title: "Memory used — last 10 minutes", systemImage: "memorychip") {
                        TimeSeriesChart(points: model.recentLive.compactMap { h in h.memoryUsed.map { SeriesPoint(date: h.timestamp, value: Double($0) / 1_073_741_824) } },
                                        yDomain: 0...Double(s.system.physicalMemory) / 1_073_741_824, color: .purple,
                                        format: { "\(Int($0)) GB" }, height: 130)
                    }
                }
                Card(title: "Recommendations", systemImage: "lightbulb") {
                    if model.recommendations.isEmpty {
                        Label("No action needed — the system looks healthy.", systemImage: "checkmark.seal").foregroundStyle(.green)
                    } else {
                        ForEach(model.recommendations.prefix(5)) { RecommendationRow(rec: $0) }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Top CPU", systemImage: "flame") {
                        ProcessMiniList(processes: s.topProcesses(by: .cpu, limit: 6), metric: { Format.percent($0.cpuPercent, digits: 1) })
                    }
                    Card(title: "Top memory (by app)", systemImage: "square.stack.3d.up") {
                        ForEach(model.appGroups.prefix(6)) { g in
                            HStack { Text(g.name).lineLimit(1); Spacer(); Text(Format.memory(g.footprint)).monospacedDigit().foregroundStyle(.secondary) }
                                .font(.callout)
                        }
                    }
                }
                if s.power.hasBattery {
                    Card(title: "Battery", systemImage: "battery.75percent") {
                        HStack(spacing: 30) {
                            StatRow(label: "Charge", value: s.power.chargePercent.map { "\($0)%" } ?? "—")
                            StatRow(label: "Maximum capacity", value: Format.percent(s.power.healthPercent.value, digits: 1), provenance: s.power.healthPercent.provenance)
                            StatRow(label: "Cycles", value: s.power.cycleCount.map(String.init) ?? "—")
                            StatRow(label: "Source", value: s.power.source)
                        }
                    }
                }
            } else {
                ProgressView("Collecting first sample…").frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }
}

struct HealthBadge: View {
    let report: HealthReport
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(report.overall)")
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(report.status.color)
            Text("Health score").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProcessMiniList: View {
    let processes: [ProcessRecord]
    let metric: (ProcessRecord) -> String
    var body: some View {
        ForEach(processes) { p in
            HStack {
                Text(p.name).lineLimit(1)
                Text("\(p.pid)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text(metric(p)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

struct HealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollPage {
            HStack(alignment: .top) {
                SectionHeader(title: "System Health", subtitle: "Every point deducted is listed with its reason.")
                if let h = model.health { HealthBadge(report: h) }
            }
            if let h = model.health {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(h.dimensions) { d in
                        Card {
                            HStack {
                                Text(d.kind.title).font(.title3.weight(.semibold))
                                Spacer()
                                Text("\(d.score)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(d.status.color)
                            }
                            Text(d.summary).foregroundStyle(.secondary).font(.callout)
                            if d.deductions.isEmpty {
                                Label("No deductions", systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout)
                            }
                            ForEach(d.deductions, id: \.reason) { x in
                                HStack(alignment: .top) {
                                    Text("−\(x.points)").monospacedDigit().foregroundStyle(.orange).frame(width: 34, alignment: .leading)
                                    Text(x.reason)
                                }
                                .font(.callout)
                            }
                            Text("Weight \(String(format: "%.0f", d.weight))").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                Card(title: "Method", systemImage: "function") {
                    Text(h.method).font(.callout)
                    if !h.excluded.isEmpty {
                        Text("Not scored: " + h.excluded.joined(separator: "; ")).font(.callout).foregroundStyle(.secondary)
                    }
                    Text("This score summarizes documented signals (memory pressure, thermal state, free space…). It is not a hardware benchmark.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "All recommendations", systemImage: "lightbulb") {
                    if model.recommendations.isEmpty { Text("None.").foregroundStyle(.secondary) }
                    ForEach(model.recommendations) { RecommendationRow(rec: $0) }
                }
                if !model.findings.isEmpty {
                    Card(title: "Process findings", systemImage: "magnifyingglass") {
                        ForEach(model.findings) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { SeverityDot(severity: f.severity); Text(f.title).fontWeight(.medium); Spacer(); ProvenanceBadge(provenance: f.provenance) }
                                Text(f.evidence.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension HealthDimension.Kind {
    var title: String {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; default: rawValue.capitalized }
    }
}
