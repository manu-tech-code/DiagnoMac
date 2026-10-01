import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Devices", subtitle: "Everything connected to this Mac: Bluetooth accessories, displays, USB and power.") {
            Button("Refresh") { Task { await model.refresh(.devices) } }
        } content: {
            if let devices = model.snapshot.devices {
                CardRow {
                    bluetoothCard(devices)
                    VStack(spacing: 14) {
                        displaysCard
                        powerCard
                        usbCard(devices)
                    }
                }
            } else {
                LoadingCard(text: "Looking for devices…")
            }
        }
    }

    private func bluetoothCard(_ devices: DevicesInfo) -> some View {
        Card("Bluetooth", trailing: devices.bluetoothOn == false ? "Off" : "\(devices.bluetooth.filter(\.isConnected).count) connected") {
            if devices.bluetooth.isEmpty {
                Text(devices.bluetoothOn == false ? "Bluetooth is turned off." : "No paired Bluetooth devices.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(devices.bluetooth.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Image(systemName: symbol(for: device.kind))
                                .frame(width: 22)
                                .foregroundStyle(device.isConnected ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).fontWeight(.medium)
                                Text([device.kind, device.isConnected ? "Connected" : "Not connected"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.batteryLevels.isEmpty {
                                Text(device.isConnected ? "Battery not reported" : "—").font(.caption).foregroundStyle(.tertiary)
                            } else {
                                HStack(spacing: 10) {
                                    ForEach(device.batteryLevels, id: \.self) { level in
                                        HStack(spacing: 4) {
                                            if !level.label.isEmpty { Text(level.label).font(.caption).foregroundStyle(.secondary) }
                                            Image(systemName: batterySymbol(level.percent))
                                                .foregroundStyle(level.percent < 20 ? .red : .primary)
                                            Text("\(level.percent)%").monospacedDigit()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                Text("Battery levels appear for accessories that report them, such as AirPods and Apple keyboards, mice and trackpads, while they're connected.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displaysCard: some View {
        Card("Displays") {
            let displays = model.snapshot.machine?.displays ?? []
            if displays.isEmpty {
                Text("Reading displays…").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(displays) { d in
                        KeyValueRow(key: d.name, value: [d.pixels.replacingOccurrences(of: " x ", with: "×"),
                                                         d.resolution.components(separatedBy: "@ ").last].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
        }
    }

    private var powerCard: some View {
        Card("Power") {
            if let battery = model.snapshot.battery, battery.externalConnected {
                VStack(spacing: 7) {
                    KeyValueRow(key: "Charger", value: battery.adapter?.name ?? "Connected")
                    if let a = battery.adapter {
                        KeyValueRow(key: "Negotiated", value: "\(a.watts) W" + (a.voltageV.map { String(format: " at %.0f V", $0) } ?? ""))
                    }
                    if let t = battery.telemetry { KeyValueRow(key: "Drawing now", value: String(format: "%.1f W", t.systemInput)) }
                }
            } else {
                Text(model.snapshot.hasBattery ? "Running on battery. No charger connected." : "Connected to power.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func usbCard(_ devices: DevicesInfo) -> some View {
        Card("USB") {
            if devices.usb.isEmpty {
                Text("No USB devices connected.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(devices.usb) { device in
                        KeyValueRow(key: device.name, value: [device.vendor, device.speed].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
        }
    }

    private func symbol(for kind: String?) -> String {
        switch kind?.lowercased() {
        case "mouse": "computermouse"
        case "keyboard": "keyboard"
        case "headset", "headphones": "headphones"
        case "speaker": "hifispeaker"
        case "trackpad": "rectangle.and.hand.point.up.left"
        case "phone": "iphone"
        default: "dot.radiowaves.left.and.right"
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }
}
