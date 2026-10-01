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
                      "  \(Format.memory(m.memoryBytes)) memory",
                      "  macOS \(m.osVersion) (\(m.osBuild)), uptime \(Format.duration(m.uptime))"]
            for d in m.displays { lines.append("  Display: \(d.name) \(d.pixels) @ \(d.resolution)") }
        }
        if let b = s.battery {
            lines += ["", "BATTERY",
                      "  \(b.healthPercent.map { "\($0)%" } ?? "?") maximum capacity, \(b.cycleCount) cycles, condition \(b.condition ?? "unknown")",
                      "  Full charge \(b.fullChargeCapacity.map(String.init) ?? "?") mAh / design \(b.designCapacity.map(String.init) ?? "?") mAh"]
        }
        if let st = s.storage {
            lines += ["", "STORAGE",
                      "  \(Format.gb(st.availableBytes)) free of \(Format.gb(st.totalBytes)), SMART \(st.smartStatus ?? "unknown")"]
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
        if let n = s.network {
            lines += ["", "NETWORK", "  \(n.interfaceKind)\(n.interfaceName.map { " (\($0))" } ?? "")"]
            if let w = n.wifi { lines.append("  RSSI \(w.rssi) dBm, noise \(w.noise) dBm, SNR \(w.snr) dB, \(w.channel ?? "")") }
            if let p = n.ping { lines.append(String(format: "  Ping %@ avg %.1f ms, %.0f%% loss", p.host, p.avgMs, p.lossPercent)) }
        }
        if let sec = s.security {
            lines += ["", "SECURITY"]
            for c in sec.checks { lines.append("  \(c.title): \(c.status)") }
        }

        lines += ["", "FINDINGS"]
        if findings.isEmpty { lines.append("  None") }
        for f in findings { lines.append("  [\(f.severity.label.uppercased())] \(f.title). \(f.detail)") }
        return lines.joined(separator: "\n")
    }
}
