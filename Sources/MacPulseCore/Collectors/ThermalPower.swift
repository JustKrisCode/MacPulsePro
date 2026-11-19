import Foundation
import IOKit
import IOKit.ps

public enum ThermalState: String, Codable, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    public var rank: Int { switch self { case .nominal: 0; case .fair: 1; case .serious: 2; case .critical: 3 } }
    public static func < (a: ThermalState, b: ThermalState) -> Bool { a.rank < b.rank }
}

public struct ThermalSnapshot: Codable, Sendable {
    public var timestamp: Date
    /// ProcessInfo.thermalState — documented, the authoritative public signal.
    public var state: ThermalState
    public var lowPowerMode: Bool
    /// `pmset -g therm` CPU speed limit (percent), when the system has recorded one.
    public var cpuSpeedLimit: Metric<Int>
    public var batteryTemperatureC: Metric<Double>
    public var cpuTemperatureC: Metric<Double>
    public var throttlingIndicator: ThrottlingIndicator
}

public struct ThrottlingIndicator: Codable, Sendable {
    public var likely: Bool
    public var provenance: Provenance
    public var reasons: [String]
}

public enum ThermalCollector {
    /// Cheap: no subprocess. Pass `includePmset` only for on-demand views (spawns `pmset`).
    public static func snapshot(includePmset: Bool = false, runner: CommandRunner = SystemCommandRunner()) -> ThermalSnapshot {
        let state = ThermalState(ProcessInfo.processInfo.thermalState)
        let speedLimit: Metric<Int>
        if includePmset {
            let r = runner.run("/usr/bin/pmset", ["-g", "therm"], timeout: 5)
            speedLimit = r.ok ? parseSpeedLimit(r.stdout) : .unavailable("pmset -g therm", "pmset failed: \(r.stderr)")
        } else {
            speedLimit = .unavailable("pmset -g therm", "Not sampled (on-demand only).")
        }
        let battery = PowerCollector.batteryTemperature()
        var reasons: [String] = []
        if state >= .serious { reasons.append("macOS thermal state is \(state.rawValue)") }
        if let limit = speedLimit.value, limit < 100 { reasons.append("pmset reports CPU speed limit \(limit)%") }
        return ThermalSnapshot(
            timestamp: Date(), state: state, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            cpuSpeedLimit: speedLimit,
            batteryTemperatureC: battery.map { Metric($0, .measuredUndocumented, source: "AppleSmartBattery Temperature") }
                ?? .unavailable("AppleSmartBattery", "No battery temperature published."),
            cpuTemperatureC: .unavailable("SMC / HID sensors", "CPU/GPU die temperatures require private APIs; MacPulse does not read them."),
            throttlingIndicator: ThrottlingIndicator(likely: !reasons.isEmpty, provenance: .inferred, reasons: reasons))
    }

    /// Parses lines like "CPU_Speed_Limit = 100".
    static func parseSpeedLimit(_ text: String) -> Metric<Int> {
        for line in text.split(whereSeparator: \.isNewline) where line.contains("CPU_Speed_Limit") {
            if let v = line.split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                return Metric(v, .measured, source: "pmset -g therm")
            }
        }
        return Metric(nil, .unavailable, source: "pmset -g therm",
                      note: "No CPU speed limit recorded (normal when no thermal event has occurred).")
    }
}

public struct PowerSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var hasBattery: Bool
    public var source: String
    public var chargePercent: Int?
    public var isCharging: Bool?
    public var fullyCharged: Bool?
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    public var designCapacity_mAh: Int?
    public var nominalCapacity_mAh: Int?
    public var rawMaxCapacity_mAh: Int?
    /// nominal / design capacity — close to the "Maximum Capacity" shown in System Settings.
    public var healthPercent: Metric<Double>
    public var voltage_mV: Int?
    public var amperage_mA: Int?
    /// voltage × amperage; negative while discharging.
    public var batteryPowerW: Metric<Double>
    public var adapterWatts: Int?
}

public enum PowerCollector {
    public static func snapshot() -> PowerSnapshot {
        var snap = PowerSnapshot(timestamp: Date(), hasBattery: false, source: "AC Power",
                                 healthPercent: .unavailable("AppleSmartBattery", "No battery"),
                                 batteryPowerW: .unavailable("AppleSmartBattery", "No battery"))
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
                snap.source = type
            }
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                snap.hasBattery = true
                snap.chargePercent = desc[kIOPSCurrentCapacityKey] as? Int
                snap.isCharging = desc[kIOPSIsChargingKey] as? Bool
                let ttE = desc[kIOPSTimeToEmptyKey] as? Int
                if let ttE, ttE > 0 { snap.minutesRemaining = ttE }
            }
        }
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return snap }
        defer { IOObjectRelease(battery) }
        guard let props = IORegistry.properties(battery) else { return snap }
        snap.hasBattery = true
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int? {
            (IORegistry.number(props[k]) ?? IORegistry.number(data[k])).map { Int(truncatingIfNeeded: $0) }
        }
        snap.cycleCount = int("CycleCount")
        snap.designCapacity_mAh = int("DesignCapacity")
        snap.nominalCapacity_mAh = int("NominalChargeCapacity")
        snap.rawMaxCapacity_mAh = int("AppleRawMaxCapacity")
        snap.fullyCharged = props["FullyCharged"] as? Bool
        snap.voltage_mV = int("Voltage")
        // Amperage is a signed value that IOKit may surface as a large unsigned number.
        if let raw = IORegistry.number(props["Amperage"]) { snap.amperage_mA = Int(Int32(truncatingIfNeeded: raw)) }
        if let adapter = props["AdapterDetails"] as? [String: Any] { snap.adapterWatts = adapter["Watts"] as? Int }
        if let design = snap.designCapacity_mAh, design > 0, let nominal = snap.nominalCapacity_mAh ?? snap.rawMaxCapacity_mAh {
            snap.healthPercent = Metric(Double(nominal) / Double(design) * 100, .estimated,
                                        source: "AppleSmartBattery NominalChargeCapacity / DesignCapacity",
                                        note: "System Settings may round or use a slightly different formula.")
        }
        if let v = snap.voltage_mV, let a = snap.amperage_mA {
            snap.batteryPowerW = Metric(Double(v) * Double(a) / 1e6, .estimated, source: "Voltage × Amperage",
                                        note: "Battery flow only; excludes power supplied directly by the adapter.")
        }
        return snap
    }

    static func batteryTemperature() -> Double? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        // Published in hundredths of a degree Celsius when present.
        guard let raw = IORegistry.int(battery, "Temperature"), raw > 0 else { return nil }
        return Double(raw) / 100
    }
}
