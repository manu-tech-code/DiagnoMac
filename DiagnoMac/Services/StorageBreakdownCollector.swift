import AppKit
import Foundation

/// Measures what's using the disk with `du`: one job per folder, a few at a time, at low priority.
/// A job with depth 1 also sizes each thing directly inside, for the drill-down.
enum StorageBreakdownCollector {
    private struct Job: Sendable {
        enum Naming: Sendable { case file, app, container, iCloud }

        let kind: StorageCategory.Kind
        let url: URL
        var depth = 0
        var naming = Naming.file
        /// Shown as an item of its category, for folders measured as a whole (Homebrew, ~/.npm, ~/dev).
        var listed = false
    }

    private struct Measured: Sendable {
        let job: Job
        let bytes: UInt64
        let items: [StorageItem]
        /// macOS refused to let DiagnoMac read the folder itself.
        let denied: Bool
    }

    /// Calls `update` with the categories so far after each folder, then returns the full breakdown.
    static func measure(update: @escaping @MainActor (StorageBreakdown, _ done: Int, _ total: Int) -> Void) async -> StorageBreakdown {
        let jobs = makeJobs()
        let usage = await diskUsage()
        var results: [Measured] = []
        await withTaskGroup(of: Measured.self) { group in
            var next = 0
            // More at once doesn't finish sooner on one SSD, and would make the Mac less responsive.
            while next < min(4, jobs.count) {
                let job = jobs[next]
                group.addTask { await run(job) }
                next += 1
            }
            for await result in group {
                results.append(result)
                await update(assemble(results, usage: usage, complete: false), results.count, jobs.count)
                if next < jobs.count {
                    let job = jobs[next]
                    group.addTask { await run(job) }
                    next += 1
                }
            }
        }
        return assemble(results, usage: usage, complete: true)
    }

    private static func makeJobs() -> [Job] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let library = home.appending(path: "Library")
        var jobs = [
            Job(kind: .applications, url: URL(fileURLWithPath: "/Applications"), depth: 1, naming: .app),
            Job(kind: .applications, url: home.appending(path: "Applications"), depth: 1, naming: .app),
            Job(kind: .documents, url: home.appending(path: "Documents"), depth: 1),
            Job(kind: .desktop, url: home.appending(path: "Desktop"), depth: 1),
            Job(kind: .downloads, url: home.appending(path: "Downloads"), depth: 1),
            Job(kind: .photos, url: home.appending(path: "Pictures"), depth: 1),
            Job(kind: .music, url: home.appending(path: "Music"), depth: 1),
            Job(kind: .movies, url: home.appending(path: "Movies"), depth: 1),
            Job(kind: .iCloudDrive, url: library.appending(path: "Mobile Documents"), depth: 1, naming: .iCloud),
            Job(kind: .mail, url: library.appending(path: "Mail")),
            Job(kind: .messages, url: library.appending(path: "Messages")),
            Job(kind: .developer, url: library.appending(path: "Developer"), depth: 1),
            Job(kind: .developer, url: URL(fileURLWithPath: "/Library/Developer"), depth: 1),
            Job(kind: .developer, url: URL(fileURLWithPath: "/opt/homebrew"), listed: true),
            Job(kind: .appData, url: library.appending(path: "Containers"), depth: 1, naming: .container),
            Job(kind: .appData, url: library.appending(path: "Group Containers"), depth: 1),
            Job(kind: .appData, url: library.appending(path: "Application Support"), depth: 1),
            Job(kind: .appData, url: library.appending(path: "Caches"), depth: 1),
            Job(kind: .bin, url: home.appending(path: ".Trash")),
        ]
        let measured = Set(jobs.map(\.url.standardizedFileURL.path))
        // The rest of the Library is app data too.
        for item in contents(of: library) where !measured.contains(item.path) {
            jobs.append(Job(kind: .appData, url: item, listed: true))
        }
        // The rest of the home folder: hidden folders are mostly developer tools, the others your own files.
        for item in contents(of: home) where !measured.contains(item.path) && item.lastPathComponent != "Library" {
            jobs.append(Job(kind: item.lastPathComponent.hasPrefix(".") ? .developer : .otherFiles, url: item, listed: true))
        }
        return jobs.filter { fm.fileExists(atPath: $0.url.path) }
    }

    private static func contents(of folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.map { folder.appending(path: $0).standardizedFileURL }
    }

    private static func run(_ job: Job) async -> Measured {
        let result = await Shell.run("/usr/bin/du", ["-k", "-d", "\(job.depth)", job.url.path], timeout: 900, qos: .utility)
        let root = job.url.path
        var bytes: UInt64 = 0
        var items: [StorageItem] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kilobytes = UInt64(parts[0]) else { continue }
            let path = String(parts[1])
            if path == root {
                bytes = kilobytes * 1024
            } else if kilobytes >= 1024 {
                items.append(StorageItem(name: name(path, job.naming), path: path, bytes: kilobytes * 1024))
            }
        }
        // At a depth, du lists folders only (it won't combine -d with -a): add the files directly inside,
        // like a big disk image in Downloads.
        if job.depth > 0 {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: job.url, includingPropertiesForKeys: Array(keys))) ?? []
            for file in files {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let size = values.totalFileAllocatedSize, size >= 1_048_576 else { continue }
                items.append(StorageItem(name: name(file.path, job.naming), path: file.path, bytes: UInt64(size)))
            }
        }
        if job.listed && bytes > 0 {
            items = [StorageItem(name: name(root, .file), path: root, bytes: bytes)]
        }
        // Only a category's own folder counts, not the odd protected folder elsewhere in the Library.
        let denied = !job.listed
            && result.stderr.split(separator: "\n").contains { $0.hasPrefix("du: \(root): ") && $0.contains("not permitted") }
        return Measured(job: job, bytes: bytes, items: items, denied: denied)
    }

    /// What the things inside are called in Finder, or for an app's container, the app's name.
    private static func name(_ path: String, _ naming: Job.Naming) -> String {
        let name = rawName(path, naming)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func rawName(_ path: String, _ naming: Job.Naming) -> String {
        let folder = (path as NSString).lastPathComponent
        switch naming {
        case .file, .app:
            if path == "/opt/homebrew" { return "Homebrew" }
            return FileManager.default.displayName(atPath: path)
        case .container:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) else { return folder }
            return FileManager.default.displayName(atPath: app.path)
        case .iCloud:
            // "com~apple~CloudDocs" is iCloud Drive itself; apps' folders look like "iCloud~md~obsidian".
            if folder == "com~apple~CloudDocs" { return "iCloud Drive" }
            return folder.split(separator: "~").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? folder
        }
    }

    private struct Usage: Sendable {
        /// Used space as Finder counts it: purgeable files are free.
        var used: UInt64
        /// The startup volume group's own volumes: System, Preboot, Recovery and Update.
        var macOS: UInt64
    }

    private static func diskUsage() async -> Usage {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let free = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        var usage = Usage(used: total > free ? total - free : 0, macOS: 0)

        let result = await Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return usage }
        let system = ["System", "Preboot", "Recovery", "Update"]
        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            func roles(_ volume: [String: Any]) -> [String] { volume["Roles"] as? [String] ?? [] }
            guard volumes.contains(where: { roles($0).contains("System") }) else { continue }
            usage.macOS = volumes.filter { !Set(roles($0)).isDisjoint(with: system) }
                .compactMap { ($0["CapacityInUse"] as? NSNumber)?.uint64Value }.reduce(0, +)
        }
        return usage
    }

    private static func assemble(_ results: [Measured], usage: Usage, complete: Bool) -> StorageBreakdown {
        var categories: [StorageCategory.Kind: StorageCategory] = [:]
        for result in results {
            var category = categories[result.job.kind] ?? StorageCategory(kind: result.job.kind, bytes: 0, items: [])
            category.bytes += result.bytes
            category.items += result.items
            categories[result.job.kind] = category
        }
        for (kind, category) in categories {
            categories[kind]?.items = Array(category.items.filter { $0.bytes >= 1_048_576 }.sorted { $0.bytes > $1.bytes }.prefix(8))
        }
        if usage.macOS > 0 { categories[.macOS] = StorageCategory(kind: .macOS, bytes: usage.macOS, items: []) }
        // What's left: swap, snapshots, other users, and folders macOS kept from DiagnoMac.
        if complete {
            let accounted = categories.values.reduce(0) { $0 + $1.bytes }
            categories[.systemData] = StorageCategory(kind: .systemData, bytes: usage.used > accounted ? usage.used - accounted : 0, items: [])
        }
        let denied = Set(results.filter(\.denied).map(\.job.kind))
        return StorageBreakdown(categories: categories.values.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes },
                                measuredAt: Date(), isComplete: complete,
                                needsAccess: StorageCategory.Kind.allCases.filter(denied.contains))
    }
}

/// The last breakdown, so the Storage page shows it straight away next time.
enum StorageBreakdownStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DiagnoMac/storage-breakdown.json")
    }

    static func load() -> StorageBreakdown? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StorageBreakdown.self, from: data)
    }

    static func save(_ breakdown: StorageBreakdown) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(breakdown).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DiagnoMac: could not save the storage breakdown: \(error)")
        }
    }
}
