import Foundation
import Observation

/// Browsing a storage category folder by folder, down to single files, with ticks that stay as you
/// move between folders so things from several places can go to the Bin together.
@MainActor
@Observable
final class StorageBrowser {
    /// The category being browsed, or nil for the list of categories.
    private(set) var category: StorageCategory.Kind?
    /// The folders opened inside it, outermost first.
    private(set) var folders: [StorageItem] = []
    /// Each opened folder's contents, largest first, by path. Nil while it's being measured.
    private(set) var contents: [String: [StorageItem]] = [:]
    /// What's ticked, by path, from any folder.
    private(set) var ticked: [String: StorageItem] = [:]

    var isBrowsing: Bool { category != nil }

    func open(_ kind: StorageCategory.Kind) {
        category = kind
        folders = []
        // Measured afresh each time a category opens, so sizes reflect what's on disk now.
        contents = [:]
    }

    func open(_ folder: StorageItem) {
        guard folder.isFolder, let kind = category else { return }
        folders.append(folder)
        guard contents[folder.path] == nil else { return }
        Task {
            let found = await StorageBreakdownCollector.contents(of: folder, kind: kind)
            contents[folder.path] = found
        }
    }

    /// Back to the category itself (`depth` 0) or one of the opened folders.
    func goUp(to depth: Int) {
        folders = Array(folders.prefix(depth))
    }

    func back() {
        if folders.isEmpty { category = nil } else { folders.removeLast() }
    }

    func close() {
        category = nil
        folders = []
    }

    /// What the current folder holds, or nil while it's measured.
    func items(in breakdown: StorageBreakdown) -> [StorageItem]? {
        if let folder = folders.last { return contents[folder.path] }
        return breakdown.categories.first { $0.kind == category }?.children
    }

    // MARK: Ticks

    /// A folder that contains it is ticked, so it goes with that folder.
    func isCovered(_ item: StorageItem) -> Bool {
        ticked.values.contains { $0.path != item.path && $0.holds(item) }
    }

    func isTicked(_ item: StorageItem) -> Bool { ticked[item.path] != nil || isCovered(item) }

    func setTicked(_ item: StorageItem, _ on: Bool) {
        if on {
            // Ticking a folder takes in anything already ticked inside it.
            ticked = ticked.filter { !item.holds($0.value) }
            ticked[item.path] = item
        } else {
            ticked[item.path] = nil
        }
    }

    func clearTicks() { ticked = [:] }

    /// What would go to the Bin, largest first.
    var selection: [StorageItem] { ticked.values.sorted { $0.bytes > $1.bytes } }

    var selectedBytes: UInt64 { ticked.values.reduce(0) { $0 + $1.bytes } }

    /// After things went to the Bin: they leave the ticks and every listing, and the folders that held
    /// them shrink.
    func moved(_ items: [StorageItem]) {
        for item in items { ticked[item.path] = nil }
        for (path, list) in contents {
            contents[path] = list.compactMap { entry in
                if items.contains(where: { $0.path == entry.path }) { return nil }
                let inside = items.filter { entry.holds($0) }.reduce(0) { $0 + $1.bytes }
                var smaller = entry
                smaller.bytes -= min(entry.bytes, inside)
                return smaller
            }
        }
        folders = folders.map { folder in
            var smaller = folder
            smaller.bytes -= min(folder.bytes, items.filter { folder.holds($0) && $0.path != folder.path }.reduce(0) { $0 + $1.bytes })
            return smaller
        }
    }
}
