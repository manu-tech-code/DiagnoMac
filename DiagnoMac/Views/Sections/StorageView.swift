import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var cleaning = false

    var body: some View {
        Page("Storage", subtitle: "Drive health, free space, and files you can safely remove.") {
            Button("Rescan") { Task { await model.refresh(.storage) } }
        } content: {
            if let st = model.snapshot.storage {
                Columns(minimum: 200) {
                    StatTile(title: "Free space", value: String(format: "%.0f", Double(st.availableBytes) / 1e9), unit: "GB",
                             caption: "\(Format.percent(st.freeFraction)) of \(Format.gb(st.totalBytes, digits: 0))",
                             severity: st.freeFraction < 0.1 ? .warning : nil)
                    StatTile(title: "Drive health", value: st.smartStatus ?? "Unknown", caption: "S.M.A.R.T. status",
                             severity: st.smartStatus == "Verified" ? .ok : .warning)
                    StatTile(title: "File system", value: st.fileSystem.replacingOccurrences(of: " (Case-sensitive)", with: ""),
                             caption: [st.isEncrypted == true ? "Encrypted" : nil, st.deviceName].compactMap { $0 }.joined(separator: " · "))
                    StatTile(title: "Reclaimable", value: Format.gb(st.reclaimableBytes), caption: "From \(st.cleanup.count) locations")
                }

                Card("Space") {
                    SegmentBar(segments: [
                        .init(label: "Used", value: Double(st.usedBytes), color: .accentColor, detail: Format.gb(st.usedBytes)),
                        .init(label: "Reclaimable", value: Double(st.reclaimableBytes), color: .orange, detail: Format.gb(st.reclaimableBytes)),
                        .init(label: "Free", value: Double(st.availableBytes), color: .green, detail: Format.gb(st.availableBytes)),
                    ].map { seg in
                        // Reclaimable is part of used; show it carved out of the used segment.
                        seg.label == "Used" ? .init(label: seg.label, value: max(0, seg.value - Double(st.reclaimableBytes)), color: seg.color, detail: seg.detail) : seg
                    }, height: 20)
                    Text("Free space counts purgeable files macOS can remove on its own, matching Finder.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card("Cleanup") {
                    VStack(spacing: 0) {
                        ForEach(Array(st.cleanup.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
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
                    Text("Folder contents move to the Trash, so you can still restore them until you empty it. Simulators are deleted by Xcode's simctl.")
                }
            } else {
                LoadingCard(text: "Measuring folders. This can take a minute on large drives…")
            }
        }
    }

    private func cleanupRow(_ item: CleanupCandidate) -> some View {
        let revealOnly = if case .revealOnly = item.method { true } else { false }
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selected.contains(item.id) },
                set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                .labelsHidden()
                .disabled(revealOnly)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.medium)
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
        return selected.isEmpty ? "Select items to clean" : "\(Format.gb(bytes)) selected"
    }
}
