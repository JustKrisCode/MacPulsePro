import Darwin
import Foundation

public enum MemoryPressure: String, Codable, Sendable, Comparable {
    case normal, warning, critical, unknown

    /// kern.memorystatus_vm_pressure_level: 1 = normal, 2 = warning, 4 = critical.
    init(kernelLevel: Int64?) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    private var rank: Int { switch self { case .unknown: -1; case .normal: 0; case .warning: 1; case .critical: 2 } }
    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rank < b.rank }
}

public struct MemorySnapshot: Codable, Sendable {
    public var timestamp: Date
    public var physical: UInt64
    public var pageSize: UInt64
    /// Anonymous memory owned by processes, minus purgeable (Activity Monitor "App Memory").
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File-backed and purgeable pages that can be reclaimed quickly ("Cached Files").
    public var cachedFiles: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var purgeable: UInt64
    /// app + wired + compressed (Activity Monitor "Memory Used").
    public var used: UInt64 { app + wired + compressed }
    public var pressure: MemoryPressure
    /// kern.memorystatus_level — the "free percentage" reported by `memory_pressure`.
    public var availablePercent: Int?
    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var swapEncrypted: Bool
    /// Cumulative counters since boot.
    public var swapins: UInt64
    public var swapouts: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64
    public var pageins: UInt64
    public var pageouts: UInt64
}

public enum MemoryCollector {
    public static func snapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSizeRaw: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSizeRaw)
        let page = UInt64(pageSizeRaw == 0 ? 4096 : pageSizeRaw)
        let physical = UInt64(Sysctl.int("hw.memsize") ?? 0)

        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? (internalPages - purgeable) * page : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return MemorySnapshot(
            timestamp: Date(),
            physical: physical,
            pageSize: page,
            app: app,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cachedFiles: (UInt64(stats.external_page_count) + purgeable) * page,
            free: UInt64(stats.free_count) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            speculative: UInt64(stats.speculative_count) * page,
            purgeable: purgeable * page,
            pressure: MemoryPressure(kernelLevel: Sysctl.int("kern.memorystatus_vm_pressure_level")),
            availablePercent: Sysctl.int("kern.memorystatus_level").map { Int($0) },
            swapTotal: swapOK ? UInt64(swap.xsu_total) : 0,
            swapUsed: swapOK ? UInt64(swap.xsu_used) : 0,
            swapEncrypted: swapOK && swap.xsu_encrypted != 0,
            swapins: UInt64(stats.swapins),
            swapouts: UInt64(stats.swapouts),
            compressions: UInt64(stats.compressions),
            decompressions: UInt64(stats.decompressions),
            pageins: UInt64(stats.pageins),
            pageouts: UInt64(stats.pageouts))
    }
}
