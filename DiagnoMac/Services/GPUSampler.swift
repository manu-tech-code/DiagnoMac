import Foundation
import IOKit

/// Reads GPU load from the IOAccelerator driver, and per-process GPU time from its user clients.
/// None of this needs administrator rights.
@MainActor
final class GPUSampler {
    private var previousTotals: [Int32: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private var lastProcesses: [GPUProcessUsage] = []

    /// `includeProcesses` reads every GPU client's counters as well; that's only needed while
    /// the CPU & GPU page is open.
    func sample(includeProcesses: Bool = true) -> GPUInfo? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var info: GPUInfo?
        var totals: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]

        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            if info == nil, let stats = property(accelerator, "PerformanceStatistics") as? [String: Any] {
                func int(_ key: String) -> Int { (stats[key] as? NSNumber)?.intValue ?? 0 }
                func bytes(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
                info = GPUInfo(deviceUtilization: int("Device Utilization %"),
                               rendererUtilization: int("Renderer Utilization %"),
                               tilerUtilization: int("Tiler Utilization %"),
                               inUseMemory: bytes("In use system memory"),
                               allocatedMemory: bytes("Alloc system memory"),
                               processes: [])
            }
            if includeProcesses { readClients(of: accelerator, into: &totals, names: &names) }
        }
        guard includeProcesses else { return info }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now &- previousTime)
        // Under half a second is too short to measure; keep the last reading and baseline.
        if previousTime > 0, elapsed < 500_000_000 {
            info?.processes = lastProcesses
            return info
        }
        if previousTime > 0, elapsed > 0 {
            info?.processes = totals.compactMap { pid, total -> GPUProcessUsage? in
                guard let before = previousTotals[pid], total >= before else { return nil }
                let percent = Double(total - before) / elapsed * 100
                guard percent >= 0.1 else { return nil }
                return GPUProcessUsage(pid: pid, name: names[pid] ?? "pid \(pid)", percent: min(100, percent),
                                       totalSeconds: Double(total) / 1e9)
            }
            .sorted { $0.percent > $1.percent }
        }
        previousTotals = totals
        previousTime = now
        lastProcesses = info?.processes ?? []
        return info
    }

    /// Each client is tagged "pid 410, WindowServer" and lists accumulated GPU time in nanoseconds.
    private func readClients(of accelerator: io_registry_entry_t, into totals: inout [Int32: UInt64], names: inout [Int32: String]) {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(children) }

        while case let client = IOIteratorNext(children), client != 0 {
            defer { IOObjectRelease(client) }
            guard let creator = property(client, "IOUserClientCreator") as? String,
                  let usage = property(client, "AppUsage") as? [[String: Any]], !usage.isEmpty else { continue }
            let parts = creator.split(separator: ",", maxSplits: 1)
            guard let pidPart = parts.first, let pid = Int32(pidPart.replacingOccurrences(of: "pid ", with: "")) else { continue }
            if parts.count == 2 { names[pid] = parts[1].trimmingCharacters(in: .whitespaces) }
            let time = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
            totals[pid, default: 0] += time
        }
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
