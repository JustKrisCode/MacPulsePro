import Foundation

/// The background monitor loop. Designed for minimal overhead:
/// - one cheap sample per interval (no subprocesses on the hot path),
/// - process table recorded only every N samples (top consumers only),
/// - one batched SQLite write per sample, retention enforced every 6 hours,
/// - interval doubled on battery power when configured.
public actor MonitorAgent {
    public struct Stats: Sendable {
        public var samples = 0
        public var alertsRaised = 0
        public var lastSampleDuration: TimeInterval = 0
    }

    private let store: HistoryStore
    private var config: MacPulseConfig
    private let sampler = SystemSampler()
    private var recent: [HistorySample] = []
    private var processHistory: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
    private var lastPrune = Date.distantPast
    private var lastAlert: [String: Date] = [:]
    public private(set) var stats = Stats()
    private let notify: @Sendable (MonitorAlert) -> Void

    public init(store: HistoryStore, config: MacPulseConfig,
                notify: @escaping @Sendable (MonitorAlert) -> Void = { Notifier.post(title: "MacPulse: " + $0.title, body: $0.detail) }) {
        self.store = store
        self.config = config
        self.notify = notify
        if let since = try? store.samples(since: Date().addingTimeInterval(-3600)) { recent = since }
    }

    public func updateConfig(_ c: MacPulseConfig) { config = c }

    public func currentInterval(onBattery: Bool) -> TimeInterval {
        let base = max(10, config.sampleIntervalSeconds)
        return onBattery && config.reduceSamplingOnBattery ? base * 2 : base
    }

    /// One monitoring cycle. Returns the alerts that passed the cooldown.
    @discardableResult
    public func tick() async -> [MonitorAlert] {
        let start = Date()
        let withProcesses = stats.samples % max(1, config.processSampleEvery) == 0
        let snap = await sampler.snapshot(includeProcesses: withProcesses)
        let sample = HistorySample(snap)
        try? store.record(sample)
        recent.append(sample)
        recent.removeAll { start.timeIntervalSince($0.timestamp) > 3600 }

        if withProcesses && !snap.processes.isEmpty {
            try? store.recordProcesses(snap.processes, at: snap.timestamp)
            for p in snap.processes where (p.cpuPercent ?? 0) > 5 || (p.footprint ?? 0) > 200_000_000 {
                processHistory[p.identity, default: []].append(ProcessHistoryPoint(timestamp: snap.timestamp, cpu: p.cpuPercent, footprint: p.footprint))
            }
            let live = Set(snap.processes.map(\.identity))
            processHistory = processHistory.filter { live.contains($0.key) }
                .mapValues { pts in pts.filter { start.timeIntervalSince($0.timestamp) <= 7200 } }
        }

        var alerts: [MonitorAlert] = []
        let summary = HistorySummary.compute(recent, cpuThreshold: config.thresholds.sustainedCPUPercent,
                                             cpuWindow: config.thresholds.sustainedCPUMinutes * 60)
        var findings: [ProcessFinding] = []
        if withProcesses {
            var ctx = ProcessAnalyzer.Context(records: snap.processes, physicalMemory: snap.system.physicalMemory)
            ctx.history = processHistory
            ctx.thresholds = config.thresholds
            findings = ProcessAnalyzer.findings(ctx)
        }
        for alert in MonitorRules.evaluate(snapshot: snap, history: summary, findings: findings, thresholds: config.thresholds) {
            let cooldown = config.notificationCooldownMinutes * 60
            if let last = lastAlert[alert.kind] ?? (try? store.lastEvent(kind: alert.kind)) ?? nil,
               start.timeIntervalSince(last) < cooldown { continue }
            lastAlert[alert.kind] = start
            _ = try? store.recordEvent(kind: alert.kind, severity: alert.severity, title: alert.title, detail: alert.detail)
            if config.notificationsEnabled { notify(alert) }
            alerts.append(alert)
        }
        if start.timeIntervalSince(lastPrune) > 6 * 3600 {
            _ = try? store.prune(retentionDays: config.retentionDays, maxSamples: config.maxSampleRows)
            lastPrune = start
        }
        stats.samples += 1
        stats.alertsRaised += alerts.count
        stats.lastSampleDuration = Date().timeIntervalSince(start)
        return alerts
    }

    /// Runs until the task is cancelled.
    public func run() async {
        while !Task.isCancelled {
            await tick()
            let onBattery = PowerCollector.snapshot().source == "Battery Power"
            try? await Task.sleep(nanoseconds: UInt64(currentInterval(onBattery: onBattery) * 1e9))
        }
    }
}
