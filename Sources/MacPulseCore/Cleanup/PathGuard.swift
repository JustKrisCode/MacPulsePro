import Darwin
import Foundation

/// Identity of a path at validation time. Used to detect swaps between scan and deletion (TOCTOU).
public struct ValidatedTarget: Codable, Sendable, Equatable {
    public var path: String
    public var resolvedPath: String
    public var device: Int64
    public var inode: UInt64
    public var kind: Kind
    public enum Kind: String, Codable, Sendable { case directory, file, symlink, other }
}

/// Allowlist-based path validation. A path may only be acted on if, after resolving every symlink in
/// its parent chain, it lies strictly inside an allowed root, on the same device, and outside every
/// denied location. The final component is never followed, so a symlink is treated as the link itself.
public struct PathGuard: Sendable {
    public let allowedRoots: [String]
    /// Paths approved as a whole (e.g. ~/.npm/_cacache): the path itself, not its siblings.
    public let allowedExact: [String]
    public let allowPersonalFolders: Bool
    private let home: String

    public init(allowedRoots: [String], allowedExact: [String] = [], allowPersonalFolders: Bool = false,
                home: String = NSHomeDirectory()) {
        self.home = Self.resolve(home) ?? home
        self.allowPersonalFolders = allowPersonalFolders
        self.allowedRoots = allowedRoots.compactMap { Self.resolve($0) }.filter { $0 != "/" }
        self.allowedExact = allowedExact.compactMap { Self.resolve($0) }.filter { $0 != "/" && $0 != (Self.resolve(home) ?? home) }
    }

    /// Builds the guard for a rule set: `.children` roots allow descendants, `.wholeItem` allows the
    /// exact path, `.contents` allows the exact path and its descendants.
    public init(rules: [CleanupRule], allowPersonalFolders: Bool = false, home: String = NSHomeDirectory()) {
        self.init(allowedRoots: rules.filter { $0.scope != .wholeItem }.map(\.root),
                  allowedExact: rules.filter { $0.scope != .children }.map(\.root),
                  allowPersonalFolders: allowPersonalFolders, home: home)
    }

    /// Always denied, regardless of allowlist.
    var hardDenied: [String] {
        ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db", "/Library", "/Applications",
         "/opt", "/cores", "/Volumes",
         home + "/Library/Keychains", home + "/.ssh", home + "/.gnupg", home + "/Library/Preferences",
         home + "/Library/Application Support", home + "/Library/Group Containers", home + "/Library/Mobile Documents",
         home + "/Library/Messages", home + "/Library/Mail", home + "/Library/Accounts", home + "/Library/Cookies",
         home + "/Library/CloudStorage", home + "/Library/Photos", home + "/Library/Calendars",
         home + "/Library/LaunchAgents", home + "/Library/Safari", home + "/.config", home + "/.local/share"]
    }

    /// Denied unless the guard was created for explicit, user-selected, Trash-only actions.
    var personalFolders: [String] {
        ["Documents", "Desktop", "Pictures", "Movies", "Music", "Public"].map { home + "/" + $0 }
    }

    static func resolve(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    static func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    public func validate(_ path: String) throws -> ValidatedTarget {
        guard path.hasPrefix("/") else { throw MacPulseError.refused("path is not absolute: \(path)") }
        guard !path.contains("\0") else { throw MacPulseError.refused("path contains NUL") }
        let comps = path.split(separator: "/", omittingEmptySubsequences: false)
        if comps.contains("..") || comps.dropFirst().dropLast().contains(".") {
            throw MacPulseError.refused("path contains relative components: \(path)")
        }
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let st = Self.lstatInfo(trimmed) else { throw MacPulseError.failed("path no longer exists: \(trimmed)") }
        let parent = (trimmed as NSString).deletingLastPathComponent
        let name = (trimmed as NSString).lastPathComponent
        guard let realParent = Self.resolve(parent) else { throw MacPulseError.refused("cannot resolve parent of \(trimmed)") }
        let resolved = (realParent == "/" ? "" : realParent) + "/" + name

        let root: String
        if let exact = allowedExact.first(where: { $0 == resolved }) {
            root = exact
        } else if let r = allowedRoots.first(where: { resolved.hasPrefix($0 + "/") }) {
            root = r
        } else {
            throw MacPulseError.refused("\(resolved) is outside every approved cleanup root")
        }
        if resolved.split(separator: "/").contains(".git") {
            throw MacPulseError.refused("\(resolved) is inside a Git repository database")
        }
        var denied = hardDenied
        if !allowPersonalFolders { denied += personalFolders }
        // A denied location blocks unless the approved root itself is more specific (e.g. Mail Downloads).
        // Denied locations always block, even if an allowlisted root lies inside them.
        if let d = denied.first(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            throw MacPulseError.refused("\(resolved) is inside protected location \(d)")
        }
        if resolved == home { throw MacPulseError.refused("refusing to act on the home directory") }
        guard let rootSt = Self.lstatInfo(root), rootSt.st_dev == st.st_dev else {
            throw MacPulseError.refused("\(resolved) is on a different volume than its cleanup root")
        }
        if let parentSt = Self.lstatInfo(realParent), parentSt.st_dev != st.st_dev {
            throw MacPulseError.refused("\(resolved) is a mount point")
        }
        let kind: ValidatedTarget.Kind = switch st.st_mode & S_IFMT {
        case S_IFDIR: .directory; case S_IFREG: .file; case S_IFLNK: .symlink; default: .other
        }
        return ValidatedTarget(path: trimmed, resolvedPath: resolved, device: Int64(st.st_dev),
                               inode: UInt64(st.st_ino), kind: kind)
    }

    /// Re-checks immediately before acting: same location, same inode, same type.
    public func revalidate(_ expected: ValidatedTarget) throws -> ValidatedTarget {
        let now = try validate(expected.path)
        guard now.resolvedPath == expected.resolvedPath, now.device == expected.device,
              now.inode == expected.inode, now.kind == expected.kind else {
            throw MacPulseError.refused("\(expected.path) changed since it was scanned")
        }
        return now
    }
}

/// Exclusive, non-blocking lock preventing concurrent cleanup runs (CLI, app or monitor).
public final class CleanupLock: @unchecked Sendable {
    private var fd: Int32 = -1

    public init(path: String = AppPaths.cleanupLock) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MacPulseError.failed("cannot open lock file \(path)") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd); fd = -1
            throw MacPulseError.locked("another cleanup is already running")
        }
    }

    public func release() {
        if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 }
    }

    deinit { release() }
}
