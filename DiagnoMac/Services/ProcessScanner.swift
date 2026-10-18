import DiagnoCore
import Foundation
import Security

/// Looks through everything running in the background for programs that don't behave like normal software.
///
/// It reads three things for each program: where it runs from and how it was started, whether its code
/// signature checks out, and what it's talking to on the network. `ProcessTriage` weighs them.
enum ProcessScanner {
    static func scan(startupItems: [StartupItem]) async -> ProcessScanResult {
        await offMain { scanSync(startupItems: startupItems) }
    }

    private static func scanSync(startupItems: [StartupItem]) -> ProcessScanResult {
        let home = NSHomeDirectory()
        let myUID = getuid()
        let running = listProcesses()

        // The signature check is the slow part, and most processes share a program, so it's done once per file.
        let paths = Set(running.map(\.path))
        let trustByPath = LockedDictionary<String, CodeTrust>()
        let pathList = Array(paths)
        DispatchQueue.concurrentPerform(iterations: pathList.count) { index in
            trustByPath[pathList[index]] = trust(ofExecutableAt: pathList[index])
        }

        let network = networkActivity()
        let launchedBy = Dictionary(startupItems.compactMap { item in item.program.map { ($0, item.label) } },
                                    uniquingKeysWith: { first, _ in first })
        let trusted = ProcessTrustStore.paths

        var flagged: [SuspiciousProcess] = []
        var apple = 0, developers = 0, unchecked = 0
        for process in running {
            let trust = trustByPath[process.path] ?? .unsigned
            switch trust {
            case .apple: apple += 1
            case .appStore, .developerID: developers += 1
            default: unchecked += 1
            }
            if trusted.contains(process.path) { continue }
            let activity = network[process.pid]
            let facts = ProcessFacts(
                pid: process.pid, name: process.name, path: process.path, commandLine: process.command,
                isRoot: process.uid == 0, cpuPercent: process.cpu, trust: trust,
                executableDeleted: !FileManager.default.fileExists(atPath: process.path),
                listeningPorts: activity?.listening ?? [], remotePorts: activity?.remote ?? [],
                launchedBy: launchedBy[process.path])
            guard let assessment = ProcessTriage.assess(facts, home: home) else { continue }
            flagged.append(SuspiciousProcess(facts: facts, assessment: assessment, ownedByYou: process.uid == myUID))
        }
        flagged.sort { ($0.assessment.concern, $0.assessment.score) > ($1.assessment.concern, $1.assessment.score) }
        return ProcessScanResult(scannedAt: Date(), checked: running.count, fromApple: apple, fromDevelopers: developers,
                                 flagged: flagged, trustedByYou: running.filter { trusted.contains($0.path) }.count)
    }

    // MARK: Processes

    private struct Running {
        var pid: Int32
        var uid: UInt32
        var cpu: Double
        var path: String
        var name: String
        var command: String
    }

    private static func listProcesses() -> [Running] {
        let result = Shell.runSync("/bin/ps", ["-axww", "-o", "pid=,uid=,pcpu=,command="], timeout: 20)
        var out: [Running] = []
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let uid = UInt32(fields[1]), let cpu = Double(fields[2]), pid > 1 else { continue }
            let command = String(fields[3])
            guard let path = executablePath(pid: pid, command: command) else { continue }
            out.append(Running(pid: pid, uid: uid, cpu: cpu, path: path, name: URL(fileURLWithPath: path).lastPathComponent, command: command))
        }
        return out
    }

    /// What the kernel says the process was started from, which can't be faked by renaming it.
    private static func executablePath(pid: Int32, command: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        if length > 0 { return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        // Some root-owned processes can't be asked; their first word is usually the path.
        if command.hasPrefix("/") {
            let first = command.split(separator: " ", maxSplits: 1).first.map(String.init)
            if let first, FileManager.default.fileExists(atPath: first) { return first }
        }
        return nil
    }

    // MARK: Code signature

    /// Where only macOS can write, because System Integrity Protection locks it.
    private static let protectedPrefixes = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/", "/bin/", "/sbin/",
                                            "/Library/Apple/"]

    private static func trust(ofExecutableAt path: String) -> CodeTrust {
        if protectedPrefixes.contains(where: { path.hasPrefix($0) }) && FileManager.default.fileExists(atPath: path) { return .apple }
        guard FileManager.default.fileExists(atPath: path) else {
            // Gone from disk, so there's nothing to read a signature from.
            return .unsigned
        }

        // For an app, the signature belongs to the whole bundle.
        var signedPath = path
        if let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) {
            signedPath = String(path[..<range.lowerBound]) + ".app"
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: signedPath) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unsigned }

        let quick = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let status = SecStaticCodeCheckValidity(code, quick, nil)
        if status == errSecCSUnsigned { return .unsigned }
        if status != errSecSuccess { return .invalid }

        if satisfies(code, "anchor apple") { return .apple }
        if satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]") { return .appStore }

        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let details = info as? [String: Any]
        let team = details?[kSecCodeInfoTeamIdentifier as String] as? String

        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and " +
            "certificate leaf[field.1.2.840.113635.100.6.1.13]"
        if satisfies(code, developerID) { return .developerID(team: team) }

        let flags = (details?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        // kSecCodeSignatureAdhoc
        if flags & 0x2 != 0 { return .adHoc }
        return .otherCertificate
    }

    private static func satisfies(_ code: SecStaticCode, _ requirement: String) -> Bool {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), parsed) == errSecSuccess
    }

    // MARK: Network

    private struct Activity {
        var listening: [Int] = []
        var remote: [Int] = []
    }

    /// Which programs are waiting for connections from other computers, and which are talking to the
    /// internet. Only the current user's programs can be seen without administrator rights.
    private static func networkActivity() -> [Int32: Activity] {
        let result = Shell.runSync("/usr/sbin/lsof", ["-nP", "-w", "-iTCP", "-F", "pnT"], timeout: 30)
        var byPID: [Int32: Activity] = [:]
        var pid: Int32 = 0
        var address: String?
        for line in result.stdout.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = String(line.dropFirst())
            switch kind {
            case "p": pid = Int32(value) ?? 0; address = nil
            case "f": address = nil
            case "n": address = value
            case "T" where value.hasPrefix("ST="):
                guard let address else { continue }
                let state = value.dropFirst(3)
                if state == "LISTEN" {
                    if let port = reachableListeningPort(address) { byPID[pid, default: Activity()].listening.append(port) }
                } else if state == "ESTABLISHED", let port = publicRemotePort(address) {
                    byPID[pid, default: Activity()].remote.append(port)
                }
            default: break
            }
        }
        return byPID
    }

    /// "*:8080" is open to the network; "127.0.0.1:8080" is only for this Mac.
    private static func reachableListeningPort(_ address: String) -> Int? {
        let (host, port) = split(address)
        guard let port, !isLoopback(host) else { return nil }
        return port
    }

    /// "192.168.1.5:50000->93.184.216.34:443" -> 443, unless the other end is on this network.
    private static func publicRemotePort(_ address: String) -> Int? {
        let parts = address.components(separatedBy: "->")
        guard parts.count == 2 else { return nil }
        let (host, port) = split(parts[1])
        guard let port, !isPrivate(host) else { return nil }
        return port
    }

    private static func split(_ address: String) -> (String, Int?) {
        guard let colon = address.lastIndex(of: ":") else { return (address, nil) }
        return (String(address[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                Int(address[address.index(after: colon)...]))
    }

    private static func isLoopback(_ host: String) -> Bool {
        host.hasPrefix("127.") || host == "::1" || host == "localhost"
    }

    private static func isPrivate(_ host: String) -> Bool {
        if isLoopback(host) || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172."), let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) }), (16...31).contains(second) { return true }
        let lower = host.lowercased()
        return lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }

    // MARK: Actions

    static func isRunning(pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Asks the program to stop (`force` stops it without letting it clean up). A program owned by another
    /// user, such as root, needs macOS's administrator prompt.
    static func stop(pid: Int32, ownedByYou: Bool, force: Bool) async -> Bool {
        let signal = force ? SIGKILL : SIGTERM
        if ownedByYou { return kill(pid, signal) == 0 }
        return await Shell.runAsAdmin("/bin/kill -\(signal) \(pid)").succeeded
    }
}

/// A dictionary that several threads can write to at once.
private final class LockedDictionary<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private var values: [Key: Value] = [:]
    private let lock = NSLock()

    subscript(key: Key) -> Value? {
        get { lock.withLock { values[key] } }
        set { lock.withLock { values[key] = newValue } }
    }
}

/// Programs the user has looked at and decided are fine, remembered by path.
enum ProcessTrustStore {
    private static let key = "trustedProcessPaths"

    static var paths: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func trust(_ path: String) {
        UserDefaults.standard.set(Array(paths.union([path])).sorted(), forKey: key)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}
