import AppKit
import Darwin
import Foundation

public enum ProcessCategory: String, Codable, Sendable, CaseIterable {
    /// Kernel, launchd, daemons and Apple system binaries.
    case system
    /// Core user-session UI owned by the user but essential (WindowServer, Dock, Finder…).
    case systemUI
    /// Regular foreground applications (Dock-visible).
    case application
    /// Helper processes inside an application bundle.
    case appHelper
    /// Other processes owned by the current user (CLI tools, agents, servers).
    case userBackground
    /// Processes owned by other users that this account cannot inspect.
    case otherUser
}

public struct ProcessRecord: Codable, Sendable, Identifiable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    public var uid: UInt32
    public var user: String
    public var name: String
    public var path: String?
    /// Process start time; together with the pid this forms the identity used to defeat PID reuse.
    public var startTime: Date
    public var startMicros: Int64
    public var status: String
    public var hasControllingTerminal: Bool
    public var category: ProcessCategory
    public var bundleIdentifier: String?
    public var isForegroundApp: Bool
    /// False when task info could not be read (other users' processes without root).
    public var accessible: Bool
    /// Percent of one core over the last sampling interval (Activity Monitor convention; may exceed 100).
    public var cpuPercent: Double?
    public var cpuTimeSeconds: Double?
    /// Physical footprint — the "Memory" column in Activity Monitor.
    public var footprint: UInt64?
    public var residentSize: UInt64?
    public var threads: Int?
    public var diskBytesRead: UInt64?
    public var diskBytesWritten: UInt64?

    public var id: String { "\(pid)-\(startMicros)" }
    public var runtime: TimeInterval { Date().timeIntervalSince(startTime) }
    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startMicros: startMicros) }
}

/// pid + start time. A different start time for the same pid means the pid was reused.
public struct ProcessIdentity: Codable, Sendable, Hashable, CustomStringConvertible {
    public var pid: Int32
    public var startMicros: Int64
    public init(pid: Int32, startMicros: Int64) { self.pid = pid; self.startMicros = startMicros }
    public var description: String { "\(pid)@\(startMicros)" }
}

struct KernelProcess: Sendable {
    var pid: Int32, ppid: Int32, pgid: Int32, uid: UInt32
    var comm: String, startMicros: Int64, stat: Int8, hasTTY: Bool
}

struct AppInfo: Sendable {
    var name: String?
    var bundleID: String?
    var regular: Bool
    var active: Bool
}

public enum ProcessCollector {
    static func kernelProcesses() -> [KernelProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = buffer.count * stride
            let rc = buffer.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if rc != 0 { if errno == ENOMEM { continue } else { return [] } }
            return buffer.prefix(size / stride).map { kp in
                let start = kp.kp_proc.p_starttime
                return KernelProcess(pid: kp.kp_proc.p_pid, ppid: kp.kp_eproc.e_ppid, pgid: kp.kp_eproc.e_pgid,
                                     uid: kp.kp_eproc.e_ucred.cr_uid, comm: stringFromCTuple(kp.kp_proc.p_comm),
                                     startMicros: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec),
                                     stat: kp.kp_proc.p_stat, hasTTY: kp.kp_eproc.e_tdev != -1)
            }
        }
        return []
    }

    /// Returns the current start time for a pid, or nil if no such process exists.
    public static func identity(of pid: Int32) -> ProcessIdentity? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        let start = kp.kp_proc.p_starttime
        return ProcessIdentity(pid: pid, startMicros: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info : nil
    }

    static func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info : nil
    }

    static func runningApps() -> [Int32: AppInfo] {
        var map: [Int32: AppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications {
            map[app.processIdentifier] = AppInfo(name: app.localizedName, bundleID: app.bundleIdentifier,
                                                 regular: app.activationPolicy == .regular, active: app.isActive)
        }
        return map
    }

    static let systemUINames: Set<String> = ["WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer",
                                             "ControlCenter", "NotificationCenter", "Spotlight", "WindowManager",
                                             "coreauthd", "universalaccessd", "TextInputMenuAgent"]
    static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/",
                                     "/bin/", "/Library/Apple/", "/private/var/db/", "/usr/lib/"]

    static func categorize(pid: Int32, uid: UInt32, name: String, path: String?, app: AppInfo?, myUID: UInt32) -> ProcessCategory {
        if pid <= 1 { return .system }
        if systemUINames.contains(name) { return uid == myUID ? .systemUI : .system }
        if uid != myUID {
            if let path, systemPathPrefixes.contains(where: path.hasPrefix) || uid == 0 { return .system }
            return .otherUser
        }
        if let app, app.regular { return .application }
        if let path {
            if path.contains(".app/Contents/") {
                // Apple system app helpers inside /System still count as system.
                return path.hasPrefix("/System/") ? .system : .appHelper
            }
            if systemPathPrefixes.contains(where: path.hasPrefix) { return .system }
        }
        return .userBackground
    }

    static func statusString(_ stat: Int8) -> String {
        switch stat {
        case 1: "idle"; case 2: "running"; case 3: "sleeping"; case 4: "stopped"; case 5: "zombie"
        default: "unknown"
        }
    }

    /// Raw listing without CPU percentages (those need two samples — see ProcessSampler).
    public static func list() -> [ProcessRecord] {
        let myUID = getuid()
        let apps = runningApps()
        var users: [UInt32: String] = [:]
        return kernelProcesses().map { kp in
            let path = executablePath(kp.pid)
            let app = apps[kp.pid]
            let task = taskInfo(kp.pid)
            let ru = rusage(kp.pid)
            let name = app?.name ?? path.map { ($0 as NSString).lastPathComponent } ?? kp.comm
            let user = users[kp.uid] ?? {
                let n = getpwuid(kp.uid).flatMap { String(validatingCString: $0.pointee.pw_name) } ?? String(kp.uid)
                users[kp.uid] = n
                return n
            }()
            let cpuNs = task.map { MachTime.toNanoseconds($0.pti_total_user) + MachTime.toNanoseconds($0.pti_total_system) }
            return ProcessRecord(
                pid: kp.pid, ppid: kp.ppid, pgid: kp.pgid, uid: kp.uid, user: user, name: name, path: path,
                startTime: Date(timeIntervalSince1970: Double(kp.startMicros) / 1e6), startMicros: kp.startMicros,
                status: statusString(kp.stat), hasControllingTerminal: kp.hasTTY,
                category: categorize(pid: kp.pid, uid: kp.uid, name: name, path: path, app: app, myUID: myUID),
                bundleIdentifier: app?.bundleID, isForegroundApp: app?.active ?? false,
                accessible: task != nil, cpuPercent: nil,
                cpuTimeSeconds: cpuNs.map { Double($0) / 1e9 },
                footprint: ru.map { $0.ri_phys_footprint }, residentSize: task.map { $0.pti_resident_size },
                threads: task.map { Int($0.pti_threadnum) },
                diskBytesRead: ru.map { $0.ri_diskio_bytesread }, diskBytesWritten: ru.map { $0.ri_diskio_byteswritten })
        }
    }
}

/// Computes per-process CPU % from the delta of cumulative CPU time between two listings.
public struct ProcessSampler: Sendable {
    private var previous: [ProcessIdentity: Double] = [:]
    private var previousTime: Date?

    public init() {}

    public mutating func sample() -> [ProcessRecord] {
        let now = Date()
        var records = ProcessCollector.list()
        let interval = previousTime.map { now.timeIntervalSince($0) } ?? 0
        var next: [ProcessIdentity: Double] = [:]
        next.reserveCapacity(records.count)
        for i in records.indices {
            guard let cpu = records[i].cpuTimeSeconds else { continue }
            let id = records[i].identity
            next[id] = cpu
            if interval > 0.1, let prev = previous[id] {
                records[i].cpuPercent = max(0, (cpu - prev) / interval * 100)
            }
        }
        previous = next
        previousTime = now
        return records
    }
}
