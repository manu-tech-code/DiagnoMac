import AppKit
import Foundation
import IOKit.ps
import Observation

/// Owns the latest scan, the live readings and the actions the UI can trigger.
@MainActor
@Observable
final class AppModel {
    var selection: Area? = .overview {
        didSet { if oldValue != selection { restartSampling() } }
    }
    /// Observed per section, so a view that shows the battery only updates when the battery does.
    let snapshot = LiveSnapshot()
    var findings: [Finding] = []
    var history: [HistoryEntry] = HistoryStore.load()

    var isScanning = false
    var scanProgress: Double = 0
    var scanStatus = ""
    var lastScan: Date?

    /// Live CPU samples, newest last, one per second while something shows them.
    var cpuHistory: [Double] = []
    var cpuNow: CPULoad?
    /// Live GPU utilization samples, newest last.
    var gpuHistory: [Double] = []
    /// Charger and battery power for the last 10 minutes the Battery page was open.
    var powerHistory: [PowerSample] = []
    var chargeSessions: [ChargeSession] = ChargeLogStore.load().map { session in
        // A session still open from a previous run ended when the app last saw it.
        var closed = session
        if closed.end == nil { closed.end = closed.lastSeen ?? closed.start }
        return closed
    }
    private var lastChargeSave = Date.distantPast

    var speedTest = SpeedTestState()
    /// Apps we asked to quit, and when. Ones still running after a few seconds can be force quit.
    var quitRequests: [Int32: Date] = [:]
    var banner: String?

    let intelligence = Intelligence()

    var score: Int { FindingsEngine.score(findings) }

    private let cpuSampler = CPUSampler()
    private let gpuSampler = GPUSampler()
    private let appsSampler = AppsSampler()
    private var speedRunner: SpeedTestRunner?
    private var liveTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var powerSourceObserver: PowerSourceObserver?
    /// The scan the Overview's summary describes.
    private var summaryScan: Date?

    init() {
        // `-openPage battery` opens on a page (used by scripts/measure.sh).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-openPage"), i + 1 < args.count, let area = Area(rawValue: args[i + 1]) {
            selection = area
        }
        intelligence.context = { [unowned self] in (self.snapshot.value, self.findings) }
        // Plugging in or unplugging the charger is reported straight away, without polling.
        powerSourceObserver = PowerSourceObserver { [weak self] in
            Task { await self?.sampleBattery() }
        }
        restartSampling()
        Task { await scan() }
        #if DEBUG
        DebugCapture.runIfRequested(model: self)
        #endif
    }

    func severity(for area: Area) -> Severity {
        FindingsEngine.worstSeverity(in: area, findings)
    }

    /// Replaces the findings only when they changed, so views that show them don't redraw for nothing.
    private func updateFindings() {
        let new = FindingsEngine.findings(for: snapshot.value)
        if new != findings { findings = new }
    }

    // MARK: Scanning

    private var stepsDone = 0.0
    private let totalSteps = 13.0

    private func step(_ name: String) {
        stepsDone += 1
        scanProgress = stepsDone / totalSteps
        scanStatus = "Checked \(name)"
        updateFindings()
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        stepsDone = 0
        snapshot.takenAt = Date()
        scanStatus = "Checking battery, memory, storage, network…"

        snapshot.memory = MemoryCollector.collect()
        step("memory")
        sampleGPU(processes: false)
        snapshot.apps = await appsSampler.sample()
        step("apps")

        await withTaskGroup(of: Void.self) { group in
            group.addTask { let v = await MachineCollector.collect(); await MainActor.run { self.snapshot.machine = v; self.step("hardware") } }
            group.addTask {
                let v = await BatteryCollector.collect()
                await MainActor.run { self.snapshot.battery = v; self.snapshot.hasBattery = v != nil; self.step("battery") }
            }
            group.addTask { let v = await BatteryCollector.powerSettings(); await MainActor.run { self.snapshot.power = v; self.step("power settings") } }
            group.addTask { let v = await PerformanceCollector.collect(); await MainActor.run { self.snapshot.performance = v; self.step("processes") } }
            group.addTask { let v = await StorageCollector.collect(); await MainActor.run { self.snapshot.storage = v; self.step("storage") } }
            group.addTask { let v = await BackupCollector.collect(); await MainActor.run { self.snapshot.backup = v; self.step("backups") } }
            group.addTask { let v = await NetworkCollector.collect(); await MainActor.run { self.snapshot.network = v; self.step("network") } }
            group.addTask { let v = await SecurityCollector.collect(); await MainActor.run { self.snapshot.security = v; self.step("security") } }
            group.addTask { let v = await StartupCollector.collect(); await MainActor.run { self.snapshot.startup = v; self.step("startup items") } }
            group.addTask { let v = await CrashLogCollector.collect(); await MainActor.run { self.snapshot.logs = v; self.step("crash logs") } }
            group.addTask { let v = await DevicesCollector.collect(); await MainActor.run { self.snapshot.devices = v; self.step("devices") } }
        }

        updateFindings()
        lastScan = Date()
        isScanning = false
        scanStatus = "Scan complete"
        history = HistoryStore.record(HistoryEntry(
            day: Calendar.current.startOfDay(for: Date()), score: score,
            batteryHealth: snapshot.battery?.healthPercent, cycleCount: snapshot.battery?.cycleCount,
            freeBytes: snapshot.storage?.availableBytes, swapUsedBytes: snapshot.memory?.swapUsed))

        // The summary is written only when someone is looking at it.
        if isWindowVisible && selection == .overview { ensureSummary() }
    }

    func refresh(_ area: Area) async {
        switch area {
        case .battery:
            snapshot.battery = await BatteryCollector.collect()
            snapshot.power = await BatteryCollector.powerSettings()
        case .performance: snapshot.performance = await PerformanceCollector.collect()
        case .memory:
            snapshot.memory = MemoryCollector.collect()
            snapshot.apps = await appsSampler.sample()
        case .apps: snapshot.apps = await appsSampler.sample()
        case .storage:
            async let storage = StorageCollector.collect()
            async let backup = BackupCollector.collect()
            snapshot.storage = await storage
            snapshot.backup = await backup
        case .network: snapshot.network = await NetworkCollector.collect()
        case .security: snapshot.security = await SecurityCollector.collect()
        case .startup: snapshot.startup = await StartupCollector.collect()
        case .logs: snapshot.logs = await CrashLogCollector.collect()
        case .devices: snapshot.devices = await DevicesCollector.collect()
        case .overview, .report: await scan()
        case .hardware, .assistant: break
        }
        updateFindings()
    }

    // MARK: Live sampling

    /// The main window is open and not hidden behind other windows.
    private(set) var isWindowVisible = false
    /// The menu bar panel is open.
    private(set) var isMenuBarPanelVisible = false

    func setWindowVisible(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        restartSampling()
    }

    func setMenuBarPanelVisible(_ visible: Bool) {
        guard visible != isMenuBarPanelVisible else { return }
        isMenuBarPanelVisible = visible
        restartSampling()
    }

    private enum Sampler: CaseIterable { case cpu, gpu, battery, memory, apps }

    /// How often each reading is taken, from what's on screen. Nil means not at all.
    private struct Schedule {
        var cpu: Duration?
        var gpu: Duration?
        var gpuProcesses: Bool
        var battery: Duration
        var memory: Duration
        var apps: Duration

        func interval(for sampler: Sampler) -> Duration? {
            switch sampler {
            case .cpu: cpu
            case .gpu: gpu
            case .battery: battery
            case .memory: memory
            case .apps: apps
            }
        }
    }

    private var schedule: Schedule {
        let page = isWindowVisible ? selection : nil
        let anyVisible = isWindowVisible || isMenuBarPanelVisible
        let showsCPU = isMenuBarPanelVisible || page == .overview || page == .performance
        let showsApps = isMenuBarPanelVisible || page == .overview || page == .apps || page == .memory
        return Schedule(
            cpu: showsCPU ? .seconds(1) : nil,
            gpu: page == .performance ? .seconds(2) : (showsCPU ? .seconds(4) : nil),
            gpuProcesses: page == .performance,
            // In the background the charger's plug and unplug events still arrive straight away.
            battery: page == .battery ? .seconds(2) : (anyVisible ? .seconds(10) : .seconds(120)),
            memory: anyVisible ? .seconds(5) : .seconds(60),
            apps: showsApps ? .seconds(5) : .seconds(60))
    }

    private var lastRun: [Sampler: ContinuousClock.Instant] = [:]

    /// Starts the sampling loop again with the schedule for what's on screen now.
    private func restartSampling() {
        liveTask?.cancel()
        // Measure CPU from now on, rather than averaging over the time nothing showed it.
        if schedule.cpu != nil && lastRun[.cpu].map({ ContinuousClock.now - $0 > .seconds(3) }) ?? true {
            _ = cpuSampler.sample()
            lastRun[.cpu] = .now
        }
        liveTask = Task { [weak self] in await self?.samplingLoop() }
    }

    private func samplingLoop() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let plan = schedule
            var nextWake = clock.now + .seconds(120)
            for sampler in Sampler.allCases {
                guard let interval = plan.interval(for: sampler) else { continue }
                if let last = lastRun[sampler], clock.now - last < interval {
                    nextWake = min(nextWake, last + interval)
                    continue
                }
                await run(sampler, plan: plan)
                lastRun[sampler] = clock.now
                nextWake = min(nextWake, clock.now + interval)
            }
            // Tolerance lets macOS group these wake-ups with others, which saves battery.
            let shortest = Sampler.allCases.compactMap { plan.interval(for: $0) }.min() ?? .seconds(60)
            try? await clock.sleep(until: nextWake, tolerance: shortest / 10)
        }
    }

    private func run(_ sampler: Sampler, plan: Schedule) async {
        switch sampler {
        case .cpu: sampleCPU()
        case .gpu: sampleGPU(processes: plan.gpuProcesses)
        case .battery: await sampleBattery()
        case .memory:
            snapshot.memory = MemoryCollector.collect()
            if !isScanning { updateFindings() }
        case .apps:
            snapshot.apps = await appsSampler.sample()
            checkQuitRequests()
            if !isScanning { updateFindings() }
        }
    }

    private func sampleCPU() {
        guard let load = cpuSampler.sample() else { return }
        cpuNow = load
        cpuHistory.append(load.total)
        if cpuHistory.count > 120 { cpuHistory.removeFirst(cpuHistory.count - 120) }
    }

    private func sampleGPU(processes: Bool) {
        guard var gpu = gpuSampler.sample(includeProcesses: processes) else { return }
        // Per-app GPU use is only measured while the CPU & GPU page is open; keep the last reading.
        if !processes { gpu.processes = snapshot.gpu?.processes ?? [] }
        snapshot.gpu = gpu
        gpuHistory.append(Double(gpu.deviceUtilization) / 100)
        if gpuHistory.count > 90 { gpuHistory.removeFirst(gpuHistory.count - 90) }
    }

    private func sampleBattery() async {
        guard snapshot.hasBattery, let battery = await BatteryCollector.readLive() else { return }
        // Keep the condition from the full scan; the live read skips the slower lookups.
        var merged = battery
        if merged.condition == nil { merged.condition = snapshot.battery?.condition }
        snapshot.battery = merged

        if let t = merged.telemetry, isWindowVisible && selection == .battery {
            powerHistory.append(PowerSample(date: Date(), input: t.systemInput, battery: t.battery, system: t.systemLoad))
            if powerHistory.count > 300 { powerHistory.removeFirst(powerHistory.count - 300) }
        }
        updateChargeLog(with: merged)
    }

    /// Opens a session when the charger is connected and closes it when it's removed.
    private func updateChargeLog(with battery: BatteryInfo) {
        let openIndex = chargeSessions.lastIndex { $0.end == nil }
        let power = battery.telemetry?.systemInput ?? 0
        switch (battery.externalConnected, openIndex) {
        case (true, nil):
            chargeSessions.append(ChargeSession(start: Date(), adapterName: battery.adapter?.name, adapterWatts: battery.adapter?.watts,
                                                startPercent: battery.chargePercent, peakWatts: power,
                                                startedBeforeLaunch: lastScan == nil))
            ChargeLogStore.save(chargeSessions)
        case (true, let index?):
            chargeSessions[index].lastSeen = Date()
            if power > chargeSessions[index].peakWatts + 1 || Date().timeIntervalSince(lastChargeSave) > 60 {
                chargeSessions[index].peakWatts = max(chargeSessions[index].peakWatts, power)
                ChargeLogStore.save(chargeSessions)
                lastChargeSave = Date()
            }
            if chargeSessions[index].adapterName == nil, let adapter = battery.adapter {
                chargeSessions[index].adapterName = adapter.name
                chargeSessions[index].adapterWatts = adapter.watts
            }
        case (false, let index?):
            chargeSessions[index].end = Date()
            chargeSessions[index].endPercent = battery.chargePercent
            ChargeLogStore.save(chargeSessions)
        case (false, nil):
            break
        }
    }

    // MARK: Apps

    func quit(_ app: RunningApp) {
        guard app.canQuit else { return }
        if AppsSampler.quit(pid: app.pid) {
            quitRequests[app.pid] = Date()
            show("Asked \(app.name) to quit")
        } else {
            show("\(app.name) didn't accept the request to quit.")
        }
    }

    func quitIdleApps() {
        let idle = (snapshot.apps ?? []).filter(\.isIdle)
        for app in idle where AppsSampler.quit(pid: app.pid) { quitRequests[app.pid] = Date() }
        show("Asked \(idle.count) idle app\(idle.count == 1 ? "" : "s") to quit")
    }

    func forceQuit(_ app: RunningApp) {
        if AppsSampler.forceQuit(pid: app.pid) {
            quitRequests[app.pid] = nil
            show("Force quit \(app.name)")
        }
    }

    /// True when the app was asked to quit over 5 seconds ago and is still running,
    /// usually because it's waiting on a save prompt or isn't responding.
    func isStuckQuitting(_ app: RunningApp) -> Bool {
        guard let asked = quitRequests[app.pid] else { return false }
        return Date().timeIntervalSince(asked) > 5
    }

    private func checkQuitRequests() {
        guard !quitRequests.isEmpty else { return }
        quitRequests = quitRequests.filter { AppsSampler.isRunning(pid: $0.key) }
    }

    func requestRestart() {
        if !SystemActions.requestRestart() {
            show("Couldn't open the restart dialog. Choose Apple menu → Restart instead.")
        }
    }

    // MARK: Speed test

    func runSpeedTest() {
        guard !speedTest.isRunning else { return }
        let runner = SpeedTestRunner()
        speedRunner = runner
        speedTest = SpeedTestState(phase: .starting, startedAt: Date(), result: speedTest.result)
        Task { [weak self] in
            for await event in runner.run() {
                guard let self, self.speedRunner === runner else { return }
                switch event {
                case .progress(let down, let up, let rpm):
                    self.speedTest.downloadMbps = down
                    self.speedTest.uploadMbps = up
                    self.speedTest.responsivenessRPM = rpm
                    let seconds = Date().timeIntervalSince(self.speedTest.startedAt ?? Date())
                    if up > 0 {
                        self.speedTest.phase = .upload
                        self.speedTest.uploadSeries.append(SpeedSample(seconds: seconds, mbps: up))
                    } else if down > 0 {
                        self.speedTest.phase = .download
                        self.speedTest.downloadSeries.append(SpeedSample(seconds: seconds, mbps: down))
                    }
                case .finished(let result):
                    self.speedTest.phase = result == nil ? .failed("The test didn't return any results.") : .done
                    self.speedTest.result = result ?? self.speedTest.result
                    self.speedTest.finishedAt = Date()
                case .failed(let message):
                    self.speedTest.phase = .failed(message)
                }
            }
            if self?.speedRunner === runner { self?.speedRunner = nil }
        }
    }

    func cancelSpeedTest() {
        let runner = speedRunner
        speedRunner = nil
        runner?.cancel()
        speedTest.phase = .idle
        speedTest.downloadSeries = []
        speedTest.uploadSeries = []
    }

    // MARK: Other actions

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

    // MARK: Apple Intelligence

    /// Writes the Overview's summary for the latest scan, once, when the Overview is on screen.
    func ensureSummary() {
        intelligence.checkAvailabilityIfNeeded()
        guard intelligence.isAvailable, let scanned = lastScan, summaryScan != scanned else { return }
        summaryScan = scanned
        let value = snapshot.value
        intelligence.generate(key: "summary", instructions: AIPrompts.summaryInstructions,
                              prompt: AIPrompts.summary(snapshot: value, findings: findings), force: true)
    }

    func regenerateSummary() {
        summaryScan = nil
        ensureSummary()
    }

    func explain(_ finding: Finding) {
        intelligence.generate(key: "finding.\(finding.id)", instructions: AIPrompts.explainInstructions,
                              prompt: AIPrompts.finding(finding, snapshot: snapshot.value, findings: findings))
    }

    func explain(_ item: StartupItem) {
        intelligence.generate(key: "startup.\(item.id)", instructions: AIPrompts.explainInstructions,
                              prompt: AIPrompts.startupItem(item))
    }

    func explain(_ group: CrashGroup) {
        guard let latest = group.reports.max(by: { $0.date < $1.date }) else { return }
        let key = "crash.\(group.process)"
        Task {
            let summary = await offMain { CrashReportReader.summary(of: latest.url) }
            intelligence.generate(key: key, instructions: AIPrompts.explainInstructions,
                                  prompt: AIPrompts.crash(group, reportSummary: summary))
        }
    }

    func show(_ message: String) {
        banner = message
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.banner = nil }
        }
    }

    var reportText: String { ReportBuilder.text(snapshot: snapshot.value, findings: findings) }
}

/// Calls back on the main thread whenever macOS reports a power source change: the charger
/// connected or removed, or the charge level changing.
@MainActor
final class PowerSourceObserver {
    private var source: CFRunLoopSource?
    private let onChange: @MainActor () -> Void

    /// Lives as long as the app, so the run loop source is never removed.
    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource(Self.callback, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    /// Runs on the main run loop, where the source was added.
    private nonisolated static let callback: IOPowerSourceCallbackType = { context in
        // The address is a plain number, which can cross to the main actor safely.
        guard let address = context.map({ UInt(bitPattern: $0) }) else { return }
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
            Unmanaged<PowerSourceObserver>.fromOpaque(pointer).takeUnretainedValue().onChange()
        }
    }
}
