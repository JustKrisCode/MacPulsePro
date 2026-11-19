import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case int(Int64), double(Double), text(String), null

    public var int: Int64? { if case .int(let v) = self { v } else if case .double(let d) = self { Int64(d) } else { nil } }
    public var double: Double? { if case .double(let v) = self { v } else if case .int(let i) = self { Double(i) } else { nil } }
    public var text: String? { if case .text(let v) = self { v } else { nil } }
}

/// Minimal thread-safe SQLite wrapper. All access is serialized through a lock.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw MacPulseError.failed("cannot open database \(path): \(msg)")
        }
        sqlite3_busy_timeout(handle, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA auto_vacuum=INCREMENTAL")
        chmod(path, 0o600)
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw MacPulseError.failed("sqlite: \(msg) in \(sql.prefix(80))")
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError(sql) }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs many statements in a single transaction (one fsync instead of N).
    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(sql) }
            let n = sqlite3_column_count(stmt)
            rows.append((0..<n).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, i)))
                default: .null
                }
            })
        }
        return rows
    }

    public func changes() -> Int { lock.lock(); defer { lock.unlock() }; return Int(sqlite3_changes(handle)) }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError(sql) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func lastError(_ sql: String) -> MacPulseError {
        .failed("sqlite: \(String(cString: sqlite3_errmsg(handle))) in \(sql.prefix(80))")
    }
}

extension Optional where Wrapped == Double { var sql: SQLValue { map { .double($0) } ?? .null } }
extension Optional where Wrapped == Int { var sql: SQLValue { map { .int(Int64($0)) } ?? .null } }
extension Optional where Wrapped == Int64 { var sql: SQLValue { map { .int($0) } ?? .null } }
extension Optional where Wrapped == UInt64 { var sql: SQLValue { map { .int(Int64(clamping: $0)) } ?? .null } }
extension Optional where Wrapped == String { var sql: SQLValue { map { .text($0) } ?? .null } }
extension Optional where Wrapped == Bool { var sql: SQLValue { map { .int($0 ? 1 : 0) } ?? .null } }
