import Darwin
import Foundation

enum PerformanceCollector {
    static func collect() async -> PerformanceInfo {
        let processes = await processes()
        return PerformanceInfo(
            loadAverage: Sysctl.loadAverage(),
            thermalState: ProcessInfo.processInfo.thermalState,
            topByCPU: Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(10)),
            topByMemory: Array(processes.sorted { $0.residentBytes > $1.residentBytes }.prefix(10))
        )
    }

    static func processes() async -> [ProcessSample] {
        let result = await Shell.run("/bin/ps", ["-Axo", "pid=,pcpu=,pmem=,rss=,comm="])
        return result.stdout.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 5,
                  let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                  let mem = Double(fields[2]), let rssKB = UInt64(fields[3]) else { return nil }
            let path = String(fields[4])
            return ProcessSample(pid: pid, name: displayName(for: path), path: path,
                                 cpuPercent: cpu, memPercent: mem, residentBytes: rssKB * 1024)
        }
    }

    /// Turns ".../Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)" into "Claude Helper (Renderer)".
    static func displayName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// The app bundle that owns an executable path, e.g. "Claude" for a Claude helper.
    static func owningApp(for path: String) -> String? {
        let components = path.split(separator: "/")
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return String(components[appIndex].dropLast(4))
    }
}

enum MemoryCollector {
    static func collect() -> MemoryInfo? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let page = UInt64(Sysctl.int("hw.pagesize") ?? 16_384)
        let swap = Sysctl.swapUsage()
        let pressureLevel = Int(Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1)

        return MemoryInfo(
            total: ProcessInfo.processInfo.physicalMemory,
            free: UInt64(stats.free_count + stats.speculative_count) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            swapUsed: swap?.used ?? 0,
            swapTotal: swap?.total ?? 0,
            pageouts: stats.pageouts,
            pressure: MemoryPressure(rawValue: pressureLevel) ?? .normal,
            availablePercent: Int(Sysctl.int("kern.memorystatus_level") ?? 0)
        )
    }
}
