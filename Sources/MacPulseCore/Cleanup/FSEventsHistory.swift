import CoreServices
import Darwin
import Foundation

/// Reads the persistent FSEvents journal to learn which directories changed since a given event ID.
/// This lets disk-growth scans re-measure only changed folders instead of walking the whole home folder.
public enum FSEventsHistory {
    public struct Changes: Sendable {
        /// Directories (normalized, no trailing slash) in which something changed.
        public var paths: Set<String>
        /// Directories whose whole subtree must be rescanned (coalesced or dropped events).
        public var subtreeRescans: Set<String>
        /// The journal cannot answer reliably (wrapped IDs, dropped events at the root, root changed…).
        public var fullRescan: Bool
        public var eventCount: Int

        public func isDirty(_ dir: String) -> Bool {
            if fullRescan { return true }
            if paths.contains(dir) { return true }
            let prefix = dir + "/"
            if paths.contains(where: { $0.hasPrefix(prefix) }) { return true }
            // A coalesced subtree event above or inside this folder.
            return subtreeRescans.contains { $0 == dir || dir.hasPrefix($0 + "/") || $0.hasPrefix(prefix) }
        }
    }

    public static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    /// Journal identity of the volume holding `path`; a different UUID means the journal was reset.
    public static func volumeUUID(for path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static func normalize(_ p: String) -> String {
        var s = p
        if s.hasPrefix("/System/Volumes/Data/") { s.removeFirst("/System/Volumes/Data".count) }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var paths = Set<String>()
        var subtree = Set<String>()
        var full = false
        var count = 0
        let done = DispatchSemaphore(value: 0)
        var finished = false
    }

    /// Replays journal events under `root` since `since`. Returns nil if the stream cannot be created
    /// or the history replay does not finish within `timeout` (callers then do a full scan).
    public static func changes(since: UInt64, root: String, timeout: TimeInterval = 30) -> Changes? {
        let collector = Collector()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let c = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            c.lock.lock(); defer { c.lock.unlock() }
            for i in 0..<count {
                let f = Int(flags[i])
                if f & kFSEventStreamEventFlagHistoryDone != 0 {
                    if !c.finished { c.finished = true; c.done.signal() }
                    continue
                }
                c.count += 1
                if f & (kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 { c.full = true }
                guard i < paths.count else { continue }
                let p = FSEventsHistory.normalize(paths[i])
                if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    c.subtree.insert(p)
                } else {
                    c.paths.insert(p)
                }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root] as CFArray,
                                               since, 0, flags) else { return nil }
        let queue = DispatchQueue(label: "macpulse.fsevents.history")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil }
        let ok = collector.done.wait(timeout: .now() + timeout) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        guard ok else { return nil }
        collector.lock.lock(); defer { collector.lock.unlock() }
        let normRoot = normalize(root)
        // A subtree rescan at (or above) the root means the journal lost detail for everything.
        let full = collector.full || collector.subtree.contains { normRoot == $0 || normRoot.hasPrefix($0 + "/") }
        return Changes(paths: collector.paths, subtreeRescans: collector.subtree, fullRescan: full, eventCount: collector.count)
    }
}
