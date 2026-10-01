import Foundation

/// A finished networkQuality run.
public struct SpeedTestResult: Equatable, Sendable {
    public var downloadMbps: Double
    public var uploadMbps: Double
    public var responsivenessRPM: Int?
    public var idleLatencyMs: Double?

    public init(downloadMbps: Double, uploadMbps: Double, responsivenessRPM: Int? = nil, idleLatencyMs: Double? = nil) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.responsivenessRPM = responsivenessRPM
        self.idleLatencyMs = idleLatencyMs
    }
}

/// One live reading while networkQuality runs.
public struct SpeedTestReading: Equatable, Sendable {
    public var downloadMbps: Double
    public var uploadMbps: Double
    public var rpm: Int

    public init(downloadMbps: Double, uploadMbps: Double, rpm: Int) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.rpm = rpm
    }
}

/// Reads what Apple's networkQuality prints to a terminal.
public enum SpeedTestParser {
    /// Strips the terminal escapes networkQuality uses to redraw its progress line.
    public static func stripEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "^D", with: "")
    }

    /// "Downlink: 76.672 Mbps, 262 RPM - Uplink: 28.754 Mbps, 0 RPM"
    public static func progress(_ line: String) -> SpeedTestReading? {
        let pattern = #"Downlink: ([\d.]+) Mbps, (\d+) RPM - Uplink: ([\d.]+) Mbps, (\d+) RPM"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int) -> String { (Range(m.range(at: i), in: line).map { String(line[$0]) }) ?? "0" }
        return SpeedTestReading(downloadMbps: Double(group(1)) ?? 0, uploadMbps: Double(group(3)) ?? 0,
                                rpm: max(Int(group(2)) ?? 0, Int(group(4)) ?? 0))
    }

    /// The summary networkQuality prints at the end, for example
    /// "Downlink capacity: 48.669 Mbps", "Downlink Responsiveness: Medium (237.730 milliseconds | 252 RPM)"
    /// and "Idle Latency: 180.484 milliseconds | 332 RPM". Falls back to the last live reading.
    public static func summary(_ lines: [String], fallback: SpeedTestReading?) -> SpeedTestResult? {
        func number(after prefix: String, unit: String) -> Double? {
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }),
                  let range = line.range(of: #"[\d.]+(?= \#(unit))"#, options: .regularExpression) else { return nil }
            return Double(line[range])
        }
        func rpm(after prefix: String) -> Int? {
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }),
                  let range = line.range(of: #"\d+(?= RPM)"#, options: .regularExpression) else { return nil }
            return Int(line[range])
        }
        let down = number(after: "Downlink capacity", unit: "Mbps") ?? fallback?.downloadMbps ?? 0
        let up = number(after: "Uplink capacity", unit: "Mbps") ?? fallback?.uploadMbps ?? 0
        guard down > 0 || up > 0 else { return nil }
        let liveRPM = fallback.flatMap { $0.rpm > 0 ? $0.rpm : nil }
        let responsiveness = rpm(after: "Downlink Responsiveness") ?? rpm(after: "Responsiveness")
            ?? rpm(after: "Uplink Responsiveness") ?? liveRPM
        return SpeedTestResult(downloadMbps: down, uploadMbps: up, responsivenessRPM: responsiveness,
                               idleLatencyMs: number(after: "Idle Latency", unit: "milliseconds"))
    }
}
