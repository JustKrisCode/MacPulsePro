import Charts
import MacPulseCore
import SwiftUI

extension SlowdownDiagnosis: Identifiable {
    public var id: Date { timestamp }
}

struct DiagnosisSheet: View {
    let diagnosis: SlowdownDiagnosis
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: diagnosis.isClear ? "checkmark.seal.fill" : diagnosis.bottleneck == .none ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(diagnosis.isClear ? .green : diagnosis.bottleneck == .none ? .yellow : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Why is my Mac slow?").font(.title2.weight(.semibold))
                    Text(diagnosis.verdict).font(.title3)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card(title: "Resource pressure", systemImage: "gauge.with.dots.needle.67percent") {
                        ForEach(["memory", "cpu", "thermal", "storage", "gpu"], id: \.self) { key in
                            if let v = diagnosis.pressure[key] {
                                HStack {
                                    Text(key == "cpu" || key == "gpu" ? key.uppercased() : key.capitalized).frame(width: 80, alignment: .leading)
                                    ProgressView(value: Double(v), total: 100).tint(v >= 85 ? .red : v >= 60 ? .orange : .accentColor)
                                    Text("\(v)").monospacedDigit().frame(width: 32, alignment: .trailing)
                                }
                                .font(.callout)
                            }
                        }
                        HStack { Spacer(); ProvenanceBadge(provenance: .inferred) }
                    }
                    Card(title: "Compared with this Mac's baseline", systemImage: "arrow.left.arrow.right") {
                        Text(diagnosis.baselineDescription).font(.caption).foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                            ForEach(diagnosis.changes) { c in
                                GridRow {
                                    Text(c.metric).foregroundStyle(.secondary)
                                    Text(c.baseline).monospacedDigit()
                                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                    Text(c.now).monospacedDigit().fontWeight(c.worse ? .semibold : .regular).foregroundStyle(c.worse ? .orange : .primary)
                                }
                            }
                        }
                        .font(.callout)
                    }
                    Card(title: "Likely causes", systemImage: "list.number") {
                        if diagnosis.causes.isEmpty { Label("Nothing stands out.", systemImage: "checkmark").foregroundStyle(.green) }
                        ForEach(Array(diagnosis.causes.enumerated()), id: \.element.id) { i, c in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(i + 1).").foregroundStyle(.secondary)
                                    Text(c.title).fontWeight(.medium)
                                    Spacer()
                                    Tag("impact \(c.impact.rawValue)")
                                    Tag("confidence \(c.confidence.rawValue)")
                                }
                                ForEach(c.evidence, id: \.self) { Text("· " + $0).font(.caption).foregroundStyle(.secondary) }
                                Text("→ " + c.suggestion).font(.callout)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            HStack {
                Text("Diagnosed \(diagnosis.timestamp.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720, height: 680)
    }
}

struct EnergyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollPage {
            SectionHeader(title: "Energy", subtitle: "Power per app from the kernel's energy accounting, and the wakeups that keep the CPU busy.")
            if let s = model.snapshot {
                let groups = model.appGroups.filter { ($0.powerWatts ?? 0) > 0 }.sorted { ($0.powerWatts ?? 0) > ($1.powerWatts ?? 0) }
                let total = groups.compactMap(\.powerWatts).reduce(0, +)
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Now", systemImage: "bolt") {
                        Text(String(format: "%.2f W", total)).font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        Text("accounted to your processes").font(.caption).foregroundStyle(.secondary)
                        ProvenanceBadge(provenance: .measuredUndocumented)
                        if let w = s.power.batteryPowerW.value, w < -0.1 {
                            StatRow(label: "Battery discharge (whole system)", value: String(format: "%.1f W", -w), provenance: .estimated)
                        } else {
                            StatRow(label: "Power source", value: s.power.source)
                        }
                    }
                    .frame(maxWidth: 300)
                    Card(title: "Last 10 minutes", systemImage: "chart.xyaxis.line") {
                        TimeSeriesChart(points: model.energyHistory.map { SeriesPoint(date: $0.date, value: $0.value, series: "Watts") },
                                        color: .yellow, format: { String(format: "%.1f W", $0) }, height: 140)
                    }
                }
                Card(title: "By app", systemImage: "square.stack.3d.up") {
                    Table(Array(groups.prefix(20))) {
                        TableColumn("App / process") { (g: AppGroup) in Text(g.name) }
                        TableColumn("Power") { (g: AppGroup) in Text(String(format: "%.2f W", g.powerWatts ?? 0)).monospacedDigit() }.width(80)
                        TableColumn("Share") { (g: AppGroup) in
                            let share = total > 0 ? (g.powerWatts ?? 0) / total : 0
                            HStack { ProgressView(value: share).frame(width: 80); Text(Format.percent(share * 100)).monospacedDigit() }
                        }.width(140)
                        TableColumn("CPU") { (g: AppGroup) in Text(Format.percent(g.cpuPercent, digits: 1)).monospacedDigit() }.width(70)
                        TableColumn("Wakeups/s") { (g: AppGroup) in Text("\(Int(g.wakeupsPerSecond))").monospacedDigit() }.width(90)
                    }
                    .frame(height: 380)
                }
                Card(title: "Most frequent wakeups", systemImage: "alarm") {
                    ProcessMiniList(processes: s.topProcesses(by: .wakeups, limit: 6), metric: { "\(Int($0.wakeupsPerSecond ?? 0))/s" })
                    Text("Every wakeup pulls a core out of its low-power state. Idle apps with thousands of wakeups per second waste battery even at low CPU %.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "About these numbers", systemImage: "info.circle") {
                    Text("Energy comes from the kernel's per-process accounting (rusage ri_energy_nj), sampled every refresh. It mainly covers CPU-side energy; display, GPU and other devices are not fully attributed, so the total is lower than the battery's discharge rate. Processes of other users are not readable without administrator rights.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct GrowthPane: View {
    @Environment(AppModel.self) private var model
    @State private var includePersonal = false
    @State private var baselineIndex = 1

    var body: some View {
        ScrollPage {
            HStack {
                SectionHeader(title: "Disk Growth", subtitle: "What grew between two measurements — including swap files that silently eat free space.")
                Toggle("Include personal folders", isOn: $includePersonal).toggleStyle(.checkbox)
                    .help("Documents, Desktop, Downloads, media — macOS may ask for permission")
                if model.growthScanning {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").foregroundStyle(.secondary)
                } else {
                    Button("Measure Now") { model.runGrowthScan(includePersonal: includePersonal) }.buttonStyle(.borderedProminent)
                }
            }
            let scans = model.growthScans
            if scans.count >= 2 {
                Picker("Compare latest with", selection: $baselineIndex) {
                    ForEach(1..<scans.count, id: \.self) { i in Text(scans[i].timestamp.formatted(date: .abbreviated, time: .shortened)).tag(i) }
                }
                .frame(maxWidth: 360)
                let report = GrowthTracker.compare(scans[min(baselineIndex, scans.count - 1)], scans[0])
                if let m = scans[0].measuredCount {
                    Text("Latest measurement: \(String(format: "%.1f", scans[0].durationSeconds)) s, \(m) folder(s) walked" +
                         (scans[0].incremental ? ", \(scans[0].reusedCount ?? 0) unchanged reused via the FSEvents journal" : " (full scan)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    GrowthStat(label: "Startup volume", value: report.volumeUsedDelta)
                    GrowthStat(label: "Swap files", value: report.swapDelta)
                    GrowthStat(label: "Tracked folders", value: report.trackedDelta)
                    GrowthStat(label: "System & other", value: report.unattributedDelta)
                }
                Card(title: "Biggest changes", systemImage: "arrow.up.arrow.down") {
                    Table(Array(report.entries.prefix(40))) {
                        TableColumn("Change") { (e: GrowthEntry) in
                            Text((e.delta > 0 ? "+" : "") + Format.bytes(e.delta)).monospacedDigit().foregroundStyle(e.delta > 0 ? .orange : .green)
                        }.width(100)
                        TableColumn("Before") { (e: GrowthEntry) in Text(Format.bytes(e.before)).monospacedDigit() }.width(90)
                        TableColumn("After") { (e: GrowthEntry) in Text(Format.bytes(e.after)).monospacedDigit() }.width(90)
                        TableColumn("Folder") { (e: GrowthEntry) in Text(e.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle) }
                    }
                    .frame(minHeight: 380)
                }
            } else {
                ContentUnavailableView(scans.isEmpty ? "No measurements yet" : "One measurement recorded",
                                       systemImage: "chart.bar.doc.horizontal",
                                       description: Text(scans.isEmpty
                                            ? "Measure now to record a baseline. Measure again later (or enable the background monitor, which measures daily) to see what grew."
                                            : "Measure again later to see what changed since \(scans[0].timestamp.formatted(date: .abbreviated, time: .shortened))."))
                    .frame(minHeight: 260)
            }
            Text("Read-only. Sizes are allocated bytes. The first measurement reads most of your home folder and can take a few minutes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.loadGrowthScans() }
    }
}

struct GrowthStat: View {
    let label: String
    let value: Int64?
    var body: some View {
        Card {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { ($0 > 0 ? "+" : "") + Format.bytes($0) } ?? "—")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle((value ?? 0) > 0 ? .orange : .green)
        }
    }
}
