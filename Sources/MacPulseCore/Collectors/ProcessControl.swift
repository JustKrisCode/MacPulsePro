import AppKit
import Darwin
import Foundation

public enum TerminationPolicy {
    public struct Decision: Sendable {
        public var allowed: Bool
        public var reason: String?
        public var warnings: [String]
    }

    /// Decides whether a process may be terminated from MacPulse at all.
    public static func evaluate(_ r: ProcessRecord, ownPID: Int32 = getpid(), ownAncestors: Set<Int32> = []) -> Decision {
        var warnings: [String] = []
        if r.pid <= 1 { return Decision(allowed: false, reason: "kernel/launchd", warnings: []) }
        if r.pid == ownPID { return Decision(allowed: false, reason: "this is MacPulse itself", warnings: []) }
        switch r.category {
        case .system: return Decision(allowed: false, reason: "protected system process", warnings: [])
        case .systemUI: return Decision(allowed: false, reason: "essential session process (\(r.name))", warnings: [])
        case .otherUser: return Decision(allowed: false, reason: "owned by another user (\(r.user))", warnings: [])
        default: break
        }
        if r.uid != getuid() { return Decision(allowed: false, reason: "not owned by the current user", warnings: []) }
        if ownAncestors.contains(r.pid) { warnings.append("This process is an ancestor of MacPulse (e.g. your terminal); MacPulse may exit too.") }
        if r.category == .application { warnings.append("The app will be asked to quit and may prompt you to save documents.") }
        if r.status == "zombie" { warnings.append("Zombie processes cannot be terminated; their parent must reap them.") }
        return Decision(allowed: true, reason: nil, warnings: warnings)
    }
}

public enum TerminationOutcome: Sendable, Equatable, CustomStringConvertible {
    case exited
    case stillRunning
    case notFound
    case identityMismatch
    case refused(String)
    case permissionDenied
    case failed(String)

    public var description: String {
        switch self {
        case .exited: "process exited"
        case .stillRunning: "process did not exit within the timeout"
        case .notFound: "process no longer exists"
        case .identityMismatch: "pid now belongs to a different process (pid reuse) — nothing was sent"
        case .refused(let r): "refused: \(r)"
        case .permissionDenied: "permission denied"
        case .failed(let m): m
        }
    }
}

/// Sends signals only after re-verifying pid + start time immediately beforehand.
public enum ProcessController {
    public static func ancestors(of pid: Int32 = getpid()) -> Set<Int32> {
        let byPID = Dictionary(ProcessCollector.kernelProcesses().map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var out = Set<Int32>(), cur = byPID[pid] ?? 0
        while cur > 1, out.insert(cur).inserted { cur = byPID[cur] ?? 0 }
        return out
    }

    /// Graceful: asks an application to quit (NSRunningApplication.terminate), otherwise SIGTERM.
    public static func terminate(_ record: ProcessRecord, timeout: TimeInterval = 5) async -> TerminationOutcome {
        let decision = TerminationPolicy.evaluate(record, ownAncestors: [])
        guard decision.allowed else { return .refused(decision.reason ?? "not allowed") }
        guard let current = ProcessCollector.identity(of: record.pid) else { return .notFound }
        guard current == record.identity else { return .identityMismatch }

        let sent: Bool
        if record.category == .application, let app = await MainActor.run(body: { NSRunningApplication(processIdentifier: record.pid) }) {
            sent = await MainActor.run { app.terminate() }
            if !sent { return .failed("the application declined the quit request") }
        } else {
            guard ProcessCollector.identity(of: record.pid) == record.identity else { return .identityMismatch }
            if kill(record.pid, SIGTERM) != 0 { return errno == EPERM ? .permissionDenied : errno == ESRCH ? .notFound : .failed(String(cString: strerror(errno))) }
            sent = true
        }
        return await waitForExit(record.identity, timeout: timeout)
    }

    /// SIGKILL. Callers must obtain a second, explicit confirmation before invoking this.
    public static func forceKill(_ record: ProcessRecord, timeout: TimeInterval = 3) async -> TerminationOutcome {
        let decision = TerminationPolicy.evaluate(record, ownAncestors: [])
        guard decision.allowed else { return .refused(decision.reason ?? "not allowed") }
        guard let current = ProcessCollector.identity(of: record.pid) else { return .notFound }
        guard current == record.identity else { return .identityMismatch }
        if kill(record.pid, SIGKILL) != 0 { return errno == EPERM ? .permissionDenied : .failed(String(cString: strerror(errno))) }
        return await waitForExit(record.identity, timeout: timeout)
    }

    static func waitForExit(_ id: ProcessIdentity, timeout: TimeInterval) async -> TerminationOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ProcessCollector.identity(of: id.pid) != id { return .exited }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return ProcessCollector.identity(of: id.pid) == id ? .stillRunning : .exited
    }
}
