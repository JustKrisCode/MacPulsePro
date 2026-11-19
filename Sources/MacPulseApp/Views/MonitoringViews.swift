import MacPulseCore
import SwiftUI

struct MonitoringView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollPage {
            SectionHeader(title: "Monitoring", subtitle: "Optional background service that records history and raises explainable alerts.")
            Card(title: "Background monitor", systemImage: "waveform.path.ecg") {
                let s = model.agentStatus
                HStack {
                    Circle().fill(s?.loaded == true ? Color.green : Color.gray).frame(width: 10, height: 10)
                    Text(s?.loaded == true ? "Running\(s?.pid.map { " (pid \($0))" } ?? "")" : s?.installed == true ? "Installed, not running" : "Off")
                        .fontWeight(.medium)
                    Spacer()
                    if s?.installed == true {
                        Button("Disable & Uninstall") { model.uninstallAgent() }
                    } else {
                        Button("Enable…") { model.installAgent() }.buttonStyle(.borderedProminent)
                    }
                    Button { model.refreshAgentStatus() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
                Text("Runs as a per-user LaunchAgent (no administrator rights) with background priority and low-priority I/O. It takes one light sample per interval, records the top processes every \(model.config.processSampleEvery) samples, and writes to a local SQLite database only.")
                    .font(.callout).foregroundStyle(.secondary)
                Grid(alignment: .leading, verticalSpacing: 8) {
                    GridRow {
                        Text("Sampling interval")
                        Picker("", selection: $model.config.sampleIntervalSeconds) {
                            ForEach([15.0, 30, 60, 120, 300], id: \.self) { Text("\(Int($0)) s").tag($0) }
                        }.labelsHidden().frame(width: 120)
                    }
                    GridRow { Text("Halve sampling on battery"); Toggle("", isOn: $model.config.reduceSamplingOnBattery).labelsHidden() }
                    GridRow {
                        Text("Keep history for")
                        Stepper("\(model.config.retentionDays) days", value: $model.config.retentionDays, in: 1...90)
                    }
                    GridRow {
                        Text("Notifications")
                        Toggle("", isOn: Binding(get: { model.config.notificationsEnabled }, set: { model.setNotifications($0) })).labelsHidden()
                    }
                }
                HStack {
                    Button("Save Settings") { model.saveConfig() }
                    Text("A running monitor picks up new settings when restarted (disable, then enable).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Card(title: "History", systemImage: "chart.xyaxis.line") {
                HistoryRangePicker()
                let samples = model.chartSamples
                if samples.isEmpty {
                    Text("No samples yet for this range.").foregroundStyle(.secondary)
                } else {
                    TimeSeriesChart(points: samples.compactMap { h in h.cpu.map { SeriesPoint(date: h.timestamp, value: $0, series: "CPU %") } }
                                    + samples.compactMap { h in h.gpu.map { SeriesPoint(date: h.timestamp, value: $0, series: "GPU %") } },
                                    yDomain: 0...100, format: { "\(Int($0))%" }, height: 150)
                    TimeSeriesChart(points: samples.compactMap { h in h.diskFree.map { SeriesPoint(date: h.timestamp, value: Double($0) / 1e9, series: "Free disk GB") } },
                                    color: .teal, format: { "\(Int($0)) GB" }, height: 110)
                }
                if let store = model.store {
                    HStack {
                        let c = try? store.counts()
                        Text("\(c?.samples ?? 0) samples · \(c?.events ?? 0) alerts · \(Format.bytes(store.fileSize)) on disk").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply Retention Now") { model.pruneHistory() }
                        Button("Reload") { model.loadStoredHistory() }
                    }
                }
            }
            Card(title: "Alerts (last 7 days)", systemImage: "bell") {
                if model.events.isEmpty {
                    Text("No alerts recorded.").foregroundStyle(.secondary)
                }
                ForEach(model.events.prefix(50)) { e in
                    HStack(alignment: .top) {
                        SeverityDot(severity: e.severity).padding(.top, 5)
                        VStack(alignment: .leading) {
                            Text(e.title).fontWeight(.medium)
                            Text(e.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(e.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Card(title: "Alert rules", systemImage: "list.bullet.rectangle") {
                let t = model.config.thresholds
                Text("• Low disk: < \(Int(t.lowDiskFreePercent))% or < \(Format.bytes(t.lowDiskFreeBytes)) free\n• Memory pressure: kernel level warning or critical\n• Swap growth: > \(Format.memory(Int64(t.swapGrowthBytesPerHour)))/h with a consistent trend (R² ≥ 0.5)\n• Sustained CPU: ≥ \(Int(t.sustainedCPUPercent))% for \(Int(t.sustainedCPUMinutes)) min\n• Thermal: state serious or critical\n• Process: ≥ \(Int(t.runawayProcessCPUPercent))% CPU for \(Int(t.runawayProcessMinutes)) min in background, or steady memory growth\nEach alert kind is rate-limited to once per \(Int(model.config.notificationCooldownMinutes)) min.")
                    .font(.callout)
            }
        }
    }
}

struct CleanupHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                SectionHeader(title: "Cleanup History", subtitle: "Audit log of every cleanup: estimated before, measured after.")
                Button("Reload") { model.reloadCleanupHistory() }
            }
            .padding([.horizontal, .top], 24)
            let entries = model.cleanupHistory
            HStack(spacing: 28) {
                StatRow(label: "Runs", value: "\(Set(entries.map(\.runID)).count)")
                StatRow(label: "Deleted (measured)", value: Format.bytes(entries.map(\.removedBytes).reduce(0, +)), provenance: .measured)
                StatRow(label: "Moved to Trash", value: Format.bytes(entries.filter { $0.status == "trashed" }.map(\.estimatedBytes).reduce(0, +)))
            }
            .padding(.horizontal, 24)
            if entries.isEmpty {
                ContentUnavailableView("No cleanups yet", systemImage: "clock.arrow.circlepath")
            } else {
                Table(entries) {
                    TableColumn("Date") { Text($0.timestamp.formatted(date: .abbreviated, time: .shortened)) }.width(140)
                    TableColumn("Status") { e in Text(e.status).foregroundStyle(e.status == "deleted" || e.status == "trashed" ? .green : .orange) }.width(110)
                    TableColumn("Method") { Text($0.method) }.width(60)
                    TableColumn("Path") { e in Text(e.path).lineLimit(1).truncationMode(.middle).help(e.detail + (e.trashPath.map { "\nIn Trash: \($0)" } ?? "")) }
                    TableColumn("Estimated") { Text(Format.bytes($0.estimatedBytes)).monospacedDigit() }.width(90)
                    TableColumn("Removed") { e in Text(e.status == "trashed" ? "in Trash" : Format.bytes(e.removedBytes)).monospacedDigit() }.width(90)
                    TableColumn("Run") { Text($0.runID).font(.caption.monospaced()).foregroundStyle(.secondary) }.width(80)
                }
            }
        }
    }
}
