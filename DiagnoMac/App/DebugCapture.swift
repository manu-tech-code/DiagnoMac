#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `DiagnoMac -captureScreens /path/to/dir` waits for the first scan, then saves a
/// PNG of the main window for every section and quits. Uses the app's own window contents, so it
/// needs no Screen Recording permission.
@MainActor
enum DebugCapture {
    static var outputDirectory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-captureScreens"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func runIfRequested(model: AppModel) {
        guard let dir = outputDirectory else { return }
        Task {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            while model.lastScan == nil { try? await Task.sleep(for: .milliseconds(300)) }
            for area in Area.allCases {
                model.selection = area
                try? await Task.sleep(for: .seconds(1.5))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
                      let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(area.rawValue).png"))
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
