import Foundation

/// The sections of the app, in sidebar order.
enum Area: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview, assistant, apps, battery, performance, memory, storage, network, security, startup, devices, hardware, logs, report

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .assistant: "Assistant"
        case .apps: "Running Apps"
        case .battery: "Battery"
        case .performance: "CPU & GPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .network: "Network"
        case .security: "Security"
        case .startup: "Startup Items"
        case .devices: "Devices"
        case .hardware: "Hardware Tests"
        case .logs: "Crash Logs"
        case .report: "Report"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .assistant: "sparkles"
        case .apps: "square.stack.3d.up"
        case .battery: "battery.100percent"
        case .performance: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .network: "wifi"
        case .security: "lock.shield"
        case .startup: "power"
        case .devices: "cable.connector"
        case .hardware: "keyboard"
        case .logs: "exclamationmark.bubble"
        case .report: "doc.text"
        }
    }

    /// Areas that don't produce findings and shouldn't show a health dot.
    var showsHealth: Bool { ![.overview, .assistant, .hardware, .report].contains(self) }
}

enum Severity: Int, Comparable, Sendable, Codable {
    case ok, info, warning, critical

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .ok: "Good"
        case .info: "Suggestion"
        case .warning: "Attention"
        case .critical: "Fix now"
        }
    }

    /// Heading used when findings are grouped by severity.
    var groupTitle: String {
        switch self {
        case .ok: "Good"
        case .info: "Suggestions"
        case .warning: "Needs attention"
        case .critical: "Fix now"
        }
    }
}

/// What a finding's button does.
enum FindingAction: Sendable, Hashable {
    case navigate(Area)
    case enableFirewall
    case openURL(URL)
}

struct Finding: Identifiable, Sendable, Hashable {
    let id: String
    let severity: Severity
    let area: Area
    let title: String
    let detail: String
    var actionTitle: String?
    var action: FindingAction?
}
