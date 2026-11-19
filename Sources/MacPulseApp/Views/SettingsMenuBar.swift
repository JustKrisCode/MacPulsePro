import AppKit
import MacPulseCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    static let menuMetrics = [("cpu", "CPU"), ("memory", "Memory"), ("gpu", "GPU"), ("swap", "Swap"), ("thermal", "Thermal"), ("disk", "Free disk")]

    var body: some View {
        @Bindable var model = model
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Notifications for alerts", isOn: Binding(get: { model.config.notificationsEnabled }, set: { model.setNotifications($0) }))
                Picker("Refresh while window is open", selection: $model.config.uiRefreshSeconds) {
                    ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Text("With only the menu bar visible, MacPulse refreshes at most every 5 s and reads the process table every sixth tick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                ForEach(Self.menuMetrics, id: \.0) { key, title in
                    Toggle(title, isOn: Binding(get: { model.config.menuBarMetrics.contains(key) }, set: { on in
                        if on { model.config.menuBarMetrics.append(key) } else { model.config.menuBarMetrics.removeAll { $0 == key } }
                    }))
                }
            }
            Section("Thresholds") {
                Stepper("Low disk below \(Int(model.config.thresholds.lowDiskFreePercent))%", value: $model.config.thresholds.lowDiskFreePercent, in: 2...40)
                Stepper("Sustained CPU at \(Int(model.config.thresholds.sustainedCPUPercent))%", value: $model.config.thresholds.sustainedCPUPercent, in: 50...100, step: 5)
                Stepper("…for \(Int(model.config.thresholds.sustainedCPUMinutes)) minutes", value: $model.config.thresholds.sustainedCPUMinutes, in: 2...60)
                Stepper("Runaway process at \(Int(model.config.thresholds.runawayProcessCPUPercent))% CPU", value: $model.config.thresholds.runawayProcessCPUPercent, in: 50...400, step: 10)
                Stepper("Alert cooldown \(Int(model.config.notificationCooldownMinutes)) min", value: $model.config.notificationCooldownMinutes, in: 5...720, step: 5)
            }
            Section("Data") {
                LabeledContent("Database", value: AppPaths.database)
                LabeledContent("Configuration", value: AppPaths.config)
                HStack {
                    Button("Export Report…") { ReportExporter.export(model: model) }
                    Button("Export History CSV…") { ReportExporter.exportHistory(model: model) }
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(AppPaths.database, inFileViewerRootedAtPath: "") }
                }
                Text("All data stays on this Mac. MacPulse makes no network connections.").font(.caption).foregroundStyle(.secondary)
            }
            Section { HStack { Spacer(); Button("Save") { model.saveConfig() }.keyboardShortcut("s", modifiers: .command) } }
        }
        .formStyle(.grouped)
        .onDisappear { model.saveConfig() }
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        let parts = model.config.menuBarMetrics.compactMap { key -> String? in
            switch key {
            case "cpu": return s?.cpu.map { "CPU \(Int($0.total))%" }
            case "memory": return s?.memory.map { "MEM \(Int(Double($0.used) / Double(max($0.physical, 1)) * 100))%" }
            case "gpu": return s?.gpu.utilization.value.map { "GPU \(Int($0))%" }
            case "swap": return s?.memory.map { "SWP \(Format.memory($0.swapUsed))" }
            case "thermal": return s.map { $0.thermal.state == .nominal ? nil : "🌡 \($0.thermal.state.title)" } ?? nil
            case "disk": return s?.volume.map { "\(Format.bytes($0.available)) free" }
            default: return nil
            }
        }
        if parts.isEmpty {
            Image(systemName: "waveform.path.ecg")
        } else {
            Text(parts.joined(separator: "  ")).monospacedDigit()
        }
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MacPulse Pro").font(.headline)
                Spacer()
                if let h = model.health {
                    Text("\(h.overall)").font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(h.status.color)
                }
            }
            if let s = model.snapshot {
                HStack(spacing: 14) {
                    MiniMeter(label: "CPU", value: s.cpu?.total)
                    MiniMeter(label: "Memory", value: s.memory.map { Double($0.used) / Double(max($0.physical, 1)) * 100 }, tint: s.memory?.pressure.color)
                    MiniMeter(label: "GPU", value: s.gpu.utilization.value)
                    MiniMeter(label: "Disk", value: s.volume.map { 100 - $0.freePercent })
                }
                HStack {
                    Label(s.thermal.state.title, systemImage: "thermometer.medium").foregroundStyle(s.thermal.state.color)
                    Spacer()
                    if let m = s.memory { Text("Swap \(Format.memory(m.swapUsed))").foregroundStyle(.secondary) }
                }
                .font(.callout)
                Divider()
                Text("Top CPU").font(.caption).foregroundStyle(.secondary)
                ProcessMiniList(processes: s.topProcesses(by: .cpu, limit: 4), metric: { Format.percent($0.cpuPercent, digits: 0) })
                if let r = model.recommendations.first(where: { $0.severity >= .warning }) {
                    Divider()
                    HStack(alignment: .top) { SeverityDot(severity: r.severity).padding(.top, 5); Text(r.title).font(.callout) }
                }
            } else {
                ProgressView()
            }
            Divider()
            HStack {
                Button("Open MacPulse") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Why slow?") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    model.diagnose()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct MiniMeter: View {
    let label: String
    let value: Double?
    var tint: Color?
    var body: some View {
        VStack(spacing: 4) {
            Gauge(value: min(100, max(0, value ?? 0)), in: 0...100) { EmptyView() } currentValueLabel: {
                Text(value.map { "\(Int($0))" } ?? "—").monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint ?? usageColor(value))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
