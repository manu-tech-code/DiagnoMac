import Foundation

enum StorageCollector {
    static func collect() async -> StorageInfo {
        async let smart = smartStatus()
        async let cleanup = cleanupCandidates()

        let root = URL(fileURLWithPath: "/")
        let values = try? root.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedFormatDescriptionKey, .volumeIsEncryptedKey,
        ])

        let (smartStatus, device) = await smart
        return StorageInfo(
            volumeName: values?.volumeName ?? "Macintosh HD",
            totalBytes: UInt64(values?.volumeTotalCapacity ?? 0),
            availableBytes: UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0)),
            fileSystem: values?.volumeLocalizedFormatDescription ?? "APFS",
            isEncrypted: values?.volumeIsEncrypted,
            smartStatus: smartStatus,
            deviceName: device,
            cleanup: await cleanup
        )
    }

    /// Reads the internal disk's SMART status and model from diskutil.
    private static func smartStatus() async -> (String?, String?) {
        let result = await Shell.run("/usr/sbin/diskutil", ["info", "disk0"])
        var smart: String?, device: String?
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "SMART Status" { smart = parts[1] }
            if parts[0] == "Device / Media Name" { device = parts[1] }
        }
        return (smart, device)
    }

    static func cleanupCandidates() async -> [CleanupCandidate] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let developer = home.appending(path: "Library/Developer")
        let candidates: [CleanupCandidate] = [
            CleanupCandidate(id: "caches", title: "User caches", url: home.appending(path: "Library/Caches"),
                             explanation: "Apps rebuild these as needed. Expect slower first launches afterwards.",
                             method: .trashContents),
            CleanupCandidate(id: "derived", title: "Xcode DerivedData", url: developer.appending(path: "Xcode/DerivedData"),
                             explanation: "Build products and indexes. Xcode recreates them on the next build.",
                             method: .trashContents),
            CleanupCandidate(id: "simdevices", title: "Unavailable simulators", url: developer.appending(path: "CoreSimulator/Devices"),
                             explanation: "Removes simulators for runtimes that are no longer installed. Size shown is all simulators.",
                             method: .command(path: "/usr/bin/xcrun", args: ["simctl", "delete", "unavailable"])),
            CleanupCandidate(id: "archives", title: "Xcode archives", url: developer.appending(path: "Xcode/Archives"),
                             explanation: "Needed to symbolicate crash reports for apps you shipped. Review before deleting.",
                             method: .revealOnly),
            CleanupCandidate(id: "devicesupport", title: "iOS device support files", url: developer.appending(path: "Xcode/iOS DeviceSupport"),
                             explanation: "Symbol files for devices you've connected. Xcode downloads them again when needed.",
                             method: .trashContents),
            CleanupCandidate(id: "logs", title: "User logs", url: home.appending(path: "Library/Logs"),
                             explanation: "Old app logs. Crash reports live here too, so check the Crash Logs page first.",
                             method: .revealOnly),
        ]

        return await withTaskGroup(of: CleanupCandidate?.self) { group in
            for candidate in candidates {
                group.addTask {
                    guard FileManager.default.fileExists(atPath: candidate.url.path) else { return nil }
                    var sized = candidate
                    sized.bytes = await offMain { directorySize(candidate.url) }
                    return sized
                }
            }
            var found: [CleanupCandidate] = []
            for await candidate in group { if let candidate { found.append(candidate) } }
            return found.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        }
    }

    static func directorySize(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Performs a cleanup. Returns a message describing the outcome.
    static func clean(_ candidate: CleanupCandidate) async -> String {
        switch candidate.method {
        case .revealOnly:
            return "Nothing removed."
        case .command(let path, let args):
            let result = await Shell.run(path, args, timeout: 120)
            return result.succeeded ? "\(candidate.title): done." : "\(candidate.title) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .trashContents:
            return await offMain {
                let fm = FileManager.default
                let items = (try? fm.contentsOfDirectory(at: candidate.url, includingPropertiesForKeys: nil)) ?? []
                var failed = 0
                for item in items {
                    do { try fm.trashItem(at: item, resultingItemURL: nil) } catch { failed += 1 }
                }
                let moved = items.count - failed
                return failed == 0
                    ? "Moved \(moved) items from \(candidate.title) to the Trash."
                    : "Moved \(moved) items to the Trash. \(failed) were in use or protected and were skipped."
            }
        }
    }
}
