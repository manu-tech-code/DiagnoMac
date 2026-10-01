import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ScoreRing(score: model.score, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DiagnoMac").font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("CPU").foregroundStyle(.secondary)
                    ProgressView(value: model.cpuNow?.total ?? 0)
                    Text(Format.percent(model.cpuNow?.total ?? 0)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                if let gpu = model.snapshot.gpu {
                    GridRow {
                        Text("GPU").foregroundStyle(.secondary)
                        ProgressView(value: Double(gpu.deviceUtilization) / 100).tint(.intelligence)
                        Text("\(gpu.deviceUtilization)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                if let mem = model.snapshot.memory {
                    GridRow {
                        Text("Memory").foregroundStyle(.secondary)
                        ProgressView(value: Double(100 - mem.availablePercent) / 100)
                        Text("\(100 - mem.availablePercent)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    GridRow {
                        Text("Swap").foregroundStyle(.secondary)
                        ProgressView(value: mem.swapFraction)
                        Text(Format.percent(mem.swapFraction)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                if let battery = model.snapshot.battery {
                    GridRow {
                        HStack(spacing: 3) {
                            Text("Battery").foregroundStyle(.secondary)
                            if battery.isCharging { Image(systemName: "bolt.fill").foregroundStyle(.green).font(.caption) }
                        }
                        ProgressView(value: Double(battery.chargePercent) / 100).tint(battery.isCharging ? .green : nil)
                        Text("\(battery.chargePercent)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    if battery.isCharging, let t = battery.telemetry {
                        GridRow {
                            Text("")
                            Text(String(format: "Charging at %.0f W", max(0, t.battery)) + (battery.minutesToFull.map { " · full in \(Format.minutes($0))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                                .gridCellColumns(2)
                        }
                    }
                }
            }

            if let top = model.findings.first {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    SeverityDot(severity: top.severity).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(top.title).fontWeight(.medium)
                        Text(top.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }

            if let version = model.updates.available {
                Divider()
                Button { model.updates.checkForUpdates() } label: {
                    Label("DiagnoMac \(version) is available", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.link)
            }

            Divider()

            HStack {
                Button("Open DiagnoMac") {
                    AppDelegate.showMainWindow(using: openWindow)
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Scan") { Task { await model.scan() } }.disabled(model.isScanning)
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.setMenuBarPanelVisible(true) }
        .onDisappear { model.setMenuBarPanelVisible(false) }
    }

    private var summary: String {
        if model.isScanning { return "Scanning…" }
        let count = model.findings.filter { $0.severity >= .warning }.count
        return count == 0 ? "No problems found" : "\(count) item\(count == 1 ? "" : "s") need attention"
    }
}
