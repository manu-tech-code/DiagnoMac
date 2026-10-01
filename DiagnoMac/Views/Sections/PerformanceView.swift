import Charts
import SwiftUI

struct PerformanceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Performance", subtitle: "Live CPU load, thermal state and the processes using the most CPU.") {
            Button("Refresh Processes") { Task { await model.refresh(.performance) } }
        } content: {
            Columns(minimum: 200) {
                let load = model.snapshot.performance?.loadAverage ?? []
                StatTile(title: "Load average", value: load.first.map { String(format: "%.2f", $0) } ?? "—",
                         caption: load.count == 3 ? String(format: "1 min · %.2f 5 min · %.2f 15 min", load[1], load[2]) : nil)
                StatTile(title: "CPU in use", value: String(format: "%.0f", (model.cpuNow?.total ?? 0) * 100), unit: "%",
                         caption: "All \(model.cpuNow?.perCore.count ?? 0) cores")
                let thermal = model.snapshot.performance?.thermalState ?? ProcessInfo.processInfo.thermalState
                StatTile(title: "Thermal state", value: thermal.label,
                         caption: thermal == .nominal ? "Not throttling" : "Performance reduced to cool down",
                         severity: thermal == .nominal ? nil : (thermal == .fair ? .warning : .critical))
                if let m = model.snapshot.machine {
                    StatTile(title: "Chip", value: m.chip.replacingOccurrences(of: "Apple ", with: ""),
                             caption: "\(m.performanceCores)P + \(m.efficiencyCores)E CPU" + (m.gpuCores.map { " · \($0)-core GPU" } ?? ""))
                }
            }

            HStack(alignment: .top, spacing: 14) {
                Card("Per-core load", trailing: "Live") { coreBars }
                Card("Total CPU, last 2 minutes", trailing: "Live") { historyChart }
            }

            processTable
        }
    }

    private var coreBars: some View {
        let cores = model.cpuNow?.perCore ?? []
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.gradient)
                                .frame(height: geo.size.height * value)
                                .animation(.easeOut(duration: 0.4), value: value)
                        }
                    }
                    Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .help(String(format: "Core %d: %.0f%%", index + 1, value * 100))
            }
        }
        .frame(height: 140)
    }

    private var historyChart: some View {
        let samples = Array(model.cpuHistory.enumerated())
        return Chart(samples, id: \.offset) { index, value in
            AreaMark(x: .value("Second", index), y: .value("CPU", value * 100))
                .foregroundStyle(Color.accentColor.opacity(0.15))
            LineMark(x: .value("Second", index), y: .value("CPU", value * 100))
                .foregroundStyle(Color.accentColor)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
        .frame(height: 140)
    }

    @ViewBuilder
    private var processTable: some View {
        if let p = model.snapshot.performance {
            Card("Top processes by CPU", trailing: "Snapshot from last refresh") {
                Table(p.topByCPU) {
                    TableColumn("Process") { proc in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(proc.name).lineLimit(1)
                            if let app = PerformanceCollector.owningApp(for: proc.path), app != proc.name {
                                Text(app).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("PID") { Text("\($0.pid)").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                    TableColumn("CPU") { proc in
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f%%", proc.cpuPercent)).monospacedDigit()
                            if proc.cpuPercent > 40 { SeverityPill(severity: .warning, text: "High") }
                        }
                    }.width(110)
                    TableColumn("Memory") { Text(Format.bytes($0.residentBytes, style: .memory)).monospacedDigit() }.width(90)
                }
                .frame(height: 330)
                if let top = p.topByCPU.first, top.name == "WindowServer", top.cpuPercent > 30 {
                    Text("WindowServer draws everything on screen. High usage usually comes from an external display at a scaled resolution, many open windows, or menu bar apps that animate.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } else {
            LoadingCard(text: "Reading processes…")
        }
    }
}
