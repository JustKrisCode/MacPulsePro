import Foundation

/// Result of running an external tool.
public struct ExecResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let notFound: Bool

    public var ok: Bool { status == 0 && !timedOut && !notFound }

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false, notFound: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.notFound = notFound
    }

    public static func missing(_ tool: String) -> ExecResult {
        ExecResult(status: 127, stdout: "", stderr: "\(tool): not found", notFound: true)
    }
}

/// Abstraction over external command execution so callers can be tested with canned output.
///
/// SECURITY: commands always run as an argv vector, never through a shell. Paths are passed as
/// discrete arguments and are never interpolated into a command string.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ args: [String], timeout: TimeInterval) -> ExecResult
}

public struct SystemCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ args: [String], timeout: TimeInterval = 15) -> ExecResult {
        // Only absolute paths to system utilities are accepted: no PATH lookup surprises.
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            return .missing(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let out = LockedData(), err = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out.set(outPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { err.set(errPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }

        do { try process.run() } catch {
            return ExecResult(status: 126, stdout: "", stderr: "failed to launch \(executable): \(error.localizedDescription)")
        }
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                timedOut = true
                process.terminate()
                break
            }
            usleep(5_000)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return ExecResult(status: process.terminationStatus,
                          stdout: String(decoding: out.get(), as: UTF8.self),
                          stderr: String(decoding: err.get(), as: UTF8.self),
                          timedOut: timedOut)
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Test double returning canned results keyed by "executable arg1 arg2".
public final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: ExecResult] = [:]
    private var _calls: [[String]] = []

    public init() {}

    public func set(_ command: String, _ result: ExecResult) {
        lock.lock(); responses[command] = result; lock.unlock()
    }

    public var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }

    public func run(_ executable: String, _ args: [String], timeout: TimeInterval) -> ExecResult {
        lock.lock(); defer { lock.unlock() }
        _calls.append([executable] + args)
        let key = ([executable] + args).joined(separator: " ")
        return responses[key] ?? .missing(executable)
    }
}
