import Foundation
import Testing
@testable import MacPulseCore

@Suite("Slowdown detective")
struct SlowdownTests {
    @Test func baselineComparisonUsesRealByteValues() throws {
        // Regression: UInt64 → Double must convert values, not reinterpret bit patterns.
        let history = Fixture.history(minutes: 120, every: 5)
        let d = SlowdownDetective.diagnose(.init(snapshot: Fixture.snapshot(), history: history))
        let mem = try #require(d.changes.first { $0.metric == "Memory used" })
        #expect(mem.baseline == "10.00 GB")
        #expect(d.baselineDescription.hasPrefix("Median of"))
    }

    @Test func memoryPressureIsTheBottleneckAndNamesTheHog() {
        let hog = Fixture.process(pid: 77, name: "Heavy", category: .application, footprint: 8 << 30,
                                  path: "/Applications/Heavy.app/Contents/MacOS/Heavy", bundle: "x.heavy")
        let snap = Fixture.snapshot(memory: Fixture.memory(pressure: .critical, swapUsed: 6 << 30), processes: [hog])
        let d = SlowdownDetective.diagnose(.init(snapshot: snap))
        #expect(d.bottleneck == .memory)
        #expect(d.causes.contains { $0.kind == .memoryHog && $0.relatedPIDs == [77] })
    }

    @Test func idleSystemHasNoBottleneck() {
        let d = SlowdownDetective.diagnose(.init(snapshot: Fixture.snapshot(cpu: Fixture.cpu(total: 5, load: [1, 1, 1]))))
        #expect(d.bottleneck == .none)
        #expect(!d.causes.contains { $0.impact == .high })
    }

    @Test func newHeavyProcessSinceBaselineIsReported() {
        let fresh = Fixture.process(pid: 88, name: "renderer", cpu: 180, started: Date().addingTimeInterval(-300))
        let snap = Fixture.snapshot(cpu: Fixture.cpu(total: 50), processes: [fresh])
        let d = SlowdownDetective.diagnose(.init(snapshot: snap, history: Fixture.history(minutes: 120, every: 5)))
        #expect(d.causes.contains { $0.kind == .newHeavyProcess && $0.relatedPIDs == [88] })
        #expect(d.causes.contains { $0.kind == .cpuHog })
    }

    @Test func swappingImpactScalesWithVolumeNotPageCount() {
        // ~500 page-outs/min × 16 KB ≈ 8 MB/min: light, must not be "high impact" or contradict an all-clear.
        let light = Fixture.history(minutes: 30).enumerated().map { i, h -> HistorySample in
            var x = h; x.swapouts = UInt64(i) * 500; return x
        }
        var calm = Fixture.snapshot(cpu: Fixture.cpu(total: 5, load: [1, 1, 1]))
        calm.memory?.swapouts = light.last!.swapouts!     // cumulative counter continues from history
        let d = SlowdownDetective.diagnose(.init(snapshot: calm, history: light))
        let swap = d.causes.first { $0.kind == .swapping }
        #expect(swap?.impact == .low)
        #expect(d.isClear)
        #expect((d.pressure["memory"] ?? 100) < 20)
        // ~8000 page-outs/min ≈ 125 MB/min: heavy.
        let heavy = light.enumerated().map { i, h -> HistorySample in var x = h; x.swapouts = UInt64(i) * 8000; return x }
        var busy = Fixture.snapshot()
        busy.memory?.swapouts = heavy.last!.swapouts!
        let d2 = SlowdownDetective.diagnose(.init(snapshot: busy, history: heavy))
        #expect(d2.causes.first { $0.kind == .swapping }?.impact == .high)
        #expect(!d2.isClear)
    }

    @Test func moderateCPUIsNotCalledSaturated() {
        let d = SlowdownDetective.diagnose(.init(snapshot: Fixture.snapshot(cpu: Fixture.cpu(total: 62, load: [30, 20, 10]))))
        #expect(d.bottleneck == .cpu)
        #expect(!d.verdict.contains("saturated"))
    }
}

@Suite("Readiness gate")
struct ReadinessTests {
    @Test func coolIdleMacIsReady() {
        let r = Readiness.evaluate([Fixture.snapshot(cpu: Fixture.cpu(total: 10))])
        #expect(r.ready && r.blockers.isEmpty)
    }

    @Test func heatPressureAndCPUBlock() {
        let hot = Fixture.snapshot(memory: Fixture.memory(pressure: .warning), cpu: Fixture.cpu(total: 90), thermal: .fair)
        let r = Readiness.evaluate([hot])
        #expect(!r.ready && r.blockers.count == 3)
        var lenient = ReadinessPolicy()
        lenient.maxThermal = .fair; lenient.maxCPUPercent = 95; lenient.requireNormalMemoryPressure = false
        #expect(Readiness.evaluate([hot], policy: lenient).ready)
    }

    @Test func cpuIsAveragedNotSingleSample() {
        let r = Readiness.evaluate([Fixture.snapshot(cpu: Fixture.cpu(total: 20)), Fixture.snapshot(cpu: Fixture.cpu(total: 95)),
                                    Fixture.snapshot(cpu: Fixture.cpu(total: 20))])
        #expect(r.ready)
    }

    @Test func lowDiskBlocks() {
        #expect(!Readiness.evaluate([Fixture.snapshot(volume: Fixture.volume(free: 1_000_000_000))]).ready)
    }
}

@Suite("Disk growth")
struct GrowthTests {
    func scan(_ ts: Date, _ folders: [(String, Int64)], swap: Int64, used: Int64) -> GrowthScan {
        GrowthScan(id: UUID().uuidString, timestamp: ts, folders: folders.map { FolderSize(path: $0.0, bytes: $0.1) },
                   swapFileBytes: swap, volumeUsed: used, localSnapshotCount: 0, durationSeconds: 1, unreadable: [])
    }

    @Test func compareAttributesGrowthWithoutDoubleCounting() {
        let lib = NSHomeDirectory() + "/Library"
        let a = scan(Date().addingTimeInterval(-86400), [(lib + "/Caches", 10), (lib + "/Caches/X", 5), ("/h/proj", 100)], swap: 1000, used: 5000)
        let b = scan(Date(), [(lib + "/Caches", 40), (lib + "/Caches/X", 35), ("/h/proj", 90), ("/h/new", 20)], swap: 1500, used: 5600)
        let r = GrowthTracker.compare(a, b)
        #expect(r.trackedDelta == 30 - 10 + 20)          // nested Caches/X not added twice
        #expect(r.swapDelta == 500 && r.volumeUsedDelta == 600)
        let expected: Int64 = 600 - 40 - 500
        #expect(r.unattributedDelta == expected)
        #expect(r.entries.first?.path == lib + "/Caches" || r.entries.first?.path == lib + "/Caches/X")
        #expect(r.entries.contains { $0.path == "/h/new" && $0.before == nil })
    }

    @Test func scansPersistNewestFirstAndAreCapped() throws {
        let t = TempDir("gr")
        let store = try HistoryStore(path: t.path + "/h.sqlite")
        for i in 0..<65 { try store.recordGrowthScan(scan(Date(timeIntervalSince1970: Double(1_800_000_000 + i)), [("/x", Int64(i))], swap: 0, used: 0)) }
        let scans = try store.growthScans(limit: 100)
        #expect(scans.count == 60)
        #expect(scans.first?.folders.first?.bytes == 64)
    }

    @Test func targetsExcludePrivacyProtectedFolders() {
        let home = NSHomeDirectory()
        let t = GrowthTracker.targets(includePersonal: false)
        for bad in ["/Documents", "/Desktop", "/Downloads", "/Library/Mail", "/Library/Containers", "/Library/Messages"] {
            #expect(!t.contains(home + bad))
        }
    }
}

@Suite("Energy sampling")
struct EnergyTests {
    @Test func powerAndWakeupsComeFromDeltas() async throws {
        var sampler = ProcessSampler()
        let first = sampler.sample()
        #expect(first.allSatisfy { $0.powerWatts == nil && $0.wakeupsPerSecond == nil })
        var x = 0.0
        for i in 0..<3_000_000 { x += Double(i).squareRoot() }   // burn a little CPU in this process
        #expect(x > 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        let me = try #require(sampler.sample().first { $0.pid == getpid() })
        #expect(me.energyNanojoules != nil)
        #expect((me.powerWatts ?? -1) >= 0)
        #expect((me.wakeupsPerSecond ?? -1) >= 0)
    }

    @Test func appGroupsSumPower() {
        var a = Fixture.process(pid: 2, name: "A", category: .application, path: "/Applications/A.app/Contents/MacOS/A")
        var b = Fixture.process(pid: 3, name: "A Helper", category: .appHelper, path: "/Applications/A.app/Contents/Frameworks/H.app/Contents/MacOS/H")
        a.powerWatts = 0.5; b.powerWatts = 0.25; a.wakeupsPerSecond = 10; b.wakeupsPerSecond = 5
        let g = ProcessAnalyzer.appGroups([a, b])
        #expect(g.first?.powerWatts == 0.75 && g.first?.wakeupsPerSecond == 15)
    }
}
