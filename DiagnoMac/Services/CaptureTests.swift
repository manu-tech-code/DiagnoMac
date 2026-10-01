import AVFoundation
import AppKit
import Observation

/// Shared permission handling for the camera and microphone tests.
enum CapturePermission: Equatable {
    case notDetermined, authorized, denied

    init(_ mediaType: AVMediaType) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }

    static func request(_ mediaType: AVMediaType) async -> CapturePermission {
        if CapturePermission(mediaType) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: mediaType)
        }
        return CapturePermission(mediaType)
    }

    static func openSettings(for mediaType: AVMediaType) {
        let pane = mediaType == .video ? "Privacy_Camera" : "Privacy_Microphone"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// Owns an AVCaptureSession and the serial queue it is configured on.
/// AVCaptureSession isn't Sendable, so it's only touched on `queue` (and read by the preview layer).
final class SessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue: DispatchQueue

    init(label: String) { queue = DispatchQueue(label: label) }

    /// Replaces the session's inputs with the device, then starts it. Returns an error message on failure.
    func run(deviceID: String, configure: @escaping @Sendable (AVCaptureSession) -> Void = { _ in }) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let session = self.session
                guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                    continuation.resume(returning: "The device is no longer connected.")
                    return
                }
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw CaptureError.busy }
                    session.addInput(input)
                } catch {
                    session.commitConfiguration()
                    continuation.resume(returning: "Couldn't open \(device.localizedName). Another app may be using it.")
                    return
                }
                configure(session)
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                continuation.resume(returning: nil)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private enum CaptureError: Error { case busy }
}

// MARK: - Camera

@MainActor
@Observable
final class CameraTest {
    private(set) var devices: [AVCaptureDevice] = []
    var selectedID: String?
    private(set) var permission = CapturePermission(.video)
    private(set) var isRunning = false
    private(set) var formatSummary: String?
    private(set) var error: String?

    let box = SessionBox(label: "diagnomac.camera")

    init() { refreshDevices() }

    func refreshDevices() {
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
        if selectedID == nil || !devices.contains(where: { $0.uniqueID == selectedID }) {
            selectedID = devices.first?.uniqueID
        }
    }

    func start() async {
        permission = await CapturePermission.request(.video)
        guard permission == .authorized, let id = selectedID else { return }
        error = await box.run(deviceID: id) { session in
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        }
        isRunning = error == nil
        formatSummary = isRunning ? Self.describe(devices.first { $0.uniqueID == id }) : nil
    }

    func select(_ id: String) async {
        selectedID = id
        if isRunning { await start() }
    }

    func stop() {
        box.stop()
        isRunning = false
    }

    private static func describe(_ device: AVCaptureDevice?) -> String? {
        guard let device else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return "\(dims.width) × \(dims.height) · up to \(Int(fps.rounded())) fps"
    }
}

// MARK: - Microphone

@MainActor
@Observable
final class MicrophoneTest {
    private(set) var devices: [AVCaptureDevice] = []
    var selectedID: String?
    private(set) var permission = CapturePermission(.audio)
    private(set) var isRunning = false
    private(set) var error: String?

    /// dBFS, -80 (silence) ... 0 (full scale).
    private(set) var level: Float = -80
    private(set) var peakHold: Float = -80
    private(set) var loudest: Float = -80
    private(set) var clipped = false
    private(set) var startedAt: Date?

    nonisolated static let floor: Float = -80

    private let box = SessionBox(label: "diagnomac.microphone")
    private let tap = LevelTap()
    private var peakHeldAt = Date.distantPast

    init() {
        refreshDevices()
        tap.onLevel = { [weak self] rms, peak in
            Task { @MainActor in self?.update(rms: rms, peak: peak) }
        }
    }

    /// No signal above the noise floor for a few seconds usually means a muted or zero-volume input.
    var looksSilent: Bool {
        guard isRunning, let startedAt, Date().timeIntervalSince(startedAt) > 3 else { return false }
        return loudest < -60
    }

    func refreshDevices() {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.filter { !$0.localizedName.hasPrefix("CADefaultDeviceAggregate") } // Core Audio's internal aggregate device
        if selectedID == nil || !devices.contains(where: { $0.uniqueID == selectedID }) {
            selectedID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? devices.first?.uniqueID
        }
    }

    func start() async {
        permission = await CapturePermission.request(.audio)
        guard permission == .authorized, let id = selectedID else { return }
        resetLevels()
        let tap = self.tap
        error = await box.run(deviceID: id) { session in
            guard session.outputs.isEmpty else { return }
            let output = AVCaptureAudioDataOutput()
            // Ask for interleaved 32-bit float so the tap can read samples directly.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(tap, queue: DispatchQueue(label: "diagnomac.microphone.tap"))
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        isRunning = error == nil
        startedAt = isRunning ? Date() : nil
    }

    func select(_ id: String) async {
        selectedID = id
        if isRunning { await start() }
    }

    func stop() {
        box.stop()
        isRunning = false
        level = Self.floor
        peakHold = Self.floor
    }

    private func resetLevels() {
        level = Self.floor; peakHold = Self.floor; loudest = Self.floor; clipped = false
    }

    private func update(rms: Float, peak: Float) {
        guard isRunning else { return }
        // Fast attack, slower release, like a hardware meter.
        level = rms > level ? rms : max(rms, level - 1.5)
        if peak >= peakHold || Date().timeIntervalSince(peakHeldAt) > 1.5 {
            peakHold = peak
            peakHeldAt = Date()
        }
        loudest = max(loudest, peak)
        if peak > -0.5 { clipped = true }
    }
}

/// Receives audio buffers on a capture queue and reports RMS and peak in dBFS.
private final class LevelTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onLevel: (@Sendable (Float, Float) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return }

        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        var sumSquares: Float = 0, peak: Float = 0
        for i in 0..<count {
            let s = samples[i]
            sumSquares += s * s
            peak = max(peak, abs(s))
        }
        let rms = (sumSquares / Float(count)).squareRoot()
        onLevel?(Self.decibels(rms), Self.decibels(peak))
    }

    private static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0 ? max(MicrophoneTest.floor, 20 * log10(amplitude)) : MicrophoneTest.floor
    }
}
