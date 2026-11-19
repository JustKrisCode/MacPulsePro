import Foundation

public struct ProcessFinding: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case largeMemory, runawayCPU, busyBackground, probableOrphan, duplicateInstances, memoryGrowth, unsignedActive, zombie
    }
    public var kind: Kind
    public var pids: [Int32]
    public var identities: [ProcessIdentity]
    public var title: String
    public var evidence: [String]
    public var severity: Severity
    public var confidence: Level
    public var provenance: Provenance
    public var id: String { kind.rawValue + ":" + identities.map(\.description).joined(separator: ",") }
}

/// Groups helper processes under their owning application bundle.
public struct AppGroup: Codable, Sendable, Identifiable {
    public var name: String
    public var bundlePath: String?
    public var pids: [Int32]
    public var footprint: UInt64
    public var cpuPercent: Double
    public var category: ProcessCategory
    /// Sum of member processes' power over the last interval (nil when no member reported energy).
    public var powerWatts: Double? = nil
    public var wakeupsPerSecond: Double = 0
    public var id: String { bundlePath ?? name }
}

public struct ProcessTreeNode: Sendable, Identifiable {
    public var record: ProcessRecord
    public var children: [ProcessTreeNode]
    public var id: String { record.id }
    public var subtreeFootprint: UInt64 { (record.footprint ?? 0) + children.map(\.subtreeFootprint).reduce(0, +) }
    public var subtreeCPU: Double { (record.cpuPercent ?? 0) + children.map(\.subtreeCPU).reduce(0, +) }
    /// For SwiftUI OutlineGroup.
    public var childNodes: [ProcessTreeNode]? { children.isEmpty ? nil : children }
}

public enum ProcessAnalyzer {
    /// Builds a forest rooted at processes whose parent is absent (normally kernel_task/launchd).
    public static func tree(_ records: [ProcessRecord]) -> [ProcessTreeNode] {
        let pids = Set(records.map(\.pid))
        let childrenOf = Dictionary(grouping: records.filter { $0.pid != $0.ppid }, by: \.ppid)
        func build(_ r: ProcessRecord, depth: Int) -> ProcessTreeNode {
            let kids = depth > 64 ? [] : (childrenOf[r.pid] ?? []).sorted { $0.pid < $1.pid }.map { build($0, depth: depth + 1) }
            return ProcessTreeNode(record: r, children: kids)
        }
        return records.filter { !pids.contains($0.ppid) || $0.pid == $0.ppid }
            .sorted { $0.pid < $1.pid }.map { build($0, depth: 0) }
    }

    /// Aggregates processes by enclosing .app bundle (e.g. a browser + all its helpers).
    public static func appGroups(_ records: [ProcessRecord]) -> [AppGroup] {
        var groups: [String: AppGroup] = [:]
        for r in records {
            let bundle = r.path.flatMap(outermostBundle)
            let key = bundle ?? r.path ?? r.name
            let name = bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? r.name
            var g = groups[key] ?? AppGroup(name: name, bundlePath: bundle, pids: [], footprint: 0, cpuPercent: 0, category: r.category)
            g.pids.append(r.pid)
            g.footprint += r.footprint ?? 0
            g.cpuPercent += r.cpuPercent ?? 0
            if let p = r.powerWatts { g.powerWatts = (g.powerWatts ?? 0) + p }
            g.wakeupsPerSecond += r.wakeupsPerSecond ?? 0
            if r.category == .application { g.category = .application }
            groups[key] = g
        }
        return groups.values.sorted { $0.footprint > $1.footprint }
    }

    static func outermostBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    public struct Context: Sendable {
        public var records: [ProcessRecord]
        public var physicalMemory: UInt64
        public var ownPID: Int32 = getpid()
        /// PIDs currently managed by launchd in the user domain (from `launchctl list`).
        public var launchdManagedPIDs: Set<Int32>?
        /// Recent per-process history (in-memory ring buffer or SQLite).
        public var history: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
        public var thresholds = Thresholds()
        public var now = Date()

        public init(records: [ProcessRecord], physicalMemory: UInt64) {
            self.records = records
            self.physicalMemory = physicalMemory
        }
    }

    static let interpreterNames: Set<String> = ["node", "python", "python3", "ruby", "java", "deno", "bun", "php", "perl", "Python"]

    public static func findings(_ ctx: Context) -> [ProcessFinding] {
        var out: [ProcessFinding] = []
        let user = ctx.records.filter { $0.category != .system && $0.category != .otherUser && $0.pid != ctx.ownPID }

        // Large consumers (single snapshot, measured).
        let largeLimit = max(ctx.thresholds.largeProcessFootprintBytes, ctx.physicalMemory / 6)
        for r in user where (r.footprint ?? 0) >= largeLimit {
            out.append(ProcessFinding(kind: .largeMemory, pids: [r.pid], identities: [r.identity],
                                      title: "\(r.name) uses \(Format.memory(r.footprint)) of memory",
                                      evidence: ["Physical footprint \(Format.memory(r.footprint)) (\(Format.percent(Double(r.footprint ?? 0) / Double(max(ctx.physicalMemory, 1)) * 100)) of RAM)",
                                                 "Running for \(Format.duration(r.runtime))"],
                                      severity: .info, confidence: .high, provenance: .measured))
        }

        // Runaway CPU: requires sustained history, never a single sample.
        for r in user {
            guard let series = ctx.history[r.identity] else { continue }
            let pts = series.compactMap { p in p.cpu.map { (p.timestamp, $0) } }
            let result = Trends.sustained(pts, threshold: ctx.thresholds.runawayProcessCPUPercent,
                                          window: ctx.thresholds.runawayProcessMinutes * 60, minFraction: 0.9)
            if result.sustained {
                let background = r.category != .application || !r.isForegroundApp
                out.append(ProcessFinding(kind: background ? .runawayCPU : .busyBackground, pids: [r.pid], identities: [r.identity],
                                          title: "\(r.name) has used ≥\(Int(ctx.thresholds.runawayProcessCPUPercent))% CPU for \(Format.duration(result.covered))",
                                          evidence: ["\(Int(result.fraction * 100))% of samples above threshold over \(Format.duration(result.covered))",
                                                     background ? "Not the frontmost application" : "Frontmost application (may be intentional work)"],
                                          severity: background ? .warning : .info, confidence: .medium, provenance: .measured))
            }
        }

        // Memory growth (possible leak): strong linear growth over ≥ 20 min.
        for r in user {
            guard let series = ctx.history[r.identity], series.count >= 8 else { continue }
            let t0 = series[0].timestamp
            let pts = series.compactMap { p in p.footprint.map { (p.timestamp.timeIntervalSince(t0), Double($0)) } }
            guard let span = pts.last?.0, span >= 1200, let fit = Trends.fit(pts) else { continue }
            let perHour = fit.slope * 3600
            let firstValue = pts.first?.1 ?? 1
            let growth = (pts.last?.1 ?? 0) - firstValue
            if perHour >= ctx.thresholds.memoryGrowthBytesPerHour, fit.r2 >= 0.8, growth / max(firstValue, 1) >= 0.2 {
                out.append(ProcessFinding(kind: .memoryGrowth, pids: [r.pid], identities: [r.identity],
                                          title: "\(r.name) memory is growing steadily (+\(Format.memory(Int64(perHour)))/h)",
                                          evidence: ["Footprint grew \(Format.memory(Int64(growth))) over \(Format.duration(span))",
                                                     String(format: "Linear fit R² = %.2f across %d samples", fit.r2, pts.count),
                                                     "Growth can be legitimate (caches, large documents); a leak is a possibility, not a certainty."],
                                          severity: .warning, confidence: fit.r2 > 0.95 && span > 3600 ? .medium : .low,
                                          provenance: .inferred))
            }
        }

        // Probable orphans: reparented to launchd, no terminal, not a launchd job, not an app.
        if let managed = ctx.launchdManagedPIDs {
            for r in user where r.category == .userBackground && r.ppid == 1 && !r.hasControllingTerminal
                && !managed.contains(r.pid) && r.runtime > 3600 && r.bundleIdentifier == nil {
                let interpreter = interpreterNames.contains(r.name) || r.path.map { interpreterNames.contains(($0 as NSString).lastPathComponent) } == true
                out.append(ProcessFinding(kind: .probableOrphan, pids: [r.pid], identities: [r.identity],
                                          title: "\(r.name) (pid \(r.pid)) appears detached from any parent",
                                          evidence: ["Parent is launchd (pid 1) but it is not a launchd-managed job",
                                                     "No controlling terminal", "Running for \(Format.duration(r.runtime))",
                                                     "Memory \(Format.memory(r.footprint)), CPU \(Format.percent(r.cpuPercent, digits: 1))"],
                                          severity: .info, confidence: interpreter ? .medium : .low, provenance: .inferred))
            }
        }

        // Duplicate instances of the same executable outside app bundles.
        let byPath = Dictionary(grouping: user.filter { $0.category == .userBackground && $0.path != nil }, by: { $0.path! })
        for (path, group) in byPath where group.count >= 3 {
            let mem = group.compactMap(\.footprint).reduce(0, +)
            guard mem >= 500_000_000 else { continue }
            out.append(ProcessFinding(kind: .duplicateInstances, pids: group.map(\.pid), identities: group.map(\.identity),
                                      title: "\(group.count) instances of \((path as NSString).lastPathComponent) using \(Format.memory(mem))",
                                      evidence: ["Executable: \(path)", "Combined footprint \(Format.memory(mem))",
                                                 "Multiple instances can be intentional (workers, servers); inspect each before acting."],
                                      severity: .info, confidence: .low, provenance: .measured))
        }
        // The same application bundle running twice.
        let apps = Dictionary(grouping: user.filter { $0.category == .application && $0.bundleIdentifier != nil }, by: { $0.bundleIdentifier! })
        for (bundle, group) in apps where group.count > 1 {
            out.append(ProcessFinding(kind: .duplicateInstances, pids: group.map(\.pid), identities: group.map(\.identity),
                                      title: "\(group[0].name) is running \(group.count) times",
                                      evidence: ["Bundle identifier \(bundle)"], severity: .info, confidence: .high, provenance: .measured))
        }

        let zombies = ctx.records.filter { $0.status == "zombie" }
        if zombies.count >= 5 {
            out.append(ProcessFinding(kind: .zombie, pids: zombies.map(\.pid), identities: zombies.map(\.identity),
                                      title: "\(zombies.count) zombie processes",
                                      evidence: ["Zombies hold no memory but indicate a parent not reaping children"] +
                                        Set(zombies.map(\.ppid)).prefix(5).map { "Parent pid \($0)" },
                                      severity: .info, confidence: .high, provenance: .measured))
        }
        return out.sorted { ($0.severity, $0.confidence) > ($1.severity, $1.confidence) }
    }

    /// Signature checks are expensive, so only the busiest few non-system processes are examined.
    public static func unusualActivity(_ records: [ProcessRecord], limit: Int = 8) -> [ProcessFinding] {
        let suspiciousRoots = ["/tmp/", "/private/tmp/", "/private/var/folders/", NSHomeDirectory() + "/Downloads/", "/Users/Shared/"]
        let busy = records.filter { $0.category == .userBackground && ($0.cpuPercent ?? 0) >= 20 }
            .sorted(by: ProcessSortKey.cpu.comparator).prefix(limit)
        return busy.compactMap { r in
            guard let path = r.path else { return nil }
            let sig = ProcessInspector.signature(path: path)
            let oddLocation = suspiciousRoots.contains(where: path.hasPrefix)
            guard sig.status == .unsigned || sig.status == .invalid || oddLocation else { return nil }
            var evidence = ["CPU \(Format.percent(r.cpuPercent, digits: 1))", "Path: \(path)", "Code signature: \(sig.status.rawValue)"]
            if oddLocation { evidence.append("Runs from a temporary or download location") }
            evidence.append("Unsigned developer tools are common; this is a prompt to verify, not a verdict.")
            return ProcessFinding(kind: .unsignedActive, pids: [r.pid], identities: [r.identity],
                                  title: "Busy process with unusual signature/location: \(r.name)",
                                  evidence: evidence, severity: .info, confidence: .low, provenance: .inferred)
        }
    }

    /// PIDs of jobs launchd manages for this user. One cheap `launchctl list` call.
    public static func launchdManagedPIDs(runner: CommandRunner = SystemCommandRunner()) -> Set<Int32>? {
        let r = runner.run("/bin/launchctl", ["list"], timeout: 5)
        guard r.ok else { return nil }
        return parseLaunchctlList(r.stdout)
    }

    static func parseLaunchctlList(_ text: String) -> Set<Int32> {
        Set(text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            line.split(separator: "\t").first.flatMap { Int32($0) }
        })
    }
}
