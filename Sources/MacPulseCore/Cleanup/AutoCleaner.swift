import Foundation

/// Opt-in scheduled cleanup of SAFE, rebuildable data only.
public struct AutoCleanConfig: Codable, Sendable, Equatable {
    public var enabled = false
    public var intervalDays: Double = 7
    /// `.delete` actually frees space; `.trash` keeps items recoverable until the Trash is emptied.
    public var mode: CleanupMode = .delete
    public var categories: [CleanupCategory] = [.developerCache, .logs]
    /// Items modified more recently than this are skipped (a tool may be using them).
    public var minIdleHours: Double = 24
    /// Items smaller than this are not worth touching.
    public var minItemBytes: Int64 = 10_000_000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoCleanConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        intervalDays = max(1, min(90, try c.decodeIfPresent(Double.self, forKey: .intervalDays) ?? d.intervalDays))
        mode = try c.decodeIfPresent(CleanupMode.self, forKey: .mode) ?? d.mode
        categories = (try c.decodeIfPresent([CleanupCategory].self, forKey: .categories) ?? d.categories)
            .filter { AutoCleaner.eligibleCategories.contains($0) }
        minIdleHours = max(1, try c.decodeIfPresent(Double.self, forKey: .minIdleHours) ?? d.minIdleHours)
        minItemBytes = max(0, try c.decodeIfPresent(Int64.self, forKey: .minItemBytes) ?? d.minItemBytes)
    }
}

public struct AutoCleanOutcome: Codable, Sendable {
    public var ranAt: Date
    public var dryRun: Bool
    public var selected: [CleanupCandidate]
    public var skipped: [SkippedItem]
    public var result: CleanupRunResult?

    public struct SkippedItem: Codable, Sendable {
        public var path: String
        public var reason: String
    }

    public var summary: String {
        guard let r = result else { return "Nothing eligible to clean." }
        let done = r.items.filter { $0.status == .deleted || $0.status == .trashed || $0.status == .dryRun }.count
        if dryRun { return "Would clean \(done) item(s), ≈ \(Format.bytes(r.estimatedTotal))." }
        let freed = r.mode == .delete ? "freed \(Format.bytes(r.removedTotal))" : "moved \(Format.bytes(r.trashedTotal)) to Trash"
        return "Cleaned \(done) of \(r.items.count) item(s), \(freed)."
    }
}

public enum AutoCleaner {
    /// Automatic cleanup may only ever touch these categories, and only SAFE items in them.
    public static let eligibleCategories: Set<CleanupCategory> = [.developerCache, .browserCache, .logs, .applicationCache]
    static let lastRunKey = "autoclean.lastRun"

    public static func isDue(_ config: AutoCleanConfig, lastRun: Date?, now: Date = Date()) -> Bool {
        guard config.enabled else { return false }
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= config.intervalDays * 86400
    }

    /// Pure selection logic (unit-tested): what an automatic run would clean, and why everything else is skipped.
    public static func select(_ analysis: StorageAnalysis, config: AutoCleanConfig, now: Date = Date())
        -> (selected: [CleanupCandidate], skipped: [AutoCleanOutcome.SkippedItem]) {
        var selected: [CleanupCandidate] = []
        var skipped: [AutoCleanOutcome.SkippedItem] = []
        let allowed = Set(config.categories).intersection(eligibleCategories)
        for c in analysis.candidates {
            func skip(_ r: String) { skipped.append(.init(path: c.path, reason: r)) }
            guard c.classification == .safe else { continue }   // REVIEW/PROTECTED/UNKNOWN are never considered
            guard allowed.contains(c.category) else { skip("category \(c.category.title) not enabled"); continue }
            guard c.isSelectable else { skip(c.blockedReason ?? "not selectable"); continue }
            guard c.estimatedBytes >= config.minItemBytes else { continue }
            if config.mode == .delete && !c.allowsDelete { skip("permanent deletion not allowed"); continue }
            if config.mode == .trash && !c.allowsTrash { skip("cannot be moved to Trash"); continue }
            if let m = c.modified, now.timeIntervalSince(m) < config.minIdleHours * 3600 {
                skip("used \(Format.duration(now.timeIntervalSince(m))) ago (needs \(Int(config.minIdleHours)) h idle)"); continue
            }
            selected.append(c)
        }
        return (selected, skipped)
    }

    public static func lastRun(_ store: HistoryStore) -> Date? {
        (try? store.meta(lastRunKey)).flatMap { $0 }.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    /// Scans, selects and cleans. Every item still passes the Cleaner's allowlist, in-use and inode checks.
    @discardableResult
    public static func run(config: AutoCleanConfig, store: HistoryStore?, dryRun: Bool,
                           scanner: CleanupScanner = CleanupScanner(), running: RunningState? = nil,
                           lockPath: String = AppPaths.cleanupLock, now: Date = Date()) throws -> AutoCleanOutcome {
        var opts = ScanOptions()
        opts.includePersonalFolders = false
        opts.includeProtectedInventory = false
        opts.includeSnapshots = false
        let state = running ?? RunningState.current()
        let analysis = scanner.scan(options: opts, running: state, now: now)
        let (selected, skipped) = select(analysis, config: config, now: now)
        var outcome = AutoCleanOutcome(ranAt: now, dryRun: dryRun, selected: selected, skipped: skipped, result: nil)
        if !selected.isEmpty {
            let cleaner = Cleaner(guardian: scanner.guardForRules, store: dryRun ? nil : store, lockPath: lockPath,
                                  runningState: { running ?? RunningState.current() })
            outcome.result = try cleaner.run(selected, mode: config.mode, dryRun: dryRun, runLabel: "auto")
        }
        if !dryRun, let store {
            try? store.setMeta(lastRunKey, String(now.timeIntervalSince1970))
            try? store.recordEvent(kind: "auto-clean", severity: .info, title: "Automatic cleanup", detail: outcome.summary, at: now)
        }
        return outcome
    }
}

extension HistoryStore {
    public func meta(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key=?", [.text(key)]).first?.first?.text
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [.text(key), .text(value)])
    }
}
