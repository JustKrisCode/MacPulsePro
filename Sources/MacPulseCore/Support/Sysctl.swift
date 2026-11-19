import Darwin
import Foundation

/// Typed wrappers around sysctlbyname. Every function returns nil when the key is unavailable.
public enum Sysctl {
    public static func data(_ name: String) -> [UInt8]? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return Array(buf.prefix(size))
    }

    /// Reads a 4- or 8-byte integer sysctl.
    public static func int(_ name: String) -> Int64? {
        guard let d = data(name) else { return nil }
        switch d.count {
        case 4: return Int64(d.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        case 8: return d.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        default: return nil
        }
    }

    public static func string(_ name: String) -> String? {
        guard let d = data(name) else { return nil }
        return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
    }

    public static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }
}

/// Mach absolute time → nanoseconds. Apple Silicon's timebase is 125/3, so raw ticks are NOT ns.
public enum MachTime {
    public static func toNanoseconds(_ ticks: UInt64) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let numer = UInt64(info.numer), denom = UInt64(max(info.denom, 1))
        return ticks / denom * numer + (ticks % denom) * numer / denom
    }
}

/// Converts a fixed-size C char tuple (e.g. `p_comm`) into a String.
func stringFromCTuple<T>(_ tuple: T) -> String {
    var copy = tuple
    return withUnsafeBytes(of: &copy) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}
