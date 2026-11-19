import Foundation

/// How a value was obtained. Every user-facing metric carries one, so measured data is never
/// presented the same way as an estimate or a heuristic.
public enum Provenance: String, Codable, Sendable {
    /// Read from a documented or long-stable OS interface.
    case measured
    /// Read from an observable but undocumented OS interface (e.g. IORegistry statistics).
    case measuredUndocumented = "measured-undocumented"
    /// Arithmetic derivation from measured inputs.
    case estimated
    /// Rule-based inference; may be wrong.
    case inferred
    /// Not obtainable without private APIs, root, or unsupported techniques.
    case unavailable

    public var label: String {
        switch self {
        case .measured: "measured"
        case .measuredUndocumented: "measured (undocumented source)"
        case .estimated: "estimated"
        case .inferred: "inferred"
        case .unavailable: "unavailable"
        }
    }
}

public struct Metric<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value?
    public var provenance: Provenance
    public var source: String
    public var note: String?

    public init(_ value: Value?, _ provenance: Provenance, source: String, note: String? = nil) {
        self.value = value
        self.provenance = value == nil ? .unavailable : provenance
        self.source = source
        self.note = note
    }

    public static func unavailable(_ source: String, _ note: String) -> Metric {
        Metric(nil, .unavailable, source: source, note: note)
    }
}

public enum Severity: String, Codable, Sendable, Comparable, CaseIterable {
    case ok, info, warning, critical
    private var rank: Int { switch self { case .ok: 0; case .info: 1; case .warning: 2; case .critical: 3 } }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

public enum Level: String, Codable, Sendable, Comparable {
    case low, medium, high
    private var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    public var weight: Double { switch self { case .low: 1; case .medium: 2; case .high: 3 } }
}

public enum MacPulseError: Error, CustomStringConvertible, Sendable {
    case usage(String)
    case unavailable(String)
    case refused(String)
    case permissionDenied(String)
    case locked(String)
    case failed(String)

    public var description: String {
        switch self {
        case .usage(let m): "usage error: \(m)"
        case .unavailable(let m): "unavailable: \(m)"
        case .refused(let m): "refused by safety policy: \(m)"
        case .permissionDenied(let m): "permission denied: \(m)"
        case .locked(let m): "busy: \(m)"
        case .failed(let m): m
        }
    }

    public var code: String {
        switch self {
        case .usage: "E_USAGE"; case .unavailable: "E_UNAVAILABLE"; case .refused: "E_REFUSED"
        case .permissionDenied: "E_PERMISSION"; case .locked: "E_BUSY"; case .failed: "E_FAILED"
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .usage: 64; case .unavailable: 69; case .refused: 77
        case .permissionDenied: 77; case .locked: 75; case .failed: 1
        }
    }
}

public enum JSON {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    public static func string<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        guard let data = try? encoder(pretty: pretty).encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum Format {
    /// Decimal units, matching Finder and Disk Utility.
    public static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let v = Double(value)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = abs(v), i = 0
        while size >= 1000, i < units.count - 1 { size /= 1000; i += 1 }
        let sign = v < 0 ? "-" : ""
        return i == 0 ? "\(sign)\(Int(size)) B" : String(format: "%@%.1f %@", sign, size, units[i])
    }

    public static func bytes(_ value: UInt64?) -> String { bytes(value.map { Int64(clamping: $0) }) }

    /// Binary units (1 GB = 2^30 bytes), matching how macOS reports RAM and Activity Monitor memory.
    public static func memory(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value), i = 0
        while size >= 1024, i < units.count - 1 { size /= 1024; i += 1 }
        return i == 0 ? "\(Int(size)) B" : String(format: i >= 3 ? "%.2f %@" : "%.1f %@", size, units[i])
    }

    public static func memory(_ value: Int64?) -> String { memory(value.map { UInt64(max(0, $0)) }) }

    public static func percent(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f%%", value)
    }

    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    public static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
