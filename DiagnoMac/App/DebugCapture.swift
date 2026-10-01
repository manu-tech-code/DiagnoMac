#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `DiagnoMac -captureScreens /path/to/dir` waits for the first scan, then saves a
/// PNG of the main window for every section and quits. Uses the app's own window contents, so it
/// needs no Screen Recording permission.
///
/// Optional flags:
///   -captureDelay <seconds>   wait longer before capturing (lets idle-app detection settle)
///   -captureAsk "<question>"  ask the assistant and explain the top finding first
///   -captureSpeedTest         run a speed test and capture it mid-run and when finished
@MainActor
enum DebugCapture {
    private static let args = ProcessInfo.processInfo.arguments

    private static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var outputDirectory: URL? { value("-captureScreens").map { URL(fileURLWithPath: $0, isDirectory: true) } }

    static func runIfRequested(model: AppModel) {
        guard let dir = outputDirectory else { return }
        Task {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            while model.lastScan == nil { try? await Task.sleep(for: .milliseconds(300)) }
            if let delay = value("-captureDelay").flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }

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

            for area in Area.allCases {
                model.selection = area
                try? await Task.sleep(for: .seconds(1.5))
                capture(to: dir.appending(path: "\(area.rawValue).png"))
            }
            dumpText(model: model, to: dir)
            NSApp.terminate(nil)
        }
    }

    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Writes the AI output and report as text, so they can be checked without reading screenshots.
    private static func dumpText(model: AppModel, to dir: URL) {
        var out = "AVAILABILITY: \(model.intelligence.availability)\n\n"
        for message in model.intelligence.messages {
            out += "[\(message.role)] \(message.text)\(message.error.map { " ERROR: \($0)" } ?? "")\n  read: \(message.sectionsRead)\n"
        }
        for (key, text) in model.intelligence.texts.sorted(by: { $0.key < $1.key }) {
            out += "\n[\(key)] \(text.text)\(text.error.map { " ERROR: \($0)" } ?? "")\n"
        }
        out += "\nSPEED TEST: \(model.speedTest.phase) \(String(describing: model.speedTest.result))\n"
        out += "\n\(model.reportText)\n"
        try? out.write(to: dir.appending(path: "dump.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
