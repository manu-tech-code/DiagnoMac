import Foundation

/// One release in the update window's timeline: its version, date and what
/// changed, grouped into sections ("New", "Fixes", "Improvements").
public struct ReleaseNote: Equatable, Sendable, Identifiable {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var items: [String]
        public init(title: String, items: [String]) { self.title = title; self.items = items }
    }

    public var version: String
    public var date: Date?
    /// A leading line of prose, when the notes start with one.
    public var summary: String?
    public var sections: [Section]
    public var id: String { version }

    public init(version: String, date: Date? = nil, summary: String? = nil, sections: [Section]) {
        self.version = version; self.date = date; self.summary = summary; self.sections = sections
    }
}

public enum ReleaseNotes {
    /// GitHub's releases API (`/repos/{owner}/{repo}/releases`), newest first,
    /// without drafts and pre-releases.
    public static func parseGitHubReleases(_ data: Data) -> [ReleaseNote] {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return releases.compactMap { r in
            guard r["draft"] as? Bool != true, r["prerelease"] as? Bool != true,
                  let tag = r["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            // Plain versions only: no tags like "v0.4.0-installer".
            guard version.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil else { return nil }
            let parsed = parseBody(r["body"] as? String ?? "")
            return ReleaseNote(version: version, date: (r["published_at"] as? String).flatMap(iso.date(from:)),
                               summary: parsed.summary, sections: parsed.sections)
        }
        .sorted { isNewer($0.version, than: $1.version) }
    }

    /// One release's notes, either GitHub's generated ones ("### Features" and
    /// "* Title by @someone in <link>") or hand-written markdown.
    public static func parseBody(_ markdown: String) -> (summary: String?, sections: [ReleaseNote.Section]) {
        var text = markdown
        while let start = text.range(of: "<!--"), let end = text.range(of: "-->", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var summary: String?
        var sections: [ReleaseNote.Section] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if title.lowercased() == "what's changed" || title.lowercased() == "what’s changed" { continue }
                sections.append(.init(title: sectionTitle(title), items: []))
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                guard let item = cleanItem(String(line.dropFirst(2))) else { continue }
                if sections.isEmpty { sections.append(.init(title: "Changes", items: [])) }
                sections[sections.count - 1].items.append(item)
            } else if summary == nil, sections.isEmpty, !line.hasPrefix("**Full Changelog**") {
                summary = plain(line)
            }
        }
        return (summary, sections.filter { !$0.items.isEmpty })
    }

    /// Whether dotted version `a` is newer than `b`, compared number by number.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func sectionTitle(_ title: String) -> String {
        switch title.lowercased() {
        case "features", "new", "also new": "New"
        case "fixes", "bug fixes": "Fixes"
        case "chores", "maintenance": "Improvements"
        case "other changes": "Other"
        default: plain(title)
        }
    }

    /// "Title; version 0.7.1 by @someone in https://…/pull/20" → "Title". Version
    /// bumps on their own ("Version 0.5.2") aren't news, so they're dropped.
    static func cleanItem(_ item: String) -> String? {
        var s = item
        s = s.replacingOccurrences(of: #"\s+by @[\w-]+ in https?://\S+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #";\s*version \d+(\.\d+)*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = plain(s)
        if s.range(of: #"^Version \d+(\.\d+)*( \(build \d+\))?$"#, options: .regularExpression) != nil { return nil }
        return s.isEmpty ? nil : s
    }

    /// Markdown and HTML bits that read badly as plain text.
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: #"</?kbd>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}
