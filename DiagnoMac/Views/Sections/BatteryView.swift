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
                    CardRow {
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

                CardRow {
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
        var note = String(format: "%.1f W is lost as heat converting the charger's power.", max(0, t.adapterLoss))
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
                    .animation(.smooth(duration: 0.9), value: percent)

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

/// Diagonal stripes that slide to the right, like current flowing in. Core Animation moves them
/// at up to 60 fps, so the app does no work per frame.
private struct ChargingStripes: NSViewRepresentable {
    func makeNSView(context: Context) -> StripesView { StripesView() }
    func updateNSView(_ view: StripesView, context: Context) {}

    final class StripesView: NSView {
        private let replicator = CAReplicatorLayer()
        private let stripe = CALayer()
        private static let spacing: CGFloat = 22

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            stripe.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
            replicator.addSublayer(stripe)
            layer?.addSublayer(replicator)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            let spacing = Self.spacing, h = bounds.height
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            replicator.frame = CGRect(x: -spacing * 2, y: 0, width: bounds.width + spacing * 4, height: h)
            replicator.instanceCount = Int(replicator.frame.width / spacing) + 2
            replicator.instanceTransform = CATransform3DMakeTranslation(spacing, 0, 0)
            stripe.bounds = CGRect(x: 0, y: 0, width: 9, height: h * 2)
            stripe.position = CGPoint(x: 0, y: h / 2)
            stripe.setAffineTransform(CGAffineTransform(rotationAngle: -0.55))
            CATransaction.commit()

            guard replicator.animation(forKey: "slide") == nil else { return }
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 0
            slide.toValue = spacing
            slide.duration = 1.1
            slide.repeatCount = .infinity
            slide.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            replicator.add(slide, forKey: "slide")
        }
    }
}

// MARK: - Power flow

/// Charger → Mac → (running the Mac, into the battery). The diagram is drawn once per reading;
/// the moving current on top is Core Animation, at up to 60 fps.
struct PowerFlowView: View {
    let telemetry: PowerTelemetry
    let charging: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wire geometry in the diagram's 420 × 200 design space.
    fileprivate static let input = FlowWire.line(from: CGPoint(x: 120, y: 100), to: CGPoint(x: 170, y: 100))
    fileprivate static let system = FlowWire.curve(from: CGPoint(x: 200, y: 100), c1: CGPoint(x: 240, y: 100),
                                                   c2: CGPoint(x: 250, y: 45), to: CGPoint(x: 290, y: 45))
    fileprivate static let battery = FlowWire.curve(from: CGPoint(x: 200, y: 100), c1: CGPoint(x: 240, y: 100),
                                                    c2: CGPoint(x: 250, y: 155), to: CGPoint(x: 290, y: 155))

    var body: some View {
        Canvas { context, size in
            let s = size.width / 420
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            func wire(_ shape: FlowWire, watts: Double) {
                let width = max(3, min(18, CGFloat(watts) / 3)) * s
                context.stroke(shape.path(scale: s), with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            wire(Self.input, watts: telemetry.systemInput)
            wire(Self.system, watts: telemetry.systemLoad)
            wire(Self.battery, watts: max(0, telemetry.battery))

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
        .overlay {
            if !reduceMotion {
                FlowCurrent(wires: [
                    .init(shape: Self.input, color: .controlAccentColor, active: telemetry.systemInput > 0.5),
                    .init(shape: Self.system, color: .controlAccentColor, active: telemetry.systemLoad > 0.5),
                    .init(shape: Self.battery, color: .systemGreen, active: telemetry.battery > 0.5),
                ])
                .allowsHitTesting(false)
            }
        }
        .aspectRatio(420 / 200, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(String(format: "Charger supplies %.1f watts: %.1f to run the Mac and %.1f into the battery.",
                                   telemetry.systemInput, telemetry.systemLoad, telemetry.battery))
    }
}

/// A wire in the diagram's 420 × 200 design space.
fileprivate enum FlowWire: Equatable {
    case line(from: CGPoint, to: CGPoint)
    case curve(from: CGPoint, c1: CGPoint, c2: CGPoint, to: CGPoint)

    func path(scale s: CGFloat) -> Path { Path(cgPath(scale: s)) }

    func cgPath(scale s: CGFloat) -> CGPath {
        let path = CGMutablePath()
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * s, y: point.y * s) }
        switch self {
        case .line(let from, let to):
            path.move(to: p(from)); path.addLine(to: p(to))
        case .curve(let from, let c1, let c2, let to):
            path.move(to: p(from)); path.addCurve(to: p(to), control1: p(c1), control2: p(c2))
        }
        return path
    }
}

/// Dashes that travel along each active wire, animated by Core Animation.
private struct FlowCurrent: NSViewRepresentable {
    struct Wire: Equatable {
        let shape: FlowWire
        let color: NSColor
        let active: Bool
    }

    let wires: [Wire]

    func makeNSView(context: Context) -> CurrentView { CurrentView() }
    func updateNSView(_ view: CurrentView, context: Context) { view.wires = wires }

    final class CurrentView: NSView {
        var wires: [Wire] = [] { didSet { if wires != oldValue { needsLayout = true } } }
        private var layers: [CAShapeLayer] = []

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let host = layer, bounds.width > 0 else { return }
            host.isGeometryFlipped = true
            let s = bounds.width / 420
            while layers.count < wires.count {
                let shape = CAShapeLayer()
                shape.fillColor = nil
                shape.lineCap = .round
                host.addSublayer(shape)
                layers.append(shape)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (wire, shape) in zip(wires, layers) {
                shape.frame = bounds
                shape.path = wire.shape.cgPath(scale: s)
                effectiveAppearance.performAsCurrentDrawingAppearance { shape.strokeColor = wire.color.cgColor }
                shape.lineWidth = 3 * s
                shape.lineDashPattern = [NSNumber(value: Double(2 * s)), NSNumber(value: Double(12 * s))]
                shape.isHidden = !wire.active
            }
            CATransaction.commit()
            for (wire, shape) in zip(wires, layers) {
                if wire.active { flow(shape, scale: s) } else { shape.removeAnimation(forKey: "flow") }
            }
        }

        private func flow(_ shape: CAShapeLayer, scale s: CGFloat) {
            let flow = CABasicAnimation(keyPath: "lineDashPhase")
            flow.fromValue = 0
            flow.toValue = -14 * s
            flow.duration = 0.9
            flow.repeatCount = .infinity
            flow.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            shape.add(flow, forKey: "flow")
        }
    }
}

private struct PowerChart: View {
    let samples: [PowerSample]

    /// Readings further apart than this, such as either side of sleep, aren't joined by a line. They
    /// come every 2 seconds while the page is open and every 2 minutes at the slowest otherwise.
    private static let maxGap: TimeInterval = 3 * 60

    private struct Reading: Identifiable {
        let sample: PowerSample
        /// The unbroken run of readings this one belongs to. Each run is drawn as its own line.
        let run: Int
        var id: Date { sample.date }
    }

    var body: some View {
        // Always the full 10 minutes, so the time labels stay a fixed 2 minutes apart.
        let end = Date()
        let start = end.addingTimeInterval(-PowerSample.window)
        let readings = Self.readings(samples.filter { $0.date >= start })
        if readings.count < 2 {
            Text("Collecting readings…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150)
        } else {
            Chart(readings) { r in
                // Drawn wide and underneath, so it stays visible when it matches the Mac's own use.
                LineMark(x: .value("Time", r.sample.date), y: .value("Watts", r.sample.input), series: .value("Run", "From charger \(r.run)"))
                    .foregroundStyle(by: .value("Series", "From charger"))
                    .lineStyle(StrokeStyle(lineWidth: 5))
                    .opacity(0.45)
                LineMark(x: .value("Time", r.sample.date), y: .value("Watts", max(0, r.sample.battery)), series: .value("Run", "Into battery \(r.run)"))
                    .foregroundStyle(by: .value("Series", "Into battery"))
                LineMark(x: .value("Time", r.sample.date), y: .value("Watts", r.sample.system), series: .value("Run", "Running the Mac \(r.run)"))
                    .foregroundStyle(by: .value("Series", "Running the Mac"))
            }
            .chartForegroundStyleScale(["From charger": Color.accentColor, "Into battery": Color.green, "Running the Mac": Color.orange])
            .chartXScale(domain: start...end)
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text("\(value.as(Int.self) ?? 0) W") } } }
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute(), collisionResolution: .greedy)
                }
            }
            .frame(height: 170)
        }
    }

    /// Numbers the readings by run, starting a new run wherever there's a gap.
    private static func readings(_ samples: [PowerSample]) -> [Reading] {
        var run = 0
        return samples.indices.map { i in
            if i > 0, samples[i].date.timeIntervalSince(samples[i - 1].date) > maxGap { run += 1 }
            return Reading(sample: samples[i], run: run)
        }
    }
}
