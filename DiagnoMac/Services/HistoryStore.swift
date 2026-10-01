import Foundation

/// One record per day, so trends like battery wear and free space build up over time.
struct HistoryEntry: Codable, Identifiable, Sendable {
    var day: Date
    var score: Int
    var batteryHealth: Int?
    var cycleCount: Int?
    var freeBytes: UInt64?
    var swapUsedBytes: UInt64?
    var id: Date { day }
}

enum HistoryStore {
    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "DiagnoMac/history.json")
    }

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Replaces today's entry with the latest scan.
    @discardableResult
    static func record(_ entry: HistoryEntry) -> [HistoryEntry] {
        var entries = load().filter { !Calendar.current.isDate($0.day, inSameDayAs: entry.day) }
        entries.append(entry)
        entries.sort { $0.day < $1.day }
        entries = Array(entries.suffix(730))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DiagnoMac: could not save history: \(error)")
        }
        return entries
    }
}
