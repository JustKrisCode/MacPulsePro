import Darwin
import Foundation
import MacPulseCore

struct Commands {
    let args: Args
    var json: Bool { args.has("json") }
    let config = MacPulseConfig.load()

    func dispatch() async throws -> Int32 {
        if args.has("help") && args.positionals.isEmpty { print(helpText); return 0 }
        let cmd = args.positionals.first ?? "status"
        let sub = args.positionals.dropFirst().first
        switch cmd {
        case "status": return try await status()
        case "doctor": return try await doctor()
        case "cpu": return try await cpu()
        case "memory", "mem", "ram": return try await memory()
        case "gpu": return try await gpu()
        case "thermal": return try await thermal()
        case "battery", "power": return battery()
        case "monitor": return try await monitor(sub)
        case "history": return try history()
        case "events": return try events()
        case "recommend", "recommendations": return try await recommend()
        case "disk" where sub == "growth": return try diskGrowth()
        case "disk": return try await DiskCommands(args: args, config: config).run(sub)
        case "why": return try await why()
        case "autoclean", "auto-clean": return try await autoclean(sub)
        case "energy", "power-usage": return try await energy()
        case "ready": return try await ready()
        case "run": return try await runWhenReady()
        case "processes", "ps": return try await ProcessCommands(args: args).run(sub)
        case "report": return try await report()
        case "config": return try configCommand(sub)
        case "version", "--version": print(ReportBuilder.version); return 0
        case "help": print(helpText); return 0
        default: throw MacPulseError.usage("unknown command '\(cmd)'")
        }
    }

    func emit<T: Encodable>(_ value: T, _ human: () -> String) {
        print(json ? JSON.string(value) : human())
    }

    func openStore() -> HistoryStore? { try? HistoryStore() }

    func recentHistory(_ store: HistoryStore?, _ snap: SystemSnapshot) -> HistorySummary {
        let samples = (try? store?.samples(since: Date().addingTimeInterval(-3600))) ?? []
        return HistorySummary.compute(samples + [HistorySample(snap)], cpuThreshold: config.thresholds.sustainedCPUPercent,
                                      cpuWindow: config.thresholds.sustainedCPUMinutes * 60)
    }

    // MARK: status

    struct StatusOutput: Encodable {
        var health: HealthReport
        var snapshot: SystemSnapshot
        var recommendations: [Recommendation]
    }

    func status() async throws -> Int32 {
        let snap = await SystemSampler().measured(interval: try args.double("interval", 1))
        let store = openStore()
        let hist = recentHistory(store, snap)
        let health = HealthScorer.evaluate(snap, history: hist, thresholds: config.thresholds)
        var ctx = ProcessAnalyzer.Context(records: snap.processes, physicalMemory: snap.system.physicalMemory)
        ctx.launchdManagedPIDs = ProcessAnalyzer.launchdManagedPIDs()
        ctx.thresholds = config.thresholds
        if let series = try? store?.processSeries(since: Date().addingTimeInterval(-7200)) { ctx.history = series.mapValues(\.points) }
        let recs = RecommendationEngine.recommendations(RecommendationContext(
            snapshot: snap, history: hist, findings: ProcessAnalyzer.findings(ctx), thresholds: config.thresholds))
        var out = snap
        if json { out.processes = snap.topProcesses(by: .cpu, limit: 15) + snap.topProcesses(by: .memory, limit: 15) }
        emit(StatusOutput(health: health, snapshot: out, recommendations: recs)) { renderStatus(snap, health, recs) }
        return health.status == .ok && !recs.contains(where: { $0.severity >= .warning }) ? 0 : 3
    }

    func renderStatus(_ s: SystemSnapshot, _ h: HealthReport, _ recs: [Recommendation]) -> String {
        var o = Style.bold("MacPulse Pro") + Style.dim("  \(s.system.chip) · macOS \(s.system.osVersion) · up \(Format.duration(s.system.uptimeSeconds))") + "\n"
        o += "\nHealth  " + Style.score(h.overall) + "/100  " + Style.severity(h.status, h.status.rawValue.uppercased()) + "\n"
        for d in h.dimensions {
            let ded = d.deductions.first.map { Style.dim("  − " + $0.reason) } ?? ""
            o += "  " + d.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0) + Style.score(d.score).padding(toLength: Style.enabled ? 12 : 3, withPad: " ", startingAt: 0) + "  " + d.summary + ded + "\n"
        }
        o += heading("Now")
        if let c = s.cpu {
            o += "  CPU      \(Style.bar(c.total)) \(Format.percent(c.total).padding(toLength: 5, withPad: " ", startingAt: 0))"
            if let p = c.performanceAverage, let e = c.efficiencyAverage { o += Style.dim(" P \(Format.percent(p)) · E \(Format.percent(e))") }
            o += Style.dim("  load \(c.loadAverage.map { String(format: "%.1f", $0) }.joined(separator: " "))") + "\n"
        }
        if let m = s.memory {
            let pct = Double(m.used) / Double(max(m.physical, 1)) * 100
            o += "  Memory   \(Style.bar(pct)) \(Format.memory(m.used)) / \(Format.memory(m.physical))  pressure \(Style.severity(m.pressure == .normal ? .ok : m.pressure == .warning ? .warning : .critical, m.pressure.rawValue))  swap \(Format.memory(m.swapUsed))\n"
        }
        o += "  GPU      \(Style.bar(s.gpu.utilization.value)) \(Format.percent(s.gpu.utilization.value)) \(Style.provenance(s.gpu.utilization.provenance))\n"
        o += "  Thermal  \(Style.severity(s.thermal.state <= .nominal ? .ok : s.thermal.state == .fair ? .info : .critical, s.thermal.state.rawValue))\(s.thermal.lowPowerMode ? Style.dim("  (Low Power Mode)") : "")\n"
        if let v = s.volume {
            o += "  Disk     \(Style.bar(100 - v.freePercent)) \(Format.bytes(v.available)) free of \(Format.bytes(v.total))\n"
        }
        if s.power.hasBattery {
            o += "  Battery  \(s.power.chargePercent.map { "\($0)%" } ?? "?") \(s.power.source == "AC Power" ? "on AC" : "on battery")  capacity \(Format.percent(s.power.healthPercent.value)) \(Style.provenance(s.power.healthPercent.provenance))\n"
        }
        o += heading("Top CPU")
        var t = Table(["PID", "Process", "CPU", "Memory", "Runtime"], aligns: [.right, .left, .right, .right, .right], flexible: 1)
        for p in s.topProcesses(by: .cpu, limit: 5) {
            t.add([String(p.pid), p.name, Format.percent(p.cpuPercent, digits: 1), Format.memory(p.footprint), Format.duration(p.runtime)])
        }
        o += t.render()
        o += heading("Top memory (by app)")
        var g = Table(["App / process", "Memory", "CPU", "Procs"], aligns: [.left, .right, .right, .right], flexible: 0)
        for a in ProcessAnalyzer.appGroups(s.processes).prefix(5) {
            g.add([a.name, Format.memory(a.footprint), Format.percent(a.cpuPercent, digits: 1), String(a.pids.count)])
        }
        o += g.render()
        if !recs.isEmpty {
            o += heading("Recommendations")
            for r in recs.prefix(4) {
                o += "  " + Style.severity(r.severity, "●") + " " + Style.bold(r.title) + Style.dim("  [confidence \(r.confidence.rawValue), risk \(r.risk.rawValue)]") + "\n"
                for e in r.evidence.prefix(3) { o += Style.dim("      · " + e) + "\n" }
                if let a = r.actionHint { o += Style.dim("      → ") + Style.cyan(a) + "\n" }
            }
            if recs.count > 4 { o += Style.dim("  … \(recs.count - 4) more: macpulse recommend") + "\n" }
        }
        return o
    }

    // MARK: doctor

    struct DoctorItem: Encodable { var name: String; var status: String; var provenance: String; var detail: String }
    struct DoctorOutput: Encodable {
        var system: SystemInfo
        var metrics: [DoctorItem]
        var permissions: [DoctorItem]
        var monitor: LaunchAgentManager.Status
        var overheadMilliseconds: [String: Double]
        var databasePath: String
        var databaseBytes: Int64?
    }

    func timed<T>(_ body: () -> T) -> (T, Double) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let v = body()
        return (v, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }

    func doctor() async throws -> Int32 {
        var overhead: [String: Double] = [:]
        var cpuSampler = CPUSampler()
        usleep(250_000)
        let (cpu, tCPU) = timed { cpuSampler.sample() }; overhead["cpu"] = tCPU
        let (mem, tMem) = timed { MemoryCollector.snapshot() }; overhead["memory"] = tMem
        var gs = GPUSampler()
        let (gpu, tGPU) = timed { gs.sample() }; overhead["gpu"] = tGPU
        let (thermal, tTh) = timed { ThermalCollector.snapshot(includePmset: true) }; overhead["thermal+pmset"] = tTh
        let (power, tPow) = timed { PowerCollector.snapshot() }; overhead["power"] = tPow
        let (vol, tVol) = timed { StorageCollector.volume("/") }; overhead["volume"] = tVol
        let (procs, tProc) = timed { ProcessCollector.list() }; overhead["processes"] = tProc
        let fullSampler = SystemSampler()
        _ = await fullSampler.snapshot()
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = await fullSampler.snapshot()
        overhead["full snapshot"] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        _ = await fullSampler.snapshot(includeProcesses: false)
        let t1 = DispatchTime.now().uptimeNanoseconds
        _ = await fullSampler.snapshot(includeProcesses: false)
        overhead["light snapshot (monitor)"] = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6

        func item(_ n: String, _ ok: Bool, _ p: Provenance, _ d: String) -> DoctorItem {
            DoctorItem(name: n, status: ok ? "available" : "unavailable", provenance: p.rawValue, detail: d)
        }
        let accessible = procs.filter(\.accessible).count
        let gpuPer = gpu.processProvenance != .unavailable
        let metrics = [
            item("CPU total & per-core", cpu != nil, .measured, "host_processor_info; \(cpu?.cores.count ?? 0) cores"),
            item("P/E core mapping", cpu?.cores.contains { $0.cluster != nil } ?? false, .measured, "IODeviceTree cpus/cluster-type"),
            item("Load average", !(cpu?.loadAverage.isEmpty ?? true), .measured, "getloadavg"),
            item("Memory breakdown", mem != nil, .measured, "host_statistics64 (HOST_VM_INFO64)"),
            item("Memory pressure", mem.map { $0.pressure != .unknown } ?? false, .measured, "kern.memorystatus_vm_pressure_level"),
            item("Swap", mem != nil, .measured, "vm.swapusage"),
            item("Per-process memory/CPU", accessible > 0, .measured, "libproc; \(accessible)/\(procs.count) processes readable (others require root)"),
            item("GPU utilization", gpu.utilization.value != nil, gpu.utilization.provenance, gpu.utilization.source),
            item("Per-process GPU time", gpuPer, gpu.processProvenance, "IORegistry AGX user-client AppUsage"),
            item("GPU power / GPU memory per process", false, .unavailable, "Needs `sudo powermetrics` or private APIs — not collected"),
            item("Thermal pressure", true, .measured, "ProcessInfo.thermalState = \(thermal.state.rawValue)"),
            item("CPU speed limit", thermal.cpuSpeedLimit.value != nil, thermal.cpuSpeedLimit.provenance, thermal.cpuSpeedLimit.note ?? "pmset -g therm"),
            item("CPU/GPU temperature", false, .unavailable, "SMC/HID sensors are private; MacPulse does not read them"),
            item("Battery temperature", thermal.batteryTemperatureC.value != nil, thermal.batteryTemperatureC.provenance, thermal.batteryTemperatureC.note ?? "AppleSmartBattery"),
            item("Battery health", power.healthPercent.value != nil, power.healthPercent.provenance, power.healthPercent.source),
            item("Volume capacity", vol != nil, .measured, "URLResourceValues"),
            item("Purgeable space", vol?.purgeableEstimate.value != nil, .estimated, "availableForImportantUsage − available"),
            item("APFS snapshot sizes", false, .unavailable, "Snapshot sizes require root; names/dates via tmutil"),
            item("MetricKit", false, .unavailable, "MetricKit reports only the app's own diagnostics (daily), not system-wide metrics"),
        ]
        func canList(_ p: String) -> Bool { (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil }
        let home = NSHomeDirectory()
        let fda = canList(home + "/Library/Safari") || canList(home + "/Library/Mail")
        let permissions = [
            DoctorItem(name: "Full Disk Access", status: fda ? "granted" : "not granted", provenance: "measured",
                       detail: fda ? "Protected folders can be analyzed" : "Optional: grant in System Settings › Privacy & Security › Full Disk Access to include Safari/Mail/Trash caches"),
            DoctorItem(name: "Trash readable", status: canList(home + "/.Trash") ? "yes" : "no", provenance: "measured", detail: home + "/.Trash"),
            DoctorItem(name: "Running as root", status: getuid() == 0 ? "yes (not recommended)" : "no", provenance: "measured", detail: "MacPulse never needs administrator rights"),
        ]
        let store = openStore()
        let out = DoctorOutput(system: SystemInfo.current(), metrics: metrics, permissions: permissions,
                               monitor: LaunchAgentManager().status(), overheadMilliseconds: overhead,
                               databasePath: AppPaths.database, databaseBytes: store?.fileSize)
        emit(out) {
            var o = Style.bold("MacPulse doctor") + "\n"
            let s = out.system
            o += "  \(s.modelIdentifier) · \(s.chip) · \(s.architecture) · macOS \(s.osVersion) (\(s.osBuild ?? "?")) · \(Format.memory(s.physicalMemory))"
            if let p = s.performanceCores, let e = s.efficiencyCores { o += " · \(p)P+\(e)E" }
            o += "\n" + heading("Metric availability")
            var t = Table(["Metric", "Status", "Provenance", "Source / note"], flexible: 3)
            for m in metrics {
                t.add([m.name, m.status == "available" ? Style.green("✓ available") : Style.dim("✗ unavailable"), m.provenance, m.detail])
            }
            o += t.render() + heading("Permissions")
            for p in permissions { o += "  \(p.name): \(Style.bold(p.status))  \(Style.dim(p.detail))\n" }
            o += heading("Background monitor")
            let m = out.monitor
            o += "  " + (m.loaded ? Style.green("running") + (m.pid.map { " (pid \($0))" } ?? "") : m.installed ? Style.yellow("installed, not loaded") : Style.dim("not installed (opt-in: macpulse monitor install)")) + "\n"
            o += "  Database: \(out.databasePath) \(out.databaseBytes.map { "(\(Format.bytes($0)))" } ?? "")\n"
            o += heading("Collector overhead (this run)")
            for (k, v) in overhead.sorted(by: { $0.key < $1.key }) { o += "  \(k.padding(toLength: 26, withPad: " ", startingAt: 0)) \(String(format: "%7.2f ms", v))\n" }
            o += Style.dim("  * measured-undocumented: real values from IORegistry driver statistics, not a documented API.") + "\n"
            return o
        }
        return 0
    }

    // MARK: cpu

    func cpu() async throws -> Int32 {
        let snap = await SystemSampler().measured(interval: try args.double("interval", 1))
        guard let c = snap.cpu else { throw MacPulseError.unavailable("CPU statistics") }
        let hist = (try? openStore()?.samples(since: Date().addingTimeInterval(-3600 * 6))) ?? []
        struct Out: Encodable { var cpu: CPUSnapshot; var top: [ProcessRecord]; var history: HistorySummary }
        let top = snap.topProcesses(by: .cpu, limit: try args.int("limit", 12))
        emit(Out(cpu: c, top: top, history: HistorySummary.compute(hist))) {
            var o = Style.bold("CPU") + "  \(Format.percent(c.total, digits: 1)) busy (user \(Format.percent(c.user, digits: 1)), system \(Format.percent(c.system, digits: 1)))\n"
            o += "  Load average: \(c.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / ")) on \(c.logicalCPUs) logical CPUs\n"
            if let p = c.performanceAverage, let e = c.efficiencyAverage {
                o += "  Performance cores \(Format.percent(p)) · Efficiency cores \(Format.percent(e))\n"
            }
            o += heading("Per core")
            for core in c.cores {
                o += "  \(String(format: "%2d", core.index)) \(core.cluster ?? "-") \(Style.bar(core.total, width: 30)) \(Format.percent(core.total))\n"
            }
            let cpuHist = hist.compactMap(\.cpu)
            if !cpuHist.isEmpty { o += heading("Last 6 h") + "  " + Style.sparkline(cpuHist, width: 60) + Style.dim("  avg \(Format.percent(cpuHist.reduce(0, +) / Double(cpuHist.count)))") + "\n" }
            o += heading("Busiest processes")
            var t = Table(["PID", "Process", "CPU", "CPU time", "Threads", "Runtime", "Category"],
                          aligns: [.right, .left, .right, .right, .right, .right, .left], flexible: 1)
            for p in top {
                t.add([String(p.pid), p.name, Format.percent(p.cpuPercent, digits: 1), Format.duration(p.cpuTimeSeconds),
                       p.threads.map(String.init) ?? "—", Format.duration(p.runtime), p.category.rawValue])
            }
            o += t.render()
            o += Style.dim("CPU % is per core (100% = one fully busy core), matching Activity Monitor.") + "\n"
            return o
        }
        return 0
    }

    // MARK: memory

    func memory() async throws -> Int32 {
        let snap = await SystemSampler().measured(interval: 0.5)
        guard let m = snap.memory else { throw MacPulseError.unavailable("memory statistics") }
        let store = openStore()
        let samples = (try? store?.samples(since: Date().addingTimeInterval(-3600 * 6))) ?? []
        let summary = HistorySummary.compute(samples + [HistorySample(snap)])
        var ctx = ProcessAnalyzer.Context(records: snap.processes, physicalMemory: m.physical)
        ctx.thresholds = config.thresholds
        if let s = try? store?.processSeries(since: Date().addingTimeInterval(-7200)) { ctx.history = s.mapValues(\.points) }
        let findings = ProcessAnalyzer.findings(ctx).filter { [.largeMemory, .memoryGrowth, .duplicateInstances].contains($0.kind) }
        let groups = Array(ProcessAnalyzer.appGroups(snap.processes).prefix(try args.int("limit", 12)))
        struct Out: Encodable { var memory: MemorySnapshot; var history: HistorySummary; var apps: [AppGroup]; var findings: [ProcessFinding] }
        emit(Out(memory: m, history: summary, apps: groups, findings: findings)) {
            var o = Style.bold("Memory") + "  pressure " + Style.severity(m.pressure == .normal ? .ok : m.pressure == .warning ? .warning : .critical, m.pressure.rawValue.uppercased())
            o += m.availablePercent.map { Style.dim("  (kernel reports \($0)% available)") } ?? ""
            o += "\n"
            var t = Table(["", "Bytes", "Of RAM"], aligns: [.left, .right, .right])
            func row(_ n: String, _ v: UInt64) { t.add([n, Format.memory(v), Format.percent(Double(v) / Double(max(m.physical, 1)) * 100)]) }
            row("Physical memory", m.physical); row("Used (app+wired+compressed)", m.used); row("  App memory", m.app)
            row("  Wired", m.wired); row("  Compressed", m.compressed); row("Cached files", m.cachedFiles)
            row("Active", m.active); row("Inactive", m.inactive); row("Free", m.free)
            o += t.render()
            o += "  Swap \(Format.memory(m.swapUsed)) of \(Format.memory(m.swapTotal))\(m.swapEncrypted ? " (encrypted)" : "") · swap-ins \(m.swapins) · swap-outs \(m.swapouts) since boot\n"
            if let g = summary.swapGrowthPerHour { o += "  Swap trend (1 h): \(g >= 0 ? "+" : "")\(Format.memory(Int64(g)))/h" + Style.dim(String(format: " (R² %.2f)", summary.swapGrowthR2 ?? 0)) + "\n" }
            else { o += Style.dim("  Swap trend needs ≥10 min of history (enable the background monitor).") + "\n" }
            let used = samples.compactMap(\.memoryUsed).map { Double($0) }
            if !used.isEmpty { o += "  Used, last 6 h: " + Style.sparkline(used, width: 50) + "\n" }
            o += Style.dim("  'Free' memory being low is normal on macOS; pressure and swapping are what matter.") + "\n"
            o += heading("Largest apps (helpers grouped)")
            var g = Table(["App / process", "Memory", "CPU", "Procs", "Category"], aligns: [.left, .right, .right, .right, .left], flexible: 0)
            for a in groups { g.add([a.name, Format.memory(a.footprint), Format.percent(a.cpuPercent, digits: 1), String(a.pids.count), a.category.rawValue]) }
            o += g.render()
            if !findings.isEmpty {
                o += heading("Findings")
                for f in findings { o += "  • \(f.title) " + Style.dim("[\(f.confidence.rawValue) confidence, \(f.provenance.label)]") + "\n" }
            }
            return o
        }
        return 0
    }

    // MARK: gpu

    func gpu() async throws -> Int32 {
        let sample = try args.double("sample", 2)
        let snap = await SystemSampler().measured(interval: sample, includeProcesses: true)
        let g = snap.gpu
        let hist = (try? openStore()?.samples(since: Date().addingTimeInterval(-3600 * 6))) ?? []
        let limit = try args.int("limit", 12)
        struct Out: Encodable { var gpu: GPUSnapshot; var cpuTotal: Double?; var thermal: ThermalState; var history: [Double] }
        emit(Out(gpu: g, cpuTotal: snap.cpu?.total, thermal: snap.thermal.state, history: hist.compactMap(\.gpu))) {
            var o = Style.bold("GPU") + "\n"
            for d in g.devices {
                o += "  \(d.name)\(d.coreCount.map { " · \($0) cores" } ?? "")\n"
                o += "    Device \(Style.bar(d.deviceUtilization)) \(Format.percent(d.deviceUtilization))   Renderer \(Format.percent(d.rendererUtilization))   Tiler \(Format.percent(d.tilerUtilization))\n"
                if let u = d.inUseSystemMemory { o += "    Driver-reported GPU memory in use: \(Format.memory(u)) (unified memory)\n" }
            }
            if g.devices.isEmpty { o += Style.dim("  No IOAccelerator devices found.") + "\n" }
            o += "  Source: \(g.utilization.source) — \(Style.provenance(g.utilization.provenance))\n"
            o += "  Correlation now: CPU \(Format.percent(snap.cpu?.total)) · thermal \(snap.thermal.state.rawValue)\n"
            let gh = hist.compactMap(\.gpu)
            if !gh.isEmpty { o += "  Last 6 h: " + Style.sparkline(gh, width: 50) + "\n" }
            o += heading("GPU time by process (last \(String(format: "%.0f", sample)) s)")
            var t = Table(["PID", "Process", "GPU share", "Total GPU time", "API"], aligns: [.right, .left, .right, .right, .left], flexible: 1)
            for p in g.processes.prefix(limit) where (p.recentPercent ?? 0) > 0.05 || p.accumulatedSeconds > 1 {
                t.add([String(p.pid), p.name, Format.percent(p.recentPercent, digits: 1), Format.duration(p.accumulatedSeconds), p.apis.joined(separator: ",")])
            }
            o += t.render()
            let browsers = g.processes.filter { p in ["Chrome", "Safari", "WebKit", "Firefox", "Edge", "Brave", "Arc", "Helper"].contains(where: p.name.contains) && (p.recentPercent ?? 0) > 1 }
            if !browsers.isEmpty {
                o += Style.yellow("  Browser/Electron GPU processes are active — WebGL, WebGPU, video and CSS effects render there.") + "\n"
            }
            for n in g.notes { o += Style.dim("  " + n) + "\n" }
            return o
        }
        return 0
    }

    // MARK: thermal & battery

    func thermal() async throws -> Int32 {
        let snap = await SystemSampler().measured(interval: 1, includeProcesses: true, includePmset: true)
        let th = snap.thermal
        let hist = (try? openStore()?.samples(since: Date().addingTimeInterval(-86400))) ?? []
        let summary = HistorySummary.compute(hist + [HistorySample(snap)])
        struct Out: Encodable { var thermal: ThermalSnapshot; var power: PowerSnapshot; var history: HistorySummary; var cpu: Double?; var gpu: Double? }
        emit(Out(thermal: th, power: snap.power, history: summary, cpu: snap.cpu?.total, gpu: snap.gpu.utilization.value)) {
            var o = Style.bold("Thermal") + "\n"
            o += "  Thermal pressure: \(Style.severity(th.state == .nominal ? .ok : th.state == .fair ? .info : .critical, th.state.rawValue.uppercased())) \(Style.dim("[measured — ProcessInfo.thermalState]"))\n"
            o += "  CPU speed limit:  \(th.cpuSpeedLimit.value.map { "\($0)%" } ?? "—") \(Style.dim("[\(th.cpuSpeedLimit.provenance.label)] \(th.cpuSpeedLimit.note ?? "")"))\n"
            o += "  Throttling:       \(th.throttlingIndicator.likely ? Style.yellow("likely") : "no indication") \(Style.dim("[inferred]")) \(th.throttlingIndicator.reasons.joined(separator: "; "))\n"
            o += "  CPU temperature:  — \(Style.dim("[unavailable] \(th.cpuTemperatureC.note ?? "")"))\n"
            o += "  Battery temp:     \(th.batteryTemperatureC.value.map { String(format: "%.1f °C", $0) } ?? "—") \(Style.dim("[\(th.batteryTemperatureC.provenance.label)]"))\n"
            o += "  Low Power Mode:   \(th.lowPowerMode ? "on" : "off") · power source \(snap.power.source)\n"
            o += "  Load now:         CPU \(Format.percent(snap.cpu?.total)) · GPU \(Format.percent(snap.gpu.utilization.value))\n"
            if summary.sampleCount > 1 {
                o += "  Last 24 h:        thermal ≥ serious for \(Int(summary.thermalElevatedMinutes)) min\n"
                let th = hist.compactMap(\.thermal).map { Double($0) }
                if !th.isEmpty { o += "                    " + Style.sparkline(th, width: 50) + Style.dim("  (0 nominal … 3 critical)") + "\n" }
            } else {
                o += Style.dim("  Enable the background monitor to record thermal history.") + "\n"
            }
            if snap.system.modelIdentifier.hasPrefix("Mac") && snap.power.hasBattery {
                o += Style.dim("  Fanless and thin notebooks reach 'fair'/'serious' sooner under sustained load; this is expected protective behavior.") + "\n"
            }
            return o
        }
        return 0
    }

    func battery() -> Int32 {
        let p = PowerCollector.snapshot()
        emit(p) {
            guard p.hasBattery else { return "No battery. Power source: \(p.source)" }
            var o = Style.bold("Battery") + "\n"
            o += "  Charge: \(p.chargePercent.map { "\($0)%" } ?? "—")\(p.isCharging == true ? " (charging)" : p.fullyCharged == true ? " (fully charged)" : "") · source \(p.source)\n"
            if let m = p.minutesRemaining { o += "  Time remaining: \(Format.duration(Double(m) * 60))\n" }
            o += "  Maximum capacity: \(Format.percent(p.healthPercent.value, digits: 1)) \(Style.dim("[\(p.healthPercent.provenance.label)] \(p.healthPercent.note ?? "")"))\n"
            o += "  Design \(p.designCapacity_mAh.map { "\($0) mAh" } ?? "—") · nominal full charge \(p.nominalCapacity_mAh.map { "\($0) mAh" } ?? "—") · raw max \(p.rawMaxCapacity_mAh.map { "\($0) mAh" } ?? "—")\n"
            o += "  Cycle count: \(p.cycleCount.map(String.init) ?? "—")\n"
            o += "  Voltage \(p.voltage_mV.map { String(format: "%.2f V", Double($0) / 1000) } ?? "—") · current \(p.amperage_mA.map { "\($0) mA" } ?? "—") · battery power \(p.batteryPowerW.value.map { String(format: "%.1f W", $0) } ?? "—") \(Style.dim("[estimated]"))\n"
            if let w = p.adapterWatts { o += "  Adapter: \(w) W\n" }
            return o
        }
        return 0
    }

    // MARK: monitor

    func monitor(_ sub: String?) async throws -> Int32 {
        switch sub {
        case "install":
            let exe = try installedExecutablePath()
            print("This installs a per-user LaunchAgent that runs '\(exe) monitor run' at login,")
            print("sampling every \(Int(config.sampleIntervalSeconds)) s (\(config.reduceSamplingOnBattery ? "doubled on battery" : "constant")), keeping \(config.retentionDays) days of history.")
            guard try confirm("Install the background monitor?", args: args) else { print("Cancelled."); return 1 }
            try LaunchAgentManager().install(executable: exe)
            print(Style.green("Installed.") + " Disable any time with: macpulse monitor uninstall")
            return 0
        case "uninstall":
            try LaunchAgentManager().uninstall()
            print("Background monitor removed. History remains in \(AppPaths.database) (delete it manually if desired).")
            return 0
        case "status":
            let s = LaunchAgentManager().status()
            let counts = try? openStore()?.counts()
            struct Out: Encodable { var agent: LaunchAgentManager.Status; var samples: Int?; var events: Int? }
            emit(Out(agent: s, samples: counts?.samples, events: counts?.events)) {
                "Installed: \(s.installed) · Loaded: \(s.loaded)\(s.pid.map { " · pid \($0)" } ?? "")\nPlist: \(s.plistPath)\nStored samples: \(counts?.samples ?? 0) · events: \(counts?.events ?? 0)"
            }
            return 0
        case "run":
            guard let store = openStore() else { throw MacPulseError.failed("cannot open history database") }
            let agent = MonitorAgent(store: store, config: config)
            printErr("[\(Date())] MacPulse monitor started (interval \(Int(config.sampleIntervalSeconds)) s)")
            let task = Task { await agent.run() }
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            signal(SIGTERM, SIG_IGN)
            source.setEventHandler { task.cancel() }
            source.resume()
            await task.value
            printErr("[\(Date())] MacPulse monitor stopped")
            return 0
        case nil, "live":
            return try await liveMonitor()
        default:
            throw MacPulseError.usage("monitor [install|uninstall|status|run]")
        }
    }

    func installedExecutablePath() throws -> String {
        let candidates = [Bundle.main.executablePath, CommandLine.arguments.first].compactMap { $0 }
        for c in candidates {
            let resolved = (c.hasPrefix("/") ? c : FileManager.default.currentDirectoryPath + "/" + c)
            if let real = realpath(resolved, nil) { defer { free(real) }; return String(cString: real) }
        }
        throw MacPulseError.failed("cannot determine the macpulse executable path")
    }

    func liveMonitor() async throws -> Int32 {
        let interval = try args.double("interval", config.uiRefreshSeconds)
        let count = try args.int("count", 0)
        let sampler = SystemSampler()
        _ = await sampler.snapshot()
        var cpuHist: [Double] = [], memHist: [Double] = [], gpuHist: [Double] = []
        var n = 0
        let tty = isatty(STDOUT_FILENO) == 1
        while count == 0 || n < count {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            let s = await sampler.snapshot()
            n += 1
            if json { print(JSON.string(HistorySample(s), pretty: false)); fflush(stdout); continue }
            if let c = s.cpu?.total { cpuHist.append(c) }
            if let m = s.memory { memHist.append(Double(m.used) / Double(max(m.physical, 1)) * 100) }
            if let g = s.gpu.utilization.value { gpuHist.append(g) }
            cpuHist = Array(cpuHist.suffix(60)); memHist = Array(memHist.suffix(60)); gpuHist = Array(gpuHist.suffix(60))
            var o = tty ? "\u{1B}[H\u{1B}[2J" : ""
            o += Style.bold("MacPulse live") + Style.dim("  \(Format.date(s.timestamp)) · every \(String(format: "%.0f", interval)) s · Ctrl-C to quit") + "\n\n"
            o += "  CPU     \(Style.bar(s.cpu?.total, width: 24)) \(Format.percent(s.cpu?.total).padding(toLength: 5, withPad: " ", startingAt: 0)) \(Style.sparkline(cpuHist, width: 40))\n"
            if let m = s.memory {
                o += "  Memory  \(Style.bar(memHist.last, width: 24)) \(Format.percent(memHist.last).padding(toLength: 5, withPad: " ", startingAt: 0)) \(Style.sparkline(memHist, width: 40))  \(m.pressure.rawValue) · swap \(Format.memory(m.swapUsed))\n"
            }
            o += "  GPU     \(Style.bar(s.gpu.utilization.value, width: 24)) \(Format.percent(s.gpu.utilization.value).padding(toLength: 5, withPad: " ", startingAt: 0)) \(Style.sparkline(gpuHist, width: 40))\n"
            o += "  Thermal \(s.thermal.state.rawValue)   Disk \(Format.bytes(s.volume?.available)) free   Load \(s.cpu?.loadAverage.first.map { String(format: "%.1f", $0) } ?? "—")\n\n"
            var t = Table(["PID", "Process", "CPU", "Memory"], aligns: [.right, .left, .right, .right], flexible: 1)
            for p in s.topProcesses(by: .cpu, limit: 12) { t.add([String(p.pid), p.name, Format.percent(p.cpuPercent, digits: 1), Format.memory(p.footprint)]) }
            o += t.render()
            print(o, terminator: "")
            fflush(stdout)
        }
        return 0
    }

    // MARK: history / events / recommend

    func history() throws -> Int32 {
        guard let store = openStore() else { throw MacPulseError.failed("cannot open history database") }
        let hours = try args.double("hours", 24)
        let samples = try store.samples(since: Date().addingTimeInterval(-hours * 3600))
        if args.has("csv") { print(ReportBuilder.historyCSV(samples), terminator: ""); return 0 }
        let summary = HistorySummary.compute(samples)
        struct Out: Encodable { var hours: Double; var summary: HistorySummary; var samples: [HistorySample] }
        emit(Out(hours: hours, summary: summary, samples: samples)) {
            guard !samples.isEmpty else {
                return "No history in the last \(Int(hours)) h. Enable the background monitor: macpulse monitor install"
            }
            var o = Style.bold("History") + Style.dim("  \(samples.count) samples over \(Format.duration(summary.span))") + "\n\n"
            let metric = args.value("metric")
            func line(_ name: String, _ values: [Double], _ fmt: (Double) -> String) {
                guard metric == nil || metric == name, !values.isEmpty else { return }
                let avg = values.reduce(0, +) / Double(values.count)
                o += "  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(Style.sparkline(values, width: 60))  min \(fmt(values.min()!)) · avg \(fmt(avg)) · max \(fmt(values.max()!))\n"
            }
            line("cpu", samples.compactMap(\.cpu)) { Format.percent($0) }
            line("memory", samples.compactMap(\.memoryUsed).map { Double($0) }) { Format.memory(Int64($0)) }
            line("swap", samples.compactMap(\.swapUsed).map { Double($0) }) { Format.memory(Int64($0)) }
            line("gpu", samples.compactMap(\.gpu)) { Format.percent($0) }
            line("thermal", samples.compactMap(\.thermal).map { Double($0) }) { ["nominal", "fair", "serious", "critical"][min(3, Int($0))] }
            line("disk", samples.compactMap(\.diskFree).map { Double($0) }) { Format.bytes(Int64($0)) }
            if let g = summary.swapGrowthPerHour { o += "\n  Swap trend (last hour): \(Format.memory(Int64(g)))/h\n" }
            if let d = summary.diskFreeChangePerDay { o += "  Free-space trend: \(Format.bytes(Int64(d)))/day\n" }
            o += "  Thermal ≥ serious: \(Int(summary.thermalElevatedMinutes)) min · memory pressure elevated: \(Int(summary.pressureElevatedMinutes)) min\n"
            return o
        }
        return 0
    }

    func events() throws -> Int32 {
        guard let store = openStore() else { throw MacPulseError.failed("cannot open history database") }
        let ev = try store.events(since: Date().addingTimeInterval(-(try args.double("hours", 24 * 7)) * 3600))
        emit(ev) {
            guard !ev.isEmpty else { return "No alerts recorded." }
            var t = Table(["Time", "Severity", "Alert", "Detail"], flexible: 3)
            for e in ev { t.add([Format.date(e.timestamp), Style.severity(e.severity, e.severity.rawValue), e.title, e.detail]) }
            return t.render()
        }
        return 0
    }

    func recommend() async throws -> Int32 {
        let snap = await SystemSampler().measured(interval: 1)
        let storage: StorageAnalysis? = args.has("with-storage") ? CleanupScanner().scan(options: {
            var o = ScanOptions(); o.includeProtectedInventory = false; o.includeSnapshots = false; return o }()) : nil
        let report = ReportBuilder.build(snapshot: snap, store: openStore(), storage: storage, config: config)
        emit(report.recommendations) {
            guard !report.recommendations.isEmpty else { return Style.green("✓ No recommendations — the system looks healthy.") }
            var o = ""
            for (i, r) in report.recommendations.enumerated() {
                o += "\(i + 1). " + Style.severity(r.severity, "[\(r.severity.rawValue.uppercased())] ") + Style.bold(r.title) + "\n"
                o += "   \(r.detail)\n"
                o += Style.dim("   confidence \(r.confidence.rawValue) · benefit \(r.benefit.rawValue) · risk \(r.risk.rawValue) · effort \(r.effort.rawValue) · \(r.reversible ? "reversible" : "not reversible") · priority \(String(format: "%.2f", r.priority))") + "\n"
                o += "   Expected effect: \(r.expectedEffect)\n"
                for e in r.evidence { o += Style.dim("   · \(e)") + "\n" }
                if let a = r.actionHint { o += "   → " + Style.cyan(a) + "\n" }
                o += "\n"
            }
            if storage == nil { o += Style.dim("Tip: add --with-storage to include disk-cleanup estimates.") + "\n" }
            return o
        }
        return 0
    }

    // MARK: report

    func report() async throws -> Int32 {
        let fmtName = args.value("format") ?? (json ? "json" : "markdown")
        guard let format = ReportFormat(rawValue: fmtName == "md" ? "markdown" : fmtName) else {
            throw MacPulseError.usage("--format must be markdown, json, csv or html")
        }
        let snap = await SystemSampler().measured(interval: 1)
        var storage: StorageAnalysis?
        if args.has("with-storage") {
            var o = ScanOptions(); o.includeSnapshots = true
            storage = CleanupScanner().scan(options: o)
        }
        let rep = ReportBuilder.build(snapshot: snap, store: openStore(), storage: storage, config: config)
        let text = ReportBuilder.render(rep, as: format)
        if let out = args.value("output") {
            let path = (out as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) && !args.has("overwrite") {
                throw MacPulseError.refused("\(path) exists; pass --overwrite to replace it")
            }
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            printErr("Report written to \(path)")
        } else {
            print(text)
        }
        return 0
    }

    // MARK: config

    func configCommand(_ sub: String?) throws -> Int32 {
        switch sub {
        case nil, "show":
            emit(config) { JSON.string(config) }
        case "path":
            print(AppPaths.config)
        case "set":
            let rest = Array(args.positionals.dropFirst(2))
            guard rest.count == 2 else { throw MacPulseError.usage("config set KEY VALUE") }
            var c = config
            try c.set(rest[0], rest[1])
            try c.save()
            print("Set \(rest[0]) = \(rest[1])")
        case "reset":
            try MacPulseConfig().save()
            print("Configuration reset to defaults.")
        default:
            throw MacPulseError.usage("config [show|set KEY VALUE|path|reset]")
        }
        return 0
    }
}
