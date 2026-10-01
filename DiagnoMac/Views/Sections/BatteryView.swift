import Charts
import SwiftUI

struct BatteryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Battery", subtitle: "Charge, power flow and wear. Plug in the charger to see where the power goes.") {
            Button("Refresh") { Task { await model.refresh(.battery) } }
        } content: {
            if let b = model.snapshot.battery {
                hero(b)

                if b.externalConnected, let t = b.telemetry {
                    HStack(alignment: .top, spacing: 14) {
                        Card("Power flow", trailing: "Live from the battery controller") {
                            PowerFlowView(telemetry: t, charging: b.isCharging)
                            Text(flowNote(b, t)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Card("Power, last 10 minutes", trailing: "Updates every 2 seconds") {
                            PowerChart(samples: model.powerHistory)
                            VStack(spacing: 6) {
                                if let v = b.voltageV { KeyValueRow(key: "Battery voltage", value: String(format: "%.2f V", v)) }
                                if let a = b.amperageMA { KeyValueRow(key: "Current into battery", value: String(format: "%.2f A", Double(a) / 1000)) }
                                if let adapter = b.adapter, let v = adapter.voltageV {
                                    KeyValueRow(key: "Charger output", value: String(format: "%.0f V · %@", v, adapter.currentA.map { String(format: "%.2f A", $0) } ?? ""))
                                }
                            }
                        }
                    }
                }

                Columns(minimum: 190) {
                    StatTile(title: "Maximum capacity", value: b.healthPercent.map(String.init) ?? "—", unit: "%",
                             caption: b.condition ?? "Normal", severity: (b.healthPercent ?? 100) < 80 ? .warning : .ok)
                    StatTile(title: "Cycle count", value: "\(b.cycleCount)", unit: "/ \(b.designCycleCount)",
                             caption: "Rated for \(b.designCycleCount) cycles")
                    StatTile(title: "Design capacity", value: b.designCapacity.map { $0.formatted() } ?? "—", unit: "mAh",
                             caption: b.fullChargeCapacity.map { "Full charge \($0.formatted()) mAh" })
                    if let t = b.temperatureC {
                        StatTile(title: "Temperature", value: String(format: "%.1f", t), unit: "°C",
                                 caption: t > 40 ? "Warm. Charging slows when hot." : "Normal")
                    } else if let t = b.telemetry {
                        StatTile(title: "Mac is using", value: String(format: "%.1f", t.systemLoad), unit: "W",
                                 caption: b.externalConnected ? "Supplied by the charger" : "From the battery")
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    capacityCard(b)
                    historyCard
                }

                chargeLogCard

                if let p = model.snapshot.power { powerCard(p) }
            } else if !model.snapshot.hasBattery {
                Card { Text("This Mac has no battery.").foregroundStyle(.secondary) }
            } else {
                LoadingCard(text: "Reading the battery…")
            }
        }
    }

    // MARK: Hero

    private func hero(_ b: BatteryInfo) -> some View {
        Card {
            HStack(spacing: 28) {
                BatteryGlyph(percent: b.chargePercent, charging: b.isCharging)
                    .frame(width: 150, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("\(b.chargePercent)%").font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                        if b.isCharging {
                            LiveBadge(text: "Charging")
                        } else if b.externalConnected {
                            SeverityPill(severity: .info, text: b.fullyCharged || b.chargePercent >= 100 ? "Charged" : "On power, not charging")
                        }
                    }
                    Text(statusLine(b)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if b.isCharging && b.chargePercent >= 80 {
                        Text("Charging slows down above 80% to protect the battery. That's normal.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if b.externalConnected && !b.isCharging && b.chargePercent < 95 {
                        Text("macOS may be holding the charge to protect the battery (Optimized Charging).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private func statusLine(_ b: BatteryInfo) -> String {
        if b.isCharging {
            var parts = [b.minutesToFull.map { "Full in about \(Format.minutes($0))" } ?? "Estimating time to full…"]
            if let a = b.adapter { parts.append("\(a.name) (negotiated \(a.watts) W)") }
            return parts.joined(separator: " · ")
        }
        if b.externalConnected {
            return b.adapter.map { "\($0.name) connected (\($0.watts) W)" } ?? "Power adapter connected"
        }
        var parts = [b.minutesToEmpty.map { "About \(Format.minutes($0)) left at current usage" } ?? "Estimating time remaining…"]
        if let w = b.watts { parts.append(String(format: "using %.1f W", abs(w))) }
        return parts.joined(separator: " · ")
    }

    private func flowNote(_ b: BatteryInfo, _ t: PowerTelemetry) -> String {
        var note = String(format: "%.1f W is lost as heat converting the charger's power.", t.adapterLoss)
        if let a = b.adapter, t.systemInput > Double(a.watts) * 0.9 {
            note += " The charger is close to its limit. A higher-wattage charger would charge faster."
        } else if let a = b.adapter {
            note += " The \(a.watts) W charger has headroom."
        }
        return note
    }

    // MARK: Cards

    private func capacityCard(_ b: BatteryInfo) -> some View {
        Card("Capacity") {
            VStack(spacing: 7) {
                if let v = b.designCapacity { KeyValueRow(key: "Design capacity", value: "\(v.formatted()) mAh") }
                if let v = b.fullChargeCapacity { KeyValueRow(key: "Full charge capacity", value: "\(v.formatted()) mAh") }
                if let v = b.nominalCapacity { KeyValueRow(key: "Nominal capacity", value: "\(v.formatted()) mAh") }
                if let v = b.remainingCapacity { KeyValueRow(key: "Currently stored", value: "\(v.formatted()) mAh") }
            }
            Text("New batteries often report slightly more than their design capacity. That's expected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var historyCard: some View {
        let points = model.history.filter { $0.batteryHealth != nil }
        return Card("Capacity history", trailing: points.count < 2 ? "Building up" : "\(points.count) days") {
            if points.count < 2 {
                Text("DiagnoMac records capacity once a day. The chart fills in as you keep using the app.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            } else {
                Chart(points) { entry in
                    LineMark(x: .value("Day", entry.day), y: .value("Capacity", entry.batteryHealth ?? 0))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 70...100)
                .foregroundStyle(.green)
                .frame(height: 130)
            }
        }
    }

    private var chargeLogCard: some View {
        let sessions = Array(model.chargeSessions.suffix(8).reversed())
        return Card("Charge log", trailing: "Every time the charger is connected") {
            if sessions.isEmpty {
                Text("Plug in your charger and DiagnoMac will log it here, with the charger used and the peak power, so a weak charger or cable shows up.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Connected"); Text("Charger"); Text("Charge").gridColumnAlignment(.trailing)
                        Text("Peak power").gridColumnAlignment(.trailing); Text("Duration").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(sessions) { s in
                        GridRow {
                            Text((s.startedBeforeLaunch ? "Before " : "") + s.start.formatted(date: .abbreviated, time: .shortened))
                            Text(s.adapterName.map { "\($0)" } ?? "Unknown charger").foregroundStyle(.secondary).lineLimit(1)
                            Text("\(s.startPercent)% → \(s.endPercent.map { "\($0)%" } ?? "now")").monospacedDigit()
                            Text(String(format: "%.0f W", s.peakWatts)).monospacedDigit()
                            Text(s.end.map { Format.duration($0.timeIntervalSince(s.start)) } ?? "Connected").monospacedDigit()
                        }
                    }
                }
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

// MARK: - Battery glyph

/// A battery outline whose fill shows the charge, with moving stripes and a bolt while charging.
struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fillColor: Color { percent <= 10 ? .red : percent <= 20 ? .orange : .green }

    var body: some View {
        GeometryReader { geo in
            let nub: CGFloat = 8
            let shell = CGSize(width: geo.size.width - nub - 3, height: geo.size.height)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.primary, lineWidth: 3)
                    .frame(width: shell.width, height: shell.height)
                RoundedRectangle(cornerRadius: 3).fill(.primary)
                    .frame(width: nub, height: shell.height * 0.34)
                    .offset(x: shell.width + 3)

                RoundedRectangle(cornerRadius: 8)
                    .fill(fillColor.gradient)
                    .overlay {
                        if charging && !reduceMotion { ChargingStripes().clipShape(RoundedRectangle(cornerRadius: 8)) }
                    }
                    .frame(width: max(8, (shell.width - 12) * CGFloat(percent) / 100), height: shell.height - 12)
                    .offset(x: 6)
                    .animation(.easeOut(duration: 0.6), value: percent)

                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: shell.height * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .frame(width: shell.width, height: shell.height)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Battery \(percent) percent\(charging ? ", charging" : "")")
    }
}

/// Diagonal stripes that slide to the right, like current flowing in.
private struct ChargingStripes: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let spacing: CGFloat = 22
                let offset = CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1) * spacing
                var x = -size.height + offset - spacing
                while x < size.width + spacing {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: size.height))
                    stripe.addLine(to: CGPoint(x: x + size.height * 0.6, y: 0))
                    stripe.addLine(to: CGPoint(x: x + size.height * 0.6 + 9, y: 0))
                    stripe.addLine(to: CGPoint(x: x + 9, y: size.height))
                    stripe.closeSubpath()
                    context.fill(stripe, with: .color(.white.opacity(0.28)))
                    x += spacing
                }
            }
        }
    }
}

// MARK: - Power flow

/// Charger → Mac → (running the Mac, into the battery), with animated current.
struct PowerFlowView: View {
    let telemetry: PowerTelemetry
    let charging: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let s = size.width / 420
                func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
                let phase = reduceMotion ? 0 : -CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 14) * s

                var input = Path(); input.move(to: p(120, 100)); input.addLine(to: p(170, 100))
                var system = Path(); system.move(to: p(200, 100)); system.addCurve(to: p(290, 45), control1: p(240, 100), control2: p(250, 45))
                var battery = Path(); battery.move(to: p(200, 100)); battery.addCurve(to: p(290, 155), control1: p(240, 100), control2: p(250, 155))

                func wire(_ path: Path, watts: Double, color: Color) {
                    let width = max(3, min(18, CGFloat(watts) / 3)) * s
                    context.stroke(path, with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    if watts > 0.5 {
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round, dash: [2 * s, 12 * s], dashPhase: phase))
                    }
                }
                wire(input, watts: telemetry.systemInput, color: .accentColor)
                wire(system, watts: telemetry.systemLoad, color: .accentColor)
                wire(battery, watts: max(0, telemetry.battery), color: .green)

                func box(_ rect: CGRect, fill: Color, stroke: Color, title: String, value: String, valueColor: Color = .primary) {
                    let r = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
                    let shape = Path(roundedRect: r, cornerRadius: 10 * s)
                    context.fill(shape, with: .color(fill))
                    context.stroke(shape, with: .color(stroke), lineWidth: 1)
                    context.draw(Text(title).font(.system(size: 11 * s)).foregroundStyle(.secondary), at: CGPoint(x: r.midX, y: r.minY + 22 * s))
                    context.draw(Text(value).font(.system(size: 18 * s, design: .monospaced)).foregroundStyle(valueColor),
                                 at: CGPoint(x: r.midX, y: r.minY + r.height * 0.66))
                }
                box(CGRect(x: 6, y: 66, width: 114, height: 68), fill: .secondary.opacity(0.08), stroke: .secondary.opacity(0.25),
                    title: "Charger", value: String(format: "%.1f W", telemetry.systemInput))
                box(CGRect(x: 290, y: 14, width: 124, height: 62), fill: .secondary.opacity(0.08), stroke: .secondary.opacity(0.25),
                    title: "Running the Mac", value: String(format: "%.1f W", telemetry.systemLoad))
                box(CGRect(x: 290, y: 124, width: 124, height: 62), fill: .green.opacity(charging ? 0.12 : 0.05), stroke: .green.opacity(0.35),
                    title: charging ? "Into the battery" : "Battery (not charging)",
                    value: String(format: "%+.1f W", telemetry.battery), valueColor: charging ? .green : .secondary)

                let hub = Path(ellipseIn: CGRect(x: 170 * s, y: 85 * s, width: 30 * s, height: 30 * s))
                context.fill(hub, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(hub, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                context.draw(Text("Mac").font(.system(size: 10 * s)).foregroundStyle(.secondary), at: p(185, 100))
            }
        }
        .aspectRatio(420 / 200, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(String(format: "Charger supplies %.1f watts: %.1f to run the Mac and %.1f into the battery.",
                                   telemetry.systemInput, telemetry.systemLoad, telemetry.battery))
    }
}

private struct PowerChart: View {
    let samples: [PowerSample]

    var body: some View {
        if samples.count < 2 {
            Text("Collecting readings…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150)
        } else {
            Chart {
                ForEach(samples) { s in
                    // Drawn wide and underneath, so it stays visible when it matches the Mac's own use.
                    LineMark(x: .value("Time", s.date), y: .value("Watts", s.input), series: .value("Series", "From charger"))
                        .foregroundStyle(by: .value("Series", "From charger"))
                        .lineStyle(StrokeStyle(lineWidth: 5))
                        .opacity(0.45)
                    LineMark(x: .value("Time", s.date), y: .value("Watts", max(0, s.battery)), series: .value("Series", "Into battery"))
                        .foregroundStyle(by: .value("Series", "Into battery"))
                    LineMark(x: .value("Time", s.date), y: .value("Watts", s.system), series: .value("Series", "Running the Mac"))
                        .foregroundStyle(by: .value("Series", "Running the Mac"))
                }
            }
            .chartForegroundStyleScale(["From charger": Color.accentColor, "Into battery": Color.green, "Running the Mac": Color.orange])
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text("\(value.as(Int.self) ?? 0) W") } } }
            .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
            .frame(height: 170)
        }
    }
}
