import AppKit
import Foundation
import Observation

/// Owns the latest scan, the live CPU feed and the actions the UI can trigger.
@MainActor
@Observable
final class AppModel {
    var selection: Area? = .overview
    var snapshot = DiagnosticsSnapshot()
    var findings: [Finding] = []
    var history: [HistoryEntry] = HistoryStore.load()

    var isScanning = false
    var scanProgress: Double = 0
    var scanStatus = ""
    var lastScan: Date?

    /// Live CPU samples, newest last, one per second.
    var cpuHistory: [Double] = []
    var cpuNow: CPULoad?
    var liveMemory: MemoryInfo?

    var speedTest: SpeedTestResult?
    var isRunningSpeedTest = false
    var banner: String?

    var score: Int { FindingsEngine.score(findings) }

    private let sampler = CPUSampler()
    private var liveTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?

    init() {
        startLiveSampling()
        Task { await scan() }
        #if DEBUG
        DebugCapture.runIfRequested(model: self)
        #endif
    }

    func severity(for area: Area) -> Severity {
        FindingsEngine.worstSeverity(in: area, findings)
    }

    // MARK: Scanning

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        snapshot.takenAt = Date()

        stepsDone = 0

        scanStatus = "Checking battery, memory, storage, network…"
        snapshot.memory = MemoryCollector.collect()
        liveMemory = snapshot.memory
        step("memory")

        await withTaskGroup(of: Void.self) { group in
            group.addTask { let v = await MachineCollector.collect(); await MainActor.run { self.snapshot.machine = v; self.step("hardware") } }
            group.addTask {
                let v = await BatteryCollector.collect()
                await MainActor.run { self.snapshot.battery = v; self.snapshot.hasBattery = v != nil; self.step("battery") }
            }
            group.addTask { let v = await BatteryCollector.powerSettings(); await MainActor.run { self.snapshot.power = v; self.step("power settings") } }
            group.addTask { let v = await PerformanceCollector.collect(); await MainActor.run { self.snapshot.performance = v; self.step("processes") } }
            group.addTask { let v = await StorageCollector.collect(); await MainActor.run { self.snapshot.storage = v; self.step("storage") } }
            group.addTask { let v = await NetworkCollector.collect(); await MainActor.run { self.snapshot.network = v; self.step("network") } }
            group.addTask { let v = await SecurityCollector.collect(); await MainActor.run { self.snapshot.security = v; self.step("security") } }
            group.addTask { let v = await StartupCollector.collect(); await MainActor.run { self.snapshot.startup = v; self.step("startup items") } }
            group.addTask { let v = await CrashLogCollector.collect(); await MainActor.run { self.snapshot.logs = v; self.step("crash logs") } }
        }

        findings = FindingsEngine.findings(for: snapshot)
        lastScan = Date()
        isScanning = false
        scanStatus = "Scan complete"
        history = HistoryStore.record(HistoryEntry(
            day: Calendar.current.startOfDay(for: Date()), score: score,
            batteryHealth: snapshot.battery?.healthPercent, cycleCount: snapshot.battery?.cycleCount,
            freeBytes: snapshot.storage?.availableBytes, swapUsedBytes: snapshot.memory?.swapUsed))
    }

    private var stepsDone = 0.0
    private let totalSteps = 10.0

    private func step(_ name: String) {
        stepsDone += 1
        scanProgress = stepsDone / totalSteps
        scanStatus = "Checked \(name)"
        findings = FindingsEngine.findings(for: snapshot)
    }

    func refresh(_ area: Area) async {
        switch area {
        case .battery:
            snapshot.battery = await BatteryCollector.collect()
            snapshot.power = await BatteryCollector.powerSettings()
        case .performance: snapshot.performance = await PerformanceCollector.collect()
        case .memory:
            snapshot.memory = MemoryCollector.collect()
            snapshot.performance = await PerformanceCollector.collect()
        case .storage: snapshot.storage = await StorageCollector.collect()
        case .network: snapshot.network = await NetworkCollector.collect()
        case .security: snapshot.security = await SecurityCollector.collect()
        case .startup: snapshot.startup = await StartupCollector.collect()
        case .logs: snapshot.logs = await CrashLogCollector.collect()
        case .overview, .report: await scan()
        case .hardware: break
        }
        findings = FindingsEngine.findings(for: snapshot)
    }

    // MARK: Live sampling

    private func startLiveSampling() {
        _ = sampler.sample() // prime the baseline
        liveTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let load = self.sampler.sample() {
                    self.cpuNow = load
                    self.cpuHistory.append(load.total)
                    if self.cpuHistory.count > 120 { self.cpuHistory.removeFirst(self.cpuHistory.count - 120) }
                }
                tick += 1
                if tick % 5 == 0 { self.liveMemory = MemoryCollector.collect() }
            }
        }
    }

    // MARK: Actions

    func perform(_ finding: Finding) {
        guard let action = finding.action else { return }
        switch action {
        case .navigate(let area): selection = area
        case .openURL(let url): NSWorkspace.shared.open(url)
        case .enableFirewall: Task { await enableFirewall() }
        }
    }

    func enableFirewall() async {
        if await SecurityCollector.enableFirewall() {
            show("Firewall turned on")
        } else {
            show("Firewall unchanged. You can turn it on in System Settings → Network → Firewall.")
        }
        await refresh(.security)
    }

    func runSpeedTest() async {
        isRunningSpeedTest = true
        speedTest = await NetworkCollector.speedTest()
        isRunningSpeedTest = false
        if speedTest == nil { show("Speed test failed. Check your connection and try again.") }
    }

    func clean(_ candidates: [CleanupCandidate]) async {
        var messages: [String] = []
        for candidate in candidates { messages.append(await StorageCollector.clean(candidate)) }
        show(messages.joined(separator: " "))
        await refresh(.storage)
    }

    func setStartupItem(_ item: StartupItem, enabled: Bool) async {
        switch await StartupCollector.setEnabled(enabled, item: item) {
        case .success: show("\(item.label) will \(enabled ? "" : "no longer ")run at login")
        case .failure(let error): show(error.localizedDescription)
        }
        await refresh(.startup)
    }

    func show(_ message: String) {
        banner = message
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.banner = nil }
        }
    }

    var reportText: String { ReportBuilder.text(snapshot: snapshot, findings: findings) }
}
