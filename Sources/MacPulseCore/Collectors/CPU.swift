import Darwin
import Foundation
import IOKit

public struct CoreUsage: Codable, Sendable, Hashable {
    public var index: Int
    /// "P" (performance), "E" (efficiency) or nil when the cluster type cannot be read (Intel).
    public var cluster: String?
    public var user: Double
    public var system: Double
    public var total: Double { user + system }
}

public struct CPUSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var intervalSeconds: Double
    /// Whole-machine utilization, 0–100 (average over all logical CPUs).
    public var total: Double
    public var user: Double
    public var system: Double
    public var cores: [CoreUsage]
    /// 1, 5 and 15 minute load averages.
    public var loadAverage: [Double]
    public var logicalCPUs: Int

    public var performanceAverage: Double? { Self.average(cores.filter { $0.cluster == "P" }) }
    public var efficiencyAverage: Double? { Self.average(cores.filter { $0.cluster == "E" }) }

    static func average(_ cores: [CoreUsage]) -> Double? {
        cores.isEmpty ? nil : cores.map(\.total).reduce(0, +) / Double(cores.count)
    }
}

struct CPUTicks: Sendable, Equatable {
    var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
}

public enum CPUCollector {
    static func readTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(task_self_trap(), vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var result: [CPUTicks] = []
        result.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            result.append(CPUTicks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                                   system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                                   idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                                   nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return result
    }

    public static func loadAverages() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        return n == 3 ? loads : []
    }

    /// Maps logical CPU id → cluster type ("P"/"E") from the IODeviceTree. Empty on Intel.
    public static func clusterTypes() -> [Int: String] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var map: [Int: String] = [:]
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard let type = IORegistry.string(child, "cluster-type"),
                  let id = IORegistry.int(child, "logical-cpu-id") else { continue }
            map[Int(id)] = type
        }
        return map
    }

    static func usage(previous: [CPUTicks], current: [CPUTicks], clusters: [Int: String]) -> (cores: [CoreUsage], user: Double, system: Double) {
        var cores: [CoreUsage] = []
        var sumUser = 0.0, sumSystem = 0.0
        for (i, (a, b)) in zip(previous, current).enumerated() {
            // Counters are 32-bit and wrap; wrapping subtraction yields the correct delta.
            let user = Double(b.user &- a.user) + Double(b.nice &- a.nice)
            let system = Double(b.system &- a.system)
            let idle = Double(b.idle &- a.idle)
            let total = user + system + idle
            let u = total > 0 ? user / total * 100 : 0
            let s = total > 0 ? system / total * 100 : 0
            sumUser += u; sumSystem += s
            cores.append(CoreUsage(index: i, cluster: clusters[i], user: u, system: s))
        }
        let n = Double(max(cores.count, 1))
        return (cores, sumUser / n, sumSystem / n)
    }
}

/// Stateful CPU sampler: utilization is a delta between two tick readings.
public struct CPUSampler: Sendable {
    private var previous: [CPUTicks]?
    private var previousTime: Date?
    private let clusters: [Int: String]

    public init() {
        clusters = CPUCollector.clusterTypes()
        previous = CPUCollector.readTicks()
        previousTime = Date()
    }

    /// Returns nil on the first call if no baseline exists.
    public mutating func sample() -> CPUSnapshot? {
        guard let current = CPUCollector.readTicks() else { return nil }
        let now = Date()
        defer { previous = current; previousTime = now }
        guard let previous, let previousTime, previous.count == current.count else { return nil }
        let u = CPUCollector.usage(previous: previous, current: current, clusters: clusters)
        return CPUSnapshot(timestamp: now, intervalSeconds: now.timeIntervalSince(previousTime),
                           total: u.user + u.system, user: u.user, system: u.system, cores: u.cores,
                           loadAverage: CPUCollector.loadAverages(), logicalCPUs: current.count)
    }
}
