import AppKit
import DiagnoCore
import SwiftUI

/// What the window's buttons do; the driver answers Sparkle with them.
struct UpdateActions {
    var updateNow: () -> Void
    var later: () -> Void
    var skip: () -> Void
    var cancel: () -> Void
    var done: () -> Void
    var viewOnGitHub: () -> Void
    /// The window's close button.
    var closed: () -> Void
}

/// The update window: titled, with only a close button, over a soft wash.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let actions: UpdateActions

    init(flow: UpdateFlow, actions: UpdateActions) {
        self.actions = actions
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Update DiagnoMac"
        window.identifier = NSUserInterfaceItemIdentifier("update")
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: UpdateWindowView(flow: flow, actions: actions))
        window.delegate = self
        window.center()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing from code (after a choice): no "closed by the user" callback.
    func close() {
        window.delegate = nil
        window.close()
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        actions.closed()
    }
}

/// DiagnoMac's cobalt, from the app icon.
enum Brand {
    static let light = Color(red: 0.29, green: 0.42, blue: 1.00)
    static let mid = Color(red: 0.16, green: 0.27, blue: 0.82)
    static let deep = Color(red: 0.09, green: 0.14, blue: 0.56)
    static let glow = Color(red: 0.66, green: 0.75, blue: 1.00)
    static let gradient = LinearGradient(colors: [light, mid], startPoint: .leading, endPoint: .trailing)
}

struct UpdateWindowView: View {
    let flow: UpdateFlow
    let actions: UpdateActions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .regular))
                .padding(.top, 22)
                .padding(.bottom, 14)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .background { wash }
        .frame(minWidth: 640, minHeight: 440)
        .animation(.smooth(duration: 0.35), value: flow.phase)
    }

    private var title: String {
        switch flow.phase {
        case .checking: "Checking for updates…"
        case .found: flow.informational ? "A new version is out" : "New version available"
        case .downloading, .installing: "Updating DiagnoMac"
        case .upToDate: "You're up to date"
        case .failed: "The update didn't work"
        }
    }

    // MARK: Timeline

    @ViewBuilder private var content: some View {
        if flow.phase == .checking {
            ProgressView().controlSize(.regular)
        } else if let notes = flow.notes {
            let shown = Self.timeline(notes, current: flow.currentVersion, offered: flow.newVersion)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, note in
                        TimelineEntry(note: note,
                                      isNew: ReleaseNotes.isNewer(note.version, than: flow.currentVersion),
                                      isNewest: i == 0 && ReleaseNotes.isNewer(note.version, than: flow.currentVersion),
                                      isInstalled: note.version == flow.currentVersion,
                                      isLast: i == shown.count - 1)
                    }
                    if flow.notesFailed {
                        Button("See what's new on GitHub") { actions.viewOnGitHub() }
                            .buttonStyle(.link)
                            .padding(.leading, TimelineEntry.textInset)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
            // Always opens on the newest release, even though the notes arrive after the window.
            .defaultScrollAnchor(.top)
            .id(shown.map(\.id))
            .transition(.opacity)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// The versions you don't have yet, then a few before them, as the history.
    static func timeline(_ notes: [ReleaseNote], current: String, offered: String?) -> [ReleaseNote] {
        let newer = notes.filter { ReleaseNotes.isNewer($0.version, than: current) }
        let rest = notes.filter { !ReleaseNotes.isNewer($0.version, than: current) }
        return Array((newer + rest).prefix(max(6, newer.count + 2)))
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            switch flow.phase {
            case .checking:
                Text("Looking for a newer version…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: actions.cancel)
            case .found:
                Text("New version found: \(Text("v\(flow.newVersion ?? "")").foregroundStyle(Brand.light))")
                    .font(.system(size: 15))
                Spacer()
                Button("Skip This Version", action: actions.skip).buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Later", action: actions.later)
                if flow.informational {
                    Button("View on GitHub", action: actions.viewOnGitHub).buttonStyle(BrandButtonStyle())
                } else {
                    Button("Update Now", action: actions.updateNow)
                        .buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    Text(fraction.map { "Downloading v\(flow.newVersion ?? "")… \(Int(($0 * 100).rounded()))%" } ?? "Downloading v\(flow.newVersion ?? "")…")
                    BrandProgress(fraction: fraction)
                }
                Spacer()
                Button("Cancel", action: actions.cancel)
            case .installing(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Installing v\(flow.newVersion ?? ""). DiagnoMac will reopen by itself.")
                    BrandProgress(fraction: fraction)
                }
                Spacer()
            case .upToDate:
                Text("DiagnoMac \(flow.currentVersion) is the latest version.").foregroundStyle(.secondary)
                Spacer()
                Button("OK", action: actions.done).buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(2)
                Spacer()
                Button("OK", action: actions.done).buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    // MARK: Background

    private var wash: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Brand.light.opacity(scheme == .dark ? 0.14 : 0.08), .clear,
                                    Brand.deep.opacity(scheme == .dark ? 0.18 : 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "arrow.up")
                .font(.system(size: 300, weight: .black))
                .foregroundStyle(LinearGradient(colors: [Brand.glow, Brand.light], startPoint: .top, endPoint: .bottom))
                .opacity(scheme == .dark ? 0.08 : 0.10)
                .offset(x: 230, y: 30)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}

/// One release card: the date, a dot on the rail, then the version and what changed.
private struct TimelineEntry: View {
    let note: ReleaseNote
    let isNew: Bool
    let isNewest: Bool
    let isInstalled: Bool
    let isLast: Bool

    static let dateWidth: CGFloat = 104
    static let railWidth: CGFloat = 22
    static let gap: CGFloat = 16
    static var textInset: CGFloat { dateWidth + gap + railWidth + gap }

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            Text(note.date.map { $0.formatted(.iso8601.year().month().day()) } ?? "")
                .font(.system(size: 13.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.dateWidth, alignment: .trailing)
                .padding(.top, 4)
            Circle()
                .fill(LinearGradient(colors: isNew ? [Brand.light, Brand.deep]
                                                   : [Color(red: 0.36, green: 0.82, blue: 0.74), Color(red: 0.56, green: 0.71, blue: 0.48)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .frame(width: 15, height: 15)
                .frame(width: Self.railWidth)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("v\(note.version)").font(.system(size: 20, weight: .bold))
                    if isNewest { Circle().fill(Brand.light).frame(width: 9, height: 9) }
                    if isNew && !isNewest { tag("New", Brand.light) }
                    if isInstalled { tag("Installed", .secondary) }
                }
                if let summary = note.summary {
                    Text(summary).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(note.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.title).font(.system(size: 15, weight: .medium))
                        ForEach(section.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Circle().fill(.tertiary).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2.5 }
                                Text(item).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if note.sections.isEmpty && note.summary == nil {
                    Text("Release notes are on GitHub.").font(.system(size: 14)).foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, isLast ? 4 : 28)
            Spacer(minLength: 0)
        }
        // The rail: a thin line through the dots, down to the next release.
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1.5)
                    .padding(.top, 22)
                    .padding(.leading, Self.dateWidth + Self.gap + Self.railWidth / 2 - 0.75)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tag(_ text: String, _ style: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(style)
            .background(Capsule().strokeBorder(.separator))
    }
}

/// A thin capsule in the brand gradient; without a fraction, a segment sweeps across.
private struct BrandProgress: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let fraction {
                    Capsule().fill(Brand.gradient)
                        .frame(width: max(6, geo.size.width * fraction))
                        .animation(.smooth(duration: 0.3), value: fraction)
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        let segment = geo.size.width * 0.3
                        Capsule().fill(Brand.gradient)
                            .frame(width: segment)
                            .offset(x: -segment + (geo.size.width + segment) * t)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(width: 280, height: 6)
        .accessibilityElement()
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

/// Update Now: the app icon's cobalt, white text.
private struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.gradient))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25)))
            .shadow(color: Brand.mid.opacity(0.35), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
