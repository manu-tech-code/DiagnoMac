import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// Cleaning mode: the keyboard, trackpad and any mouse are turned off while you wipe the Mac down.
///
/// An event tap swallows every input event before apps see it, and a dark full-screen window with a
/// countdown covers every display. It ends when the countdown does, when Esc has been held for 3 seconds,
/// or when the Mac goes to sleep. The power button isn't an input event, so it always works, and the tap
/// belongs to this process, so quitting or crashing DiagnoMac turns everything back on.
@MainActor
@Observable
final class CleaningMode {
    enum EndReason {
        case finished, heldEsc, sleep, quit

        var message: String {
            switch self {
            case .finished: "Cleaning mode finished. Your keyboard and trackpad are back on."
            case .heldEsc: "Cleaning mode stopped. Your keyboard and trackpad are back on."
            case .sleep: "Cleaning mode ended because the Mac went to sleep."
            case .quit: ""
            }
        }
    }

    /// How long Esc is held to stop it early.
    static let holdSeconds = 3.0
    static let choices = [1, 2, 3, 5]

    private(set) var isActive = false
    private(set) var endsAt = Date.distantPast
    /// How far through the Esc hold to stop (0 to 1).
    private(set) var holdProgress = 0.0
    private(set) var failure: String?
    /// Whether macOS lets DiagnoMac turn off the keyboard and trackpad. Checked when the page shows and
    /// when you come back from System Settings.
    private(set) var isTrusted = AXIsProcessTrusted()

    var minutes: Int = {
        let saved = UserDefaults.standard.integer(forKey: "cleaningMinutes")
        return CleaningMode.choices.contains(saved) ? saved : 2
    }() {
        didSet { UserDefaults.standard.set(minutes, forKey: "cleaningMinutes") }
    }

    /// Called with a line to show when it ends.
    @ObservationIgnored var onEnded: (String) -> Void = { _ in }

    /// For tests: events swallowed, events that still reached DiagnoMac's own window, and where the tap sits.
    @ObservationIgnored private(set) var swallowed = 0
    @ObservationIgnored private(set) var leaked = 0
    @ObservationIgnored private(set) var tapLocation = "none"

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var windows: [NSWindow] = []
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var previousPresentation: NSApplication.PresentationOptions = []

    private static let accessibilitySettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    #if DEBUG
    /// The countdown as it would look with this long left, without turning anything off.
    func debugPreview(secondsLeft: TimeInterval, holding: Double = 0) {
        endsAt = Date().addingTimeInterval(secondsLeft)
        holdProgress = holding
    }
    #endif

    // MARK: Permission

    func refreshPermission() { isTrusted = AXIsProcessTrusted() }

    func openAccessibilitySettings() { NSWorkspace.shared.open(Self.accessibilitySettings) }

    // MARK: Start and stop

    func start(for duration: TimeInterval? = nil) {
        guard !isActive else { return }
        failure = nil
        refreshPermission()
        guard isTrusted else {
            // macOS's own prompt, which leads to the setting.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        guard installTap() else {
            failure = "macOS wouldn't let DiagnoMac turn off the keyboard and trackpad. Quit and reopen DiagnoMac, then try again."
            return
        }
        isActive = true
        holdProgress = 0
        swallowed = 0
        leaked = 0
        let length = duration ?? Double(minutes * 60)
        endsAt = Date().addingTimeInterval(length)

        // The display and the Mac stay awake, or it would sleep in the middle of cleaning.
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                         reason: "Cleaning mode")
        previousPresentation = NSApp.presentationOptions
        NSApp.activate()
        coverScreens()
        // No Dock, menu bar, app switcher, Force Quit window or logout while it's on.
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
                                     .disableSessionTermination, .disableHideApplication, .disableAppleMenu]
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        observe()

        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            if !Task.isCancelled { self?.stop(.finished) }
        }
    }

    func stop(_ reason: EndReason) {
        guard isActive else { return }
        isActive = false
        endTask?.cancel()
        endTask = nil
        holdTask?.cancel()
        holdTask = nil
        holdProgress = 0

        removeTap()
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        NSApp.presentationOptions = previousPresentation
        for window in windows { window.orderOut(nil) }
        windows = []
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []

        // A sound tells you it's over when you're looking at the keys.
        if reason == .finished { NSSound(named: "Glass")?.play() }
        if reason != .quit { onEnded(reason.message) }
    }

    /// Ends it on the way out, so nothing stays switched off.
    func shutDown() { stop(.quit) }

    // MARK: Event tap

    private func installTap() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Every kind of event: keys, buttons, movement, scrolling, gestures and media keys.
        let everything = ~CGEventMask(0)
        // At the HID level first, where events enter, then the session if macOS won't allow that.
        for (name, location) in [("HID", CGEventTapLocation.cghidEventTap), ("session", .cgSessionEventTap)] {
            guard let port = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: everything, callback: cleaningTapCallback, userInfo: refcon) else { continue }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            // On the main run loop, so the callback runs on the main thread.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            tap = port
            tapSource = source
            tapLocation = name
            return true
        }
        return false
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// Whether to swallow an event. All of them are, apart from the Esc hold that ends it.
    fileprivate func handle(_ type: CGEventType, keycode: Int64, repeating: Bool) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it's slow. Turn it on again, or the keyboard would work.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown where keycode == 53 && !repeating:
            escDown()
        case .keyUp where keycode == 53:
            escUp()
        default:
            break
        }
        swallowed &+= 1
        return true
    }

    // MARK: Esc hold

    private func escDown() {
        guard holdTask == nil else { return }
        let start = Date()
        holdTask = Task { [weak self] in
            while !Task.isCancelled {
                let progress = Date().timeIntervalSince(start) / Self.holdSeconds
                self?.holdProgress = min(1, progress)
                if progress >= 1 {
                    self?.stop(.heldEsc)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func escUp() {
        holdTask?.cancel()
        holdTask = nil
        holdProgress = 0
    }

    // MARK: Screens

    /// A dark window over every display: the countdown on the main one, plain black on the others.
    private func coverScreens() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = CleaningWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.onLeakedKey = { [weak self] in self?.leaked += 1 }
            if screen == NSScreen.main || screen == NSScreen.screens.first {
                window.contentView = NSHostingView(rootView: CleaningOverlayView(mode: self))
            }
            return window
        }
        for window in windows { window.orderFrontRegardless() }
        windows.first(where: { $0.contentView is NSHostingView<CleaningOverlayView> })?.makeKeyAndOrderFront(nil)
    }

    private func observe() {
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated(handler) }
            observers.append((center, token))
        }
        // A Mac that sleeps would wake with the keyboard still off, and nothing to turn it back on.
        let workspace = NSWorkspace.shared.notificationCenter
        add(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.stop(.sleep) }
        add(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.stop(.sleep) }
        add(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.coverScreens() }
        add(.default, NSApplication.willTerminateNotification) { [weak self] in self?.shutDown() }
    }
}

/// Swallows keys, so nothing a stray key does ever reaches DiagnoMac either.
private final class CleaningWindow: NSWindow {
    var onLeakedKey: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onLeakedKey() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onLeakedKey(); return true }
}

/// The event tap's callback: a plain function, with the mode passed through `refcon`.
private func cleaningTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                 _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let isKey = type == .keyDown || type == .keyUp
    let keycode = isKey ? event.getIntegerValueField(.keyboardEventKeycode) : -1
    let repeating = isKey && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    // The pointer goes in as an integer: a raw pointer can't be handed to the main actor.
    let address = UInt(bitPattern: refcon)
    let swallow = MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return false }
        return Unmanaged<CleaningMode>.fromOpaque(pointer).takeUnretainedValue().handle(type, keycode: keycode, repeating: repeating)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
