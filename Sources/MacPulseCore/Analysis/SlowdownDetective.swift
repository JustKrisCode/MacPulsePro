import Foundation

/// "Why is my Mac slow right now?" — identifies the current bottleneck, compares the present with the
/// machine's own recent baseline and names concrete, evidence-backed causes.
public struct SlowdownDiagnosis: Codable, Sendable {
    public enum Bottleneck: String, Codable, Sendable { case memory, cpu, thermal, storage, gpu, none }

    public var timestamp: Date
    public var bottleneck: Bottleneck
    public var verdict: String
    /// Pressure per resource, 0–100 (higher = more contended). Inferred from measured signals.
    public var pressure: [String: Int]
    public var baselineDescription: String
    public var changes: [MetricChange]
    public var causes: [SlowdownCause]

    /// True when there is no bottleneck and no high-impact cause — the UI shows an all-clear only then.
    public var isClear: Bool { bottleneck == .none && !causes.contains { $0.impact == .high } }
}

public struct MetricChange: Codable, Sendable, Identifiable {
    public var metric: String
    public var now: String
    public var baseline: String
    public var worse: Bool
    public var id: String { metric }
}

public struct SlowdownCause: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case cpuHog, memoryHog, newHeavyProcess, memoryGrowth, swapping, thermal, gpuHog, energyHog, wakeupStorm, lowDisk, runaway
    }
    public var kind: Kind
    public var title: String
    public var evidence: [String]
    public var impact: Level
    public var confidence: Level
    public var relatedPIDs: [Int32]
    public var suggestion: String
    public var id: String { kind.rawValue + relatedPIDs.map(String.init).joined(separator: ",") + title }
}

public enum SlowdownDetective {
    public struct Input: Sendable {
        public var snapshot: SystemSnapshot
        /// Persisted or session history, any order.
        public var history: [HistorySample]
        /// Per-process history (for growth since baseline).
        public var processHistory: [ProcessIdentity: [ProcessHistoryPoint]]
        public var findings: [ProcessFinding]
        public var thresholds: Thresholds

        public init(snapshot: SystemSnapshot, history: [HistorySample] = [], processHistory: [ProcessIdentity: [ProcessHistoryPoint]] = [:],
                    findings: [ProcessFinding] = [], thresholds: Thresholds = Thresholds()) {
            self.snapshot = snapshot; self.history = history; self.processHistory = processHistory
            self.findings = findings; self.thresholds = thresholds
        }
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public static func diagnose(_ input: Input) -> SlowdownDiagnosis {
        let s = input.snapshot
        let now = s.timestamp
        let hist = input.history.sorted { $0.timestamp < $1.timestamp }
        let summary = HistorySummary.compute(hist + [HistorySample(s)], cpuThreshold: input.thresholds.sustainedCPUPercent,
                                             cpuWindow: input.thresholds.sustainedCPUMinutes * 60)

        // Swapping is judged by volume (MB/min written to swap), not by page count: pages are 16 KB on Apple Silicon.
        let pageBytes = Double(s.memory?.pageSize ?? 16384)
        let swapMBPerMin = (summary.swapoutsPerMinute ?? 0) * pageBytes / 1_048_576

        // MARK: resource pressure (0–100)
        var pressure: [String: Int] = [:]
        if let m = s.memory {
            var p = m.pressure == .critical ? 95 : m.pressure == .warning ? 70 : 0
            p = max(p, min(90, Int(swapMBPerMin * 0.9)))
            p = max(p, Int(Double(m.compressed) / Double(max(m.physical, 1)) * 100))
            pressure["memory"] = min(100, p)
        }
        if let c = s.cpu {
            // Utilization drives the score; a run queue well above the core count adds contention on top.
            let perCore = (c.loadAverage.first ?? 0) / Double(max(c.logicalCPUs, 1))
            let busy = max(c.total, summary.cpuAverage ?? 0)
            pressure["cpu"] = min(100, Int(busy + max(0, perCore - 1.5) * 15))
        }
        pressure["thermal"] = [0, 40, 80, 100][s.thermal.state.rank]
        if let v = s.volume {
            pressure["storage"] = v.freePercent < 5 ? 95 : v.freePercent < 10 ? 70 : v.available < input.thresholds.lowDiskFreeBytes ? 60 : v.freePercent < 20 ? 25 : 0
        }
        if let g = s.gpu.utilization.value { pressure["gpu"] = Int(summary.sustainedHighGPU ? max(g, 85) : g * 0.8) }
        let top = pressure.max { $0.value < $1.value }
        let bottleneck: SlowdownDiagnosis.Bottleneck = (top?.value ?? 0) >= 60 ? (SlowdownDiagnosis.Bottleneck(rawValue: top!.key) ?? .none) : .none

        // MARK: baseline (median of samples 15 min – 24 h old, excluding the last 15 min)
        let baselineSamples = hist.filter { now.timeIntervalSince($0.timestamp) > 900 && now.timeIntervalSince($0.timestamp) < 86400 }
        let recent = hist.filter { now.timeIntervalSince($0.timestamp) <= 300 } + [HistorySample(s)]
        var changes: [MetricChange] = []
        let baselineText: String
        if baselineSamples.count >= 5, let first = baselineSamples.first {
            baselineText = "Median of \(baselineSamples.count) samples since \(Format.date(first.timestamp))"
            func cmp(_ name: String, _ key: (HistorySample) -> Double?, _ fmt: (Double) -> String, higherIsWorse: Bool = true, threshold: Double) {
                guard let b = median(baselineSamples.compactMap(key)), let n = median(recent.compactMap(key)) else { return }
                let worse = higherIsWorse ? n - b > threshold : b - n > threshold
                changes.append(MetricChange(metric: name, now: fmt(n), baseline: fmt(b), worse: worse))
            }
            cmp("CPU", { $0.cpu }, { Format.percent($0) }, threshold: 15)
            cmp("Memory used", { $0.memoryUsed.map { Double($0) } }, { Format.memory(UInt64(max(0, $0))) }, threshold: 2e9)
            cmp("Compressed", { $0.compressed.map { Double($0) } }, { Format.memory(UInt64(max(0, $0))) }, threshold: 1e9)
            cmp("Swap used", { $0.swapUsed.map { Double($0) } }, { Format.memory(UInt64(max(0, $0))) }, threshold: 1e9)
            cmp("GPU", { $0.gpu }, { Format.percent($0) }, threshold: 20)
            cmp("Thermal", { $0.thermal.map { Double($0) } }, { ["nominal", "fair", "serious", "critical"][min(3, max(0, Int($0.rounded())))] }, threshold: 0.5)
            cmp("Free disk", { $0.diskFree.map { Double($0) } }, { Format.bytes(Int64($0)) }, higherIsWorse: false, threshold: 5e9)
        } else {
            baselineText = "Not enough history for a baseline (enable the background monitor or keep MacPulse open ≥ 20 min)."
        }

        // MARK: causes
        var causes: [SlowdownCause] = []
        let user = s.processes.filter { $0.category != .system && $0.category != .otherUser }
        let groups = ProcessAnalyzer.appGroups(user)
        let totalCPU = Double(max(s.cpu?.logicalCPUs ?? 1, 1)) * 100

        for g in groups.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(3) where g.cpuPercent >= 50 {
            let share = g.cpuPercent / totalCPU * 100
            causes.append(SlowdownCause(kind: .cpuHog, title: "\(g.name) is using \(Format.percent(g.cpuPercent)) CPU",
                                        evidence: ["≈\(Format.percent(share)) of total CPU capacity across \(g.pids.count) process(es)",
                                                   g.powerWatts.map { "Power ≈ \(String(format: "%.1f", $0)) W" } ?? ""].filter { !$0.isEmpty },
                                        impact: share >= 30 ? .high : share >= 10 ? .medium : .low,
                                        confidence: .high, relatedPIDs: g.pids,
                                        suggestion: "If you are not actively using it, quit or pause \(g.name)."))
        }
        let systemBusy = s.processes.filter { $0.category == .system && ($0.cpuPercent ?? 0) >= 60 }.prefix(2)
        for p in systemBusy {
            causes.append(SlowdownCause(kind: .cpuHog, title: "System process \(p.name) is busy (\(Format.percent(p.cpuPercent)))",
                                        evidence: ["macOS service — usually indexing, syncing or updating", "Running for \(Format.duration(p.runtime))"],
                                        impact: .medium, confidence: .medium, relatedPIDs: [p.pid],
                                        suggestion: "Usually temporary. Spotlight (mds), photo analysis, iCloud (bird/fileproviderd) and backups settle down after they finish."))
        }
        if (pressure["memory"] ?? 0) >= 50 || (s.memory?.pressure ?? .normal) >= .warning {
            for g in groups.prefix(3) where g.footprint >= 1_500_000_000 {
                causes.append(SlowdownCause(kind: .memoryHog, title: "\(g.name) holds \(Format.memory(g.footprint))",
                                            evidence: ["\(g.pids.count) process(es)", "Memory is the current bottleneck"],
                                            impact: g.footprint >= (s.memory?.physical ?? 1) / 5 ? .high : .medium, confidence: .high,
                                            relatedPIDs: g.pids, suggestion: "Close windows/tabs or quit \(g.name) to relieve memory pressure."))
            }
        }
        let swapGrowing = (summary.swapGrowthPerHour ?? 0) > input.thresholds.swapGrowthBytesPerHour
        if let r = summary.swapoutsPerMinute, swapMBPerMin >= 5 || swapGrowing {
            let impact: Level = swapMBPerMin >= 100 ? .high : swapMBPerMin >= 20 || swapGrowing ? .medium : .low
            causes.append(SlowdownCause(kind: .swapping,
                                        title: impact == .low ? "Light background swapping" : "The system is actively swapping",
                                        evidence: ["\(Int(r)) page-outs/min ≈ \(String(format: "%.0f", swapMBPerMin)) MB/min written to swap",
                                                   summary.swapGrowthPerHour.flatMap { $0 > 100_000_000 ? "Swap growing \(Format.memory(Int64($0)))/h" : nil } ?? "",
                                                   "Swap in use: \(Format.memory(s.memory?.swapUsed))"].filter { !$0.isEmpty },
                                        impact: impact, confidence: .high, relatedPIDs: [],
                                        suggestion: "Swapping makes everything wait on the SSD. Reduce the number of heavy apps open at once."))
        }
        // Heavy processes that did not exist at baseline time.
        if let firstBaseline = baselineSamples.first?.timestamp {
            for p in user where p.startTime > firstBaseline && ((p.cpuPercent ?? 0) >= 40 || (p.footprint ?? 0) >= 1_000_000_000) {
                causes.append(SlowdownCause(kind: .newHeavyProcess, title: "\(p.name) started \(Format.duration(p.runtime)) ago and is heavy",
                                            evidence: ["CPU \(Format.percent(p.cpuPercent, digits: 1)), memory \(Format.memory(p.footprint))", "Not running at baseline time"],
                                            impact: .medium, confidence: .medium, relatedPIDs: [p.pid],
                                            suggestion: "A recently started task is a likely reason for the change."))
            }
        }
        // Memory that grew substantially during the observed window.
        for p in user {
            guard let pts = input.processHistory[p.identity], let first = pts.first(where: { $0.footprint != nil }),
                  let a = first.footprint, let b = p.footprint, b > a, b - a >= 700_000_000,
                  now.timeIntervalSince(first.timestamp) >= 600 else { continue }
            causes.append(SlowdownCause(kind: .memoryGrowth, title: "\(p.name) grew by \(Format.memory(b - a))",
                                        evidence: ["\(Format.memory(a)) → \(Format.memory(b)) over \(Format.duration(now.timeIntervalSince(first.timestamp)))"],
                                        impact: b - a >= 2_000_000_000 ? .high : .medium, confidence: .medium, relatedPIDs: [p.pid],
                                        suggestion: "Restarting the app returns its memory if the growth is not needed."))
        }
        for f in input.findings where f.kind == .runawayCPU {
            causes.append(SlowdownCause(kind: .runaway, title: f.title, evidence: f.evidence, impact: .high, confidence: f.confidence,
                                        relatedPIDs: f.pids, suggestion: "Inspect it; a background process stuck at full CPU is rarely intentional."))
        }
        if s.thermal.state >= .fair {
            causes.append(SlowdownCause(kind: .thermal, title: "Thermal state is \(s.thermal.state.rawValue)",
                                        evidence: ["macOS reduces clock speeds to manage heat" + (s.thermal.state == .fair ? " (mildly at 'fair')" : ""),
                                                   summary.thermalElevatedMinutes > 0 ? "Elevated for \(Int(summary.thermalElevatedMinutes)) min in history" : ""].filter { !$0.isEmpty },
                                        impact: s.thermal.state >= .serious ? .high : .low, confidence: .high, relatedPIDs: [],
                                        suggestion: "Pause overlapping heavy work and let the Mac cool; keep the underside unobstructed."))
        }
        if (pressure["gpu"] ?? 0) >= 70, let gp = s.gpu.processes.first(where: { ($0.recentPercent ?? 0) >= 20 }) {
            causes.append(SlowdownCause(kind: .gpuHog, title: "\(gp.name) is using \(Format.percent(gp.recentPercent)) of GPU time",
                                        evidence: ["GPU \(Format.percent(s.gpu.utilization.value)) busy", "APIs: \(gp.apis.joined(separator: ", "))"],
                                        impact: .medium, confidence: .medium, relatedPIDs: [gp.pid],
                                        suggestion: "Browsers render WebGL/video in their GPU process — close heavy tabs or pause video."))
        }
        let onBattery = s.power.source == "Battery Power"
        for p in user.sorted(by: ProcessSortKey.energy.comparator).prefix(2) where (p.powerWatts ?? 0) >= (onBattery ? 1 : 3) {
            causes.append(SlowdownCause(kind: .energyHog, title: "\(p.name) draws ≈\(String(format: "%.1f", p.powerWatts ?? 0)) W",
                                        evidence: ["Kernel energy accounting", onBattery ? "On battery" : "On AC power"],
                                        impact: onBattery ? .medium : .low, confidence: .medium, relatedPIDs: [p.pid],
                                        suggestion: onBattery ? "High power use shortens battery life and adds heat." : "Adds heat on a fanless Mac."))
        }
        for p in user.sorted(by: ProcessSortKey.wakeups.comparator).prefix(1) where (p.wakeupsPerSecond ?? 0) >= 1000 {
            causes.append(SlowdownCause(kind: .wakeupStorm, title: "\(p.name) wakes the CPU \(Int(p.wakeupsPerSecond ?? 0))×/s",
                                        evidence: ["Frequent wakeups keep cores out of low-power states"],
                                        impact: .low, confidence: .medium, relatedPIDs: [p.pid],
                                        suggestion: "Often timers in an idle app or a busy browser tab."))
        }
        if let v = s.volume, (pressure["storage"] ?? 0) >= 60 {
            causes.append(SlowdownCause(kind: .lowDisk, title: "Only \(Format.bytes(v.available)) free on the startup disk",
                                        evidence: ["Swap and caches need free space; very low space slows writes and updates"],
                                        impact: .high, confidence: .high, relatedPIDs: [], suggestion: "Run a cleanup dry run: macpulse disk analyze"))
        }
        causes.sort { ($0.impact, $0.confidence) > ($1.impact, $1.confidence) }

        let verdict: String = switch bottleneck {
        case .memory: "Memory is the bottleneck: apps are competing for RAM\(swapMBPerMin >= 20 ? " and the system is swapping" : "")."
        case .cpu: (s.cpu?.total ?? 0) >= 85
            ? "The CPU is saturated: more work is queued than the cores can run."
            : "The CPU is the most contended resource (\(Format.percent(s.cpu?.total)) busy with a long run queue)."
        case .thermal: "The Mac is hot, so macOS is reducing performance to protect it."
        case .storage: "The startup disk is nearly full, which slows swapping, caching and updates."
        case .gpu: "The GPU is heavily loaded; graphics work (often a browser) is the constraint."
        case .none: causes.contains { $0.impact == .high }
            ? "No resource is saturated system-wide, but the causes below may explain sluggishness."
            : "No system-level bottleneck right now. If something feels slow, it is likely inside one app (or network-bound)."
        }
        return SlowdownDiagnosis(timestamp: now, bottleneck: bottleneck, verdict: verdict, pressure: pressure,
                                 baselineDescription: baselineText, changes: changes, causes: Array(causes.prefix(10)))
    }
}
