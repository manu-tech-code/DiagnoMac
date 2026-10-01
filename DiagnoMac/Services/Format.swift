import Foundation

enum Format {
    static func bytes(_ value: UInt64, style: ByteCountFormatter.CountStyle = .file) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: style)
    }

    static func gb(_ value: UInt64, digits: Int = 1) -> String {
        String(format: "%.\(digits)f GB", Double(value) / 1_000_000_000)
    }

    /// Memory uses binary units, matching Activity Monitor.
    static func memory(_ value: UInt64) -> String {
        String(format: "%.2f GB", Double(value) / 1_073_741_824)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "—"
    }

    static func minutes(_ m: Int) -> String {
        m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", fraction * 100)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
