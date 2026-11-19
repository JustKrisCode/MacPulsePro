import Darwin
import Foundation
import MacPulseCore

struct Args {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    static let valueKeys: Set<String> = ["interval", "limit", "sort", "format", "output", "select", "mode",
                                         "min-size", "hours", "metric", "count", "sample", "filter", "pid", "timeout",
                                         "max-wait", "cpu", "check-every", "since", "every", "categories"]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" { positionals += argv[(i + 1)...]; break }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    values[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if Self.valueKeys.contains(body), i + 1 < argv.count {
                    values[body] = argv[i + 1]; i += 1
                } else {
                    flags.insert(body)
                }
            } else if a.hasPrefix("-") && a.count == 2 {
                switch a { case "-h": flags.insert("help"); case "-y": flags.insert("yes"); case "-v": flags.insert("verbose")
                default: flags.insert(String(a.dropFirst())) }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    func has(_ f: String) -> Bool { flags.contains(f) }
    func value(_ k: String) -> String? { values[k] }
    func int(_ k: String, _ d: Int) throws -> Int {
        guard let v = values[k] else { return d }
        guard let i = Int(v), i >= 0 else { throw MacPulseError.usage("--\(k) expects a non-negative integer, got '\(v)'") }
        return i
    }
    func double(_ k: String, _ d: Double) throws -> Double {
        guard let v = values[k] else { return d }
        guard let x = Double(v), x > 0 else { throw MacPulseError.usage("--\(k) expects a positive number, got '\(v)'") }
        return x
    }
    func bytes(_ k: String, _ d: Int64) throws -> Int64 {
        guard let v = values[k] else { return d }
        guard let b = parseBytes(v) else { throw MacPulseError.usage("--\(k) expects a size like 500MB or 2GB, got '\(v)'") }
        return b
    }
}

func parseBytes(_ s: String) -> Int64? {
    let t = s.trimmingCharacters(in: .whitespaces).uppercased()
    let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("T", 1e12), ("G", 1e9), ("M", 1e6), ("K", 1e3), ("B", 1)]
    for (u, m) in units where t.hasSuffix(u) {
        guard let n = Double(t.dropLast(u.count).trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
        return Int64(n * m)
    }
    return Int64(t)
}

enum Style {
    nonisolated(unsafe) static var enabled = false

    static func configure(disable: Bool) {
        enabled = !disable && isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    }

    static func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func blue(_ s: String) -> String { wrap(s, "34") }
    static func cyan(_ s: String) -> String { wrap(s, "36") }

    static func severity(_ s: Severity, _ text: String) -> String {
        switch s { case .ok: green(text); case .info: cyan(text); case .warning: yellow(text); case .critical: red(text) }
    }

    static func score(_ v: Int) -> String { v >= 80 ? green("\(v)") : v >= 50 ? yellow("\(v)") : red("\(v)") }

    static func cls(_ c: CleanupClass) -> String {
        switch c { case .safe: green("SAFE"); case .review: yellow("REVIEW"); case .protected: blue("PROTECTED"); case .unknown: dim("UNKNOWN") }
    }

    static func provenance(_ p: Provenance) -> String {
        switch p { case .measured: dim("measured"); case .measuredUndocumented: dim("measured*"); case .estimated: yellow("est.")
        case .inferred: yellow("inferred"); case .unavailable: dim("n/a") }
    }

    /// A horizontal bar of `width` cells for 0–100.
    static func bar(_ pct: Double?, width: Int = 20) -> String {
        guard let pct, pct.isFinite else { return dim(String(repeating: "·", count: width)) }
        let filled = Int((min(100, max(0, pct)) / 100 * Double(width)).rounded())
        let s = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        return pct >= 90 ? red(s) : pct >= 70 ? yellow(s) : green(s)
    }

    static func sparkline(_ values: [Double], width: Int = 40) -> String {
        guard !values.isEmpty else { return dim("(no history)") }
        let blocks = Array("▁▂▃▄▅▆▇█")
        let step = max(1, values.count / width)
        let buckets = stride(from: 0, to: values.count, by: step).map { i -> Double in
            let slice = values[i..<min(values.count, i + step)]
            return slice.reduce(0, +) / Double(slice.count)
        }
        let lo = buckets.min() ?? 0, hi = buckets.max() ?? 1
        let range = hi - lo
        return String(buckets.map { blocks[range > 0 ? min(7, Int(($0 - lo) / range * 7)) : 0] })
    }
}

func visibleWidth(_ s: String) -> Int {
    var count = 0, inEscape = false
    for ch in s.unicodeScalars {
        if ch == "\u{1B}" { inEscape = true; continue }
        if inEscape { if ch == "m" { inEscape = false }; continue }
        count += 1
    }
    return count
}

func terminalWidth() -> Int {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 20 { return Int(ws.ws_col) }
    return Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 140
}

struct Table {
    enum Align { case left, right }
    var headers: [String]
    var aligns: [Align]
    var rows: [[String]] = []
    /// Column allowed to shrink to fit the terminal.
    var flexible: Int?

    init(_ headers: [String], aligns: [Align]? = nil, flexible: Int? = nil) {
        self.headers = headers
        self.aligns = aligns ?? headers.map { _ in .left }
        self.flexible = flexible
    }

    mutating func add(_ row: [String]) { rows.append(row) }

    func render() -> String {
        var widths = headers.map(visibleWidth)
        for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], visibleWidth(c)) } }
        if let f = flexible {
            let total = widths.reduce(0, +) + 2 * (widths.count - 1)
            let over = total - terminalWidth()
            if over > 0 { widths[f] = max(12, widths[f] - over) }
        }
        func line(_ cells: [String], header: Bool) -> String {
            cells.enumerated().map { i, raw in
                var c = raw
                if visibleWidth(c) > widths[i] {
                    c = String(c.prefix(max(1, widths[i] - 1))) + "…"
                }
                let pad = String(repeating: " ", count: max(0, widths[i] - visibleWidth(c)))
                let cell = aligns[i] == .right ? pad + c : c + pad
                return header ? Style.bold(cell) : cell
            }.joined(separator: "  ")
        }
        var out = line(headers, header: true) + "\n"
        for r in rows { out += line(r, header: false) + "\n" }
        return out
    }
}

func heading(_ s: String) -> String { "\n" + Style.bold(s) + "\n" }

func confirm(_ prompt: String, args: Args) throws -> Bool {
    if args.has("yes") { return true }
    guard isatty(STDIN_FILENO) == 1 else {
        throw MacPulseError.refused("confirmation required: re-run with --yes in non-interactive use")
    }
    print(prompt + " Type 'yes' to continue: ", terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
