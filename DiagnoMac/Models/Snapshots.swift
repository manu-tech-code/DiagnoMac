import Foundation

// Plain value types produced by the collectors. Everything here is Sendable so
// collectors can run off the main actor and hand results back.

struct DisplayInfo: Identifiable, Sendable {
    let id: Int
    let name: String
    let pixels: String
    let resolution: String
    let isBuiltIn: Bool
}

struct MachineInfo: Sendable {
    var modelName: String
    var modelIdentifier: String
    var chip: String
    var performanceCores: Int
    var efficiencyCores: Int
    var gpuCores: Int?
    var memoryBytes: UInt64
    var osVersion: String
    var osBuild: String
    var bootTime: Date?
    var firmware: String?
    var displays: [DisplayInfo]

    var totalCores: Int { performanceCores + efficiencyCores }
    var uptime: TimeInterval {
        bootTime.map { Date().timeIntervalSince($0) } ?? ProcessInfo.processInfo.systemUptime
    }
}

struct BatteryInfo: Sendable {
    var chargePercent: Int
    var cycleCount: Int
    var designCycleCount: Int = 1000
    var designCapacity: Int?
    var fullChargeCapacity: Int?
    var nominalCapacity: Int?
    var remainingCapacity: Int?
    var condition: String?
    var temperatureC: Double?
    var voltageV: Double?
    var amperageMA: Int?
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var adapter: AdapterInfo?
    var telemetry: PowerTelemetry?

    /// Matches what System Settings calls "Maximum Capacity": nominal vs design, capped at 100.
    var healthPercent: Int? {
        guard let design = designCapacity, design > 0, let nominal = nominalCapacity ?? fullChargeCapacity else { return nil }
        return min(100, Int((Double(nominal) / Double(design) * 100).rounded()))
    }

    /// Positive while charging, negative while discharging.
    var watts: Double? {
        if let telemetry, telemetry.battery != 0 { return telemetry.battery }
        guard let v = voltageV, let a = amperageMA else { return nil }
        return v * Double(a) / 1000
    }
}

struct PowerSettings: Sendable {
    struct Profile: Sendable {
        var displaySleepMinutes: Int?
        var systemSleepMinutes: Int?
        var lowPowerMode: Bool?
        var wakeOnNetwork: Bool?
    }
    var battery: Profile
    var ac: Profile
}

struct ProcessSample: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let path: String
    let cpuPercent: Double
    let memPercent: Double
    let residentBytes: UInt64
    var id: Int32 { pid }
}

struct PerformanceInfo: Sendable {
    var loadAverage: [Double]
    var thermalState: ProcessInfo.ThermalState
    var topByCPU: [ProcessSample]
    var topByMemory: [ProcessSample]
}

enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

struct MemoryInfo: Sendable {
    var total: UInt64
    var free: UInt64
    var active: UInt64
    var inactive: UInt64
    var wired: UInt64
    var compressed: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pageouts: UInt64
    var pressure: MemoryPressure
    /// kern.memorystatus_level: the percentage of memory the system considers available.
    var availablePercent: Int

    var swapFraction: Double { swapTotal == 0 ? 0 : Double(swapUsed) / Double(swapTotal) }
    var other: UInt64 { total &- min(total, free + active + inactive + wired + compressed) }
}

struct CleanupCandidate: Identifiable, Sendable {
    enum Method: Sendable {
        /// Move the folder's contents to the Trash, keeping the folder.
        case trashContents
        /// Run a command that removes the data itself.
        case command(path: String, args: [String])
        /// Too risky to automate; show it in Finder.
        case revealOnly
    }

    let id: String
    let title: String
    let url: URL
    var bytes: UInt64?
    let explanation: String
    let method: Method
}

struct StorageInfo: Sendable {
    var volumeName: String
    var totalBytes: UInt64
    var availableBytes: UInt64
    var fileSystem: String
    var isEncrypted: Bool?
    var smartStatus: String?
    var deviceName: String?
    var cleanup: [CleanupCandidate]

    var usedBytes: UInt64 { totalBytes &- min(totalBytes, availableBytes) }
    var freeFraction: Double { totalBytes == 0 ? 0 : Double(availableBytes) / Double(totalBytes) }
    var reclaimableBytes: UInt64 {
        // Only folders we empty ourselves; simctl removes an unknown share of its folder.
        cleanup.filter { if case .trashContents = $0.method { true } else { false } }.compactMap(\.bytes).reduce(0, +)
    }
}

struct WiFiInfo: Sendable {
    var rssi: Int
    var noise: Int
    var channel: String?
    var txRateMbps: Double
    var phyMode: String?
    var security: String?

    var snr: Int { rssi - noise }
}

struct PingResult: Sendable {
    var host: String
    var minMs: Double
    var avgMs: Double
    var maxMs: Double
    var jitterMs: Double
    var lossPercent: Double
}

struct NetworkCheck: Identifiable, Sendable {
    let id: String
    let title: String
    let passed: Bool
    let detail: String
}

struct NetworkInfo: Sendable {
    var interfaceName: String?
    var interfaceKind: String
    var isConnected: Bool
    var wifi: WiFiInfo?
    var ping: PingResult?
    var checks: [NetworkCheck]
}

struct SpeedTestResult: Sendable {
    var downloadMbps: Double
    var uploadMbps: Double
    var responsivenessRPM: Int?
    var idleLatencyMs: Double?
}

struct SecurityCheck: Identifiable, Sendable {
    let id: String
    let title: String
    let status: String
    let severity: Severity
    let detail: String
}

struct SecurityInfo: Sendable {
    var checks: [SecurityCheck]
    func check(_ id: String) -> SecurityCheck? { checks.first { $0.id == id } }
}

struct StartupItem: Identifiable, Sendable {
    enum Scope: String, Sendable {
        case userAgent = "User agent"
        case systemAgent = "System agent"
        case systemDaemon = "System daemon"
    }

    let url: URL
    let label: String
    let scope: Scope
    let program: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    var isLoaded: Bool?
    var isDisabled: Bool

    var id: String { url.path }
    var canToggleWithoutAdmin: Bool { scope == .userAgent }

    /// "com.google.keystone.agent" -> "Google"
    var vendor: String {
        let parts = label.split(separator: ".")
        guard parts.count >= 2 else { return label }
        let known = ["com", "org", "io", "net", "sh", "app", "dev", "co", "me", "us"]
        let name = String(known.contains(String(parts[0])) ? parts[1] : parts[0])
        let friendly = ["brew": "Homebrew", "epicgames": "Epic Games", "microsoft": "Microsoft", "google": "Google",
                        "adobe": "Adobe", "docker": "Docker", "zoom": "Zoom", "dropbox": "Dropbox", "tailscale": "Tailscale"]
        return friendly[name.lowercased()] ?? (name.prefix(1).uppercased() + name.dropFirst())
    }
}

struct CrashReport: Sendable {
    enum Kind: String, Sendable {
        case crash = "Crash", hang = "Hang", memory = "Out of memory", resource = "Resource limit", panic = "Kernel panic", other = "Other"
    }
    let url: URL
    let process: String
    let date: Date
    let kind: Kind
    /// Apple's own processes; the user can't update these separately from macOS.
    var isFirstParty = false
    var bundleID: String?
}

struct CrashGroup: Identifiable, Sendable {
    let process: String
    let reports: [CrashReport]
    var id: String { process }
    var count: Int { reports.count }
    /// macOS sometimes marks a third-party crash as first-party, so any non-Apple bundle ID wins.
    var isFirstParty: Bool {
        if reports.contains(where: { ($0.bundleID.map { !$0.hasPrefix("com.apple.") }) ?? false }) { return false }
        return reports.contains(where: \.isFirstParty)
    }
    var lastDate: Date { reports.map(\.date).max() ?? .distantPast }
    var kinds: [CrashReport.Kind] { Array(Set(reports.map(\.kind))).sorted { $0.rawValue < $1.rawValue } }
}

struct LogsInfo: Sendable {
    var reports: [CrashReport]
    var unreadableFolders: [String]

    var panics: [CrashReport] { reports.filter { $0.kind == .panic } }

    func groups(since: Date) -> [CrashGroup] {
        let recent = reports.filter { $0.date >= since && $0.kind != .panic }
        return Dictionary(grouping: recent, by: \.process)
            .map { CrashGroup(process: $0.key, reports: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastDate > $1.lastDate }
    }
}
