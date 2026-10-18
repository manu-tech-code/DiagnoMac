import Foundation

/// Who vouches for a program, from its code signature.
public enum CodeTrust: Equatable, Sendable {
    /// Signed by Apple.
    case apple
    /// From the Mac App Store.
    case appStore
    /// A registered developer, with Apple's notarization check behind it.
    case developerID(team: String?)
    /// Signed with some other certificate, such as a developer's own build.
    case otherCertificate
    /// A signature anyone can make for themselves, with no identity behind it.
    case adHoc
    /// No signature at all.
    case unsigned
    /// Signed, but the file has been changed since.
    case invalid

    /// Whether a real identity stands behind it.
    public var isVouchedFor: Bool {
        switch self {
        case .apple, .appStore, .developerID: true
        case .otherCertificate, .adHoc, .unsigned, .invalid: false
        }
    }
}

/// What the scan could find out about one running program.
public struct ProcessFacts: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// The executable on disk.
    public var path: String
    /// The program and its arguments, as it was started.
    public var commandLine: String
    public var isRoot: Bool
    public var cpuPercent: Double
    public var trust: CodeTrust
    /// The file the process was started from is gone.
    public var executableDeleted: Bool
    /// Listening for connections from other computers, on these ports.
    public var listeningPorts: [Int]
    /// Remote ports of connections to other computers.
    public var remotePorts: [Int]
    /// Started by a launch agent or daemon, which restarts it.
    public var launchedBy: String?

    public init(pid: Int32, name: String, path: String, commandLine: String = "", isRoot: Bool = false, cpuPercent: Double = 0,
                trust: CodeTrust, executableDeleted: Bool = false, listeningPorts: [Int] = [], remotePorts: [Int] = [],
                launchedBy: String? = nil) {
        self.pid = pid
        self.name = name
        self.path = path
        self.commandLine = commandLine
        self.isRoot = isRoot
        self.cpuPercent = cpuPercent
        self.trust = trust
        self.executableDeleted = executableDeleted
        self.listeningPorts = listeningPorts
        self.remotePorts = remotePorts
        self.launchedBy = launchedBy
    }
}

/// One thing about a process that doesn't look right, in words anyone can follow.
public struct ProcessSignal: Equatable, Sendable {
    public var weight: Int
    public var text: String
}

public enum ProcessConcern: Int, Comparable, Sendable {
    /// Unusual, and worth a look.
    case worthChecking
    /// Several things that normal software doesn't do.
    case suspicious

    public static func < (a: ProcessConcern, b: ProcessConcern) -> Bool { a.rawValue < b.rawValue }
}

public struct ProcessAssessment: Equatable, Sendable {
    public var concern: ProcessConcern
    public var score: Int
    public var signals: [ProcessSignal]
}

/// Decides whether a running program is worth a closer look. These are hints rather than proof: a
/// program is only flagged for things that malware does and ordinary software almost never does.
public enum ProcessTriage {
    public static let suspiciousScore = 80
    public static let worthCheckingScore = 35

    /// Where macOS keeps its own programs. System Integrity Protection stops anything else writing here.
    static let systemPrefixes = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/", "/usr/standalone/",
                                 "/bin/", "/sbin/", "/Library/Apple/", "/Library/Developer/CommandLineTools/",
                                 "/Applications/Xcode.app/", "/Applications/Safari.app/"]

    /// Names that only macOS's own programs go by.
    static let systemNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer", "mds", "mds_stores",
        "mdworker", "mdworker_shared", "syslogd", "configd", "notifyd", "distnoted", "cfprefsd", "opendirectoryd", "securityd",
        "trustd", "coreaudiod", "bluetoothd", "airportd", "sshd", "diskarbitrationd", "fseventsd", "powerd", "logd",
        "UserEventAgent", "coreservicesd", "launchservicesd", "tccd", "amfid", "syspolicyd", "endpointsecurityd",
    ]

    /// Programs that mine cryptocurrency, which is the usual reason for a Mac that's busy for no reason.
    static let minerNames = ["xmrig", "xmr-stak", "minerd", "cpuminer", "cgminer", "bfgminer", "ethminer", "nanominer",
                             "nbminer", "t-rex", "lolminer", "phoenixminer", "kdevtmpfsi", "kinsing", "randomx", "monero"]

    /// Remote ports that mining pools and remote-control tools are known for.
    static let poolPorts: Set<Int> = [3333, 4444, 5555, 7777, 14444, 14433, 45560, 45700]
    static let backdoorPorts: Set<Int> = [1337, 31337, 12345, 6667, 6697, 2222, 9999]

    /// Folders under the home folder that tools like Homebrew, Rust and Node put their programs in.
    static let developerFolders = [".cargo", ".rustup", ".nvm", ".pyenv", ".rbenv", ".bun", ".volta", ".npm", ".deno", ".docker",
                                   ".vscode", ".cursor", ".local", ".orbstack", ".colima", ".lima", ".gradle", ".sdkman",
                                   ".asdf", ".mise", ".fnm", ".ollama", ".claude", ".codex", ".antigravity", ".pnpm", ".yarn",
                                   ".cache", ".config", ".nix-profile", ".swiftpm", ".conda", ".virtualenvs", ".pyenv"]

    static let interpreters: Set<String> = ["python", "python3", "node", "ruby", "perl", "bash", "sh", "zsh", "osascript", "php", "lua"]

    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "jpg", "jpeg", "png",
                                                  "gif", "mp3", "mp4", "heic", "csv", "pages", "numbers", "key"]

    public static func assess(_ p: ProcessFacts, home: String) -> ProcessAssessment? {
        // Apple's own signature is the one thing a program can't fake, so nothing else is looked at.
        if p.trust == .apple { return nil }

        var signals: [ProcessSignal] = []
        func add(_ weight: Int, _ text: String) { signals.append(ProcessSignal(weight: weight, text: text)) }

        let inSystemFolder = systemPrefixes.contains { p.path.hasPrefix($0) }
        let lowerName = p.name.lowercased()
        let lowerCommand = p.commandLine.lowercased()

        // Pretending to be part of macOS.
        if !inSystemFolder && (systemNames.contains(p.name) || lowerName.hasPrefix("com.apple.")) {
            add(90, "It's named “\(p.name)”, like part of macOS, but it isn't one of Apple's programs.")
        }

        // By the program's own name, or by the pool address and donation flag every miner is started with.
        let fileName = URL(fileURLWithPath: p.path).lastPathComponent.lowercased()
        let startedLikeAMiner = lowerCommand.contains("stratum+tcp://") || lowerCommand.contains("stratum+ssl://") ||
            lowerCommand.contains("--donate-level")
        if minerNames.contains(where: { lowerName.contains($0) || fileName.contains($0) }) || startedLikeAMiner {
            add(80, "It looks like a cryptocurrency miner, which uses your Mac's power to earn money for someone else.")
        }

        switch p.trust {
        case .invalid:
            add(80, "Its code signature is broken, which means the file was changed after it was signed.")
        case .unsigned:
            add(30, "It isn't signed by anyone, so nobody has vouched for it.")
        case .adHoc:
            // Programs built on the Mac itself are signed this way, so this alone says little.
            add(10, "It carries only a self-made signature, with no developer behind it.")
        case .otherCertificate, .appStore, .developerID, .apple:
            break
        }

        if p.executableDeleted && !inSystemFolder {
            add(50, "The file it was started from has been deleted, so it's running from memory only.")
        }

        let vouched = p.trust.isVouchedFor
        let location = place(of: p.path, home: home)
        if let location {
            // An installer from a developer can run from a temporary folder, so it counts for less.
            add(vouched ? 10 : location.weight, location.text)
        }

        let script = scriptPath(of: p)
        if let script, let scriptPlace = place(of: script, home: home), scriptPlace.weight >= 25 {
            add(scriptPlace.weight + 10, "It's running a script from there: \(URL(fileURLWithPath: script).lastPathComponent).")
        }

        let ext = URL(fileURLWithPath: p.path).pathExtension.lowercased()
        if documentExtensions.contains(ext) {
            add(60, "The program is named like a document (“.\(ext)”), a trick that makes a program look harmless.")
        }

        if let pattern = commandLinePattern(lowerCommand) {
            add(60, pattern)
        }

        if !vouched {
            if p.cpuPercent >= 70 {
                add(25, "It's using \(Int(p.cpuPercent))% of a processor core without anyone having opened it.")
            }
            if let port = p.remotePorts.first(where: { poolPorts.contains($0) }) {
                add(30, "It's talking to port \(port) on another computer, which cryptocurrency miners commonly use.")
            } else if let port = p.remotePorts.first(where: { backdoorPorts.contains($0) }) {
                add(30, "It's talking to port \(port) on another computer, which remote-control tools commonly use.")
            }
            if let port = p.listeningPorts.first {
                add(20, "It's waiting for other computers to connect, on port \(port).")
            }
            if p.isRoot, let location, location.weight >= 25 {
                add(20, "It has full control of the Mac, and it's running from a folder anyone can write to.")
            }
        }

        if let label = p.launchedBy, !signals.isEmpty, !vouched {
            add(20, "It starts itself every time you log in (“\(label)”) and restarts if it's closed.")
        }

        let score = signals.reduce(0) { $0 + $1.weight }
        guard score >= worthCheckingScore else { return nil }
        return ProcessAssessment(concern: score >= suspiciousScore ? .suspicious : .worthChecking,
                                 score: score, signals: signals.sorted { $0.weight > $1.weight })
    }

    // MARK: Where it runs from

    private static func place(of path: String, home: String) -> ProcessSignal? {
        let temporary = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/dev/shm/"]
        if temporary.contains(where: { path.hasPrefix($0) }) || path.contains("/private/var/folders/") && path.contains("/T/") {
            return ProcessSignal(weight: 30, text: "It's running from a temporary folder, where installed software doesn't normally live.")
        }
        if path.hasPrefix("/Users/Shared/") {
            return ProcessSignal(weight: 30, text: "It's running from the Shared folder, which any user can write to.")
        }
        if path.hasPrefix("/Volumes/") && !path.hasPrefix("/Volumes/Macintosh HD") {
            return ProcessSignal(weight: 15, text: "It's running from an external drive or a mounted disk image.")
        }
        let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : nil
        if let relative {
            let parts = relative.split(separator: "/").map(String.init)
            if let hidden = parts.first(where: { $0.hasPrefix(".") }) {
                let isDeveloperFolder = parts.first.map { developerFolders.contains($0) } ?? false
                if !isDeveloperFolder && hidden != ".Trash" {
                    return ProcessSignal(weight: 30, text: "It's running from a hidden folder or file (“\(hidden)”), which software only does to stay out of sight.")
                }
            }
            if parts.first == "Downloads" {
                return ProcessSignal(weight: 20, text: "It's running straight from your Downloads folder, so it was never installed.")
            }
            if parts.first == "Library", parts.dropFirst().first == "Caches" {
                return ProcessSignal(weight: 25, text: "It's running from a cache folder, which holds temporary data rather than programs.")
            }
        }
        return nil
    }

    /// For an interpreter such as Python or bash, the script it was given: that's the real program.
    static func scriptPath(of p: ProcessFacts) -> String? {
        guard interpreters.contains(URL(fileURLWithPath: p.path).lastPathComponent.trimmingCharacters(in: .decimalDigits.union(.punctuationCharacters))) ||
                interpreters.contains(p.name) else { return nil }
        let arguments = p.commandLine.split(separator: " ", omittingEmptySubsequences: true).dropFirst()
        return arguments.first { $0.hasPrefix("/") }.map(String.init)
    }

    /// Command lines that download and run something unseen, or hand a shell to a stranger.
    static func commandLinePattern(_ command: String) -> String? {
        let pipesToShell = (command.contains("curl ") || command.contains("wget ")) && (command.contains("| sh") || command.contains("|sh") ||
                                                                                     command.contains("| bash") || command.contains("|bash"))
        if pipesToShell { return "It downloads something from the internet and runs it without saving it first." }
        if command.contains("base64") && (command.contains("| sh") || command.contains("|sh") || command.contains("| bash") ||
                                          command.contains("|bash") || command.contains("-d |") || command.contains("--decode |")) {
            return "It runs a hidden command that has been disguised so it can't be read."
        }
        if command.contains("/dev/tcp/") || command.contains("/dev/udp/") || command.contains("bash -i >&") {
            return "It opens a shell that someone on another computer can type into."
        }
        if (command.contains("nc ") || command.contains("ncat ") || command.contains("netcat ")) && (command.contains(" -e ") || command.contains(" -c ")) {
            return "It hands a shell to another computer, which is how remote takeovers work."
        }
        if command.contains("python") && command.contains("socket") && command.contains("subprocess") && command.contains(" -c ") {
            return "A one-line Python command connects out to another computer and runs what it's told."
        }
        if command.contains("osascript") && command.contains("do shell script") && command.contains("administrator privileges") {
            return "A script is asking macOS for administrator rights without showing you an app."
        }
        return nil
    }
}
