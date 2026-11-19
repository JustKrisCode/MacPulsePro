import Foundation
import Testing
@testable import MacPulseCore

@Suite("Trends")
struct TrendTests {
    @Test func linearFitRecoversSlope() throws {
        let pts = (0..<10).map { (Double($0) * 60, 100 + Double($0) * 5) }
        let f = try #require(Trends.fit(pts))
        #expect(abs(f.slope - 5.0 / 60) < 1e-9)
        #expect(f.r2 > 0.999)
    }

    @Test func fitNeedsThreePoints() { #expect(Trends.fit([(0, 1), (1, 2)]) == nil) }

    @Test func sustainedRequiresCoverageAndFraction() {
        let now = Date()
        let high = (0...10).map { (now.addingTimeInterval(-Double($0) * 60), 95.0) }
        #expect(Trends.sustained(high, threshold: 85, window: 600).sustained)
        let short = (0...2).map { (now.addingTimeInterval(-Double($0) * 10), 95.0) }
        #expect(!Trends.sustained(short, threshold: 85, window: 600).sustained)
        let mixed = (0...10).map { (now.addingTimeInterval(-Double($0) * 60), $0 % 2 == 0 ? 95.0 : 10.0) }
        #expect(!Trends.sustained(mixed, threshold: 85, window: 600).sustained)
    }

    @Test func historySummaryDetectsSwapGrowth() throws {
        let h = Fixture.history(minutes: 60, swapPerMinute: 50_000_000)
        let s = HistorySummary.compute(h)
        let g = try #require(s.swapGrowthPerHour)
        #expect(abs(g - 3_000_000_000) < 50_000_000)
        #expect((s.swapGrowthR2 ?? 0) > 0.99)
        #expect((s.swapoutsPerMinute ?? 0) > 9)
    }

    @Test func elevatedMinutesIgnoreGaps() {
        let now = Date()
        let s = [HistorySample(timestamp: now.addingTimeInterval(-7200), thermal: 2),
                 HistorySample(timestamp: now.addingTimeInterval(-60), thermal: 2),
                 HistorySample(timestamp: now, thermal: 0)]
        #expect(abs(HistorySummary.elevatedMinutes(s) { ($0.thermal ?? 0) >= 2 } - 1) < 0.01)
    }

    @Test func emptyHistoryIsSafe() {
        let s = HistorySummary.compute([])
        #expect(s.sampleCount == 0 && s.swapGrowthPerHour == nil && !s.sustainedHighCPU)
    }
}

@Suite("Health score")
struct HealthTests {
    @Test func healthySystemScoresHigh() {
        let r = HealthScorer.evaluate(Fixture.snapshot())
        #expect(r.overall >= 95)
        #expect(r.status == .ok)
        #expect(r.dimensions.allSatisfy { $0.deductions.isEmpty })
    }

    @Test func criticalPressureCapsOverall() {
        let r = HealthScorer.evaluate(Fixture.snapshot(memory: Fixture.memory(pressure: .critical)))
        #expect(r.overall <= 49)
        let mem = r.dimensions.first { $0.kind == .memory }
        #expect(mem?.deductions.contains { $0.reason.contains("CRITICAL") } == true)
    }

    @Test func lowDiskIsExplained() {
        let r = HealthScorer.evaluate(Fixture.snapshot(volume: Fixture.volume(free: 10_000_000_000)))
        let d = r.dimensions.first { $0.kind == .storage }
        #expect((d?.score ?? 100) < 50)
        #expect(d?.deductions.count == 2)
    }

    @Test func unavailableMetricsAreExcludedNotFaked() {
        let r = HealthScorer.evaluate(Fixture.snapshot(gpu: nil))
        #expect(!r.dimensions.contains { $0.kind == .gpu })
        #expect(r.excluded.contains { $0.hasPrefix("gpu") })
    }

    @Test func singleHighCpuSampleIsAMinorDeduction() {
        let r = HealthScorer.evaluate(Fixture.snapshot(cpu: Fixture.cpu(total: 95)))
        #expect(r.dimensions.first { $0.kind == .cpu }?.score == 90)
    }
}

@Suite("Recommendations")
struct RecommendationTests {
    @Test func pressureWithRisingSwapIsCriticalAndNamesConsumers() {
        let big = Fixture.process(pid: 500, name: "Heavy", category: .application, footprint: 6 << 30,
                                  path: "/Applications/Heavy.app/Contents/MacOS/Heavy", bundle: "com.x.heavy")
        let snap = Fixture.snapshot(memory: Fixture.memory(pressure: .warning, swapUsed: 6 << 30), processes: [big])
        let hist = HistorySummary.compute(Fixture.history(minutes: 60, swapPerMinute: 60_000_000))
        let recs = RecommendationEngine.recommendations(RecommendationContext(snapshot: snap, history: hist))
        let r = recs.first { $0.id == "memory.pressure" }
        #expect(r?.severity == .critical)
        #expect(r?.confidence == .high)
        #expect(r?.relatedPIDs.contains(500) == true)
        #expect(recs.first?.id == "memory.pressure")
    }

    @Test func lowDiskWithSwappingExplainsStorageImpact() {
        let snap = Fixture.snapshot(memory: Fixture.memory(pressure: .warning, swapUsed: 4 << 30), volume: Fixture.volume(free: 8_000_000_000))
        let recs = RecommendationEngine.recommendations(RecommendationContext(snapshot: snap,
            cleanup: CleanupSummary(safeBytes: 5_000_000_000, reviewBytes: 1, safeCount: 3)))
        #expect(recs.contains { $0.id == "storage.low" && $0.confidence == .high })
        #expect(recs.contains { $0.id == "storage.swap" })
    }

    @Test func hotCpuProducesThermalRecommendation() {
        let busy = Fixture.process(pid: 77, name: "encoder", cpu: 350)
        let snap = Fixture.snapshot(cpu: Fixture.cpu(total: 92), thermal: .serious, processes: [busy])
        let recs = RecommendationEngine.recommendations(RecommendationContext(snapshot: snap))
        let r = recs.first { $0.id == "cpu.thermal" }
        #expect(r?.severity == .critical)
        #expect(r?.relatedPIDs == [77])
        #expect(!recs.contains { $0.id == "thermal.elevated" })
    }

    @Test func healthySystemHasNoWarnings() {
        let recs = RecommendationEngine.recommendations(RecommendationContext(snapshot: Fixture.snapshot()))
        #expect(!recs.contains { $0.severity >= .warning })
    }

    @Test func rankingIsDeterministic() {
        let snap = Fixture.snapshot(memory: Fixture.memory(pressure: .warning), cpu: Fixture.cpu(total: 95), thermal: .fair,
                                    volume: Fixture.volume(free: 9_000_000_000))
        let a = RecommendationEngine.recommendations(RecommendationContext(snapshot: snap)).map(\.id)
        let b = RecommendationEngine.recommendations(RecommendationContext(snapshot: snap)).map(\.id)
        #expect(a == b && !a.isEmpty)
    }
}

@Suite("Process analysis")
struct ProcessAnalysisTests {
    @Test func buildsTreeAndAggregatesSubtree() {
        let procs = [Fixture.process(pid: 1, ppid: 0, name: "launchd", category: .system, footprint: 10),
                     Fixture.process(pid: 10, ppid: 1, name: "shell", footprint: 100),
                     Fixture.process(pid: 11, ppid: 10, name: "child", footprint: 50)]
        let roots = ProcessAnalyzer.tree(procs)
        #expect(roots.count == 1 && roots[0].record.pid == 1)
        #expect(roots[0].subtreeFootprint == 160)
        #expect(roots[0].children[0].children[0].record.pid == 11)
    }

    @Test func groupsHelpersUnderTheirApp() {
        let procs = [Fixture.process(pid: 2, name: "Browser", category: .application, footprint: 100, path: "/Applications/B.app/Contents/MacOS/B"),
                     Fixture.process(pid: 3, name: "B Helper", category: .appHelper, footprint: 300,
                                     path: "/Applications/B.app/Contents/Frameworks/H.app/Contents/MacOS/B Helper")]
        let g = ProcessAnalyzer.appGroups(procs)
        #expect(g.count == 1 && g[0].footprint == 400 && g[0].category == .application)
    }

    @Test func orphanRequiresDetachedUnmanagedLongRunning() {
        let orphan = Fixture.process(pid: 900, ppid: 1, name: "node")
        let managed = Fixture.process(pid: 901, ppid: 1, name: "agent")
        let young = Fixture.process(pid: 902, ppid: 1, name: "python3", started: Date().addingTimeInterval(-60))
        let terminal = Fixture.process(pid: 903, ppid: 1, name: "ruby", tty: true)
        var ctx = ProcessAnalyzer.Context(records: [orphan, managed, young, terminal], physicalMemory: 24 << 30)
        ctx.launchdManagedPIDs = [901]
        let f = ProcessAnalyzer.findings(ctx).filter { $0.kind == .probableOrphan }
        #expect(f.map(\.pids) == [[900]])
        #expect(f.first?.confidence == .medium)
        ctx.launchdManagedPIDs = nil   // without launchd data, never guess
        #expect(ProcessAnalyzer.findings(ctx).filter { $0.kind == .probableOrphan }.isEmpty)
    }

    @Test func runawayNeedsSustainedHistoryNotOneSample() {
        let p = Fixture.process(pid: 50, name: "spinner", cpu: 100)
        var ctx = ProcessAnalyzer.Context(records: [p], physicalMemory: 24 << 30)
        #expect(ProcessAnalyzer.findings(ctx).filter { $0.kind == .runawayCPU }.isEmpty)
        let now = Date()
        ctx.history[p.identity] = (0...10).map { ProcessHistoryPoint(timestamp: now.addingTimeInterval(-Double($0) * 30), cpu: 99, footprint: 1) }
        #expect(ProcessAnalyzer.findings(ctx).contains { $0.kind == .runawayCPU })
    }

    @Test func memoryGrowthDetectedOnlyForStrongTrend() {
        let p = Fixture.process(pid: 60, name: "leaky", footprint: 2 << 30)
        var ctx = ProcessAnalyzer.Context(records: [p], physicalMemory: 24 << 30)
        let now = Date()
        func point(_ i: Int, _ bytes: Int) -> ProcessHistoryPoint {
            ProcessHistoryPoint(timestamp: now.addingTimeInterval(Double(i - 12) * 300), cpu: 1, footprint: UInt64(bytes))
        }
        ctx.history[p.identity] = (0..<12).map { (i: Int) -> ProcessHistoryPoint in point(i, 1_000_000_000 + i * 60_000_000) }
        let f = ProcessAnalyzer.findings(ctx).first { $0.kind == .memoryGrowth }
        #expect(f != nil && f?.provenance == .inferred)
        ctx.history[p.identity] = (0..<12).map { (i: Int) -> ProcessHistoryPoint in point(i, 1_000_000_000 + (i % 2) * 300_000_000) }
        #expect(!ProcessAnalyzer.findings(ctx).contains { $0.kind == .memoryGrowth })
    }

    @Test func terminationPolicyProtectsSystemAndOthers() {
        #expect(!TerminationPolicy.evaluate(Fixture.process(pid: 1, name: "launchd", category: .system)).allowed)
        #expect(!TerminationPolicy.evaluate(Fixture.process(pid: 400, name: "WindowServer", category: .systemUI)).allowed)
        #expect(!TerminationPolicy.evaluate(Fixture.process(pid: 401, name: "x", category: .otherUser, uid: 0)).allowed)
        #expect(!TerminationPolicy.evaluate(Fixture.process(pid: getpid(), name: "self")).allowed)
        let app = TerminationPolicy.evaluate(Fixture.process(pid: 402, name: "Notes", category: .application))
        #expect(app.allowed && !app.warnings.isEmpty)
        let parent = TerminationPolicy.evaluate(Fixture.process(pid: 403, name: "zsh"), ownAncestors: [403])
        #expect(parent.allowed && parent.warnings.contains { $0.contains("ancestor") })
    }
}

@Suite("Parsers")
struct ParserTests {
    @Test func procArgsParsing() throws {
        var buf = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buf += Array("/usr/bin/tool".utf8) + [0, 0, 0]
        buf += Array("tool".utf8) + [0] + Array("--token=abc".utf8) + [0] + Array("file name.txt".utf8) + [0]
        buf += Array("PATH=/bin".utf8) + [0]
        let args = try #require(ProcessInspector.parseProcArgs(buf))
        #expect(args == ["tool", "--token=abc", "file name.txt"])
        #expect(ProcessInspector.redact(args) == ["tool", "--token=[redacted]", "file name.txt"])
        #expect(ProcessInspector.redact(["cli", "--password", "hunter2", "x"]) == ["cli", "--password", "[redacted]", "x"])
    }

    @Test func gpuCreatorParsing() {
        #expect(GPUCollector.parseCreator("pid 424, WindowServer")?.0 == 424)
        #expect(GPUCollector.parseCreator("pid 9, Google Chrome Helper (GPU)")?.1 == "Google Chrome Helper (GPU)")
        #expect(GPUCollector.parseCreator("garbage") == nil)
    }

    @Test func pmsetSpeedLimit() {
        #expect(ThermalCollector.parseSpeedLimit("CPU_Scheduler_Limit = 100\nCPU_Speed_Limit = 72\n").value == 72)
        let none = ThermalCollector.parseSpeedLimit("Note: No thermal warning level has been recorded")
        #expect(none.value == nil && none.provenance == .unavailable)
    }

    @Test func tmutilSnapshots() {
        let s = StorageCollector.parseSnapshots("Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-19-101500.local\ncom.apple.os.update-ABC\n")
        #expect(s.count == 2)
        #expect(s[0].date != nil)
    }

    @Test func launchctlList() {
        let set = ProcessAnalyzer.parseLaunchctlList("PID\tStatus\tLabel\n123\t0\tcom.a\n-\t0\tcom.b\n456\t-9\tcom.c\n")
        #expect(set == [123, 456])
    }

    @Test func diskutilPlist() throws {
        let plist: [String: Any] = ["Containers": [["ContainerReference": "disk3", "CapacityCeiling": 500, "CapacityFree": 100,
                                                     "Volumes": [["Name": "Data", "Roles": ["Data"], "CapacityInUse": 300]]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let c = StorageCollector.parseAPFSList(data)
        #expect(c.first?.free == 100 && c.first?.volumes.first?.name == "Data")
        #expect(StorageCollector.parseAPFSList(Data("not a plist".utf8)).isEmpty)
    }

    @Test func fileKindClassification() {
        #expect(FileKindClassifier.classify("/x/Setup.DMG").0 == .review)
        #expect(FileKindClassifier.classify("/x/thesis.docx").0 == .protected)
        #expect(FileKindClassifier.classify("/x/db.sqlite").0 == .protected)
        #expect(FileKindClassifier.classify("/x/blob.xyz").0 == .unknown)
    }

    @Test func formatting() {
        #expect(Format.bytes(Int64(1_500_000_000)) == "1.5 GB")
        #expect(Format.memory(UInt64(24) << 30) == "24.00 GB")
        #expect(Format.memory(Int64(21_954_052_096)) == "20.45 GB")
        let asDouble: Double = 21_954_052_096
        #expect(Format.memory(Int64(asDouble)) == "20.45 GB")
        #expect(Format.duration(3700) == "1h 1m")
        #expect(Format.percent(nil) == "—")
    }
}
