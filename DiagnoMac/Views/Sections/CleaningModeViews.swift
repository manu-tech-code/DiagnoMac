import SwiftUI

/// What covers the screen during Cleaning mode: the time left, and how to stop early.
struct CleaningOverlayView: View {
    let mode: CleaningMode

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
            Text("Cleaning mode").font(.system(size: 30, weight: .semibold))
            // Once a second, not every frame: this is on screen for minutes.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(mode.endsAt.timeIntervalSince(context.date)))
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .monospacedDigit()
            }
            Text("The keyboard and trackpad are off. Wipe away.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
            stopHint
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    @ViewBuilder
    private var stopHint: some View {
        VStack(spacing: 10) {
            if mode.holdProgress > 0 {
                Capsule().fill(.white.opacity(0.2)).frame(width: 260, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: 260 * mode.holdProgress, height: 6)
                    }
                Text("Keep holding Esc to stop").foregroundStyle(.white.opacity(0.9))
            } else {
                Text("To stop early, hold Esc for \(Int(CleaningMode.holdSeconds)) seconds.")
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(height: 44)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// On the Hardware page: how long, and the button that starts it.
struct CleaningModeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var cleaning = model.cleaning
        Card("Cleaning mode") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wipe down the keyboard and trackpad without pressing anything").fontWeight(.medium)
                    Text("Turns off the keyboard, trackpad and any mouse, and covers the screen with a countdown. To stop early, hold Esc for \(Int(CleaningMode.holdSeconds)) seconds. The Mac stays awake while it's on, and the power button always works.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !cleaning.isTrusted {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS needs your OK first. Allow DiagnoMac in System Settings → Privacy & Security → Accessibility, then press Start again.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button("Open Accessibility Settings…") { cleaning.openAccessibilitySettings() }.buttonStyle(.link)
                    }
                }
            }
            if let failure = cleaning.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker("Length", selection: $cleaning.minutes) {
                    ForEach(CleaningMode.choices, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
                Button("Start Cleaning Mode") { cleaning.start() }.buttonStyle(.borderedProminent)
            }
        }
        .onAppear { cleaning.refreshPermission() }
        // Back from System Settings, where it may have just been allowed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in cleaning.refreshPermission() }
    }
}
