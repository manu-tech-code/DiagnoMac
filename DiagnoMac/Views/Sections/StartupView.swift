import SwiftUI

struct StartupView: View {
    @Environment(AppModel.self) private var model
    @State private var busy: Set<String> = []

    var body: some View {
        Page("Startup Items", subtitle: "Background agents that start at login. Each one costs memory, battery and boot time.") {
            Button("Refresh") { Task { await model.refresh(.startup) } }
        } content: {
            if let items = model.snapshot.startup {
                if items.isEmpty {
                    Card { Text("No third-party launch agents or daemons are installed.").foregroundStyle(.secondary) }
                }
                ForEach([StartupItem.Scope.userAgent, .systemAgent, .systemDaemon], id: \.self) { scope in
                    let group = items.filter { $0.scope == scope }
                    if !group.isEmpty {
                        Card(scope.rawValue + "s", trailing: scope == .userAgent ? "You can switch these off" : "Need an administrator") {
                            VStack(spacing: 0) {
                                ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { Divider() }
                                    row(item)
                                }
                            }
                        }
                    }
                }
                Text("Switching an item off runs launchctl disable and unloads it. The file stays in place, so you can switch it back on.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LoadingCard()
            }
        }
    }

    private func row(_ item: StartupItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            rowContent(item)
            if let text = model.intelligence.text(for: "startup.\(item.id)") {
                AIBlock(title: "Explained on this Mac", text: text,
                        onDismiss: { model.intelligence.dismiss(key: "startup.\(item.id)") },
                        onRetry: { model.explain(item) })
            }
        }
    }

    private func rowContent(_ item: StartupItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).font(.body.monospaced())
                    if item.isLoaded == true { SeverityPill(severity: .info, text: "Running") }
                    if item.keepAlive { SeverityPill(severity: .ok, text: "Keep-alive").foregroundStyle(.secondary) }
                }
                Text([item.vendor, item.program.map { URL(fileURLWithPath: $0).lastPathComponent }].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.intelligence.isAvailable && model.intelligence.text(for: "startup.\(item.id)") == nil {
                ExplainButton(title: "What Is This?") { model.explain(item) }.controlSize(.small)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show plist in Finder")
            if busy.contains(item.id) {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { !item.isDisabled },
                    set: { enabled in
                        busy.insert(item.id)
                        Task {
                            await model.setStartupItem(item, enabled: enabled)
                            busy.remove(item.id)
                        }
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!item.canToggleWithoutAdmin)
                    .help(item.canToggleWithoutAdmin ? "Run at login" : "System-wide items need an administrator")
            }
        }
        .padding(.vertical, 8)
    }
}
