import Foundation

enum StartupCollector {
    static func collect() async -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders: [(URL, StartupItem.Scope)] = [
            (home.appending(path: "Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]

        async let loadedLabels = loadedUserLabels()
        async let disabledLabels = disabledUserLabels()

        var items: [StartupItem] = []
        for (folder, scope) in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "plist" {
                guard let plist = NSDictionary(contentsOf: file) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? file.deletingPathExtension().lastPathComponent
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
                items.append(StartupItem(url: file, label: label, scope: scope, program: program,
                                         runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                                         isLoaded: nil, isDisabled: plist["Disabled"] as? Bool ?? false))
            }
        }

        let loaded = await loadedLabels
        let disabled = await disabledLabels
        for index in items.indices where items[index].scope == .userAgent {
            items[index].isLoaded = loaded.contains(items[index].label)
            if disabled.contains(items[index].label) { items[index].isDisabled = true }
        }
        return items.sorted { ($0.scope.rawValue, $0.label) < ($1.scope.rawValue, $1.label) }
    }

    private static func loadedUserLabels() async -> Set<String> {
        let result = await Shell.run("/bin/launchctl", ["list"])
        return Set(result.stdout.split(separator: "\n").dropFirst().compactMap { line in
            line.split(separator: "\t").last.map(String.init)
        })
    }

    /// Labels the user has switched off with `launchctl disable`.
    private static func disabledUserLabels() async -> Set<String> {
        let result = await Shell.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])
        var labels = Set<String>()
        for line in result.stdout.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let quoted = line.split(separator: "\"").dropFirst().first { labels.insert(String(quoted)) }
        }
        return labels
    }

    /// Turns a user agent on or off. The plist file stays in place so it can be re-enabled.
    static func setEnabled(_ enabled: Bool, item: StartupItem) async -> Result<Void, StartupError> {
        guard item.canToggleWithoutAdmin else { return .failure(.needsAdmin) }
        let domain = "gui/\(getuid())"
        if enabled {
            _ = await Shell.run("/bin/launchctl", ["enable", "\(domain)/\(item.label)"])
            let boot = await Shell.run("/bin/launchctl", ["bootstrap", domain, item.url.path])
            // Status 5 / 37 means it was already loaded, which is fine.
            if !boot.succeeded && ![5, 37].contains(boot.status) { return .failure(.launchctl(boot.stderr)) }
        } else {
            let disable = await Shell.run("/bin/launchctl", ["disable", "\(domain)/\(item.label)"])
            guard disable.succeeded else { return .failure(.launchctl(disable.stderr)) }
            _ = await Shell.run("/bin/launchctl", ["bootout", domain, item.url.path])
        }
        return .success(())
    }

    enum StartupError: Error, LocalizedError {
        case needsAdmin
        case launchctl(String)

        var errorDescription: String? {
            switch self {
            case .needsAdmin: "System-wide items need an administrator. Remove them from the app that installed them."
            case .launchctl(let message): message.isEmpty ? "launchctl refused the change." : message
            }
        }
    }
}
