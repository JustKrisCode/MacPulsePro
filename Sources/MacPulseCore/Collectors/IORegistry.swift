import Foundation
import IOKit

/// Helpers for reading IORegistry properties that may be stored as CFData, CFNumber or CFString.
enum IORegistry {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        switch property(entry, key) {
        case let s as String: return s
        case let d as Data: return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
        default: return nil
        }
    }

    static func int(_ entry: io_registry_entry_t, _ key: String) -> Int64? {
        number(property(entry, key))
    }

    static func number(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let d as Data where d.count == 4: return Int64(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        case let d as Data where d.count == 8: return d.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        default: return nil
        }
    }

    static func className(_ entry: io_object_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buf)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Iterates matching services, releasing each one after the body runs.
    static func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    static func forEachChild(_ entry: io_registry_entry_t, plane: String = "IOService", _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            body(child)
            IOObjectRelease(child)
        }
    }
}
