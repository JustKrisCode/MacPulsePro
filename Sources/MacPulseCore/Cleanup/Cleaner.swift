import Darwin
import Foundation

public enum CleanupMode: String, Codable, Sendable, CaseIterable {
    /// Move to the user's Trash (recoverable; space is freed when the Trash is emptied).
    case trash
    /// Permanent removal (only for items whose rule allows it).
    case delete
}

public struct CleanupItemResult: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case dryRun, trashed, deleted, partiallyDeleted, skipped, failed, cancelled }
    public var candidateID: String
    public var ruleID: String
    public var path: String
    public var classification: CleanupClass
    public var mode: CleanupMode
    public var status: Status
    public var estimatedBytes: Int64
    /// Measured: allocated bytes of inodes actually unlinked (last link only).
    public var removedBytes: Int64
    public var trashPath: String?
    public var message: String
    public var id: String { candidateID }
}

public struct CleanupRunResult: Codable, Sendable {
    public var runID: String
    public var dryRun: Bool
    public var mode: CleanupMode
    public var startedAt: Date
    public var finishedAt: Date
    public var items: [CleanupItemResult]
    public var freeBefore: Int64?
    public var freeAfter: Int64?
    /// Measured change in volume free space. Noisy: other processes write concurrently.
    public var measuredVolumeDelta: Int64? {
        guard let a = freeBefore, let b = freeAfter else { return nil }
        return b - a
    }
    public var estimatedTotal: Int64 { items.map(\.estimatedBytes).reduce(0, +) }
    public var removedTotal: Int64 { items.map(\.removedBytes).reduce(0, +) }
    public var trashedTotal: Int64 { items.filter { $0.status == .trashed }.map(\.estimatedBytes).reduce(0, +) }
    public var failures: Int { items.filter { $0.status == .failed || $0.status == .partiallyDeleted }.count }
}

enum SafeDeleter {
    struct Outcome { var removed: Int64 = 0; var failures: [String] = []; var cancelled = false }

    /// Post-order removal using fts with FTS_PHYSICAL (symlinks are unlinked, never followed) and
    /// FTS_XDEV (never crosses into another volume). Only st_dev-matching entries are touched.
    static func remove(_ path: String, keepRoot: Bool, device: Int64, cancel: CancellationFlag?) -> Outcome {
        var out = Outcome()
        guard let st = PathGuard.lstatInfo(path) else { out.failures.append("\(path): vanished"); return out }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            if unlink(path) == 0 { if st.st_nlink <= 1 { out.removed += Int64(st.st_blocks) * 512 } }
            else { out.failures.append("\(path): \(String(cString: strerror(errno)))") }
            return out
        }
        guard let cPath = strdup(path) else { return out }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            out.failures.append("\(path): cannot open"); return out
        }
        defer { fts_close(fts) }
        var count = 0
        while let ent = fts_read(fts) {
            count += 1
            if count & 255 == 0, cancel?.isCancelled == true { out.cancelled = true; break }
            let p = String(cString: ent.pointee.fts_path)
            let level = Int(ent.pointee.fts_level)
            switch Int32(ent.pointee.fts_info) {
            case FTS_D:
                if let s = ent.pointee.fts_statp?.pointee, Int64(s.st_dev) != device { fts_set(fts, ent, FTS_SKIP) }
            case FTS_DP:
                if level == 0 && keepRoot { continue }
                if rmdir(p) != 0 { out.failures.append("\(p): \(String(cString: strerror(errno)))") }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let s = ent.pointee.fts_statp?.pointee, Int64(s.st_dev) == device else { continue }
                if unlink(p) == 0 {
                    if s.st_nlink <= 1 { out.removed += Int64(s.st_blocks) * 512 }
                } else {
                    out.failures.append("\(p): \(String(cString: strerror(errno)))")
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                out.failures.append("\(p): \(String(cString: strerror(ent.pointee.fts_errno)))")
            default:
                break
            }
        }
        return out
    }
}

/// Executes approved cleanup. Every item is validated against the allowlist, re-checked for live
/// owners, and its inode identity is re-verified immediately before acting.
public struct Cleaner: Sendable {
    public var guardian: PathGuard
    public var store: HistoryStore?
    public var lockPath: String
    public var runningState: @Sendable () -> RunningState

    public init(guardian: PathGuard, store: HistoryStore?, lockPath: String = AppPaths.cleanupLock,
                runningState: @escaping @Sendable () -> RunningState = { RunningState.current() }) {
        self.guardian = guardian; self.store = store; self.lockPath = lockPath; self.runningState = runningState
    }

    public func run(_ candidates: [CleanupCandidate], mode: CleanupMode, dryRun: Bool,
                    cancel: CancellationFlag? = nil,
                    progress: (@Sendable (Int, Int, String) -> Void)? = nil) throws -> CleanupRunResult {
        let lock = dryRun ? nil : try CleanupLock(path: lockPath)
        defer { lock?.release() }
        let runID = UUID().uuidString.prefix(8).lowercased()
        let started = Date()
        let freeBefore = StorageCollector.volume("/")?.available
        let running = runningState()
        let fullGroups = duplicateGroupsSelectedEntirely(candidates)
        var items: [CleanupItemResult] = []

        for (i, c) in candidates.enumerated() {
            progress?(i, candidates.count, c.path)
            if cancel?.isCancelled == true {
                items.append(result(c, mode, .cancelled, "Cancelled before start")); continue
            }
            items.append(process(c, mode: mode, dryRun: dryRun, running: running, fullGroups: fullGroups, cancel: cancel))
        }
        let run = CleanupRunResult(runID: String(runID), dryRun: dryRun, mode: mode, startedAt: started, finishedAt: Date(),
                                   items: items, freeBefore: freeBefore,
                                   freeAfter: dryRun ? freeBefore : StorageCollector.volume("/")?.available)
        if !dryRun, let store {
            for item in items {
                try? store.recordCleanup(CleanupHistoryEntry(
                    id: 0, timestamp: run.finishedAt, runID: run.runID, ruleID: item.ruleID, path: item.path,
                    classification: item.classification.rawValue, method: item.mode.rawValue,
                    estimatedBytes: item.estimatedBytes, removedBytes: item.removedBytes, status: item.status.rawValue,
                    detail: item.message, trashPath: item.trashPath))
            }
        }
        return run
    }

    func duplicateGroupsSelectedEntirely(_ candidates: [CleanupCandidate]) -> Set<String> {
        // Callers pass only selected items plus `groupSize` encoded in the group id suffix "#n".
        var counts: [String: Int] = [:]
        for c in candidates { if let g = c.groupID { counts[g, default: 0] += 1 } }
        return Set(counts.compactMap { g, n in
            guard let total = g.split(separator: "#").last.flatMap({ Int($0) }) else { return nil }
            return n >= total ? g : nil
        })
    }

    func result(_ c: CleanupCandidate, _ mode: CleanupMode, _ status: CleanupItemResult.Status, _ msg: String,
                removed: Int64 = 0, trash: String? = nil) -> CleanupItemResult {
        CleanupItemResult(candidateID: c.id, ruleID: c.ruleID, path: c.path, classification: c.classification, mode: mode,
                          status: status, estimatedBytes: c.estimatedBytes, removedBytes: removed, trashPath: trash, message: msg)
    }

    func process(_ c: CleanupCandidate, mode: CleanupMode, dryRun: Bool, running: RunningState,
                 fullGroups: Set<String>, cancel: CancellationFlag?) -> CleanupItemResult {
        guard c.classification.isActionable else {
            return result(c, mode, .skipped, "\(c.classification.rawValue.capitalized) items are never cleaned")
        }
        if mode == .delete && !c.allowsDelete { return result(c, mode, .skipped, "Permanent deletion is not allowed for this item; use Trash") }
        if mode == .trash && !c.allowsTrash { return result(c, mode, .skipped, "This item can only be permanently deleted") }
        if let g = c.groupID, fullGroups.contains(g) {
            return result(c, mode, .skipped, "Refusing to remove every copy in a duplicate group — keep at least one")
        }
        guard let expected = c.target else { return result(c, mode, .skipped, c.blockedReason ?? "Not validated") }
        let owner = Owner(c.owner ?? "", bundleIDs: c.ownerBundleIDs, processNames: c.ownerProcesses)
        let users = running.users(of: owner)
        if !users.isEmpty { return result(c, mode, .skipped, "In use by \(users.joined(separator: ", "))") }
        let verified: ValidatedTarget
        do { verified = try guardian.revalidate(expected) } catch {
            return result(c, mode, .skipped, "\(error)")
        }
        if verified.kind == .symlink { return result(c, mode, .skipped, "Target is a symbolic link") }
        let parent = (verified.path as NSString).deletingLastPathComponent
        let writableDir = c.keepRoot ? verified.path : parent
        if access(writableDir, W_OK) != 0 {
            return result(c, mode, .skipped, "No write permission for \(writableDir)")
        }
        if dryRun {
            let verb = mode == .trash ? "move to Trash" : "permanently delete"
            return result(c, mode, .dryRun, "Would \(verb) \(Format.bytes(c.estimatedBytes)) (validated)")
        }
        // Final identity check right before the irreversible step.
        do { _ = try guardian.revalidate(verified) } catch { return result(c, mode, .skipped, "\(error)") }

        switch mode {
        case .trash:
            if c.keepRoot { return trashContents(c, verified) }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: verified.path), resultingItemURL: &resulting)
                return result(c, mode, .trashed, "Moved to Trash — space is freed when the Trash is emptied",
                              trash: resulting?.path)
            } catch {
                return result(c, mode, .failed, "Trash failed: \(error.localizedDescription)")
            }
        case .delete:
            let o = SafeDeleter.remove(verified.path, keepRoot: c.keepRoot, device: verified.device, cancel: cancel)
            if o.cancelled { return result(c, mode, .cancelled, "Cancelled; \(Format.bytes(o.removed)) removed so far", removed: o.removed) }
            if o.failures.isEmpty { return result(c, mode, .deleted, "Deleted", removed: o.removed) }
            let sample = o.failures.prefix(3).joined(separator: "; ")
            return result(c, mode, o.removed > 0 ? .partiallyDeleted : .failed,
                          "\(o.failures.count) items could not be removed: \(sample)", removed: o.removed)
        }
    }

    func trashContents(_ c: CleanupCandidate, _ dir: ValidatedTarget) -> CleanupItemResult {
        var failures = 0
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names {
            let child = dir.path + "/" + name
            guard (try? guardian.validate(child)) != nil else { failures += 1; continue }
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: child), resultingItemURL: nil) } catch { failures += 1 }
        }
        return result(c, .trash, failures == 0 ? .trashed : .partiallyDeleted,
                      failures == 0 ? "Contents moved to Trash" : "\(failures) of \(names.count) items could not be moved")
    }
}
