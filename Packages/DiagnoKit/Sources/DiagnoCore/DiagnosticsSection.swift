import Foundation

/// The parts of the scan the assistant can read.
public enum DiagnosticsSection: String, CaseIterable, Sendable {
    case overview, battery, cpu, gpu, memory, apps, storage, backup, network, security, startup, crashes, devices

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

extension DiagnosticsSection {
    /// Picks the readings a question is about, so the model gets the right facts up front instead of
    /// relying on it to call the right tools. Empty when the question names no part of the Mac.
    public static func relevant(to question: String, limit: Int = 3) -> [DiagnosticsSection] {
        let words = QuestionWords(question)
        var picked: [DiagnosticsSection] = []
        for route in routes where route.keywords.contains(where: words.mention) {
            for section in route.sections where !picked.contains(section) { picked.append(section) }
        }
        return Array(picked.prefix(limit))
    }

    /// Whether a question is about the Mac's health as a whole, like "How is my Mac doing?" or "What should
    /// I fix?", which the overview answers. Other questions that name no part, like "How do I take a
    /// screenshot?", get no readings: the model answers them from what it knows.
    public static func isAboutOverallHealth(_ question: String) -> Bool {
        let words = QuestionWords(question)
        return [
            "overall", "health", "healthy", "score", "problem*", "issue*", "wrong", "fix*", "status", "summar*",
            "check up", "checkup", "diagnos*", "scan*", "finding*", "optimi*", "tune up", "maintenance",
            "mac doing", "mac ok", "mac okay", "mac fine",
        ].contains(where: words.mention)
    }

    /// Advice for the kind of question, like why the Mac is slow or its fan is loud, that no one part's
    /// facts cover. Kept apart from those facts so it only comes up when it's asked about.
    public static func notes(for question: String) -> [String] {
        let words = QuestionWords(question)
        return routes.filter { $0.keywords.contains(where: words.mention) }.compactMap(\.note)
    }

    private static let routes: [(keywords: [String], sections: [DiagnosticsSection], note: String?)] = [
        (["batter*", "charg*", "plug", "plugged", "plugging", "unplug*", "adapter", "power", "watt*", "cycle*", "magsafe"], [.battery], nil),
        (["slow*", "lag*", "sluggish", "performance", "speed up", "faster", "beach ball"], [.memory, .cpu],
         """
         With memory pressure normal and a light CPU load, the Mac isn't short of memory or power. Then the usual cause is \
         one busy app: name the app using the most CPU in the readings.
         """),
        (["hot", "heat*", "overheat*", "fan", "fans", "thermal", "temperature*"], [.cpu],
         """
         A loud fan while the Mac isn't overheating and the load is light means nothing is wrong: it's cooling down after \
         a burst of work, or the room is warm. Fans also speed up under heavy load and when the vents are blocked.
         """),
        (["app", "apps", "application*", "quit", "quitting", "running"], [.apps, .memory], nil),
        (["memory", "ram", "swap*"], [.memory, .apps], nil),
        (["cpu", "processor*", "process*", "windowserver", "kernel task", "load"], [.cpu], nil),
        (["gpu", "graphics", "game", "games", "gaming"], [.gpu], nil),
        (["disk*", "storage", "space", "delet*", "clean*", "free up", "cache*", "ssd", "drive"], [.storage], nil),
        (["backup*", "back up", "backed up", "time machine"], [.backup], nil),
        (["wifi", "wi fi", "internet", "network*", "router", "speed test", "ping", "latency", "connection", "online", "offline"], [.network], nil),
        (["secur*", "virus*", "malware", "spyware", "firewall", "hack*", "filevault", "encrypt*", "suspicious*", "suspect*", "trojan*", "miner*", "cryptominer*", "infect*"], [.security], nil),
        (["crash*", "freez*", "froze", "frozen", "hang*", "panic*", "quit unexpectedly"], [.crashes], nil),
        (["bluetooth", "mouse", "keyboard*", "trackpad*", "airpods", "headphone*", "accessor*", "peripheral*", "usb",
          "display", "displays", "monitor", "monitors"], [.devices], nil),
        (["startup", "start up", "login", "log in", "boot*", "background", "agent*", "launch*", "daemon*"], [.startup], nil),
    ]

    /// What the on-device model needs to know to answer common questions about this part, beyond the
    /// readings. Without it the model falls back to repeating the readings. Advice about what DiagnoMac
    /// can do lives here too, rather than in the instructions: the model brings up whatever those
    /// mention, whether or not the question is about it.
    public var facts: String? {
        switch self {
        case .overview:
            "To say how the Mac is doing overall, give the health score and the first problem listed. " + Self.commonFacts
        case .battery:
            """
            Keeping a Mac plugged in, even between 80% and 100%, is fine: it can't overcharge, and once the battery is full \
            the Mac runs on the charger's power. Unplugging at 100% isn't needed, though it does no harm, and there's no need \
            to drain the battery. Charging slows down above 80% on purpose, to protect the battery. Optimized Battery Charging, \
            on by default, learns the owner's routine and waits at 80% when the Mac will stay plugged in for a long time. \
            To check it, open System Settings → Battery, click the info button next to Battery Health and turn on \
            Optimized Battery Charging. Heat wears batteries most, so avoid charging somewhere hot.
            """
        case .memory:
            """
            Memory pressure normal means the Mac has enough memory, even when apps use a lot of it: macOS puts spare memory \
            to work, and an app's memory use only matters when the pressure is elevated or critical. To free memory, quit idle apps, close browser tabs or restart; deleting caches or files doesn't free memory. \
            Swap is memory kept on the SSD when RAM is full. Only apps marked idle are safe to quit, and DiagnoMac's \
            Running Apps page can quit them.
            """
        case .apps:
            """
            Recommend quitting only apps listed as idle. Any app can be quit, but apps in use may have unsaved work. \
            DiagnoMac's Running Apps page can quit them.
            """
        case .storage:
            """
            Does deleting caches make a Mac faster? No, not unless its disk is nearly full: it only frees disk space, and \
            apps rebuild their caches as they need them. DiagnoMac's Storage page can clean up the cleanup candidates.
            """
        case .cpu:
            """
            WindowServer is the part of macOS that draws the screen. It uses more CPU with more open windows, external displays, \
            animation and transparency, and it can't be quit; closing unused windows and turning on Reduce Transparency \
            (System Settings → Accessibility → Display) lower it. kernel_task using CPU is macOS keeping the Mac cool.
            """
        case .network:
            "A weak Wi-Fi signal gets better closer to the router. A slow ping or lost packets make calls and games lag."
        case .crashes:
            """
            Crashes in macOS's own processes are fixed by macOS updates, not by the owner. An app that keeps crashing is worth \
            updating or reinstalling.
            """
        case .backup:
            """
            Time Machine needs an external or network disk, and is set up in System Settings → General → Time Machine. \
            Without a backup, files are lost if the Mac breaks or is lost.
            """
        case .security:
            """
            If the firewall is off, DiagnoMac's Security page can turn it on. The same page scans background programs for ones \
            that look suspicious: running from a temporary or hidden folder, pretending to be part of macOS, or mining cryptocurrency. \
            A flagged program is a hint, not proof, so say it's worth checking rather than that it's a virus.
            """
        case .startup:
            """
            DiagnoMac's Startup Items page can turn a startup item off. That can be undone, and the app it belongs to \
            still works when opened by hand.
            """
        case .gpu, .devices:
            nil
        }
    }

    /// The facts any part of a scan can touch: memory, disk space, crashes and backups.
    public static var commonFacts: String {
        [DiagnosticsSection.memory, .storage, .crashes, .backup].compactMap(\.facts).joined(separator: " ")
    }
}

/// The words of a question, for matching keywords and names against it.
public struct QuestionWords: Sendable {
    private let words: [String]
    private let text: String

    public init(_ question: String) {
        words = Self.split(question)
        text = " " + words.joined(separator: " ") + " "
    }

    /// A single word matches a whole word, and with a trailing `*` the start of one ("charg*" matches
    /// "charging"). Several words, like "time machine" or an app's name, match whole words in order.
    public func mention(_ keyword: String) -> Bool {
        let isPrefix = keyword.hasSuffix("*")
        let parts = Self.split(isPrefix ? String(keyword.dropLast()) : keyword)
        guard let first = parts.first else { return false }
        if parts.count > 1 { return text.contains(" " + parts.joined(separator: " ") + " ") }
        return isPrefix ? words.contains { $0.hasPrefix(first) } : words.contains(first)
    }

    private static func split(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
