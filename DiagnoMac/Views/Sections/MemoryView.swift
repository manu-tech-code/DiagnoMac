import SwiftUI

struct MemoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Memory", subtitle: "How RAM is being used, and whether macOS has to fall back to swap.") {
            Button("Refresh") { Task { await model.refresh(.memory) } }
        } content: {
            if let m = model.liveMemory ?? model.snapshot.memory {
                Columns(minimum: 200) {
                    StatTile(title: "Memory pressure", value: m.pressure.label,
                             caption: "\(m.availablePercent)% available",
                             severity: m.pressure == .normal ? .ok : (m.pressure == .warning ? .warning : .critical))
                    StatTile(title: "Swap used", value: Format.memory(m.swapUsed), caption: "of \(Format.memory(m.swapTotal))",
                             severity: m.swapFraction > 0.6 ? .warning : nil)
                    StatTile(title: "Page-outs", value: m.pageouts.formatted(), caption: "Since startup")
                    StatTile(title: "Installed", value: Format.bytes(m.total, style: .memory), caption: "Unified memory")
                }

                Card("Breakdown", trailing: "Updates every 5 seconds") {
                    SegmentBar(segments: [
                        .init(label: "Wired", value: Double(m.wired), color: .red.opacity(0.8), detail: Format.memory(m.wired)),
                        .init(label: "App memory", value: Double(m.active), color: .accentColor, detail: Format.memory(m.active)),
                        .init(label: "Compressed", value: Double(m.compressed), color: .orange, detail: Format.memory(m.compressed)),
                        .init(label: "Cached files", value: Double(m.inactive), color: .accentColor.opacity(0.4), detail: Format.memory(m.inactive)),
                        .init(label: "Other", value: Double(m.other), color: .gray.opacity(0.5), detail: Format.memory(m.other)),
                        .init(label: "Free", value: Double(m.free), color: .green, detail: Format.memory(m.free)),
                    ], height: 20)
                    Text(advice(m)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if let p = model.snapshot.performance {
                    Card("Largest memory users") {
                        Table(p.topByMemory) {
                            TableColumn("Process") { proc in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(proc.name).lineLimit(1)
                                    if let app = PerformanceCollector.owningApp(for: proc.path), app != proc.name {
                                        Text(app).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            TableColumn("Memory") { Text(Format.bytes($0.residentBytes, style: .memory)).monospacedDigit() }.width(100)
                            TableColumn("Share") { Text(String(format: "%.1f%%", $0.memPercent)).monospacedDigit() }.width(70)
                        }
                        .frame(height: 330)
                        Text("Resident memory as reported by ps. Activity Monitor's numbers include compressed memory, so they can be higher.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                LoadingCard()
            }
        }
    }

    private func advice(_ m: MemoryInfo) -> String {
        if m.swapFraction > 0.6 {
            return "Swap is \(Format.percent(m.swapFraction)) full. Apps are being written out to disk, which slows switching between them. Quit the largest memory users below or turn off background services you don't need."
        }
        if m.pressure != .normal { return "Memory is under pressure. Quitting a few large apps will help." }
        return "Memory pressure is normal. Cached files are reused memory and are released as soon as apps need it."
    }
}
