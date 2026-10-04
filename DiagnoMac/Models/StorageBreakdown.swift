import Foundation

/// What's using the disk, by kind of file, like the Storage page in macOS's own settings.
struct StorageBreakdown: Codable, Sendable {
    /// Largest first. macOS and System Data come from the volumes rather than from folders.
    var categories: [StorageCategory]
    var measuredAt: Date
    /// False while folders are still being measured: System Data isn't known until the end.
    var isComplete: Bool
    /// Parts macOS wouldn't let DiagnoMac read, so their space counts as System Data.
    var needsAccess: [StorageCategory.Kind]
    /// Big things that don't look used any more, largest first.
    var suggestions: [StorageSuggestion] = []

    /// After moving things to the Bin: they leave their categories and the suggestions, and the Bin grows.
    mutating func movedToBin(_ moved: [StorageItem]) {
        let paths = Set(moved.map(\.path))
        var binned: UInt64 = 0
        for index in categories.indices {
            for item in categories[index].items where paths.contains(item.path) {
                categories[index].bytes -= min(categories[index].bytes, item.bytes)
                binned += item.bytes
            }
            categories[index].items.removeAll { paths.contains($0.path) }
        }
        suggestions.removeAll { paths.contains($0.item.path) }
        if let bin = categories.firstIndex(where: { $0.kind == .bin }) {
            categories[bin].bytes += binned
        } else if binned > 0 {
            categories.append(StorageCategory(kind: .bin, bytes: binned, items: []))
        }
        categories.removeAll { $0.bytes == 0 }
        categories.sort { $0.bytes > $1.bytes }
    }

    mutating func emptiedBin() {
        categories.removeAll { $0.kind == .bin }
    }
}

/// Something big that doesn't look used any more, and why.
struct StorageSuggestion: Codable, Sendable, Identifiable {
    let item: StorageItem
    let kind: StorageCategory.Kind
    let reason: String
    var id: String { item.path }
}

struct StorageCategory: Codable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case applications, documents, desktop, downloads, iCloudDrive, photos, music, movies, mail, messages,
             developer, appData, bin, otherFiles, macOS, systemData

        var title: String {
            switch self {
            case .applications: "Applications"
            case .documents: "Documents"
            case .desktop: "Desktop"
            case .downloads: "Downloads"
            case .iCloudDrive: "iCloud Drive"
            case .photos: "Photos and pictures"
            case .music: "Music"
            case .movies: "Movies"
            case .mail: "Mail"
            case .messages: "Messages"
            case .developer: "Developer"
            case .appData: "App data and caches"
            case .bin: "Bin"
            case .otherFiles: "Other files in your home folder"
            case .macOS: "macOS"
            case .systemData: "System Data"
            }
        }

        /// What's in it, in a few words.
        var detail: String {
            switch self {
            case .applications: "Apps in Applications"
            case .documents: "Your Documents folder"
            case .desktop: "Files on your desktop"
            case .downloads: "Your Downloads folder"
            case .iCloudDrive: "iCloud files kept on this Mac"
            case .photos: "Your Pictures folder, including the Photos library"
            case .music: "Your Music folder: Music library, GarageBand and more"
            case .movies: "Your Movies folder: TV, iMovie and more"
            case .mail: "Messages and attachments in Mail"
            case .messages: "Conversations and attachments in Messages"
            case .developer: "Xcode, simulators, Homebrew and developer tools' hidden folders"
            case .appData: "What apps keep in your Library: settings, containers and caches"
            case .bin: "Files in the Bin, until you empty it"
            case .otherFiles: "Folders and files in your home folder that aren't anywhere above"
            case .macOS: "The system itself, and what it needs to start up and recover"
            case .systemData: "Swap, snapshots, logs and other system files, plus anything DiagnoMac couldn't read"
            }
        }

        var systemImage: String {
            switch self {
            case .applications: "square.grid.2x2.fill"
            case .documents: "doc.fill"
            case .desktop: "menubar.dock.rectangle"
            case .downloads: "arrow.down.circle.fill"
            case .iCloudDrive: "icloud.fill"
            case .photos: "photo.fill"
            case .music: "music.note"
            case .movies: "film.fill"
            case .mail: "envelope.fill"
            case .messages: "message.fill"
            case .developer: "hammer.fill"
            case .appData: "shippingbox.fill"
            case .bin: "trash.fill"
            case .otherFiles: "folder.fill"
            case .macOS: "apple.logo"
            case .systemData: "gearshape.2.fill"
            }
        }
    }

    let kind: Kind
    var bytes: UInt64
    /// The biggest things inside, largest first.
    var items: [StorageItem]
    var id: Kind { kind }
}

struct StorageItem: Codable, Sendable, Identifiable {
    let name: String
    let path: String
    let bytes: UInt64
    /// Your own files and apps you installed. Never libraries, Apple's apps or the system.
    var canMoveToBin = false
    var id: String { path }
}
