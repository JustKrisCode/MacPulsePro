import Foundation

public struct VolumeSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var mountPoint: String
    public var name: String?
    public var fileSystem: String?
    public var total: Int64
    /// Free space right now (statfs-equivalent).
    public var available: Int64
    /// Free space including purgeable data macOS can evict for important writes.
    public var availableForImportantUsage: Int64?
    public var availableForOpportunisticUsage: Int64?
    public var purgeableEstimate: Metric<Int64>
    public var used: Int64 { total - available }
    public var freePercent: Double { total > 0 ? Double(available) / Double(total) * 100 : 0 }
}

public struct APFSContainerInfo: Codable, Sendable {
    public var reference: String
    public var capacity: Int64
    public var free: Int64
    public var volumes: [APFSVolumeInfo]
}

public struct APFSVolumeInfo: Codable, Sendable {
    public var name: String
    public var roles: [String]
    public var used: Int64
}

public struct LocalSnapshotInfo: Codable, Sendable {
    public var name: String
    public var date: Date?
}

public enum StorageCollector {
    /// Cheap capacity read via statfs (no purgeable computation). Suitable for polling.
    public static func quickVolume(_ path: String = "/") -> VolumeSnapshot? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let block = Int64(st.f_bsize)
        let fsType = withUnsafeBytes(of: st.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return VolumeSnapshot(timestamp: Date(), mountPoint: path, name: nil, fileSystem: fsType.uppercased(),
                              total: Int64(st.f_blocks) * block, available: Int64(st.f_bavail) * block,
                              availableForImportantUsage: nil, availableForOpportunisticUsage: nil,
                              purgeableEstimate: .unavailable("statfs", "Purgeable space is refreshed periodically."))
    }

    /// Full read including purgeable space. Expensive (macOS consults its cache-delete service): call rarely.
    public static func volume(_ path: String = "/") -> VolumeSnapshot? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityForOpportunisticUsageKey,
                                         .volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let available = v.volumeAvailableCapacity else { return nil }
        let important = v.volumeAvailableCapacityForImportantUsage
        let purgeable: Metric<Int64> = important.map {
            Metric(max(0, $0 - Int64(available)), .estimated,
                   source: "availableForImportantUsage − available",
                   note: "Space macOS reports it could free (caches, snapshots, iCloud-evictable files).")
        } ?? .unavailable("URLResourceValues", "Important-usage capacity not reported.")
        return VolumeSnapshot(timestamp: Date(), mountPoint: path, name: v.volumeLocalizedName,
                              fileSystem: v.volumeLocalizedFormatDescription,
                              total: Int64(total), available: Int64(available),
                              availableForImportantUsage: important,
                              availableForOpportunisticUsage: v.volumeAvailableCapacityForOpportunisticUsage,
                              purgeableEstimate: purgeable)
    }

    /// Spawns `diskutil` — call on demand, never from a polling loop.
    public static func apfsContainers(runner: CommandRunner = SystemCommandRunner()) -> [APFSContainerInfo] {
        let r = runner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 15)
        guard r.ok else { return [] }
        return parseAPFSList(Data(r.stdout.utf8))
    }

    static func parseAPFSList(_ data: Data) -> [APFSContainerInfo] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return [] }
        return containers.map { c in
            let vols = (c["Volumes"] as? [[String: Any]] ?? []).map { v in
                APFSVolumeInfo(name: v["Name"] as? String ?? "?", roles: v["Roles"] as? [String] ?? [],
                               used: (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0)
            }
            return APFSContainerInfo(reference: c["ContainerReference"] as? String ?? "?",
                                     capacity: (c["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0,
                                     free: (c["CapacityFree"] as? NSNumber)?.int64Value ?? 0,
                                     volumes: vols)
        }
    }

    /// Local Time Machine snapshots. Sizes are not exposed without root, so only names/dates are returned.
    public static func localSnapshots(runner: CommandRunner = SystemCommandRunner()) -> [LocalSnapshotInfo]? {
        let r = runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15)
        guard r.ok else { return nil }
        return parseSnapshots(r.stdout)
    }

    static func parseSnapshots(_ text: String) -> [LocalSnapshotInfo] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("com.apple.") else { return nil }
            let base = s.hasSuffix(".local") ? String(s.dropLast(6)) : s
            let datePart = base.split(separator: ".").last.map(String.init)
            return LocalSnapshotInfo(name: s, date: datePart.flatMap { f.date(from: $0) })
        }
    }
}

public struct SystemInfo: Codable, Sendable {
    public var modelIdentifier: String
    public var chip: String
    public var architecture: String
    public var osVersion: String
    public var osBuild: String?
    public var physicalMemory: UInt64
    public var logicalCPUs: Int
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var bootTime: Date?
    public var uptimeSeconds: TimeInterval { bootTime.map { Date().timeIntervalSince($0) } ?? ProcessInfo.processInfo.systemUptime }

    public static func current() -> SystemInfo {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let levels = Sysctl.int("hw.nperflevels") ?? 0
        return SystemInfo(
            modelIdentifier: Sysctl.string("hw.model") ?? "unknown",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "unknown",
            architecture: arch,
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            osBuild: Sysctl.string("kern.osversion"),
            physicalMemory: UInt64(Sysctl.int("hw.memsize") ?? 0),
            logicalCPUs: Int(Sysctl.int("hw.logicalcpu") ?? Int64(ProcessInfo.processInfo.processorCount)),
            performanceCores: levels >= 1 ? Sysctl.int("hw.perflevel0.logicalcpu").map { Int($0) } : nil,
            efficiencyCores: levels >= 2 ? Sysctl.int("hw.perflevel1.logicalcpu").map { Int($0) } : nil,
            bootTime: Sysctl.bootTime())
    }
}
