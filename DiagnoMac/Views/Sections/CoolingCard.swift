import AppKit
import QuartzCore
import SwiftUI

/// The cooling section of CPU & GPU: a live fan visual backed by read-only SMC
/// readings, plus the two-minute history and a temperature/response trace.
struct CoolingCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var fan: FanInfo? { model.fanNow }
    private var thermal: ProcessInfo.ThermalState {
        model.snapshot.performance?.thermalState ?? ProcessInfo.processInfo.thermalState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            WidthSwitch(threshold: 820) {
                HStack(alignment: .top, spacing: 16) {
                    stage
                        .frame(maxWidth: .infinity)
                        .frame(height: 420)
                    CoolingReadout(fan: fan, thermal: thermal)
                        .frame(width: 390)
                        .frame(height: 420, alignment: .center)
                }
            } narrow: {
                VStack(spacing: 14) {
                    stage.frame(height: 330)
                    CoolingReadout(fan: fan, thermal: thermal)
                }
            }
            .padding(16)
            .padding(.top, 10)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6))
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.accentColor.opacity(0.55), .cyan.opacity(0.3), .purple.opacity(0.18), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Text("COOLING").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            if fan?.availability == .available {
                LiveBadge(text: "Live")
            } else {
                Text(fan?.availability == .fanless ? "Passive" : (fan == nil ? "Reading…" : "Unavailable"))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .foregroundStyle(fan?.availability == .unavailable ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .background((fan?.availability == .unavailable ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 8)
            if let fan, fan.availability == .available {
                Text("Fan 1 of \(max(fan.fanCount, 1))").font(.caption).foregroundStyle(.secondary)
                if let min = fan.minRPM, let max = fan.maxRPM {
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text("\(min.formatted())–\(max.formatted()) RPM").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            } else if fan?.availability == .fanless {
                Text("No fan").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        if let fan {
            switch fan.availability {
            case .available:
                rotorStage(fan)
            case .fanless:
                passiveStage(title: "Passively cooled",
                             detail: "This Mac has no fan. Heat leaves through the chassis.",
                             symbol: "wind", tint: .cyan)
            case .unavailable:
                unavailableStage(fan)
            }
        } else {
            loadingStage
        }
    }

    private func rotorStage(_ fan: FanInfo) -> some View {
        GeometryReader { geo in
            ZStack {
                stageBackground
                FanRotorView(info: fan,
                             reduceMotion: reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    .padding(1)
                stageLabels
                hubLabel(fan)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.495)
                stageFooter(fan)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fan")
        .accessibilityValue(fanAccessibilityValue(fan))
    }

    private var stageBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.19, green: 0.19, blue: 0.21),
                                    Color(red: 0.10, green: 0.10, blue: 0.11)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.05), .clear],
                           center: UnitPoint(x: 0.5, y: 0.47), startRadius: 10, endRadius: 330)
            Canvas { context, size in
                let spacing: CGFloat = 19
                let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
                let radius = min(size.width, size.height) * 0.44
                for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                    for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                        let distance = hypot(x - center.x, y - center.y)
                        guard distance < radius else { continue }
                        let alpha = 0.055 * (1 - distance / radius)
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                                     with: .color(.white.opacity(alpha)))
                    }
                }
            }
        }
    }

    private var stageLabels: some View {
        VStack {
            HStack {
                stageLabel("AIR IN", color: .cyan)
                Spacer()
                stageLabel("HEAT OUT", color: .orange)
            }
            Spacer()
        }
        .padding(14)
    }

    private func stageLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5).shadow(color: color.opacity(0.7), radius: 4)
            Text(text).font(.system(size: 8.5, weight: .semibold)).tracking(1.1).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func hubLabel(_ fan: FanInfo) -> some View {
        VStack(spacing: 0) {
            if let temp = fan.socTemperature {
                Text("\(Int(temp.rounded()))°")
                    .font(.system(size: 29, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(hubTint(temp))
                Text("SoC").font(.system(size: 7.5, weight: .semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.42))
            } else {
                Text(thermal.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Text("THERMAL").font(.system(size: 7, weight: .semibold)).tracking(1.1).foregroundStyle(.white.opacity(0.4))
            }
        }
        .allowsHitTesting(false)
    }

    private func hubTint(_ temperature: Double) -> Color {
        if temperature >= 95 { return Color(red: 1, green: 0.42, blue: 0.30) }
        if temperature >= 88 { return Color(red: 1, green: 0.72, blue: 0.42) }
        return .white.opacity(0.94)
    }

    private func stageFooter(_ fan: FanInfo) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                HStack(spacing: 7) {
                    Circle().fill(footerColor(fan)).frame(width: 5, height: 5)
                        .shadow(color: footerColor(fan).opacity(0.7), radius: 4)
                    Text(stageMessage(fan)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("SMC").font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.32))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 11)
            .padding(.top, 36)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.52)], startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    private func footerColor(_ fan: FanInfo) -> Color {
        if let max = fan.maxRPM, max > 0, Double(fan.rpm) / Double(max) > 0.82 { return .purple }
        return .orange
    }

    private func stageMessage(_ fan: FanInfo) -> String {
        if thermal == .serious || thermal == .critical {
            return "Heat is building — the fan is catching up"
        }
        if fan.isSpinningUp { return "Spinning up to move the heat out" }
        if let max = fan.maxRPM, max > 0, Double(fan.rpm) / Double(max) > 0.82 { return "Blowing heat out at full tilt" }
        if fan.rpm <= (fan.minRPM ?? 0) + 80, (fan.socTemperature ?? 0) < 50 { return "Holding a quiet idle" }
        return "Pulling heat from the SoC and pushing it out"
    }

    private func fanAccessibilityValue(_ fan: FanInfo) -> String {
        var parts = ["fan \(fan.rpm) RPM"]
        if let percent = fan.percentOfMax { parts.append("\(Int(percent * 100)) percent of maximum") }
        if let temp = fan.socTemperature { parts.append("SoC \(Int(temp.rounded())) degrees Celsius") }
        parts.append(stageMessage(fan))
        return parts.joined(separator: ", ")
    }

    private func unavailableStage(_ fan: FanInfo) -> some View {
        passiveStage(title: "Fan details unavailable", detail: "macOS doesn't expose fan sensors on this Mac.",
                     symbol: "exclamationmark.triangle", tint: .orange)
    }

    private func passiveStage(title: String, detail: String, symbol: String, tint: Color) -> some View {
        ZStack {
            stageBackground
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(tint.opacity(0.8))
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07)) }
        .accessibilityElement(children: .combine)
    }

    private var loadingStage: some View {
        ZStack {
            stageBackground
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the SMC…").font(.callout).foregroundStyle(.white.opacity(0.55))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07)) }
    }
}

// MARK: - Readout

private struct CoolingReadout: View {
    let fan: FanInfo?
    let thermal: ProcessInfo.ThermalState

    private var phase: FanPhase { FanPhase(fan: fan, thermal: thermal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text("FAN SPEED").font(.system(size: 9.8, weight: .semibold)).tracking(1).foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                FanStatusPill(phase: phase)
            }

            if let fan, fan.availability == .available {
                available(fan)
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func available(_ fan: FanInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(fan.rpm.formatted())
                .font(.system(size: 46, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text("RPM").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
        }
        .lineLimit(1)

        HStack(spacing: 4) {
            if let percent = fan.percentOfMax {
                Text("\(Int((percent * 100).rounded()))% of max")
            } else {
                Text("fan speed")
            }
            if let target = fan.targetRPM {
                Text("·").foregroundStyle(.tertiary)
                Text("target \(target.formatted()) RPM")
            }
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        .lineLimit(1)

        FanSpeedMeter(fraction: fan.percentOfMax ?? 0)
        if let max = fan.maxRPM {
            HStack {
                Text("0")
                Spacer()
                Text("\(max.formatted()) RPM")
            }
            .font(.system(size: 8.5)).foregroundStyle(.tertiary)
            .padding(.top, -5)
        }

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 0) {
                    FanMetric(title: "CPU", value: temperature(fan.cpuTemperature), unit: "°C",
                              subtitle: fan.cpuTemperature == nil ? "Sensor unavailable" : "Hottest CPU sensor",
                              tint: (fan.cpuTemperature ?? 0) >= 90 ? .orange : .primary)
                    FanMetric(title: "Thermal state", value: thermal.label,
                              subtitle: thermal == .nominal ? "Not throttling" : "Performance reduced",
                              tint: thermal == .nominal ? .primary : .orange)
                }
                VStack(spacing: 0) {
                    FanMetric(title: "GPU", value: temperature(fan.gpuTemperature), unit: "°C",
                              subtitle: fan.gpuTemperature == nil ? "Sensor unavailable" : "Hottest GPU sensor")
                    FanMetric(title: "Headroom", value: fan.headroom?.formatted() ?? "—", unit: "RPM",
                              subtitle: fan.maxRPM.map { "to \($0.formatted()) max" } ?? "Limit unavailable")
                }
            }
        }

        FanFlowRow()
        HStack {
            if let min = fan.minRPM, let max = fan.maxRPM {
                Text("Min \(min.formatted()) · Max \(max.formatted()) RPM")
            } else {
                Text("Fan speed from AppleSMC")
            }
            Spacer(minLength: 8)
            Text("Sampled every second")
        }
        .font(.system(size: 9)).foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private func temperature(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))" } ?? "—"
    }

    @ViewBuilder private var fallback: some View {
        Text(fan == nil ? "Reading the SMC…" : (fan?.availability == .fanless ? "No fan" : "Fan speed unavailable"))
            .font(.system(size: 30, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
        Text(fan == nil
             ? "Fan speed and temperature will appear in a moment."
             : (fan?.availability == .fanless
                ? "This Mac is cooled passively. The temperature and thermal state are still live."
                : "macOS doesn't expose this Mac's fan. The temperature and thermal state are still live."))
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 0) {
                    FanMetric(title: "CPU", value: temperature(fan?.cpuTemperature), unit: "°C", subtitle: "Processor")
                    FanMetric(title: "Thermal state", value: thermal.label,
                              subtitle: thermal == .nominal ? "Not throttling" : "Performance reduced",
                              tint: thermal == .nominal ? .primary : .orange)
                }
                VStack(spacing: 0) {
                    FanMetric(title: "GPU", value: temperature(fan?.gpuTemperature), unit: "°C", subtitle: "Graphics")
                    FanMetric(title: "Fan", value: fan?.availability == .fanless ? "None" : "—",
                              subtitle: fan?.availability == .fanless ? "Passive cooling" : "Not exposed")
                }
            }
        }
    }
}

private enum FanPhase {
    case availableIdle, spinningUp, spinningDown, holding, maxCooling, thermalPressure, passive, unavailable, loading

    init(fan: FanInfo?, thermal: ProcessInfo.ThermalState) {
        guard let fan else { self = .loading; return }
        switch fan.availability {
        case .fanless: self = .passive; return
        case .unavailable: self = .unavailable; return
        case .available: break
        }
        if fan.isSpinningUp { self = .spinningUp; return }
        if thermal == .serious || thermal == .critical { self = .thermalPressure; return }
        if fan.isSpinningDown { self = .spinningDown; return }
        if let max = fan.maxRPM, max > 0, Double(fan.rpm) / Double(max) >= 0.94 { self = .maxCooling; return }
        if let min = fan.minRPM, fan.rpm <= min + 80, (fan.socTemperature ?? 0) < 50 { self = .availableIdle; return }
        self = .holding
    }

    var label: String {
        switch self {
        case .availableIdle: "Idle"
        case .spinningUp: "Spinning up"
        case .spinningDown: "Spinning down"
        case .holding: "Holding steady"
        case .maxCooling: "Max cooling"
        case .thermalPressure: "Thermal pressure"
        case .passive: "Passive"
        case .unavailable: "Unavailable"
        case .loading: "Reading…"
        }
    }

    var color: Color {
        switch self {
        case .holding, .availableIdle: .green
        case .spinningUp, .spinningDown: .accentColor
        case .maxCooling: .purple
        case .thermalPressure: .orange
        case .passive: .secondary
        case .unavailable: .orange
        case .loading: .secondary
        }
    }
}

private struct FanStatusPill: View {
    let phase: FanPhase
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(phase.color).frame(width: 5, height: 5)
                .shadow(color: phase.color.opacity(0.7), radius: 3)
            Text(phase.label).font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(phase.color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(phase.color.opacity(0.12), in: Capsule())
        .overlay { Capsule().strokeBorder(phase.color.opacity(0.18)) }
        .lineLimit(1)
    }
}

private struct FanMetric: View {
    let title: String
    let value: String
    var unit: String?
    var subtitle: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8.8, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.system(size: 8.8)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator.opacity(0.5)).frame(height: 1)
        }
    }
}

private struct FanSpeedMeter: View {
    let fraction: Double

    var body: some View {
        Canvas { context, size in
            let count = 36
            let gap: CGFloat = 3
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let active = Int((min(1, max(0, fraction)) * Double(count)).rounded())
            let gradient = Gradient(colors: [.accentColor, .cyan, .purple])
            for index in 0..<count {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                if index < active {
                    context.fill(path, with: .linearGradient(gradient,
                                                            startPoint: .zero,
                                                            endPoint: CGPoint(x: size.width, y: 0)))
                } else {
                    context.fill(path, with: .color(.secondary.opacity(0.18)))
                }
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

private struct FanFlowRow: View {
    var body: some View {
        HStack(spacing: 10) {
            end("AIR IN", color: .cyan)
            ZStack {
                Capsule().fill(LinearGradient(colors: [.cyan.opacity(0.34), .orange.opacity(0.48)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                Image(systemName: "fanblades")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.background.secondary)
            }
            end("HEAT OUT", color: .orange)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.4)) }
    }

    private func end(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 4.5, height: 4.5)
            Text(text).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Charts

struct FanChartsRow: View {
    var body: some View {
        CardRow {
            FanResponseCard()
            FanHistoryCard()
        }
    }
}

private struct FanHistoryCard: View {
    @Environment(AppModel.self) private var model

    private var samples: [FanSample] {
        model.fanHistory.filter { $0.date > Date().addingTimeInterval(-120) }
    }

    var body: some View {
        let samples = self.samples
        let peak = samples.map(\.rpm).max()
        Card("Fan, last 2 minutes", trailing: peak.map { "Peak \(Int($0).formatted()) RPM" }) {
            if samples.isEmpty {
                placeholder("Waiting for fan samples…")
            } else {
                FanTraceGraph(samples: samples, maxRPM: model.fanNow?.maxRPM)
                    .frame(height: 150)
                HStack {
                    Text("Average \(Int((samples.map(\.rpm).reduce(0, +) / Double(samples.count)).rounded()).formatted()) RPM")
                    Spacer()
                    Text("\(samples.count) samples · 1 s")
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                Text("The trace starts when this page opens and keeps the last two minutes.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }
}

private struct FanResponseCard: View {
    @Environment(AppModel.self) private var model

    private var samples: [FanSample] {
        model.fanHistory.filter { $0.temperature != nil && $0.date > Date().addingTimeInterval(-120) }
    }

    var body: some View {
        let samples = self.samples
        Card("Fan response", trailing: "Temperature → speed") {
            if samples.count < 2 {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Collecting fan and temperature samples…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                FanResponseGraph(samples: samples, maxRPM: model.fanNow?.maxRPM)
                    .frame(height: 150)
                Text("Each point is one sample. The fan follows temperature, so the point moves after the chip warms — not when load first rises.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Graph primitives

private struct FanTraceGraph: View {
    let samples: [FanSample]
    let maxRPM: Int?

    private var values: [Double] { samples.map(\.rpm) }

    private var bounds: (low: Double, high: Double) {
        let maximum = Double(maxRPM ?? 6000)
        let lowValue = values.min() ?? 0
        let highValue = values.max() ?? maximum
        let low = Swift.max(0, floor((lowValue - 250) / 500) * 500)
        let high = Swift.min(maximum, Swift.max(low + 1000, ceil((highValue + 250) / 500) * 500))
        return (low, high)
    }

    var body: some View {
        let b = bounds
        Canvas { context, size in
            let left: CGFloat = 38, right: CGFloat = 6, top: CGFloat = 6, bottom: CGFloat = 24
            let plot = CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
            let now = Date()
            let window: TimeInterval = 120

            for fraction in [0.0, 0.5, 1.0] {
                let y = plot.maxY - CGFloat(fraction) * plot.height
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.14)), lineWidth: 1)
                let value = b.low + (b.high - b.low) * fraction
                context.draw(Text("\(Int(value).formatted())").font(.system(size: 8)).foregroundStyle(.tertiary),
                             at: CGPoint(x: plot.minX - 5, y: y), anchor: .trailing)
            }

            for (seconds, label) in [(0.0, "2 min"), (60.0, "1 min"), (120.0, "now")] {
                let x = plot.minX + CGFloat(seconds / window) * plot.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(.secondary.opacity(0.08)), lineWidth: 1)
                context.draw(Text(label).font(.system(size: 8)).foregroundStyle(.tertiary),
                             at: CGPoint(x: x, y: plot.maxY + 12), anchor: .center)
            }

            let points = samples.compactMap { sample -> CGPoint? in
                let age = Swift.max(0, Swift.min(window, now.timeIntervalSince(sample.date)))
                let x = plot.maxX - CGFloat(age / window) * plot.width
                let fraction = (sample.rpm - b.low) / Swift.max(b.high - b.low, 1)
                let y = plot.maxY - CGFloat(Swift.min(1, Swift.max(0, fraction))) * plot.height
                return CGPoint(x: x, y: y)
            }

            guard points.count > 1 else {
                if let point = points.first {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                                 with: .color(.accentColor))
                }
                return
            }

            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }

            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: plot.maxY))
            area.addLine(to: CGPoint(x: points[0].x, y: plot.maxY))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [.accentColor.opacity(0.20), .accentColor.opacity(0)]),
                                                     startPoint: CGPoint(x: 0, y: plot.minY),
                                                     endPoint: CGPoint(x: 0, y: plot.maxY)))
            context.stroke(line, with: .linearGradient(Gradient(colors: [.accentColor, .cyan]),
                                                      startPoint: CGPoint(x: plot.minX, y: 0),
                                                      endPoint: CGPoint(x: plot.maxX, y: 0)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            if let last = points.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 7, y: last.y - 7, width: 14, height: 14)),
                             with: .color(.accentColor.opacity(0.12)))
                context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
                             with: .color(.white))
                context.stroke(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
                               with: .color(.accentColor), lineWidth: 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Fan speed over the last two minutes")
        .accessibilityValue(samples.last.map { "\(Int($0.rpm).formatted()) RPM now" } ?? "No samples")
    }
}

private struct FanResponseGraph: View {
    let samples: [FanSample]
    let maxRPM: Int?

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 34, right: CGFloat = 8, top: CGFloat = 8, bottom: CGFloat = 18
            let plot = CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
            let maximum = Double(maxRPM ?? 6000)
            let tempLow = 30.0, tempHigh = 100.0

            for temp in stride(from: 40.0, through: 100.0, by: 20) {
                let x = plot.minX + CGFloat((temp - tempLow) / (tempHigh - tempLow)) * plot.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                context.draw(Text("\(Int(temp))°").font(.system(size: 8)).foregroundStyle(.tertiary),
                             at: CGPoint(x: x, y: plot.maxY + 10), anchor: .center)
            }
            for fraction in [0.0, 0.5, 1.0] {
                let y = plot.maxY - CGFloat(fraction) * plot.height
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                context.draw(Text("\(Int((maximum * fraction) / 1000))k").font(.system(size: 8)).foregroundStyle(.tertiary),
                             at: CGPoint(x: plot.minX - 5, y: y), anchor: .trailing)
            }

            let points = samples.compactMap { sample -> CGPoint? in
                guard let temp = sample.temperature else { return nil }
                let x = plot.minX + CGFloat((min(tempHigh, max(tempLow, temp)) - tempLow) / (tempHigh - tempLow)) * plot.width
                let y = plot.maxY - CGFloat(Swift.min(1, Swift.max(0, sample.rpm / maximum))) * plot.height
                return CGPoint(x: x, y: y)
            }
            guard !points.isEmpty else { return }

            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(.accentColor.opacity(0.5)), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))

            for point in points.dropLast() {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.4, y: point.y - 1.4, width: 2.8, height: 2.8)),
                             with: .color(.accentColor.opacity(0.45)))
            }
            if let last = points.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 8, y: last.y - 8, width: 16, height: 16)),
                             with: .color(.accentColor.opacity(0.14)))
                context.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                             with: .color(.white))
                context.stroke(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                               with: .color(.accentColor), lineWidth: 1.2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Fan speed against CPU temperature")
        .accessibilityValue(samples.last.flatMap { sample in
            sample.temperature.map { "\(Int(sample.rpm).formatted()) RPM at \(Int($0.rounded())) degrees" }
        } ?? "No paired samples")
    }
}

// MARK: - Rotor

private struct FanRotorView: NSViewRepresentable {
    let info: FanInfo
    let reduceMotion: Bool

    func makeNSView(context: Context) -> FanRotorNSView {
        let view = FanRotorNSView()
        view.update(info: info, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: FanRotorNSView, context: Context) {
        view.update(info: info, reduceMotion: reduceMotion)
    }
}

/// Draws the rotor and airflow with Core Graphics. The reading itself updates
/// once a second; this view interpolates between readings at the display rate,
/// so the fan speeds up and settles fluidly instead of jumping.
private final class FanRotorNSView: NSView {
    private var info: FanInfo?
    private var reduceMotion = false
    private var animationLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var time: Double = 0
    private var rpm: Double = 0
    private var targetRPM: Double = 0
    private var rpmVelocity: Double = 0
    private var temperature: Double = 55
    private var targetTemperature: Double = 55
    private var angle: Double = 0
    private var hasReading = false

    private struct Particle {
        var angle: Double
        var radius: Double
        var radialSpeed: Double
        var angularSpeed: Double
        var life: Double
        var maxLife: Double
        var size: Double
        var tint: Int
    }
    private var particles: [Particle] = []
    private var seeded = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawConcurrently = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(info: FanInfo, reduceMotion: Bool) {
        self.info = info
        self.reduceMotion = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = Double(info.rpm)
        if !hasReading {
            rpm = target
            targetRPM = target
            temperature = info.socTemperature ?? temperature
            targetTemperature = temperature
            hasReading = true
            seedParticles()
        } else {
            targetRPM = target
            targetTemperature = info.socTemperature ?? targetTemperature
        }
        if reduceMotion { particles.removeAll(keepingCapacity: false) }
        if window != nil { updateLinkState() }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateLinkState()
    }

    @objc private func occlusionChanged() {
        updateLinkState()
    }

    private func updateLinkState() {
        let onScreen = window != nil
            && (window?.occlusionState.contains(.visible) ?? false)
            && !visibleRect.isEmpty
        if onScreen {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        if let animationLink {
            animationLink.isPaused = false
            return
        }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        lastTimestamp = 0
        animationLink = link
    }

    private func stop() {
        animationLink?.invalidate()
        animationLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard !visibleRect.isEmpty else {
            stop()
            return
        }
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 0 : min(0.05, max(0, now - lastTimestamp))
        lastTimestamp = now
        guard dt > 0 else { needsDisplay = true; return }

        time += dt
        let maxRPM = Double(info?.maxRPM ?? 6000)
        let stiffness = targetRPM > rpm ? 11.0 : 8.5
        rpmVelocity += (targetRPM - rpm) * stiffness * dt
        rpmVelocity *= exp(-6.4 * dt)
        rpm = min(maxRPM, max(0, rpm + rpmVelocity * dt))
        temperature += (targetTemperature - temperature) * (1 - exp(-dt / 2.2))

        let flow = maxRPM > 0 ? rpm / maxRPM : 0
        let motionScale = reduceMotion ? 0.42 : 1
        angle = (angle + (0.18 + 2.15 * pow(flow, 0.92)) * .pi * 2 * dt * motionScale)
            .truncatingRemainder(dividingBy: .pi * 2)

        updateParticles(dt: dt, flow: flow)
        needsDisplay = true
    }

    private func seedParticles() {
        guard !seeded else { return }
        seeded = true
        for _ in 0..<30 { particles.append(makeParticle(initial: true)) }
    }

    private func makeParticle(initial: Bool) -> Particle {
        let flow = max(0.01, min(1, rpm / Double(info?.maxRPM ?? 6000)))
        let speed = 0.35 + flow * 1.55
        let life = 0.9 + Double.random(in: 0...1.5)
        let roll = Int.random(in: 0..<100)
        return Particle(
            angle: Double.random(in: 0..<(.pi * 2)),
            radius: initial ? 0.95 + Double.random(in: 0...0.55) : 0.92 + Double.random(in: 0...0.12),
            radialSpeed: (0.26 + Double.random(in: 0...0.88)) * speed,
            angularSpeed: (0.18 + Double.random(in: 0...0.5)) * (0.5 + flow * 2.1),
            life: life,
            maxLife: life,
            size: 1.15 + Double.random(in: 0...2.15),
            tint: roll < 60 ? 0 : (roll < 88 ? 1 : 2)
        )
    }

    private func updateParticles(dt: Double, flow: Double) {
        guard !reduceMotion else { particles.removeAll(keepingCapacity: false); return }
        let target = Int(30 + pow(max(0, flow), 1.3) * 165)
        var guardCount = 0
        while particles.count < target && guardCount < 12 {
            particles.append(makeParticle(initial: false))
            guardCount += 1
        }
        if particles.count > target { particles.removeFirst(particles.count - target) }

        for index in particles.indices.reversed() {
            particles[index].life -= dt
            particles[index].radius += particles[index].radialSpeed * (0.55 + flow * 1.15) * dt
            particles[index].angle += particles[index].angularSpeed * dt
            if particles[index].life <= 0 || particles[index].radius > 1.72 {
                particles.remove(at: index)
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width, height = bounds.height
        guard width > 10, height > 10 else { return }
        let center = CGPoint(x: width / 2, y: height * 0.495)
        let radius = min(width * 0.265, height * 0.36, 160)
        guard radius > 20 else { return }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.setShouldAntialias(true)

        let flow = min(1, max(0, rpm / Double(info?.maxRPM ?? 6000)))
        let heat = min(1, max(0, (temperature - 36) / 58))
        drawBackdrop(ctx, radius: radius, flow: flow, heat: heat)
        drawIntake(ctx, radius: radius, flow: flow)
        drawHousing(ctx, radius: radius, flow: flow)
        drawExhaust(ctx, radius: radius, flow: flow)
        drawGauge(ctx, radius: radius, flow: flow)
        drawRotor(ctx, radius: radius, flow: flow)
        drawHub(ctx, radius: radius)

        ctx.restoreGState()
    }

    private func drawBackdrop(_ ctx: CGContext, radius: CGFloat, flow: Double, heat: Double) {
        let spotlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.28, green: 0.29, blue: 0.32, alpha: 0.40),
            CGColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 0.12),
            CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 0),
        ] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(spotlight, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: radius * 1.8, options: [])

        let bloom = (0.055 + heat * 0.26) * (1.05 - flow * 0.24)
        let heatGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 1, green: 0.45, blue: 0.21, alpha: bloom),
            CGColor(red: 1, green: 0.28, blue: 0.25, alpha: bloom * 0.38),
            CGColor(red: 1, green: 0.24, blue: 0.24, alpha: 0),
        ] as CFArray, locations: [0, 0.5, 1])!
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.drawRadialGradient(heatGradient, startCenter: .zero, startRadius: radius * 0.2,
                               endCenter: .zero, endRadius: radius * 1.48, options: [])
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.028))
        ctx.setLineWidth(1)
        for factor in [0.56, 0.86, 1.36] as [CGFloat] {
            ctx.addArc(center: .zero, radius: radius * factor, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            if factor == 1.36 { ctx.setLineDash(phase: 0, lengths: [2, 7]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        let period = 2.4 - flow * 1.45
        for index in 0..<2 {
            let u = ((time / period) + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            let ring = radius * (1.04 + u * 0.54)
            let alpha = (1 - u) * (0.05 + flow * 0.09)
            ctx.setStrokeColor(heat > 0.55
                ? CGColor(red: 1, green: 0.57, blue: 0.27, alpha: alpha)
                : CGColor(red: 0.47, green: 0.80, blue: 1, alpha: alpha))
            ctx.setLineWidth(1)
            ctx.addArc(center: .zero, radius: ring, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
        }
    }

    private func drawIntake(_ ctx: CGContext, radius: CGFloat, flow: Double) {
        guard !reduceMotion else { return }
        for index in 0..<20 {
            let seed = Double(index) * 1.71
            let speed = 0.06 + flow * 0.15
            let r = 1.12 + ((seed * 0.13 + time * speed + Double(index) * 0.073)
                .truncatingRemainder(dividingBy: 0.5))
            let a = seed * 2.4 + time * 0.035 * (1 + flow)
            let start = CGPoint(x: cos(a) * r * radius, y: sin(a) * r * radius)
            let end = CGPoint(x: cos(a + 0.03) * (r + 0.075) * radius,
                              y: sin(a + 0.03) * (r + 0.075) * radius)
            ctx.setStrokeColor(CGColor(red: 0.47, green: 0.84, blue: 1, alpha: 0.09 + flow * 0.11))
            ctx.setLineWidth(1.15)
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
        }
    }

    private func drawHousing(_ ctx: CGContext, radius: CGFloat, flow: Double) {
        let ringRadius = radius * 1.075
        let ringWidth = max(9, radius * 0.085)

        ctx.saveGState()
        ctx.addArc(center: .zero, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.setLineWidth(ringWidth + 3)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.strokePath()

        let metal = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.36, green: 0.39, blue: 0.43, alpha: 1),
            CGColor(red: 0.19, green: 0.21, blue: 0.24, alpha: 1),
            CGColor(red: 0.11, green: 0.13, blue: 0.15, alpha: 1),
            CGColor(red: 0.24, green: 0.26, blue: 0.29, alpha: 1),
            CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1),
        ] as CFArray, locations: [0, 0.22, 0.48, 0.72, 1])!
        ctx.saveGState()
        ctx.addArc(center: .zero, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.setLineWidth(ringWidth)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(metal, start: CGPoint(x: -ringRadius, y: -ringRadius),
                               end: CGPoint(x: ringRadius, y: ringRadius), options: [])
        ctx.restoreGState()

        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.11))
        ctx.addArc(center: .zero, radius: ringRadius - ringWidth * 0.5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
        ctx.addArc(center: .zero, radius: ringRadius + ringWidth * 0.5, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        let cavity = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.20),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.62),
        ] as CFArray, locations: [0, 0.82, 1])!
        ctx.saveGState()
        ctx.addArc(center: .zero, radius: radius * 1.04, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.clip()
        ctx.drawRadialGradient(cavity, startCenter: .zero, startRadius: radius * 0.45,
                               endCenter: .zero, endRadius: radius * 1.03, options: [])
        ctx.restoreGState()

        // Cool rim light on the upper left, warm pressure on the lower right.
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(red: 0.59, green: 0.85, blue: 1, alpha: 0.18))
        ctx.setLineWidth(1.5)
        ctx.addArc(center: .zero, radius: ringRadius - ringWidth * 0.48,
                   startAngle: .pi * 1.08, endAngle: .pi * 1.76, clockwise: false)
        ctx.strokePath()
        if temperature > 74 {
            let alpha = min(1, (temperature - 74) / 22) * 0.28
            ctx.setStrokeColor(CGColor(red: 1, green: 0.41, blue: 0.20, alpha: alpha))
            ctx.setLineWidth(2.4)
            ctx.addArc(center: .zero, radius: ringRadius + ringWidth * 0.45,
                       startAngle: .pi * 0.12, endAngle: .pi * 0.88, clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()

        for degrees in [45.0, 135.0, 225.0, 315.0] {
            let a = degrees * .pi / 180
            let point = CGPoint(x: cos(a) * ringRadius, y: sin(a) * ringRadius)
            ctx.fillEllipse(in: CGRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4))
            ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1))
            ctx.fillPath()
        }
    }

    private func drawExhaust(_ ctx: CGContext, radius: CGFloat, flow: Double) {
        guard !reduceMotion, !particles.isEmpty else { return }
        // Three ember colours by three age bands: nine paths per frame instead of
        // two stroke calls per particle, while keeping the orange/pink/violet mix.
        let ageBands = 3
        let bucketCount = 9
        var paths = Array(repeating: CGMutablePath(), count: bucketCount)
        var used = [Bool](repeating: false, count: bucketCount)
        for particle in particles {
            let r = particle.radius * radius
            guard r > radius * 0.52 else { continue }
            let age = 1 - particle.life / particle.maxLife
            let band = min(ageBands - 1, max(0, Int(age * Double(ageBands))))
            let bucket = particle.tint * ageBands + band
            let startRadius = max(radius * 0.4, r - particle.radialSpeed * radius * 0.075)
            let startAngle = particle.angle - particle.angularSpeed * 0.06
            paths[bucket].move(to: CGPoint(x: cos(startAngle) * startRadius, y: sin(startAngle) * startRadius))
            paths[bucket].addLine(to: CGPoint(x: cos(particle.angle) * r, y: sin(particle.angle) * r))
            used[bucket] = true
        }
        guard used.contains(true) else { return }

        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (1.00, 0.56, 0.20),
            (1.00, 0.28, 0.48),
            (0.62, 0.30, 1.00),
        ]
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.setLineCap(.round)
        for bucket in 0..<bucketCount where used[bucket] {
            let tint = bucket / ageBands
            let band = bucket % ageBands
            let color = palette[tint]
            let alpha = (0.92 - Double(band) * 0.24) * (tint == 2 ? 0.9 : 1)
            ctx.setStrokeColor(red: color.0, green: color.1, blue: color.2, alpha: alpha * 0.24)
            ctx.setLineWidth(5.2)
            ctx.addPath(paths[bucket])
            ctx.strokePath()
            ctx.setStrokeColor(red: color.0, green: color.1, blue: color.2, alpha: alpha)
            ctx.setLineWidth(1.7)
            ctx.addPath(paths[bucket])
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawGauge(_ ctx: CGContext, radius: CGFloat, flow: Double) {
        let start = CGFloat.pi * 0.75
        let end = CGFloat.pi * 2.25
        let gaugeRadius = radius * 1.16
        let pct = CGFloat(flow)

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.12)
        ctx.setLineWidth(2.4)
        ctx.addArc(center: .zero, radius: gaugeRadius, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()

        if pct > 0.002 {
            let sweep = (end - start) * pct
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.addArc(center: .zero, radius: gaugeRadius, startAngle: start, endAngle: start + sweep, clockwise: false)
            ctx.setLineWidth(2.9)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let gaugeGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 0.96),
                CGColor(red: 0.39, green: 0.82, blue: 1.0, alpha: 0.96),
                CGColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 0.96),
            ] as CFArray, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(gaugeGradient, start: CGPoint(x: -gaugeRadius, y: 0),
                                   end: CGPoint(x: gaugeRadius, y: 0), options: [])
            ctx.restoreGState()

            let tip = start + sweep
            let point = CGPoint(x: cos(tip) * gaugeRadius, y: sin(tip) * gaugeRadius)
            let color = arcColor(pct)
            ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 0.20)
            ctx.fillEllipse(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
            ctx.setFillColor(red: 0.95, green: 0.99, blue: 1, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: point.x - 3.2, y: point.y - 3.2, width: 6.4, height: 6.4))
        }

        // Ticks: four paths instead of one stroke per tick.
        let litMajor = CGMutablePath(), litMinor = CGMutablePath()
        let dimMajor = CGMutablePath(), dimMinor = CGMutablePath()
        let ticks = 49
        for index in 0..<ticks {
            let fraction = CGFloat(index) / CGFloat(ticks - 1)
            let angle = start + (end - start) * fraction
            let major = index % 6 == 0
            let inner = gaugeRadius + 6
            let outer = gaugeRadius + (major ? 11 : 7.5)
            let path = fraction <= pct ? (major ? litMajor : litMinor) : (major ? dimMajor : dimMinor)
            path.move(to: CGPoint(x: cos(angle) * inner, y: sin(angle) * inner))
            path.addLine(to: CGPoint(x: cos(angle) * outer, y: sin(angle) * outer))
        }
        ctx.setLineCap(.butt)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(red: 0.45, green: 0.82, blue: 1, alpha: 0.72)
        ctx.addPath(litMajor); ctx.strokePath()
        ctx.setLineWidth(1.0)
        ctx.setStrokeColor(red: 0.45, green: 0.82, blue: 1, alpha: 0.55)
        ctx.addPath(litMinor); ctx.strokePath()
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.16)
        ctx.addPath(dimMajor); ctx.strokePath()
        ctx.setLineWidth(1.0)
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.16)
        ctx.addPath(dimMinor); ctx.strokePath()

        drawSmallLabel("0", at: CGPoint(x: cos(start + 0.12) * (gaugeRadius + 19),
                                        y: sin(start + 0.12) * (gaugeRadius + 19)))
        drawSmallLabel("MAX", at: CGPoint(x: cos(end - 0.12) * (gaugeRadius + 19),
                                          y: sin(end - 0.12) * (gaugeRadius + 19)))
        ctx.restoreGState()
    }

    private func arcColor(_ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let blue: (CGFloat, CGFloat, CGFloat) = (0.04, 0.52, 1.0)
        let cyan: (CGFloat, CGFloat, CGFloat) = (0.39, 0.82, 1.0)
        let purple: (CGFloat, CGFloat, CGFloat) = (0.75, 0.35, 0.95)
        if t < 0.55 {
            let f = t / 0.55
            return (blue.0 + (cyan.0 - blue.0) * f, blue.1 + (cyan.1 - blue.1) * f, blue.2 + (cyan.2 - blue.2) * f)
        }
        let f = (t - 0.55) / 0.45
        return (cyan.0 + (purple.0 - cyan.0) * f, cyan.1 + (purple.1 - cyan.1) * f, cyan.2 + (purple.2 - cyan.2) * f)
    }

    private func drawSmallLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.30),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    private func drawRotor(_ ctx: CGContext, radius: CGFloat, flow: Double) {
        let hub = radius * 0.355
        let speed = CGFloat(flow)
        let ghosts = reduceMotion ? 0 : min(9, 3 + Int(speed * 8))
        let bases = (0..<9).map { CGFloat(angle) + CGFloat($0) * .pi * 2 / 9 }

        let bladeGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.31, green: 0.35, blue: 0.40, alpha: 1),
            CGColor(red: 0.17, green: 0.20, blue: 0.24, alpha: 1),
            CGColor(red: 0.09, green: 0.11, blue: 0.13, alpha: 1),
            CGColor(red: 0.23, green: 0.26, blue: 0.30, alpha: 1),
            CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1),
        ] as CFArray, locations: [0, 0.3, 0.62, 0.85, 1])!

        for ghost in stride(from: ghosts, through: 1, by: -1) {
            let offset = CGFloat(ghost) * (0.012 + speed * 0.075)
            let ghostPath = CGMutablePath()
            for base in bases { ghostPath.addPath(bladePath(base: base - offset, radius: radius, hub: hub)) }
            ctx.saveGState()
            ctx.setAlpha(0.05 + speed * 0.06)
            ctx.addPath(ghostPath)
            ctx.setFillColor(red: 0.42, green: 0.46, blue: 0.52, alpha: 1)
            ctx.fillPath()
            ctx.restoreGState()
        }

        let bladeShape = CGMutablePath()
        let grooves = CGMutablePath()
        let leadingEdges = CGMutablePath()
        let g0r = hub + (radius - hub) * 0.24
        let g1r = hub + (radius - hub) * 0.83
        for base in bases {
            bladeShape.addPath(bladePath(base: base, radius: radius, hub: hub))
            grooves.move(to: point(radius: g0r, angle: base + 0.045))
            grooves.addQuadCurve(to: point(radius: g1r, angle: base + 0.285),
                                 control: point(radius: g1r * 0.93, angle: base + 0.23))
            leadingEdges.addPath(leadingEdgePath(base: base, radius: radius, hub: hub))
        }

        ctx.saveGState()
        ctx.addPath(bladeShape)
        ctx.clip()
        ctx.drawLinearGradient(bladeGradient, start: CGPoint(x: -radius, y: -radius),
                               end: CGPoint(x: radius, y: radius), options: [])
        ctx.restoreGState()

        ctx.addPath(bladeShape)
        ctx.setStrokeColor(red: 0.03, green: 0.04, blue: 0.05, alpha: 0.62)
        ctx.setLineWidth(0.9)
        ctx.strokePath()

        ctx.addPath(grooves)
        ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 0.19)
        ctx.setLineWidth(1.1)
        ctx.strokePath()

        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.setStrokeColor(red: 0.75, green: 0.90, blue: 1, alpha: 0.15 + Double(speed) * 0.13)
        ctx.setLineWidth(1.25)
        ctx.addPath(leadingEdges)
        ctx.strokePath()
        ctx.setFillColor(red: 0.82, green: 0.94, blue: 1, alpha: 0.12 + Double(speed) * 0.16)
        for base in bases {
            let tip = point(radius: radius * 0.955, angle: base + 0.31)
            ctx.fillEllipse(in: CGRect(x: tip.x - 2, y: tip.y - 2, width: 4, height: 4))
        }
        ctx.restoreGState()

        // Fixed studio sheen across the rotor.
        ctx.saveGState()
        ctx.addArc(center: .zero, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.clip()
        let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.78, green: 0.89, blue: 1, alpha: 0.09),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.012),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.20),
        ] as CFArray, locations: [0, 0.38, 0.65, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: -radius, y: -radius),
                               end: CGPoint(x: radius * 0.45, y: radius * 0.55), options: [])
        ctx.restoreGState()
    }

    private func leadingEdgePath(base: CGFloat, radius: CGFloat, hub: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let p0 = point(radius: hub, angle: base - 0.10)
        let c1 = point(radius: hub + (radius - hub) * 0.45, angle: base - 0.02)
        let c2 = point(radius: hub + (radius - hub) * 0.88, angle: base + 0.10)
        let p1 = point(radius: radius * 0.98, angle: base + 0.18)
        path.move(to: p0)
        path.addCurve(to: p1, control1: c1, control2: c2)
        return path
    }

    private func drawHub(_ ctx: CGContext, radius: CGFloat) {
        let hub = radius * 0.355
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.32, green: 0.36, blue: 0.40, alpha: 1),
            CGColor(red: 0.17, green: 0.20, blue: 0.23, alpha: 1),
            CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1),
        ] as CFArray, locations: [0, 0.45, 1])!
        ctx.addEllipse(in: CGRect(x: -hub, y: -hub, width: hub * 2, height: hub * 2))
        ctx.clip()
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: -hub * 0.35, y: -hub * 0.45), startRadius: hub * 0.08,
                               endCenter: .zero, endRadius: hub * 1.12, options: [])
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(1)
        ctx.addArc(center: .zero, radius: hub, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.addArc(center: .zero, radius: hub * 0.82, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Temperature ring around the hub.
        let fraction = min(1, max(0, (temperature - 30) / 70))
        let ringRadius = hub * 0.92
        let start = -CGFloat.pi / 2
        let sweep = CGFloat(fraction) * (.pi * 2 - 0.35)
        guard sweep > 0.01 else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.addArc(center: .zero, radius: ringRadius, startAngle: start, endAngle: start + sweep, clockwise: false)
        ctx.setLineWidth(2.6)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let ring = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.39, green: 0.82, blue: 1, alpha: 0.95),
            CGColor(red: 0.86, green: 0.95, blue: 1, alpha: 0.95),
            CGColor(red: 1, green: 0.60, blue: 0.56, alpha: 0.95),
        ] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(ring, start: CGPoint(x: -ringRadius, y: -ringRadius),
                               end: CGPoint(x: ringRadius, y: ringRadius), options: [])
        ctx.restoreGState()
    }

    private func bladePath(base: CGFloat, radius: CGFloat, hub: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let p0 = point(radius: hub, angle: base - 0.10)
        let c1 = point(radius: hub + (radius - hub) * 0.45, angle: base - 0.02)
        let c2 = point(radius: hub + (radius - hub) * 0.88, angle: base + 0.10)
        let p1 = point(radius: radius * 0.98, angle: base + 0.18)
        let q = point(radius: radius * 1.025, angle: base + 0.31)
        let p2 = point(radius: radius * 0.97, angle: base + 0.43)
        let c3 = point(radius: hub + (radius - hub) * 0.82, angle: base + 0.45)
        let c4 = point(radius: hub + (radius - hub) * 0.30, angle: base + 0.34)
        let p3 = point(radius: hub, angle: base + 0.14)
        path.move(to: p0)
        path.addCurve(to: p1, control1: c1, control2: c2)
        path.addQuadCurve(to: p2, control: q)
        path.addCurve(to: p3, control1: c3, control2: c4)
        path.closeSubpath()
        return path
    }

    private func leadingEdge(_ ctx: CGContext, base: CGFloat, radius: CGFloat, hub: CGFloat) {
        let p0 = point(radius: hub, angle: base - 0.10)
        let c1 = point(radius: hub + (radius - hub) * 0.45, angle: base - 0.02)
        let c2 = point(radius: hub + (radius - hub) * 0.88, angle: base + 0.10)
        let p1 = point(radius: radius * 0.98, angle: base + 0.18)
        ctx.move(to: p0)
        ctx.addCurve(to: p1, control1: c1, control2: c2)
    }

    private func point(radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }
}
