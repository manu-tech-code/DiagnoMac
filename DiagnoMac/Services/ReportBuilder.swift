import Foundation

/// Plain-text summary for IT, Apple Support or a repair shop. Serial numbers are never included.
enum ReportBuilder {
    static func text(snapshot s: DiagnosticsSnapshot, findings: [Finding]) -> String {
        var lines: [String] = []
        let date = s.takenAt.formatted(date: .abbreviated, time: .shortened)
        lines.append("DiagnoMac report · \(date)")
        lines.append("Health score: \(FindingsEngine.score(findings))/100")

        if let m = s.machine {
            lines += ["", "MACHINE",
                      "  \(m.modelName) (\(m.modelIdentifier)), \(m.chip)",
                      "  \(m.totalCores) CPU cores (\(m.performanceCores) performance, \(m.efficiencyCores) efficiency)" + (m.gpuCores.map { ", \($0)-core GPU" } ?? ""),
                      "  \(Format.bytes(m.memoryBytes, style: .memory)) memory",
                      "  macOS \(m.osVersion) (\(m.osBuild)), uptime \(Format.duration(m.uptime))"]
            for d in m.displays { lines.append("  Display: \(d.name), \(d.pixels) pixels, \(d.resolution)") }
        }
        if let b = s.battery {
            lines += ["", "BATTERY",
                      "  \(b.healthPercent.map { "\($0)%" } ?? "?") maximum capacity, \(b.cycleCount) cycles, condition \(b.condition ?? "unknown")",
                      "  Full charge \(b.fullChargeCapacity.map(String.init) ?? "?") mAh / design \(b.designCapacity.map(String.init) ?? "?") mAh"]
            if let a = b.adapter {
                lines.append("  Charger: \(a.name), negotiated \(a.watts) W" + (b.isCharging ? ", charging at \(b.chargePercent)%" : ""))
            }
            if let t = b.telemetry, b.externalConnected {
                lines.append(String(format: "  Power: %.1f W in, %.1f W to the Mac, %+.1f W to the battery", t.systemInput, t.systemLoad, t.battery))
            }
        }
        if let st = s.storage {
            lines += ["", "STORAGE",
                      "  \(Format.gb(st.availableBytes)) free of \(Format.gb(st.totalBytes)), SMART \(st.smartStatus ?? "unknown")"]
        }
        if let backup = s.backup {
            lines.append(backup.isConfigured
                ? "  Time Machine: \(backup.destinations.joined(separator: ", ")), last backup \(backup.latestBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown")"
                : "  Time Machine: no backup disk set up")
        }
        if let m = s.memory {
            lines += ["", "MEMORY",
                      "  Pressure \(m.pressure.label.lowercased()), swap \(Format.memory(m.swapUsed)) / \(Format.memory(m.swapTotal)), \(m.pageouts) page-outs"]
        }
        if let p = s.performance {
            lines += ["", "CPU",
                      "  Load average " + p.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / ") + ", thermal \(p.thermalState.label.lowercased())"]
            for proc in p.topByCPU.prefix(5) { lines.append(String(format: "  %5.1f%%  %@", proc.cpuPercent, proc.name)) }
        }
        if let g = s.gpu {
            lines += ["", "GPU", "  \(g.deviceUtilization)% busy, \(Format.memory(g.inUseMemory)) in use"]
            for proc in g.processes.prefix(3) { lines.append(String(format: "  %5.1f%%  %@", proc.percent, proc.name)) }
        }
        if let apps = s.apps, !apps.isEmpty {
            let idle = apps.filter(\.isIdle)
            lines += ["", "APPS", "  \(apps.count) open, \(idle.count) idle"]
            for app in apps.prefix(5) { lines.append("  \(Format.bytes(app.memoryBytes, style: .memory))  \(app.name)\(app.isIdle ? " (idle)" : "")") }
        }
        if let n = s.network {
            lines += ["", "NETWORK", "  \(n.interfaceKind)\(n.interfaceName.map { " (\($0))" } ?? "")"]
            if let w = n.wifi { lines.append("  RSSI \(w.rssi) dBm, noise \(w.noise) dBm, SNR \(w.snr) dB, \(w.channel ?? "")") }
            if let p = n.ping { lines.append(String(format: "  Ping %@ avg %.1f ms, %.0f%% loss", p.host, p.avgMs, p.lossPercent)) }
        }
        if let devices = s.devices, !devices.bluetooth.isEmpty {
            lines += ["", "BLUETOOTH"]
            for d in devices.bluetooth {
                let battery = d.lowestBattery.map { ", battery \($0)%" } ?? ""
                lines.append("  \(d.name) (\(d.isConnected ? "connected" : "not connected")\(battery))")
            }
        }
        if let sec = s.security {
            lines += ["", "SECURITY"]
            for c in sec.checks { lines.append("  \(c.title): \(c.status)") }
            if let scan = s.processScan {
                lines.append("  Background programs: \(scan.checked) checked, \(scan.flagged.count) flagged")
                for p in scan.flagged { lines.append("    \(p.name) (\(p.path)): \(p.assessment.signals.map(\.text).joined(separator: " "))") }
            }
        }

        lines += ["", "FINDINGS"]
        if findings.isEmpty { lines.append("  None") }
        for f in findings { lines.append("  [\(f.severity.label.uppercased())] \(f.title). \(f.detail)") }
        return lines.joined(separator: "\n")
    }
}
