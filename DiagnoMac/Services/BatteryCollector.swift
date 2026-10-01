import Foundation
import IOKit
import IOKit.ps

enum BatteryCollector {
    /// Returns nil on Macs without a battery.
    static func collect() async -> BatteryInfo? {
        guard var info = await offMain({ read() }) else { return nil }
        if info.condition == nil { info.condition = await profilerCondition() }
        return info
    }

    /// The fast IOKit-only read used every few seconds. Skips the system_profiler fallback,
    /// which is far too heavy to run continuously.
    static func readLive() async -> BatteryInfo? {
        await offMain { read() }
    }

    /// Fallback for when the power source API doesn't report health (seen on macOS 27).
    private static func profilerCondition() async -> String? {
        let result = await Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"])
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let entries = json["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for entry in entries {
            if let health = (entry["sppower_battery_health_info"] as? [String: Any])?["sppower_battery_health"] as? String {
                return health == "Good" ? "Normal" : health
            }
        }
        return nil
    }

    private static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        guard props["BatteryInstalled"] as? Bool ?? true else { return nil }

        // Recent macOS versions keep the capacity figures inside BatteryData.
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (props[key] as? Int) ?? (data[key] as? Int) }
        func signed(_ key: String) -> Int? {
            // Amperage is reported as an unsigned 64-bit pattern of a signed value.
            if let n = props[key] as? NSNumber { return Int(truncatingIfNeeded: n.int64Value) }
            return nil
        }
        func minutes(_ key: String) -> Int? {
            guard let m = int(key), m > 0, m < 65535 else { return nil }
            return m
        }

        var info = BatteryInfo(
            chargePercent: int("CurrentCapacity") ?? 0,
            cycleCount: int("CycleCount") ?? 0,
            designCapacity: int("DesignCapacity"),
            fullChargeCapacity: int("FullChargeCapacity") ?? int("AppleRawMaxCapacity"),
            nominalCapacity: int("NominalChargeCapacity"),
            remainingCapacity: int("RemainingCapacity") ?? int("AppleRawCurrentCapacity"),
            condition: nil,
            temperatureC: (int("Temperature") ?? int("VirtualTemperature")).map { Double($0) / 100 },
            voltageV: int("Voltage").map { Double($0) / 1000 },
            amperageMA: signed("Amperage"),
            isCharging: props["IsCharging"] as? Bool ?? false,
            externalConnected: props["ExternalConnected"] as? Bool ?? false,
            fullyCharged: props["FullyCharged"] as? Bool ?? false,
            minutesToEmpty: minutes("AvgTimeToEmpty"),
            minutesToFull: minutes("AvgTimeToFull")
        )
        info.condition = powerSourceCondition()

        if info.externalConnected, let details = props["AdapterDetails"] as? [String: Any],
           let watts = details["Watts"] as? Int, watts > 0 {
            let name = (details["Name"] as? String)?.trimmingCharacters(in: .whitespaces)
            info.adapter = AdapterInfo(
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(watts)W USB-C charger",
                watts: watts,
                voltageV: (details["AdapterVoltage"] as? Int).map { Double($0) / 1000 },
                currentA: (details["Current"] as? Int).map { Double($0) / 1000 })
        }

        // Milliwatts; BatteryPower is a signed value stored as unsigned.
        if let t = props["PowerTelemetryData"] as? [String: Any] {
            func watts(_ key: String) -> Double {
                (t[key] as? NSNumber).map { Double(Int64(truncatingIfNeeded: $0.int64Value)) / 1000 } ?? 0
            }
            info.telemetry = PowerTelemetry(systemInput: watts("SystemPowerIn"), battery: watts("BatteryPower"),
                                            systemLoad: watts("SystemLoad"), adapterLoss: watts("AdapterEfficiencyLoss"))
        }
        return info
    }

    /// "Normal", "Service Recommended", etc., from the power source API.
    private static func powerSourceCondition() -> String? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let condition = desc["BatteryHealthCondition"] as? String, !condition.isEmpty { return condition }
            if let health = desc[kIOPSBatteryHealthKey] as? String {
                return health == "Good" ? "Normal" : health
            }
        }
        return nil
    }

    static func powerSettings() async -> PowerSettings {
        let result = await Shell.run("/usr/bin/pmset", ["-g", "custom"])
        var profiles: [String: PowerSettings.Profile] = [:]
        var current: String?
        for raw in result.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                current = line.hasPrefix("Battery") ? "battery" : line.hasPrefix("AC") ? "ac" : nil
                if let current { profiles[current] = PowerSettings.Profile() }
                continue
            }
            guard let key = current else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let value = Int(parts[1]) else { continue }
            switch parts[0] {
            case "displaysleep": profiles[key]?.displaySleepMinutes = value
            case "sleep": profiles[key]?.systemSleepMinutes = value
            case "lowpowermode": profiles[key]?.lowPowerMode = value != 0
            case "womp": profiles[key]?.wakeOnNetwork = value != 0
            default: break
            }
        }
        return PowerSettings(battery: profiles["battery"] ?? .init(), ac: profiles["ac"] ?? .init())
    }
}
