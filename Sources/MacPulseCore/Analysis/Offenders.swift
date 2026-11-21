import Foundation

/// "Top offenders this week": which apps most often heated the Mac, filled memory, drew energy or woke the CPU,
/// aggregated from the background monitor's history.
public struct Offender: Codable, Sendable, Identifiable {
    public var name: String
    /// Ranking value (meaning depends on the list).
    public var score: Double
    public var detail: String
    public var samples: Int
    public var id: String { name }
}

public struct OffenderReport: Codable, Sendable {
    public var days: Double
    public var from: Date?
    public var to: Date?
    public var processSamples: Int
    public var systemSamples: Int
    public var cpu: [Offender]
    public var heat: [Offender]
    public var memoryPressure: [Offender]
    public var memory: [Offender]
    public var energy: [Offender]
    public var wakeups: [Offender]
    public var hotMinutes: Double
    public var pressureMinutes: Double
    public var notes: [String]
}

public enum OffenderAnalyzer {
    struct Row { var ts: Double; var name: String; var cpu: Double?; var footprint: Double?; var power: Double?; var wakeups: Double?; var thermal: Int?; var pressure: Int? }

    public static func report(store: HistoryStore, days: Double = 7, limit: Int = 5, now: Date = Date()) throws -> OffenderReport {
        let since = now.addingTimeInterval(-days * 86400).timeIntervalSince1970
        let rawRows = try store.db.query("""
            SELECT p.ts, p.name, p.cpu, p.footprint, p.power, p.wakeups, s.thermal, s.pressure
            FROM process_samples p LEFT JOIN samples s ON s.ts = p.ts
            WHERE p.ts >= ?
            """, [.double(since)]).map {
            Row(ts: $0[0].double ?? 0, name: $0[1].text ?? "?", cpu: $0[2].double, footprint: $0[3].double,
                power: $0[4].double, wakeups: $0[5].double, thermal: $0[6].int.map { Int($0) }, pressure: $0[7].int.map { Int($0) })
        }
        // Collapse instances sharing a name at the same moment (e.g. several helpers) into one row per (name, time).
        func add(_ a: Double?, _ b: Double?) -> Double? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        var merged: [String: Row] = [:]
        for r in rawRows {
            let key = "\(r.name)\u{0}\(r.ts)"
            if var m = merged[key] {
                m.cpu = add(m.cpu, r.cpu); m.footprint = add(m.footprint, r.footprint)
                m.power = add(m.power, r.power); m.wakeups = add(m.wakeups, r.wakeups)
                merged[key] = m
            } else { merged[key] = r }
        }
        let rows = Array(merged.values)
        let system = try store.samples(since: Date(timeIntervalSince1970: since))
        let summary = HistorySummary.compute(system)
        let groups = Dictionary(grouping: rows, by: \.name)
        let snapshots = Set(rows.map(\.ts)).count

        func top(_ f: ([Row]) -> (Double, String)?) -> [Offender] {
            groups.compactMap { name, rs in f(rs).map { Offender(name: name, score: $0.0, detail: $0.1, samples: rs.count) } }
                .filter { $0.score > 0 }.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
        }
        // Sums over samples are proportional to time-weighted totals because the monitor samples at a fixed rate.
        let cpu = top { rs in
            let v = rs.compactMap(\.cpu); guard !v.isEmpty else { return nil }
            return (v.reduce(0, +), "avg \(Format.percent(v.reduce(0, +) / Double(v.count))) CPU · in top list \(Format.percent(Double(rs.count) / Double(max(snapshots, 1)) * 100)) of the time")
        }
        let heat = top { rs in
            let hot = rs.filter { ($0.thermal ?? 0) >= 1 }.compactMap(\.cpu); guard !hot.isEmpty else { return nil }
            return (hot.reduce(0, +), "avg \(Format.percent(hot.reduce(0, +) / Double(hot.count))) CPU while the Mac was warm (fair or hotter)")
        }
        let pressure = top { rs in
            let p = rs.filter { ($0.pressure ?? 0) >= 1 }.compactMap(\.footprint); guard !p.isEmpty else { return nil }
            return (p.reduce(0, +), "avg \(Format.memory(UInt64(p.reduce(0, +) / Double(p.count)))) while memory pressure was elevated")
        }
        let memory = top { rs in
            let v = rs.compactMap(\.footprint); guard let mx = v.max() else { return nil }
            return (v.reduce(0, +) / Double(v.count), "avg \(Format.memory(UInt64(v.reduce(0, +) / Double(v.count)))), peak \(Format.memory(UInt64(mx)))")
        }
        let energy = top { rs in
            let v = rs.compactMap(\.power); guard !v.isEmpty else { return nil }
            return (v.reduce(0, +), String(format: "avg %.2f W while sampled", v.reduce(0, +) / Double(v.count)))
        }
        let wakeups = top { rs in
            let v = rs.compactMap(\.wakeups); guard !v.isEmpty else { return nil }
            let avg = v.reduce(0, +) / Double(v.count)
            return (avg * Double(v.count), "avg \(Int(avg)) wakeups/s")
        }
        var notes = ["Based on the background monitor's samples of the top processes (not every process every minute)."]
        if rows.isEmpty { notes = ["No history yet. Enable the background monitor (macpulse monitor install) and check back after a day."] }
        else if !rows.contains(where: { $0.power != nil }) { notes.append("Energy and wakeup history starts with this version; those lists fill in over time.") }
        return OffenderReport(days: days, from: rows.map(\.ts).min().map { Date(timeIntervalSince1970: $0) },
                              to: rows.map(\.ts).max().map { Date(timeIntervalSince1970: $0) },
                              processSamples: rawRows.count, systemSamples: system.count, cpu: cpu, heat: heat,
                              memoryPressure: pressure, memory: memory, energy: energy, wakeups: wakeups,
                              hotMinutes: HistorySummary.elevatedMinutes(system) { ($0.thermal ?? 0) >= 1 },
                              pressureMinutes: summary.pressureElevatedMinutes, notes: notes)
    }
}
