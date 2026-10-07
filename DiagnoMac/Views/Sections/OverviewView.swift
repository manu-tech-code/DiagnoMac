import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private var ai: Intelligence { model.intelligence }

    var body: some View {
        Page("Health Overview", subtitle: "Every check, worst first. Each finding links to the details and a fix.") {
            CardRow {
                scoreCard.frame(minWidth: 440)
                machineCard.frame(width: 290)
            }

            Columns(minimum: 156) {
                OverviewTile(area: .battery) { BatteryTileContent() }
                OverviewTile(area: .storage) { StorageTileContent() }
                OverviewTile(area: .memory) { MemoryTileContent() }
                OverviewTile(area: .performance) { CPUTileContent() }
                OverviewTile(area: .performance) { GPUTileContent() }
            }

            findingsSection
        }
        .onAppear { model.ensureSummary() }
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
                            .animation(.smooth, value: model.scanProgress)
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

    private func regenerateSummary() { model.regenerateSummary() }

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
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.45), value: model.findings)
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

// MARK: - Tiles

/// Each tile reads only its own reading, so a once-a-second CPU sample redraws one tile, not the page.
private struct OverviewTile<Content: View>: View {
    @Environment(AppModel.self) private var model
    let area: Area
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button { model.selection = area } label: { content() }
            .buttonStyle(.plain)
            .help("Open \(area.title)")
    }
}

private struct BatteryTileContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let b = model.snapshot.battery {
            StatTile(title: "Battery", value: "\(b.chargePercent)", unit: "%",
                     caption: b.isCharging ? "Charging" + (b.telemetry.map { String(format: " · %.0f W", max(0, $0.battery)) } ?? "")
                         : "\(b.healthPercent.map { "\($0)% health" } ?? "") · \(b.cycleCount) cycles",
                     severity: b.isCharging ? .ok : nil)
        } else {
            StatTile(title: "Battery", value: model.snapshot.hasBattery ? "…" : "None", caption: model.snapshot.hasBattery ? "Reading" : "This Mac has no battery")
        }
    }
}

private struct StorageTileContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let st = model.snapshot.storage {
            StatTile(title: "Storage", value: String(format: "%.0f", Double(st.availableBytes) / 1e9), unit: "GB free",
                     caption: "of \(Format.gb(st.totalBytes, digits: 0)) · SMART \(st.smartStatus ?? "unknown")")
        } else {
            StatTile(title: "Storage", value: "…", caption: "Measuring")
        }
    }
}

private struct MemoryTileContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let m = model.snapshot.memory {
            StatTile(title: "Memory", value: "\(m.availablePercent)", unit: "% free",
                     caption: "Swap \(Format.percent(m.swapFraction)) full",
                     severity: m.swapFraction > 0.6 || m.pressure != .normal ? .warning : nil)
        } else {
            StatTile(title: "Memory", value: "…", caption: "Reading")
        }
    }
}

private struct CPUTileContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        StatTile(title: "CPU", value: String(format: "%.0f", (model.cpuNow?.total ?? 0) * 100), unit: "%",
                 caption: model.snapshot.performance?.loadAverage.first.map { String(format: "Load %.2f", $0) } ?? "")
    }
}

private struct GPUTileContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let g = model.snapshot.gpu {
            StatTile(title: "GPU", value: "\(g.deviceUtilization)", unit: "%",
                     caption: "\(model.snapshot.machine?.gpuCores.map { "\($0) cores · " } ?? "")\(Format.memory(g.inUseMemory)) in use")
        } else {
            StatTile(title: "GPU", value: "…", caption: "Reading")
        }
    }
}
