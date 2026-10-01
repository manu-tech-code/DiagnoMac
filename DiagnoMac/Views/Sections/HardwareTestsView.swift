import AVFoundation
import SwiftUI

struct HardwareTestsView: View {
    var body: some View {
        Page("Hardware Tests", subtitle: "Interactive tests for parts that sensors can't check for you.") {
            VStack(alignment: .leading, spacing: 14) {
                KeyboardTestCard()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], spacing: 14) {
                    DisplayTestCard()
                    SpeakerTestCard()
                    TrackpadTestCard()
                    CaptureDevicesCard()
                }
            }
        }
    }
}

// MARK: - Keyboard

private struct Key: Identifiable {
    let label: String
    let code: UInt16
    var width: CGFloat = 1
    var id: UInt16 { code }
}

/// US ANSI MacBook layout, using virtual key codes (kVK_*).
private let keyboardRows: [[Key]] = [
    [Key(label: "esc", code: 53, width: 1.4), Key(label: "F1", code: 122), Key(label: "F2", code: 120), Key(label: "F3", code: 99),
     Key(label: "F4", code: 118), Key(label: "F5", code: 96), Key(label: "F6", code: 97), Key(label: "F7", code: 98),
     Key(label: "F8", code: 100), Key(label: "F9", code: 101), Key(label: "F10", code: 109), Key(label: "F11", code: 103), Key(label: "F12", code: 111)],
    [Key(label: "`", code: 50), Key(label: "1", code: 18), Key(label: "2", code: 19), Key(label: "3", code: 20), Key(label: "4", code: 21),
     Key(label: "5", code: 23), Key(label: "6", code: 22), Key(label: "7", code: 26), Key(label: "8", code: 28), Key(label: "9", code: 25),
     Key(label: "0", code: 29), Key(label: "-", code: 27), Key(label: "=", code: 24), Key(label: "delete", code: 51, width: 1.6)],
    [Key(label: "tab", code: 48, width: 1.6), Key(label: "Q", code: 12), Key(label: "W", code: 13), Key(label: "E", code: 14), Key(label: "R", code: 15),
     Key(label: "T", code: 17), Key(label: "Y", code: 16), Key(label: "U", code: 32), Key(label: "I", code: 34), Key(label: "O", code: 31),
     Key(label: "P", code: 35), Key(label: "[", code: 33), Key(label: "]", code: 30), Key(label: "\\", code: 42)],
    [Key(label: "caps", code: 57, width: 1.9), Key(label: "A", code: 0), Key(label: "S", code: 1), Key(label: "D", code: 2), Key(label: "F", code: 3),
     Key(label: "G", code: 5), Key(label: "H", code: 4), Key(label: "J", code: 38), Key(label: "K", code: 40), Key(label: "L", code: 37),
     Key(label: ";", code: 41), Key(label: "'", code: 39), Key(label: "return", code: 36, width: 1.9)],
    [Key(label: "shift", code: 56, width: 2.4), Key(label: "Z", code: 6), Key(label: "X", code: 7), Key(label: "C", code: 8), Key(label: "V", code: 9),
     Key(label: "B", code: 11), Key(label: "N", code: 45), Key(label: "M", code: 46), Key(label: ",", code: 43), Key(label: ".", code: 47),
     Key(label: "/", code: 44), Key(label: "shift", code: 60, width: 2.4)],
    [Key(label: "fn", code: 63), Key(label: "⌃", code: 59), Key(label: "⌥", code: 58), Key(label: "⌘", code: 55, width: 1.3),
     Key(label: "space", code: 49, width: 5.4), Key(label: "⌘", code: 54, width: 1.3), Key(label: "⌥", code: 61),
     Key(label: "←", code: 123), Key(label: "↑", code: 126), Key(label: "↓", code: 125), Key(label: "→", code: 124)],
]
private let totalKeys = keyboardRows.joined().count

private struct KeyboardTestCard: View {
    @State private var tested: Set<UInt16> = []
    @State private var down: Set<UInt16> = []
    @State private var capturing = false

    var body: some View {
        Card("Keyboard", trailing: "\(tested.count) of \(totalKeys) keys tested") {
            VStack(spacing: 5) {
                ForEach(Array(keyboardRows.enumerated()), id: \.offset) { _, row in
                    GeometryReader { geo in
                        let spacing: CGFloat = 5
                        let units = row.map(\.width).reduce(0, +)
                        let unit = (geo.size.width - spacing * CGFloat(row.count - 1)) / units
                        HStack(spacing: spacing) {
                            ForEach(row) { key in
                                keyCap(key).frame(width: unit * key.width)
                            }
                        }
                    }
                    .frame(height: 32)
                }
            }
            .background(KeyCaptureView(isActive: capturing, onDown: { code in
                down.insert(code); tested.insert(code)
            }, onUp: { code in
                down.remove(code)
            }))
            HStack {
                Text(capturing
                     ? "Press every key. Keys turn green once they register. Shortcuts like ⌘Q are blocked while testing."
                     : "Start the test, then press every key. A key that stays grey may be faulty.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { tested.removeAll(); down.removeAll() }
                Button(capturing ? "Stop Test" : "Start Test") { capturing.toggle() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func keyCap(_ key: Key) -> some View {
        let isDown = down.contains(key.code), isDone = tested.contains(key.code)
        return Text(key.label)
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(isDown ? Color.white : isDone ? Color.green : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 6).fill(isDown ? Color.accentColor : isDone ? Color.green.opacity(0.15) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isDone ? Color.green.opacity(0.4) : Color.secondary.opacity(0.2)))
    }
}

/// Installs a local event monitor that reports raw key codes, including modifier keys.
private struct KeyCaptureView: NSViewRepresentable {
    var isActive: Bool
    var onDown: (UInt16) -> Void
    var onUp: (UInt16) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        if isActive { context.coordinator.start() } else { context.coordinator.stop() }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator {
        var parent: KeyCaptureView
        private var monitor: Any?
        private var modifierState: Set<UInt16> = []

        init(parent: KeyCaptureView) { self.parent = parent }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                MainActor.assumeIsolated { self.handle(event) }
                return nil // swallow the event so shortcuts don't fire while testing
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            switch event.type {
            case .keyDown: parent.onDown(event.keyCode)
            case .keyUp: parent.onUp(event.keyCode)
            case .flagsChanged:
                // flagsChanged fires on both press and release; toggle per key.
                if modifierState.contains(event.keyCode) {
                    modifierState.remove(event.keyCode)
                    parent.onUp(event.keyCode)
                } else {
                    modifierState.insert(event.keyCode)
                    parent.onDown(event.keyCode)
                }
            default: break
            }
        }
    }
}

// MARK: - Display

private struct DisplayTestCard: View {
    var body: some View {
        Card("Display") {
            Text("Fills the screen with solid colors so dead or stuck pixels stand out. Click or press Space for the next color, Esc to stop.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                    Button(NSScreen.screens.count > 1 ? "Test \(screen.localizedName)" : "Start Display Test") {
                        DisplayTestWindow.show(on: screen)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

@MainActor
private enum DisplayTestWindow {
    private static var window: NSWindow?

    static func show(on screen: NSScreen) {
        let window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        let view = ColorCycleView(frame: screen.frame)
        view.onFinish = { close() }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSCursor.hide()
        self.window = window
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
        NSCursor.unhide()
    }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class ColorCycleView: NSView {
        private let colors: [NSColor] = [.red, .green, .blue, .white, .black, .gray]
        private var index = 0
        var onFinish: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            colors[index].setFill()
            dirtyRect.fill()
        }

        private func advance() {
            index += 1
            if index >= colors.count { onFinish?() } else { needsDisplay = true }
        }

        override func mouseDown(with event: NSEvent) { advance() }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53: onFinish?()              // esc
            case 49, 124, 36: advance()       // space, right arrow, return
            default: break
            }
        }
    }
}

// MARK: - Speakers

private struct SpeakerTestCard: View {
    @State private var player = TonePlayer()

    var body: some View {
        Card("Speakers") {
            Text("Plays a tone on each side. Listen for crackle, buzzing, or one side missing.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Left") { player.play(pan: -1) }
                Button("Right") { player.play(pan: 1) }
                Button("Sweep Both") { player.sweep() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

@MainActor
private final class TonePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(pan: Float) {
        schedule(buffer(seconds: 1) { t in (440, t) }, pan: pan)
    }

    func sweep() {
        // Logarithmic sweep from 100 Hz to 8 kHz exposes rattles at specific frequencies.
        schedule(buffer(seconds: 3) { t in (100 * pow(80, t / 3), t) }, pan: 0)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, pan: Float) {
        do {
            if !engine.isRunning { try engine.start() }
            node.stop()
            node.pan = pan
            node.scheduleBuffer(buffer)
            node.play()
        } catch {
            NSSound.beep()
        }
    }

    /// `frequency(t)` returns the instantaneous frequency at time t.
    private func buffer(seconds: Double, frequency: (Double) -> (Double, Double)) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            let (hz, _) = frequency(t)
            phase += 2 * .pi * hz / format.sampleRate
            let envelope = min(1, t / 0.02, (seconds - t) / 0.05) // avoid clicks at start and end
            let sample = Float(sin(phase) * 0.25 * envelope)
            buffer.floatChannelData![0][i] = sample
            buffer.floatChannelData![1][i] = sample
        }
        return buffer
    }
}

// MARK: - Trackpad

private struct TrackpadTestCard: View {
    @State private var strokes: [[CGPoint]] = []
    @State private var clicks = 0

    var body: some View {
        Card("Trackpad", trailing: "\(clicks) clicks") {
            Text("Drag across the whole area. Gaps or jumps in the line point to dead zones.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Canvas { context, _ in
                for stroke in strokes where stroke.count > 1 {
                    var path = Path()
                    path.addLines(stroke)
                    context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 160)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if value.translation == .zero { strokes.append([value.location]) } else { strokes[strokes.count - 1].append(value.location) }
                }
                .onEnded { value in if value.translation == .zero { clicks += 1 } })
            HStack {
                Spacer()
                Button("Clear") { strokes.removeAll(); clicks = 0 }
            }
        }
    }
}

// MARK: - Camera & microphone

private struct CaptureDevicesCard: View {
    private var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }
    private var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            .filter { !$0.localizedName.hasPrefix("CADefaultDeviceAggregate") } // Core Audio's internal aggregate device
    }

    var body: some View {
        Card("Camera & microphone") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cameras, id: \.uniqueID) { Label($0.localizedName, systemImage: "camera") }
                ForEach(microphones, id: \.uniqueID) { Label($0.localizedName, systemImage: "mic") }
                if cameras.isEmpty && microphones.isEmpty {
                    Text("No cameras or microphones found.").foregroundStyle(.secondary)
                }
            }
            Text("Live camera preview and a microphone level meter are coming next. They need camera and microphone permission.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
