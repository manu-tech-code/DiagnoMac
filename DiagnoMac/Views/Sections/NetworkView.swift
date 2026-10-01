import Charts
import DiagnoCore
import SwiftUI

struct NetworkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Network", subtitle: "Connection quality, latency, DNS and throughput.") {
            HStack {
                Button("Recheck") { Task { await model.refresh(.network) } }
                if model.speedTest.isRunning {
                    Button("Cancel Test") { model.cancelSpeedTest() }
                } else {
                    Button { model.runSpeedTest() } label: {
                        Label(model.speedTest.result == nil ? "Run Speed Test" : "Run Again", systemImage: "speedometer")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } content: {
            SpeedTestCard(state: model.speedTest)

            if let n = model.snapshot.network {
                Columns(minimum: 190) {
                    StatTile(title: "Interface", value: n.interfaceKind, caption: n.interfaceName.map { "\($0) · \(n.isConnected ? "connected" : "offline")" })
                    StatTile(title: "Latency", value: n.ping.map { String(format: "%.1f", $0.avgMs) } ?? "—", unit: "ms",
                             caption: n.ping.map { String(format: "To %@ · jitter %.2f ms", $0.host, $0.jitterMs) })
                    if let w = n.wifi {
                        StatTile(title: "Signal", value: "\(w.snr)", unit: "dB SNR", caption: "\(w.rssi) dBm",
                                 severity: w.snr >= 25 ? .ok : w.snr >= 15 ? .warning : .critical)
                        StatTile(title: "Channel", value: w.channel?.components(separatedBy: " ").first ?? "—",
                                 caption: [w.channel.flatMap { $0.split(separator: "(").last.map { String($0.dropLast()) } }, w.phyMode].compactMap { $0 }.joined(separator: " · "))
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    if let w = n.wifi {
                        Card("Wi-Fi signal") {
                            VStack(spacing: 7) {
                                KeyValueRow(key: "Signal (RSSI)", value: "\(w.rssi) dBm")
                                KeyValueRow(key: "Noise", value: "\(w.noise) dBm")
                                KeyValueRow(key: "Signal-to-noise", value: "\(w.snr) dB")
                                if let c = w.channel { KeyValueRow(key: "Channel", value: c) }
                                if let p = w.phyMode { KeyValueRow(key: "Standard", value: p) }
                                KeyValueRow(key: "Transmit rate", value: String(format: "%.0f Mbps", w.txRateMbps))
                            }
                            Gauge(value: min(1, max(0, Double(w.snr) / 45))) {
                                EmptyView()
                            } currentValueLabel: {
                                Text(w.snr >= 25 ? "Good" : w.snr >= 15 ? "Fair" : "Poor")
                            }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(w.snr >= 25 ? .green : w.snr >= 15 ? .orange : .red)
                            Text("Above 25 dB is good. Below 15 dB expect drops and slow speeds.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Card("Checks") {
                        VStack(spacing: 0) {
                            ForEach(Array(n.checks.enumerated()), id: \.element.id) { index, check in
                                if index > 0 { Divider() }
                                HStack {
                                    Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(check.passed ? .green : (check.id == "ipv6" ? .secondary : Color.red))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(check.title).fontWeight(.medium)
                                        Text(check.detail).font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            } else {
                LoadingCard(text: "Testing the connection…")
            }
        }
    }
}

// MARK: - Speed test

private struct SpeedTestCard: View {
    let state: SpeedTestState

    var body: some View {
        Card {
            HStack {
                Text("SPEED TEST").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                statusBadge
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(phaseTitle).foregroundStyle(.secondary)
                    bigNumber
                    steps
                    progress
                }
                .frame(minWidth: 260, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    liveChart
                    Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state.phase {
        case .starting, .download, .upload, .finishing:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                LiveBadge(text: "Testing · \(remainingSeconds) s left", color: .accentColor)
            }
        case .done:
            SeverityPill(severity: .ok, text: "Finished \(state.finishedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")")
        case .failed:
            SeverityPill(severity: .warning, text: "Didn't finish")
        case .idle:
            EmptyView()
        }
    }

    private var remainingSeconds: Int {
        guard let start = state.startedAt else { return Int(SpeedTestState.expectedDuration) }
        return max(1, Int((SpeedTestState.expectedDuration - Date().timeIntervalSince(start)).rounded(.up)))
    }

    private var phaseTitle: String {
        switch state.phase {
        case .idle: state.result == nil ? "Not run yet" : "Last result"
        case .starting: "Connecting to Apple's test servers…"
        case .download: "Measuring download…"
        case .upload: "Measuring upload…"
        case .finishing: "Measuring responsiveness…"
        case .done: "Result"
        case .failed(let message): message
        }
    }

    private var bigNumber: some View {
        let value: Double?
        let unit: String
        switch state.phase {
        case .download: value = state.downloadMbps; unit = "Mbps down"
        case .upload: value = state.uploadMbps; unit = "Mbps up"
        case .starting: value = nil; unit = "Mbps"
        default: value = state.result?.downloadMbps; unit = "Mbps down"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value.map { String(format: $0 >= 100 ? "%.0f" : "%.1f", $0) } ?? "—")
                .font(.system(size: 48, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: value)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        let done = state.phase == .done
        return HStack(spacing: 8) {
            step(1, "Download", active: state.phase == .download || state.phase == .starting,
                 complete: done || state.phase == .upload || state.phase == .finishing,
                 value: done ? state.result.map { String(format: "%.0f", $0.downloadMbps) } : nil)
            step(2, "Upload", active: state.phase == .upload, complete: done || state.phase == .finishing,
                 value: done ? state.result.map { String(format: "%.0f", $0.uploadMbps) } : nil)
            step(3, "Responsiveness", active: state.phase == .finishing, complete: done,
                 value: done ? state.result?.responsivenessRPM.map { "\($0) RPM" } : nil)
        }
    }

    private func step(_ number: Int, _ title: String, active: Bool, complete: Bool, value: String?) -> some View {
        HStack(spacing: 5) {
            if complete { Image(systemName: "checkmark") } else { Text("\(number)") }
            Text(title)
            if let value { Text(value).monospacedDigit().fontWeight(.semibold) }
        }
        .font(.caption)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundStyle(complete ? Color.green : active ? Color.accentColor : Color.secondary)
        .background((active ? Color.accentColor : Color.clear).opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(complete ? Color.green.opacity(0.4) : active ? Color.accentColor : Color.secondary.opacity(0.3)))
    }

    @ViewBuilder
    private var progress: some View {
        if state.isRunning, let start = state.startedAt {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                ProgressView(value: min(0.97, context.date.timeIntervalSince(start) / SpeedTestState.expectedDuration))
            }
        } else if state.phase == .done {
            ProgressView(value: 1).tint(.green)
        }
    }

    private var liveChart: some View {
        let down = state.downloadSeries.enumerated().map { ThroughputPoint(index: $0.offset, sample: $0.element, series: "Download") }
        let up = state.uploadSeries.enumerated().map { ThroughputPoint(index: $0.offset, sample: $0.element, series: "Upload") }
        return Chart {
            ForEach(down + up) { point in
                LineMark(x: .value("Seconds", point.sample.seconds), y: .value("Mbps", point.sample.mbps), series: .value("Phase", point.series))
                    .foregroundStyle(by: .value("Phase", point.series))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(["Download": Color.accentColor, "Upload": Color.green])
        .chartXScale(domain: 0...max(SpeedTestState.expectedDuration, (state.uploadSeries.last ?? state.downloadSeries.last)?.seconds ?? 0))
        .chartXAxis {
            AxisMarks(values: .stride(by: 5)) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)s") }
            }
        }
        .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text("\(value.as(Int.self) ?? 0)") } } }
        .frame(height: 140)
        .overlay {
            if state.downloadSeries.isEmpty && state.uploadSeries.isEmpty {
                Text(state.isRunning ? "Waiting for the first reading…" : "Live throughput appears here during a test.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var footnote: String {
        if state.isRunning {
            return "Live readings from Apple's networkQuality tool. Download runs first, then upload; each continues until the speed settles."
        }
        if let r = state.result {
            var text = rating(r.downloadMbps)
            if let rpm = r.responsivenessRPM {
                text += rpm >= 1000 ? " Responsiveness is high, so calls stay smooth while downloading."
                    : rpm >= 300 ? " Responsiveness is medium: calls may stutter during big downloads."
                    : " Responsiveness is low: expect lag in calls and games while the connection is busy."
            }
            if let latency = r.idleLatencyMs { text += String(format: " Idle latency %.0f ms.", latency) }
            return text
        }
        return "Measures download, upload and responsiveness against Apple's servers. Takes about \(Int(SpeedTestState.expectedDuration)) seconds and uses some data."
    }

    private func rating(_ mbps: Double) -> String {
        switch mbps {
        case 100...: "Fast: enough for 4K streaming and large downloads."
        case 25..<100: "Good for HD video calls and streaming."
        case 10..<25: "OK for browsing and calls; large downloads will be slow."
        default: "Slow. Video calls and streaming may struggle."
        }
    }
}

private struct ThroughputPoint: Identifiable {
    let index: Int
    let sample: SpeedSample
    let series: String
    var id: String { "\(series)-\(index)" }
}
