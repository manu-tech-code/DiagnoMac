import Darwin
import Foundation

/// Runs Apple's networkQuality tool and streams its live readings.
///
/// networkQuality only prints progress when its output is a terminal, so it runs attached to a
/// pseudo-terminal and we read the other end.
final class SpeedTestRunner: @unchecked Sendable {
    enum Event: Sendable {
        case progress(downMbps: Double, upMbps: Double, rpm: Int)
        case finished(SpeedTestResult?)
        case failed(String)
    }

    private let lock = NSLock()
    private var process: Process?

    func run() -> AsyncStream<Event> {
        AsyncStream { continuation in
            var master: Int32 = 0, slave: Int32 = 0
            guard openpty(&master, &slave, nil, nil, nil) == 0 else {
                continuation.yield(.failed("Couldn't start the speed test."))
                continuation.finish()
                return
            }
            let readFD = master

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            // Sequential so download and upload are measured separately; capped so progress can be estimated.
            process.arguments = ["-s", "-M", "\(Int(SpeedTestState.expectedDuration))"]
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle
            process.standardInput = FileHandle.nullDevice

            do { try process.run() } catch {
                close(readFD)
                continuation.yield(.failed("Couldn't start networkQuality: \(error.localizedDescription)"))
                continuation.finish()
                return
            }
            // Close our copy so reads end when the tool exits.
            try? slaveHandle.close()
            lock.withLock { self.process = process }

            continuation.onTermination = { [weak self] _ in self?.cancel() }

            DispatchQueue.global(qos: .userInitiated).async {
                var pending = ""
                var summary: [String] = []
                var last: (Double, Double, Int) = (0, 0, 0)
                var buffer = [UInt8](repeating: 0, count: 4096)

                while true {
                    let n = read(readFD, &buffer, buffer.count)
                    if n <= 0 { break }
                    pending += String(decoding: buffer[0..<n], as: UTF8.self)
                    // Progress lines are redrawn in place with \r; the summary uses \n.
                    let pieces = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                    pending = pieces.last ?? ""
                    for raw in pieces.dropLast() {
                        let line = Self.stripEscapes(raw).trimmingCharacters(in: .whitespaces)
                        guard !line.isEmpty else { continue }
                        if let p = Self.parseProgress(line) {
                            last = p
                            continuation.yield(.progress(downMbps: p.0, upMbps: p.1, rpm: p.2))
                        } else {
                            summary.append(line)
                        }
                    }
                }
                close(readFD)
                process.waitUntilExit()

                if process.terminationReason == .uncaughtSignal {
                    continuation.yield(.failed("Speed test cancelled."))
                } else if process.terminationStatus != 0 && last.0 == 0 {
                    let message = summary.last ?? "networkQuality exited with status \(process.terminationStatus)."
                    continuation.yield(.failed(message))
                } else {
                    continuation.yield(.finished(Self.parseSummary(summary, fallback: last)))
                }
                continuation.finish()
            }
        }
    }

    func cancel() {
        lock.withLock {
            if let process, process.isRunning { process.terminate() }
            process = nil
        }
    }

    // MARK: Parsing

    private static func stripEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "^D", with: "")
    }

    /// "Downlink: 76.672 Mbps, 262 RPM - Uplink: 28.754 Mbps, 0 RPM"
    static func parseProgress(_ line: String) -> (Double, Double, Int)? {
        let pattern = #"Downlink: ([\d.]+) Mbps, (\d+) RPM - Uplink: ([\d.]+) Mbps, (\d+) RPM"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int) -> String { (Range(m.range(at: i), in: line).map { String(line[$0]) }) ?? "0" }
        let rpm = max(Int(group(2)) ?? 0, Int(group(4)) ?? 0)
        return (Double(group(1)) ?? 0, Double(group(3)) ?? 0, rpm)
    }

    /// Reads "Downlink capacity: 48.669 Mbps", "Uplink capacity: …", "Downlink Responsiveness: Medium (237.730 milliseconds | 252 RPM)",
    /// "Idle Latency: 180.484 milliseconds | 332 RPM".
    static func parseSummary(_ lines: [String], fallback: (Double, Double, Int)) -> SpeedTestResult? {
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
        let down = number(after: "Downlink capacity", unit: "Mbps") ?? fallback.0
        let up = number(after: "Uplink capacity", unit: "Mbps") ?? fallback.1
        guard down > 0 || up > 0 else { return nil }
        let responsiveness = rpm(after: "Downlink Responsiveness") ?? rpm(after: "Responsiveness")
            ?? rpm(after: "Uplink Responsiveness") ?? (fallback.2 > 0 ? fallback.2 : nil)
        return SpeedTestResult(downloadMbps: down, uploadMbps: up, responsivenessRPM: responsiveness,
                               idleLatencyMs: number(after: "Idle Latency", unit: "milliseconds"))
    }
}
