import Foundation

public struct SystemSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var system: SystemInfo
    public var cpu: CPUSnapshot?
    public var memory: MemorySnapshot?
    public var gpu: GPUSnapshot
    public var thermal: ThermalSnapshot
    public var power: PowerSnapshot
    public var volume: VolumeSnapshot?
    /// Empty when processes were not requested.
    public var processes: [ProcessRecord]

    public func topProcesses(by key: ProcessSortKey, limit: Int = 10) -> [ProcessRecord] {
        Array(processes.sorted(by: key.comparator).prefix(limit))
    }
}

public enum ProcessSortKey: String, CaseIterable, Sendable {
    case cpu, memory, runtime, pid, name, energy, wakeups

    public var comparator: @Sendable (ProcessRecord, ProcessRecord) -> Bool {
        switch self {
        case .cpu: { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
        case .memory: { ($0.footprint ?? 0) > ($1.footprint ?? 0) }
        case .runtime: { $0.startTime < $1.startTime }
        case .pid: { $0.pid < $1.pid }
        case .name: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .energy: { ($0.powerWatts ?? -1) > ($1.powerWatts ?? -1) }
        case .wakeups: { ($0.wakeupsPerSecond ?? -1) > ($1.wakeupsPerSecond ?? -1) }
        }
    }
}

/// Owns all stateful samplers. Both the CLI and the app use this single engine.
public actor SystemSampler {
    private var cpu = CPUSampler()
    private var processes = ProcessSampler()
    private var gpu = GPUSampler()
    private let system = SystemInfo.current()
    private let runner: CommandRunner
    /// Free space is read cheaply (statfs) every `volumeCacheSeconds`; the purgeable estimate requires
    /// macOS's cache-delete service, which is expensive, so it is refreshed only every `purgeableRefreshSeconds`.
    private var cachedVolume: (Date, VolumeSnapshot?)?
    private var fullVolume: (Date, VolumeSnapshot)?
    public var volumeCacheSeconds: TimeInterval = 30
    public var purgeableRefreshSeconds: TimeInterval = 600

    private func volume() -> VolumeSnapshot? {
        let now = Date()
        if let (t, v) = cachedVolume, now.timeIntervalSince(t) < volumeCacheSeconds { return v }
        var v = StorageCollector.quickVolume("/")
        if fullVolume == nil || now.timeIntervalSince(fullVolume!.0) >= purgeableRefreshSeconds,
           let full = StorageCollector.volume("/") {
            fullVolume = (now, full)
        }
        if let full = fullVolume?.1, v != nil {
            v!.name = full.name
            v!.fileSystem = full.fileSystem
            v!.purgeableEstimate = full.purgeableEstimate
            if let p = full.purgeableEstimate.value { v!.availableForImportantUsage = v!.available + p }
        }
        cachedVolume = (now, v)
        return v
    }

    /// Forces the next snapshot to re-read volume capacity and purgeable space (e.g. after a cleanup).
    public func invalidateVolume() { cachedVolume = nil; fullVolume = nil }

    public init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    public func snapshot(includeProcesses: Bool = true, includePmset: Bool = false) -> SystemSnapshot {
        let cpuSnap = cpu.sample()
        let procs = includeProcesses ? processes.sample() : []
        return SystemSnapshot(timestamp: Date(), system: system, cpu: cpuSnap,
                              memory: MemoryCollector.snapshot(), gpu: gpu.sample(),
                              thermal: ThermalCollector.snapshot(includePmset: includePmset, runner: runner),
                              power: PowerCollector.snapshot(), volume: volume(),
                              processes: procs)
    }

    /// Takes a baseline, waits `interval`, and returns a snapshot with valid deltas (CPU %, GPU share).
    public func measured(interval: TimeInterval = 1.0, includeProcesses: Bool = true, includePmset: Bool = false) async -> SystemSnapshot {
        _ = snapshot(includeProcesses: includeProcesses)
        try? await Task.sleep(nanoseconds: UInt64(max(0.2, interval) * 1e9))
        return snapshot(includeProcesses: includeProcesses, includePmset: includePmset)
    }
}
