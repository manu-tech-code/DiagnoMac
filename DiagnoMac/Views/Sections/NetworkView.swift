import SwiftUI

struct NetworkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Network", subtitle: "Connection quality, latency, DNS and throughput.") {
            HStack {
                Button("Recheck") { Task { await model.refresh(.network) } }
                Button {
                    Task { await model.runSpeedTest() }
                } label: {
                    Label(model.isRunningSpeedTest ? "Testing…" : "Run Speed Test", systemImage: "speedometer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunningSpeedTest)
            }
        } content: {
            if let n = model.snapshot.network {
                Columns(minimum: 200) {
                    StatTile(title: "Interface", value: n.interfaceKind, caption: n.interfaceName.map { "\($0) · \(n.isConnected ? "connected" : "offline")" })
                    StatTile(title: "Latency", value: n.ping.map { String(format: "%.1f", $0.avgMs) } ?? "—", unit: "ms",
                             caption: n.ping.map { String(format: "To %@ · jitter %.2f ms", $0.host, $0.jitterMs) })
                    StatTile(title: "Download", value: model.speedTest.map { String(format: "%.0f", $0.downloadMbps) } ?? "—", unit: "Mbps",
                             caption: model.speedTest == nil ? "Run a speed test" : "Apple networkQuality")
                    StatTile(title: "Upload", value: model.speedTest.map { String(format: "%.0f", $0.uploadMbps) } ?? "—", unit: "Mbps",
                             caption: model.speedTest?.responsivenessRPM.map { "Responsiveness \($0) RPM" } ?? "Run a speed test")
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
                            SignalGauge(snr: w.snr)
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

private struct SignalGauge: View {
    let snr: Int
    var body: some View {
        let quality = min(1, max(0, Double(snr) / 45))
        Gauge(value: quality) {
            EmptyView()
        } currentValueLabel: {
            Text(snr >= 25 ? "Good" : snr >= 15 ? "Fair" : "Poor")
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(snr >= 25 ? .green : snr >= 15 ? .orange : .red)
    }
}
