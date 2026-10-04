import Foundation

/// Runs blocking work on a GCD queue so it never ties up a Swift concurrency thread.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }
    }

    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 20,
                    qos: QualityOfService = .default) async -> Result {
        await offMain { runSync(path, args, timeout: timeout, qos: qos) }
    }

    static func runSync(_ path: String, _ args: [String], timeout: TimeInterval, qos: QualityOfService = .default) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.qualityOfService = qos
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Drain stderr on another thread so a chatty command can't fill its pipe and deadlock us.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }

    /// Runs a shell command as root after macOS shows its own administrator password prompt.
    static func runAsAdmin(_ command: String) async -> Result {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 120)
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}
