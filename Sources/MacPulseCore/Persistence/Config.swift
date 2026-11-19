import Foundation

public struct Thresholds: Codable, Sendable, Equatable {
    public var lowDiskFreePercent: Double = 10
    public var lowDiskFreeBytes: Int64 = 15_000_000_000
    public var swapGrowthBytesPerHour: Double = 2_000_000_000
    public var sustainedCPUPercent: Double = 85
    public var sustainedCPUMinutes: Double = 10
    public var runawayProcessCPUPercent: Double = 90
    public var runawayProcessMinutes: Double = 5
    public var largeProcessFootprintBytes: UInt64 = 4_000_000_000
    public var memoryGrowthBytesPerHour: Double = 200_000_000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Thresholds()
        lowDiskFreePercent = try c.decodeIfPresent(Double.self, forKey: .lowDiskFreePercent) ?? d.lowDiskFreePercent
        lowDiskFreeBytes = try c.decodeIfPresent(Int64.self, forKey: .lowDiskFreeBytes) ?? d.lowDiskFreeBytes
        swapGrowthBytesPerHour = try c.decodeIfPresent(Double.self, forKey: .swapGrowthBytesPerHour) ?? d.swapGrowthBytesPerHour
        sustainedCPUPercent = try c.decodeIfPresent(Double.self, forKey: .sustainedCPUPercent) ?? d.sustainedCPUPercent
        sustainedCPUMinutes = try c.decodeIfPresent(Double.self, forKey: .sustainedCPUMinutes) ?? d.sustainedCPUMinutes
        runawayProcessCPUPercent = try c.decodeIfPresent(Double.self, forKey: .runawayProcessCPUPercent) ?? d.runawayProcessCPUPercent
        runawayProcessMinutes = try c.decodeIfPresent(Double.self, forKey: .runawayProcessMinutes) ?? d.runawayProcessMinutes
        largeProcessFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .largeProcessFootprintBytes) ?? d.largeProcessFootprintBytes
        memoryGrowthBytesPerHour = try c.decodeIfPresent(Double.self, forKey: .memoryGrowthBytesPerHour) ?? d.memoryGrowthBytesPerHour
    }
}

public struct MacPulseConfig: Codable, Sendable, Equatable {
    /// Background monitor sampling interval, seconds (min 10).
    public var sampleIntervalSeconds: Double = 60
    /// Record top processes every N samples.
    public var processSampleEvery: Int = 5
    /// Double the interval while running on battery.
    public var reduceSamplingOnBattery: Bool = true
    public var retentionDays: Int = 14
    public var maxSampleRows: Int = 100_000
    public var notificationsEnabled: Bool = false
    public var notificationCooldownMinutes: Double = 60
    public var thresholds = Thresholds()
    /// Metrics shown in the menu bar: cpu, memory, gpu, thermal, disk, swap.
    public var menuBarMetrics: [String] = ["cpu", "memory"]
    /// Foreground app refresh interval, seconds.
    public var uiRefreshSeconds: Double = 2

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MacPulseConfig()
        sampleIntervalSeconds = max(10, try c.decodeIfPresent(Double.self, forKey: .sampleIntervalSeconds) ?? d.sampleIntervalSeconds)
        processSampleEvery = max(1, try c.decodeIfPresent(Int.self, forKey: .processSampleEvery) ?? d.processSampleEvery)
        reduceSamplingOnBattery = try c.decodeIfPresent(Bool.self, forKey: .reduceSamplingOnBattery) ?? d.reduceSamplingOnBattery
        retentionDays = min(365, max(1, try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays))
        maxSampleRows = max(1000, try c.decodeIfPresent(Int.self, forKey: .maxSampleRows) ?? d.maxSampleRows)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        notificationCooldownMinutes = try c.decodeIfPresent(Double.self, forKey: .notificationCooldownMinutes) ?? d.notificationCooldownMinutes
        thresholds = try c.decodeIfPresent(Thresholds.self, forKey: .thresholds) ?? d.thresholds
        menuBarMetrics = try c.decodeIfPresent([String].self, forKey: .menuBarMetrics) ?? d.menuBarMetrics
        uiRefreshSeconds = min(60, max(1, try c.decodeIfPresent(Double.self, forKey: .uiRefreshSeconds) ?? d.uiRefreshSeconds))
    }

    public static func load(path: String = AppPaths.config) -> MacPulseConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(MacPulseConfig.self, from: data) else { return MacPulseConfig() }
        return cfg
    }

    public func save(path: String = AppPaths.config) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let data = try JSON.encoder().encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Sets a value by dotted key (e.g. `thresholds.lowDiskFreePercent`). Used by `macpulse config set`.
    public mutating func set(_ key: String, _ value: String) throws {
        var dict = (try JSONSerialization.jsonObject(with: JSON.encoder().encode(self))) as? [String: Any] ?? [:]
        let parts = key.split(separator: ".").map(String.init)
        func parse(_ existing: Any?) throws -> Any {
            switch existing {
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    guard let b = Bool(value) else { throw MacPulseError.usage("\(key) expects true/false") }
                    return b
                }
                guard let d = Double(value) else { throw MacPulseError.usage("\(key) expects a number") }
                return d
            case is [Any]:
                return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case nil:
                throw MacPulseError.usage("unknown config key \(key)")
            default:
                return value
            }
        }
        if parts.count == 1 {
            dict[parts[0]] = try parse(dict[parts[0]])
        } else if parts.count == 2, var sub = dict[parts[0]] as? [String: Any] {
            sub[parts[1]] = try parse(sub[parts[1]])
            dict[parts[0]] = sub
        } else {
            throw MacPulseError.usage("unknown config key \(key)")
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        self = try JSONDecoder().decode(MacPulseConfig.self, from: data)
    }
}
