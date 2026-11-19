import Foundation

/// One scored dimension. Scores start at 100 and every deduction is recorded with its reason,
/// so the number is always explainable. See docs/HEALTH_SCORE.md for the rule table.
public struct HealthDimension: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case memory, cpu, thermal, storage, gpu, battery }
    public var kind: Kind
    public var score: Int
    public var status: Severity
    public var weight: Double
    public var deductions: [Deduction]
    public var summary: String
    public var id: String { kind.rawValue }
}

public struct Deduction: Codable, Sendable {
    public var points: Int
    public var reason: String
}

public struct HealthReport: Codable, Sendable {
    public var overall: Int
    public var status: Severity
    public var dimensions: [HealthDimension]
    public var excluded: [String]
    public var method: String
}

public enum HealthScorer {
    public static func evaluate(_ s: SystemSnapshot, history: HistorySummary = .empty, thresholds: Thresholds = Thresholds()) -> HealthReport {
        var dims: [HealthDimension] = []
        var excluded: [String] = []

        if let m = s.memory { dims.append(memory(m, history, thresholds)) } else { excluded.append("memory: statistics unavailable") }
        if let c = s.cpu { dims.append(cpu(c, history, thresholds)) } else { excluded.append("cpu: no baseline sample") }
        dims.append(thermal(s.thermal, history))
        if let v = s.volume { dims.append(storage(v, thresholds)) } else { excluded.append("storage: volume info unavailable") }
        if let g = s.gpu.utilization.value { dims.append(gpu(g, history)) } else { excluded.append("gpu: utilization not published by driver") }
        if s.power.hasBattery, let h = s.power.healthPercent.value { dims.append(battery(h, s.power)) }
        else { excluded.append("battery: not present or health not readable") }

        let totalWeight = dims.map(\.weight).reduce(0, +)
        var overall = totalWeight > 0 ? Int((dims.map { Double($0.score) * $0.weight }.reduce(0, +) / totalWeight).rounded()) : 0
        // A single critical dimension caps the overall score: averages must not hide an emergency.
        if dims.contains(where: { $0.status == .critical }) { overall = min(overall, 49) }
        else if dims.contains(where: { $0.status == .warning }) { overall = min(overall, 79) }
        return HealthReport(overall: overall, status: status(for: overall), dimensions: dims, excluded: excluded,
                            method: "Weighted mean of dimension scores (memory 3, cpu 2, thermal 2, storage 2, gpu 1, battery 1); capped at 49 if any dimension is critical and 79 if any is a warning.")
    }

    static func status(for score: Int) -> Severity {
        score >= 80 ? .ok : score >= 50 ? .warning : .critical
    }

    static func finish(_ kind: HealthDimension.Kind, weight: Double, _ deductions: [Deduction], summary: String) -> HealthDimension {
        let score = max(0, 100 - deductions.map(\.points).reduce(0, +))
        return HealthDimension(kind: kind, score: score, status: status(for: score), weight: weight,
                               deductions: deductions, summary: summary)
    }

    static func memory(_ m: MemorySnapshot, _ h: HistorySummary, _ t: Thresholds) -> HealthDimension {
        var d: [Deduction] = []
        switch m.pressure {
        case .warning: d.append(Deduction(points: 35, reason: "Kernel memory pressure is WARNING"))
        case .critical: d.append(Deduction(points: 70, reason: "Kernel memory pressure is CRITICAL"))
        default: break
        }
        if let g = h.swapGrowthPerHour, g >= t.swapGrowthBytesPerHour, (h.swapGrowthR2 ?? 0) >= 0.5 {
            d.append(Deduction(points: 15, reason: "Swap growing \(Format.memory(Int64(g)))/h over the last hour"))
        }
        if let rate = h.swapoutsPerMinute, rate > 1000 {
            d.append(Deduction(points: 10, reason: "Active swapping: \(Int(rate)) page-outs/min"))
        }
        let compressedRatio = Double(m.compressed) / Double(max(m.physical, 1))
        if compressedRatio > 0.25 {
            d.append(Deduction(points: 10, reason: "Compressed memory is \(Format.percent(compressedRatio * 100)) of RAM"))
        }
        return finish(.memory, weight: 3, d, summary: "Pressure \(m.pressure.rawValue), \(Format.memory(m.used)) used of \(Format.memory(m.physical)), swap \(Format.memory(m.swapUsed))")
    }

    static func cpu(_ c: CPUSnapshot, _ h: HistorySummary, _ t: Thresholds) -> HealthDimension {
        var d: [Deduction] = []
        if h.sustainedHighCPU {
            d.append(Deduction(points: 35, reason: "CPU ≥\(Int(t.sustainedCPUPercent))% sustained over \(Int(t.sustainedCPUMinutes)) min"))
        } else if c.total >= 90 {
            d.append(Deduction(points: 10, reason: "CPU currently \(Format.percent(c.total)) (single sample)"))
        }
        if let l1 = c.loadAverage.first, c.logicalCPUs > 0 {
            let perCore = l1 / Double(c.logicalCPUs)
            if perCore >= 4 { d.append(Deduction(points: 20, reason: String(format: "1-min load %.1f is %.1f× the core count (heavy run-queue contention)", l1, perCore))) }
            else if perCore >= 2 { d.append(Deduction(points: 10, reason: String(format: "1-min load %.1f is %.1f× the core count", l1, perCore))) }
        }
        return finish(.cpu, weight: 2, d, summary: "\(Format.percent(c.total)) busy, load \(c.loadAverage.map { String(format: "%.1f", $0) }.joined(separator: " "))")
    }

    static func thermal(_ th: ThermalSnapshot, _ h: HistorySummary) -> HealthDimension {
        var d: [Deduction] = []
        switch th.state {
        case .fair: d.append(Deduction(points: 15, reason: "Thermal state FAIR"))
        case .serious: d.append(Deduction(points: 50, reason: "Thermal state SERIOUS — performance is being reduced"))
        case .critical: d.append(Deduction(points: 80, reason: "Thermal state CRITICAL"))
        case .nominal: break
        }
        if h.thermalElevatedMinutes >= 30 {
            d.append(Deduction(points: 10, reason: "Thermal state ≥ serious for \(Int(h.thermalElevatedMinutes)) min in history"))
        }
        return finish(.thermal, weight: 2, d, summary: "macOS thermal state \(th.state.rawValue)")
    }

    static func storage(_ v: VolumeSnapshot, _ t: Thresholds) -> HealthDimension {
        var d: [Deduction] = []
        let pct = v.freePercent
        if pct < 5 { d.append(Deduction(points: 70, reason: "Only \(Format.percent(pct, digits: 1)) free")) }
        else if pct < t.lowDiskFreePercent { d.append(Deduction(points: 40, reason: "\(Format.percent(pct, digits: 1)) free (below \(Int(t.lowDiskFreePercent))%)")) }
        else if pct < 20 { d.append(Deduction(points: 15, reason: "\(Format.percent(pct, digits: 1)) free (below 20%)")) }
        if v.available < t.lowDiskFreeBytes {
            d.append(Deduction(points: 20, reason: "Less than \(Format.bytes(t.lowDiskFreeBytes)) free — swap files and OS updates need headroom"))
        }
        return finish(.storage, weight: 2, d, summary: "\(Format.bytes(v.available)) free of \(Format.bytes(v.total))")
    }

    static func gpu(_ util: Double, _ h: HistorySummary) -> HealthDimension {
        var d: [Deduction] = []
        if h.sustainedHighGPU { d.append(Deduction(points: 25, reason: "GPU ≥85% sustained over 10 min")) }
        else if util >= 95 { d.append(Deduction(points: 5, reason: "GPU currently \(Format.percent(util)) (single sample)")) }
        return finish(.gpu, weight: 1, d, summary: "GPU \(Format.percent(util)) busy")
    }

    static func battery(_ health: Double, _ p: PowerSnapshot) -> HealthDimension {
        var d: [Deduction] = []
        // Apple's battery service guidance for Mac notebooks is based on 80% maximum capacity.
        if health < 80 { d.append(Deduction(points: Int(min(60, (80 - health) * 3 + 20)), reason: "Maximum capacity \(Format.percent(health)) (below Apple's 80% service guideline)")) }
        else if health < 90 { d.append(Deduction(points: Int((90 - health) * 1.5), reason: "Maximum capacity \(Format.percent(health))")) }
        return finish(.battery, weight: 1, d, summary: "Capacity \(Format.percent(health)), \(p.cycleCount.map { "\($0) cycles" } ?? "cycles unknown")")
    }
}
