import Charts
import SwiftUI

struct BatteryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Battery", subtitle: "Wear, charge and power source. Capacity normally drops 1–2% for every 50 cycles.") {
            Button("Refresh") { Task { await model.refresh(.battery) } }
        } content: {
            if let b = model.snapshot.battery {
                Columns(minimum: 200) {
                    StatTile(title: "Maximum capacity", value: b.healthPercent.map(String.init) ?? "—", unit: "%",
                             caption: b.condition ?? "Normal", severity: (b.healthPercent ?? 100) < 80 ? .warning : .ok)
                    StatTile(title: "Cycle count", value: "\(b.cycleCount)", unit: "/ \(b.designCycleCount)",
                             caption: "Rated for \(b.designCycleCount) cycles")
                    StatTile(title: "Charge", value: "\(b.chargePercent)", unit: "%", caption: chargeCaption(b))
                    StatTile(title: b.isCharging ? "Time to full" : "Time remaining",
                             value: (b.isCharging ? b.minutesToFull : b.minutesToEmpty).map(Format.minutes) ?? "—",
                             caption: b.externalConnected ? "Power adapter connected" : "At current usage")
                }

                HStack(alignment: .top, spacing: 14) {
                    Card("Capacity") {
                        VStack(spacing: 7) {
                            if let v = b.designCapacity { KeyValueRow(key: "Design capacity", value: "\(v.formatted()) mAh") }
                            if let v = b.fullChargeCapacity { KeyValueRow(key: "Full charge capacity", value: "\(v.formatted()) mAh") }
                            if let v = b.nominalCapacity { KeyValueRow(key: "Nominal capacity", value: "\(v.formatted()) mAh") }
                            if let v = b.remainingCapacity { KeyValueRow(key: "Currently stored", value: "\(v.formatted()) mAh") }
                            if let t = b.temperatureC { KeyValueRow(key: "Temperature", value: String(format: "%.1f °C", t)) }
                            if let v = b.voltageV { KeyValueRow(key: "Voltage", value: String(format: "%.2f V", v)) }
                            if let w = b.watts { KeyValueRow(key: w >= 0 ? "Charging power" : "Power draw", value: String(format: "%.1f W", abs(w))) }
                        }
                        Text("New batteries often report slightly more than their design capacity. That's expected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    historyCard
                }

                if let p = model.snapshot.power { powerCard(p) }
            } else if !model.snapshot.hasBattery {
                Card { Text("This Mac has no battery.").foregroundStyle(.secondary) }
            } else {
                LoadingCard(text: "Reading the battery…")
            }
        }
    }

    private func chargeCaption(_ b: BatteryInfo) -> String {
        if b.isCharging { return "Charging" }
        if b.externalConnected { return b.fullyCharged ? "Charged, on power adapter" : "On power adapter, not charging" }
        return "On battery"
    }

    private var historyCard: some View {
        let points = model.history.filter { $0.batteryHealth != nil }
        return Card("Capacity history", trailing: points.count < 2 ? "Building up" : "\(points.count) days") {
            if points.count < 2 {
                Text("DiagnoMac records capacity once a day. The chart fills in as you keep using the app.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                Chart(points) { entry in
                    LineMark(x: .value("Day", entry.day), y: .value("Capacity", entry.batteryHealth ?? 0))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Day", entry.day), y: .value("Capacity", entry.batteryHealth ?? 0))
                        .foregroundStyle(.green.opacity(0.12))
                }
                .chartYScale(domain: 70...100)
                .foregroundStyle(.green)
                .frame(height: 140)
            }
        }
    }

    private func powerCard(_ p: PowerSettings) -> some View {
        Card("Power settings") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("Setting").foregroundStyle(.secondary)
                    Text("On battery").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("On power adapter").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                Divider()
                row("Display sleep", p.battery.displaySleepMinutes.map(minutes), p.ac.displaySleepMinutes.map(minutes))
                row("System sleep", p.battery.systemSleepMinutes.map(minutes), p.ac.systemSleepMinutes.map(minutes))
                row("Low Power Mode", p.battery.lowPowerMode.map(onOff), p.ac.lowPowerMode.map(onOff))
                row("Wake for network access", p.battery.wakeOnNetwork.map(onOff), p.ac.wakeOnNetwork.map(onOff))
            }
            if let ac = p.ac.displaySleepMinutes, ac > 30 {
                Text("The display stays on for \(minutes(ac)) on power. 10–15 minutes saves energy and screen wear.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ name: String, _ battery: String?, _ ac: String?) -> some View {
        GridRow {
            Text(name)
            Text(battery ?? "—").monospacedDigit()
            Text(ac ?? "—").monospacedDigit()
        }
    }

    private func minutes(_ m: Int) -> String { m == 0 ? "Never" : Format.minutes(m) }
    private func onOff(_ b: Bool) -> String { b ? "On" : "Off" }
}
