import Foundation
import Testing
@testable import MacPulseCore

@Suite("Automatic cleanup")
struct AutoCleanTests {
    func candidate(_ name: String, cls: CleanupClass = .safe, cat: CleanupCategory = .developerCache, bytes: Int64 = 50_000_000,
                   ageHours: Double = 48, blocked: String? = nil, allowsDelete: Bool = true) -> CleanupCandidate {
        var u = DiskUsage(); u.allocated = bytes
        return CleanupCandidate(id: name, ruleID: "r", title: name, category: cat, path: "/x/" + name, classification: cls,
                                confidence: .high, usage: u, modified: Date().addingTimeInterval(-ageHours * 3600), owner: nil,
                                inUseBy: [], reason: "", consequence: "", allowsDelete: allowsDelete, allowsTrash: true, keepRoot: false,
                                target: ValidatedTarget(path: "/x/" + name, resolvedPath: "/x/" + name, device: 1, inode: 1, kind: .directory),
                                blockedReason: blocked)
    }

    func analysis(_ c: [CleanupCandidate]) -> StorageAnalysis {
        StorageAnalysis(timestamp: Date(), durationSeconds: 0, volume: nil, candidates: c, protectedItems: [], localSnapshots: nil, containers: [], notes: [])
    }

    @Test func selectsOnlyIdleSafeItemsInEnabledCategories() {
        var cfg = AutoCleanConfig(); cfg.enabled = true
        let (sel, skipped) = AutoCleaner.select(analysis([
            candidate("ok"),
            candidate("review", cls: .review),
            candidate("protected", cls: .protected),
            candidate("browser", cat: .browserCache),
            candidate("fresh", ageHours: 2),
            candidate("tiny", bytes: 1000),
            candidate("inuse", blocked: "In use by X"),
            candidate("noDelete", allowsDelete: false),
        ]), config: cfg)
        #expect(sel.map(\.id) == ["ok"])
        #expect(Set(skipped.map { ($0.path as NSString).lastPathComponent }) == ["browser", "fresh", "inuse", "noDelete"])
    }

    @Test func dueOnlyWhenEnabledAndIntervalElapsed() {
        var cfg = AutoCleanConfig()
        #expect(!AutoCleaner.isDue(cfg, lastRun: nil))
        cfg.enabled = true
        #expect(AutoCleaner.isDue(cfg, lastRun: nil))
        #expect(!AutoCleaner.isDue(cfg, lastRun: Date().addingTimeInterval(-86400)))
        #expect(AutoCleaner.isDue(cfg, lastRun: Date().addingTimeInterval(-8 * 86400)))
    }

    @Test func configRejectsIneligibleCategoriesAndClamps() throws {
        let json = #"{"enabled": true, "intervalDays": 0, "categories": ["developerCache", "trash", "largeFile"]}"#
        let c = try JSONDecoder().decode(AutoCleanConfig.self, from: Data(json.utf8))
        #expect(c.categories == [.developerCache])
        #expect(c.intervalDays == 1)
        #expect(MacPulseConfig().autoClean.enabled == false)
    }

    @Test func endToEndCleansOnlyEligibleItemsAndAudits() throws {
        let t = TempDir("ac")
        let old = Date().addingTimeInterval(-3 * 86400)
        t.file("Caches/Homebrew/dl.bin", bytes: 20_000_000, modified: old)          // SAFE dev cache, idle → cleaned
        t.file("Caches/go-build/x.bin", bytes: 20_000_000)                          // SAFE but used just now → kept
        t.file("Caches/com.example.App/x.bin", bytes: 20_000_000, modified: old)    // REVIEW → never touched
        let rules = [CleanupRule(id: "c", title: "c", category: .applicationCache, root: t.path + "/Caches", scope: .children,
                                 classification: .review, confidence: .medium, reason: "", consequence: "", allowsDelete: true,
                                 childClassifier: CacheKnowledge.classify)]
        let store = try HistoryStore(path: t.path + "/h.sqlite")
        var cfg = AutoCleanConfig(); cfg.enabled = true
        let scanner = CleanupScanner(rules: rules, runner: MockCommandRunner())

        let preview = try AutoCleaner.run(config: cfg, store: store, dryRun: true, scanner: scanner, running: .nothing, lockPath: t.path + "/l")
        #expect(preview.result?.items.map { ($0.path as NSString).lastPathComponent } == ["Homebrew"])
        #expect(t.exists("Caches/Homebrew/dl.bin"))
        #expect(AutoCleaner.lastRun(store) == nil)

        let out = try AutoCleaner.run(config: cfg, store: store, dryRun: false, scanner: scanner, running: .nothing, lockPath: t.path + "/l")
        #expect(out.result?.items.first?.status == .deleted)
        #expect(!t.exists("Caches/Homebrew"))
        #expect(t.exists("Caches/go-build/x.bin"))
        #expect(t.exists("Caches/com.example.App/x.bin"))
        #expect(AutoCleaner.lastRun(store) != nil)
        let audit = try store.cleanupHistory()
        #expect(audit.count == 1 && audit[0].runID.hasPrefix("auto-"))
        #expect(try store.events(since: .distantPast).contains { $0.kind == "auto-clean" })
    }

    @Test func runningOwnerBlocksAutomaticCleanup() throws {
        let t = TempDir("ac")
        t.file("Caches/Homebrew/dl.bin", bytes: 20_000_000, modified: Date().addingTimeInterval(-3 * 86400))
        let rules = [CleanupRule(id: "c", title: "c", category: .applicationCache, root: t.path + "/Caches", scope: .children,
                                 classification: .review, confidence: .medium, reason: "", consequence: "", allowsDelete: true,
                                 childClassifier: CacheKnowledge.classify)]
        var cfg = AutoCleanConfig(); cfg.enabled = true
        let out = try AutoCleaner.run(config: cfg, store: nil, dryRun: false, scanner: CleanupScanner(rules: rules, runner: MockCommandRunner()),
                                      running: RunningState(bundleIDs: [], processNames: ["brew"]), lockPath: t.path + "/l")
        #expect(out.result == nil)
        #expect(t.exists("Caches/Homebrew/dl.bin"))
    }
}
