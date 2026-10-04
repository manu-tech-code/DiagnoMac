import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var cleaning = false
    @State private var browser = StorageBrowser()
    @State private var selectedSuggestions: Set<String> = []
    /// What the Move to Bin confirmation is asking about.
    @State private var pendingBin: [StorageItem]?
    @State private var confirmingEmptyBin = false

    var body: some View {
        Page("Storage", subtitle: "Drive health, backups, and files you can safely remove.") {
            Button("Rescan") {
                Task { await model.refresh(.storage) }
                if model.snapshot.storageBreakdown != nil { model.measureStorage() }
            }
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

                // What you can act on comes before the long list of what's using space.
                if let breakdown = model.snapshot.storageBreakdown, breakdown.isComplete, !breakdown.suggestions.isEmpty {
                    suggestionsCard(breakdown.suggestions)
                }
                spaceCard(st)

                cleanupCard(st)
                backupCard
            } else {
                LoadingCard(text: "Measuring folders. This can take a minute on large drives…")
            }
        }
        .confirmationDialog(binTitle, isPresented: Binding(get: { pendingBin != nil }, set: { if !$0 { pendingBin = nil } }),
                            titleVisibility: .visible, presenting: pendingBin) { items in
            Button("Move to Bin", role: .destructive) {
                selectedSuggestions.subtract(items.map(\.path))
                Task { browser.moved(await model.moveToBin(items)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            Text(binMessage(items))
        }
        .confirmationDialog("Empty the Bin?", isPresented: $confirmingEmptyBin, titleVisibility: .visible) {
            Button("Empty Bin", role: .destructive) { Task { await model.emptyBin() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Bin is deleted for good, freeing \(Format.bytes(binBytes)). You can't undo this.")
        }
        .onAppear {
            model.refreshStorageBreakdownIfStale()
            #if DEBUG
            // `-browseStorage <category> [-browseFolder <path>]`: open the browser there, for screenshots.
            let args = ProcessInfo.processInfo.arguments
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            if let kind = value("-browseStorage").flatMap(StorageCategory.Kind.init(rawValue:)) {
                browser.open(kind)
                let children = model.snapshot.storageBreakdown?.categories.first { $0.kind == kind }?.children ?? []
                // Opens each folder on the way down to the path.
                if let path = value("-browseFolder"), let top = children.first(where: { $0.holds(StorageItem(name: "", path: path, bytes: 0)) }) {
                    browser.open(top)
                    var current = top.path
                    for part in path.dropFirst(top.path.count).split(separator: "/") {
                        current += "/" + part
                        browser.open(StorageItem(name: String(part), path: current, bytes: 0, isFolder: true))
                    }
                }
            }
            #endif
        }
    }

    // MARK: Space

    private func spaceCard(_ st: StorageInfo) -> some View {
        Card("Space", trailing: spaceStatus) {
            if let progress = model.storageProgress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total)).controlSize(.small)
            }
            if let breakdown = model.snapshot.storageBreakdown, !breakdown.categories.isEmpty {
                SegmentBar(segments: breakdown.categories.map {
                    .init(label: $0.kind.title, value: Double($0.bytes), color: $0.kind.color, detail: Format.bytes($0.bytes))
                } + [.init(label: "Free", value: Double(st.availableBytes), color: .secondary.opacity(0.2), detail: Format.bytes(st.availableBytes))],
                height: 20, showsLegend: false)
                .animation(.smooth(duration: 0.5), value: breakdown.categories.map(\.bytes))

                if browser.isBrowsing {
                    browserView(breakdown)
                } else {
                    VStack(spacing: 0) {
                        ForEach(breakdown.categories) { category in
                            Divider()
                            categoryRow(category, used: st.usedBytes)
                        }
                    }
                    if !breakdown.needsAccess.isEmpty { accessNote(breakdown.needsAccess) }
                }
            } else {
                SegmentBar(segments: [
                    .init(label: "Used", value: max(0, Double(st.usedBytes) - Double(st.reclaimableBytes)), color: .accentColor, detail: Format.gb(st.usedBytes)),
                    .init(label: "Reclaimable", value: Double(st.reclaimableBytes), color: .orange, detail: Format.gb(st.reclaimableBytes)),
                    .init(label: "Free", value: Double(st.availableBytes), color: .green, detail: Format.gb(st.availableBytes)),
                ], height: 20)
                Text("Free space counts purgeable files macOS can remove on its own, matching Finder.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                measurePrompt
            }
        }
    }

    private var spaceStatus: String? {
        if let progress = model.storageProgress {
            return progress.total > 0 ? "Measuring folders, \(progress.done) of \(progress.total)" : "Measuring folders…"
        }
        return model.snapshot.storageBreakdown.map { "Measured \(Format.relative($0.measuredAt))" }
    }

    private func categoryRow(_ category: StorageCategory, used: UInt64) -> some View {
        HStack(spacing: 10) {
            Button {
                guard !category.children.isEmpty else { return }
                withAnimation(.smooth(duration: 0.3)) { browser.open(category.kind) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: category.kind.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(category.kind.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.kind.title).fontWeight(.medium)
                        Text(category.kind.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    ShareBar(fraction: Double(category.bytes) / Double(max(used, 1)), color: category.kind.color)
                        .frame(width: 80, height: 6)
                    Text(Format.bytes(category.bytes)).monospacedDigit().frame(minWidth: 72, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(category.children.isEmpty ? 0 : 1)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if category.kind == .bin {
                Button("Empty Bin…") { confirmingEmptyBin = true }.controlSize(.small)
            }
        }
    }

    // MARK: Browser

    private func browserView(_ breakdown: StorageBreakdown) -> some View {
        let kind = browser.category ?? .otherFiles
        let items = browser.items(in: breakdown)
        let total = items?.reduce(0) { $0 + $1.bytes } ?? 0
        let selectable = (items ?? []).filter { $0.canMoveToBin && !browser.isCovered($0) }
        let bindings = selectable.map { item in
            Binding(get: { browser.ticked[item.path] != nil }, set: { browser.setTicked(item, $0) })
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { withAnimation(.smooth(duration: 0.3)) { browser.back() } } label: {
                    Image(systemName: "chevron.left").frame(width: 16)
                }
                .help(browser.folders.isEmpty ? "All categories" : "Back")
                breadcrumb(kind)
                Spacer(minLength: 12)
                Text(Format.bytes(total)).monospacedDigit().foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Toggle(sources: bindings, isOn: \.self) {
                    Text(!selectable.isEmpty && selectable.allSatisfy { browser.ticked[$0.path] != nil } ? "Deselect all" : "Select all")
                        .fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                .disabled(selectable.isEmpty)
                Text(browser.ticked.isEmpty ? "Tick what you want to remove, in any folder"
                     : "\(browser.ticked.count) selected · \(Format.bytes(browser.selectedBytes))")
                    .foregroundStyle(.secondary)
                Spacer()
                if !browser.ticked.isEmpty {
                    Button("Clear") { browser.clearTicks() }
                }
                Button("Move to Bin…") { pendingBin = browser.selection }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.ticked.isEmpty)
            }

            if let items {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Divider()
                        browserRow(item, total: total, color: kind.color)
                    }
                }
                if items.isEmpty {
                    Text("Nothing in here takes up space.").foregroundStyle(.secondary).padding(.vertical, 8)
                } else if items.count >= StorageBreakdownCollector.listLimit {
                    Text("Showing the \(items.count) largest. Smaller ones are left out.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring \(browser.folders.last?.name ?? "the folder")…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// The category, then the folders opened in it. Deep paths show only the last two folders.
    private func breadcrumb(_ kind: StorageCategory.Kind) -> some View {
        let shown = Array(browser.folders.enumerated()).suffix(2)
        return HStack(spacing: 5) {
            crumb(kind.title, depth: 0)
            if browser.folders.count > 2 {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Text("…").foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.element.path) { index, folder in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                crumb(folder.name, depth: index + 1)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func crumb(_ title: String, depth: Int) -> some View {
        if depth == browser.folders.count {
            Text(title).fontWeight(.semibold).truncationMode(.middle)
        } else {
            Button(title) { withAnimation(.smooth(duration: 0.3)) { browser.goUp(to: depth) } }
                .buttonStyle(.link)
                .truncationMode(.middle)
        }
    }

    private func browserRow(_ item: StorageItem, total: UInt64, color: Color) -> some View {
        let covered = browser.isCovered(item)
        return HStack(spacing: 10) {
            if item.canMoveToBin {
                Toggle("", isOn: Binding(get: { browser.isTicked(item) }, set: { browser.setTicked(item, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(covered)
            } else {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help("Protected: DiagnoMac doesn't remove this")
            }
            Button {
                if item.isFolder { withAnimation(.smooth(duration: 0.3)) { browser.open(item) } }
            } label: {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(covered ? "Goes with the folder you ticked" : !item.canMoveToBin ? "Protected" : item.isFolder ? "Folder" : "File")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    ShareBar(fraction: Double(item.bytes) / Double(max(total, 1)), color: color)
                        .frame(width: 70, height: 6)
                    Text(Format.bytes(item.bytes)).monospacedDigit().frame(minWidth: 72, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(item.isFolder ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 5)
    }

    // MARK: Suggestions

    private func suggestionsCard(_ suggestions: [StorageSuggestion]) -> some View {
        let total = suggestions.reduce(0) { $0 + $1.item.bytes }
        let chosen = suggestions.filter { selectedSuggestions.contains($0.id) }
        let bindings = suggestions.map { suggestion in
            Binding(get: { selectedSuggestions.contains(suggestion.id) },
                    set: { if $0 { selectedSuggestions.insert(suggestion.id) } else { selectedSuggestions.remove(suggestion.id) } })
        }
        return Card("Suggestions", trailing: "Could free \(Format.bytes(total))") {
            Text("Big things you don't seem to use any more. Nothing is removed until you confirm, and it goes to the Bin first, so you can put it back.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(sources: bindings, isOn: \.self) {
                Text(chosen.count == suggestions.count ? "Deselect all" : "Select all").fontWeight(.medium)
            }
            .toggleStyle(.checkbox)

            VStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Divider()
                    suggestionRow(suggestion)
                }
            }
            HStack {
                Text(chosen.isEmpty ? "Select what you don't need" : "\(chosen.count) selected · \(Format.bytes(chosen.reduce(0) { $0 + $1.item.bytes }))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Move to Bin…") { pendingBin = chosen.map(\.item) }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
            .padding(.top, 6)
        }
    }

    private func suggestionRow(_ suggestion: StorageSuggestion) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selectedSuggestions.contains(suggestion.id) },
                set: { if $0 { selectedSuggestions.insert(suggestion.id) } else { selectedSuggestions.remove(suggestion.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: suggestion.item.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(suggestion.item.name).fontWeight(.medium).lineLimit(1)
                    Text(suggestion.kind.title).font(.caption).foregroundStyle(.secondary)
                }
                Text(suggestion.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(Self.location(of: suggestion.item)).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Text(Format.bytes(suggestion.item.bytes)).monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: suggestion.item.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 8)
    }

    // MARK: Confirmations

    private var binTitle: String {
        guard let items = pendingBin else { return "" }
        return items.count == 1 ? "Move “\(items[0].name)” to the Bin?" : "Move \(items.count) items to the Bin?"
    }

    private func binMessage(_ items: [StorageItem]) -> String {
        let bytes = items.reduce(0) { $0 + $1.bytes }
        var message = "\(Format.bytes(bytes)) goes to the Bin. You can put it back until you empty the Bin, which frees the space."
        if items.contains(where: { $0.path.hasSuffix(".app") && $0.path.hasPrefix("/Applications/") }) {
            message += " Moving an app to the Bin uninstalls it."
        }
        let library = NSHomeDirectory() + "/Library/"
        if items.contains(where: { $0.path.hasPrefix(library) || ($0.path as NSString).lastPathComponent.hasPrefix(".") }) {
            message += " Apps and tools lose what they kept there, and download or rebuild it when they need it."
        }
        return message
    }

    private var binBytes: UInt64 {
        model.snapshot.storageBreakdown?.categories.first { $0.kind == .bin }?.bytes ?? 0
    }

    private static func location(of item: StorageItem) -> String {
        let folder = (item.path as NSString).deletingLastPathComponent
        return folder == NSHomeDirectory() ? "Home folder" : folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private func accessNote(_ kinds: [StorageCategory.Kind]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS didn't let DiagnoMac read \(kinds.map(\.title).formatted(.list(type: .and))), so that space counts as System Data.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Give DiagnoMac Full Disk Access…") { NSWorkspace.shared.open(Self.fullDiskAccessSettings) }
                    .buttonStyle(.link)
            }
        }
        .padding(.top, 6)
    }

    private var measurePrompt: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("See what's using space").fontWeight(.medium)
                Text("DiagnoMac measures your folders, which takes a minute or two. macOS may ask whether it can read your Desktop, Documents, Downloads and other apps' data. It only looks at their sizes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.storageProgress != nil {
                ProgressView().controlSize(.small)
            } else {
                Button("Measure") { model.measureStorage() }.buttonStyle(.borderedProminent)
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

/// A category's share of the used space.
private struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(3, geo.size.width * min(1, fraction)))
            }
        }
    }
}

extension StorageCategory.Kind {
    var color: Color {
        switch self {
        case .applications: .blue
        case .documents: .orange
        case .desktop: .teal
        case .downloads: .green
        case .iCloudDrive: .cyan
        case .photos: .yellow
        case .music: .pink
        case .movies: .purple
        case .mail: .indigo
        case .messages: .mint
        case .developer: .brown
        case .appData: Color(hue: 0.02, saturation: 0.62, brightness: 0.92)
        case .bin: .gray
        case .otherFiles: Color(hue: 0.6, saturation: 0.35, brightness: 0.78)
        case .macOS: Color(white: 0.62)
        case .systemData: Color(white: 0.45)
        }
    }
}
