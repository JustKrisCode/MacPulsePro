import Foundation

public struct Recommendation: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var evidence: [String]
    public var severity: Severity
    public var confidence: Level
    public var expectedEffect: String
    public var benefit: Level
    public var risk: Level
    public var reversible: Bool
    public var effort: Level
    public var relatedPIDs: [Int32]
    public var actionHint: String?

    /// Deterministic ranking: evidence severity × benefit × confidence × safety × reversibility ÷ effort.
    public var priority: Double {
        let sev: Double = switch severity { case .critical: 4; case .warning: 3; case .info: 1.5; case .ok: 1 }
        let safety: Double = switch risk { case .low: 1; case .medium: 0.6; case .high: 0.3 }
        return sev * benefit.weight * (confidence.weight / 3) * safety * (reversible ? 1 : 0.7) / effort.weight
    }
}

public struct CleanupSummary: Codable, Sendable {
    public var safeBytes: Int64
    public var reviewBytes: Int64
    public var safeCount: Int
    public init(safeBytes: Int64, reviewBytes: Int64, safeCount: Int) {
        self.safeBytes = safeBytes; self.reviewBytes = reviewBytes; self.safeCount = safeCount
    }
}

public struct RecommendationContext: Sendable {
    public var snapshot: SystemSnapshot
    public var history: HistorySummary
    public var findings: [ProcessFinding]
    public var cleanup: CleanupSummary?
    public var thresholds: Thresholds

    public init(snapshot: SystemSnapshot, history: HistorySummary = .empty, findings: [ProcessFinding] = [],
                cleanup: CleanupSummary? = nil, thresholds: Thresholds = Thresholds()) {
        self.snapshot = snapshot; self.history = history; self.findings = findings
        self.cleanup = cleanup; self.thresholds = thresholds
    }
}

public enum RecommendationEngine {
    static let browserMarkers = ["Chrome", "Chromium", "Safari", "WebKit", "Firefox", "Edge", "Brave", "Arc", "Opera", "Vivaldi", "Helper (GPU)", "Electron"]

    public static func recommendations(_ ctx: RecommendationContext) -> [Recommendation] {
        var out: [Recommendation] = []
        let s = ctx.snapshot, h = ctx.history, t = ctx.thresholds
        let groups = ProcessAnalyzer.appGroups(s.processes.filter { $0.category != .system && $0.category != .otherUser })
        let topMemory = groups.prefix(5).filter { $0.footprint > 300_000_000 }
        let memList = topMemory.map { "\($0.name): \(Format.memory($0.footprint))" }

        // R1/R2: memory pressure (+ rising swap).
        if let m = s.memory {
            let swapRising = (h.swapGrowthPerHour ?? 0) >= t.swapGrowthBytesPerHour && (h.swapGrowthR2 ?? 0) >= 0.5
            if m.pressure >= .warning {
                var ev = ["Kernel memory pressure: \(m.pressure.rawValue)", "Swap used: \(Format.memory(m.swapUsed))",
                          "Compressed: \(Format.memory(m.compressed))"]
                if swapRising, let g = h.swapGrowthPerHour { ev.append("Swap growing \(Format.memory(Int64(g)))/h") }
                out.append(Recommendation(
                    id: "memory.pressure", title: "Reduce concurrent memory-heavy workloads",
                    detail: "macOS is under memory pressure\(swapRising ? " and swap is rising" : ""). Quitting or pausing the largest non-essential consumers lowers pressure; freeing a 'free RAM' number does not.",
                    evidence: ev + memList.map { "Large consumer — \($0)" },
                    severity: m.pressure == .critical || swapRising ? .critical : .warning,
                    confidence: swapRising ? .high : .medium,
                    expectedEffect: "Lower memory pressure, fewer page-outs, better responsiveness.",
                    benefit: .high, risk: .low, reversible: true, effort: .low,
                    relatedPIDs: topMemory.flatMap(\.pids), actionHint: "macpulse memory"))
            } else if swapRising, let g = h.swapGrowthPerHour {
                out.append(Recommendation(
                    id: "memory.swap-growth", title: "Swap is growing while pressure is still normal",
                    detail: "Sustained swap growth often precedes memory pressure. Check which apps are expanding.",
                    evidence: ["Swap growth \(Format.memory(Int64(g)))/h (R² \(String(format: "%.2f", h.swapGrowthR2 ?? 0)))"] + memList,
                    severity: .warning, confidence: .medium, expectedEffect: "Prevent a slide into memory pressure.",
                    benefit: .medium, risk: .low, reversible: true, effort: .low, relatedPIDs: topMemory.flatMap(\.pids),
                    actionHint: "macpulse memory"))
            } else if m.swapUsed > m.physical / 4 {
                out.append(Recommendation(
                    id: "memory.residual-swap", title: "Large swap in use, but no current pressure",
                    detail: "Swap that is not actively paged is mostly harmless. It is released when the owning processes exit or after a restart; no action is needed unless swapping is active.",
                    evidence: ["Swap used \(Format.memory(m.swapUsed)) of \(Format.memory(m.swapTotal))", "Pressure normal",
                               h.swapoutsPerMinute.map { "Page-outs: \(Int($0))/min" } ?? "Page-out rate unknown (needs history)"],
                    severity: .info, confidence: .medium, expectedEffect: "Restarting long-running apps returns swap space to disk.",
                    benefit: .low, risk: .low, reversible: true, effort: .medium, relatedPIDs: [], actionHint: nil))
            }
        }

        // R3: sustained CPU with elevated thermal state.
        let backgroundBusy = s.processes.filter { ($0.cpuPercent ?? 0) >= 25 && !$0.isForegroundApp && $0.category != .system && $0.category != .otherUser }
            .sorted(by: ProcessSortKey.cpu.comparator).prefix(5)
        let busyList = backgroundBusy.map { "\($0.name) (pid \($0.pid)): \(Format.percent($0.cpuPercent, digits: 0)) CPU" }
        if (h.sustainedHighCPU || (s.cpu?.total ?? 0) >= 85) && s.thermal.state >= .fair {
            out.append(Recommendation(
                id: "cpu.thermal", title: "Heavy CPU load is heating the Mac",
                detail: "Sustained CPU load with an elevated thermal state means macOS will lower clock speeds (fanless Macs reach this sooner). Pausing background work restores headroom.",
                evidence: ["Thermal state \(s.thermal.state.rawValue)", "CPU \(Format.percent(s.cpu?.total))\(h.sustainedHighCPU ? " (sustained)" : "")"] + busyList,
                severity: s.thermal.state >= .serious ? .critical : .warning, confidence: h.sustainedHighCPU ? .high : .medium,
                expectedEffect: "Cooler system, fewer thermal clock reductions, faster foreground work.",
                benefit: .high, risk: .low, reversible: true, effort: .low,
                relatedPIDs: backgroundBusy.map(\.pid), actionHint: "macpulse cpu"))
        } else if h.sustainedHighCPU {
            out.append(Recommendation(
                id: "cpu.sustained", title: "CPU has been saturated for a sustained period",
                detail: "Identify whether the busiest processes are doing work you asked for.",
                evidence: ["Average CPU \(Format.percent(h.cpuAverage)) over the last 10 min"] + busyList,
                severity: .warning, confidence: .high, expectedEffect: "More responsive system once unnecessary work stops.",
                benefit: .medium, risk: .low, reversible: true, effort: .low, relatedPIDs: backgroundBusy.map(\.pid),
                actionHint: "macpulse cpu"))
        }
        if let c = s.cpu, let l1 = c.loadAverage.first, l1 > Double(c.logicalCPUs) * 3 {
            out.append(Recommendation(
                id: "cpu.load", title: "Run queue far exceeds core count",
                detail: "Many runnable threads are competing for \(c.logicalCPUs) cores. Reduce parallelism (build jobs, test workers, VMs) to cut contention.",
                evidence: [String(format: "Load averages %.1f / %.1f / %.1f", l1, c.loadAverage[safe: 1] ?? 0, c.loadAverage[safe: 2] ?? 0),
                           "\(c.logicalCPUs) logical CPUs"] + busyList,
                severity: .warning, confidence: .medium, expectedEffect: "Lower latency for interactive work.",
                benefit: .medium, risk: .low, reversible: true, effort: .medium, relatedPIDs: backgroundBusy.map(\.pid),
                actionHint: "macpulse processes --sort cpu"))
        }

        // R4: GPU + CPU — check whether a browser GPU process is responsible.
        let gpuBusy = (s.gpu.utilization.value ?? 0) >= 70 || h.sustainedHighGPU
        if gpuBusy {
            let topGPU = s.gpu.processes.filter { ($0.recentPercent ?? 0) >= 5 }.prefix(5)
            let browserGPU = topGPU.filter { p in browserMarkers.contains { p.name.contains($0) } }
            var ev = ["GPU utilization \(Format.percent(s.gpu.utilization.value))\(h.sustainedHighGPU ? " (sustained)" : "")"]
            ev += topGPU.map { "\($0.name) (pid \($0.pid)): \(Format.percent($0.recentPercent, digits: 1)) of GPU time [\($0.apis.joined(separator: ","))]" }
            if (s.cpu?.total ?? 0) >= 50 { ev.append("CPU \(Format.percent(s.cpu?.total)) at the same time") }
            out.append(Recommendation(
                id: "gpu.heavy", title: browserGPU.isEmpty ? "GPU is heavily loaded" : "A browser is driving most GPU work",
                detail: browserGPU.isEmpty
                    ? "Check the listed processes; 3D apps, video export and games are expected to use the GPU."
                    : "Browser GPU processes render WebGL/WebGPU, video and animated pages. Close heavy tabs or check the browser's task manager to find the page.",
                evidence: ev, severity: h.sustainedHighGPU ? .warning : .info, confidence: topGPU.isEmpty ? .low : .medium,
                expectedEffect: "Lower GPU load and heat; smoother graphics in the app you care about.",
                benefit: .medium, risk: .low, reversible: true, effort: .low,
                relatedPIDs: topGPU.map(\.pid), actionHint: "macpulse gpu"))
        }

        // R5: thermal on its own.
        if s.thermal.state >= .serious && !out.contains(where: { $0.id == "cpu.thermal" }) {
            out.append(Recommendation(
                id: "thermal.elevated", title: "The Mac is thermally constrained",
                detail: "macOS is limiting performance to protect hardware. Reduce heavy workloads, keep vents/underside unobstructed and avoid direct sun or soft surfaces.",
                evidence: ["Thermal state \(s.thermal.state.rawValue)"] + s.thermal.throttlingIndicator.reasons,
                severity: .critical, confidence: .high, expectedEffect: "Performance recovers as temperature drops.",
                benefit: .high, risk: .low, reversible: true, effort: .low, relatedPIDs: [], actionHint: "macpulse thermal"))
        }

        // R6/R7: storage.
        if let v = s.volume {
            let low = v.freePercent < t.lowDiskFreePercent || v.available < t.lowDiskFreeBytes
            if low {
                var ev = ["\(Format.bytes(v.available)) free (\(Format.percent(v.freePercent, digits: 1)))"]
                if let p = v.purgeableEstimate.value, p > 0 { ev.append("macOS can purge about \(Format.bytes(p)) automatically (estimated)") }
                if let c = ctx.cleanup { ev.append("Safe rebuildable data found: \(Format.bytes(c.safeBytes)) in \(c.safeCount) items; review items: \(Format.bytes(c.reviewBytes))") }
                out.append(Recommendation(
                    id: "storage.low", title: "Free up disk space",
                    detail: "Start with a dry run of safe, rebuildable caches, then review large files. Nothing is deleted without explicit confirmation.",
                    evidence: ev, severity: v.freePercent < 5 ? .critical : .warning,
                    confidence: ctx.cleanup == nil ? .medium : .high,
                    expectedEffect: ctx.cleanup.map { "Up to \(Format.bytes($0.safeBytes)) from safe items (estimated; verified after cleanup)." } ?? "Depends on scan results.",
                    benefit: .high, risk: .low, reversible: true, effort: .low, relatedPIDs: [], actionHint: "macpulse disk analyze"))
                if let m = s.memory, m.swapUsed > 0, (h.swapoutsPerMinute ?? 0) > 100 || m.pressure >= .warning {
                    out.append(Recommendation(
                        id: "storage.swap", title: "Low disk space while the system is swapping",
                        detail: "Swap files live on the startup volume. With little free space macOS cannot grow swap, which can stall apps or trigger 'out of application memory' warnings.",
                        evidence: ["Free space \(Format.bytes(v.available))", "Swap used \(Format.memory(m.swapUsed))",
                                   "Memory pressure \(m.pressure.rawValue)"],
                        severity: .critical, confidence: .high, expectedEffect: "Restores room for swap and system updates.",
                        benefit: .high, risk: .low, reversible: true, effort: .low, relatedPIDs: [], actionHint: "macpulse disk analyze"))
                }
            } else if let c = ctx.cleanup, c.safeBytes >= 2_000_000_000 {
                out.append(Recommendation(
                    id: "storage.caches", title: "Large rebuildable caches available",
                    detail: "These caches regenerate on demand. Cleaning them is optional; apps may be slower the first time they rebuild.",
                    evidence: ["\(Format.bytes(c.safeBytes)) in \(c.safeCount) safe items (estimated)"],
                    severity: .info, confidence: .high, expectedEffect: "Reclaims disk space; no performance gain by itself.",
                    benefit: .low, risk: .low, reversible: true, effort: .low, relatedPIDs: [], actionHint: "macpulse disk clean --dry-run"))
            }
            if let perDay = h.diskFreeChangePerDay, perDay < -5_000_000_000 {
                out.append(Recommendation(
                    id: "storage.trend", title: "Free space is shrinking quickly",
                    detail: "Something is writing several GB per day. Check downloads, caches and VM/container images.",
                    evidence: ["Free space trend \(Format.bytes(Int64(perDay)))/day"], severity: .warning, confidence: .medium,
                    expectedEffect: "Find the growth before the disk fills.", benefit: .medium, risk: .low, reversible: true,
                    effort: .medium, relatedPIDs: [], actionHint: "macpulse disk analyze"))
            }
        }

        // R8: process findings.
        for f in ctx.findings where [.runawayCPU, .memoryGrowth, .probableOrphan].contains(f.kind) {
            let (title, effect): (String, String) = switch f.kind {
            case .runawayCPU: ("Investigate a continuously busy background process", "Frees CPU and reduces heat if the work is unnecessary.")
            case .memoryGrowth: ("Investigate steadily growing memory", "Restarting a leaking process returns its memory.")
            default: ("Review a probably abandoned process", "Frees its memory/CPU if it is no longer needed.")
            }
            out.append(Recommendation(id: "process.\(f.id)", title: title, detail: f.title, evidence: f.evidence,
                                      severity: f.severity, confidence: f.confidence, expectedEffect: effect,
                                      benefit: f.kind == .probableOrphan ? .low : .medium, risk: .medium, reversible: false,
                                      effort: .low, relatedPIDs: f.pids,
                                      actionHint: f.pids.first.map { "macpulse processes inspect \($0)" }))
        }

        // R9: battery and power mode.
        if let health = s.power.healthPercent.value, health < 80 {
            out.append(Recommendation(
                id: "battery.service", title: "Battery capacity is below 80%",
                detail: "Apple recommends service for Mac notebook batteries below 80% maximum capacity. Check System Settings › Battery for the official condition.",
                evidence: ["Estimated maximum capacity \(Format.percent(health))", s.power.cycleCount.map { "\($0) charge cycles" } ?? ""].filter { !$0.isEmpty },
                severity: .info, confidence: .medium, expectedEffect: "Restored battery runtime after service.",
                benefit: .medium, risk: .low, reversible: true, effort: .high, relatedPIDs: [], actionHint: nil))
        }
        if s.thermal.lowPowerMode && (s.cpu?.total ?? 0) >= 60 {
            out.append(Recommendation(
                id: "power.lowpower", title: "Low Power Mode is on during heavy work",
                detail: "Low Power Mode lowers clock speeds. Turn it off in System Settings › Battery if you need full performance.",
                evidence: ["Low Power Mode enabled", "CPU \(Format.percent(s.cpu?.total))"], severity: .info, confidence: .high,
                expectedEffect: "Higher sustained performance (and power draw).", benefit: .medium, risk: .low,
                reversible: true, effort: .low, relatedPIDs: [], actionHint: nil))
        }
        return out.sorted { $0.priority > $1.priority }
    }
}

extension Array {
    public subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
