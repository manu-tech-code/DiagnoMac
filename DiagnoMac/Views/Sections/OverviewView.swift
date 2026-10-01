import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Health Overview", subtitle: "A summary of every check, worst first. Each finding links to the details and a fix.") {
            Button {
                Task { await model.scan() }
            } label: {
                Label(model.isScanning ? "Scanning…" : "Run Full Scan", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isScanning)
        } content: {
            HStack(alignment: .top, spacing: 14) {
                Card {
                    HStack(spacing: 24) {
                        ScoreRing(score: model.score)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(headline).font(.title2.weight(.semibold))
                            Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                ForEach([Severity.critical, .warning, .info], id: \.self) { sev in
                                    let n = model.findings.filter { $0.severity == sev }.count
                                    if n > 0 { SeverityPill(severity: sev, text: "\(n) \(sev.label.lowercased())\(n == 1 || sev == .critical ? "" : "s")") }
                                }
                            }
                            if model.isScanning {
                                ProgressView(value: model.scanProgress) { Text(model.scanStatus).font(.caption) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(minWidth: 420)

                machineCard.frame(width: 300)
            }

            Card("Findings", trailing: model.findings.isEmpty ? nil : "\(model.findings.count) open") {
                if model.findings.isEmpty {
                    Text(model.isScanning ? "Looking for problems…" : "Nothing to fix. This Mac looks healthy.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.findings.enumerated()), id: \.element.id) { index, finding in
                            if index > 0 { Divider() }
                            FindingRow(finding: finding) { model.perform($0) }
                        }
                    }
                }
            }

            Columns(minimum: 220) {
                if let b = model.snapshot.battery {
                    StatTile(title: "Battery", value: b.healthPercent.map(String.init) ?? "—", unit: "% capacity",
                             caption: "\(b.cycleCount) cycles · \(b.condition ?? "Unknown")")
                }
                if let st = model.snapshot.storage {
                    StatTile(title: "Storage", value: String(format: "%.0f", Double(st.availableBytes) / 1e9), unit: "GB free",
                             caption: "of \(Format.gb(st.totalBytes, digits: 0)) · SMART \(st.smartStatus ?? "unknown")")
                }
                if let m = model.liveMemory ?? model.snapshot.memory {
                    StatTile(title: "Memory", value: "\(m.availablePercent)", unit: "% available",
                             caption: "Swap \(Format.memory(m.swapUsed)) of \(Format.memory(m.swapTotal))")
                }
                StatTile(title: "CPU", value: String(format: "%.0f", (model.cpuNow?.total ?? 0) * 100), unit: "% now",
                         caption: model.snapshot.performance.map { "Load " + $0.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / ") } ?? "")
            }
        }
    }

    private var machineCard: some View {
        Card("This Mac") {
            if let m = model.snapshot.machine {
                VStack(spacing: 7) {
                    KeyValueRow(key: "Model", value: m.modelName)
                    KeyValueRow(key: "Chip", value: m.chip)
                    KeyValueRow(key: "Memory", value: Format.bytes(m.memoryBytes, style: .memory))
                    KeyValueRow(key: "Storage", value: model.snapshot.storage.map { Format.gb($0.totalBytes, digits: 0) } ?? "—")
                    KeyValueRow(key: "macOS", value: m.osVersion)
                    KeyValueRow(key: "Uptime", value: Format.duration(m.uptime))
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var headline: String {
        if model.lastScan == nil && model.isScanning { return "Scanning this Mac…" }
        switch model.score {
        case 95...: return "This Mac is in great shape"
        case 80..<95: return "Healthy, with a few things to tidy up"
        case 60..<80: return "A few problems need attention"
        default: return "Several problems need fixing"
        }
    }

    private var summary: String {
        let critical = model.findings.filter { $0.severity == .critical }
        let warnings = model.findings.filter { $0.severity == .warning }
        if critical.isEmpty && warnings.isEmpty { return "No critical or warning-level issues found." }
        let names = (critical + warnings).prefix(3).map { $0.title.lowercased() }
        return "Most important: " + ListFormatter.localizedString(byJoining: names) + "."
    }
}
