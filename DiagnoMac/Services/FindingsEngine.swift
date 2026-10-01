import Foundation

/// Everything one scan collected. Sections stay nil until their collector finishes.
struct DiagnosticsSnapshot: Sendable {
    var machine: MachineInfo?
    var battery: BatteryInfo?
    var hasBattery = true
    var power: PowerSettings?
    var performance: PerformanceInfo?
    var memory: MemoryInfo?
    var storage: StorageInfo?
    var network: NetworkInfo?
    var security: SecurityInfo?
    var startup: [StartupItem]?
    var logs: LogsInfo?
    var gpu: GPUInfo?
    var apps: [RunningApp]?
    var backup: BackupInfo?
    var devices: DevicesInfo?
    var takenAt = Date()
}

/// Turns raw readings into ranked, actionable findings.
enum FindingsEngine {
    static func findings(for s: DiagnosticsSnapshot) -> [Finding] {
        var out: [Finding] = []

        if let security = s.security {
            for check in security.checks where check.severity >= .warning {
                switch check.id {
                case "firewall":
                    out.append(Finding(id: "firewall", severity: .critical, area: .security, title: "Firewall is off",
                                       detail: check.detail, actionTitle: "Turn On Firewall…", action: .enableFirewall))
                case "filevault":
                    out.append(Finding(id: "filevault", severity: .critical, area: .security, title: "FileVault is off",
                                       detail: check.detail, actionTitle: "Open Settings",
                                       action: .openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?FDE")!)))
                default:
                    out.append(Finding(id: check.id, severity: check.severity, area: .security, title: "\(check.title) is \(check.status.lowercased())",
                                       detail: check.detail, actionTitle: "View Security", action: .navigate(.security)))
                }
            }
        }

        if let b = s.battery {
            if let health = b.healthPercent, health < 80 {
                out.append(Finding(id: "battery-health", severity: .warning, area: .battery, title: "Battery capacity is \(health)%",
                                   detail: "Below 80% Apple recommends a battery service. Expect noticeably shorter battery life.",
                                   actionTitle: "View Battery", action: .navigate(.battery)))
            }
            if let condition = b.condition, condition != "Normal" {
                out.append(Finding(id: "battery-condition", severity: .warning, area: .battery, title: "Battery condition: \(condition)",
                                   detail: "macOS reports the battery needs attention.", actionTitle: "View Battery", action: .navigate(.battery)))
            }
            if b.cycleCount > Int(Double(b.designCycleCount) * 0.85) {
                out.append(Finding(id: "battery-cycles", severity: .info, area: .battery, title: "\(b.cycleCount) battery cycles",
                                   detail: "The battery is rated for \(b.designCycleCount) cycles.", actionTitle: "View Battery", action: .navigate(.battery)))
            }
        }

        let idleApps = (s.apps ?? []).filter(\.isIdle)
        let idleBytes = idleApps.reduce(UInt64(0)) { $0 + $1.memoryBytes }

        if let m = s.memory {
            if m.pressure != .normal || m.swapFraction > 0.6 {
                let severity: Severity = m.pressure == .critical ? .critical : .warning
                let biggestIdle = idleApps.max { $0.memoryBytes < $1.memoryBytes }
                    .map { " \($0.name) is holding \(Format.bytes($0.memoryBytes, style: .memory)) while idle." } ?? " Apps are being pushed out of RAM."
                out.append(Finding(id: "memory", severity: severity, area: .memory,
                                   title: m.swapFraction > 0.6 ? "Swap is \(Format.percent(m.swapFraction)) full" : "Memory pressure is \(m.pressure.label.lowercased())",
                                   detail: "\(Format.memory(m.swapUsed)) of \(Format.memory(m.swapTotal)) swap in use, with \(m.pageouts.formatted()) page-outs." + biggestIdle,
                                   actionTitle: "Relieve Memory", action: .navigate(.memory)))
            }
        }

        if idleBytes > 1_000_000_000 {
            let names = ListFormatter.localizedString(byJoining: idleApps.prefix(4).map(\.name))
            out.append(Finding(id: "idle-apps", severity: .info, area: .apps,
                               title: "\(idleApps.count) idle apps are using \(Format.bytes(idleBytes, style: .memory))",
                               detail: "\(names) \(idleApps.count == 1 ? "has" : "have") used no CPU recently but still hold memory.",
                               actionTitle: "Review Apps", action: .navigate(.apps)))
        }

        if let backup = s.backup {
            let settings = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!
            if !backup.isConfigured {
                out.append(Finding(id: "backup", severity: .warning, area: .storage, title: "No Time Machine backup",
                                   detail: "No backup disk is set up. If this SSD fails or the Mac is lost, your files can't be recovered.",
                                   actionTitle: "Set Up Time Machine…", action: .openURL(settings)))
            } else if let days = backup.daysSinceBackup, days > 7 {
                out.append(Finding(id: "backup", severity: .warning, area: .storage, title: "Last backup was \(days) days ago",
                                   detail: "Time Machine hasn't completed a backup for over a week. Connect your backup disk.",
                                   actionTitle: "Open Time Machine", action: .openURL(settings)))
            }
        }

        if let devices = s.devices {
            for device in devices.bluetooth where device.isConnected {
                guard let level = device.lowestBattery, level < 20 else { continue }
                out.append(Finding(id: "bt-\(device.name)", severity: level < 10 ? .warning : .info, area: .devices,
                                   title: "\(device.name) battery at \(level)%",
                                   detail: "Charge it soon so it doesn't die mid-use.", actionTitle: "View Devices", action: .navigate(.devices)))
            }
        }

        if let p = s.performance, let cores = s.machine?.totalCores, cores > 0 {
            let load = p.loadAverage.first ?? 0
            if load > Double(cores) * 0.6 {
                let top = p.topByCPU.first
                out.append(Finding(id: "load", severity: load > Double(cores) ? .warning : .info, area: .performance,
                                   title: "High CPU load",
                                   detail: String(format: "Load average %.2f on %d cores.", load, cores) + (top.map { " \($0.name) is using \(Int($0.cpuPercent))% CPU." } ?? ""),
                                   actionTitle: "View Processes", action: .navigate(.performance)))
            }
            if p.thermalState == .serious || p.thermalState == .critical {
                out.append(Finding(id: "thermal", severity: .critical, area: .performance, title: "Mac is thermally throttling",
                                   detail: "Thermal state is \(p.thermalState.label.lowercased()). Performance is being reduced to cool down.",
                                   actionTitle: "View Performance", action: .navigate(.performance)))
            }
        }

        if let st = s.storage {
            if st.freeFraction < 0.1 {
                out.append(Finding(id: "disk-low", severity: st.freeFraction < 0.05 ? .critical : .warning, area: .storage,
                                   title: "Only \(Format.gb(st.availableBytes)) free",
                                   detail: "macOS needs free space for swap, updates and snapshots.", actionTitle: "Review Cleanup", action: .navigate(.storage)))
            }
            if let smart = st.smartStatus, smart != "Verified", smart != "Not Supported" {
                out.append(Finding(id: "smart", severity: .critical, area: .storage, title: "Drive SMART status: \(smart)",
                                   detail: "The SSD reports a fault. Back up now.", actionTitle: "View Storage", action: .navigate(.storage)))
            }
            let reclaimable = st.reclaimableBytes
            if reclaimable > 5_000_000_000 {
                let biggest = st.cleanup.first { if case .trashContents = $0.method { true } else { false } }
                    .map { " \($0.title) is the largest." } ?? ""
                out.append(Finding(id: "cleanup", severity: .info, area: .storage, title: "\(Format.gb(reclaimable, digits: 0)) can be reclaimed",
                                   detail: "Caches and developer files you can safely remove." + biggest,
                                   actionTitle: "Review Cleanup", action: .navigate(.storage)))
            }
        }

        if let n = s.network {
            for check in n.checks where !check.passed && check.id != "ipv6" {
                out.append(Finding(id: "net-\(check.id)", severity: .warning, area: .network, title: "\(check.title) failed",
                                   detail: check.detail, actionTitle: "View Network", action: .navigate(.network)))
            }
            if let wifi = n.wifi, wifi.snr < 20 {
                out.append(Finding(id: "wifi-weak", severity: .warning, area: .network, title: "Weak Wi-Fi signal",
                                   detail: "Signal-to-noise ratio is \(wifi.snr) dB. Move closer to the router or switch to 5 GHz.",
                                   actionTitle: "View Network", action: .navigate(.network)))
            }
            if let ping = n.ping, ping.lossPercent > 0, ping.lossPercent < 100 {
                out.append(Finding(id: "packet-loss", severity: .warning, area: .network, title: "\(Int(ping.lossPercent))% packet loss",
                                   detail: "Some packets to \(ping.host) were dropped. Calls and games will stutter.",
                                   actionTitle: "View Network", action: .navigate(.network)))
            }
        }

        if let items = s.startup {
            let active = items.filter { !$0.isDisabled && ($0.runAtLoad || $0.keepAlive) }
            if active.count >= 6 {
                out.append(Finding(id: "startup", severity: .info, area: .startup, title: "\(active.count) background items start at login",
                                   detail: "Each one costs memory, battery and boot time. Updaters are usually safe to turn off.",
                                   actionTitle: "Review Startup Items", action: .navigate(.startup)))
            }
        }

        if let logs = s.logs {
            let weekAgo = Date().addingTimeInterval(-7 * 86_400)
            let recentPanics = logs.panics.filter { $0.date >= weekAgo }
            if !recentPanics.isEmpty {
                out.append(Finding(id: "panic", severity: .critical, area: .logs, title: "\(recentPanics.count) kernel panic\(recentPanics.count == 1 ? "" : "s") this week",
                                   detail: "The Mac restarted because of a serious error. Hardware or a kernel extension may be at fault.",
                                   actionTitle: "View Crash Logs", action: .navigate(.logs)))
            }
            if let worst = logs.groups(since: weekAgo).first(where: { $0.reports.contains { $0.kind == .crash } }), worst.count >= 5 {
                out.append(Finding(id: "crashes", severity: .info, area: .logs, title: "\(worst.process) crashed \(worst.count) times",
                                   detail: worst.isFirstParty
                                       ? "A macOS system process is crashing repeatedly. It's usually fixed by the next macOS update; report it to Apple with Feedback Assistant if it persists."
                                       : "Repeated crashes in the last 7 days. Updating or reinstalling the app may help.",
                                   actionTitle: "View Crash Logs", action: .navigate(.logs)))
            }
        }

        return out.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.title < $1.title }
    }

    static func score(_ findings: [Finding]) -> Int {
        let penalty = findings.reduce(0) { total, f in
            total + (f.severity == .critical ? 12 : f.severity == .warning ? 6 : f.severity == .info ? 1 : 0)
        }
        return max(0, 100 - penalty)
    }

    static func worstSeverity(in area: Area, _ findings: [Finding]) -> Severity {
        findings.filter { $0.area == area }.map(\.severity).max() ?? .ok
    }
}
