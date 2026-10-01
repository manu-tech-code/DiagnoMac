import AppKit
import Darwin

/// Lists open apps and measures each one's memory and CPU, including its helper processes.
/// Memory is the physical footprint (what Activity Monitor shows); CPU is measured between samples.
@MainActor
final class AppsSampler {
    private struct Descriptor: Sendable {
        let pid: Int32
        let name: String
        let bundleID: String?
        let bundlePath: String?
        let kind: RunningApp.Kind
        let isActive: Bool
        let isHidden: Bool
    }

    private struct Totals: Sendable {
        var footprint: UInt64 = 0
        var cpuNanoseconds: UInt64 = 0
        var processes = 0
    }

    private var previous: [Int32: (cpu: UInt64, time: UInt64)] = [:]
    private var history: [Int32: [Double]] = [:]
    private var firstSeen: [Int32: Date] = [:]

    func sample() async -> [RunningApp] {
        let descriptors = Self.descriptors()
        let totals = await offMain { Self.measure(descriptors) }
        let now = DispatchTime.now().uptimeNanoseconds

        var apps: [RunningApp] = []
        for d in descriptors {
            let t = totals[d.pid] ?? Totals()
            var cpu = 0.0
            if let before = previous[d.pid], now > before.time, t.cpuNanoseconds >= before.cpu {
                cpu = Double(t.cpuNanoseconds - before.cpu) / Double(now - before.time) * 100
                history[d.pid, default: []].append(cpu)
                if history[d.pid]!.count > 12 { history[d.pid]!.removeFirst() }
            }
            previous[d.pid] = (t.cpuNanoseconds, now)
            let seen = firstSeen[d.pid] ?? Date()
            firstSeen[d.pid] = seen
            let samples = history[d.pid] ?? []

            apps.append(RunningApp(
                pid: d.pid, name: d.name, bundleID: d.bundleID, bundlePath: d.bundlePath, kind: d.kind,
                memoryBytes: t.footprint, cpuPercent: cpu,
                averageCPU: samples.isEmpty ? cpu : samples.reduce(0, +) / Double(samples.count),
                processCount: max(1, t.processes), isActive: d.isActive, isHidden: d.isHidden,
                observedSeconds: samples.isEmpty ? 0 : Date().timeIntervalSince(seen)))
        }

        // Forget apps that have quit.
        let live = Set(descriptors.map(\.pid))
        previous = previous.filter { live.contains($0.key) }
        history = history.filter { live.contains($0.key) }
        firstSeen = firstSeen.filter { live.contains($0.key) }

        return apps.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    /// Apps worth showing: Dock apps, menu bar apps, and third-party background apps.
    private static func descriptors() -> [Descriptor] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let path = app.bundleURL?.path else { return nil }
            // Helpers nested inside another app's bundle are counted with that app.
            if path.dropLast(4).contains(".app/") { return nil }
            let isApple = app.bundleIdentifier?.hasPrefix("com.apple.") ?? false
            let inApplications = path.hasPrefix("/Applications") || path.hasPrefix("/System/Applications")
                || path.hasPrefix(NSHomeDirectory() + "/Applications")

            let kind: RunningApp.Kind
            switch app.activationPolicy {
            case .regular: kind = .window
            case .accessory:
                guard !isApple || inApplications else { return nil }
                kind = .menuBar
            default:
                guard !isApple, inApplications else { return nil }
                kind = .background
            }
            return Descriptor(pid: app.processIdentifier,
                              name: app.localizedName ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                              bundleID: app.bundleIdentifier, bundlePath: path, kind: kind,
                              isActive: app.isActive, isHidden: app.isHidden)
        }
    }

    /// Walks every process once and adds it to the app whose bundle contains its executable.
    nonisolated private static func measure(_ apps: [Descriptor]) -> [Int32: Totals] {
        let bundles = apps.compactMap { app in app.bundlePath.map { ($0 + "/", app.pid) } }
            .sorted { $0.0.count > $1.0.count } // longest path wins for nested bundles
        var totals: [Int32: Totals] = [:]

        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let path = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard let owner = bundles.first(where: { path.hasPrefix($0.0) })?.1,
                  let usage = rusage(pid) else { continue }
            totals[owner, default: Totals()].footprint += usage.ri_phys_footprint
            totals[owner, default: Totals()].cpuNanoseconds += machToNanoseconds(usage.ri_user_time + usage.ri_system_time)
            totals[owner, default: Totals()].processes += 1
        }
        return totals
    }

    nonisolated private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    /// rusage CPU times are in Mach absolute time units on Apple silicon.
    nonisolated private static func machToNanoseconds(_ ticks: UInt64) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom != 0 else { return ticks }
        return ticks / UInt64(timebase.denom) * UInt64(timebase.numer)
    }

    // MARK: Actions

    /// Asks the app to quit normally, so it can save work and show its own prompts.
    static func quit(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    static func forceQuit(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false
    }

    static func isRunning(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    static func show(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
