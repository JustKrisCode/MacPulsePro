import Foundation

public struct SystemReport: Codable, Sendable {
    public var generatedAt: Date
    public var tool: String
    public var snapshot: SystemSnapshot
    public var health: HealthReport
    public var history: HistorySummary
    public var recommendations: [Recommendation]
    public var findings: [ProcessFinding]
    public var storage: StorageAnalysis?
    public var recentEvents: [StoredEvent]
    public var recentCleanups: [CleanupHistoryEntry]
}

public enum ReportFormat: String, CaseIterable, Sendable { case markdown, json, csv, html }

public enum ReportBuilder {
    public static let version = "MacPulse Pro 1.0.0"

    public static func build(snapshot: SystemSnapshot, store: HistoryStore?, storage: StorageAnalysis?,
                             config: MacPulseConfig = MacPulseConfig()) -> SystemReport {
        let samples = (try? store?.samples(since: Date().addingTimeInterval(-3600))) ?? []
        let summary = HistorySummary.compute(samples + [HistorySample(snapshot)],
                                             cpuThreshold: config.thresholds.sustainedCPUPercent,
                                             cpuWindow: config.thresholds.sustainedCPUMinutes * 60)
        var ctx = ProcessAnalyzer.Context(records: snapshot.processes, physicalMemory: snapshot.system.physicalMemory)
        ctx.thresholds = config.thresholds
        ctx.launchdManagedPIDs = ProcessAnalyzer.launchdManagedPIDs()
        if let series = try? store?.processSeries(since: Date().addingTimeInterval(-7200)) {
            ctx.history = series.mapValues(\.points)
        }
        let findings = ProcessAnalyzer.findings(ctx) + ProcessAnalyzer.unusualActivity(snapshot.processes)
        let recs = RecommendationEngine.recommendations(RecommendationContext(
            snapshot: snapshot, history: summary, findings: findings, cleanup: storage?.summary, thresholds: config.thresholds))
        return SystemReport(generatedAt: Date(), tool: version, snapshot: snapshot,
                            health: HealthScorer.evaluate(snapshot, history: summary, thresholds: config.thresholds),
                            history: summary, recommendations: recs, findings: findings, storage: storage,
                            recentEvents: (try? store?.events(since: Date().addingTimeInterval(-86400 * 7), limit: 50)) ?? [],
                            recentCleanups: (try? store?.cleanupHistory(limit: 50)) ?? [])
    }

    public static func render(_ r: SystemReport, as format: ReportFormat) -> String {
        switch format {
        case .json: JSON.string(r)
        case .markdown: markdown(r)
        case .html: html(r)
        case .csv: csv(r)
        }
    }

    // MARK: Markdown

    public static func markdown(_ r: SystemReport) -> String {
        let s = r.snapshot
        var md = "# MacPulse Pro system report\n\n"
        md += "Generated \(Format.date(r.generatedAt)) by \(r.tool). All data was collected locally.\n\n"
        md += "## System\n\n| | |\n|---|---|\n"
        md += "| Model | \(s.system.modelIdentifier) |\n| Chip | \(s.system.chip) |\n"
        md += "| macOS | \(s.system.osVersion) (\(s.system.osBuild ?? "?")) |\n| Memory | \(Format.memory(s.system.physicalMemory)) |\n"
        md += "| CPUs | \(s.system.logicalCPUs) logical\(s.system.performanceCores.map { " (\($0) P" } ?? "")\(s.system.efficiencyCores.map { " + \($0) E)" } ?? "") |\n"
        md += "| Uptime | \(Format.duration(s.system.uptimeSeconds)) |\n\n"

        md += "## Health score: \(r.health.overall)/100 (\(r.health.status.rawValue))\n\n"
        md += "_\(r.health.method)_\n\n| Dimension | Score | Summary | Deductions |\n|---|---|---|---|\n"
        for d in r.health.dimensions {
            let ded = d.deductions.isEmpty ? "—" : d.deductions.map { "−\($0.points): \($0.reason)" }.joined(separator: "<br>")
            md += "| \(d.kind.rawValue) | \(d.score) | \(d.summary) | \(ded) |\n"
        }
        if !r.health.excluded.isEmpty { md += "\nExcluded: " + r.health.excluded.joined(separator: "; ") + "\n" }

        md += "\n## Recommendations\n\n"
        if r.recommendations.isEmpty { md += "No action needed.\n" }
        for (i, rec) in r.recommendations.enumerated() {
            md += "### \(i + 1). \(rec.title)\n\n\(rec.detail)\n\n"
            md += "- Severity: \(rec.severity.rawValue) · Confidence: \(rec.confidence.rawValue) · Risk: \(rec.risk.rawValue) · Effort: \(rec.effort.rawValue) · Reversible: \(rec.reversible ? "yes" : "no")\n"
            md += "- Expected effect: \(rec.expectedEffect)\n"
            for e in rec.evidence { md += "- Evidence: \(e)\n" }
            if let a = rec.actionHint { md += "- Next step: `\(a)`\n" }
            md += "\n"
        }

        md += "## Metrics\n\n"
        if let c = s.cpu {
            md += "- CPU: \(Format.percent(c.total, digits: 1)) (user \(Format.percent(c.user, digits: 1)), system \(Format.percent(c.system, digits: 1)))"
            if let p = c.performanceAverage, let e = c.efficiencyAverage { md += ", P-cores \(Format.percent(p)), E-cores \(Format.percent(e))" }
            md += ", load \(c.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))\n"
        }
        if let m = s.memory {
            md += "- Memory: pressure **\(m.pressure.rawValue)**, used \(Format.memory(m.used)) (app \(Format.memory(m.app)), wired \(Format.memory(m.wired)), compressed \(Format.memory(m.compressed))), cached files \(Format.memory(m.cachedFiles)), swap \(Format.memory(m.swapUsed))/\(Format.memory(m.swapTotal))\n"
        }
        md += "- GPU: \(Format.percent(s.gpu.utilization.value)) [\(s.gpu.utilization.provenance.label)]\n"
        md += "- Thermal: \(s.thermal.state.rawValue) [measured, ProcessInfo.thermalState]; CPU temperature: unavailable (private sensors)\n"
        if let v = s.volume {
            md += "- Disk: \(Format.bytes(v.available)) free of \(Format.bytes(v.total)); purgeable ≈ \(Format.bytes(v.purgeableEstimate.value)) [estimated]\n"
        }
        if s.power.hasBattery {
            md += "- Battery: \(s.power.chargePercent.map { "\($0)%" } ?? "?"), capacity \(Format.percent(s.power.healthPercent.value)) [estimated], \(s.power.cycleCount.map { "\($0) cycles" } ?? "")\n"
        }

        md += "\n## Top processes\n\n| PID | Name | CPU | Memory | Runtime | Category |\n|---|---|---|---|---|---|\n"
        for p in s.topProcesses(by: .cpu, limit: 10) {
            md += "| \(p.pid) | \(p.name) | \(Format.percent(p.cpuPercent, digits: 1)) | \(Format.memory(p.footprint)) | \(Format.duration(p.runtime)) | \(p.category.rawValue) |\n"
        }
        md += "\n| PID | Name | Memory | CPU |\n|---|---|---|---|\n"
        for p in s.topProcesses(by: .memory, limit: 10) {
            md += "| \(p.pid) | \(p.name) | \(Format.memory(p.footprint)) | \(Format.percent(p.cpuPercent, digits: 1)) |\n"
        }
        if !r.findings.isEmpty {
            md += "\n## Process findings\n\n"
            for f in r.findings { md += "- **\(f.title)** (\(f.confidence.rawValue) confidence, \(f.provenance.label)): \(f.evidence.joined(separator: "; "))\n" }
        }
        if let st = r.storage {
            md += "\n## Storage analysis (estimated reclaimable)\n\n"
            md += "- Safe: \(Format.bytes(st.bytes(.safe))) · Review: \(Format.bytes(st.bytes(.review)))\n"
            for (cat, b) in st.byCategory() { md += "- \(cat.title): \(Format.bytes(b))\n" }
            for p in st.protectedItems { md += "- Protected — \(p.title): \(Format.bytes(p.usage.allocated)) (\(p.reason))\n" }
            if let snaps = st.localSnapshots { md += "- Local APFS snapshots: \(snaps.count) (sizes require root; macOS removes them automatically when space is needed)\n" }
        }
        if !r.recentCleanups.isEmpty {
            md += "\n## Recent cleanups (measured)\n\n| Date | Path | Status | Estimated | Removed |\n|---|---|---|---|---|\n"
            for c in r.recentCleanups.prefix(20) {
                md += "| \(Format.date(c.timestamp)) | \(c.path) | \(c.status) | \(Format.bytes(c.estimatedBytes)) | \(Format.bytes(c.removedBytes)) |\n"
            }
        }
        md += "\n---\nMeasured values come from documented macOS interfaces unless marked. GPU statistics come from IORegistry driver counters (undocumented). Estimates are labelled.\n"
        return md
    }

    // MARK: HTML

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func html(_ r: SystemReport) -> String {
        // Minimal markdown-to-HTML for our own controlled output: tables, headings, lists.
        var body = ""
        var inTable = false, inList = false
        for line in markdown(r).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("|") {
                if line.contains("---|") { continue }
                if !inTable { body += "<table>"; inTable = true }
                let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                body += "<tr>" + cells.map { "<td>\(esc($0.trimmingCharacters(in: .whitespaces)).replacingOccurrences(of: "&lt;br&gt;", with: "<br>"))</td>" }.joined() + "</tr>"
                continue
            } else if inTable { body += "</table>"; inTable = false }
            if line.hasPrefix("- ") {
                if !inList { body += "<ul>"; inList = true }
                body += "<li>\(inline(esc(String(line.dropFirst(2)))))</li>"; continue
            } else if inList { body += "</ul>"; inList = false }
            if line.hasPrefix("### ") { body += "<h3>\(esc(String(line.dropFirst(4))))</h3>" }
            else if line.hasPrefix("## ") { body += "<h2>\(esc(String(line.dropFirst(3))))</h2>" }
            else if line.hasPrefix("# ") { body += "<h1>\(esc(String(line.dropFirst(2))))</h1>" }
            else if line == "---" { body += "<hr>" }
            else if !line.isEmpty { body += "<p>\(inline(esc(line)))</p>" }
        }
        if inTable { body += "</table>" }
        if inList { body += "</ul>" }
        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>MacPulse Pro report</title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        :root{color-scheme:light dark;--fg:#1d1d1f;--bg:#fbfbfd;--line:#d2d2d7;--muted:#6e6e73}
        @media(prefers-color-scheme:dark){:root{--fg:#f5f5f7;--bg:#161618;--line:#3a3a3c;--muted:#a1a1a6}}
        body{font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;color:var(--fg);background:var(--bg);max-width:980px;margin:40px auto;padding:0 24px}
        h1{font-size:28px;letter-spacing:-.02em}h2{margin-top:36px;border-bottom:1px solid var(--line);padding-bottom:6px}
        table{border-collapse:collapse;width:100%;margin:12px 0;font-variant-numeric:tabular-nums}
        td{border-bottom:1px solid var(--line);padding:6px 8px;vertical-align:top}tr:first-child td{font-weight:600;color:var(--muted)}
        code{font:12px ui-monospace,SFMono-Regular,monospace;background:rgba(127,127,127,.15);padding:1px 4px;border-radius:4px}
        p em,em{color:var(--muted)}
        </style></head><body>\(body)</body></html>
        """
    }

    static func inline(_ s: String) -> String {
        var out = s
        for (marker, tag) in [("**", "strong"), ("`", "code"), ("_", "em")] {
            let parts = out.components(separatedBy: marker)
            guard parts.count >= 3, parts.count % 2 == 1 else { continue }
            out = parts.enumerated().map { i, p in i % 2 == 1 ? "<\(tag)>\(p)</\(tag)>" : p }.joined()
        }
        return out
    }

    // MARK: CSV (process table + health; history export lives in historyCSV)

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    public static func csv(_ r: SystemReport) -> String {
        var out = "pid,ppid,name,category,cpu_percent,footprint_bytes,runtime_seconds,path\n"
        for p in r.snapshot.processes.sorted(by: ProcessSortKey.cpu.comparator) {
            out += [String(p.pid), String(p.ppid), csvField(p.name), p.category.rawValue,
                    p.cpuPercent.map { String(format: "%.2f", $0) } ?? "", p.footprint.map(String.init) ?? "",
                    String(Int(p.runtime)), csvField(p.path ?? "")].joined(separator: ",") + "\n"
        }
        return out
    }

    public static func historyCSV(_ samples: [HistorySample]) -> String {
        let f = ISO8601DateFormatter()
        var out = "timestamp,cpu_percent,load1,memory_used,compressed,pressure,swap_used,gpu_percent,thermal,disk_free,battery_percent,on_ac\n"
        func d(_ v: Double?, _ fmt: String) -> String { v.map { String(format: fmt, $0) } ?? "" }
        func n<T: CustomStringConvertible>(_ v: T?) -> String { v.map { $0.description } ?? "" }
        for s in samples {
            var row: [String] = [f.string(from: s.timestamp), d(s.cpu, "%.2f"), d(s.load1, "%.2f")]
            row += [n(s.memoryUsed), n(s.compressed), n(s.pressure), n(s.swapUsed)]
            row += [d(s.gpu, "%.1f"), n(s.thermal), n(s.diskFree), n(s.battery)]
            row.append(s.onAC.map { $0 ? "1" : "0" } ?? "")
            out += row.joined(separator: ",") + "\n"
        }
        return out
    }
}
