import Foundation
import IOKit

public struct GPUDevice: Codable, Sendable {
    public var name: String
    public var coreCount: Int?
    /// IOAccelerator PerformanceStatistics "Device Utilization %".
    public var deviceUtilization: Double?
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    /// Driver-reported GPU system memory in use (unified memory on Apple Silicon).
    public var inUseSystemMemory: UInt64?
    public var allocatedSystemMemory: UInt64?
}

/// GPU time attributed to one process, derived from IOKit AGX user-client counters.
public struct GPUProcessUsage: Codable, Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var apis: [String]
    /// Cumulative GPU time since the process opened its GPU connection, in seconds.
    public var accumulatedSeconds: Double
    /// Share of wall-clock time the GPU spent on this process during the last interval (0–100+).
    public var recentPercent: Double?
}

public struct GPUSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var devices: [GPUDevice]
    public var processes: [GPUProcessUsage]
    public var utilization: Metric<Double>
    public var processProvenance: Provenance
    public var notes: [String]
}

public enum GPUCollector {
    public static func devices() -> [GPUDevice] {
        var result: [GPUDevice] = []
        IORegistry.forEachService(matching: "IOAccelerator") { service in
            // Read only the keys we need: copying the accelerator's full property dictionary is expensive.
            let stats = IORegistry.property(service, "PerformanceStatistics") as? [String: Any] ?? [:]
            func d(_ k: String) -> Double? { (stats[k] as? NSNumber)?.doubleValue }
            func u(_ k: String) -> UInt64? { (stats[k] as? NSNumber)?.uint64Value }
            let name = IORegistry.string(service, "model") ?? IORegistry.string(service, "IOGLBundleName") ?? IORegistry.className(service)
            result.append(GPUDevice(name: name,
                                    coreCount: IORegistry.int(service, "gpu-core-count").map { Int($0) },
                                    deviceUtilization: d("Device Utilization %") ?? d("GPU Activity(%)"),
                                    rendererUtilization: d("Renderer Utilization %"),
                                    tilerUtilization: d("Tiler Utilization %"),
                                    inUseSystemMemory: u("In use system memory"),
                                    allocatedSystemMemory: u("Alloc system memory")))
        }
        return result
    }

    /// Reads per-process accumulated GPU time from AGX user clients (Apple Silicon only).
    /// Units: the counter advances in nanoseconds of GPU time (validated against device utilization).
    static func processCounters() -> [Int32: (name: String, apis: Set<String>, ns: UInt64)] {
        var result: [Int32: (name: String, apis: Set<String>, ns: UInt64)] = [:]
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            IORegistry.forEachChild(accelerator) { child in
                guard IORegistry.className(child).contains("UserClient"),
                      let creator = IORegistry.string(child, "IOUserClientCreator"),
                      let (pid, name) = parseCreator(creator) else { return }
                let usage = IORegistry.property(child, "AppUsage") as? [[String: Any]] ?? []
                var entry = result[pid] ?? (name, [], 0)
                for item in usage {
                    if let t = (item["accumulatedGPUTime"] as? NSNumber)?.uint64Value { entry.ns &+= t }
                    if let api = item["API"] as? String { entry.apis.insert(api) }
                }
                result[pid] = entry
            }
        }
        return result
    }

    /// Parses "pid 424, WindowServer".
    static func parseCreator(_ s: String) -> (Int32, String)? {
        guard s.hasPrefix("pid ") else { return nil }
        let rest = s.dropFirst(4)
        guard let comma = rest.firstIndex(of: ","), let pid = Int32(rest[..<comma]) else { return nil }
        let name = rest[rest.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return (pid, name)
    }
}

/// Stateful sampler: per-process GPU share is the delta of accumulated GPU time over wall time.
public struct GPUSampler: Sendable {
    private var previous: [Int32: UInt64] = [:]
    private var previousTime: Date?

    public init() {}

    /// `includeProcesses: false` skips the per-process walk (the expensive part) and keeps the previous baseline.
    public mutating func sample(includeProcesses: Bool = true) -> GPUSnapshot {
        let now = Date()
        let devices = GPUCollector.devices()
        guard includeProcesses else {
            let util = devices.compactMap(\.deviceUtilization).max()
            return GPUSnapshot(timestamp: now, devices: devices, processes: [],
                               utilization: util.map { Metric($0, .measuredUndocumented, source: "IOAccelerator PerformanceStatistics") }
                                   ?? .unavailable("IOAccelerator", "This GPU driver does not publish utilization statistics."),
                               processProvenance: .unavailable, notes: ["Per-process GPU time not sampled this tick."])
        }
        let counters = GPUCollector.processCounters()
        let interval = previousTime.map { now.timeIntervalSince($0) }
        var processes: [GPUProcessUsage] = []
        for (pid, c) in counters {
            var recent: Double?
            if let interval, interval > 0.2, let prev = previous[pid], c.ns >= prev {
                recent = Double(c.ns - prev) / (interval * 1e9) * 100
            }
            // IOUserClientCreator truncates names to 16 chars; prefer the executable name.
            let fullName = ProcessCollector.executablePath(pid).map { ($0 as NSString).lastPathComponent } ?? c.name
            processes.append(GPUProcessUsage(pid: pid, name: fullName, apis: c.apis.sorted(),
                                             accumulatedSeconds: Double(c.ns) / 1e9, recentPercent: recent))
        }
        previous = counters.mapValues(\.ns)
        previousTime = now
        processes.sort { ($0.recentPercent ?? -1, $0.accumulatedSeconds) > ($1.recentPercent ?? -1, $1.accumulatedSeconds) }

        var notes: [String] = []
        let util = devices.compactMap(\.deviceUtilization).max()
        let metric: Metric<Double> = util.map {
            Metric($0, .measuredUndocumented, source: "IOAccelerator PerformanceStatistics",
                   note: "Driver statistic exposed through IORegistry; not a documented Apple API.")
        } ?? .unavailable("IOAccelerator", "This GPU driver does not publish utilization statistics.")
        if counters.isEmpty {
            notes.append("Per-process GPU time is unavailable on this GPU/driver.")
        }
        notes.append("GPU power and per-process GPU memory require `sudo powermetrics` or private APIs and are not collected.")
        return GPUSnapshot(timestamp: now, devices: devices, processes: processes, utilization: metric,
                           processProvenance: counters.isEmpty ? .unavailable : .measuredUndocumented, notes: notes)
    }
}

extension GPUProcessUsage: Identifiable {
    public var id: Int32 { pid }
}
