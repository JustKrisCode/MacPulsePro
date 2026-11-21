import Foundation
import Testing
@testable import MacPulseCore

@Suite("Incremental growth via FSEvents", .serialized)
struct FSEventsTests {
    /// fseventsd persists events asynchronously; poll until the change shows up in the journal.
    func waitForJournal(_ since: UInt64, root: String, contains dir: String) -> FSEventsHistory.Changes? {
        for _ in 0..<20 {
            if let c = FSEventsHistory.changes(since: since, root: root, timeout: 5), c.isDirty(dir) { return c }
            usleep(500_000)
        }
        return nil
    }

    @Test func journalReportsChangedDirectory() throws {
        let t = TempDir("fse")
        t.dir("a"); t.dir("b")
        let since = FSEventsHistory.currentEventID()
        t.file("a/new.bin", bytes: 10_000)
        let c = try #require(waitForJournal(since, root: t.path, contains: t.path + "/a"))
        #expect(c.isDirty(t.path + "/a"))
        #expect(!c.isDirty(t.path + "/b"))
    }

    @Test func incrementalScanMatchesFullScan() throws {
        let t = TempDir("fse")
        let before = FSEventsHistory.currentEventID()
        let dirs = ["one", "two", "three"].map { t.dir($0) }
        t.file("one/x.bin", bytes: 100_000); t.file("two/y.bin", bytes: 200_000); t.file("three/z.bin", bytes: 300_000)
        // Let fseventsd assign IDs to the setup writes first (it journals asynchronously).
        _ = waitForJournal(before, root: t.path, contains: t.path + "/three")
        usleep(1_500_000)
        let first = GrowthTracker.scan(home: t.path, targetsOverride: dirs)
        #expect(first.reusedCount == 0 && first.eventID != nil)

        t.file("two/more.bin", bytes: 5_000_000)             // grow one folder
        _ = waitForJournal(first.eventID!, root: t.path, contains: t.path + "/two")
        let incremental = GrowthTracker.scan(previous: first, home: t.path, targetsOverride: dirs)
        let full = GrowthTracker.scan(home: t.path, targetsOverride: dirs)

        #expect((incremental.reusedCount ?? 0) >= 1, "unchanged folders should be reused")
        let inc = Dictionary(uniqueKeysWithValues: incremental.folders.map { ($0.path, $0.bytes) })
        let ref = Dictionary(uniqueKeysWithValues: full.folders.map { ($0.path, $0.bytes) })
        #expect(inc == ref, "incremental sizes must equal a full rescan")
        #expect((inc[t.path + "/two"] ?? 0) > 5_000_000)
    }

    @Test func differentJournalForcesFullScan() {
        let t = TempDir("fse")
        let d = [t.dir("one")]
        var first = GrowthTracker.scan(home: t.path, targetsOverride: d)
        first.volumeUUID = "not-the-real-volume"
        let second = GrowthTracker.scan(previous: first, home: t.path, targetsOverride: d)
        #expect(second.reusedCount == 0)
    }
}
