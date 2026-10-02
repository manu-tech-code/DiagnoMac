import DiagnoCore
import Foundation

// Value types for the readings that update continuously (GPU, apps, charging, speed test)
// and for the newer checks (backups, devices).

struct GPUProcessUsage: Identifiable, Sendable {
    let pid: Int32
    let name: String
    /// Share of wall-clock time this process kept the GPU busy, 0...100.
    let percent: Double
    /// Total GPU time since the process started.
    let totalSeconds: Double
    var id: Int32 { pid }
}

struct GPUInfo: Sendable {
    var deviceUtilization: Int
    var rendererUtilization: Int
    var tilerUtilization: Int
    var inUseMemory: UInt64
    var allocatedMemory: UInt64
    /// Busiest first. Empty on the first sample, since usage is measured between samples.
    var processes: [GPUProcessUsage]
}

struct AdapterInfo: Sendable {
    var name: String
    var watts: Int
    var voltageV: Double?
    var currentA: Double?
}

/// Where the power goes, from the battery controller's telemetry. All values in watts.
struct PowerTelemetry: Sendable {
    /// Power coming in from the charger.
    var systemInput: Double
    /// Positive while charging, negative while the battery is powering the Mac.
    var battery: Double
    /// Power the Mac itself is using.
    var systemLoad: Double
    /// Lost as heat converting adapter power.
    var adapterLoss: Double
}

struct PowerSample: Identifiable, Sendable {
    /// How far back the Battery page's power chart goes.
    static let window: TimeInterval = 10 * 60

    let date: Date
    let input: Double
    let battery: Double
    let system: Double
    var id: Date { date }
}

struct ChargeSession: Codable, Identifiable, Sendable {
    var id = UUID()
    var start: Date
    var end: Date?
    var adapterName: String?
    var adapterWatts: Int?
    var startPercent: Int
    var endPercent: Int?
    var peakWatts: Double
    /// The charger was already connected when DiagnoMac started, so the real start time is unknown.
    var startedBeforeLaunch: Bool
    /// Last time DiagnoMac saw this session in progress. Used to close sessions left open when the app quit.
    var lastSeen: Date?
}

struct RunningApp: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case window = "Window"
        case menuBar = "Menu bar"
        case background = "Background"
    }

    let pid: Int32
    let name: String
    let bundleID: String?
    let bundlePath: String?
    let kind: Kind
    var memoryBytes: UInt64
    var cpuPercent: Double
    /// Average over the last minute of samples.
    var averageCPU: Double
    var processCount: Int
    var isActive: Bool
    var isHidden: Bool
    /// How long DiagnoMac has been watching this app.
    var observedSeconds: TimeInterval

    var id: Int32 { pid }

    /// DiagnoMac and Finder stay open: quitting Finder only makes macOS relaunch it.
    var canQuit: Bool {
        bundleID != Bundle.main.bundleIdentifier && bundleID != "com.apple.finder"
    }

    /// Open with a window, not in front, and using essentially no CPU for a while.
    var isIdle: Bool {
        kind == .window && canQuit && !isActive && observedSeconds >= 15 && averageCPU < 0.5
    }
}

struct BackupInfo: Sendable {
    var destinations: [String]
    var latestBackup: Date?
    var autoBackup: Bool?

    var isConfigured: Bool { !destinations.isEmpty }
    var daysSinceBackup: Int? {
        latestBackup.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 }
    }
}

struct BluetoothDevice: Identifiable, Sendable {
    struct Level: Sendable, Hashable {
        let label: String
        let percent: Int
    }

    let name: String
    let kind: String?
    let isConnected: Bool
    let batteryLevels: [Level]
    var id: String { name }
    var lowestBattery: Int? { batteryLevels.map(\.percent).min() }
}

struct USBDevice: Identifiable, Sendable {
    let name: String
    let vendor: String?
    let speed: String?
    var id: String { name + (vendor ?? "") }
}

struct DevicesInfo: Sendable {
    var bluetoothOn: Bool?
    var bluetooth: [BluetoothDevice]
    var usb: [USBDevice]
}

/// One live throughput reading, timed from the start of the test.
struct SpeedSample: Sendable {
    let seconds: Double
    let mbps: Double
}

struct SpeedTestState: Sendable {
    enum Phase: Equatable, Sendable {
        case idle, starting, download, upload, finishing, done
        case failed(String)
    }

    var phase: Phase = .idle
    var startedAt: Date?
    var finishedAt: Date?
    var downloadMbps: Double = 0
    var uploadMbps: Double = 0
    var responsivenessRPM: Int = 0
    var downloadSeries: [SpeedSample] = []
    var uploadSeries: [SpeedSample] = []
    var result: SpeedTestResult?

    var isRunning: Bool { [.starting, .download, .upload, .finishing].contains(phase) }
    /// networkQuality is capped at this many seconds, so progress can be estimated.
    static let expectedDuration: TimeInterval = 24
}
