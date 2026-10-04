import DiagnoCore
import Foundation

extension DiagnosticsSection {
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
    /// Parts whose readings name a process or app the question mentions, like "What is intelligencetasksd?".
    static func naming(_ question: String, in s: DiagnosticsSnapshot) -> [DiagnosticsSection] {
        let words = QuestionWords(question)
        // Shorter names, like the "cp" command, are ordinary words too often.
        func named(_ names: [String]) -> Bool { names.contains { $0.count >= 4 && words.mention($0) } }
        var sections: [DiagnosticsSection] = []
        if named(s.logs?.groups(since: Date().addingTimeInterval(-7 * 86_400)).map(\.process) ?? []) { sections.append(.crashes) }
        if named(s.performance?.topByCPU.map(\.name) ?? []) { sections.append(.cpu) }
        if named(s.apps?.map(\.name) ?? []) { sections.append(.apps) }
        return sections
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
            lines.append("Problems, most serious first:")
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
        var lines = ["Charge \(b.chargePercent)%. Maximum capacity \(b.healthPercent.map { "\($0)%" } ?? "unknown") of when it was new. \(b.cycleCount) of \(b.designCycleCount) rated cycles. Condition \(b.condition ?? "unknown")."]
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
                                t.systemInput, t.systemLoad, t.battery, max(0, t.adapterLoss)))
        } else if let w = b.watts {
            lines.append(String(format: "Battery power draw %.1f W.", abs(w)))
        }
        if let temp = b.temperatureC { lines.append(String(format: "Battery temperature %.1f °C.", temp)) }
        return lines.joined(separator: "\n")
    }

    private static func cpu(_ s: DiagnosticsSnapshot) -> String {
        guard let p = s.performance else { return "CPU not read yet." }
        // In plain words, because the small model gets comparisons between numbers wrong.
        let cores = Double(s.machine?.totalCores ?? 0)
        let load = p.loadAverage.first ?? 0
        let level = cores == 0 ? "" : load < cores * 0.5 ? ", light: the CPU has room to spare" : load < cores ? ", busy" : ", overloaded: more work than cores"
        let heat = switch p.thermalState {
        case .nominal: "not overheating"
        case .fair: "warm"
        case .serious, .critical: "too hot, so macOS is slowing it down to cool off"
        @unknown default: "unknown"
        }
        var lines = ["Load average " + p.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / ") + " (1/5/15 min) on \(Int(cores)) cores\(level). Thermal state \(p.thermalState.label.lowercased()): \(heat)."]
        lines.append("Top processes by CPU:")
        // Not DiagnoMac: these are measured during its scan, and the model blames the scan for whatever was asked.
        for proc in p.topByCPU.filter({ $0.pid != ProcessInfo.processInfo.processIdentifier }).prefix(6) {
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
        let pressure = switch m.pressure {
        case .normal: "normal, so the Mac has enough memory"
        case .warning: "elevated, so memory is getting tight"
        case .critical: "critical, so the Mac is short of memory"
        }
        var lines = ["Memory pressure \(pressure). \(m.availablePercent)% available of \(Format.bytes(m.total, style: .memory)). Swap \(Format.memory(m.swapUsed)) of \(Format.memory(m.swapTotal)). \(m.pageouts) page-outs since startup. Compressed \(Format.memory(m.compressed)), wired \(Format.memory(m.wired))."]
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
        if !idle.isEmpty {
            lines.append("Idle apps, open but unused, safe to quit: \(list(idle)).")
        } else if apps.contains(where: { $0.observedSeconds >= 15 }) {
            lines.append("Idle apps: none. Every app with a window is in front or doing work.")
        } else {
            lines.append("Idle apps: not known yet. DiagnoMac needs a few more seconds to see which apps are unused.")
        }
        if !active.isEmpty { lines.append("Apps in use, keep open: \(list(active, cpu: true)).") }
        if !background.isEmpty { lines.append("Menu bar and background apps: \(list(background, cpu: true)).") }
        if !protected.isEmpty { lines.append("Never quit: \(protected.map(\.name).joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }

    private static func storage(_ s: DiagnosticsSnapshot) -> String {
        guard let st = s.storage else { return "Storage not read yet." }
        let free = st.totalBytes > 0 ? Double(st.availableBytes) / Double(st.totalBytes) : 1
        let room = free >= 0.2 ? "plenty of room" : free >= 0.1 ? "getting full" : "nearly full, which can slow the Mac down"
        var lines = ["The disk holds \(Format.gb(st.totalBytes)) and has \(Format.gb(st.availableBytes)) free: \(room). Drive SMART status \(st.smartStatus ?? "unknown")."]
        if let breakdown = s.storageBreakdown, breakdown.isComplete {
            lines.append("What's using space, measured \(Format.relative(breakdown.measuredAt)):")
            for category in breakdown.categories.prefix(8) {
                let inside = category.items.prefix(3).map { "\($0.name) \(Format.gb($0.bytes))" }.joined(separator: ", ")
                lines.append("- \(category.kind.title): \(Format.gb(category.bytes))\(inside.isEmpty ? "" : " (biggest: \(inside))")")
            }
            if !breakdown.suggestions.isEmpty {
                lines.append("Suggested for the Bin on DiagnoMac's Storage page, since they don't look used:")
                for suggestion in breakdown.suggestions.prefix(5) {
                    lines.append("- \(suggestion.item.name), \(Format.gb(suggestion.item.bytes)): \(suggestion.reason)")
                }
            }
        }
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
            let signal = w.rssi >= -50 ? "excellent" : w.rssi >= -60 ? "good" : w.rssi >= -70 ? "fair" : "weak"
            lines.append("Wi-Fi signal \(w.rssi) dBm (\(signal)), noise \(w.noise) dBm, SNR \(w.snr) dB (\(w.snr >= 25 ? "good" : "low")), channel \(w.channel ?? "?"), \(w.phyMode ?? ""), \(Int(w.txRateMbps)) Mbps link.")
        }
        if let p = n.ping {
            let speed = p.avgMs < 50 ? "good" : p.avgMs < 100 ? "fine for calls, slow for games" : "slow, calls may lag"
            lines.append(String(format: "Ping %@ %.0f ms average (%@), jitter %.1f ms, %.0f%% loss.", p.host, p.avgMs, speed, p.jitterMs, p.lossPercent))
        }
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
