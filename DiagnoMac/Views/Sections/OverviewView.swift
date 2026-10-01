import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private var ai: Intelligence { model.intelligence }

    var body: some View {
        Page("Health Overview", subtitle: "Every check, worst first. Each finding links to the details and a fix.") {
            Button {
                Task { await model.scan() }
            } label: {
                Label(model.isScanning ? "Scanning…" : "Run Full Scan", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isScanning)
        } content: {
            HStack(alignment: .top, spacing: 14) {
                scoreCard.frame(minWidth: 440)
                machineCard.frame(width: 290)
            }

            Columns(minimum: 156) { tiles }

            findingsSection
        }
    }

    // MARK: Score

    private var scoreCard: some View {
        Card {
            HStack(spacing: 24) {
                ScoreRing(score: model.score)
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline).font(.title2.weight(.semibold))
                    Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach([Severity.critical, .warning, .info], id: \.self) { sev in
                            let n = model.findings.filter { $0.severity == sev }.count
                            if n > 0 { SeverityPill(severity: sev, text: "\(n) \(sev.groupTitle.lowercased())") }
                        }
                    }
                    if model.isScanning {
                        ProgressView(value: model.scanProgress) { Text(model.scanStatus).font(.caption) }
                            .controlSize(.small)
                    }
                }
            }
            if ai.isAvailable, let text = ai.text(for: "summary") {
                AIBlock(title: "Summary · written on this Mac by Apple Intelligence", text: text,
                        onRetry: { regenerateSummary() })
                    .overlay(alignment: .topTrailing) {
                        if !text.isStreaming && text.error == nil {
                            Button { regenerateSummary() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).padding(10)
                                .help("Write the summary again")
                        }
                    }
                    .padding(.top, 4)
            }
        }
    }

    private func regenerateSummary() {
        ai.generate(key: "summary", instructions: AIPrompts.summaryInstructions,
                    prompt: AIPrompts.summary(snapshot: model.snapshot, findings: model.findings), force: true)
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

    // MARK: Tiles

    @ViewBuilder
    private var tiles: some View {
        if let b = model.snapshot.battery {
            tile(.battery) {
                StatTile(title: "Battery", value: "\(b.chargePercent)", unit: "%",
                         caption: b.isCharging ? "Charging" + (b.telemetry.map { String(format: " · %.0f W", max(0, $0.battery)) } ?? "")
                             : "\(b.healthPercent.map { "\($0)% health" } ?? "") · \(b.cycleCount) cycles",
                         severity: b.isCharging ? .ok : nil)
            }
        }
        if let st = model.snapshot.storage {
            tile(.storage) {
                StatTile(title: "Storage", value: String(format: "%.0f", Double(st.availableBytes) / 1e9), unit: "GB free",
                         caption: "of \(Format.gb(st.totalBytes, digits: 0)) · SMART \(st.smartStatus ?? "unknown")")
            }
        }
        if let m = model.snapshot.memory {
            tile(.memory) {
                StatTile(title: "Memory", value: "\(m.availablePercent)", unit: "% free",
                         caption: "Swap \(Format.percent(m.swapFraction)) full",
                         severity: m.swapFraction > 0.6 || m.pressure != .normal ? .warning : nil)
            }
        }
        tile(.performance) {
            StatTile(title: "CPU", value: String(format: "%.0f", (model.cpuNow?.total ?? 0) * 100), unit: "%",
                     caption: model.snapshot.performance?.loadAverage.first.map { String(format: "Load %.2f", $0) } ?? "")
        }
        if let g = model.snapshot.gpu {
            tile(.performance) {
                StatTile(title: "GPU", value: "\(g.deviceUtilization)", unit: "%",
                         caption: "\(model.snapshot.machine?.gpuCores.map { "\($0) cores · " } ?? "")\(Format.memory(g.inUseMemory)) in use")
            }
        }
    }

    private func tile<Content: View>(_ area: Area, @ViewBuilder content: () -> Content) -> some View {
        Button { model.selection = area } label: { content() }
            .buttonStyle(.plain)
            .help("Open \(area.title)")
    }

    // MARK: Findings

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Findings").font(.title2.weight(.bold))
                Spacer()
                Text(model.findings.isEmpty ? "" : "\(model.findings.count) open").foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            if model.findings.isEmpty {
                Card {
                    Label(model.isScanning ? "Looking for problems…" : "Nothing to fix. This Mac looks healthy.",
                          systemImage: model.isScanning ? "hourglass" : "checkmark.seal.fill")
                        .foregroundStyle(model.isScanning ? Color.secondary : Color.green)
                }
            }

            ForEach([Severity.critical, .warning, .info], id: \.self) { severity in
                let group = model.findings.filter { $0.severity == severity }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            SeverityDot(severity: severity)
                            Text(severity.groupTitle).font(.headline)
                            Text("\(group.count)").foregroundStyle(.secondary)
                        }
                        ForEach(group) { finding in
                            FindingCard(finding: finding,
                                        explanation: ai.text(for: "finding.\(finding.id)"),
                                        canExplain: ai.isAvailable,
                                        perform: { model.perform($0) },
                                        explain: { model.explain($0) },
                                        dismissExplanation: { ai.dismiss(key: "finding.\(finding.id)") })
                        }
                    }
                }
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
        let important = model.findings.filter { $0.severity >= .warning }
        if important.isEmpty { return "No critical or warning-level issues found." }
        let names = important.prefix(3).map { $0.title.prefix(1).lowercased() + $0.title.dropFirst() }
        return "Most important: " + ListFormatter.localizedString(byJoining: names) + "."
    }
}
