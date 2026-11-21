import Foundation

/// Records folder sizes over time so "where did my free space go?" has a measured answer.
public struct FolderSize: Codable, Sendable, Identifiable {
    public var path: String
    public var bytes: Int64
    public var id: String { path }
}

public struct GrowthScan: Codable, Sendable {
    public var id: String
    public var timestamp: Date
    public var folders: [FolderSize]
    /// Space used by swap files (lives on the startup volume).
    public var swapFileBytes: Int64?
    public var volumeUsed: Int64?
    public var localSnapshotCount: Int?
    public var durationSeconds: Double
    public var unreadable: [String]
    /// FSEvents journal position taken at the start of the scan (enables incremental rescans).
    public var eventID: UInt64? = nil
    public var volumeUUID: String? = nil
    public var includedPersonal: Bool? = nil
    /// How many folders were walked vs. reused unchanged from the previous scan.
    public var measuredCount: Int? = nil
    public var reusedCount: Int? = nil
    public var incremental: Bool { (reusedCount ?? 0) > 0 }
}

public struct GrowthEntry: Codable, Sendable, Identifiable {
    public var path: String
    public var before: Int64?
    public var after: Int64?
    public var delta: Int64 { (after ?? 0) - (before ?? 0) }
    public var id: String { path }
}

public struct GrowthReport: Codable, Sendable {
    public var from: Date
    public var to: Date
    public var entries: [GrowthEntry]
    public var volumeUsedDelta: Int64?
    public var swapDelta: Int64?
    public var trackedDelta: Int64
    /// Volume change not explained by tracked folders or swap (system files, other users, snapshots, untracked folders).
    public var unattributedDelta: Int64?
}

public enum GrowthTracker {
    /// Folders measured. Privacy-protected locations (Documents, Desktop, Downloads, media, Mail, Containers…) are
    /// only included with `includePersonal`, because reading them triggers macOS permission prompts.
    public static func targets(home: String = NSHomeDirectory(), includePersonal: Bool) -> [String] {
        let fm = FileManager.default
        let personal: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public"]
        let skipHome: Set<String> = ["Library", ".Trash"]
        let skipLibrary: Set<String> = ["Containers", "Group Containers", "Mail", "Messages", "Safari", "Mobile Documents",
                                        "CloudStorage", "Photos", "Calendars", "Cookies", "Accounts", "Biome", "DuetExpertCenter",
                                        "Suggestions", "IdentityServices", "Metadata", "PersonalizationPortrait", "Sharing", "Reminders",
                                        "HomeKit", "Autosave Information", "Daemon Containers", "Application Scripts"]
        var out: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: home)) ?? [] where !skipHome.contains(name) {
            if personal.contains(name) && !includePersonal { continue }
            out.append(home + "/" + name)
        }
        let lib = home + "/Library"
        for name in (try? fm.contentsOfDirectory(atPath: lib)) ?? [] where !skipLibrary.contains(name) {
            out.append(lib + "/" + name)
        }
        // One level deeper where growth usually hides.
        for sub in ["Application Support", "Caches", "Developer"] {
            for name in (try? fm.contentsOfDirectory(atPath: lib + "/" + sub)) ?? [] where name != ".DS_Store" {
                out.append(lib + "/" + sub + "/" + name)
            }
        }
        return out.filter { p in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Measures folder sizes. With `previous`, only folders the FSEvents journal reports as changed are
    /// walked again; everything else reuses the previous size. Falls back to a full scan whenever the
    /// journal cannot answer reliably (different volume journal, wrapped IDs, dropped events, timeout).
    public static func scan(includePersonal: Bool = false, previous: GrowthScan? = nil, cancel: CancellationFlag? = nil,
                            runner: CommandRunner = SystemCommandRunner(), home: String = NSHomeDirectory(),
                            targetsOverride: [String]? = nil) -> GrowthScan {
        let start = Date()
        let eventID = FSEventsHistory.currentEventID()
        let uuid = FSEventsHistory.volumeUUID(for: home)
        let paths = targetsOverride ?? targets(home: home, includePersonal: includePersonal)

        var reuse: [String: Int64] = [:]
        if let previous, let since = previous.eventID, previous.volumeUUID == uuid, uuid != nil,
           (previous.includedPersonal ?? false) == includePersonal,
           let changes = FSEventsHistory.changes(since: since, root: home), !changes.fullRescan {
            let old = Dictionary(previous.folders.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
            for p in paths where !changes.isDirty(p) {
                if let b = old[p] { reuse[p] = b }
            }
        }
        let toMeasure = paths.filter { reuse[$0] == nil }
        let results = LockedArray<FolderSize>()
        let unreadable = LockedArray<String>()
        DispatchQueue.concurrentPerform(iterations: toMeasure.count) { i in
            if cancel?.isCancelled == true { return }
            let u = DiskUsageScanner.measure(toMeasure[i], cancel: cancel)
            if u.permissionDenied > 0 && u.allocated == 0 { unreadable.append(toMeasure[i]); return }
            results.append(FolderSize(path: toMeasure[i], bytes: u.allocated))
        }
        let folders = results.values + reuse.map { FolderSize(path: $0.key, bytes: $0.value) }
        let mem = MemoryCollector.snapshot()
        let vol = StorageCollector.quickVolume("/")
        return GrowthScan(id: String(UUID().uuidString.prefix(8).lowercased()), timestamp: Date(),
                          folders: folders.sorted { $0.bytes > $1.bytes },
                          swapFileBytes: mem.map { Int64($0.swapTotal) }, volumeUsed: vol?.used,
                          localSnapshotCount: StorageCollector.localSnapshots(runner: runner)?.count,
                          durationSeconds: Date().timeIntervalSince(start), unreadable: unreadable.values.sorted(),
                          eventID: eventID, volumeUUID: uuid, includedPersonal: includePersonal,
                          measuredCount: toMeasure.count, reusedCount: reuse.count)
    }

    public static func compare(_ old: GrowthScan, _ new: GrowthScan) -> GrowthReport {
        let a = Dictionary(old.folders.map { ($0.path, $0.bytes) }, uniquingKeysWith: { x, _ in x })
        let b = Dictionary(new.folders.map { ($0.path, $0.bytes) }, uniquingKeysWith: { x, _ in x })
        let lib = NSHomeDirectory() + "/Library/"
        func isNested(_ p: String) -> Bool { p.hasPrefix(lib) && String(p.dropFirst(lib.count)).contains("/") }
        var entries = Set(a.keys).union(b.keys).map { GrowthEntry(path: $0, before: a[$0], after: b[$0]) }
        entries.sort { abs($0.delta) > abs($1.delta) }
        // Only top-level entries are summed, so nested folders are not double-counted.
        let tracked = entries.filter { !isNested($0.path) }.map(\.delta).reduce(0, +)
        let volDelta = old.volumeUsed.flatMap { o in new.volumeUsed.map { $0 - o } }
        let swapDelta = old.swapFileBytes.flatMap { o in new.swapFileBytes.map { $0 - o } }
        return GrowthReport(from: old.timestamp, to: new.timestamp, entries: entries.filter { $0.delta != 0 },
                            volumeUsedDelta: volDelta, swapDelta: swapDelta, trackedDelta: tracked,
                            unattributedDelta: volDelta.map { $0 - tracked - (swapDelta ?? 0) })
    }
}

extension HistoryStore {
    func ensureGrowthTable() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS growth_scans(id TEXT PRIMARY KEY, ts REAL NOT NULL, json TEXT NOT NULL);
        """)
    }

    /// Stores a scan (JSON) and keeps the most recent 60.
    public func recordGrowthScan(_ scan: GrowthScan) throws {
        try ensureGrowthTable()
        let json = JSON.string(scan, pretty: false)
        try db.run("INSERT OR REPLACE INTO growth_scans(id, ts, json) VALUES(?,?,?)",
                   [.text(scan.id), .double(scan.timestamp.timeIntervalSince1970), .text(json)])
        try db.run("DELETE FROM growth_scans WHERE id NOT IN (SELECT id FROM growth_scans ORDER BY ts DESC LIMIT 60)")
    }

    public func growthScans(limit: Int = 60) throws -> [GrowthScan] {
        try ensureGrowthTable()
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try db.query("SELECT json FROM growth_scans ORDER BY ts DESC LIMIT ?", [.int(Int64(limit))]).compactMap {
            $0.first?.text.flatMap { try? d.decode(GrowthScan.self, from: Data($0.utf8)) }
        }
    }
}
