import AppKit
import Foundation

/// Pulls the useful parts out of a crash report so the on-device model can explain it
/// without exceeding its context window.
enum CrashReportReader {
    static func summary(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "The report couldn't be read." }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any] else {
            return String(text.prefix(1500))
        }

        var out: [String] = []
        let name = header["app_name"] as? String ?? header["name"] as? String ?? "Unknown"
        out.append("Process: \(name) \(header["app_version"] as? String ?? "")")
        if let bundle = header["bundleID"] as? String { out.append("Bundle: \(bundle)") }
        if let os = header["os_version"] as? String { out.append("macOS: \(os)") }
        out.append("Made by Apple: \((header["is_first_party"] as? Int) == 1 ? "yes" : "no")")

        // Crash reports (bug type 309) have a JSON body with the exception and thread backtraces.
        if let body = try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any] {
            if let exception = body["exception"] as? [String: Any] {
                let parts = ["type", "signal", "subtype"].compactMap { exception[$0] as? String }
                out.append("Exception: " + parts.joined(separator: ", "))
            }
            if let termination = body["termination"] as? [String: Any] {
                let reason = [termination["namespace"], termination["indicator"]].compactMap { $0 as? String }.joined(separator: " ")
                if !reason.isEmpty { out.append("Termination: \(reason)") }
            }
            if let asi = body["asi"] as? [String: [String]], let first = asi.values.first?.first {
                out.append("App message: \(first.prefix(200))")
            }
            let images = (body["usedImages"] as? [[String: Any]])?.map { $0["name"] as? String ?? "?" } ?? []
            if let threads = body["threads"] as? [[String: Any]] {
                let crashed = threads.first { ($0["triggered"] as? Bool) == true } ?? threads.first
                let frames = (crashed?["frames"] as? [[String: Any]] ?? []).prefix(10).map { frame -> String in
                    let image = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0] : nil } ?? "?"
                    return "  \(image): \(frame["symbol"] as? String ?? "(no symbol)")"
                }
                if !frames.isEmpty { out.append("Crashed thread, top frames:\n" + frames.joined(separator: "\n")) }
            }
        } else {
            // Hang and resource reports are plain text.
            out.append(String(lines[1].prefix(1200)))
        }
        return String(out.joined(separator: "\n").prefix(2400))
    }
}

enum SystemActions {
    /// Shows macOS's own "Are you sure you want to restart?" dialog.
    @MainActor
    static func requestRestart() -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"loginwindow\" to «event aevtrrst»")?.executeAndReturnError(&error)
        return error == nil
    }
}
