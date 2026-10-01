import Foundation

enum CrashLogCollector {
    static func collect() async -> LogsInfo {
        await offMain { read() }
    }

    private static func read() -> LogsInfo {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            home.appending(path: "Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]
        var reports: [CrashReport] = []
        var unreadable: [String] = []

        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                unreadable.append(folder.path)
                continue
            }
            for file in files where ["ips", "crash", "panic", "diag", "spin", "hang"].contains(file.pathExtension) {
                if let report = parse(file) { reports.append(report) }
            }
        }
        return LogsInfo(reports: reports.sorted { $0.date > $1.date }, unreadableFolders: unreadable)
    }

    /// .ips files start with a one-line JSON header that names the process and the kind of report.
    private static func parse(_ url: URL) -> CrashReport? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let name = url.deletingPathExtension().lastPathComponent
        var process = fallbackProcessName(name)
        var bugType: String?
        var firstParty = false

        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 4096), let newline = data.firstIndex(of: 0x0A),
               let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any] {
                process = (header["app_name"] as? String) ?? (header["name"] as? String) ?? process
                bugType = header["bug_type"] as? String
                firstParty = (header["is_first_party"] as? Int) == 1 || ((header["bundleID"] as? String)?.hasPrefix("com.apple.") ?? false)
            }
        }

        let kind = classify(bugType: bugType, fileName: name, ext: url.pathExtension)
        if kind == .panic { process = "Kernel" }
        return CrashReport(url: url, process: process, date: modified, kind: kind, isFirstParty: firstParty)
    }

    /// "Music-2026-09-29-224212.ips" -> "Music"
    private static func fallbackProcessName(_ name: String) -> String {
        if let range = name.range(of: #"[-_]\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    private static func classify(bugType: String?, fileName: String, ext: String) -> CrashReport.Kind {
        switch bugType {
        case "309", "109": return .crash
        case "288", "328", "409": return .hang
        case "298": return .memory
        case "210", "110": return .panic
        case "145", "142", "206", "385", "202": return .resource
        default: break
        }
        let lower = fileName.lowercased()
        if lower.hasPrefix("panic") || ext == "panic" { return .panic }
        if lower.hasPrefix("jetsam") { return .memory }
        if ext == "crash" { return .crash }
        if ext == "hang" || ext == "spin" { return .hang }
        if ext == "diag" { return .resource }
        return .other
    }
}
