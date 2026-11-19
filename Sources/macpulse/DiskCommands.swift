import Foundation
import MacPulseCore

struct DiskCommands {
    let args: Args
    let config: MacPulseConfig
    var json: Bool { args.has("json") }

    func run(_ sub: String?) async throws -> Int32 {
        switch sub {
        case nil, "analyze": return try analyze()
        case "clean", "cleanup": return try clean()
        case "large": return try large()
        case "duplicates", "dupes": return try duplicates()
        case "history": return try history()
        default: throw MacPulseError.usage("disk [analyze|clean|large|duplicates|history]")
        }
    }

    func scanOptions() -> ScanOptions {
        var o = ScanOptions()
        o.includePersonalFolders = args.has("personal")
        o.includeProtectedInventory = !args.has("no-protected")
        o.includeSnapshots = !args.has("no-snapshots")
        return o
    }

    func progressNote(_ s: String) { if !json { printErr(Style.dim(s)) } }

    func analyze() throws -> Int32 {
        progressNote("Scanning (read-only)…")
        let analysis = CleanupScanner().scan(options: scanOptions())
        if json { print(JSON.string(analysis)); return 0 }
        var o = ""
        if let v = analysis.volume {
            o += Style.bold("Startup volume") + "  \(v.name ?? "/") · \(v.fileSystem ?? "")\n"
            o += "  Capacity \(Format.bytes(v.total)) · used \(Format.bytes(v.used)) · free \(Format.bytes(v.available)) (\(Format.percent(v.freePercent, digits: 1)))\n"
            if let imp = v.availableForImportantUsage { o += "  Available incl. purgeable: \(Format.bytes(imp)) → purgeable ≈ \(Format.bytes(v.purgeableEstimate.value)) \(Style.dim("[estimated]"))\n" }
        }
        for c in analysis.containers {
            o += "  APFS container \(c.reference): \(Format.bytes(c.capacity - c.free)) used of \(Format.bytes(c.capacity))\n"
            for vol in c.volumes.sorted(by: { $0.used > $1.used }).prefix(6) {
                o += Style.dim("    \(vol.name)\(vol.roles.isEmpty ? "" : " [\(vol.roles.joined(separator: ","))]"): \(Format.bytes(vol.used))") + "\n"
            }
        }
        if let snaps = analysis.localSnapshots {
            o += "  Local APFS snapshots: \(snaps.count)" + Style.dim(snaps.isEmpty ? "" : " (macOS deletes these automatically when space is needed; sizes require root)") + "\n"
        }
        o += heading("Reclaimable (estimated, allocated bytes)")
        o += "  \(Style.cls(.safe)) \(Format.bytes(analysis.bytes(.safe)))   \(Style.cls(.review)) \(Format.bytes(analysis.bytes(.review)))\n\n"
        for (cat, bytes) in analysis.byCategory() { o += "  \(cat.title.padding(toLength: 22, withPad: " ", startingAt: 0)) \(Format.bytes(bytes))\n" }
        o += heading("Candidates")
        var t = Table(["ID", "Class", "Size", "Modified", "Status", "Item"], aligns: [.left, .left, .right, .left, .left, .left], flexible: 5)
        let limit = try args.int("limit", 40)
        var blockedNotes: [String: String] = [:]
        for c in analysis.candidates.prefix(limit) {
            let status: String
            if !c.inUseBy.isEmpty { status = Style.yellow("in use") }
            else if let b = c.blockedReason { status = Style.yellow("blocked"); blockedNotes[c.id] = b }
            else { status = Style.green(c.allowsTrash ? (c.allowsDelete ? "ready" : "trash only") : "delete only") }
            let owner = c.inUseBy.isEmpty ? "" : Style.dim(" (quit \(c.inUseBy.joined(separator: ", ")))")
            t.add([c.id, Style.cls(c.classification), Format.bytes(c.estimatedBytes), Format.date(c.modified), status, "\(c.title) — \(abbreviate(c.path))" + owner])
        }
        o += t.render()
        for (id, note) in blockedNotes.sorted(by: { $0.key < $1.key }) { o += Style.dim("  \(id): \(note)") + "\n" }
        if analysis.candidates.count > limit { o += Style.dim("  … \(analysis.candidates.count - limit) more (use --limit or --json)") + "\n" }
        if !analysis.protectedItems.isEmpty {
            o += heading("Protected (shown for transparency, never cleaned)")
            for p in analysis.protectedItems {
                let size = p.usage.permissionDenied > 0 && p.usage.allocated == 0 ? "not readable" : Format.bytes(p.usage.allocated) + (p.usage.permissionDenied > 0 ? "+" : "")
                o += "  \(Style.cls(.protected)) \(size.padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.title) — \(Style.dim(p.reason))\n"
            }
        }
        for n in analysis.notes { o += Style.yellow("  note: ") + n + "\n" }
        if !args.has("personal") { o += Style.dim("  Downloads was not scanned; add --personal to include old installers there.") + "\n" }
        o += "\nNext: " + Style.cyan("macpulse disk clean --select ID,ID") + " (dry run) or " + Style.cyan("--all-safe") + "\n"
        o += Style.dim("Sizes are allocated blocks (sparse/compressed aware, hard links counted once). APFS clones may make actual savings smaller.") + "\n"
        print(o)
        return 0
    }

    func abbreviate(_ p: String) -> String {
        let h = NSHomeDirectory()
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    func clean() throws -> Int32 {
        let apply = args.has("apply")
        if apply && args.has("dry-run") { throw MacPulseError.usage("--apply and --dry-run are mutually exclusive") }
        guard let mode = CleanupMode(rawValue: args.value("mode") ?? "trash") else {
            throw MacPulseError.usage("--mode must be trash or delete")
        }
        let selection = Set((args.value("select") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let allSafe = args.has("all-safe")
        guard !selection.isEmpty || allSafe else {
            throw MacPulseError.usage("choose items with --select ID,ID (IDs from 'macpulse disk analyze') or --all-safe")
        }
        progressNote("Re-scanning to validate the selection…")
        let scanner = CleanupScanner()
        var opts = scanOptions(); opts.includeProtectedInventory = false; opts.includeSnapshots = false
        let analysis = scanner.scan(options: opts)
        var chosen = analysis.candidates.filter { selection.contains($0.id) }
        if allSafe { chosen += analysis.candidates.filter { $0.classification == .safe && $0.isSelectable && !selection.contains($0.id) } }
        let missing = selection.subtracting(chosen.map(\.id))
        if !missing.isEmpty { printErr(Style.yellow("Not found (changed or no longer present): ") + missing.sorted().joined(separator: ", ")) }
        guard !chosen.isEmpty else { throw MacPulseError.failed("nothing to clean") }
        // Trash-only items cannot be permanently deleted, and the Trash itself can only be deleted.
        let effectiveMode = { (c: CleanupCandidate) -> CleanupMode in
            if !c.allowsTrash { return .delete }
            if mode == .delete && !c.allowsDelete { return .trash }
            return mode
        }
        let guardian = PathGuard(rules: scanner.rules, allowPersonalFolders: args.has("personal"))
        let cleaner = Cleaner(guardian: guardian, store: try? HistoryStore())
        let groups = Dictionary(grouping: chosen, by: effectiveMode)

        // Always run a dry run first and show it.
        var dryItems: [CleanupItemResult] = []
        for (m, items) in groups { dryItems += try cleaner.run(items, mode: m, dryRun: true).items }
        if !json || !apply {
            if json { print(JSON.string(dryItems)); return 0 }
            print(Style.bold(apply ? "Plan" : "Dry run") + Style.dim(" — nothing has been changed yet") + "\n")
            var t = Table(["ID", "Class", "Size", "Action", "Path", "Result"], aligns: [.left, .left, .right, .left, .left, .left], flexible: 4)
            for r in dryItems {
                let ok = r.status == .dryRun
                t.add([r.candidateID, Style.cls(r.classification), Format.bytes(r.estimatedBytes), r.mode == .trash ? "→ Trash" : Style.red("DELETE"),
                       abbreviate(r.path), ok ? Style.green("ok") : Style.yellow(r.message)])
            }
            print(t.render())
            let okItems = dryItems.filter { $0.status == .dryRun }
            print("Would process \(okItems.count) items, ≈ \(Format.bytes(okItems.map(\.estimatedBytes).reduce(0, +))) (estimated).")
            if okItems.contains(where: { $0.mode == .trash }) { print(Style.dim("Items moved to Trash free space only after the Trash is emptied.")) }
        }
        guard apply else {
            print("\nTo perform it: " + Style.cyan("macpulse disk clean \(args.value("select").map { "--select \($0)" } ?? "")\(allSafe ? " --all-safe" : "") --mode \(mode.rawValue) --apply"))
            return 0
        }
        let runnable = chosen.filter { c in dryItems.contains { $0.candidateID == c.id && $0.status == .dryRun } }
        guard !runnable.isEmpty else { throw MacPulseError.refused("no item passed validation") }
        let permanent = runnable.filter { effectiveMode($0) == .delete }
        if !permanent.isEmpty { print(Style.red("\(permanent.count) item(s) will be PERMANENTLY deleted and cannot be recovered.")) }
        guard try confirm("Proceed with \(runnable.count) item(s)?", args: args) else { print("Cancelled. Nothing was changed."); return 1 }

        let cancel = CancellationFlag()
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)
        sigSource.setEventHandler { cancel.cancel(); printErr("\nCancelling after the current item…") }
        sigSource.resume()
        var results: [CleanupRunResult] = []
        for (m, items) in Dictionary(grouping: runnable, by: effectiveMode) {
            results.append(try cleaner.run(items, mode: m, dryRun: false, cancel: cancel) { i, n, path in
                if !json { printErr(Style.dim("  [\(i + 1)/\(n)] \(abbreviate(path))")) }
            })
        }
        sigSource.cancel()
        if json { print(JSON.string(results)); return results.contains { $0.failures > 0 } ? 1 : 0 }
        let items = results.flatMap(\.items)
        var t = Table(["ID", "Status", "Estimated", "Removed (measured)", "Path", "Detail"], aligns: [.left, .left, .right, .right, .left, .left], flexible: 5)
        for r in items {
            let st = switch r.status { case .deleted, .trashed: Style.green(r.status.rawValue); case .skipped, .cancelled: Style.yellow(r.status.rawValue); default: Style.red(r.status.rawValue) }
            t.add([r.candidateID, st, Format.bytes(r.estimatedBytes), r.status == .trashed ? "in Trash" : Format.bytes(r.removedBytes), abbreviate(r.path), r.message])
        }
        print("\n" + t.render())
        let removed = results.map(\.removedTotal).reduce(0, +)
        let trashed = results.map(\.trashedTotal).reduce(0, +)
        let delta = results.compactMap(\.measuredVolumeDelta).reduce(0, +)
        print("Deleted (measured from unlinked blocks): \(Format.bytes(removed)) · moved to Trash: \(Format.bytes(trashed))")
        print("Volume free-space change (measured, includes other activity): \(delta >= 0 ? "+" : "")\(Format.bytes(delta))")
        print(Style.dim("Recorded in cleanup history: macpulse disk history"))
        return items.contains { $0.status == .failed || $0.status == .partiallyDeleted } ? 1 : 0
    }

    func large() throws -> Int32 {
        let root = (args.positionals.dropFirst(2).first.map { ($0 as NSString).expandingTildeInPath }) ?? NSHomeDirectory()
        let min = try args.bytes("min-size", 1_000_000_000)
        progressNote("Searching \(root) for files ≥ \(Format.bytes(min)) (skips ~/Library, .git, node_modules, app bundles)…")
        let r = FileFinder.largeFiles(in: root, minSize: min, limit: try args.int("limit", 50))
        if json { print(JSON.string(r.files)); return 0 }
        var t = Table(["Class", "Allocated", "Private*", "Modified", "Path"], aligns: [.left, .right, .right, .left, .left], flexible: 4)
        for f in r.files {
            t.add([Style.cls(f.classification), Format.bytes(f.allocated), f.privateBytes.map { Format.bytes($0) } ?? "—", Format.date(f.modified), abbreviate(f.path)])
        }
        print(t.render())
        print(Style.dim("* Private = bytes not shared with APFS clones, i.e. what deleting the file would actually free."))
        if r.permissionDenied > 0 { print(Style.yellow("\(r.permissionDenied) folders were not readable (grant Full Disk Access to include them).")) }
        print(Style.dim("Large files are listed for your review. Remove them in Finder, or move REVIEW items to Trash from the app."))
        return 0
    }

    func duplicates() throws -> Int32 {
        guard let raw = args.positionals.dropFirst(2).first else { throw MacPulseError.usage("disk duplicates PATH") }
        let root = (raw as NSString).expandingTildeInPath
        let min = try args.bytes("min-size", 1_000_000)
        progressNote("Hashing candidate files under \(root)…")
        let groups = FileFinder.duplicates(in: root, minSize: min)
        if json { print(JSON.string(groups)); return 0 }
        guard !groups.isEmpty else { print("No duplicate files ≥ \(Format.bytes(min)) found."); return 0 }
        let total = groups.map(\.reclaimable).reduce(0, +)
        print(Style.bold("\(groups.count) duplicate groups") + " — keeping one copy each would free \(Format.bytes(total))\n")
        for g in groups.prefix(try args.int("limit", 25)) {
            print("  \(Format.bytes(g.size)) × \(g.files.count)  reclaim \(Format.bytes(g.reclaimable)) \(Style.dim("[\(g.reclaimProvenance.label)]"))  sha256 \(g.sha256.prefix(12))")
            for (i, f) in g.files.enumerated() {
                let clone = (f.privateBytes ?? f.allocated) < f.allocated / 2 ? Style.dim(" (APFS clone — shares storage)") : ""
                print("    \(i == 0 ? Style.green("keep") : "    ") \(abbreviate(f.path))\(clone)")
            }
        }
        print(Style.dim("\nMacPulse never removes every copy. Use the app's Storage › Duplicates view to move extra copies to Trash."))
        return 0
    }

    func history() throws -> Int32 {
        guard let store = try? HistoryStore() else { throw MacPulseError.failed("cannot open history database") }
        let entries = try store.cleanupHistory(limit: try args.int("limit", 100))
        if json { print(JSON.string(entries)); return 0 }
        guard !entries.isEmpty else { print("No cleanups recorded."); return 0 }
        var t = Table(["Date", "Run", "Status", "Method", "Estimated", "Removed", "Path"], aligns: [.left, .left, .left, .left, .right, .right, .left], flexible: 6)
        for e in entries {
            t.add([Format.date(e.timestamp), e.runID, e.status, e.method, Format.bytes(e.estimatedBytes),
                   e.status == "trashed" ? "in Trash" : Format.bytes(e.removedBytes), abbreviate(e.path)])
        }
        print(t.render())
        return 0
    }
}
