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
        UpdateButton(available: model.updates.available, lastChecked: { model.updates.lastChecked }) {
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
