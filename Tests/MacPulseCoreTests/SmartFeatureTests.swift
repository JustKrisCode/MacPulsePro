import Foundation
import SQLite3
import Testing
@testable import MacPulseCore

@Suite("Smart features")
struct SmartFeatureTests {
    @Test func migratesVersion1DatabaseWithoutLosingRows() throws {
        let t = TempDir("mig")
        let path = t.path + "/old.sqlite"
        let old = try Database(path: path)
        try old.execute("CREATE TABLE process_samples(ts REAL NOT NULL, pid INTEGER NOT NULL, start INTEGER NOT NULL, name TEXT, cpu REAL, footprint INTEGER)")
        try old.run("INSERT INTO process_samples VALUES(1, 2, 3, 'legacy', 50, 1000)")
        let store = try HistoryStore(path: path)
        let cols = try store.db.query("PRAGMA table_info(process_samples)").compactMap { $0[1].text }
        #expect(cols.contains("power") && cols.contains("wakeups"))
        #expect(try store.counts().processSamples == 1)
        #expect(try store.meta("schema") == "2")
    }

    @Test func offendersMergeSameNameAndCorrelateWithHeatAndPressure() throws {
        let t = TempDir("off")
        let store = try HistoryStore(path: t.path + "/h.sqlite")
        let now = Date()
        for i in 0..<10 {
            let ts = now.addingTimeInterval(Double(i - 10) * 60)
            try store.record(HistorySample(timestamp: ts, cpu: 50, pressure: i >= 5 ? 1 : 0, thermal: i >= 5 ? 2 : 0))
            var a = Fixture.process(pid: 10, name: "Helper", cpu: 20, footprint: 1 << 30, started: now.addingTimeInterval(-9999))
            var b = Fixture.process(pid: 11, name: "Helper", cpu: 30, footprint: 1 << 30, started: now.addingTimeInterval(-9998))
            a.powerWatts = 0.5; b.powerWatts = 0.5; a.wakeupsPerSecond = 100; b.wakeupsPerSecond = 100
            let quiet = Fixture.process(pid: 12, name: "Quiet", cpu: i >= 5 ? 0 : 80, footprint: 100_000_000, started: now.addingTimeInterval(-9997))
            try store.recordProcesses([a, b, quiet], at: ts)
        }
        let r = try OffenderAnalyzer.report(store: store, days: 1, now: now.addingTimeInterval(60))
        let helperCPU = try #require(r.cpu.first { $0.name == "Helper" })
        #expect(helperCPU.detail.contains("avg 50%"))          // 20 + 30 merged per moment
        #expect(helperCPU.detail.contains("100% of the time")) // never above 100%
        #expect(r.heat.first?.name == "Helper")                 // Quiet was idle while hot
        #expect(r.memoryPressure.first?.name == "Helper")
        #expect(r.energy.first?.name == "Helper" && r.energy.first!.detail.contains("1.00 W"))
        #expect(r.hotMinutes > 0)
    }

    @Test func sustainedWakeupsAndEnergyBecomeFindingsButSingleSpikesDoNot() {
        let p = Fixture.process(pid: 70, name: "chatty")
        var ctx = ProcessAnalyzer.Context(records: [p], physicalMemory: 24 << 30)
        let now = Date()
        ctx.history[p.identity] = [ProcessHistoryPoint(timestamp: now, cpu: 1, footprint: 1, power: 5, wakeups: 5000)]
        #expect(!ProcessAnalyzer.findings(ctx).contains { $0.kind == .wakeupStorm || $0.kind == .energyHog })
        ctx.history[p.identity] = (0...12).map {
            ProcessHistoryPoint(timestamp: now.addingTimeInterval(-Double($0) * 180), cpu: 2, footprint: 1, power: 3, wakeups: 2500)
        }
        let kinds = Set(ProcessAnalyzer.findings(ctx).map(\.kind))
        #expect(kinds.contains(.wakeupStorm) && kinds.contains(.energyHog))
    }

    @Test func energyAlertsOnlyOnBatteryWakeupAlertsAlways() {
        let id = ProcessIdentity(pid: 1, startMicros: 1)
        let f = [ProcessFinding(kind: .energyHog, pids: [1], identities: [id], title: "e", evidence: ["x"], severity: .info, confidence: .medium, provenance: .measured),
                 ProcessFinding(kind: .wakeupStorm, pids: [1], identities: [id], title: "w", evidence: ["x"], severity: .info, confidence: .medium, provenance: .measured)]
        var snap = Fixture.snapshot()
        let ac = MonitorRules.evaluate(snapshot: snap, history: .empty, findings: f, thresholds: Thresholds()).map(\.title)
        #expect(ac == ["w"])
        snap.power.source = "Battery Power"
        let batt = MonitorRules.evaluate(snapshot: snap, history: .empty, findings: f, thresholds: Thresholds()).map(\.title)
        #expect(Set(batt) == ["e", "w"])
    }
}
