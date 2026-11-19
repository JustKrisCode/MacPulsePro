import Darwin
import Foundation
import MacPulseCore

struct ProcessCommands {
    let args: Args
    var json: Bool { args.has("json") }

    func run(_ sub: String?) async throws -> Int32 {
        switch sub {
        case nil, "list", "top": return try await list()
        case "tree": return try await tree()
        case "inspect", "info": return try await inspect()
        case "terminate", "kill", "quit": return try await terminate()
        default: throw MacPulseError.usage("processes [list|tree|inspect PID|terminate PID]")
        }
    }

    func sampled() async -> [ProcessRecord] {
        await SystemSampler().measured(interval: 1).processes
    }

    func list() async throws -> Int32 {
        guard let key = ProcessSortKey(rawValue: args.value("sort") ?? "cpu") else {
            throw MacPulseError.usage("--sort must be one of: \(ProcessSortKey.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var procs = await sampled()
        if !args.has("all") { procs = procs.filter { $0.category != .otherUser || ($0.cpuPercent ?? 0) > 0 } }
        if let f = args.value("filter")?.lowercased() {
            procs = procs.filter { $0.name.lowercased().contains(f) || ($0.path?.lowercased().contains(f) ?? false) || String($0.pid) == f }
        }
        procs.sort(by: key.comparator)
        let limit = try args.int("limit", 25)
        let shown = limit == 0 ? procs : Array(procs.prefix(limit))
        if json { print(JSON.string(shown)); return 0 }
        var t = Table(["PID", "PPID", "Process", "CPU", "Memory", "Power", "Wakeups/s", "Runtime", "User", "Category"],
                      aligns: [.right, .right, .left, .right, .right, .right, .right, .right, .left, .left], flexible: 2)
        for p in shown {
            t.add([String(p.pid), String(p.ppid), p.name, Format.percent(p.cpuPercent, digits: 1),
                   p.accessible ? Format.memory(p.footprint) : Style.dim("n/a"),
                   p.powerWatts.map { String(format: "%.2f W", $0) } ?? "—", p.wakeupsPerSecond.map { String(Int($0)) } ?? "—",
                   Format.duration(p.runtime), p.user, p.category.rawValue])
        }
        print(t.render())
        let hidden = procs.count - shown.count
        print(Style.dim("\(procs.count) processes\(hidden > 0 ? ", \(hidden) not shown (--limit 0 for all)" : ""). Memory = physical footprint; n/a = owned by another user (root needed)."))
        return 0
    }

    func tree() async throws -> Int32 {
        let procs = await sampled()
        var roots = ProcessAnalyzer.tree(procs)
        if let raw = args.value("pid") {
            guard let pid = Int32(raw) else { throw MacPulseError.usage("--pid expects a number") }
            func find(_ nodes: [ProcessTreeNode]) -> ProcessTreeNode? {
                for n in nodes { if n.record.pid == pid { return n }; if let f = find(n.children) { return f } }
                return nil
            }
            guard let node = find(roots) else { throw MacPulseError.failed("no process with pid \(pid)") }
            roots = [node]
        }
        struct Node: Encodable { var pid: Int32; var name: String; var cpu: Double?; var footprint: UInt64?; var children: [Node] }
        func conv(_ n: ProcessTreeNode) -> Node { Node(pid: n.record.pid, name: n.record.name, cpu: n.record.cpuPercent, footprint: n.record.footprint, children: n.children.map(conv)) }
        if json { print(JSON.string(roots.map(conv))); return 0 }
        var out = ""
        func walk(_ n: ProcessTreeNode, _ prefix: String, _ last: Bool, _ depth: Int) {
            let branch = depth == 0 ? "" : (last ? "└─ " : "├─ ")
            let cpu = (n.record.cpuPercent ?? 0) >= 1 ? Style.yellow(" \(Format.percent(n.record.cpuPercent, digits: 0))") : ""
            let mem = n.record.footprint.map { Style.dim(" \(Format.memory($0))") } ?? ""
            let sub = n.children.isEmpty ? "" : Style.dim("  [subtree \(Format.memory(n.subtreeFootprint))]")
            out += prefix + branch + "\(n.record.name) " + Style.dim("(\(n.record.pid))") + cpu + mem + sub + "\n"
            let childPrefix = depth == 0 ? "" : prefix + (last ? "   " : "│  ")
            for (i, c) in n.children.enumerated() { walk(c, childPrefix, i == n.children.count - 1, depth + 1) }
        }
        for (i, r) in roots.enumerated() { walk(r, "", i == roots.count - 1, 0) }
        print(out, terminator: "")
        return 0
    }

    func pidArgument() throws -> Int32 {
        guard let raw = args.positionals.dropFirst(2).first, let pid = Int32(raw), pid > 0 else {
            throw MacPulseError.usage("expected a PID, e.g. 'macpulse processes inspect 1234'")
        }
        return pid
    }

    func inspect() async throws -> Int32 {
        let pid = try pidArgument()
        let procs = await sampled()
        guard let d = ProcessInspector.details(pid: pid, in: procs) else { throw MacPulseError.failed("no process with pid \(pid)") }
        let decision = TerminationPolicy.evaluate(d.record, ownAncestors: ProcessController.ancestors())
        struct Out: Encodable { var details: ProcessDetails; var terminable: Bool; var reason: String?; var warnings: [String] }
        if json { print(JSON.string(Out(details: d, terminable: decision.allowed, reason: decision.reason, warnings: decision.warnings))); return 0 }
        let r = d.record
        var o = Style.bold("\(r.name)") + Style.dim("  pid \(r.pid) · started \(Format.date(r.startTime)) (\(Format.duration(r.runtime)) ago)") + "\n"
        o += "  Path:        \(r.path ?? "—")\n"
        o += "  Bundle:      \(r.bundleIdentifier ?? "—")\n"
        o += "  User:        \(r.user) (uid \(r.uid)) · category \(r.category.rawValue) · status \(r.status)\n"
        o += "  CPU:         \(Format.percent(r.cpuPercent, digits: 1)) now · \(Format.duration(r.cpuTimeSeconds)) total\n"
        o += "  Memory:      \(Format.memory(r.footprint)) footprint · \(Format.memory(r.residentSize)) resident · \(r.threads.map(String.init) ?? "—") threads\n"
        o += "  Disk I/O:    \(Format.bytes(r.diskBytesRead)) read · \(Format.bytes(r.diskBytesWritten)) written\n"
        o += "  Working dir: \(d.workingDirectory ?? "—")\n"
        o += "  Signature:   \(d.signature.status.rawValue)\(d.signature.teamIdentifier.map { " · team \($0)" } ?? "")\(d.signature.signingIdentifier.map { " · \($0)" } ?? "")\n"
        o += "  Terminal:    \(r.hasControllingTerminal ? "attached" : "none")\n"
        if let a = d.arguments { o += "  Arguments:   " + a.joined(separator: " ").prefix(600) + Style.dim("  (secrets redacted)") + "\n" }
        o += "  Ancestry:    " + ([r] + d.ancestors).map { "\($0.name)(\($0.pid))" }.joined(separator: " ← ") + "\n"
        if !d.children.isEmpty { o += "  Children:    " + d.children.prefix(20).map { "\($0.name)(\($0.pid))" }.joined(separator: ", ") + "\n" }
        o += "  Terminate:   " + (decision.allowed ? Style.green("allowed") + " — macpulse processes terminate \(r.pid)" : Style.red("not allowed") + " (\(decision.reason ?? ""))") + "\n"
        for w in decision.warnings { o += Style.yellow("               ⚠ \(w)") + "\n" }
        print(o)
        return 0
    }

    func terminate() async throws -> Int32 {
        let pid = try pidArgument()
        let procs = await sampled()
        guard let r = procs.first(where: { $0.pid == pid }) else { throw MacPulseError.failed("no process with pid \(pid)") }
        let decision = TerminationPolicy.evaluate(r, ownAncestors: ProcessController.ancestors())
        guard decision.allowed else { throw MacPulseError.refused("cannot terminate \(r.name) (\(pid)): \(decision.reason ?? "")") }
        let children = procs.filter { $0.ppid == pid }
        print(Style.bold("\(r.name)") + " (pid \(pid), started \(Format.date(r.startTime)), \(Format.memory(r.footprint)), CPU \(Format.percent(r.cpuPercent, digits: 1)))")
        print("  Path: \(r.path ?? "—")")
        if !children.isEmpty { print(Style.yellow("  Has \(children.count) child process(es); they may exit too: ") + children.prefix(8).map { "\($0.name)(\($0.pid))" }.joined(separator: ", ")) }
        for w in decision.warnings { print(Style.yellow("  ⚠ \(w)")) }
        let method = r.category == .application ? "ask the application to quit" : "send SIGTERM (graceful)"
        guard try confirm("MacPulse will \(method).", args: args) else { print("Cancelled."); return 1 }
        var outcome = await ProcessController.terminate(r, timeout: try args.double("timeout", 5))
        print("Result: \(outcome)")
        if outcome == .stillRunning && args.has("force") {
            print(Style.red("The process is still running. Force-quitting (SIGKILL) discards unsaved work."))
            guard try confirm("Force quit \(r.name) (\(pid))?", args: args) else { print("Not forced."); return 1 }
            outcome = await ProcessController.forceKill(r)
            print("Result: \(outcome)")
        } else if outcome == .stillRunning {
            print(Style.dim("Add --force to escalate to SIGKILL after a second confirmation."))
        }
        return outcome == .exited ? 0 : 1
    }
}
