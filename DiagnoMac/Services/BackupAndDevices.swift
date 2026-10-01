import Foundation

enum BackupCollector {
    static func collect() async -> BackupInfo {
        async let destinationInfo = Shell.run("/usr/bin/tmutil", ["destinationinfo"])
        async let latest = Shell.run("/usr/bin/tmutil", ["latestbackup"])
        async let auto = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.TimeMachine", "AutoBackup"])

        let info = await destinationInfo
        var destinations: [String] = []
        if !info.stdout.contains("No destinations configured") {
            for line in info.stdout.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "Name" { destinations.append(parts[1]) }
            }
        }

        // Backup folders are named like 2026-09-30-123456.backup.
        var latestDate: Date?
        let latestOut = await latest.stdout
        if let range = latestOut.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            latestDate = f.date(from: String(latestOut[range]))
        }

        let autoOut = await auto
        return BackupInfo(destinations: destinations, latestBackup: latestDate,
                          autoBackup: autoOut.succeeded ? autoOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" : nil)
    }
}

enum DevicesCollector {
    static func collect() async -> DevicesInfo {
        let result = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "SPUSBHostDataType", "-json"], timeout: 30)
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            return DevicesInfo(bluetoothOn: nil, bluetooth: [], usb: [])
        }

        var bluetooth: [BluetoothDevice] = []
        var bluetoothOn: Bool?
        if let bt = (json["SPBluetoothDataType"] as? [[String: Any]])?.first {
            if let controller = bt["controller_properties"] as? [String: Any], let state = controller["controller_state"] as? String {
                bluetoothOn = state.contains("on")
            }
            for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                for entry in bt[key] as? [[String: Any]] ?? [] {
                    for (name, value) in entry {
                        let props = value as? [String: Any] ?? [:]
                        bluetooth.append(BluetoothDevice(name: name, kind: props["device_minorType"] as? String,
                                                         isConnected: connected, batteryLevels: batteryLevels(props)))
                    }
                }
            }
        }

        var usb: [USBDevice] = []
        func walk(_ items: [[String: Any]]) {
            for item in items {
                let name = item["_name"] as? String ?? ""
                if !name.isEmpty, !name.hasSuffix("Bus"), !name.contains("Root Hub") {
                    usb.append(USBDevice(name: name,
                                         vendor: (item["USBKeyVendorName"] ?? item["manufacturer"]) as? String,
                                         speed: (item["USBDeviceKeyLinkSpeed"] ?? item["device_speed"]) as? String))
                }
                walk(item["_items"] as? [[String: Any]] ?? [])
            }
        }
        walk(json["SPUSBHostDataType"] as? [[String: Any]] ?? [])

        return DevicesInfo(bluetoothOn: bluetoothOn,
                           bluetooth: bluetooth.sorted { ($0.isConnected ? 0 : 1, $0.name) < ($1.isConnected ? 0 : 1, $1.name) },
                           usb: usb)
    }

    /// Keys like device_batteryLevelMain = "85%", device_batteryLevelLeft, device_batteryLevelCase.
    private static func batteryLevels(_ props: [String: Any]) -> [BluetoothDevice.Level] {
        props.compactMap { key, value -> BluetoothDevice.Level? in
            guard key.hasPrefix("device_batteryLevel"), let text = value as? String,
                  let percent = Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) else { return nil }
            let label = key.replacingOccurrences(of: "device_batteryLevel", with: "")
            return BluetoothDevice.Level(label: label == "Main" ? "" : label, percent: percent)
        }
        .sorted { $0.label < $1.label }
    }
}

/// Remembers every time the charger is connected, so a weak charger or cable shows up over time.
enum ChargeLogStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DiagnoMac/charge-log.json")
    }

    static func load() -> [ChargeSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ChargeSession].self, from: data)) ?? []
    }

    static func save(_ sessions: [ChargeSession]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(sessions.suffix(100))).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DiagnoMac: could not save charge log: \(error)")
        }
    }
}
