import Darwin
import Foundation
import MacPulseCore

extension Commands {
    // MARK: why

    func why() async throws -> Int32 {
        let store = openStore()
        let snap = await SystemSampler().measured(interval: try args.double("interval", 2))
        let history = (try? store?.samples(since: Date().addingTimeInterval(-86400))) ?? []
        let series = ((try? store?.processSeries(since: Date().addingTimeInterval(-7200))) ?? [:]).mapValues(\.points)
        var ctx = ProcessAnalyzer.Context(records: snap.processes, physicalMemory: snap.system.physicalMemory)
        ctx.history = series
        ctx.thresholds = config.thresholds
        let d = SlowdownDetective.diagnose(.init(snapshot: snap, history: history, processHistory: series,
                                                 findings: ProcessAnalyzer.findings(ctx), thresholds: config.thresholds))
        emit(d) {
            var o = Style.bold("Why is my Mac slow?") + "\n\n  " + (d.isClear ? Style.green(d.verdict) : Style.yellow(d.verdict)) + "\n"
            o += heading("Resource pressure (0–100, inferred from measured signals)")
            for key in ["memory", "cpu", "thermal", "storage", "gpu"] {
                guard let v = d.pressure[key] else { continue }
                o += "  \(key.padding(toLength: 8, withPad: " ", startingAt: 0)) \(Style.bar(Double(v), width: 24)) \(v)\n"
            }
            o += heading("Compared with this Mac's baseline")
            o += Style.dim("  " + d.baselineDescription) + "\n"
            for c in d.changes {
                o += "  \(c.metric.padding(toLength: 12, withPad: " ", startingAt: 0)) \(c.baseline.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(c.worse ? Style.yellow(c.now) : c.now)\n"
            }
            o += heading("Likely causes")
            if d.causes.isEmpty { o += Style.green("  Nothing stands out.") + "\n" }
            for (i, c) in d.causes.enumerated() {
                let impact = c.impact == .high ? Style.red("high") : c.impact == .medium ? Style.yellow("medium") : Style.dim("low")
                o += "  \(i + 1). " + Style.bold(c.title) + Style.dim("  [impact ") + impact + Style.dim(", confidence \(c.confidence.rawValue)]") + "\n"
                for e in c.evidence { o += Style.dim("     · \(e)") + "\n" }
                o += "     → \(c.suggestion)\n"
            }
            if history.isEmpty { o += Style.dim("\nTip: enable the background monitor (macpulse monitor install) for baseline comparisons.") + "\n" }
            return o
        }
        return d.bottleneck == .none ? 0 : 3
    }

    // MARK: energy

    func energy() async throws -> Int32 {
        let sample = try args.double("sample", 3)
        let snap = await SystemSampler().measured(interval: sample)
        let groups = ProcessAnalyzer.appGroups(snap.processes.filter { $0.powerWatts != nil })
            .sorted { ($0.powerWatts ?? 0) > ($1.powerWatts ?? 0) }
        let total = snap.processes.compactMap(\.powerWatts).reduce(0, +)
        let limit = try args.int("limit", 15)
        struct Out: Encodable { var accountedWatts: Double; var batteryWatts: Double?; var source: String; var apps: [AppGroup]; var processes: [ProcessRecord] }
        let top = snap.topProcesses(by: .energy, limit: limit)
        emit(Out(accountedWatts: total, batteryWatts: snap.power.batteryPowerW.value, source: snap.power.source,
                 apps: Array(groups.prefix(limit)), processes: top)) {
            var o = Style.bold("Energy") + Style.dim("  over the last \(String(format: "%.0f", sample)) s · \(snap.power.source)") + "\n"
            o += "  Accounted to processes you can read: \(String(format: "%.2f W", total))" + Style.dim("  [kernel energy accounting]") + "\n"
            if let w = snap.power.batteryPowerW.value, w < -0.1 { o += "  Battery discharge: \(String(format: "%.1f W", -w))" + Style.dim("  (whole system incl. display)") + "\n" }
            o += heading("By app")
            var t = Table(["App / process", "Power", "Share", "CPU", "Wakeups/s"], aligns: [.left, .right, .right, .right, .right], flexible: 0)
            for g in groups.prefix(limit) {
                let p = g.powerWatts ?? 0
                t.add([g.name, String(format: "%.2f W", p), Format.percent(total > 0 ? p / total * 100 : nil), Format.percent(g.cpuPercent, digits: 1), String(Int(g.wakeupsPerSecond))])
            }
            o += t.render()
            o += heading("Most frequent wakeups")
            var w = Table(["PID", "Process", "Wakeups/s", "Power"], aligns: [.right, .left, .right, .right], flexible: 1)
            for p in snap.topProcesses(by: .wakeups, limit: 6) {
                w.add([String(p.pid), p.name, String(Int(p.wakeupsPerSecond ?? 0)), p.powerWatts.map { String(format: "%.2f W", $0) } ?? "—"])
            }
            o += w.render()
            o += Style.dim("Per-process energy comes from the kernel's accounting (rusage ri_energy_nj). It covers CPU-side energy; display, GPU and\nother devices are not fully attributed, so totals are lower than the battery's discharge rate. Other users' processes are not readable.") + "\n"
            return o
        }
        return 0
    }

    // MARK: ready / run --when-ready

    func readinessPolicy() throws -> ReadinessPolicy {
        var p = ReadinessPolicy()
        p.maxCPUPercent = try args.double("cpu", p.maxCPUPercent)
        if args.has("allow-fair") { p.maxThermal = .fair }
        return p
    }

    func ready() async throws -> Int32 {
        let sampler = SystemSampler()
        var recent: [SystemSnapshot] = [await sampler.snapshot(includeProcesses: false)]
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            recent.append(await sampler.snapshot(includeProcesses: false))
        }
        let r = Readiness.evaluate(Array(recent.dropFirst()), policy: try readinessPolicy())
        emit(r) {
            (r.ready ? Style.green("✓ Ready for heavy work") : Style.yellow("✗ Not ready")) + "\n"
                + r.blockers.map { "  blocked: \($0)" }.joined(separator: "\n") + (r.blockers.isEmpty ? "" : "\n")
                + Style.dim("  " + r.checks.joined(separator: " · "))
        }
        return r.ready ? 0 : 10
    }

    static func parseDuration(_ s: String) -> TimeInterval? {
        let t = s.lowercased()
        let mult: Double = t.hasSuffix("d") ? 86400 : t.hasSuffix("h") ? 3600 : t.hasSuffix("m") ? 60 : 1
        let num = t.trimmingCharacters(in: CharacterSet(charactersIn: "dhms"))
        return Double(num).map { $0 * mult }
    }

    func runWhenReady() async throws -> Int32 {
        let argv = CommandLine.arguments
        guard let sep = argv.firstIndex(of: "--"), sep + 1 < argv.count else {
            throw MacPulseError.usage("run --when-ready [--max-wait 30m] [--cpu 60] [--allow-fair] [--run-anyway] -- COMMAND [ARGS…]")
        }
        let command = Array(argv[(sep + 1)...])
        guard args.has("when-ready") else { throw MacPulseError.usage("run requires --when-ready") }
        guard let maxWait = Self.parseDuration(args.value("max-wait") ?? "30m") else { throw MacPulseError.usage("--max-wait expects e.g. 90s, 15m, 1h") }
        let policy = try readinessPolicy()
        let every = max(2, try args.double("check-every", 5))
        let sampler = SystemSampler()
        var window: [SystemSnapshot] = [await sampler.snapshot(includeProcesses: false)]
        let deadline = Date().addingTimeInterval(maxWait)
        var lastMessage = ""
        while true {
            try? await Task.sleep(nanoseconds: UInt64(every * 1e9))
            window.append(await sampler.snapshot(includeProcesses: false))
            window = Array(window.suffix(4))
            let r = Readiness.evaluate(Array(window.dropFirst()), policy: policy)
            if r.ready {
                printErr(Style.green("macpulse: ready (\(r.checks.joined(separator: ", "))) — starting: ") + command.joined(separator: " "))
                break
            }
            let msg = r.blockers.joined(separator: "; ")
            if msg != lastMessage { printErr(Style.dim("macpulse: waiting — \(msg)")); lastMessage = msg }
            if Date() >= deadline {
                if args.has("run-anyway") { printErr(Style.yellow("macpulse: max wait reached — starting anyway")); break }
                throw MacPulseError.locked("still not ready after \(Format.duration(maxWait)): \(msg)")
            }
        }
        fflush(stdout)
        // Replace this process with the command (argv vector, no shell). Exit status is the command's.
        var cargs: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        execvp(command[0], &cargs)
        let err = String(cString: strerror(errno))
        cargs.forEach { free($0) }
        throw MacPulseError.failed("cannot run \(command[0]): \(err)")
    }

    // MARK: disk growth

    func diskGrowth() throws -> Int32 {
        guard let store = openStore() else { throw MacPulseError.failed("cannot open history database") }
        var scans = try store.growthScans()
        if args.has("scan") || scans.isEmpty {
            if !json { printErr(Style.dim("Measuring folders (read-only, may take a minute)…")) }
            let scan = GrowthTracker.scan(includePersonal: args.has("personal"), previous: args.has("full") ? nil : scans.first)
            try store.recordGrowthScan(scan)
            scans.insert(scan, at: 0)
        }
        guard scans.count >= 2 else {
            let msg = "Baseline recorded (\(scans[0].folders.count) folders). Run 'macpulse disk growth --scan' later — or enable the background monitor, which scans daily — to see what grew."
            if json { print(JSON.string(["status": msg])) } else { print(msg) }
            return 0
        }
        let newest = scans[0]
        var older = scans[1]
        if let since = args.value("since") {
            guard let secs = Self.parseDuration(since) else { throw MacPulseError.usage("--since expects e.g. 12h, 7d") }
            older = scans.last { newest.timestamp.timeIntervalSince($0.timestamp) >= secs * 0.9 } ?? scans.last!
        }
        let report = GrowthTracker.compare(older, newest)
        let limit = try args.int("limit", 20)
        emit(report) {
            let home = NSHomeDirectory()
            func short(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
            func signed(_ v: Int64) -> String { (v > 0 ? "+" : "") + Format.bytes(v) }
            var o = Style.bold("Disk growth") + Style.dim("  \(Format.date(report.from)) → \(Format.date(report.to))") + "\n"
            if let m = newest.measuredCount {
                o += Style.dim("  Latest scan: \(String(format: "%.1f", newest.durationSeconds)) s · measured \(m) folder(s)" +
                               (newest.incremental ? ", reused \(newest.reusedCount ?? 0) unchanged (FSEvents journal)" : " (full scan)")) + "\n"
            }
            if let v = report.volumeUsedDelta { o += "  Startup volume used: \(v > 0 ? Style.yellow(signed(v)) : Style.green(signed(v)))\n" }
            if let s = report.swapDelta { o += "  Swap files:          \(signed(s))" + Style.dim("  (grows under memory pressure, shrinks after restart)") + "\n" }
            o += "  Tracked folders:     \(signed(report.trackedDelta))\n"
            if let u = report.unattributedDelta { o += "  Other (system, snapshots, untracked): \(signed(u))\n" }
            o += heading("Biggest changes")
            var t = Table(["Change", "Before", "After", "Folder"], aligns: [.right, .right, .right, .left], flexible: 3)
            for e in report.entries.prefix(limit) {
                t.add([e.delta > 0 ? Style.yellow(signed(e.delta)) : Style.green(signed(e.delta)), Format.bytes(e.before), Format.bytes(e.after), short(e.path)])
            }
            o += t.render()
            o += Style.dim("Allocated sizes. Privacy-protected folders are excluded unless you pass --personal. Scans kept: \(scans.count)/60.") + "\n"
            return o
        }
        return 0
    }
}

extension Commands {
    func offenders() throws -> Int32 {
        guard let store = openStore() else { throw MacPulseError.failed("cannot open history database") }
        let days = try args.double("days", 7)
        let limit = try args.int("limit", 5)
        let r = try OffenderAnalyzer.report(store: store, days: days, limit: limit)
        emit(r) {
            var o = Style.bold("Top offenders") + Style.dim("  last \(Int(days)) day(s) · \(r.processSamples) process samples") + "\n"
            if r.hotMinutes > 0 || r.pressureMinutes > 0 {
                o += "  Warm (thermal ≥ fair): \(Int(r.hotMinutes)) min · memory pressure elevated: \(Int(r.pressureMinutes)) min\n"
            }
            func section(_ title: String, _ list: [Offender]) {
                guard !list.isEmpty else { return }
                o += heading(title)
                for (i, x) in list.enumerated() { o += "  \(i + 1). " + Style.bold(x.name) + Style.dim("  \(x.detail)") + "\n" }
            }
            section("Heated the Mac", r.heat)
            section("Filled memory under pressure", r.memoryPressure)
            section("Most CPU", r.cpu)
            section("Most energy", r.energy)
            section("Most CPU wakeups", r.wakeups)
            section("Largest memory", r.memory)
            for n in r.notes { o += Style.dim("\n" + n) }
            return o + "\n"
        }
        return 0
    }
}
