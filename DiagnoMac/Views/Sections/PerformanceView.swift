import SwiftUI

/// The page itself reads nothing live: each card reads its own readings, so a CPU sample every
/// second redraws only the cards that show the CPU.
struct PerformanceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("CPU & GPU", subtitle: "Live load on the processor and graphics, thermal state, and what's using them.") {
            Button("Refresh Processes") { Task { await model.refresh(.performance) } }
        } content: {
            Columns(minimum: 190) {
                CPUInUseTile()
                GPUTiles()
                ThermalTile()
            }

            CardRow {
                Card("CPU per core") { CoreBars() }
                Card("CPU, last 2 minutes") { CPUHistoryChart() }
            }

            CardRow {
                GPUCard()
                GPUProcessesCard()
            }

            ProcessTable()
        }
    }
}

private struct CPUInUseTile: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let load = model.snapshot.performance?.loadAverage ?? []
        StatTile(title: "CPU in use", value: String(format: "%.0f", (model.cpuNow?.total ?? 0) * 100), unit: "%",
                 caption: load.count == 3 ? String(format: "Load %.2f · %.2f · %.2f", load[0], load[1], load[2]) : nil)
    }
}

private struct GPUTiles: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        StatTile(title: "GPU in use", value: model.snapshot.gpu.map { "\($0.deviceUtilization)" } ?? "—", unit: "%",
                 caption: model.snapshot.machine?.gpuCores.map { "\($0)-core GPU" })
        StatTile(title: "GPU memory", value: model.snapshot.gpu.map { Format.memory($0.inUseMemory) } ?? "—",
                 caption: model.snapshot.gpu.map { "\(Format.memory($0.allocatedMemory)) allocated" })
    }
}

private struct ThermalTile: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let thermal = model.snapshot.performance?.thermalState ?? ProcessInfo.processInfo.thermalState
        StatTile(title: "Thermal state", value: thermal.label,
                 caption: thermal == .nominal ? "Not throttling" : "Performance reduced to cool down",
                 severity: thermal == .nominal ? nil : (thermal == .fair ? .warning : .critical))
    }
}

/// One bar per core. Each bar glides to its new height; Core Animation does the motion.
private struct CoreBars: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let cores = model.cpuNow?.perCore ?? []
        VStack(spacing: 4) {
            CoreBarsLayer(values: cores)
            HStack(spacing: 6) {
                ForEach(cores.indices, id: \.self) { index in
                    Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 140)
        .accessibilityElement()
        .accessibilityLabel("CPU per core")
        .accessibilityValue(cores.enumerated().map { "core \($0.offset + 1) \(Int($0.element * 100)) percent" }.joined(separator: ", "))
    }
}

private struct CoreBarsLayer: NSViewRepresentable {
    let values: [Double]

    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ view: BarsView, context: Context) { view.values = values }

    final class BarsView: NSView {
        var values: [Double] = [] { didSet { if values != oldValue { layoutBars(animated: true) } } }
        private var tracks: [CALayer] = []
        private var fills: [CALayer] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            layoutBars(animated: false)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            layoutBars(animated: false)
        }

        private func layoutBars(animated: Bool) {
            guard let host = layer, bounds.width > 0 else { return }
            while tracks.count < values.count {
                let track = CALayer(), fill = CALayer()
                track.cornerRadius = 4
                fill.cornerRadius = 4
                host.addSublayer(track)
                host.addSublayer(fill)
                tracks.append(track)
                fills.append(fill)
            }
            let n = CGFloat(max(values.count, 1)), spacing: CGFloat = 6
            let width = (bounds.width - spacing * (n - 1)) / n
            CATransaction.begin()
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                CATransaction.setAnimationDuration(0.85)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            } else {
                CATransaction.setDisableActions(true)
            }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                for (i, value) in values.enumerated() {
                    let x = CGFloat(i) * (width + spacing)
                    tracks[i].frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
                    tracks[i].backgroundColor = NSColor.quaternaryLabelColor.cgColor
                    fills[i].frame = CGRect(x: x, y: 0, width: width, height: bounds.height * min(1, max(0, value)))
                    fills[i].backgroundColor = NSColor.controlAccentColor.cgColor
                }
            }
            CATransaction.commit()
        }
    }
}

private struct CPUHistoryChart: View {
    @Environment(AppModel.self) private var model
    var body: some View { SparklineChart(values: model.cpuHistory, capacity: 120, interval: 1) }
}

private struct GPUCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card("GPU, last 6 minutes") {
            SparklineChart(values: model.gpuHistory, color: .intelligence, height: 110, capacity: 180, interval: 2)
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
}

private struct GPUProcessesCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
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
}

private struct ProcessTable: View {
    @Environment(AppModel.self) private var model
    var body: some View {
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
