import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Checks") {
                    ForEach(Area.allCases) { area in
                        NavigationLink(value: area) {
                            HStack {
                                Label(area.title, systemImage: area.systemImage)
                                Spacer()
                                if area.showsHealth && (model.lastScan != nil || model.severity(for: area) > .ok) {
                                    SeverityDot(severity: model.severity(for: area))
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { scanFooter }
        } detail: {
            detail(for: model.selection ?? .overview)
                .overlay(alignment: .bottom) { banner }
        }
        // Sampling follows what's on screen: fast while the window shows live readings,
        // slow once it's closed, minimized or covered by other windows.
        .onAppear { model.setWindowVisible(true) }
        .onDisappear { model.setWindowVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue == AppDelegate.mainWindowID else { return }
            model.setWindowVisible(window.isVisible && window.occlusionState.contains(.visible))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Run Full Scan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                .help("Run every check again (⌘R)")
            }
        }
    }

    @ViewBuilder
    private func detail(for area: Area) -> some View {
        switch area {
        case .overview: OverviewView()
        case .assistant: AssistantView()
        case .apps: AppsView()
        case .devices: DevicesView()
        case .battery: BatteryView()
        case .performance: PerformanceView()
        case .memory: MemoryView()
        case .storage: StorageView()
        case .network: NetworkView()
        case .security: SecurityView()
        case .startup: StartupView()
        case .hardware: HardwareTestsView()
        case .logs: CrashLogsView()
        case .report: ReportView()
        }
    }

    private var scanFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            updateButton
            if model.isScanning {
                ProgressView(value: model.scanProgress).controlSize(.small)
                Text(model.scanStatus).font(.caption).foregroundStyle(.secondary)
            } else if let last = model.lastScan {
                Text("Last scan \(last.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updateButton: some View {
        SidebarUpdateButton(available: model.updates.available, lastChecked: { model.updates.lastChecked }) {
            model.updates.checkForUpdates()
        }
    }

    private var banner: some View {
        // The container always exists, so the banner can animate both in and out.
        ZStack {
            if let text = model.banner {
                Text(text)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 8, y: 2)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.4), value: model.banner)
    }
}

/// The sidebar's update button: Check for Updates, until a check finds a version. Then it turns
/// into the update, in the app icon's cobalt, so it's noticed.
private struct SidebarUpdateButton: View {
    let available: String?
    /// Read on each refresh: Sparkle's last check date isn't observable.
    let lastChecked: () -> Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: available == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(available == nil ? AnyShapeStyle(Brand.light) : AnyShapeStyle(.white))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(available.map { "Update to \($0)" } ?? "Check for Updates")
                        .font(.system(size: 13, weight: .semibold))
                    // Once a minute, so "checked 5 min ago" stays true.
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(subtitle).font(.caption).opacity(0.75).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SidebarUpdateButtonStyle(prominent: available != nil))
        .help(available.map { "Install DiagnoMac \($0)" } ?? "See if there's a newer DiagnoMac")
        .animation(.smooth(duration: 0.4), value: available)
    }

    private var subtitle: String {
        if available != nil { return "Ready to install" }
        return lastChecked().map { "Checked \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" } ?? "See what's new"
    }
}

private struct SidebarUpdateButtonStyle: ButtonStyle {
    let prominent: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(shape.fill(prominent ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.quaternary)))
            .overlay(shape.strokeBorder(.white.opacity(prominent ? 0.25 : 0.08)))
            .shadow(color: prominent ? Brand.mid.opacity(0.35) : .clear, radius: 8, y: 3)
            .brightness(hovering ? 0.06 : 0)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
