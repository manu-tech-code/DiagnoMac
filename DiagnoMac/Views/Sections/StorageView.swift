import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var cleaning = false

    var body: some View {
        Page("Storage", subtitle: "Drive health, backups, and files you can safely remove.") {
            Button("Rescan") { Task { await model.refresh(.storage) } }
        } content: {
            if let st = model.snapshot.storage {
                Columns(minimum: 190) {
                    StatTile(title: "Free space", value: String(format: "%.0f", Double(st.availableBytes) / 1e9), unit: "GB",
                             caption: "\(Format.percent(st.freeFraction)) of \(Format.gb(st.totalBytes, digits: 0))",
                             severity: st.freeFraction < 0.1 ? .warning : nil)
                    StatTile(title: "Drive health", value: st.smartStatus ?? "Unknown", caption: "S.M.A.R.T. status",
                             severity: st.smartStatus == "Verified" ? .ok : .warning)
                    backupTile
                    StatTile(title: "Reclaimable", value: Format.gb(st.reclaimableBytes), caption: "From \(st.cleanup.count) locations")
                }

                Card("Space") {
                    SegmentBar(segments: [
                        .init(label: "Used", value: max(0, Double(st.usedBytes) - Double(st.reclaimableBytes)), color: .accentColor, detail: Format.gb(st.usedBytes)),
                        .init(label: "Reclaimable", value: Double(st.reclaimableBytes), color: .orange, detail: Format.gb(st.reclaimableBytes)),
                        .init(label: "Free", value: Double(st.availableBytes), color: .green, detail: Format.gb(st.availableBytes)),
                    ], height: 20)
                    Text("Free space counts purgeable files macOS can remove on its own, matching Finder.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                cleanupCard(st)
                backupCard
            } else {
                LoadingCard(text: "Measuring folders. This can take a minute on large drives…")
            }
        }
    }

    // MARK: Cleanup

    private func selectable(_ st: StorageInfo) -> [CleanupCandidate] {
        st.cleanup.filter { if case .revealOnly = $0.method { false } else { true } }
    }

    private func cleanupCard(_ st: StorageInfo) -> some View {
        let options = selectable(st)
        let bindings = options.map { item in
            Binding(get: { selected.contains(item.id) },
                    set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })
        }
        return Card("Cleanup") {
            // Shows a dash when only some items are selected.
            Toggle(sources: bindings, isOn: \.self) {
                Text(selected.count == options.count && !options.isEmpty ? "Deselect all" : "Select all").fontWeight(.medium)
            }
            .toggleStyle(.checkbox)
            .disabled(options.isEmpty)

            VStack(spacing: 0) {
                ForEach(Array(st.cleanup.enumerated()), id: \.element.id) { index, item in
                    Divider()
                    cleanupRow(item)
                }
            }
            HStack {
                Text(selectedSummary(st)).foregroundStyle(.secondary)
                Spacer()
                Button(cleaning ? "Cleaning…" : "Clean Selected…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || cleaning)
            }
            .padding(.top, 6)
        }
        .confirmationDialog("Clean \(selectedItems(st).count) location\(selectedItems(st).count == 1 ? "" : "s")?", isPresented: $confirming) {
            Button("Clean", role: .destructive) {
                let items = selectedItems(st)
                cleaning = true
                Task {
                    await model.clean(items)
                    selected.removeAll()
                    cleaning = false
                }
            }
        } message: {
            Text("Folder contents move to the Trash, so you can restore them until you empty it. Simulators are deleted by Xcode's simctl.")
        }
    }

    private func cleanupRow(_ item: CleanupCandidate) -> some View {
        let revealOnly = if case .revealOnly = item.method { true } else { false }
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selected.contains(item.id) },
                set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(revealOnly)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium)
                    if revealOnly { Text("Review in Finder").font(.caption).foregroundStyle(.secondary) }
                }
                Text(item.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(item.bytes.map { Format.gb($0) } ?? "—").monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 8)
    }

    private func selectedItems(_ st: StorageInfo) -> [CleanupCandidate] {
        st.cleanup.filter { selected.contains($0.id) }
    }

    private func selectedSummary(_ st: StorageInfo) -> String {
        let bytes = selectedItems(st).compactMap(\.bytes).reduce(0, +)
        return selected.isEmpty ? "Select items to clean" : "\(selected.count) selected · \(Format.gb(bytes))"
    }

    // MARK: Backups

    private static let timeMachineSettings = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!

    @ViewBuilder
    private var backupTile: some View {
        if let b = model.snapshot.backup {
            if !b.isConfigured {
                StatTile(title: "Backups", value: "None", caption: "Time Machine off", severity: .warning)
            } else {
                StatTile(title: "Last backup", value: b.latestBackup.map { Format.relative($0) } ?? "Unknown",
                         caption: "Time Machine", severity: (b.daysSinceBackup ?? 0) > 7 ? .warning : .ok)
            }
        } else {
            StatTile(title: "Backups", value: "…", caption: "Checking Time Machine")
        }
    }

    @ViewBuilder
    private var backupCard: some View {
        if let b = model.snapshot.backup {
            Card("Time Machine") {
                if b.isConfigured {
                    VStack(spacing: 7) {
                        KeyValueRow(key: "Backup disks", value: b.destinations.joined(separator: ", "))
                        KeyValueRow(key: "Last backup", value: b.latestBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")
                        if let auto = b.autoBackup { KeyValueRow(key: "Automatic backups", value: auto ? "On" : "Off") }
                    }
                    if b.latestBackup == nil {
                        Text("The last backup date is only visible while the backup disk is connected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Open Time Machine Settings") { NSWorkspace.shared.open(Self.timeMachineSettings) }
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "externaldrive.badge.xmark").font(.title).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Nothing on this Mac is being backed up").fontWeight(.medium)
                            Text("Connect an external drive at least as big as your used space (\(Format.gb(model.snapshot.storage?.usedBytes ?? 0, digits: 0))), then turn on Time Machine. It keeps hourly copies automatically.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Set Up Time Machine…") { NSWorkspace.shared.open(Self.timeMachineSettings) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}
