#if DEBUG
import AppKit
import DiagnoCore
import SwiftUI

/// Debug-only: `DiagnoMac -captureScreens /path/to/dir` waits for the first scan, then saves a
/// PNG of the main window for every section and quits. Uses the app's own window contents, so it
/// needs no Screen Recording permission.
///
/// Optional flags:
///   -captureDelay <seconds>   wait longer before capturing (lets idle-app detection settle)
///   -captureAsk "<question>"  ask the assistant and explain the top finding first
///   -captureSpeedTest         run a speed test and capture it mid-run and when finished
///   -capturePowerHistory      fill the Battery page's power chart with made-up readings, with a gap
///   -captureMenuBarPanel      capture the menu bar panel's contents as menubar.png
///   -captureStorageBreakdown  measure what's using the disk first, and wait for it
///   -appsFilter <name>          open Running Apps with that filter selected (All, With Windows, Menu Bar & Background, Idle)
///   -browseStorage <category> [-browseFolder <path>]   open the Storage page's browser there
///   -captureCleaningOverlay   capture the Cleaning mode countdown screen as cleaning.png, without starting it
///   -testCleaning <seconds> -testCleaningFile <file> [-testCleaningPost]   start Cleaning mode for a few seconds, and
///                             with -testCleaningPost send it test input and hold Esc; results go to the file
@MainActor
enum DebugCapture {
    private static let args = ProcessInfo.processInfo.arguments

    private static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var outputDirectory: URL? { value("-captureScreens").map { URL(fileURLWithPath: $0, isDirectory: true) } }

    static func runIfRequested(model: AppModel) {
        // `-checkBinRules <file>`: which sample paths can go to the Bin, written to the file, then quit.
        if let path = value("-checkBinRules") {
            let home = NSHomeDirectory()
            typealias Sample = (path: String, kind: StorageCategory.Kind)
            let inHome: [Sample] = [
                ("Library/Keychains", .appData), ("Library/Preferences/com.example.plist", .appData),
                ("Library/Caches", .appData), ("Library/Caches/com.spotify.client", .appData),
                ("Library/Application Support/Claude", .appData), ("Library/Application Support/AddressBook", .appData),
                ("Library/Group Containers/group.com.apple.notes", .appData), ("Library/Containers/com.docker.docker", .appData),
                ("Library/Developer/Xcode", .developer), ("Library/Developer/Xcode/Archives", .developer),
                ("Library/Developer/Xcode/DerivedData", .developer), ("Library/Developer/CoreSimulator", .developer),
                (".ssh", .developer), (".ssh/id_ed25519", .developer), (".zshrc", .developer),
                (".cache", .developer), (".cache/huggingface", .developer),
                ("Models", .otherFiles), ("Models/Qwen3.8-Flash-Next-FP8", .otherFiles),
                ("Music/Music", .music), ("Music/Music/Media.localized", .music),
                ("Pictures/Photos Library.photoslibrary", .photos), ("Downloads/pycharm-2026.2.3-aarch64.dmg", .downloads),
            ]
            let elsewhere: [Sample] = [
                ("/Applications/Xcode.app", .applications), ("/Applications/Safari.app", .applications),
                ("/Applications/Utilities", .applications), ("/Library/Developer/CommandLineTools", .developer),
            ]
            var samples: [Sample] = []
            for sample in inHome { samples.append((home + "/" + sample.path, sample.kind)) }
            samples += elsewhere
            var out: [String] = []
            for sample in samples {
                let verdict = StorageBreakdownCollector.debugCanMoveToBin(sample.path, sample.kind) ? "CAN GO " : "LOCKED "
                out.append(verdict + " " + sample.path.replacingOccurrences(of: home, with: "~"))
            }
            try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)  // Still launching, so NSApp.terminate wouldn't take yet.
        }
        // `-showUpdateFound <version>`: the sidebar's update button as if a check had found that version.
        if let version = value("-showUpdateFound") { model.updates.debugFound(version) }
        // `-testCleaning`: Cleaning mode end to end, if macOS has already allowed DiagnoMac.
        if let seconds = value("-testCleaning").flatMap(Double.init), let file = value("-testCleaningFile") {
            Task { await testCleaning(model: model, seconds: seconds, post: args.contains("-testCleaningPost"), file: file) }
            return
        }
        // `-captureNow <png>`: after -captureDelay seconds (8 by default), save the window as it is, then quit.
        // Quicker than -captureScreens when one page is enough, like the Storage browser with -browseStorage.
        if let file = value("-captureNow") {
            Task {
                try? await Task.sleep(for: .seconds(value("-captureDelay").flatMap(Double.init) ?? 8))
                capture(to: URL(fileURLWithPath: file))
                if !FileManager.default.fileExists(atPath: file) {
                    // Say why there's no picture.
                    let main = NSApp.windows.first { $0.identifier?.rawValue == AppDelegate.mainWindowID }
                    let note = "main window: " + (main.map { "visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none")
                    try? note.write(toFile: file + ".txt", atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
            return
        }
        // `-dumpWindows <file>`: after 6 seconds, write the windows and activation policy, then quit.
        if let path = value("-dumpWindows") {
            Task {
                try? await Task.sleep(for: .seconds(6))
                var out = "policy=\(NSApp.activationPolicy().rawValue) modelWindowVisible=\(model.isWindowVisible) selection=\(model.selection?.rawValue ?? "nil")\n"
                for w in NSApp.windows where w.frame.width > 100 {
                    out += "id=\(w.identifier?.rawValue ?? "nil") visible=\(w.isVisible) onscreen=\(w.occlusionState.contains(.visible)) \(Int(w.frame.width))x\(Int(w.frame.height))\n"
                }
                try? out.write(toFile: path, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        // `-askEach <questions.txt>`: after the first scan, asks the assistant each line in a new conversation
        // (a line starting with "+" follows up in the same one), writes each answer and the readings it used
        // to <questions.txt>.answers, then quits. Lines starting with "#" are skipped. Add -captureDelay to let
        // idle-app detection settle first.
        if let path = value("-askEach") {
            Task {
                while model.lastScan == nil { try? await Task.sleep(for: .milliseconds(300)) }
                if let delay = value("-captureDelay").flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }
                let ai = model.intelligence
                ai.checkAvailabilityIfNeeded()
                let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                var out = "AVAILABILITY: \(ai.availability)\n\n"
                for line in lines {
                    let followUp = line.hasPrefix("+")
                    let question = followUp ? line.dropFirst().trimmingCharacters(in: .whitespaces) : line
                    if !followUp { ai.resetChat() }
                    let start = Date.now
                    ai.send(question)
                    while ai.isResponding { try? await Task.sleep(for: .milliseconds(200)) }
                    let answer = ai.messages.last
                    out += "\(followUp ? "+ " : "")Q: \(question)\n"
                    out += "READ: \(answer?.sectionsRead.joined(separator: ", ") ?? "") (\(Int(Date.now.timeIntervalSince(start))) s)\n"
                    out += "A: \(answer?.text ?? "")\(answer?.error.map { "\nERROR: \($0)" } ?? "")\n\n"
                }
                // The readings the answers drew on, to check them against.
                out += "READINGS\n"
                for section in DiagnosticsSection.allCases {
                    out += "[\(section.title)]\n\(DiagnosticsDescriber.describe(section, model.snapshot.value, findings: model.findings))\n\n"
                }
                try? out.write(toFile: path + ".answers", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        guard let dir = outputDirectory else { return }
        Task {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            while model.lastScan == nil { try? await Task.sleep(for: .milliseconds(300)) }
            for w in NSApp.windows where w.frame.width > 200 {
                NSLog("DiagnoMac capture: window id=%@ visible=%d", w.identifier?.rawValue ?? "nil", w.isVisible ? 1 : 0)
            }
            if let delay = value("-captureDelay").flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }
            if args.contains("-capturePowerHistory") { model.powerHistory = madeUpPowerHistory() }

            if let question = value("-captureAsk") {
                model.intelligence.send(question)
                if let first = model.findings.first { model.explain(first) }
                if let item = model.snapshot.startup?.first(where: { $0.label.contains("mlx") }) ?? model.snapshot.startup?.first {
                    model.explain(item)
                }
                if let group = model.snapshot.logs?.groups(since: Date().addingTimeInterval(-7 * 86_400)).first {
                    model.explain(group)
                }
            }

            if args.contains("-captureStorageBreakdown") {
                let start = Date.now
                model.measureStorage()
                while model.storageProgress != nil { try? await Task.sleep(for: .seconds(1)) }
                NSLog("DiagnoMac capture: storage measured in %.0f s", Date.now.timeIntervalSince(start))
            }

            if args.contains("-captureCleaningOverlay") {
                model.cleaning.debugPreview(secondsLeft: 107)
                let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
                let window = NSWindow(contentViewController: NSHostingController(rootView: CleaningOverlayView(mode: model.cleaning)))
                window.setFrame(NSRect(x: 0, y: 0, width: screen.width * 0.6, height: screen.height * 0.6), display: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(2))
                capture(window, to: dir.appending(path: "cleaning.png"))
                model.cleaning.debugPreview(secondsLeft: 107, holding: 0.55)
                try? await Task.sleep(for: .seconds(1))
                capture(window, to: dir.appending(path: "cleaning-holding.png"))
                window.close()
            }

            if args.contains("-captureMenuBarPanel") {
                // In an ordinary window: SwiftUI's menu bar icon only opens its panel on a real click.
                let panel = NSWindow(contentViewController: NSHostingController(rootView: MenuBarView().environment(model)))
                panel.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(2))
                capture(panel, to: dir.appending(path: "menubar.png"))
                panel.close()
            }

            if args.contains("-captureSpeedTest") {
                model.selection = .network
                model.runSpeedTest()
                try? await Task.sleep(for: .seconds(9))
                capture(to: dir.appending(path: "network-live.png"))
                for _ in 0..<60 where model.speedTest.isRunning { try? await Task.sleep(for: .seconds(1)) }
                try? await Task.sleep(for: .seconds(1))
                capture(to: dir.appending(path: "network-done.png"))
            }

            // Let any AI answers finish streaming.
            for _ in 0..<90 {
                let busy = model.intelligence.isResponding || model.intelligence.texts.values.contains(where: \.isStreaming)
                if !busy { break }
                try? await Task.sleep(for: .seconds(1))
            }

            if args.contains("-captureUpdateWindow") {
                model.updates.debugWindow(.found, version: value("-captureUpdateVersion") ?? "0.2.0")
                try? await Task.sleep(for: .seconds(4))
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "update" }), let view = window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "update-window.png"))
                    window.close()
                }
            }

            for area in Area.allCases {
                model.selection = area
                try? await Task.sleep(for: .seconds(1.5))
                capture(to: dir.appending(path: "\(area.rawValue).png"))
            }
            dumpText(model: model, to: dir)
            NSApp.terminate(nil)
        }
    }

    /// Ten minutes of readings: every 10 seconds in the background, four minutes asleep, then every
    /// 2 seconds with the Battery page open.
    private static func madeUpPowerHistory() -> [PowerSample] {
        let now = Date()
        let secondsAgo = Array(stride(from: 590.0, to: 360, by: -10)) + Array(stride(from: 120.0, to: 0, by: -2))
        return secondsAgo.map { ago in
            let system = 10 + 3 * cos(ago / 15)
            let battery = 28 + 4 * sin(ago / 25)
            return PowerSample(date: now.addingTimeInterval(-ago), input: battery + system + 3, battery: battery, system: system)
        }
    }

    private static func testCleaning(model: AppModel, seconds: Double, post: Bool, file: String) async {
        try? await Task.sleep(for: .seconds(4))
        let mode = model.cleaning
        mode.refreshPermission()
        var out = "trusted=\(mode.isTrusted)\n"
        func finish() { try? out.write(toFile: file, atomically: true, encoding: .utf8); NSApp.terminate(nil) }
        // 0 seconds only reports whether macOS has allowed it, without turning anything off.
        guard mode.isTrusted, seconds > 0 else { finish(); return }

        let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let startedAt = Date()
        mode.start(for: seconds)
        out += "active=\(mode.isActive) tap=\(mode.tapLocation) failure=\(mode.failure ?? "none")\n"
        guard mode.isActive else { finish(); return }

        if post {
            try? await Task.sleep(for: .seconds(1))
            let cursorBefore = NSEvent.mouseLocation
            let swallowedBefore = mode.swallowed
            let source = CGEventSource(stateID: .hidSystemState)
            var posted = 0
            func send(_ event: CGEvent?) { event?.post(tap: .cghidEventTap); posted += 1 }
            for code: CGKeyCode in [7, 8] {  // x, c
                send(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true))
                send(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false))
            }
            let tab = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: true)  // Command-Tab, the app switcher
            tab?.flags = .maskCommand
            send(tab)
            send(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left))
            send(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left))
            send(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left))
            send(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0))
            try? await Task.sleep(for: .seconds(1))
            out += "posted=\(posted) swallowed=\(mode.swallowed - swallowedBefore) leakedToWindow=\(mode.leaked)\n"
            out += "cursor moved=\(NSEvent.mouseLocation != cursorBefore) frontmost before=\(frontBefore) after=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n"

            // Holding Esc ends it after \(CleaningMode.holdSeconds) seconds.
            let heldAt = Date()
            send(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true))
            while mode.isActive && Date().timeIntervalSince(heldAt) < 8 { try? await Task.sleep(for: .milliseconds(100)) }
            out += "esc hold ended it: \(!mode.isActive) after \(String(format: "%.1f", Date().timeIntervalSince(heldAt))) s\n"
            send(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false))
        }
        while mode.isActive { try? await Task.sleep(for: .milliseconds(200)) }
        out += "ended after \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s; banner: \(model.banner ?? "none")\n"
        finish()
    }

    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppDelegate.mainWindowID && $0.isVisible }) else { return }
        capture(window, to: url)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Writes the AI output and report as text, so they can be checked without reading screenshots.
    private static func dumpText(model: AppModel, to dir: URL) {
        var out = "AVAILABILITY: \(model.intelligence.availability)\n"
        out += "POLICY: \(NSApp.activationPolicy().rawValue) WINDOW VISIBLE (model): \(model.isWindowVisible)\n"
        for w in NSApp.windows { out += "WINDOW id=\(w.identifier?.rawValue ?? "nil") visible=\(w.isVisible) frame=\(Int(w.frame.width))x\(Int(w.frame.height))\n" }
        out += "ARGS: \(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))\n\n"
        for message in model.intelligence.messages {
            out += "[\(message.role)] \(message.text)\(message.error.map { " ERROR: \($0)" } ?? "")\n  read: \(message.sectionsRead)\n"
        }
        for (key, text) in model.intelligence.texts.sorted(by: { $0.key < $1.key }) {
            out += "\n[\(key)] \(text.text)\(text.error.map { " ERROR: \($0)" } ?? "")\n"
        }
        out += "\nSPEED TEST: \(model.speedTest.phase) \(String(describing: model.speedTest.result))\n"
        if let breakdown = model.snapshot.storageBreakdown {
            out += "\nSTORAGE (complete: \(breakdown.isComplete), needs access: \(breakdown.needsAccess.map(\.rawValue)))\n"
            for category in breakdown.categories {
                out += "\(category.kind.title): \(Format.bytes(category.bytes))  " + category.items.prefix(4).map { "\($0.name) \(Format.bytes($0.bytes))" }.joined(separator: ", ") + "\n"
            }
            for suggestion in breakdown.suggestions {
                out += "SUGGEST \(suggestion.item.name) \(Format.bytes(suggestion.item.bytes)) [\(suggestion.kind.rawValue)]: \(suggestion.reason)\n"
            }
        }
        out += "\n\(model.reportText)\n"
        try? out.write(to: dir.appending(path: "dump.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
