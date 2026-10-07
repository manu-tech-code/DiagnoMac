import SwiftUI

struct AppsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", windows = "With Windows", background = "Menu Bar & Background", idle = "Idle"
        var id: String { rawValue }

        var shortName: String {
            switch self {
            case .all: "All"
            case .windows: "Windows"
            case .background: "Menu bar"
            case .idle: "Idle"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var filter: Filter = {
        #if DEBUG
        // `-appsFilter "With Windows"`: open with that filter selected, for screenshots.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-appsFilter"), i + 1 < args.count, let chosen = Filter(rawValue: args[i + 1]) { return chosen }
        #endif
        return .all
    }()
    @State private var pendingQuit: RunningApp?
    @State private var confirmQuitIdle = false

    var body: some View {
        Page("Running Apps", subtitle: "Everything open on this Mac, including apps that only live in the menu bar or background. Quit what you don't need.") {
            // Its own row, not in the header: beside the description it ran into it.
            SegmentedFilter(options: Filter.allCases, selection: $filter, label: \.rawValue, shortLabel: \.shortName)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let apps = model.snapshot.apps {
                let idle = apps.filter(\.isIdle)
                Columns(minimum: 200) {
                    StatTile(title: "Apps open", value: "\(apps.count)",
                             caption: "\(apps.filter { $0.kind != .window }.count) in the menu bar or background")
                    StatTile(title: "Memory used by apps", value: Format.bytes(apps.reduce(0) { $0 + $1.memoryBytes }, style: .memory),
                             caption: "Not counting macOS itself")
                    Card("Idle apps") {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(idle.count)").font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                            Text(idle.isEmpty ? "" : "holding \(Format.bytes(idle.reduce(0) { $0 + $1.memoryBytes }, style: .memory))")
                                .foregroundStyle(.secondary)
                        }
                        Button("Quit All Idle Apps…") { confirmQuitIdle = true }.disabled(idle.isEmpty)
                    }
                }

                Card("\(filtered(apps).count) apps", trailing: "Sorted by memory · updates every 5 seconds") {
                    VStack(spacing: 0) {
                        header
                        ForEach(filtered(apps)) { app in
                            Divider()
                            row(app)
                        }
                    }
                    Text("Quit asks the app to close normally so it can save your work. If it doesn't close within a few seconds, you can force quit it. Idle means the app is open, not in front, and has used almost no CPU recently.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .confirmationDialog("Quit \(pendingQuit?.name ?? "")?", isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } })) {
                    Button("Quit") { if let app = pendingQuit { model.quit(app) }; pendingQuit = nil }
                } message: {
                    Text("If it has unsaved work, it will ask you what to do first.")
                }
                .confirmationDialog("Quit \(idle.count) idle apps?", isPresented: $confirmQuitIdle) {
                    Button("Quit \(idle.count) Apps") { model.quitIdleApps() }
                } message: {
                    Text(ListFormatter.localizedString(byJoining: idle.map(\.name)) + ". Apps with unsaved work will ask you what to do first.")
                }
            } else {
                LoadingCard(text: "Measuring open apps…")
            }
        }
    }

    private func filtered(_ apps: [RunningApp]) -> [RunningApp] {
        switch filter {
        case .all: apps
        case .windows: apps.filter { $0.kind == .window }
        case .background: apps.filter { $0.kind != .window }
        case .idle: apps.filter(\.isIdle)
        }
    }

    private var header: some View {
        HStack {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("Shows as").frame(width: 100, alignment: .leading)
            Text("Memory").frame(width: 90, alignment: .trailing)
            Text("CPU").frame(width: 70, alignment: .trailing)
            Text("Processes").frame(width: 80, alignment: .trailing)
            Spacer().frame(width: 150)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    private func row(_ app: RunningApp) -> some View {
        HStack {
            HStack(spacing: 10) {
                AppIcon(path: app.bundlePath).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(app.name).fontWeight(.medium).lineLimit(1)
                        if app.isIdle { SeverityPill(severity: .info, text: "Idle") }
                        if app.averageCPU > 30 { SeverityPill(severity: .warning, text: "Busy") }
                        if app.isHidden { Text("Hidden").font(.caption).foregroundStyle(.secondary) }
                    }
                    if !app.canQuit {
                        Text(app.bundleID == "com.apple.finder" ? "macOS reopens Finder automatically" : "This app")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(app.kind.rawValue).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(Format.bytes(app.memoryBytes, style: .memory)).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(app.observedSeconds > 0 ? String(format: "%.1f%%", app.averageCPU) : "…").monospacedDigit().frame(width: 70, alignment: .trailing)
            Text("\(app.processCount)").monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            HStack(spacing: 6) {
                Spacer()
                if app.kind == .window {
                    Button { AppsSampler.show(pid: app.pid) } label: { Image(systemName: "macwindow") }
                        .buttonStyle(.borderless).help("Bring to front")
                }
                if model.isStuckQuitting(app) {
                    Button("Force Quit") { model.forceQuit(app) }.tint(.red)
                } else if model.quitRequests[app.pid] != nil {
                    ProgressView().controlSize(.small)
                } else if app.canQuit {
                    Button("Quit") { pendingQuit = app }
                }
            }
            .frame(width: 150)
        }
        .padding(.vertical, 7)
    }
}

/// The app's Finder icon.
struct AppIcon: View {
    let path: String?
    var body: some View {
        if let path {
            Image(nsImage: AppIconCache.icon(for: path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "app").resizable().foregroundStyle(.secondary)
        }
    }
}

/// Finder icons carry every size up to 1024 px; rows show them at 20–24 points, so a small copy
/// is kept per app instead of asking NSWorkspace again on every redraw.
@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let full = NSWorkspace.shared.icon(forFile: path)
        let small = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            full.draw(in: rect)
            return true
        }
        cache.setObject(small, forKey: path as NSString)
        return small
    }
}
