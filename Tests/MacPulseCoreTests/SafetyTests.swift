import Darwin
import Foundation
import Testing
@testable import MacPulseCore

@Suite("PathGuard — filesystem safety")
struct PathGuardTests {
    @Test func acceptsChildOfApprovedRoot() throws {
        let t = TempDir("pg")
        let root = t.dir("Caches")
        let item = t.file("Caches/app/data.bin")
        let g = PathGuard(allowedRoots: [root], home: t.path)
        let v = try g.validate((item as NSString).deletingLastPathComponent)
        #expect(v.kind == .directory)
    }

    @Test func rejectsRootItselfAndOutsidePaths() {
        let t = TempDir("pg")
        let root = t.dir("Caches")
        t.file("Other/x")
        let g = PathGuard(allowedRoots: [root], home: t.path)
        #expect(throws: MacPulseError.self) { try g.validate(root) }
        #expect(throws: MacPulseError.self) { try g.validate(t.path + "/Other/x") }
        #expect(throws: MacPulseError.self) { try g.validate(t.path) }
    }

    @Test func rejectsTraversalAndRelativeComponents() {
        let t = TempDir("pg")
        let root = t.dir("Caches")
        t.file("secret.txt")
        let g = PathGuard(allowedRoots: [root], home: t.path)
        #expect(throws: MacPulseError.self) { try g.validate(root + "/../secret.txt") }
        #expect(throws: MacPulseError.self) { try g.validate(root + "/./x") }
        #expect(throws: MacPulseError.self) { try g.validate("relative/path") }
    }

    @Test func rejectsSymlinkedParentEscapingTheRoot() throws {
        let t = TempDir("pg")
        let root = t.dir("Caches")
        let outside = t.dir("Outside")
        t.file("Outside/precious.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/escape", withDestinationPath: outside)
        let g = PathGuard(allowedRoots: [root], home: t.path)
        // The parent resolves outside the root, so the target is refused.
        #expect(throws: MacPulseError.self) { try g.validate(root + "/escape/precious.txt") }
        // The link itself is inside the root and is reported as a symlink (never followed).
        #expect(try g.validate(root + "/escape").kind == .symlink)
    }

    @Test func deniesPersonalFoldersGitAndSystemLocations() {
        let t = TempDir("pg")
        t.file("Documents/report.pages")
        t.file("proj/.git/objects/ab")
        let g = PathGuard(allowedRoots: [t.path + "/Documents", t.path + "/proj"], home: t.path)
        #expect(throws: MacPulseError.self) { try g.validate(t.path + "/Documents/report.pages") }
        #expect(throws: MacPulseError.self) { try g.validate(t.path + "/proj/.git/objects") }
        let sys = PathGuard(allowedRoots: ["/System/Library"], home: t.path)
        #expect(throws: MacPulseError.self) { try sys.validate("/System/Library/CoreServices") }
        let personal = PathGuard(allowedRoots: [t.path + "/Documents"], allowPersonalFolders: true, home: t.path)
        #expect((try? personal.validate(t.path + "/Documents/report.pages")) != nil)
    }

    @Test func exactApprovalAllowsOnlyThatPath() throws {
        let t = TempDir("pg")
        let cache = t.dir(".npm/_cacache")
        t.dir(".npm/_logs")
        let g = PathGuard(allowedRoots: [], allowedExact: [cache], home: t.path)
        #expect(try g.validate(cache).kind == .directory)
        #expect(throws: MacPulseError.self) { try g.validate(t.path + "/.npm/_logs") }
    }

    @Test func revalidationDetectsSwappedInode() throws {
        let t = TempDir("pg")
        let root = t.dir("Caches")
        let item = t.dir("Caches/app")
        let g = PathGuard(allowedRoots: [root], home: t.path)
        let before = try g.validate(item)
        try FileManager.default.removeItem(atPath: item)
        try FileManager.default.createSymbolicLink(atPath: item, withDestinationPath: "/")
        #expect(throws: MacPulseError.self) { try g.revalidate(before) }
    }

    @Test func handlesUnicodeWhitespaceAndQuotes() throws {
        let t = TempDir("pg")
        let root = t.dir("Caches")
        let weird = t.dir("Caches/My \"App\" café ☕️ 'q' $(rm -rf ~)")
        let g = PathGuard(allowedRoots: [root], home: t.path)
        #expect(try g.validate(weird).resolvedPath.hasSuffix("$(rm -rf ~)"))
    }
}

@Suite("SafeDeleter and Cleaner")
struct CleanerTests {
    func candidate(_ t: TempDir, _ path: String, root: String, cls: CleanupClass = .safe, keepRoot: Bool = false,
                   owner: Owner? = nil, group: String? = nil, guardian: PathGuard) -> CleanupCandidate {
        var usage = DiskUsageScanner.measure(path)
        if usage.allocated == 0 { usage.allocated = 1 }
        return CleanupCandidate(id: CleanupCandidate.makeID(rule: "t", path: path), ruleID: "test", title: "t", category: .applicationCache,
                                path: path, classification: cls, confidence: .high, usage: usage, modified: nil, owner: owner?.display,
                                ownerBundleIDs: owner?.bundleIDs ?? [], ownerProcesses: owner?.processNames ?? [], inUseBy: [],
                                reason: "", consequence: "", allowsDelete: true, allowsTrash: true, keepRoot: keepRoot,
                                target: try? guardian.validate(path), blockedReason: nil, groupID: group)
    }

    func cleaner(_ t: TempDir, roots: [String], exact: [String] = [], running: RunningState = .nothing, store: HistoryStore? = nil) -> Cleaner {
        Cleaner(guardian: PathGuard(allowedRoots: roots, allowedExact: exact, home: t.path), store: store,
                lockPath: t.path + "/cleanup.lock", runningState: { running })
    }

    @Test func deletesValidatedTreeAndMeasuresBytes() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/app/a.bin", bytes: 100_000)
        t.file("Caches/app/sub/b.bin", bytes: 50_000)
        let c = cleaner(t, roots: [root])
        let cand = candidate(t, root + "/app", root: root, guardian: c.guardian)
        let run = try c.run([cand], mode: .delete, dryRun: false)
        #expect(run.items.first?.status == .deleted)
        #expect(!t.exists("Caches/app"))
        #expect(t.exists("Caches"))
        #expect(run.removedTotal >= 150_000)
    }

    @Test func dryRunChangesNothing() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/app/a.bin")
        let c = cleaner(t, roots: [root])
        let run = try c.run([candidate(t, root + "/app", root: root, guardian: c.guardian)], mode: .delete, dryRun: true)
        #expect(run.items.first?.status == .dryRun)
        #expect(t.exists("Caches/app/a.bin"))
    }

    @Test func neverFollowsSymlinksOutOfTheTree() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        let precious = t.file("Precious/keep.txt")
        t.file("Caches/app/real.bin")
        try FileManager.default.createSymbolicLink(atPath: root + "/app/link-to-precious", withDestinationPath: t.path + "/Precious")
        try FileManager.default.createSymbolicLink(atPath: root + "/app/link-to-file", withDestinationPath: precious)
        let c = cleaner(t, roots: [root])
        let run = try c.run([candidate(t, root + "/app", root: root, guardian: c.guardian)], mode: .delete, dryRun: false)
        #expect(run.items.first?.status == .deleted)
        #expect(FileManager.default.fileExists(atPath: precious))
        #expect(!t.exists("Caches/app"))
    }

    @Test func hardLinkedFilesAreNotCountedAsFreed() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        let original = t.file("Elsewhere/big.bin", bytes: 200_000)
        t.dir("Caches/app")
        #expect(link(original, root + "/app/big.bin") == 0)
        let c = cleaner(t, roots: [root])
        let cand = candidate(t, root + "/app", root: root, guardian: c.guardian)
        #expect(cand.usage.sharedHardLinkBytes >= 200_000)
        let run = try c.run([cand], mode: .delete, dryRun: false)
        #expect(run.removedTotal < 100_000)
        #expect(FileManager.default.fileExists(atPath: original))
    }

    @Test func refusesProtectedAndUnknownClasses() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/p/x"); t.file("Caches/u/x")
        let c = cleaner(t, roots: [root])
        let run = try c.run([candidate(t, root + "/p", root: root, cls: .protected, guardian: c.guardian),
                             candidate(t, root + "/u", root: root, cls: .unknown, guardian: c.guardian)], mode: .delete, dryRun: false)
        #expect(run.items.allSatisfy { $0.status == .skipped })
        #expect(t.exists("Caches/p/x") && t.exists("Caches/u/x"))
    }

    @Test func skipsItemsOwnedByRunningApps() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/com.example.App/x")
        let running = RunningState(bundleIDs: ["com.example.App"], processNames: [])
        let c = cleaner(t, roots: [root], running: running)
        let cand = candidate(t, root + "/com.example.App", root: root, owner: Owner("Example", bundleIDs: ["com.example.App"]), guardian: c.guardian)
        let run = try c.run([cand], mode: .delete, dryRun: false)
        #expect(run.items.first?.status == .skipped)
        #expect(run.items.first?.message.contains("In use") == true)
        #expect(t.exists("Caches/com.example.App/x"))
    }

    @Test func skipsTargetsReplacedSinceScan() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/app/x")
        let c = cleaner(t, roots: [root])
        let cand = candidate(t, root + "/app", root: root, guardian: c.guardian)
        try FileManager.default.removeItem(atPath: root + "/app")
        t.file("Caches/app/new-content")   // same path, new inode
        let run = try c.run([cand], mode: .delete, dryRun: false)
        #expect(run.items.first?.status == .skipped)
        #expect(t.exists("Caches/app/new-content"))
    }

    @Test func concurrentCleanupIsRejected() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/app/x")
        let c = cleaner(t, roots: [root])
        let held = try CleanupLock(path: t.path + "/cleanup.lock")
        defer { held.release() }
        #expect(throws: MacPulseError.self) {
            try c.run([candidate(t, root + "/app", root: root, guardian: c.guardian)], mode: .delete, dryRun: false)
        }
        #expect(t.exists("Caches/app/x"))
    }

    @Test func cancellationStopsBeforeProcessing() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/a/x"); t.file("Caches/b/x")
        let c = cleaner(t, roots: [root])
        let flag = CancellationFlag()
        flag.cancel()
        let run = try c.run([candidate(t, root + "/a", root: root, guardian: c.guardian),
                             candidate(t, root + "/b", root: root, guardian: c.guardian)], mode: .delete, dryRun: false, cancel: flag)
        #expect(run.items.allSatisfy { $0.status == .cancelled })
        #expect(t.exists("Caches/a/x") && t.exists("Caches/b/x"))
    }

    @Test func permissionDeniedIsReportedNotHidden() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/app/locked/x")
        t.file("Caches/app/free.bin")
        chmod(root + "/app/locked", 0o555)       // cannot delete x inside
        let c = cleaner(t, roots: [root])
        let run = try c.run([candidate(t, root + "/app", root: root, guardian: c.guardian)], mode: .delete, dryRun: false)
        let item = try #require(run.items.first)
        #expect(item.status == .partiallyDeleted || item.status == .failed)
        #expect(item.message.contains("could not be removed"))
        #expect(t.exists("Caches/app/locked/x"))
        #expect(!t.exists("Caches/app/free.bin"))
    }

    @Test func keepRootRemovesOnlyContents() throws {
        let t = TempDir("cl")
        let trash = t.dir("FakeTrash")
        t.file("FakeTrash/one"); t.file("FakeTrash/two/three")
        let c = cleaner(t, roots: [trash], exact: [trash])
        let cand = candidate(t, trash, root: trash, keepRoot: true, guardian: c.guardian)
        let run = try c.run([cand], mode: .delete, dryRun: false)
        #expect(run.items.first?.status == .deleted)
        #expect(t.exists("FakeTrash"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash).isEmpty)
    }

    @Test func refusesToRemoveEveryDuplicateCopy() throws {
        let t = TempDir("cl")
        let root = t.dir("Files")
        t.file("Files/a.bin"); t.file("Files/b.bin")
        let c = cleaner(t, roots: [root])
        let g = "abc#2"
        let run = try c.run([candidate(t, root + "/a.bin", root: root, cls: .review, group: g, guardian: c.guardian),
                             candidate(t, root + "/b.bin", root: root, cls: .review, group: g, guardian: c.guardian)], mode: .delete, dryRun: false)
        #expect(run.items.allSatisfy { $0.status == .skipped })
        #expect(t.exists("Files/a.bin") && t.exists("Files/b.bin"))
    }

    @Test func auditLogRecordsRealRunsOnly() throws {
        let t = TempDir("cl")
        let root = t.dir("Caches")
        t.file("Caches/app/x")
        let store = try HistoryStore(path: t.path + "/db.sqlite")
        let c = cleaner(t, roots: [root], store: store)
        let cand = candidate(t, root + "/app", root: root, guardian: c.guardian)
        _ = try c.run([cand], mode: .delete, dryRun: true)
        #expect(try store.cleanupHistory().isEmpty)
        _ = try c.run([cand], mode: .delete, dryRun: false)
        let h = try store.cleanupHistory()
        #expect(h.count == 1 && h[0].status == "deleted" && h[0].path == root + "/app")
    }
}

@Suite("Disk accounting")
struct DiskUsageTests {
    @Test func sparseFileAllocatesLessThanLogicalSize() throws {
        let t = TempDir("du")
        let p = t.path + "/sparse.img"
        let fd = open(p, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        ftruncate(fd, 1_000_000_000)
        close(fd)
        let u = DiskUsageScanner.measure(p)
        #expect(u.logical == 1_000_000_000)
        #expect(u.allocated < 10_000_000)
    }

    @Test func countsFilesDirectoriesAndNewestModification() {
        let t = TempDir("du")
        let old = Date().addingTimeInterval(-86400 * 10)
        t.file("a/1", bytes: 1000, modified: old)
        let newest = Date().addingTimeInterval(-60)
        t.file("a/b/2", bytes: 1000, modified: newest)
        let u = DiskUsageScanner.measure(t.path + "/a")
        #expect(u.files == 2 && u.directories == 2)
        #expect(abs((u.newestModification?.timeIntervalSince1970 ?? 0) - newest.timeIntervalSince1970) < 2)
    }

    @Test func permissionDeniedDirectoriesAreCounted() {
        let t = TempDir("du")
        t.file("a/locked/x")
        chmod(t.path + "/a/locked", 0o000)
        let u = DiskUsageScanner.measure(t.path + "/a")
        #expect(u.permissionDenied >= 1)
    }

    @Test func privateSizeIsReportedOnAPFS() {
        let t = TempDir("du")
        let p = t.file("f.bin", bytes: 1_000_000)
        if let priv = DiskUsageScanner.privateSize(p) { #expect(priv > 0) }
    }

    @Test func clonedFilesShareStorage() throws {
        let t = TempDir("du")
        let src = t.file("src.bin", bytes: 4_000_000)
        let dst = t.path + "/clone.bin"
        guard clonefile(src, dst, 0) == 0 else { return } // not APFS: nothing to verify
        if let priv = DiskUsageScanner.privateSize(dst) { #expect(priv < 1_000_000) }
    }

    @Test func missingPathYieldsErrorNotCrash() {
        let u = DiskUsageScanner.measure("/nonexistent/\(UUID().uuidString)")
        #expect(u.allocated == 0)
    }
}

@Suite("Cleanup scanner")
struct ScannerTests {
    @Test func classifiesChildrenAppliesAgeAndExtensionFilters() {
        let t = TempDir("sc")
        let old = Date().addingTimeInterval(-86400 * 40)
        t.file("Caches/Homebrew/dl.tar", bytes: 2_000_000)
        t.file("Caches/com.example.thing/x", bytes: 2_000_000)
        t.file("Logs/old/a.log", bytes: 2_000_000, modified: old)
        t.file("Logs/new/a.log", bytes: 2_000_000)
        t.file("Downloads/setup.dmg", bytes: 2_000_000, modified: old)
        t.file("Downloads/photo.jpg", bytes: 2_000_000, modified: old)
        let rules = [
            CleanupRule(id: "c", title: "c", category: .applicationCache, root: t.path + "/Caches", scope: .children,
                        classification: .review, confidence: .medium, reason: "", consequence: "", allowsDelete: true,
                        childClassifier: CacheKnowledge.classify),
            CleanupRule(id: "l", title: "l", category: .logs, root: t.path + "/Logs", scope: .children, classification: .safe,
                        confidence: .medium, reason: "", consequence: "", minAgeDays: 30, allowsDelete: true),
            CleanupRule(id: "d", title: "d", category: .installers, root: t.path + "/Downloads", scope: .children,
                        classification: .review, confidence: .medium, reason: "", consequence: "", minAgeDays: 14,
                        extensions: ["dmg"], allowsDelete: false, personal: true),
        ]
        var opts = ScanOptions(); opts.includeSnapshots = false; opts.includeProtectedInventory = false
        let scanner = CleanupScanner(rules: rules, runner: MockCommandRunner())
        let a = scanner.scan(options: opts, running: .nothing)
        let paths = Set(a.candidates.map { ($0.path as NSString).lastPathComponent })
        #expect(paths == ["Homebrew", "com.example.thing", "old"])
        #expect(a.candidates.first { $0.path.hasSuffix("Homebrew") }?.classification == .safe)
        #expect(a.candidates.first { $0.path.hasSuffix("com.example.thing") }?.classification == .review)
        #expect(a.candidates.allSatisfy { $0.target != nil })
        opts.includePersonalFolders = true
        let b = scanner.scan(options: opts, running: .nothing)
        #expect(b.candidates.contains { $0.path.hasSuffix("setup.dmg") })
        #expect(!b.candidates.contains { $0.path.hasSuffix("photo.jpg") })
    }

    @Test func runningOwnerBlocksCandidate() {
        let t = TempDir("sc")
        t.file("Caches/Google/Chrome/x", bytes: 2_000_000)
        let rules = [CleanupRule(id: "c", title: "c", category: .applicationCache, root: t.path + "/Caches", scope: .children,
                                 classification: .review, confidence: .medium, reason: "", consequence: "", allowsDelete: true,
                                 childClassifier: CacheKnowledge.classify)]
        var opts = ScanOptions(); opts.includeSnapshots = false; opts.includeProtectedInventory = false
        let a = CleanupScanner(rules: rules, runner: MockCommandRunner())
            .scan(options: opts, running: RunningState(bundleIDs: ["com.google.Chrome"], processNames: []))
        let c = a.candidates.first
        #expect(c?.inUseBy == ["Google Chrome"])
        #expect(c?.isSelectable == false)
    }

    @Test func symlinkChildIsNeverSelectable() throws {
        let t = TempDir("sc")
        t.dir("Caches")
        t.file("Real/big", bytes: 3_000_000)
        try FileManager.default.createSymbolicLink(atPath: t.path + "/Caches/link", withDestinationPath: t.path + "/Real")
        let rules = [CleanupRule(id: "c", title: "c", category: .applicationCache, root: t.path + "/Caches", scope: .children,
                                 classification: .safe, confidence: .medium, reason: "", consequence: "", allowsDelete: true)]
        var opts = ScanOptions(); opts.includeSnapshots = false; opts.includeProtectedInventory = false; opts.minimumBytes = 0
        let a = CleanupScanner(rules: rules, runner: MockCommandRunner()).scan(options: opts, running: .nothing)
        #expect(a.candidates.allSatisfy { !$0.isSelectable })
    }

    @Test func catalogRulesNeverTargetProtectedLocations() {
        let home = NSHomeDirectory()
        for rule in CleanupCatalog.rules(home: home) {
            for bad in ["/Documents", "/Desktop", "/Pictures", "/Library/Application Support", "/Library/Keychains", "/.ssh"] {
                #expect(!rule.root.hasPrefix(home + bad), "rule \(rule.id) targets \(bad)")
            }
            #expect(rule.root != home)
        }
    }
}
