import Foundation

/// Decides whether the Mac has headroom for a heavy job (build, render, export). Used by
/// `macpulse ready` and `macpulse run --when-ready -- <command>` — useful on fanless Macs, where
/// stacking heavy jobs pushes the thermal state up and every job slows down.
public struct ReadinessPolicy: Codable, Sendable, Equatable {
    public var maxThermal: ThermalState = .nominal
    public var maxCPUPercent: Double = 60
    public var requireNormalMemoryPressure = true
    public var maxSwapoutsPerMinute: Double = 300
    public var minFreeDiskBytes: Int64 = 5_000_000_000

    public init() {}
}

public struct ReadinessResult: Codable, Sendable {
    public var ready: Bool
    public var blockers: [String]
    public var checks: [String]
}

public enum Readiness {
    /// `recent` = the last few snapshots (oldest first); CPU is averaged over them to ignore single spikes.
    public static func evaluate(_ recent: [SystemSnapshot], policy: ReadinessPolicy = ReadinessPolicy()) -> ReadinessResult {
        guard let s = recent.last else { return ReadinessResult(ready: false, blockers: ["no data"], checks: []) }
        var blockers: [String] = [], checks: [String] = []

        if s.thermal.state > policy.maxThermal { blockers.append("thermal state \(s.thermal.state.rawValue) (max \(policy.maxThermal.rawValue))") }
        else { checks.append("thermal \(s.thermal.state.rawValue)") }

        let cpus = recent.compactMap { $0.cpu?.total }
        if let avg = cpus.isEmpty ? nil : cpus.reduce(0, +) / Double(cpus.count) {
            if avg > policy.maxCPUPercent { blockers.append("CPU \(Format.percent(avg)) averaged (max \(Format.percent(policy.maxCPUPercent)))") }
            else { checks.append("CPU \(Format.percent(avg))") }
        }
        if let m = s.memory {
            if policy.requireNormalMemoryPressure && m.pressure >= .warning { blockers.append("memory pressure \(m.pressure.rawValue)") }
            else { checks.append("memory pressure \(m.pressure.rawValue)") }
        }
        if recent.count >= 2, let a = recent.first, let am = a.memory, let bm = s.memory, bm.swapouts >= am.swapouts {
            let minutes = s.timestamp.timeIntervalSince(a.timestamp) / 60
            if minutes > 0 {
                let rate = Double(bm.swapouts - am.swapouts) / minutes
                if rate > policy.maxSwapoutsPerMinute { blockers.append("swapping \(Int(rate)) page-outs/min") }
                else { checks.append("swap activity \(Int(rate))/min") }
            }
        }
        if let v = s.volume {
            if v.available < policy.minFreeDiskBytes { blockers.append("only \(Format.bytes(v.available)) free disk") }
            else { checks.append("\(Format.bytes(v.available)) free") }
        }
        return ReadinessResult(ready: blockers.isEmpty, blockers: blockers, checks: checks)
    }
}
