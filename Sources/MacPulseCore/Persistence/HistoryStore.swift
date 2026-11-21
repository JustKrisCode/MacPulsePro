import Foundation

public enum AppPaths {
    public static var supportDirectory: String {
        if let override = ProcessInfo.processInfo.environment["MACPULSE_HOME"], !override.isEmpty { return override }
        return NSHomeDirectory() + "/Library/Application Support/MacPulsePro"
    }
    public static var database: String { supportDirectory + "/history.sqlite" }
    public static var config: String { supportDirectory + "/config.json" }
    public static var cleanupLock: String { supportDirectory + "/cleanup.lock" }
    public static var logDirectory: String { NSHomeDirectory() + "/Library/Logs/MacPulsePro" }
}

public struct StoredEvent: Codable, Sendable, Identifiable {
    public var id: Int64
    public var timestamp: Date
    public var kind: String
    public var severity: Severity
    public var title: String
    public var detail: String
}

public struct ProcessHistoryPoint: Codable, Sendable {
    public var timestamp: Date
    public var cpu: Double?
    public var footprint: UInt64?
    public var power: Double?
    public var wakeups: Double?
    public init(timestamp: Date, cpu: Double?, footprint: UInt64?, power: Double? = nil, wakeups: Double? = nil) {
        self.timestamp = timestamp; self.cpu = cpu; self.footprint = footprint; self.power = power; self.wakeups = wakeups
    }
}

public struct CleanupHistoryEntry: Codable, Sendable, Identifiable {
    public var id: Int64
    public var timestamp: Date
    public var runID: String
    public var ruleID: String
    public var path: String
    public var classification: String
    public var method: String
    public var estimatedBytes: Int64
    public var removedBytes: Int64
    public var status: String
    public var detail: String
    public var trashPath: String?
}

/// Persistent metric history, alerts and the cleanup audit log.
public final class HistoryStore: Sendable {
    public let db: Database
    static let schemaVersion: Int64 = 1

    public init(path: String = AppPaths.database) throws {
        db = try Database(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS samples(
            ts REAL PRIMARY KEY, cpu REAL, load1 REAL, mem_used INTEGER, compressed INTEGER, pressure INTEGER,
            swap_used INTEGER, swapouts INTEGER, gpu REAL, thermal INTEGER, disk_free INTEGER, battery INTEGER, on_ac INTEGER);
        CREATE TABLE IF NOT EXISTS process_samples(
            ts REAL NOT NULL, pid INTEGER NOT NULL, start INTEGER NOT NULL, name TEXT, cpu REAL, footprint INTEGER);
        CREATE INDEX IF NOT EXISTS process_samples_identity ON process_samples(pid, start, ts);
        CREATE INDEX IF NOT EXISTS process_samples_ts ON process_samples(ts);
        CREATE TABLE IF NOT EXISTS events(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT, severity TEXT, title TEXT, detail TEXT);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS cleanup_history(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, run_id TEXT, rule_id TEXT, path TEXT,
            classification TEXT, method TEXT, estimated INTEGER, removed INTEGER, status TEXT, detail TEXT, trash_path TEXT);
        """)
        try db.run("INSERT OR IGNORE INTO meta(key, value) VALUES('schema', ?)", [.text(String(Self.schemaVersion))])
        // v2: energy and wakeups per process sample (additive migration; old rows keep NULL).
        let cols = try db.query("PRAGMA table_info(process_samples)").compactMap { $0[safe: 1]?.text }
        if !cols.contains("power") { try db.execute("ALTER TABLE process_samples ADD COLUMN power REAL") }
        if !cols.contains("wakeups") { try db.execute("ALTER TABLE process_samples ADD COLUMN wakeups REAL") }
        try db.run("UPDATE meta SET value='2' WHERE key='schema'")
    }

    // MARK: samples

    public func record(_ s: HistorySample) throws {
        try db.run("""
        INSERT OR REPLACE INTO samples(ts,cpu,load1,mem_used,compressed,pressure,swap_used,swapouts,gpu,thermal,disk_free,battery,on_ac)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.double(s.timestamp.timeIntervalSince1970), s.cpu.sql, s.load1.sql, s.memoryUsed.sql, s.compressed.sql,
              s.pressure.sql, s.swapUsed.sql, s.swapouts.sql, s.gpu.sql, s.thermal.sql, s.diskFree.sql,
              s.battery.sql, s.onAC.sql])
    }

    public func samples(since: Date, limit: Int = 50_000) throws -> [HistorySample] {
        try db.query("""
        SELECT ts,cpu,load1,mem_used,compressed,pressure,swap_used,swapouts,gpu,thermal,disk_free,battery,on_ac
        FROM samples WHERE ts >= ? ORDER BY ts ASC LIMIT ?
        """, [.double(since.timeIntervalSince1970), .int(Int64(limit))]).map { r in
            HistorySample(timestamp: Date(timeIntervalSince1970: r[0].double ?? 0), cpu: r[1].double, load1: r[2].double,
                          memoryUsed: r[3].int.map { UInt64(max(0, $0)) }, compressed: r[4].int.map { UInt64(max(0, $0)) },
                          pressure: r[5].int.map { Int($0) }, swapUsed: r[6].int.map { UInt64(max(0, $0)) },
                          swapouts: r[7].int.map { UInt64(max(0, $0)) }, gpu: r[8].double, thermal: r[9].int.map { Int($0) },
                          diskFree: r[10].int, battery: r[11].int.map { Int($0) }, onAC: r[12].int.map { $0 != 0 })
        }
    }

    /// Records the top consumers only — the full process table is never persisted.
    public func recordProcesses(_ records: [ProcessRecord], at date: Date, topN: Int = 12) throws {
        let byCPU = records.sorted(by: ProcessSortKey.cpu.comparator).prefix(topN)
        let byMem = records.sorted(by: ProcessSortKey.memory.comparator).prefix(topN)
        let byEnergy = records.sorted(by: ProcessSortKey.energy.comparator).prefix(topN / 2)
        let byWakeups = records.sorted(by: ProcessSortKey.wakeups.comparator).prefix(topN / 2)
        var seen = Set<ProcessIdentity>()
        let selected = (byCPU + byMem + byEnergy + byWakeups).filter { seen.insert($0.identity).inserted }
        try db.transaction {
            for p in selected {
                try db.run("INSERT INTO process_samples(ts,pid,start,name,cpu,footprint,power,wakeups) VALUES(?,?,?,?,?,?,?,?)",
                           [.double(date.timeIntervalSince1970), .int(Int64(p.pid)), .int(p.startMicros),
                            .text(p.name), p.cpuPercent.sql, p.footprint.sql, p.powerWatts.sql, p.wakeupsPerSecond.sql])
            }
        }
    }

    public func processSeries(_ id: ProcessIdentity, since: Date) throws -> [ProcessHistoryPoint] {
        try db.query("SELECT ts,cpu,footprint FROM process_samples WHERE pid=? AND start=? AND ts>=? ORDER BY ts",
                     [.int(Int64(id.pid)), .int(id.startMicros), .double(since.timeIntervalSince1970)]).map {
            ProcessHistoryPoint(timestamp: Date(timeIntervalSince1970: $0[0].double ?? 0), cpu: $0[1].double,
                                footprint: $0[2].int.map { UInt64(max(0, $0)) })
        }
    }

    /// All process series since a date, grouped by identity (used for leak and runaway detection).
    public func processSeries(since: Date) throws -> [ProcessIdentity: (name: String, points: [ProcessHistoryPoint])] {
        var out: [ProcessIdentity: (name: String, points: [ProcessHistoryPoint])] = [:]
        for r in try db.query("SELECT pid,start,name,ts,cpu,footprint,power,wakeups FROM process_samples WHERE ts>=? ORDER BY ts",
                              [.double(since.timeIntervalSince1970)]) {
            let id = ProcessIdentity(pid: Int32(r[0].int ?? 0), startMicros: r[1].int ?? 0)
            var entry = out[id] ?? (r[2].text ?? "?", [])
            entry.points.append(ProcessHistoryPoint(timestamp: Date(timeIntervalSince1970: r[3].double ?? 0),
                                                    cpu: r[4].double, footprint: r[5].int.map { UInt64(max(0, $0)) },
                                                    power: r[6].double, wakeups: r[7].double))
            out[id] = entry
        }
        return out
    }

    // MARK: events

    @discardableResult
    public func recordEvent(kind: String, severity: Severity, title: String, detail: String, at date: Date = Date()) throws -> Int64 {
        try db.run("INSERT INTO events(ts,kind,severity,title,detail) VALUES(?,?,?,?,?)",
                   [.double(date.timeIntervalSince1970), .text(kind), .text(severity.rawValue), .text(title), .text(detail)])
    }

    public func events(since: Date, limit: Int = 500) throws -> [StoredEvent] {
        try db.query("SELECT id,ts,kind,severity,title,detail FROM events WHERE ts>=? ORDER BY ts DESC LIMIT ?",
                     [.double(since.timeIntervalSince1970), .int(Int64(limit))]).map {
            StoredEvent(id: $0[0].int ?? 0, timestamp: Date(timeIntervalSince1970: $0[1].double ?? 0),
                        kind: $0[2].text ?? "", severity: Severity(rawValue: $0[3].text ?? "") ?? .info,
                        title: $0[4].text ?? "", detail: $0[5].text ?? "")
        }
    }

    public func lastEvent(kind: String) throws -> Date? {
        try db.query("SELECT MAX(ts) FROM events WHERE kind=?", [.text(kind)]).first?.first?.double
            .map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: cleanup audit

    public func recordCleanup(_ e: CleanupHistoryEntry) throws {
        try db.run("""
        INSERT INTO cleanup_history(ts,run_id,rule_id,path,classification,method,estimated,removed,status,detail,trash_path)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        """, [.double(e.timestamp.timeIntervalSince1970), .text(e.runID), .text(e.ruleID), .text(e.path),
              .text(e.classification), .text(e.method), .int(e.estimatedBytes), .int(e.removedBytes),
              .text(e.status), .text(e.detail), e.trashPath.sql])
    }

    public func cleanupHistory(limit: Int = 500) throws -> [CleanupHistoryEntry] {
        try db.query("""
        SELECT id,ts,run_id,rule_id,path,classification,method,estimated,removed,status,detail,trash_path
        FROM cleanup_history ORDER BY ts DESC, id DESC LIMIT ?
        """, [.int(Int64(limit))]).map {
            CleanupHistoryEntry(id: $0[0].int ?? 0, timestamp: Date(timeIntervalSince1970: $0[1].double ?? 0),
                                runID: $0[2].text ?? "", ruleID: $0[3].text ?? "", path: $0[4].text ?? "",
                                classification: $0[5].text ?? "", method: $0[6].text ?? "",
                                estimatedBytes: $0[7].int ?? 0, removedBytes: $0[8].int ?? 0,
                                status: $0[9].text ?? "", detail: $0[10].text ?? "", trashPath: $0[11].text)
        }
    }

    // MARK: retention

    public struct PruneResult: Sendable { public var samples: Int; public var processSamples: Int; public var events: Int }

    /// Enforces retention by age and row count. The cleanup audit log is kept for 365 days.
    @discardableResult
    public func prune(retentionDays: Int, maxSamples: Int, now: Date = Date()) throws -> PruneResult {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970
        var r = PruneResult(samples: 0, processSamples: 0, events: 0)
        try db.run("DELETE FROM samples WHERE ts < ?", [.double(cutoff)]); r.samples = db.changes()
        try db.run("DELETE FROM samples WHERE ts NOT IN (SELECT ts FROM samples ORDER BY ts DESC LIMIT ?)", [.int(Int64(maxSamples))])
        r.samples += db.changes()
        try db.run("DELETE FROM process_samples WHERE ts < ?", [.double(cutoff)]); r.processSamples = db.changes()
        try db.run("DELETE FROM events WHERE ts < ?", [.double(cutoff)]); r.events = db.changes()
        try db.run("DELETE FROM cleanup_history WHERE ts < ?", [.double(now.addingTimeInterval(-365 * 86400).timeIntervalSince1970)])
        try db.execute("PRAGMA incremental_vacuum")
        return r
    }

    public func counts() throws -> (samples: Int, processSamples: Int, events: Int, cleanup: Int) {
        func c(_ t: String) throws -> Int { Int(try db.query("SELECT COUNT(*) FROM \(t)").first?.first?.int ?? 0) }
        return (try c("samples"), try c("process_samples"), try c("events"), try c("cleanup_history"))
    }

    public var fileSize: Int64 {
        let files = [db.path, db.path + "-wal", db.path + "-shm"]
        return files.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.int64Value }.reduce(0, +)
    }
}
