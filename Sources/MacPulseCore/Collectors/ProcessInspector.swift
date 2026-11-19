import Darwin
import Foundation
import Security

public struct ProcessDetails: Codable, Sendable {
    public var record: ProcessRecord
    /// Arguments with likely secrets redacted. Nil when not readable (other users' processes).
    public var arguments: [String]?
    public var workingDirectory: String?
    public var signature: CodeSignatureInfo
    public var ancestors: [ProcessRecord]
    public var children: [ProcessRecord]
}

public struct CodeSignatureInfo: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case apple, validDeveloper, unsigned, invalid, unknown }
    public var status: Status
    public var teamIdentifier: String?
    public var signingIdentifier: String?
}

public enum ProcessInspector {
    public static func details(pid: Int32, in records: [ProcessRecord]) -> ProcessDetails? {
        guard let record = records.first(where: { $0.pid == pid }) else { return nil }
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var ancestors: [ProcessRecord] = []
        var cursor = record.ppid
        var guardCount = 0
        while cursor > 0, let parent = byPID[cursor], guardCount < 64 {
            ancestors.append(parent)
            cursor = parent.ppid
            guardCount += 1
        }
        if cursor == 0, let kernel = byPID[0] { ancestors.append(kernel) }
        return ProcessDetails(record: record,
                              arguments: arguments(pid).map(redact),
                              workingDirectory: workingDirectory(pid),
                              signature: record.path.map(signature) ?? CodeSignatureInfo(status: .unknown),
                              ancestors: ancestors,
                              children: records.filter { $0.ppid == pid })
    }

    /// Parses KERN_PROCARGS2: [argc:int32][exec_path\0][\0 padding][argv0\0 … argvN\0][env…].
    public static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    static func parseProcArgs(_ buf: [UInt8]) -> [String]? {
        guard buf.count > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 }   // exec path
        while i < buf.count, buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < buf.count {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static let secretPattern = try! NSRegularExpression(
        pattern: #"(?i)(token|secret|passw(or)?d|api[-_]?key|auth|bearer|credential)"#)

    /// Redacts values of arguments that look like they carry credentials.
    public static func redact(_ args: [String]) -> [String] {
        var out: [String] = []
        var redactNext = false
        for arg in args {
            if redactNext { out.append("[redacted]"); redactNext = false; continue }
            let range = NSRange(arg.startIndex..., in: arg)
            if secretPattern.firstMatch(in: arg, range: range) != nil {
                if let eq = arg.firstIndex(of: "=") {
                    out.append(String(arg[...eq]) + "[redacted]")
                } else {
                    out.append(arg)
                    redactNext = arg.hasPrefix("-")
                }
            } else {
                out.append(arg)
            }
        }
        return out
    }

    public static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = stringFromCTuple(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    public static func signature(path: String) -> CodeSignatureInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return CodeSignatureInfo(status: .unknown) }
        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let ident = info[kSecCodeInfoIdentifier as String] as? String
        if info[kSecCodeInfoIdentifier as String] == nil {
            return CodeSignatureInfo(status: .unsigned)
        }
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess {
            return CodeSignatureInfo(status: .apple, teamIdentifier: team, signingIdentifier: ident)
        }
        let valid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        return CodeSignatureInfo(status: valid ? .validDeveloper : .invalid, teamIdentifier: team, signingIdentifier: ident)
    }
}
