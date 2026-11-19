import Darwin
import Foundation
@testable import MacPulseCore

/// A self-cleaning temporary directory. All destructive tests operate only inside one of these.
final class TempDir {
    let path: String

    init(_ name: String = "mp") {
        let base = NSTemporaryDirectory() + "macpulse-tests-\(name)-\(UUID().uuidString.prefix(8))"
        try! FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        path = PathGuard.resolve(base)!
    }

    deinit {
        // Restore permissions changed by permission tests, then remove.
        if let e = FileManager.default.enumerator(atPath: path) {
            for case let rel as String in e { chmod(path + "/" + rel, 0o755) }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 4096, modified: Date? = nil) -> String {
        let p = path + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 0x5A, count: bytes))
        if let modified { try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: p) }
        return p
    }

    @discardableResult
    func dir(_ rel: String) -> String {
        let p = path + "/" + rel
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path + "/" + rel) }
}

enum Fixture {
    static func system() -> SystemInfo {
        SystemInfo(modelIdentifier: "Mac16,13", chip: "Apple M4", architecture: "arm64", osVersion: "27.2.0", osBuild: "T",
                   physicalMemory: 24 << 30, logicalCPUs: 10, performanceCores: 4, efficiencyCores: 6,
                   bootTime: Date().addingTimeInterval(-86400))
    }

    static func memory(pressure: MemoryPressure = .normal, swapUsed: UInt64 = 0, compressed: UInt64 = 1 << 30) -> MemorySnapshot {
        MemorySnapshot(timestamp: Date(), physical: 24 << 30, pageSize: 16384, app: 8 << 30, wired: 3 << 30,
                       compressed: compressed, cachedFiles: 5 << 30, free: 1 << 30, active: 6 << 30, inactive: 6 << 30,
                       speculative: 0, purgeable: 0, pressure: pressure, availablePercent: 50, swapTotal: 8 << 30,
                       swapUsed: swapUsed, swapEncrypted: true, swapins: 0, swapouts: 0, compressions: 0,
                       decompressions: 0, pageins: 0, pageouts: 0)
    }

    static func cpu(total: Double = 20, load: [Double] = [2, 2, 2]) -> CPUSnapshot {
        CPUSnapshot(timestamp: Date(), intervalSeconds: 1, total: total, user: total * 0.7, system: total * 0.3,
                    cores: (0..<10).map { CoreUsage(index: $0, cluster: $0 < 6 ? "E" : "P", user: total * 0.7, system: total * 0.3) },
                    loadAverage: load, logicalCPUs: 10)
    }

    static func volume(free: Int64 = 200_000_000_000, total: Int64 = 500_000_000_000) -> VolumeSnapshot {
        VolumeSnapshot(timestamp: Date(), mountPoint: "/", name: "Macintosh HD", fileSystem: "APFS", total: total,
                       available: free, availableForImportantUsage: free + 1_000_000_000, availableForOpportunisticUsage: free,
                       purgeableEstimate: Metric(1_000_000_000, .estimated, source: "test"))
    }

    static func process(pid: Int32, ppid: Int32 = 1, name: String = "proc", category: ProcessCategory = .userBackground,
                        cpu: Double? = 0, footprint: UInt64? = 50_000_000, path: String? = nil, tty: Bool = false,
                        started: Date = Date().addingTimeInterval(-7200), uid: UInt32 = getuid(), foreground: Bool = false,
                        bundle: String? = nil) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: ppid, pgid: pid, uid: uid, user: "tester", name: name, path: path ?? "/usr/local/bin/\(name)",
                      startTime: started, startMicros: Int64(started.timeIntervalSince1970 * 1e6), status: "running",
                      hasControllingTerminal: tty, category: category, bundleIdentifier: bundle, isForegroundApp: foreground,
                      accessible: true, cpuPercent: cpu, cpuTimeSeconds: 10, footprint: footprint, residentSize: footprint,
                      threads: 4, diskBytesRead: 0, diskBytesWritten: 0)
    }

    static func snapshot(memory: MemorySnapshot? = memory(), cpu: CPUSnapshot? = cpu(), thermal: ThermalState = .nominal,
                         volume: VolumeSnapshot? = volume(), gpu: Double? = 10, processes: [ProcessRecord] = []) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: Date(), system: system(), cpu: cpu, memory: memory,
            gpu: GPUSnapshot(timestamp: Date(), devices: [], processes: [],
                             utilization: gpu.map { Metric($0, .measuredUndocumented, source: "test") } ?? .unavailable("t", "t"),
                             processProvenance: .unavailable, notes: []),
            thermal: ThermalSnapshot(timestamp: Date(), state: thermal, lowPowerMode: false,
                                     cpuSpeedLimit: .unavailable("t", "t"), batteryTemperatureC: .unavailable("t", "t"),
                                     cpuTemperatureC: .unavailable("t", "t"),
                                     throttlingIndicator: ThrottlingIndicator(likely: false, provenance: .inferred, reasons: [])),
            power: PowerSnapshot(timestamp: Date(), hasBattery: false, source: "AC Power",
                                 healthPercent: .unavailable("t", "t"), batteryPowerW: .unavailable("t", "t")),
            volume: volume, processes: processes)
    }

    /// Hourly-spaced history with linearly growing swap.
    static func history(minutes: Int, every: Int = 1, swapStart: UInt64 = 1 << 30, swapPerMinute: UInt64 = 0,
                        cpu: Double = 20, thermal: Int = 0) -> [HistorySample] {
        let now = Date()
        return stride(from: minutes, through: 0, by: -every).map { m in
            HistorySample(timestamp: now.addingTimeInterval(-Double(m) * 60), cpu: cpu, load1: 2, memoryUsed: 10 << 30,
                          compressed: 1 << 30, pressure: 0, swapUsed: swapStart + UInt64(minutes - m) * swapPerMinute,
                          swapouts: UInt64(minutes - m) * 10, gpu: 10, thermal: thermal, diskFree: 100_000_000_000,
                          battery: 80, onAC: true)
        }
    }
}

extension RunningState {
    static let nothing = RunningState(bundleIDs: [], processNames: [])
}
