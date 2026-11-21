import Foundation

public struct MonitorAlert: Codable, Sendable, Equatable {
    public var kind: String
    public var severity: Severity
    public var title: String
    public var detail: String
}

/// Explainable anomaly rules evaluated by the background monitor.
public enum MonitorRules {
    public static func evaluate(snapshot s: SystemSnapshot, history h: HistorySummary, findings: [ProcessFinding],
                                thresholds t: Thresholds) -> [MonitorAlert] {
        var alerts: [MonitorAlert] = []
        if let v = s.volume, v.freePercent < t.lowDiskFreePercent || v.available < t.lowDiskFreeBytes {
            alerts.append(MonitorAlert(kind: "low-disk", severity: v.freePercent < 5 ? .critical : .warning,
                                       title: "Low disk space",
                                       detail: "\(Format.bytes(v.available)) free (\(Format.percent(v.freePercent, digits: 1))). Run a cleanup dry run in MacPulse."))
        }
        if let m = s.memory, m.pressure >= .warning {
            alerts.append(MonitorAlert(kind: "memory-pressure", severity: m.pressure == .critical ? .critical : .warning,
                                       title: "Memory pressure \(m.pressure.rawValue)",
                                       detail: "Swap \(Format.memory(m.swapUsed)), compressed \(Format.memory(m.compressed))."))
        }
        if let g = h.swapGrowthPerHour, g >= t.swapGrowthBytesPerHour, (h.swapGrowthR2 ?? 0) >= 0.5 {
            let top = s.processes.filter { $0.category != .system }.sorted(by: ProcessSortKey.memory.comparator).first
            alerts.append(MonitorAlert(kind: "swap-growth", severity: .warning, title: "Swap is growing quickly",
                                       detail: "+\(Format.memory(Int64(g)))/h over the last hour (now \(Format.memory(s.memory?.swapUsed)))."
                                         + (top.map { " Largest app: \($0.name) (\(Format.memory($0.footprint)))." } ?? "")))
        }
        if h.sustainedHighCPU {
            alerts.append(MonitorAlert(kind: "sustained-cpu", severity: .warning, title: "Sustained high CPU",
                                       detail: "Average \(Format.percent(h.cpuAverage)) over \(Int(t.sustainedCPUMinutes)) minutes."))
        }
        if s.thermal.state >= .serious {
            alerts.append(MonitorAlert(kind: "thermal", severity: s.thermal.state == .critical ? .critical : .warning,
                                       title: "Thermal pressure \(s.thermal.state.rawValue)",
                                       detail: "macOS is reducing performance to manage temperature."))
        }
        let onBattery = s.power.source == "Battery Power"
        for f in findings where f.kind == .runawayCPU || f.kind == .memoryGrowth || f.kind == .wakeupStorm
            || (f.kind == .energyHog && onBattery) {
            alerts.append(MonitorAlert(kind: "process-\(f.kind.rawValue)-\(f.identities.first?.description ?? "")",
                                       severity: .warning, title: f.title, detail: f.evidence.first ?? ""))
        }
        return alerts
    }
}

/// Posts user notifications without requiring an app bundle: osascript with argv (no string interpolation).
public enum Notifier {
    public static func post(title: String, body: String, runner: CommandRunner = SystemCommandRunner()) {
        _ = runner.run("/usr/bin/osascript",
                       ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                        "-e", "end run", String(title.prefix(120)), String(body.prefix(240))], timeout: 5)
    }
}
