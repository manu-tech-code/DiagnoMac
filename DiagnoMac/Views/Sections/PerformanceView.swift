import Charts
import SwiftUI

struct PerformanceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("CPU & GPU", subtitle: "Live load on the processor and graphics, thermal state, and what's using them.") {
            Button("Refresh Processes") { Task { await model.refresh(.performance) } }
        } content: {
            Columns(minimum: 190) {
                let load = model.snapshot.performance?.loadAverage ?? []
                StatTile(title: "CPU in use", value: String(format: "%.0f", (model.cpuNow?.total ?? 0) * 100), unit: "%",
                         caption: load.count == 3 ? String(format: "Load %.2f · %.2f · %.2f", load[0], load[1], load[2]) : nil)
                StatTile(title: "GPU in use", value: model.snapshot.gpu.map { "\($0.deviceUtilization)" } ?? "—", unit: "%",
                         caption: model.snapshot.machine?.gpuCores.map { "\($0)-core GPU" })
                StatTile(title: "GPU memory", value: model.snapshot.gpu.map { Format.memory($0.inUseMemory) } ?? "—",
                         caption: model.snapshot.gpu.map { "\(Format.memory($0.allocatedMemory)) allocated" })
                let thermal = model.snapshot.performance?.thermalState ?? ProcessInfo.processInfo.thermalState
                StatTile(title: "Thermal state", value: thermal.label,
                         caption: thermal == .nominal ? "Not throttling" : "Performance reduced to cool down",
                         severity: thermal == .nominal ? nil : (thermal == .fair ? .warning : .critical))
            }

            HStack(alignment: .top, spacing: 14) {
                Card("CPU per core") { coreBars }
                Card("CPU, last 2 minutes") { SparklineChart(values: model.cpuHistory) }
            }

            HStack(alignment: .top, spacing: 14) {
                gpuCard
                gpuProcessesCard
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

    private var gpuCard: some View {
        Card("GPU, last 3 minutes") {
            SparklineChart(values: model.gpuHistory, color: .intelligence, height: 110)
            if let g = model.snapshot.gpu {
                VStack(spacing: 10) {
                    meter("Overall", g.deviceUtilization)
                    meter("Rendering", g.rendererUtilization)
                    meter("Geometry (tiler)", g.tilerUtilization)
                }
            }
        }
    }

    private func meter(_ name: String, _ value: Int) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(name).foregroundStyle(.secondary)
                Spacer()
                Text("\(value)%").monospacedDigit()
            }
            .font(.callout)
            ProgressView(value: Double(value), total: 100).tint(.intelligence)
        }
    }

    private var gpuProcessesCard: some View {
        Card("Using the GPU now", trailing: "Updates every 2 seconds") {
            let processes = model.snapshot.gpu?.processes ?? []
            if processes.isEmpty {
                Text("Measuring… Usage appears after two samples.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Process"); Text("GPU").gridColumnAlignment(.trailing); Text("Total GPU time").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(processes.prefix(8)) { p in
                        GridRow {
                            Text(p.name).lineLimit(1)
                            Text(String(format: "%.1f%%", p.percent)).monospacedDigit()
                            Text(Format.duration(p.totalSeconds)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Share of time each process kept the GPU busy, from the graphics driver's per-app counters.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
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
