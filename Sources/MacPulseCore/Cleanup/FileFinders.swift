import CryptoKit
import Darwin
import Foundation

public enum FileKindClassifier {
    static let installer: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    static let archive: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]
    static let protectedExt: Set<String> = [
        // documents / media / source / databases / credentials / VMs
        "pages", "numbers", "key", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pdf", "txt", "md", "rtf",
        "jpg", "jpeg", "png", "heic", "raw", "cr2", "nef", "arw", "dng", "psd", "ai", "sketch", "fig", "blend", "spine",
        "mov", "mp4", "m4v", "mkv", "avi", "wav", "aiff", "flac", "mp3", "m4a", "logicx", "band", "fcpbundle",
        "swift", "ts", "js", "py", "rs", "go", "c", "cpp", "h", "java", "kt", "sql",
        "sqlite", "sqlite3", "db", "realm", "kdbx", "keychain", "p12", "pem", "key",
        "vmdk", "vdi", "qcow2", "utm", "pvm", "sparseimage", "sparsebundle", "raw-image", "photoslibrary",
    ]

    public static func classify(_ path: String) -> (CleanupClass, String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if installer.contains(ext) { return (.review, "Installer or disk image — usually re-downloadable") }
        if archive.contains(ext) { return (.review, "Archive — check whether its contents exist elsewhere") }
        if protectedExt.contains(ext) { return (.protected, "Document, media, source, database or VM file") }
        return (.unknown, "Unrecognized file type")
    }
}

public struct LargeFile: Codable, Sendable, Identifiable {
    public var path: String
    public var logical: Int64
    public var allocated: Int64
    /// Clone-aware: bytes that would actually be freed. Nil if the filesystem cannot report it.
    public var privateBytes: Int64?
    public var modified: Date
    public var classification: CleanupClass
    public var note: String
    public var id: String { path }
}

public struct DuplicateGroup: Codable, Sendable, Identifiable {
    public var id: String
    public var size: Int64
    public var sha256: String
    public var files: [LargeFile]
    /// Bytes freed by keeping one copy, using private (clone-aware) sizes where available.
    public var reclaimable: Int64
    public var reclaimProvenance: Provenance
}

public enum FileFinder {
    /// Packages and directories never descended into.
    static let skipDirectoryNames: Set<String> = [".git", "node_modules", ".Trash", "Library", ".svn", ".hg"]
    static let packageExtensions: Set<String> = ["app", "photoslibrary", "fcpbundle", "logicx", "xcarchive", "bundle", "framework"]

    static func walk(_ root: String, cancel: CancellationFlag?, minSize: Int64, _ visit: (String, stat) -> Void) -> (errors: Int, denied: Int) {
        var errors = 0, denied = 0
        guard let cPath = strdup(root) else { return (1, 0) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return (1, 0) }
        defer { fts_close(fts) }
        var n = 0
        while let ent = fts_read(fts) {
            n += 1
            if n & 1023 == 0, cancel?.isCancelled == true { break }
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_D, ent.pointee.fts_level > 0 {
                let name = String(cString: ent.pointee.fts_name_ptr)
                if skipDirectoryNames.contains(name) || packageExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    fts_set(fts, ent, FTS_SKIP)
                }
            } else if info == FTS_F, let st = ent.pointee.fts_statp?.pointee, Int64(st.st_size) >= minSize {
                visit(String(cString: ent.pointee.fts_path), st)
            } else if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                errors += 1
                if ent.pointee.fts_errno == EACCES || ent.pointee.fts_errno == EPERM { denied += 1 }
            }
        }
        return (errors, denied)
    }

    static func makeFile(_ path: String, _ st: stat) -> LargeFile {
        let (cls, note) = FileKindClassifier.classify(path)
        return LargeFile(path: path, logical: Int64(st.st_size), allocated: Int64(st.st_blocks) * 512,
                         privateBytes: DiskUsageScanner.privateSize(path),
                         modified: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)),
                         classification: cls, note: note)
    }

    public static func largeFiles(in root: String, minSize: Int64 = 1_000_000_000, limit: Int = 200,
                                  cancel: CancellationFlag? = nil) -> (files: [LargeFile], permissionDenied: Int) {
        var found: [LargeFile] = []
        let r = walk(root, cancel: cancel, minSize: minSize) { path, st in found.append(makeFile(path, st)) }
        return (Array(found.sorted { $0.allocated > $1.allocated }.prefix(limit)), r.denied)
    }

    /// size → partial hash (first+last 64 KiB) → full SHA-256. Hard links to the same inode are not duplicates.
    public static func duplicates(in root: String, minSize: Int64 = 1_000_000, cancel: CancellationFlag? = nil) -> [DuplicateGroup] {
        var bySize: [Int64: [(String, stat)]] = [:]
        _ = walk(root, cancel: cancel, minSize: minSize) { path, st in bySize[Int64(st.st_size), default: []].append((path, st)) }
        var groups: [DuplicateGroup] = []
        for (size, entries) in bySize where entries.count > 1 {
            if cancel?.isCancelled == true { break }
            var seenInodes = Set<UInt64>()
            let unique = entries.filter { seenInodes.insert(UInt64($0.1.st_ino)).inserted }
            guard unique.count > 1 else { continue }
            let byPartial = Dictionary(grouping: unique) { partialHash($0.0, size: size) ?? UUID().uuidString }
            for (_, partialGroup) in byPartial where partialGroup.count > 1 {
                let byFull = Dictionary(grouping: partialGroup) { fullHash($0.0) ?? UUID().uuidString }
                for (hash, same) in byFull where same.count > 1 {
                    let files = same.map { makeFile($0.0, $0.1) }.sorted { $0.modified < $1.modified }
                    let privates = files.dropFirst().map(\.privateBytes)
                    let measured = privates.allSatisfy { $0 != nil }
                    let reclaim = measured ? privates.compactMap { $0 }.reduce(0, +) : files.dropFirst().map(\.allocated).reduce(0, +)
                    groups.append(DuplicateGroup(id: String(hash.prefix(12)) + "#\(files.count)", size: size, sha256: hash,
                                                 files: files, reclaimable: reclaim,
                                                 reclaimProvenance: measured ? .measured : .estimated))
                }
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func partialHash(_ path: String, size: Int64) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        let chunk = 65_536
        if let head = try? h.read(upToCount: chunk) { hasher.update(data: head) }
        if size > Int64(chunk * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? h.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let data = try? h.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Wraps user-selected large/duplicate files as Trash-only cleanup candidates.
    public static func candidates(for files: [LargeFile], groupID: String? = nil, guardian: PathGuard) -> [CleanupCandidate] {
        files.map { f in
            var usage = DiskUsage()
            usage.logical = f.logical
            usage.allocated = f.privateBytes ?? f.allocated
            usage.files = 1
            usage.newestModification = f.modified
            var blocked: String?
            var target: ValidatedTarget?
            do { target = try guardian.validate(f.path) } catch { blocked = "\(error)" }
            let cls: CleanupClass = groupID != nil ? .review : f.classification
            return CleanupCandidate(id: CleanupCandidate.makeID(rule: groupID ?? "large", path: f.path),
                                    ruleID: groupID == nil ? "large-files" : "duplicates", title: (f.path as NSString).lastPathComponent,
                                    category: groupID == nil ? .largeFile : .duplicate, path: f.path, classification: cls,
                                    confidence: .medium, usage: usage, modified: f.modified, owner: nil, inUseBy: [],
                                    reason: groupID == nil ? f.note : "Identical content (SHA-256) to another file",
                                    consequence: "Moved to Trash; restore from Trash if needed.", allowsDelete: false,
                                    allowsTrash: true, keepRoot: false, target: target,
                                    blockedReason: cls.isActionable ? blocked : "\(cls.rawValue.capitalized) file — open it yourself to decide",
                                    groupID: groupID)
        }
    }
}

extension FTSENT {
    /// `fts_name` is a flexible array member; read it via its address.
    var fts_name_ptr: UnsafePointer<CChar> {
        mutating get { withUnsafePointer(to: &fts_name) { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) } }
    }
}
