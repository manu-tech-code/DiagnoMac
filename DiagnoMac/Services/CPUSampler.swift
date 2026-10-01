import Darwin
import Foundation

struct CPULoad: Sendable {
    /// 0...1 per logical core.
    var perCore: [Double]
    var total: Double { perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count) }
}

/// Measures CPU usage per core from the difference between two tick snapshots.
/// Sampling takes microseconds, so it runs on the main actor.
@MainActor
final class CPUSampler {
    private var previous: [[UInt32]] = []

    func sample() -> CPULoad? {
        guard let ticks = Self.readTicks() else { return nil }
        defer { previous = ticks }
        guard previous.count == ticks.count else { return nil }

        let perCore = zip(ticks, previous).map { now, before -> Double in
            let user = Double(now[0] &- before[0])
            let system = Double(now[1] &- before[1])
            let idle = Double(now[2] &- before[2])
            let nice = Double(now[3] &- before[3])
            let total = user + system + idle + nice
            return total > 0 ? (user + system + nice) / total : 0
        }
        return CPULoad(perCore: perCore)
    }

    /// [user, system, idle, nice] ticks for each core.
    private static func readTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * states
            return [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE].map {
                UInt32(bitPattern: info[base + Int($0)])
            }
        }
    }
}
