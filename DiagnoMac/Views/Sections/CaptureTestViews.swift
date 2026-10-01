import AVFoundation
import SwiftUI

// MARK: - Camera

struct CameraTestCard: View {
    @State private var camera = CameraTest()
    @State private var mirrored = true

    var body: some View {
        Card("Camera", trailing: camera.formatSummary) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                if camera.isRunning {
                    CameraPreview(session: camera.box.session, mirrored: mirrored)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    placeholder
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            HStack {
                DevicePicker(devices: camera.devices, selection: camera.selectedID) { id in
                    Task { await camera.select(id) }
                }
                Toggle("Mirror", isOn: $mirrored).toggleStyle(.checkbox).disabled(!camera.isRunning)
                Spacer()
                startStopButton
            }
            if let error = camera.error {
                Text(error).font(.callout).foregroundStyle(.red)
            } else {
                Text("Check for a sharp, evenly lit image with no dead lines, tint or frozen frames.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: camera.permission == .denied ? "video.slash" : "video")
                .font(.system(size: 30)).foregroundStyle(.white.opacity(0.6))
            Text(camera.devices.isEmpty ? "No camera found"
                 : camera.permission == .denied ? "DiagnoMac doesn't have camera access"
                 : "Camera is off")
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        if camera.permission == .denied {
            Button("Open Privacy Settings") { CapturePermission.openSettings(for: .video) }
        } else if camera.isRunning {
            Button("Stop Camera") { camera.stop() }
        } else {
            Button("Start Camera") { Task { await camera.start() } }
                .buttonStyle(.borderedProminent)
                .disabled(camera.devices.isEmpty)
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        guard let connection = view.previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspect
            layer = previewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}

// MARK: - Microphone

struct MicrophoneTestCard: View {
    @State private var mic = MicrophoneTest()

    var body: some View {
        Card("Microphone", trailing: mic.isRunning ? String(format: "%.0f dBFS", mic.level) : nil) {
            LevelMeter(level: mic.level, peak: mic.peakHold)
                .frame(height: 22)
                .opacity(mic.isRunning ? 1 : 0.4)

            HStack(spacing: 18) {
                reading("Level", mic.level)
                reading("Peak", mic.peakHold)
                reading("Loudest", mic.loudest)
                Spacer()
            }

            HStack {
                DevicePicker(devices: mic.devices, selection: mic.selectedID) { id in
                    Task { await mic.select(id) }
                }
                Spacer()
                startStopButton
            }

            Group {
                if let error = mic.error {
                    Text(error).foregroundStyle(.red)
                } else if mic.permission == .denied {
                    Text("Allow microphone access in System Settings, then come back.").foregroundStyle(.secondary)
                } else if mic.clipped {
                    Label("The input clipped at full scale. Lower the input volume in Sound settings if your voice distorts.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if mic.looksSilent {
                    Label("No sound detected. Check that the input isn't muted and its volume isn't at zero in System Settings → Sound.",
                          systemImage: "speaker.slash").foregroundStyle(.orange)
                } else {
                    Text("Speak normally. Speech usually peaks between −30 and −10 dBFS. Audio isn't recorded.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { mic.stop() }
    }

    private func reading(_ title: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(mic.isRunning && value > MicrophoneTest.floor ? String(format: "%.0f dB", value) : "—")
                .font(.body.monospacedDigit())
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        if mic.permission == .denied {
            Button("Open Privacy Settings") { CapturePermission.openSettings(for: .audio) }
        } else if mic.isRunning {
            Button("Stop") { mic.stop() }
        } else {
            Button("Start Meter") { Task { await mic.start() } }
                .buttonStyle(.borderedProminent)
                .disabled(mic.devices.isEmpty)
        }
    }
}

/// Horizontal dBFS meter: green to -18, yellow to -6, red above, with a peak-hold tick.
private struct LevelMeter: View {
    let level: Float
    let peak: Float

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat((max(MicrophoneTest.floor, min(0, db)) - MicrophoneTest.floor) / -MicrophoneTest.floor)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                LinearGradient(stops: [
                    .init(color: .green, location: 0),
                    .init(color: .green, location: fraction(-18)),
                    .init(color: .yellow, location: fraction(-18)),
                    .init(color: .yellow, location: fraction(-6)),
                    .init(color: .red, location: fraction(-6)),
                ], startPoint: .leading, endPoint: .trailing)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: w * fraction(level))
                }
                .animation(.linear(duration: 0.05), value: level)
                Rectangle().fill(Color.primary)
                    .frame(width: 2)
                    .offset(x: max(0, w * fraction(peak) - 2))
                    .opacity(peak > MicrophoneTest.floor ? 1 : 0)
                ForEach([-60, -40, -20, -6], id: \.self) { db in
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1).offset(x: w * fraction(Float(db)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(String(format: "%.0f decibels", level))
    }
}

// MARK: - Shared

private struct DevicePicker: View {
    let devices: [AVCaptureDevice]
    let selection: String?
    let onSelect: @MainActor @Sendable (String) -> Void

    var body: some View {
        Picker("Device", selection: Binding(get: { selection ?? "" }, set: onSelect)) {
            ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(devices.count < 2)
    }
}
