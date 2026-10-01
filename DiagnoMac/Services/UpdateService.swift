import AppKit
import DiagnoCore
import Observation
@preconcurrency import Sparkle

/// Updates through Sparkle. Once a day it reads the appcast attached to the latest GitHub
/// release, checks the download's EdDSA signature against the key in Info.plist, and replaces
/// the app on relaunch. Sparkle's window is replaced by ours (`UpdateDriver`): a timeline of
/// releases with Update Now. An update found in the background shows as a banner first.
@MainActor
@Observable
final class UpdateService: NSObject {
    /// A version found by a scheduled check, waiting for you.
    private(set) var available: String?
    /// Called when a scheduled check finds a version.
    @ObservationIgnored var onBackgroundUpdate: (String) -> Void = { _ in }

    @ObservationIgnored private let driver = UpdateDriver()
    @ObservationIgnored private var updater: SPUUpdater?

    func start() {
        guard updater == nil else { return }
        driver.onBackgroundUpdate = { [weak self] version in
            self?.available = version
            NSLog("DiagnoMac updates: \(version) available")
            self?.onBackgroundUpdate(version)
        }
        driver.onSessionEnd = { [weak self] in self?.available = nil }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            NSLog("DiagnoMac updates: couldn't start (\(error.localizedDescription))")
        }
        self.updater = updater
    }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { updater?.lastUpdateCheckDate }

    /// The update window: the waiting update, or a fresh check.
    func checkForUpdates() {
        if driver.hasPendingUpdate {
            driver.showPendingUpdate()
            return
        }
        #if DEBUG
        guard Self.debugFeed != nil else {
            NSAlert.informational(title: "No updates in development builds",
                                  message: "Set DebugFeedURL to a local appcast to try them:\ndefaults write com.amalitech.DiagnoMac DebugFeedURL file:///…/appcast.xml")
            return
        }
        #endif
        updater?.checkForUpdates()
    }

    #if DEBUG
    /// Development builds share the release's bundle id and defaults, so they never check the
    /// real feed: only a local one, set with
    /// `defaults write com.amalitech.DiagnoMac DebugFeedURL file:///…/appcast.xml`.
    static var debugFeed: String? { UserDefaults.standard.string(forKey: "DebugFeedURL") }

    /// The update window in a given step, with real notes and nothing to install.
    func debugWindow(_ phase: UpdateFlow.Phase, version: String) { driver.debugShow(phase, version: version) }
    #endif
}

extension UpdateService: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("DiagnoMac updates: found \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NSLog("DiagnoMac updates: up to date")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        NSLog("DiagnoMac updates: \(error.localizedDescription)\(underlying.map { " (\($0.domain) \($0.code): \($0.localizedDescription))" } ?? "")")
    }

    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? { Self.debugFeed }
    func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool { Self.debugFeed != nil }
    #endif
}

#if DEBUG
private extension NSAlert {
    static func informational(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
#endif

// MARK: - The update flow

/// What the update window shows, step by step.
@MainActor
@Observable
final class UpdateFlow {
    enum Phase: Equatable {
        case checking
        /// An update is waiting for a choice.
        case found
        /// Downloading; the fraction is nil until the size is known.
        case downloading(Double?)
        /// Unpacking (fraction) and then installing (nil); the app relaunches after.
        case installing(Double?)
        case upToDate
        case failed(String)
    }

    var phase: Phase = .checking
    /// The version on offer.
    var newVersion: String?
    /// The release only points to its notes, with nothing to download.
    var informational = false
    /// Recent releases for the timeline, newest first; nil while they load.
    var notes: [ReleaseNote]?
    var notesFailed = false
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}

/// Sparkle's user interface, ours instead of Sparkle's window: a timeline of releases with
/// "New version available" and Update Now, progress in the same window, and "you're up to date".
/// An update found by the daily check is announced in the app first; its button opens the window.
@MainActor
final class UpdateDriver: NSObject {
    let flow = UpdateFlow()
    /// The daily check found a version.
    var onBackgroundUpdate: (String) -> Void = { _ in }
    /// The session ended (installed, dismissed or failed).
    var onSessionEnd: () -> Void = {}

    private lazy var window = UpdateWindowController(flow: flow, actions: UpdateActions(
        updateNow: { [weak self] in self?.updateNow() },
        later: { [weak self] in self?.answer(.dismiss) },
        skip: { [weak self] in self?.answer(.skip) },
        cancel: { [weak self] in self?.cancelRunning() },
        done: { [weak self] in self?.acknowledgeAndClose() },
        viewOnGitHub: { [weak self] in self?.viewOnGitHub() },
        closed: { [weak self] in self?.windowClosedByUser() }))
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var acknowledgement: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    /// Only checks the user started may open the window for "up to date" or an error.
    private var userInitiated = false

    var hasPendingUpdate: Bool { choice != nil && flow.phase == .found }

    /// The banner's Update button, or Check for Updates… while one is waiting.
    func showPendingUpdate() {
        window.show()
    }

    // MARK: Choices from the window

    private func updateNow() {
        guard choice != nil else { window.close(); return }
        flow.phase = .downloading(nil)
        choice?(.install)
        choice = nil
    }

    private func answer(_ c: SPUUserUpdateChoice) {
        choice?(c)
        choice = nil
        window.close()
    }

    private func cancelRunning() {
        cancellation?()
        cancellation = nil
        window.close()
    }

    private func acknowledgeAndClose() {
        acknowledgement?()
        acknowledgement = nil
        window.close()
    }

    private func viewOnGitHub() {
        let version = flow.newVersion.map { "tag/v\($0)" } ?? "latest"
        NSWorkspace.shared.open(URL(string: "https://github.com/manu-tech-code/DiagnoMac/releases/\(version)")!)
        answer(.dismiss)
    }

    /// The window's close button means "later", "cancel" or "OK", depending on the step.
    private func windowClosedByUser() {
        switch flow.phase {
        case .found: choice?(.dismiss); choice = nil
        case .checking, .downloading: cancellation?(); cancellation = nil
        case .upToDate, .failed: acknowledgement?(); acknowledgement = nil
        case .installing: break
        }
    }

    // MARK: Notes

    private func loadNotes(foundDate: Date?) {
        flow.notes = nil
        flow.notesFailed = false
        Task { [flow] in
            var notes = await ReleaseHistory.recent()
            if notes == nil { flow.notesFailed = true }
            // The version on offer always leads, even if GitHub's list doesn't have it yet.
            if let v = flow.newVersion, !(notes ?? []).contains(where: { $0.version == v }) {
                notes = [ReleaseNote(version: v, date: foundDate, sections: [])] + (notes ?? [])
            }
            flow.notes = notes ?? []
        }
    }

    #if DEBUG
    /// The window in a given step, with real notes and nothing to install.
    func debugShow(_ phase: UpdateFlow.Phase, version: String) {
        flow.newVersion = phase == .upToDate ? nil : version
        flow.phase = phase
        loadNotes(foundDate: .now)
        window.show()
    }
    #endif
}

extension UpdateDriver: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Automatic checks are on in Info.plist; this is only a fallback.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        self.cancellation = cancellation
        flow.phase = .checking
        flow.newVersion = nil
        window.show()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choice = reply
        cancellation = nil
        flow.newVersion = appcastItem.displayVersionString
        flow.informational = appcastItem.isInformationOnlyUpdate
        flow.phase = .found
        loadNotes(foundDate: appcastItem.date)
        if state.userInitiated || userInitiated {
            window.show()
        } else {
            onBackgroundUpdate(appcastItem.displayVersionString)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        self.acknowledgement = acknowledgement
        flow.newVersion = nil
        flow.phase = .upToDate
        loadNotes(foundDate: nil)
        window.show()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        NSLog("DiagnoMac updates: \(error.localizedDescription)")
        guard userInitiated || window.isVisible else { acknowledgement(); return }
        self.acknowledgement = acknowledgement
        flow.phase = .failed(error.localizedDescription)
        window.show()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedBytes = 0
        receivedBytes = 0
        flow.phase = .downloading(nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        receivedBytes = 0
        flow.phase = .downloading(0)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard expectedBytes > 0 else { return }
        flow.phase = .downloading(min(1, Double(receivedBytes) / Double(expectedBytes)))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        flow.phase = .installing(0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        flow.phase = .installing(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Update Now already said yes: install and relaunch straight away.
        flow.phase = .installing(nil)
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        flow.phase = .installing(nil)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        window.show()
    }

    func dismissUpdateInstallation() {
        choice = nil
        cancellation = nil
        acknowledgement = nil
        userInitiated = false
        window.close()
        onSessionEnd()
    }
}

/// The last releases from GitHub, for the timeline.
enum ReleaseHistory {
    static func recent() async -> [ReleaseNote]? {
        guard let url = URL(string: "https://api.github.com/repos/manu-tech-code/DiagnoMac/releases?per_page=8") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DiagnoMac", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ReleaseNotes.parseGitHubReleases(data)
    }
}
