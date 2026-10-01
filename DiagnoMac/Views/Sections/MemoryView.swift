import SwiftUI

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmQuitIdle = false

    private static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
                                                "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera"]

    var body: some View {
        Page("Memory", subtitle: "How RAM is being used, and how to take pressure off it.") {
            Button("Refresh") { Task { await model.refresh(.memory) } }
        } content: {
            if let m = model.snapshot.memory {
                Columns(minimum: 190) {
                    StatTile(title: "Memory pressure", value: m.pressure.label,
                             caption: "\(m.availablePercent)% available",
                             severity: m.pressure == .normal ? .ok : (m.pressure == .warning ? .warning : .critical))
                    StatTile(title: "Swap used", value: Format.memory(m.swapUsed), caption: "of \(Format.memory(m.swapTotal))",
                             severity: m.swapFraction > 0.6 ? .warning : nil)
                    StatTile(title: "Page-outs", value: m.pageouts.formatted(), caption: "Since startup")
                    StatTile(title: "Installed", value: Format.bytes(m.total, style: .memory), caption: "Unified memory")
                }

                reliefCard(m)

                Card("Breakdown", trailing: "Updates every 5 seconds") {
                    SegmentBar(segments: [
                        .init(label: "Wired", value: Double(m.wired), color: .red.opacity(0.8), detail: Format.memory(m.wired)),
                        .init(label: "App memory", value: Double(m.active), color: .accentColor, detail: Format.memory(m.active)),
                        .init(label: "Compressed", value: Double(m.compressed), color: .orange, detail: Format.memory(m.compressed)),
                        .init(label: "Cached files", value: Double(m.inactive), color: .accentColor.opacity(0.4), detail: Format.memory(m.inactive)),
                        .init(label: "Other", value: Double(m.other), color: .gray.opacity(0.5), detail: Format.memory(m.other)),
                        .init(label: "Free", value: Double(m.free), color: .green, detail: Format.memory(m.free)),
                    ], height: 20)
                    Text("Cached files are memory macOS reuses instantly when an app needs it, so they aren't a problem.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let apps = model.snapshot.apps, !apps.isEmpty {
                    Card("Apps using the most memory", trailing: "Same measure as Activity Monitor") {
                        VStack(spacing: 0) {
                            ForEach(Array(apps.prefix(10).enumerated()), id: \.element.id) { index, app in
                                if index > 0 { Divider() }
                                HStack(spacing: 10) {
                                    AppIcon(path: app.bundlePath).frame(width: 20, height: 20)
                                    Text(app.name)
                                    if app.isIdle { SeverityPill(severity: .info, text: "Idle") }
                                    Spacer()
                                    Text(Format.bytes(app.memoryBytes, style: .memory)).monospacedDigit()
                                    Text(String(format: "%.1f%%", Double(app.memoryBytes) / Double(max(1, m.total)) * 100))
                                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            } else {
                LoadingCard()
            }
        }
    }

    // MARK: Relief

    private struct Suggestion: Identifiable {
        let id: String
        let title: String
        let why: String
        let frees: String
        let app: RunningApp?
    }

    private func suggestions(_ m: MemoryInfo) -> [Suggestion] {
        var out: [Suggestion] = []
        let apps = model.snapshot.apps ?? []
        for app in apps.filter({ $0.isIdle && $0.memoryBytes > 150_000_000 }).prefix(6) {
            out.append(Suggestion(id: "quit.\(app.pid)", title: "Quit \(app.name)",
                                  why: "Idle: open in the background with almost no CPU use.",
                                  frees: Format.bytes(app.memoryBytes, style: .memory), app: app))
        }
        for app in apps.filter({ !$0.isIdle && $0.canQuit && $0.kind != .window && $0.memoryBytes > 300_000_000 }).prefix(2) {
            out.append(Suggestion(id: "bg.\(app.pid)", title: "Quit \(app.name)",
                                  why: "Runs in the \(app.kind == .menuBar ? "menu bar" : "background") and holds a lot of memory.",
                                  frees: Format.bytes(app.memoryBytes, style: .memory), app: app))
        }
        if let browser = apps.first(where: { Self.browsers.contains($0.bundleID ?? "") && $0.processCount > 6 }) {
            out.append(Suggestion(id: "tabs", title: "Close unused \(browser.name) tabs",
                                  why: "Each tab runs as its own process. \(browser.name) has \(browser.processCount) open.",
                                  frees: "Varies", app: nil))
        }
        if m.swapUsed > 1_000_000_000 {
            let uptime = model.snapshot.machine.map { " Up for \(Format.duration($0.uptime))." } ?? ""
            out.append(Suggestion(id: "restart", title: "Restart your Mac",
                                  why: "Clears swap completely and gives every app a fresh start.\(uptime)",
                                  frees: "\(Format.memory(m.swapUsed)) swap", app: nil))
        }
        return out
    }

    private func reliefCard(_ m: MemoryInfo) -> some View {
        let items = suggestions(m)
        let idle = (model.snapshot.apps ?? []).filter(\.isIdle)
        let underPressure = m.pressure != .normal || m.swapFraction > 0.5
        return Card("Relieve memory pressure", trailing: idle.isEmpty ? nil : "Idle apps hold \(Format.bytes(idle.reduce(0) { $0 + $1.memoryBytes }, style: .memory))") {
            if items.isEmpty {
                Label(underPressure ? "No idle apps to quit yet. DiagnoMac needs about 15 seconds to tell which apps are idle."
                                    : "Memory is fine. Nothing needs to be closed.",
                      systemImage: underPressure ? "hourglass" : "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).fontWeight(.medium)
                                Text(item.why).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.frees).monospacedDigit().foregroundStyle(.secondary)
                            action(for: item).frame(width: 110, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                    }
                }
                HStack {
                    Text("Apps are asked to quit normally, so they can save your work first.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit \(idle.count) Idle App\(idle.count == 1 ? "" : "s")…") { confirmQuitIdle = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(idle.isEmpty)
                }
            }
            if underPressure {
                Text("When RAM runs out, macOS compresses memory and then moves it to the SSD as swap. Reading it back is much slower than RAM, which is the lag you feel when switching apps.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Quit \(idle.count) idle apps?", isPresented: $confirmQuitIdle) {
            Button("Quit \(idle.count) Apps") { model.quitIdleApps() }
        } message: {
            Text(ListFormatter.localizedString(byJoining: idle.map(\.name)) + ". Apps with unsaved work will ask you what to do first.")
        }
    }

    @ViewBuilder
    private func action(for item: Suggestion) -> some View {
        if let app = item.app {
            if model.isStuckQuitting(app) {
                Button("Force Quit") { model.forceQuit(app) }.tint(.red)
            } else if model.quitRequests[app.pid] != nil {
                ProgressView().controlSize(.small)
            } else {
                Button("Quit") { model.quit(app) }
            }
        } else if item.id == "restart" {
            Button("Restart…") { model.requestRestart() }
        }
    }
}
