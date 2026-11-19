import Foundation

/// Manages the opt-in per-user LaunchAgent for the background monitor. No administrator rights needed.
public struct LaunchAgentManager: Sendable {
    public static let label = "com.macpulse.monitor"
    public var runner: CommandRunner
    public var plistPath: String
    public var uid: uid_t
    public var logDirectory: String

    public init(runner: CommandRunner = SystemCommandRunner(),
                plistPath: String = NSHomeDirectory() + "/Library/LaunchAgents/\(LaunchAgentManager.label).plist",
                uid: uid_t = getuid(), logDirectory: String = AppPaths.logDirectory) {
        self.runner = runner; self.plistPath = plistPath; self.uid = uid; self.logDirectory = logDirectory
    }

    public struct Status: Codable, Sendable {
        public var installed: Bool
        public var loaded: Bool
        public var pid: Int32?
        public var executable: String?
        public var plistPath: String
    }

    public func plist(executable: String) -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [executable, "monitor", "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 60,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "LowPriorityBackgroundIO": true,
            "Nice": 10,
            "StandardOutPath": logDirectory + "/monitor.log",
            "StandardErrorPath": logDirectory + "/monitor.log",
        ]
    }

    public func install(executable: String) throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw MacPulseError.failed("monitor executable not found: \(executable)")
        }
        try FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: executable), format: .xml, options: 0)
        if status().loaded { _ = runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"], timeout: 10) }
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        let r = runner.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath], timeout: 10)
        guard r.ok else { throw MacPulseError.failed("launchctl bootstrap failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func uninstall() throws {
        if status().loaded {
            let r = runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"], timeout: 10)
            if !r.ok && status().loaded { throw MacPulseError.failed("launchctl bootout failed: \(r.stderr)") }
        }
        if FileManager.default.fileExists(atPath: plistPath) { try FileManager.default.removeItem(atPath: plistPath) }
    }

    public func status() -> Status {
        let installed = FileManager.default.fileExists(atPath: plistPath)
        var exe: String?
        if installed, let data = FileManager.default.contents(atPath: plistPath),
           let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            exe = (p["ProgramArguments"] as? [String])?.first
        }
        let r = runner.run("/bin/launchctl", ["print", "gui/\(uid)/\(Self.label)"], timeout: 5)
        var pid: Int32?
        if r.ok, let line = r.stdout.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }) {
            pid = Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        return Status(installed: installed, loaded: r.ok, pid: pid, executable: exe, plistPath: plistPath)
    }
}
