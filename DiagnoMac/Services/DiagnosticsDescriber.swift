import Foundation

/// The parts of the scan the assistant can read.
enum DiagnosticsSection: String, CaseIterable, Sendable {
    case overview, battery, cpu, gpu, memory, apps, storage, backup, network, security, startup, crashes, devices

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// The readings that explain one finding. Narrower than its area, so the model stays on topic.
    init(finding: Finding) {
        switch finding.id {
        case "backup": self = .backup
        case "memory": self = .memory
        case "idle-apps": self = .apps
        case "load", "thermal": self = .cpu
        default:
            if finding.id.hasPrefix("bt-") { self = .devices } else { self.init(area: finding.area) }
        }
    }

    /// The section most relevant to explaining a finding in this area.
    init(area: Area) {
        switch area {
        case .battery: self = .battery
        case .performance: self = .cpu
        case .memory: self = .memory
        case .apps: self = .apps
        case .storage: self = .storage
        case .network: self = .network
        case .security: self = .security
        case .startup: self = .startup
        case .logs: self = .crashes
        case .devices: self = .devices
        default: self = .overview
        }
    }
}

extension DiagnosticsSection {
    /// Picks the readings a question is about, so the model gets the right facts up front
    /// instead of relying on it to call the right tools. Overview always comes first.
    static func relevant(to question: String, limit: Int = 3) -> [DiagnosticsSection] {
        let q = question.lowercased()
        let routes: [([String], [DiagnosticsSection])] = [
            (["slow", "speed up", "lag", "sluggish", "performance", "hot", "fan", "beach ball"], [.memory, .apps, .cpu]),
            (["app", "quit", "close", "running", "open"], [.apps, .memory]),
            (["memory", "ram", "swap"], [.memory, .apps]),
            (["battery", "charge", "charging", "charger", "power", "adapter"], [.battery]),
            (["disk", "storage", "space", "delete", "clean", "free up", "cache", "ssd"], [.storage, .backup]),
            (["backup", "time machine"], [.backup]),
            (["wifi", "wi-fi", "internet", "network", "router", "speed test", "download"], [.network]),
            (["secure", "security", "virus", "malware", "firewall", "hack", "filevault"], [.security]),
            (["crash", "freeze", "froze", "hang", "panic", "quit unexpectedly"], [.crashes]),
            (["gpu", "graphics", "display", "screen"], [.gpu]),
            (["cpu", "processor", "process"], [.cpu]),
            (["bluetooth", "mouse", "keyboard", "airpods", "headphone", "accessor", "device", "usb"], [.devices]),
            (["startup", "login", "boot", "background", "agent", "launch"], [.startup]),
        ]
        var picked: [DiagnosticsSection] = [.overview]
        for (words, sections) in routes where words.contains(where: q.contains) {
            for section in sections where !picked.contains(section) { picked.append(section) }
        }
        return Array(picked.prefix(limit))
    }
}

/// Renders readings as short plain text for the on-device model, which has a small context window.
/// Never includes serial numbers, network names or hardware identifiers.
enum DiagnosticsDescriber {
    static func describe(_ section: DiagnosticsSection, _ s: DiagnosticsSnapshot, findings: [Finding]) -> String {
        let text: String
        switch section {
        case .overview: text = overview(s, findings)
        case .battery: text = battery(s)
        case .cpu: text = cpu(s)
        case .gpu: text = gpu(s)
        case .memory: text = memory(s)
        case .apps: text = apps(s)
        case .storage: text = storage(s)
        case .backup: text = backup(s)
        case .network: text = network(s)
        case .security: text = security(s)
        case .startup: text = startup(s)
        case .crashes: text = crashes(s)
        case .devices: text = devices(s)
        }
        return String(text.prefix(1400))
    }

    private static func overview(_ s: DiagnosticsSnapshot, _ findings: [Finding]) -> String {
        var lines: [String] = []
        if let m = s.machine {
            lines.append("\(m.modelName), \(m.chip), \(Format.bytes(m.memoryBytes, style: .memory)) memory, macOS \(m.osVersion), up \(Format.duration(m.uptime)).")
        }
        lines.append("Health score \(FindingsEngine.score(findings))/100.")
        if findings.isEmpty {
            lines.append("No problems found.")
        } else {
            lines.append("Findings, most serious first:")
            for f in findings.prefix(7) {
                let fix = f.actionTitle.map { " Fix in DiagnoMac: \($0.replacingOccurrences(of: "…", with: ""))." } ?? ""
                lines.append("- [\(f.severity.label)] \(f.title). \(f.detail)\(fix)")
            }
        }
        var vitals: [String] = []
        if let b = s.battery { vitals.append("battery \(b.chargePercent)%\(b.isCharging ? " charging" : "")") }
        if let m = s.memory { vitals.append("memory pressure \(m.pressure.label.lowercased()), swap \(Format.percent(m.swapFraction))") }
        if let p = s.performance, let load = p.loadAverage.first { vitals.append(String(format: "CPU load %.2f", load)) }
        if let g = s.gpu { vitals.append("GPU \(g.deviceUtilization)%") }
        if let st = s.storage { vitals.append("\(Format.gb(st.availableBytes, digits: 0)) free") }
        if let backup = s.backup { vitals.append(backup.isConfigured ? "Time Machine on" : "no Time Machine backup") }
        if !vitals.isEmpty { lines.append("Vitals: " + vitals.joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }

    private static func battery(_ s: DiagnosticsSnapshot) -> String {
        guard let b = s.battery else { return s.hasBattery ? "Battery not read yet." : "This Mac has no battery." }
        var lines = ["Charge \(b.chargePercent)%. Health \(b.healthPercent.map { "\($0)%" } ?? "unknown") of original capacity. \(b.cycleCount) of \(b.designCycleCount) rated cycles. Condition \(b.condition ?? "unknown")."]
        if b.isCharging {
            lines.append("Charging" + (b.minutesToFull.map { ", full in \(Format.minutes($0))" } ?? "") + ".")
        } else if b.externalConnected {
            lines.append("On power adapter, not charging\(b.fullyCharged ? " (full)" : "").")
        } else if let m = b.minutesToEmpty {
            lines.append("On battery, about \(Format.minutes(m)) left.")
        }
        if let a = b.adapter { lines.append("Charger: \(a.name), negotiated \(a.watts) W.") }
        if let t = b.telemetry, b.externalConnected {
            lines.append(String(format: "Power: %.1f W in from charger, %.1f W running the Mac, %+.1f W into the battery, %.1f W lost as heat.",
                                t.systemInput, t.systemLoad, t.battery, t.adapterLoss))
        } else if let w = b.watts {
            lines.append(String(format: "Battery power draw %.1f W.", abs(w)))
        }
        if let temp = b.temperatureC { lines.append(String(format: "Battery temperature %.1f °C.", temp)) }
        return lines.joined(separator: "\n")
    }

    private static func cpu(_ s: DiagnosticsSnapshot) -> String {
        guard let p = s.performance else { return "CPU not read yet." }
        var lines = ["Load average " + p.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / ") + " (1/5/15 min) on \(s.machine?.totalCores ?? 0) cores. Thermal state \(p.thermalState.label.lowercased())."]
        lines.append("Top processes by CPU:")
        for proc in p.topByCPU.prefix(6) {
            lines.append(String(format: "- %@ %.0f%%", proc.name, proc.cpuPercent) + (PerformanceCollector.owningApp(for: proc.path).map { " (\($0))" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    private static func gpu(_ s: DiagnosticsSnapshot) -> String {
        guard let g = s.gpu else { return "GPU not read yet." }
        var lines = ["GPU \(g.deviceUtilization)% busy (rendering \(g.rendererUtilization)%, geometry \(g.tilerUtilization)%). \(Format.memory(g.inUseMemory)) GPU memory in use. \(s.machine?.gpuCores.map { "\($0)-core GPU." } ?? "")"]
        if !g.processes.isEmpty {
            lines.append("Using the GPU now:")
            for p in g.processes.prefix(6) { lines.append(String(format: "- %@ %.0f%%", p.name, p.percent)) }
        }
        return lines.joined(separator: "\n")
    }

    private static func memory(_ s: DiagnosticsSnapshot) -> String {
        guard let m = s.memory else { return "Memory not read yet." }
        var lines = ["Pressure \(m.pressure.label.lowercased()), \(m.availablePercent)% available of \(Format.bytes(m.total, style: .memory)). Swap \(Format.memory(m.swapUsed)) of \(Format.memory(m.swapTotal)). \(m.pageouts) page-outs since startup. Compressed \(Format.memory(m.compressed)), wired \(Format.memory(m.wired))."]
        if let apps = s.apps, !apps.isEmpty {
            let top = apps.prefix(6).map { "\($0.name) \(Format.bytes($0.memoryBytes, style: .memory))\($0.isIdle ? " idle" : "")" }
            lines.append("Apps using the most memory: \(top.joined(separator: ", ")).")
            let idle = apps.filter(\.isIdle)
            if !idle.isEmpty {
                lines.append("Quitting the idle apps would free about \(Format.bytes(idle.reduce(0) { $0 + $1.memoryBytes }, style: .memory)).")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func apps(_ s: DiagnosticsSnapshot) -> String {
        guard let apps = s.apps, !apps.isEmpty else { return "Running apps not read yet." }
        func list(_ group: [RunningApp], cpu: Bool = false) -> String {
            group.prefix(8).map { a in
                "\(a.name) \(Format.bytes(a.memoryBytes, style: .memory))" + (cpu ? String(format: " (%.0f%% CPU)", a.averageCPU) : "")
            }.joined(separator: ", ")
        }
        let idle = apps.filter(\.isIdle)
        let active = apps.filter { !$0.isIdle && $0.canQuit && $0.kind == .window }
        let background = apps.filter { !$0.isIdle && $0.canQuit && $0.kind != .window }
        let protected = apps.filter { !$0.canQuit }
        var lines = ["\(apps.count) apps open, using \(Format.bytes(apps.reduce(0) { $0 + $1.memoryBytes }, style: .memory)) in total."]
        lines.append(idle.isEmpty ? "Idle apps: none yet." : "Idle apps, open but unused, safe to quit: \(list(idle)).")
        if !active.isEmpty { lines.append("Apps in use, keep open: \(list(active, cpu: true)).") }
        if !background.isEmpty { lines.append("Menu bar and background apps: \(list(background, cpu: true)).") }
        if !protected.isEmpty { lines.append("Never quit: \(protected.map(\.name).joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }

    private static func storage(_ s: DiagnosticsSnapshot) -> String {
        guard let st = s.storage else { return "Storage not read yet." }
        var lines = ["\(Format.gb(st.availableBytes)) free of \(Format.gb(st.totalBytes)). Drive SMART status \(st.smartStatus ?? "unknown")."]
        if !st.cleanup.isEmpty {
            lines.append("Cleanup candidates:")
            for c in st.cleanup.prefix(6) { lines.append("- \(c.title): \(c.bytes.map { Format.gb($0) } ?? "?"). \(c.explanation)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func backup(_ s: DiagnosticsSnapshot) -> String {
        guard let b = s.backup else { return "Backups not read yet." }
        guard b.isConfigured else { return "Time Machine has no backup disk set up. Nothing on this Mac is being backed up." }
        let last = b.latestBackup.map { "Last backup \(Format.relative($0))." } ?? "Last backup date unknown."
        return "Time Machine backs up to \(b.destinations.count) disk(s). \(last) Automatic backups \(b.autoBackup == false ? "off" : "on")."
    }

    private static func network(_ s: DiagnosticsSnapshot) -> String {
        guard let n = s.network else { return "Network not read yet." }
        var lines = ["\(n.interfaceKind), \(n.isConnected ? "connected" : "offline")."]
        if let w = n.wifi {
            lines.append("Wi-Fi signal \(w.rssi) dBm, noise \(w.noise) dBm, SNR \(w.snr) dB, channel \(w.channel ?? "?"), \(w.phyMode ?? ""), \(Int(w.txRateMbps)) Mbps link.")
        }
        if let p = n.ping { lines.append(String(format: "Ping %@ %.0f ms average, jitter %.1f ms, %.0f%% loss.", p.host, p.avgMs, p.jitterMs, p.lossPercent)) }
        for c in n.checks { lines.append("- \(c.title): \(c.passed ? "pass" : "FAIL"), \(c.detail)") }
        return lines.joined(separator: "\n")
    }

    private static func security(_ s: DiagnosticsSnapshot) -> String {
        guard let sec = s.security else { return "Security not read yet." }
        return sec.checks.map { "- \($0.title): \($0.status)" }.joined(separator: "\n")
    }

    private static func startup(_ s: DiagnosticsSnapshot) -> String {
        guard let items = s.startup else { return "Startup items not read yet." }
        guard !items.isEmpty else { return "No third-party startup items." }
        return items.prefix(14).map {
            "- \($0.label) (\($0.scope.rawValue.lowercased())\($0.isDisabled ? ", turned off" : "")\($0.isLoaded == true ? ", running" : ""))"
        }.joined(separator: "\n")
    }

    private static func crashes(_ s: DiagnosticsSnapshot) -> String {
        guard let logs = s.logs else { return "Crash logs not read yet." }
        let week = Date().addingTimeInterval(-7 * 86_400)
        var lines = ["Kernel panics in the last 7 days: \(logs.panics.filter { $0.date >= week }.count)."]
        let groups = logs.groups(since: week)
        if groups.isEmpty { lines.append("No app crashes in the last 7 days.") }
        for g in groups.prefix(6) {
            lines.append("- \(g.process): \(g.count) reports (\(g.kinds.map(\.rawValue).joined(separator: ", ")))\(g.isFirstParty ? ", part of macOS" : "")")
        }
        return lines.joined(separator: "\n")
    }

    private static func devices(_ s: DiagnosticsSnapshot) -> String {
        var lines: [String] = []
        if let d = s.devices {
            for bt in d.bluetooth.prefix(8) {
                let battery = bt.batteryLevels.map { "\($0.label.isEmpty ? "" : $0.label + " ")\($0.percent)%" }.joined(separator: ", ")
                lines.append("- \(bt.name) (\(bt.kind ?? "Bluetooth"), \(bt.isConnected ? "connected" : "not connected")\(battery.isEmpty ? "" : ", battery " + battery))")
            }
            for u in d.usb.prefix(6) { lines.append("- USB: \(u.name)") }
        }
        for display in s.machine?.displays ?? [] { lines.append("- Display: \(display.name) \(display.pixels) \(display.resolution)") }
        if let a = s.battery?.adapter { lines.append("- Charger: \(a.name), \(a.watts) W") }
        return lines.isEmpty ? "No devices found." : lines.joined(separator: "\n")
    }
}
