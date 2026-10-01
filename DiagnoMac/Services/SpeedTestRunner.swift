import Darwin
import DiagnoCore
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
                var last: SpeedTestReading?
                var buffer = [UInt8](repeating: 0, count: 4096)

                while true {
                    let n = read(readFD, &buffer, buffer.count)
                    if n <= 0 { break }
                    pending += String(decoding: buffer[0..<n], as: UTF8.self)
                    // Progress lines are redrawn in place with \r; the summary uses \n.
                    let pieces = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                    pending = pieces.last ?? ""
                    for raw in pieces.dropLast() {
                        let line = SpeedTestParser.stripEscapes(raw).trimmingCharacters(in: .whitespaces)
                        guard !line.isEmpty else { continue }
                        if let reading = SpeedTestParser.progress(line) {
                            last = reading
                            continuation.yield(.progress(downMbps: reading.downloadMbps, upMbps: reading.uploadMbps, rpm: reading.rpm))
                        } else {
                            summary.append(line)
                        }
                    }
                }
                close(readFD)
                process.waitUntilExit()

                if process.terminationReason == .uncaughtSignal {
                    continuation.yield(.failed("Speed test cancelled."))
                } else if process.terminationStatus != 0 && (last?.downloadMbps ?? 0) == 0 {
                    let message = summary.last ?? "networkQuality exited with status \(process.terminationStatus)."
                    continuation.yield(.failed(message))
                } else {
                    continuation.yield(.finished(SpeedTestParser.summary(summary, fallback: last)))
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
}
