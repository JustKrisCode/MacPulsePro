import Darwin
import Foundation
import Testing
@testable import MacPulseCore

@Suite("Persistence")
struct PersistenceTests {
    @Test func recordsQueriesAndPrunes() throws {
        let t = TempDir("db")
        let store = try HistoryStore(path: t.path + "/h.sqlite")
        let old = HistorySample(timestamp: Date().addingTimeInterval(-86400 * 30), cpu: 1)
        try store.record(old)
        for s in Fixture.history(minutes: 30) { try store.record(s) }
        #expect(try store.samples(since: Date().addingTimeInterval(-3600)).count == 31)
        let r = try store.prune(retentionDays: 14, maxSamples: 20)
        #expect(r.samples == 12)
        #expect(try store.counts().samples == 20)
    }

    @Test func roundTripsAllSampleFields() throws {
        let t = TempDir("db")
        let store = try HistoryStore(path: t.path + "/h.sqlite")
        let s = HistorySample(timestamp: Date(timeIntervalSince1970: 1_800_000_000), cpu: 12.5, load1: 3, memoryUsed: 5, compressed: 6,
                              pressure: 1, swapUsed: 7, swapouts: 8, gpu: 40, thermal: 2, diskFree: 9, battery: 80, onAC: false)
        try store.record(s)
        #expect(try store.samples(since: .distantPast) == [s])
    }

    @Test func processSeriesAndEvents() throws {
        let t = TempDir("db")
        let store = try HistoryStore(path: t.path + "/h.sqlite")
        let p = Fixture.process(pid: 42, cpu: 50, footprint: 123)
        try store.recordProcesses([p], at: Date())
        let series = try store.processSeries(p.identity, since: .distantPast)
        #expect(series.count == 1 && series[0].footprint == 123)
        try store.recordEvent(kind: "low-disk", severity: .warning, title: "Low", detail: "d")
        #expect(try store.events(since: .distantPast).first?.kind == "low-disk")
        #expect(try store.lastEvent(kind: "low-disk") != nil)
        #expect(try store.lastEvent(kind: "nope") == nil)
    }

    @Test func databaseFileIsPrivate() throws {
        let t = TempDir("db")
        _ = try HistoryStore(path: t.path + "/h.sqlite")
        let mode = try FileManager.default.attributesOfItem(atPath: t.path + "/h.sqlite")[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}

@Suite("Configuration")
struct ConfigTests {
    @Test func missingKeysUseDefaultsAndValuesAreClamped() throws {
        let json = #"{"sampleIntervalSeconds": 2, "retentionDays": 9999, "thresholds": {"lowDiskFreePercent": 7}}"#
        let c = try JSONDecoder().decode(MacPulseConfig.self, from: Data(json.utf8))
        #expect(c.sampleIntervalSeconds == 10)
        #expect(c.retentionDays == 365)
        #expect(c.thresholds.lowDiskFreePercent == 7)
        #expect(c.thresholds.sustainedCPUPercent == 85)
        #expect(c.notificationsEnabled == false)
    }

    @Test func setByDottedKey() throws {
        var c = MacPulseConfig()
        try c.set("notificationsEnabled", "true")
        try c.set("thresholds.lowDiskFreePercent", "12")
        try c.set("menuBarMetrics", "cpu,gpu")
        #expect(c.notificationsEnabled && c.thresholds.lowDiskFreePercent == 12 && c.menuBarMetrics == ["cpu", "gpu"])
        #expect(throws: MacPulseError.self) { try c.set("nope", "1") }
        #expect(throws: MacPulseError.self) { try c.set("retentionDays", "abc") }
    }

    @Test func saveAndLoad() throws {
        let t = TempDir("cfg")
        var c = MacPulseConfig()
        c.retentionDays = 30
        try c.save(path: t.path + "/c.json")
        #expect(MacPulseConfig.load(path: t.path + "/c.json").retentionDays == 30)
        #expect(MacPulseConfig.load(path: t.path + "/missing.json") == MacPulseConfig())
    }
}

@Suite("Monitoring")
struct MonitoringTests {
    @Test func rulesFireOnThresholds() {
        let snap = Fixture.snapshot(memory: Fixture.memory(pressure: .critical), thermal: .serious, volume: Fixture.volume(free: 5_000_000_000))
        let kinds = Set(MonitorRules.evaluate(snapshot: snap, history: .empty, findings: [], thresholds: Thresholds()).map(\.kind))
        #expect(kinds == ["low-disk", "memory-pressure", "thermal"])
        #expect(MonitorRules.evaluate(snapshot: Fixture.snapshot(), history: .empty, findings: [], thresholds: Thresholds()).isEmpty)
    }

    @Test func agentRecordsSamplesAndHonorsCooldown() async throws {
        let t = TempDir("mon")
        let store = try HistoryStore(path: t.path + "/h.sqlite")
        var cfg = MacPulseConfig()
        cfg.thresholds.lowDiskFreePercent = 100        // force the low-disk rule on a real volume
        cfg.notificationsEnabled = true
        let box = AlertBox()
        let agent = MonitorAgent(store: store, config: cfg, notify: { box.add($0) })
        let first = await agent.tick()
        let second = await agent.tick()
        #expect(first.contains { $0.kind == "low-disk" })
        #expect(!second.contains { $0.kind == "low-disk" })
        #expect(box.count == first.count + second.count)
        #expect(try store.counts().samples == 2)
        #expect(try store.counts().processSamples > 0)
        let stats = await agent.stats
        #expect(stats.lastSampleDuration < 1.0)
    }

    @Test func notificationsAreOptIn() async throws {
        let t = TempDir("mon")
        let store = try HistoryStore(path: t.path + "/h.sqlite")
        var cfg = MacPulseConfig()
        cfg.thresholds.lowDiskFreePercent = 100
        let box = AlertBox()
        let agent = MonitorAgent(store: store, config: cfg, notify: { box.add($0) })
        let alerts = await agent.tick()
        #expect(!alerts.isEmpty && box.count == 0)
    }

    @Test func batteryDoublesInterval() async throws {
        let t = TempDir("mon")
        let agent = MonitorAgent(store: try HistoryStore(path: t.path + "/h.sqlite"), config: MacPulseConfig(), notify: { _ in })
        #expect(await agent.currentInterval(onBattery: true) == 120)
        #expect(await agent.currentInterval(onBattery: false) == 60)
    }

    @Test func launchAgentInstallUsesLaunchctlAndWritesPlist() throws {
        let t = TempDir("la")
        let mock = MockCommandRunner()
        mock.set("/bin/launchctl bootstrap gui/501 \(t.path)/agent.plist", ExecResult(status: 0, stdout: "", stderr: ""))
        let mgr = LaunchAgentManager(runner: mock, plistPath: t.path + "/agent.plist", uid: 501, logDirectory: t.path + "/logs")
        try mgr.install(executable: "/bin/echo")
        let data = try #require(FileManager.default.contents(atPath: t.path + "/agent.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == ["/bin/echo", "monitor", "run"])
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(mock.calls.contains { $0.contains("bootstrap") })
        try mgr.uninstall()
        #expect(!FileManager.default.fileExists(atPath: t.path + "/agent.plist"))
        #expect(throws: MacPulseError.self) { try mgr.install(executable: "/nonexistent/macpulse") }
    }

    @Test func launchctlFailureIsSurfaced() {
        let t = TempDir("la")
        let mock = MockCommandRunner()   // every call fails
        let mgr = LaunchAgentManager(runner: mock, plistPath: t.path + "/agent.plist", uid: 501, logDirectory: t.path + "/logs")
        #expect(throws: MacPulseError.self) { try mgr.install(executable: "/bin/echo") }
    }
}

final class AlertBox: @unchecked Sendable {
    private let lock = NSLock()
    private var alerts: [MonitorAlert] = []
    func add(_ a: MonitorAlert) { lock.lock(); alerts.append(a); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return alerts.count }
}

@Suite("Live collectors (integration)")
struct CollectorIntegrationTests {
    @Test func cpuSamplerProducesBoundedValues() throws {
        var s = CPUSampler()
        usleep(200_000)
        let first = s.sample()
        let c = try #require(first)
        #expect(c.total >= 0 && c.total <= 100)
        #expect(c.cores.count == ProcessInfo.processInfo.processorCount)
        #expect(c.loadAverage.count == 3)
    }

    @Test func memoryNumbersAreConsistent() throws {
        let m = try #require(MemoryCollector.snapshot())
        #expect(m.physical == UInt64(ProcessInfo.processInfo.physicalMemory))
        #expect(m.used <= m.physical)
        #expect(m.pressure != .unknown)
    }

    @Test func processListContainsSelfWithIdentity() throws {
        let procs = ProcessCollector.list()
        let me = try #require(procs.first { $0.pid == getpid() })
        #expect(me.accessible && (me.footprint ?? 0) > 0)
        #expect(ProcessCollector.identity(of: getpid()) == me.identity)
        #expect(procs.contains { $0.pid == 1 && $0.category == .system })
    }

    @Test func volumeAndSystemInfo() throws {
        let v = try #require(StorageCollector.volume("/"))
        #expect(v.total > v.available && v.available > 0)
        let info = SystemInfo.current()
        #expect(info.physicalMemory > 0 && info.logicalCPUs > 0)
    }

    @Test func quickVolumeMatchesFullVolume() throws {
        let quick = try #require(StorageCollector.quickVolume("/"))
        let full = try #require(StorageCollector.volume("/"))
        #expect(quick.total == full.total)
        // Free space moves constantly; allow 2 GB of drift between the two reads.
        #expect(abs(quick.available - full.available) < 2_000_000_000)
        #expect(quick.purgeableEstimate.value == nil)
    }

    @Test func samplerReusesExpensivePurgeableRead() async throws {
        let sampler = SystemSampler()
        let a = await sampler.snapshot(includeProcesses: false)
        await sampler.invalidateVolume()
        let b = await sampler.snapshot(includeProcesses: false)
        #expect(a.volume?.purgeableEstimate.provenance == .estimated || a.volume?.purgeableEstimate.provenance == .unavailable)
        #expect(b.volume?.total == a.volume?.total)
    }

    @Test func gpuSamplerNeverFabricates() {
        var g = GPUSampler()
        let s = g.sample()
        if s.devices.isEmpty { #expect(s.utilization.value == nil && s.utilization.provenance == .unavailable) }
        if let u = s.utilization.value { #expect(u >= 0 && u <= 100) }
        #expect(s.processes.allSatisfy { $0.recentPercent == nil })   // first sample has no baseline
    }

    @Test func thermalSnapshotDoesNotInventTemperature() {
        let t = ThermalCollector.snapshot()
        #expect(t.cpuTemperatureC.value == nil && t.cpuTemperatureC.provenance == .unavailable)
    }

    @Test func pmsetUnavailableIsHandled() {
        let t = ThermalCollector.snapshot(includePmset: true, runner: MockCommandRunner())
        #expect(t.cpuSpeedLimit.value == nil && t.cpuSpeedLimit.provenance == .unavailable)
    }

    @Test func missingSystemToolsDegradeGracefully() {
        let mock = MockCommandRunner()
        #expect(StorageCollector.apfsContainers(runner: mock).isEmpty)
        #expect(StorageCollector.localSnapshots(runner: mock) == nil)
        #expect(ProcessAnalyzer.launchdManagedPIDs(runner: mock) == nil)
        #expect(SystemCommandRunner().run("relative-tool", [], timeout: 1).notFound)
    }

    @Test func commandRunnerTimesOut() {
        let r = SystemCommandRunner().run("/bin/sleep", ["5"], timeout: 0.3)
        #expect(r.timedOut && !r.ok)
    }
}

@Suite("Process control (spawns a disposable child)")
struct ProcessControlTests {
    func spawnSleep() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    func record(for pid: Int32) throws -> ProcessRecord {
        try #require(ProcessCollector.list().first { $0.pid == pid })
    }

    @Test func pidReuseProtectionSendsNothing() async throws {
        let child = try spawnSleep()
        defer { child.terminate() }
        usleep(100_000)
        var r = try record(for: child.processIdentifier)
        // /bin/sleep is a system binary; treat it as a user process for this test only.
        r.category = .userBackground
        r.startMicros += 1   // simulate a reused pid with a different start time
        let outcome = await ProcessController.terminate(r, timeout: 1)
        #expect(outcome == .identityMismatch)
        #expect(child.isRunning)
    }

    @Test func gracefulTerminationOfOwnChild() async throws {
        let child = try spawnSleep()
        usleep(100_000)
        var r = try record(for: child.processIdentifier)
        r.category = .userBackground
        let outcome = await ProcessController.terminate(r, timeout: 3)
        child.waitUntilExit()
        #expect(outcome == .exited)
        #expect(child.terminationReason == .uncaughtSignal)
    }

    @Test func systemBinaryIsRefusedByDefault() async throws {
        let child = try spawnSleep()
        defer { child.terminate() }
        usleep(100_000)
        let r = try record(for: child.processIdentifier)
        #expect(r.category == .system)
        if case .refused = await ProcessController.terminate(r) {} else { Issue.record("expected refusal") }
        #expect(child.isRunning)
    }
}

@Suite("Reports")
struct ReportTests {
    @Test func markdownAndHtmlContainSectionsAndEscape() {
        var snap = Fixture.snapshot(processes: [Fixture.process(pid: 5, name: "<script>alert(1)</script>", cpu: 50)])
        snap.memory = Fixture.memory()
        let rep = SystemReport(generatedAt: Date(), tool: "t", snapshot: snap, health: HealthScorer.evaluate(snap),
                               history: .empty, recommendations: [], findings: [], storage: nil, recentEvents: [], recentCleanups: [])
        let md = ReportBuilder.markdown(rep)
        #expect(md.contains("## Health score") && md.contains("## Top processes"))
        let html = ReportBuilder.html(rep)
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;script&gt;"))
        let csv = ReportBuilder.csv(rep)
        #expect(csv.hasPrefix("pid,ppid,name"))
        #expect(ReportBuilder.historyCSV(Fixture.history(minutes: 2)).split(separator: "\n").count == 4)
    }
}

@Suite("Overhead")
struct OverheadTests {
    @Test func monitorSnapshotIsCheap() async {
        let sampler = SystemSampler()
        _ = await sampler.snapshot(includeProcesses: false)
        let clock = ContinuousClock()
        let light = await clock.measure { for _ in 0..<10 { _ = await sampler.snapshot(includeProcesses: false) } }
        let full = await clock.measure { for _ in 0..<5 { _ = await sampler.snapshot(includeProcesses: true) } }
        let lightMs = Double(light.components.attoseconds) / 1e15 / 10 + Double(light.components.seconds) * 100
        let fullMs = Double(full.components.attoseconds) / 1e15 / 5 + Double(full.components.seconds) * 200
        print("overhead: light snapshot \(String(format: "%.2f", lightMs)) ms, full snapshot \(String(format: "%.2f", fullMs)) ms")
        #expect(lightMs < 100)
        #expect(fullMs < 400)
    }
}
