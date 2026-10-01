import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Wraps SMAppService so the Settings toggle reflects what macOS actually has registered.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = enabled
                ? "macOS didn't add DiagnoMac to Login Items: \(error.localizedDescription)"
                : "macOS didn't remove DiagnoMac from Login Items: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum Preferences {
    /// When macOS opens DiagnoMac at login, skip the window and the Dock icon.
    static let startInMenuBarKey = "startInMenuBarAtLogin"
    static let showMenuBarIconKey = "showMenuBarIcon"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI uses the Window scene's id as the NSWindow identifier.
    static let mainWindowID = "main"

    /// True when loginwindow launched us as a login item.
    private(set) var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch Apple event says whether this is a login launch.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAtLogin = true
        }
        UserDefaults.standard.register(defaults: [Preferences.startInMenuBarKey: true, Preferences.showMenuBarIconKey: true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        // `-menuBarOnly` starts the way a login launch does, without a window (used by scripts/measure.sh).
        let menuBarOnly = ProcessInfo.processInfo.arguments.contains("-menuBarOnly")
            || (launchedAtLogin && defaults.bool(forKey: Preferences.startInMenuBarKey))
        guard menuBarOnly, defaults.bool(forKey: Preferences.showMenuBarIconKey) else { return }
        NSApp.setActivationPolicy(.accessory)
        // SwiftUI opens the main window during launch; close it once it exists.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == AppDelegate.mainWindowID {
                window.close()
            }
        }
    }

    /// Closing the window keeps DiagnoMac running in the menu bar. Without this, SwiftUI quits an
    /// app whose main scene is a single `Window` as soon as that window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Preferences.showMenuBarIconKey)
    }

    /// Clicking the Dock icon or reopening the app from Finder brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppDelegate.showMainWindow() }
        return true
    }

    /// Restores the Dock icon (if the app started in the menu bar) and shows the main window.
    @MainActor
    static func showMainWindow(using openWindow: OpenWindowAction? = nil) {
        NSApp.setActivationPolicy(.regular)
        if let openWindow {
            openWindow(id: mainWindowID)
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == mainWindowID }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
}
