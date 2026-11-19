import Foundation
import MacPulseCore

extension Commands {
    func autoclean(_ sub: String?) async throws -> Int32 {
        var cfg = config
        switch sub {
        case nil, "status":
            let store = openStore()
            let last = store.flatMap { AutoCleaner.lastRun($0) }
            let a = cfg.autoClean
            let runs = ((try? store?.cleanupHistory(limit: 500)) ?? []).filter { $0.runID.hasPrefix("auto-") }
            let agent = LaunchAgentManager().status()
            struct Out: Encodable { var config: AutoCleanConfig; var lastRun: Date?; var nextRun: Date?; var monitorRunning: Bool; var recentItems: [CleanupHistoryEntry] }
            let next = a.enabled ? (last.map { $0.addingTimeInterval(a.intervalDays * 86400) } ?? Date()) : nil
            emit(Out(config: a, lastRun: last, nextRun: next, monitorRunning: agent.loaded, recentItems: Array(runs.prefix(20)))) {
                var o = Style.bold("Automatic cleanup") + "  " + (a.enabled ? Style.green("ON") : Style.dim("OFF")) + "\n"
                o += "  Every \(Int(a.intervalDays)) day(s) · \(a.mode == .delete ? "delete permanently" : "move to Trash") · categories: \(a.categories.map(\.title).joined(separator: ", "))\n"
                o += "  Only SAFE items, idle ≥ \(Int(a.minIdleHours)) h, ≥ \(Format.bytes(a.minItemBytes)) each; apps in use are skipped.\n"
                o += "  Last run: \(last.map { Format.date($0) } ?? "never") · next: \(next.map { $0 <= Date() ? "due now" : Format.date($0) } ?? "—")\n"
                if a.enabled && !agent.loaded {
                    o += Style.yellow("  The background monitor is not running — cleanup runs only while the MacPulse app is open.") + "\n"
                    o += Style.dim("  Enable it for unattended runs: macpulse monitor install") + "\n"
                }
                if !runs.isEmpty {
                    o += heading("Recent automatic cleanups")
                    var t = Table(["Date", "Status", "Freed", "Path"], aligns: [.left, .left, .right, .left], flexible: 3)
                    for e in runs.prefix(15) { t.add([Format.date(e.timestamp), e.status, e.status == "trashed" ? "in Trash" : Format.bytes(e.removedBytes), e.path]) }
                    o += t.render()
                }
                return o
            }
            return 0
        case "enable", "disable":
            cfg.autoClean.enabled = sub == "enable"
            if let every = args.value("every") {
                guard let d = Double(every), d >= 1, d <= 90 else { throw MacPulseError.usage("--every expects days between 1 and 90") }
                cfg.autoClean.intervalDays = d
            }
            if let m = args.value("mode") {
                guard let mode = CleanupMode(rawValue: m) else { throw MacPulseError.usage("--mode must be delete or trash") }
                cfg.autoClean.mode = mode
            }
            if let cats = args.value("categories") {
                let parsed = try cats.split(separator: ",").map { raw -> CleanupCategory in
                    let s = raw.trimmingCharacters(in: .whitespaces)
                    guard let c = CleanupCategory(rawValue: s), AutoCleaner.eligibleCategories.contains(c) else {
                        throw MacPulseError.usage("category '\(s)' is not allowed; choose from \(AutoCleaner.eligibleCategories.map(\.rawValue).sorted().joined(separator: ", "))")
                    }
                    return c
                }
                cfg.autoClean.categories = parsed
            }
            try cfg.save()
            print(cfg.autoClean.enabled ? Style.green("Automatic cleanup enabled.") : "Automatic cleanup disabled.")
            if cfg.autoClean.enabled {
                print("Preview what it would clean: macpulse autoclean preview")
                if !LaunchAgentManager().status().loaded { print(Style.dim("For unattended runs also enable the monitor: macpulse monitor install")) }
            }
            return 0
        case "preview", "run":
            let dry = sub == "preview"
            var c = cfg.autoClean
            c.enabled = true
            if !json { printErr(Style.dim("Scanning…")) }
            let plan = AutoCleaner.select(CleanupScanner().scan(options: {
                var o = ScanOptions(); o.includeProtectedInventory = false; o.includeSnapshots = false; return o }()), config: c)
            if !dry {
                guard !plan.selected.isEmpty else { print("Nothing eligible to clean."); return 0 }
                print("Will \(c.mode == .delete ? Style.red("permanently delete") : "move to Trash") \(plan.selected.count) SAFE item(s), ≈ \(Format.bytes(plan.selected.map(\.estimatedBytes).reduce(0, +))).")
                guard try confirm("Run automatic cleanup now?", args: args) else { print("Cancelled."); return 1 }
            }
            let outcome = try AutoCleaner.run(config: c, store: openStore(), dryRun: dry)
            emit(outcome) {
                var o = Style.bold(dry ? "Automatic cleanup — preview (nothing changed)" : "Automatic cleanup — done") + "\n"
                var t = Table(["Result", "Size", "Path"], aligns: [.left, .right, .left], flexible: 2)
                for r in outcome.result?.items ?? [] {
                    let st = r.status == .dryRun ? Style.green("would clean") : r.status == .deleted || r.status == .trashed ? Style.green(r.status.rawValue) : Style.yellow(r.status.rawValue)
                    t.add([st, Format.bytes(r.status == .deleted ? r.removedBytes : r.estimatedBytes), r.path])
                }
                o += t.render()
                if !outcome.skipped.isEmpty {
                    o += heading("Skipped SAFE items")
                    for s in outcome.skipped.prefix(15) { o += Style.dim("  \(s.path) — \(s.reason)") + "\n" }
                }
                o += "\n" + outcome.summary + "\n"
                return o
            }
            return 0
        default:
            throw MacPulseError.usage("autoclean [status|enable|disable|preview|run] [--every DAYS] [--mode delete|trash] [--categories developerCache,logs,browserCache,applicationCache]")
        }
    }
}
