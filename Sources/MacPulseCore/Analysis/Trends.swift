import Foundation

/// A compact persisted sample of system state.
public struct HistorySample: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var cpu: Double?
    public var load1: Double?
    public var memoryUsed: UInt64?
    public var compressed: UInt64?
    public var pressure: Int?          // 0 normal, 1 warning, 2 critical
    public var swapUsed: UInt64?
    public var swapouts: UInt64?
    public var gpu: Double?
    public var thermal: Int?           // ThermalState.rank
    public var diskFree: Int64?
    public var battery: Int?
    public var onAC: Bool?

    public init(timestamp: Date, cpu: Double? = nil, load1: Double? = nil, memoryUsed: UInt64? = nil,
                compressed: UInt64? = nil, pressure: Int? = nil, swapUsed: UInt64? = nil, swapouts: UInt64? = nil,
                gpu: Double? = nil, thermal: Int? = nil, diskFree: Int64? = nil, battery: Int? = nil, onAC: Bool? = nil) {
        self.timestamp = timestamp; self.cpu = cpu; self.load1 = load1; self.memoryUsed = memoryUsed
        self.compressed = compressed; self.pressure = pressure; self.swapUsed = swapUsed; self.swapouts = swapouts
        self.gpu = gpu; self.thermal = thermal; self.diskFree = diskFree; self.battery = battery; self.onAC = onAC
    }

    public init(_ s: SystemSnapshot) {
        let pressure: Int? = switch s.memory?.pressure {
        case .normal: 0; case .warning: 1; case .critical: 2; default: nil
        }
        self.init(timestamp: s.timestamp, cpu: s.cpu?.total, load1: s.cpu?.loadAverage.first,
                  memoryUsed: s.memory?.used, compressed: s.memory?.compressed, pressure: pressure,
                  swapUsed: s.memory?.swapUsed, swapouts: s.memory?.swapouts,
                  gpu: s.gpu.utilization.value, thermal: s.thermal.state.rank,
                  diskFree: s.volume?.available, battery: s.power.chargePercent,
                  onAC: s.power.source == "AC Power")
    }
}

public struct LinearFit: Sendable, Equatable {
    /// Units of y per second.
    public var slope: Double
    public var intercept: Double
    public var r2: Double
}

public enum Trends {
    /// Ordinary least squares over (seconds, value) points.
    public static func fit(_ points: [(Double, Double)]) -> LinearFit? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        let mx = points.map(\.0).reduce(0, +) / n
        let my = points.map(\.1).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (x, y) in points {
            sxx += (x - mx) * (x - mx); sxy += (x - mx) * (y - my); syy += (y - my) * (y - my)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1
        return LinearFit(slope: slope, intercept: my - slope * mx, r2: r2)
    }

    /// Fraction of samples in `window` (ending at the newest sample) whose value exceeds `threshold`,
    /// plus the time span actually covered. "Sustained" requires both high fraction and coverage.
    public static func sustained(_ samples: [(Date, Double)], threshold: Double, window: TimeInterval,
                                 minFraction: Double = 0.8) -> (sustained: Bool, fraction: Double, covered: TimeInterval) {
        guard let last = samples.map(\.0).max() else { return (false, 0, 0) }
        let inWindow = samples.filter { last.timeIntervalSince($0.0) <= window }
        guard let first = inWindow.map(\.0).min(), inWindow.count >= 3 else { return (false, 0, 0) }
        let fraction = Double(inWindow.filter { $0.1 >= threshold }.count) / Double(inWindow.count)
        let covered = last.timeIntervalSince(first)
        return (fraction >= minFraction && covered >= window * 0.75, fraction, covered)
    }
}

public struct HistorySummary: Codable, Sendable {
    public var sampleCount: Int
    public var span: TimeInterval
    /// Linear-regression slope of swap used over the last hour, bytes/hour.
    public var swapGrowthPerHour: Double?
    public var swapGrowthR2: Double?
    public var swapoutsPerMinute: Double?
    public var cpuAverage: Double?
    public var sustainedHighCPU: Bool
    public var sustainedHighGPU: Bool
    public var gpuAverage: Double?
    public var thermalElevatedMinutes: Double
    public var pressureElevatedMinutes: Double
    public var diskFreeChangePerDay: Double?

    public static let empty = HistorySummary(sampleCount: 0, span: 0, sustainedHighCPU: false, sustainedHighGPU: false,
                                             thermalElevatedMinutes: 0, pressureElevatedMinutes: 0)

    public static func compute(_ samplesIn: [HistorySample], cpuThreshold: Double = 85,
                               cpuWindow: TimeInterval = 600) -> HistorySummary {
        let samples = samplesIn.sorted { $0.timestamp < $1.timestamp }
        guard let first = samples.first, let last = samples.last else { return .empty }
        var s = HistorySummary.empty
        s.sampleCount = samples.count
        s.span = last.timestamp.timeIntervalSince(first.timestamp)

        let hour = samples.filter { last.timestamp.timeIntervalSince($0.timestamp) <= 3600 }
        let swapPts = hour.compactMap { h in h.swapUsed.map { (h.timestamp.timeIntervalSince(first.timestamp), Double($0)) } }
        if let span = swapPts.last.map({ $0.0 - (swapPts.first?.0 ?? 0) }), span >= 600, let f = Trends.fit(swapPts) {
            s.swapGrowthPerHour = f.slope * 3600
            s.swapGrowthR2 = f.r2
        }
        if let a = hour.first(where: { $0.swapouts != nil }), let b = hour.last(where: { $0.swapouts != nil }),
           let sa = a.swapouts, let sb = b.swapouts, sb >= sa {
            let minutes = b.timestamp.timeIntervalSince(a.timestamp) / 60
            if minutes >= 5 { s.swapoutsPerMinute = Double(sb - sa) / minutes }
        }
        let cpu = samples.compactMap { h in h.cpu.map { (h.timestamp, $0) } }
        if !cpu.isEmpty {
            let recent = cpu.filter { last.timestamp.timeIntervalSince($0.0) <= cpuWindow }
            s.cpuAverage = recent.map(\.1).reduce(0, +) / Double(max(recent.count, 1))
            s.sustainedHighCPU = Trends.sustained(cpu, threshold: cpuThreshold, window: cpuWindow).sustained
        }
        let gpu = samples.compactMap { h in h.gpu.map { (h.timestamp, $0) } }
        if !gpu.isEmpty {
            let recent = gpu.filter { last.timestamp.timeIntervalSince($0.0) <= cpuWindow }
            s.gpuAverage = recent.map(\.1).reduce(0, +) / Double(max(recent.count, 1))
            s.sustainedHighGPU = Trends.sustained(gpu, threshold: 85, window: cpuWindow).sustained
        }
        s.thermalElevatedMinutes = elevatedMinutes(samples) { ($0.thermal ?? 0) >= 2 }
        s.pressureElevatedMinutes = elevatedMinutes(samples) { ($0.pressure ?? 0) >= 1 }
        let disk = samples.compactMap { h in h.diskFree.map { (h.timestamp.timeIntervalSince(first.timestamp), Double($0)) } }
        if s.span >= 6 * 3600, let f = Trends.fit(disk) { s.diskFreeChangePerDay = f.slope * 86400 }
        return s
    }

    /// Sums the intervals between consecutive samples where the predicate held (gaps > 15 min are ignored).
    static func elevatedMinutes(_ samples: [HistorySample], _ predicate: (HistorySample) -> Bool) -> Double {
        var total = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) where predicate(a) {
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            if dt <= 900 { total += dt }
        }
        return total / 60
    }
}
