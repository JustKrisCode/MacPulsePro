import AppKit
import CryptoKit
import Foundation

public struct CleanupCandidate: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var ruleID: String
    public var title: String
    public var category: CleanupCategory
    public var path: String
    public var classification: CleanupClass
    public var confidence: Level
    public var usage: DiskUsage
    public var modified: Date?
    public var owner: String?
    public var ownerBundleIDs: [String] = []
    public var ownerProcesses: [String] = []
    public var inUseBy: [String]
    public var reason: String
    public var consequence: String
    public var allowsDelete: Bool
    public var allowsTrash: Bool
    public var keepRoot: Bool
    public var target: ValidatedTarget?
    /// Set when the item cannot be cleaned right now (in use, permission, validation failure).
    public var blockedReason: String?
    /// Duplicate group; the cleaner refuses to remove every member of a group.
    public var groupID: String?

    public var estimatedBytes: Int64 { usage.allocated - usage.sharedHardLinkBytes }
    public var isSelectable: Bool { classification.isActionable && blockedReason == nil && target != nil }

    public static func == (a: CleanupCandidate, b: CleanupCandidate) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public static func makeID(rule: String, path: String) -> String {
        SHA256.hash(data: Data((rule + "\u{0}" + path).utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProtectedItem: Codable, Sendable, Identifiable {
    public var title: String
    public var path: String
    public var category: CleanupCategory
    public var usage: DiskUsage
    public var reason: String
    public var id: String { path }
}

public struct StorageAnalysis: Codable, Sendable {
    public var timestamp: Date
    public var durationSeconds: Double
    public var volume: VolumeSnapshot?
    public var candidates: [CleanupCandidate]
    public var protectedItems: [ProtectedItem]
    public var localSnapshots: [LocalSnapshotInfo]?
    public var containers: [APFSContainerInfo]
    public var notes: [String]

    public func bytes(_ cls: CleanupClass) -> Int64 {
        candidates.filter { $0.classification == cls }.map(\.estimatedBytes).reduce(0, +)
    }

    public var summary: CleanupSummary {
        let safe = candidates.filter { $0.classification == .safe && $0.blockedReason == nil }
        return CleanupSummary(safeBytes: safe.map(\.estimatedBytes).reduce(0, +),
                              reviewBytes: candidates.filter { $0.classification == .review }.map(\.estimatedBytes).reduce(0, +),
                              safeCount: safe.count)
    }

    public func byCategory() -> [(CleanupCategory, Int64)] {
        Dictionary(grouping: candidates, by: \.category).map { ($0.key, $0.value.map(\.estimatedBytes).reduce(0, +)) }
            .sorted { $0.1 > $1.1 }
    }
}

/// What is running right now — used to block cleanup of caches owned by live apps.
public struct RunningState: Sendable {
    public var bundleIDs: Set<String>
    public var processNames: Set<String>

    public init(bundleIDs: Set<String>, processNames: Set<String>) {
        self.bundleIDs = bundleIDs; self.processNames = processNames
    }

    public static func current() -> RunningState {
        let bundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var names = Set<String>()
        for p in ProcessCollector.kernelProcesses() { names.insert(p.comm) }
        return RunningState(bundleIDs: bundles, processNames: names)
    }

    public func users(of owner: Owner?) -> [String] {
        guard let owner else { return [] }
        var hits: [String] = []
        if owner.bundleIDs.contains(where: bundleIDs.contains) { hits.append(owner.display) }
        hits += owner.processNames.filter(processNames.contains)
        return hits
    }
}

public struct ScanOptions: Sendable {
    public var includePersonalFolders = false
    public var includeProtectedInventory = true
    public var includeSnapshots = true
    public var minimumBytes: Int64 = 1_000_000
    public init() {}
}

public struct CleanupScanner: Sendable {
    public var rules: [CleanupRule]
    public var runner: CommandRunner

    public init(rules: [CleanupRule] = CleanupCatalog.rules(), runner: CommandRunner = SystemCommandRunner()) {
        self.rules = rules; self.runner = runner
    }

    public var guardForRules: PathGuard { PathGuard(rules: rules) }

    struct Job: Sendable {
        var rule: CleanupRule
        var path: String
        var knowledge: ChildKnowledge?
    }

    public func scan(options: ScanOptions = ScanOptions(), running: RunningState = .current(),
                     cancel: CancellationFlag? = nil, now: Date = Date()) -> StorageAnalysis {
        let start = Date()
        var notes: [String] = []
        let guardian = PathGuard(rules: rules, allowPersonalFolders: options.includePersonalFolders)
        var jobs: [Job] = []
        let fm = FileManager.default
        for rule in rules {
            if rule.personal && !options.includePersonalFolders { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rule.root, isDirectory: &isDir) else { continue }
            switch rule.scope {
            case .wholeItem, .contents:
                jobs.append(Job(rule: rule, path: rule.root, knowledge: nil))
            case .children:
                guard isDir.boolValue else { continue }
                do {
                    for name in try fm.contentsOfDirectory(atPath: rule.root) where name != ".DS_Store" && name != ".localized" {
                        if let exts = rule.extensions, !exts.contains((name as NSString).pathExtension.lowercased()) { continue }
                        jobs.append(Job(rule: rule, path: rule.root + "/" + name, knowledge: rule.childClassifier?(name)))
                    }
                } catch {
                    notes.append("\(rule.title): cannot list \(rule.root) — \(Self.describe(error)). Grant Full Disk Access to include it.")
                }
            }
        }

        let results = LockedArray<CleanupCandidate>()
        let allJobs = jobs
        DispatchQueue.concurrentPerform(iterations: allJobs.count) { i in
            if cancel?.isCancelled == true { return }
            if let c = makeCandidate(allJobs[i], guardian: guardian, running: running, options: options, now: now, cancel: cancel) {
                results.append(c)
            }
        }

        var protectedItems: [ProtectedItem] = []
        if options.includeProtectedInventory {
            for loc in CleanupCatalog.protectedLocations() where fm.fileExists(atPath: loc.path) {
                if cancel?.isCancelled == true { break }
                protectedItems.append(ProtectedItem(title: loc.title, path: loc.path, category: loc.category,
                                                    usage: DiskUsageScanner.measure(loc.path, cancel: cancel), reason: loc.reason))
            }
        }
        var snapshots: [LocalSnapshotInfo]?
        var containers: [APFSContainerInfo] = []
        if options.includeSnapshots {
            snapshots = StorageCollector.localSnapshots(runner: runner)
            if snapshots == nil { notes.append("Local snapshots could not be listed (tmutil unavailable or denied).") }
            containers = StorageCollector.apfsContainers(runner: runner)
        }
        if cancel?.isCancelled == true { notes.append("Scan was cancelled; results are partial.") }
        return StorageAnalysis(timestamp: now, durationSeconds: Date().timeIntervalSince(start),
                               volume: StorageCollector.volume("/"),
                               candidates: results.values.sorted { $0.estimatedBytes > $1.estimatedBytes },
                               protectedItems: protectedItems.sorted { $0.usage.allocated > $1.usage.allocated },
                               localSnapshots: snapshots, containers: containers, notes: notes)
    }

    func makeCandidate(_ job: Job, guardian: PathGuard, running: RunningState, options: ScanOptions,
                       now: Date, cancel: CancellationFlag?) -> CleanupCandidate? {
        let rule = job.rule
        let k = job.knowledge
        let cls = k?.classification ?? rule.classification
        let owner = k?.owner ?? rule.owner
        var usage = DiskUsageScanner.measure(job.path, cancel: cancel)
        if rule.scope == .contents { usage.directories = max(0, usage.directories - 1) }
        guard usage.allocated >= options.minimumBytes else { return nil }
        let modified = usage.newestModification
        if let minAge = rule.minAgeDays, let m = modified, now.timeIntervalSince(m) < minAge * 86400 { return nil }

        var blocked: String?
        var target: ValidatedTarget?
        do {
            target = try guardian.validate(job.path)
            if target?.kind == .symlink { blocked = "Symbolic link — only real data is cleaned" }
        } catch {
            blocked = "\(error)"
        }
        let users = running.users(of: owner)
        if !users.isEmpty { blocked = "In use by \(users.joined(separator: ", ")) — quit it first" }
        if usage.permissionDenied > 0 && blocked == nil {
            blocked = "Some contents are not readable (\(usage.permissionDenied) items) — partial removal likely"
        }
        return CleanupCandidate(
            id: CleanupCandidate.makeID(rule: rule.id, path: job.path), ruleID: rule.id,
            title: k?.title ?? rule.title, category: k?.category ?? rule.category, path: job.path,
            classification: cls, confidence: k?.confidence ?? rule.confidence, usage: usage, modified: modified,
            owner: owner?.display, ownerBundleIDs: owner?.bundleIDs ?? [], ownerProcesses: owner?.processNames ?? [],
            inUseBy: users, reason: k?.reason ?? rule.reason,
            consequence: k?.consequence ?? rule.consequence, allowsDelete: rule.allowsDelete,
            allowsTrash: rule.allowsTrash, keepRoot: rule.scope == .contents, target: target, blockedReason: blocked)
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError) { return "permission denied" }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) { return "permission denied" }
        return ns.localizedDescription
    }
}

final class LockedArray<T: Sendable>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()
    func append(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
