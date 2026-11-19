import Darwin
import Foundation

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Size of a filesystem tree with APFS-aware accounting.
public struct DiskUsage: Codable, Sendable, Equatable {
    /// Sum of file lengths (what Finder calls "size").
    public var logical: Int64 = 0
    /// Sum of allocated blocks (st_blocks × 512) — reflects sparse and compressed files.
    /// Hard links are counted once. APFS clones are still counted per file (see docs/STORAGE.md).
    public var allocated: Int64 = 0
    public var files: Int = 0
    public var directories: Int = 0
    public var newestModification: Date?
    /// Allocated bytes of files with additional hard links outside the tree; deleting them frees nothing.
    public var sharedHardLinkBytes: Int64 = 0
    public var errors: Int = 0
    public var permissionDenied: Int = 0
    public var truncated: Bool = false

    public init() {}
}

public enum DiskUsageScanner {
    /// Walks without following symlinks or crossing mount points.
    public static func measure(_ path: String, cancel: CancellationFlag? = nil, maxEntries: Int = 5_000_000) -> DiskUsage {
        var usage = DiskUsage()
        guard let cPath = strdup(path) else { return usage }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            usage.errors = 1
            if errno == EACCES || errno == EPERM { usage.permissionDenied = 1 }
            return usage
        }
        defer { fts_close(fts) }
        var seenLinks = Set<UInt64>()
        var newest: Double = 0
        var entries = 0
        while let ent = fts_read(fts) {
            entries += 1
            if entries > maxEntries || (entries & 1023 == 0 && cancel?.isCancelled == true) {
                usage.truncated = true
                break
            }
            let info = Int32(ent.pointee.fts_info)
            switch info {
            case FTS_D:
                usage.directories += 1
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = ent.pointee.fts_statp?.pointee else { continue }
                let alloc = Int64(st.st_blocks) * 512
                let mtime = Double(st.st_mtimespec.tv_sec)
                if mtime > newest { newest = mtime }
                usage.files += 1
                if st.st_nlink > 1 && (st.st_mode & S_IFMT) == S_IFREG {
                    // Count each inode once; it is "shared" if links exist that we did not see.
                    if !seenLinks.insert(UInt64(st.st_ino)).inserted { continue }
                    usage.sharedHardLinkBytes += alloc
                }
                usage.logical += Int64(st.st_size)
                usage.allocated += alloc
            case FTS_DNR, FTS_ERR, FTS_NS:
                usage.errors += 1
                let e = ent.pointee.fts_errno
                if e == EACCES || e == EPERM { usage.permissionDenied += 1 }
            default:
                break
            }
        }
        if newest > 0 { usage.newestModification = Date(timeIntervalSince1970: newest) }
        return usage
    }

    /// Clone-aware private size of one file (bytes not shared with APFS clones), via getattrlist.
    /// Returns nil when the filesystem does not support ATTR_CMNEXT_PRIVATESIZE.
    public static func privateSize(_ path: String) -> Int64? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(0x8000_0000)    // ATTR_CMN_RETURNED_ATTRS
        attrs.forkattr = attrgroup_t(0x0000_0008)      // ATTR_CMNEXT_PRIVATESIZE (extended common attr)
        var buf = [UInt8](repeating: 0, count: 64)
        let options = UInt32(0x20 | 0x1)                // FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW
        let rc = buf.withUnsafeMutableBytes { getattrlist(path, &attrs, $0.baseAddress, 64, options) }
        guard rc == 0 else { return nil }
        // Layout: u_int32 length | attribute_set_t (5 × u_int32) | off_t privatesize
        let returnedFork = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self) }
        guard returnedFork & 0x8 != 0 else { return nil }
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Int64.self) }
    }
}
