import Charts
import MacPulseCore
import SwiftUI

struct MemoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollPage {
            SectionHeader(title: "Memory", subtitle: "Memory pressure and swapping determine responsiveness — not the amount of free RAM.")
            if let s = model.snapshot, let m = s.memory {
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Pressure", systemImage: "gauge.with.dots.needle.50percent") {
                        Text(m.pressure.rawValue.capitalized).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(m.pressure.color)
                        ProvenanceBadge(provenance: .measured)
                        if let a = m.availablePercent { Text("Kernel reports \(a)% available").font(.callout).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: 240)
                    Card(title: "Composition", systemImage: "chart.bar.xaxis") {
                        Chart {
                            BarMark(x: .value("Bytes", Double(m.app) / 1_073_741_824)).foregroundStyle(by: .value("Type", "App"))
                            BarMark(x: .value("Bytes", Double(m.wired) / 1_073_741_824)).foregroundStyle(by: .value("Type", "Wired"))
                            BarMark(x: .value("Bytes", Double(m.compressed) / 1_073_741_824)).foregroundStyle(by: .value("Type", "Compressed"))
                            BarMark(x: .value("Bytes", Double(m.cachedFiles) / 1_073_741_824)).foregroundStyle(by: .value("Type", "Cached files"))
                        }
                        .chartXScale(domain: 0...Double(m.physical) / 1_073_741_824)
                        .chartXAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) GB") } } } }
                        .frame(height: 70)
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                            GridRow { StatRow(label: "Used", value: Format.memory(m.used)); StatRow(label: "Physical", value: Format.memory(m.physical)) }
                            GridRow { StatRow(label: "App", value: Format.memory(m.app)); StatRow(label: "Wired", value: Format.memory(m.wired)) }
                            GridRow { StatRow(label: "Compressed", value: Format.memory(m.compressed)); StatRow(label: "Cached files", value: Format.memory(m.cachedFiles)) }
                            GridRow { StatRow(label: "Active", value: Format.memory(m.active)); StatRow(label: "Inactive", value: Format.memory(m.inactive)) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Swap", systemImage: "arrow.left.arrow.right") {
                        StatRow(label: "Used", value: "\(Format.memory(m.swapUsed)) of \(Format.memory(m.swapTotal))", provenance: .measured)
                        StatRow(label: "Swap-outs since boot", value: "\(m.swapouts)")
                        StatRow(label: "Trend (1 h)", value: model.historySummary.swapGrowthPerHour.map { "\($0 >= 0 ? "+" : "")\(Format.memory(Int64($0)))/h" } ?? "needs ≥10 min of data",
                                provenance: model.historySummary.swapGrowthPerHour == nil ? nil : .estimated)
                        if let r = model.historySummary.swapoutsPerMinute { StatRow(label: "Page-out rate", value: "\(Int(r))/min") }
                    }
                    Card(title: "Pressure & swap history", systemImage: "chart.xyaxis.line") {
                        HistoryRangePicker()
                        TimeSeriesChart(points: model.chartSamples.compactMap { h in h.swapUsed.map { SeriesPoint(date: h.timestamp, value: Double($0) / 1_073_741_824, series: "Swap GB") } }
                                        + model.chartSamples.compactMap { h in h.compressed.map { SeriesPoint(date: h.timestamp, value: Double($0) / 1_073_741_824, series: "Compressed GB") } },
                                        color: .purple, format: { String(format: "%.1f", $0) }, height: 150)
                    }
                }
                Card(title: "Largest applications (helpers grouped)", systemImage: "square.stack.3d.up") {
                    Table(Array(model.appGroups.prefix(15))) {
                        TableColumn("Application / process") { Text($0.name) }
                        TableColumn("Memory") { Text(Format.memory($0.footprint)).monospacedDigit() }.width(100)
                        TableColumn("CPU") { Text(Format.percent($0.cpuPercent, digits: 1)).monospacedDigit() }.width(70)
                        TableColumn("Processes") { Text("\($0.pids.count)").monospacedDigit() }.width(80)
                        TableColumn("Category") { Text($0.category.rawValue).foregroundStyle(.secondary) }.width(120)
                    }
                    .frame(height: 360)
                }
                let memFindings = model.findings.filter { [.largeMemory, .memoryGrowth, .duplicateInstances, .probableOrphan].contains($0.kind) }
                if !memFindings.isEmpty {
                    Card(title: "Findings", systemImage: "magnifyingglass") {
                        ForEach(memFindings) { f in
                            HStack(alignment: .top) {
                                SeverityDot(severity: f.severity).padding(.top, 5)
                                VStack(alignment: .leading) {
                                    Text(f.title).fontWeight(.medium)
                                    Text(f.evidence.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                ProvenanceBadge(provenance: f.provenance)
                            }
                        }
                        Text("Memory-growth detection uses this session's samples (or the monitor's history) and needs ≥20 minutes of data.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct CPUView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollPage {
            SectionHeader(title: "CPU", subtitle: "Per-core utilization with performance (P) and efficiency (E) clusters.")
            if let s = model.snapshot, let c = s.cpu {
                HStack(spacing: 16) {
                    Card {
                        HStack(spacing: 28) {
                            RingGauge(value: c.total, label: "Total")
                            RingGauge(value: c.performanceAverage, label: "P-cores", caption: s.system.performanceCores.map { "\($0) cores" })
                            RingGauge(value: c.efficiencyAverage, label: "E-cores", caption: s.system.efficiencyCores.map { "\($0) cores" })
                            VStack(alignment: .leading, spacing: 6) {
                                StatRow(label: "User", value: Format.percent(c.user, digits: 1))
                                StatRow(label: "System", value: Format.percent(c.system, digits: 1))
                                StatRow(label: "Load 1 / 5 / 15", value: c.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / "))
                                StatRow(label: "Sustained high load", value: model.historySummary.sustainedHighCPU ? "Yes" : "No")
                            }
                            .frame(maxWidth: 300)
                        }
                    }
                }
                Card(title: "Cores", systemImage: "square.grid.3x3") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(c.cores, id: \.index) { core in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Core \(core.index)").font(.caption.weight(.medium))
                                    if let cl = core.cluster { Text(cl).font(.caption2.weight(.bold)).foregroundStyle(cl == "P" ? .orange : .teal) }
                                    Spacer()
                                    Text(Format.percent(core.total)).font(.caption.monospacedDigit())
                                }
                                Sparkline(values: model.coreHistory[safe: core.index] ?? [], color: core.cluster == "P" ? .orange : .teal)
                                    .frame(height: 28)
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                Card(title: "History", systemImage: "chart.xyaxis.line") {
                    HistoryRangePicker()
                    TimeSeriesChart(points: model.chartSamples.compactMap { h in h.cpu.map { SeriesPoint(date: h.timestamp, value: $0, series: "CPU %") } },
                                    yDomain: 0...100, format: { "\(Int($0))%" })
                }
                Card(title: "Busiest processes", systemImage: "flame") {
                    Table(s.topProcesses(by: .cpu, limit: 15)) {
                        TableColumn("Process") { p in Text(p.name) }
                        TableColumn("PID") { p in Text("\(p.pid)").monospacedDigit() }.width(60)
                        TableColumn("CPU") { p in Text(Format.percent(p.cpuPercent, digits: 1)).monospacedDigit() }.width(70)
                        TableColumn("CPU time") { p in Text(Format.duration(p.cpuTimeSeconds)).monospacedDigit() }.width(90)
                        TableColumn("Threads") { p in Text(p.threads.map(String.init) ?? "—").monospacedDigit() }.width(70)
                        TableColumn("Runtime") { p in Text(Format.duration(p.runtime)).monospacedDigit() }.width(90)
                        TableColumn("Kind") { p in Text(p.isForegroundApp ? "foreground" : p.category.rawValue).foregroundStyle(.secondary) }.width(120)
                    }
                    .frame(height: 380)
                    Text("CPU % is per core: 100% means one fully busy core, matching Activity Monitor.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Cheap sparkline drawn with a single Path in a Canvas (no Swift Charts layout per cell).
struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    var maxValue: Double = 100

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(v, 0), maxValue) / maxValue)) }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(values[0])))
            for (i, v) in values.enumerated().dropFirst() { line.addLine(to: CGPoint(x: CGFloat(i) * step, y: y(v))) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.25)))
            ctx.stroke(line, with: .color(color), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

struct GPUView: View {
    @Environment(AppModel.self) private var model
    static let browserMarkers = ["Chrome", "Chromium", "Safari", "WebKit", "Firefox", "Edge", "Brave", "Arc", "Opera", "Electron", "Helper (GPU)"]

    var body: some View {
        ScrollPage {
            SectionHeader(title: "GPU", subtitle: "Apple Silicon GPU activity from IORegistry driver statistics.")
            if let s = model.snapshot {
                let g = s.gpu
                HStack(alignment: .top, spacing: 16) {
                    Card {
                        HStack(spacing: 28) {
                            RingGauge(value: g.devices.first?.deviceUtilization, label: "Device")
                            RingGauge(value: g.devices.first?.rendererUtilization, label: "Renderer")
                            RingGauge(value: g.devices.first?.tilerUtilization, label: "Tiler")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(g.devices.first?.name ?? "No GPU statistics").font(.headline)
                                if let n = g.devices.first?.coreCount { StatRow(label: "GPU cores", value: "\(n)") }
                                StatRow(label: "Driver GPU memory in use", value: Format.memory(g.devices.first?.inUseSystemMemory), provenance: .measuredUndocumented)
                                HStack { Text("Source").foregroundStyle(.secondary); Spacer(); ProvenanceBadge(provenance: g.utilization.provenance) }.font(.callout)
                            }
                            .frame(maxWidth: 320)
                        }
                    }
                }
                Card(title: "Correlation: GPU, CPU and thermal", systemImage: "chart.xyaxis.line") {
                    HistoryRangePicker()
                    TimeSeriesChart(points: model.chartSamples.compactMap { h in h.gpu.map { SeriesPoint(date: h.timestamp, value: $0, series: "GPU %") } }
                                    + model.chartSamples.compactMap { h in h.cpu.map { SeriesPoint(date: h.timestamp, value: $0, series: "CPU %") } }
                                    + model.chartSamples.compactMap { h in h.thermal.map { SeriesPoint(date: h.timestamp, value: Double($0) * 33.3, series: "Thermal (0–3 scaled)") } },
                                    yDomain: 0...100, color: .pink, format: { "\(Int($0))" }, height: 190)
                }
                Card(title: "GPU time by process", systemImage: "list.number") {
                    let rows = g.processes.filter { ($0.recentPercent ?? 0) > 0.05 || $0.accumulatedSeconds > 5 }.prefix(20).map { $0 }
                    Table(rows, columns: {
                        TableColumn("Process") { (p: GPUProcessUsage) in
                            HStack {
                                Text(p.name)
                                if Self.browserMarkers.contains(where: p.name.contains) { Tag("browser/web") }
                            }
                        }
                        TableColumn("PID") { (p: GPUProcessUsage) in Text("\(p.pid)").monospacedDigit() }.width(60)
                        TableColumn("GPU share") { (p: GPUProcessUsage) in Text(Format.percent(p.recentPercent, digits: 1)).monospacedDigit() }.width(90)
                        TableColumn("Trend") { (p: GPUProcessUsage) in Sparkline(values: model.gpuProcessHistory[p.pid] ?? [], color: .pink).frame(height: 18) }.width(120)
                        TableColumn("Total GPU time") { (p: GPUProcessUsage) in Text(Format.duration(p.accumulatedSeconds)).monospacedDigit() }.width(110)
                        TableColumn("API") { (p: GPUProcessUsage) in Text(p.apis.joined(separator: ", ")).foregroundStyle(.secondary) }.width(70)
                    })
                    .frame(height: 320)
                    Text("Share = GPU busy time attributed to the process ÷ wall time during the last interval. Browsers render WebGL, WebGPU, video and compositing in their GPU helper process, so web workloads appear there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "Limits", systemImage: "info.circle") {
                    ForEach(g.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    Text("MetricKit only reports this app's own diagnostics, so it is not used for system-wide GPU data.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ThermalView: View {
    @Environment(AppModel.self) private var model
    @State private var pmset: ThermalSnapshot?

    var body: some View {
        ScrollPage {
            SectionHeader(title: "Thermal", subtitle: "macOS thermal pressure — the authoritative public signal for heat-related throttling.")
            if let s = model.snapshot {
                let th = pmset ?? s.thermal
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Thermal pressure", systemImage: "thermometer.medium") {
                        Text(th.state.title).font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(th.state.color)
                        ProvenanceBadge(provenance: .measured)
                        HStack(spacing: 6) {
                            ForEach(ThermalState.allCases, id: \.self) { st in
                                Capsule().fill(st <= th.state ? st.color : Color.gray.opacity(0.2)).frame(height: 6)
                            }
                        }
                    }
                    Card(title: "Indicators", systemImage: "list.bullet") {
                        StatRow(label: "Throttling likely", value: th.throttlingIndicator.likely ? "Yes" : "No", provenance: .inferred)
                        StatRow(label: "CPU speed limit", value: th.cpuSpeedLimit.value.map { "\($0)%" } ?? "—", provenance: th.cpuSpeedLimit.provenance)
                        StatRow(label: "CPU/GPU temperature", value: "—", provenance: .unavailable)
                        StatRow(label: "Battery temperature", value: th.batteryTemperatureC.value.map { String(format: "%.1f °C", $0) } ?? "—", provenance: th.batteryTemperatureC.provenance)
                        StatRow(label: "Low Power Mode", value: th.lowPowerMode ? "On" : "Off")
                        StatRow(label: "Power source", value: s.power.source)
                        Button("Check pmset speed limit") {
                            Task.detached { let t = ThermalCollector.snapshot(includePmset: true); await MainActor.run { pmset = t } }
                        }
                        .help("Runs `pmset -g therm` once (not polled)")
                    }
                }
                Card(title: "Thermal state vs. CPU and GPU load", systemImage: "chart.xyaxis.line") {
                    HistoryRangePicker()
                    TimeSeriesChart(points: model.chartSamples.compactMap { h in h.thermal.map { SeriesPoint(date: h.timestamp, value: Double($0) * 33.3, series: "Thermal (0–3 scaled)") } }
                                    + model.chartSamples.compactMap { h in h.cpu.map { SeriesPoint(date: h.timestamp, value: $0, series: "CPU %") } }
                                    + model.chartSamples.compactMap { h in h.gpu.map { SeriesPoint(date: h.timestamp, value: $0, series: "GPU %") } },
                                    yDomain: 0...100, color: .orange, format: { "\(Int($0))" }, height: 190)
                    StatRow(label: "Time at serious or worse (loaded history)", value: "\(Int(model.historySummary.thermalElevatedMinutes)) min")
                }
                Card(title: "Guidance", systemImage: "lightbulb") {
                    Text("Fanless Macs dissipate heat passively: sustained workloads reach “fair” and “serious” sooner, and macOS lowers clock speeds to stay within safe limits. That is expected protective behavior, not a fault.")
                    Text("To keep performance up: avoid overlapping heavy jobs (builds, exports, renders, many browser tabs with WebGL), keep the underside unobstructed, and work on a hard surface. MacPulse never alters thermal management.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
