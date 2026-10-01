import CoreWLAN
import Foundation
import Network

enum NetworkCollector {
    static func collect() async -> NetworkInfo {
        let path = await currentPath()
        let wifi = wifiInfo()

        let interface = path.availableInterfaces.first { path.usesInterfaceType($0.type) }
        let kind: String = switch interface?.type {
        case .wifi: "Wi-Fi"
        case .wiredEthernet: "Ethernet"
        case .cellular: "Cellular"
        case .loopback: "Loopback"
        case .other: "Other"
        default: "None"
        }
        let connected = path.status == .satisfied

        async let ping = ping(host: "1.1.1.1")
        async let dns = resolveTime(host: "apple.com")
        async let gateway = gatewayReachable()
        let pingResult = connected ? await ping : nil
        let dnsMs = connected ? await dns : nil
        let gatewayOK = await gateway

        var checks: [NetworkCheck] = [
            NetworkCheck(id: "link", title: "Network connection", passed: connected,
                         detail: connected ? "Connected over \(kind)" : "No usable network interface"),
            NetworkCheck(id: "gateway", title: "Router reachable", passed: gatewayOK,
                         detail: gatewayOK ? "Default gateway responds" : "No reply from the default gateway"),
            NetworkCheck(id: "dns", title: "DNS resolution", passed: dnsMs != nil,
                         detail: dnsMs.map { String(format: "Resolved apple.com in %.0f ms", $0) } ?? "Could not resolve apple.com"),
        ]
        if let pingResult {
            checks.append(NetworkCheck(id: "internet", title: "Internet reachable", passed: pingResult.lossPercent < 100,
                                       detail: String(format: "Ping %@ · %.0f%% loss", pingResult.host, pingResult.lossPercent)))
        } else {
            checks.append(NetworkCheck(id: "internet", title: "Internet reachable", passed: false, detail: "No reply from 1.1.1.1"))
        }
        checks.append(NetworkCheck(id: "ipv6", title: "IPv6", passed: path.supportsIPv6,
                                   detail: path.supportsIPv6 ? "IPv6 route available" : "IPv4 only"))

        return NetworkInfo(interfaceName: interface?.name, interfaceKind: kind, isConnected: connected,
                           wifi: wifi, ping: pingResult, checks: checks)
    }

    private static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "diagnomac.path"))
        }
    }

    private static func wifiInfo() -> WiFiInfo? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              interface.rssiValue() != 0 else { return nil }
        let channel = interface.wlanChannel().map { ch -> String in
            let band = switch ch.channelBand {
            case .band2GHz: "2.4 GHz"
            case .band5GHz: "5 GHz"
            case .band6GHz: "6 GHz"
            default: ""
            }
            let width = switch ch.channelWidth {
            case .width20MHz: "20 MHz"
            case .width40MHz: "40 MHz"
            case .width80MHz: "80 MHz"
            case .width160MHz: "160 MHz"
            default: ""
            }
            return "\(ch.channelNumber) (\([band, width].filter { !$0.isEmpty }.joined(separator: ", ")))"
        }
        let phy: String? = switch interface.activePHYMode() {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "802.11n (Wi-Fi 4)"
        case .mode11ac: "802.11ac (Wi-Fi 5)"
        case .mode11ax: "802.11ax (Wi-Fi 6/6E)"
        default: nil
        }
        return WiFiInfo(rssi: interface.rssiValue(), noise: interface.noiseMeasurement(), channel: channel,
                        txRateMbps: interface.transmitRate(), phyMode: phy, security: nil)
    }

    static func ping(host: String, count: Int = 5) async -> PingResult? {
        let result = await Shell.run("/sbin/ping", ["-c", "\(count)", "-q", "-t", "8", host], timeout: 12)
        var loss = 100.0
        var stats: [Double] = []
        for line in result.stdout.split(separator: "\n") {
            if line.contains("packet loss"), let range = line.range(of: #"[\d.]+(?=% packet loss)"#, options: .regularExpression) {
                loss = Double(line[range]) ?? 100
            }
            if line.contains("round-trip"), let eq = line.split(separator: "=").last {
                stats = eq.trimmingCharacters(in: .whitespaces).split(separator: " ").first?
                    .split(separator: "/").compactMap { Double($0) } ?? []
            }
        }
        guard stats.count >= 4 else {
            // Every packet lost: report that rather than "unknown".
            return result.stdout.contains("packet loss")
                ? PingResult(host: host, minMs: 0, avgMs: 0, maxMs: 0, jitterMs: 0, lossPercent: loss)
                : nil
        }
        return PingResult(host: host, minMs: stats[0], avgMs: stats[1], maxMs: stats[2], jitterMs: stats[3], lossPercent: loss)
    }

    private static func resolveTime(host: String) async -> Double? {
        await offMain {
            let start = Date()
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            return status == 0 ? Date().timeIntervalSince(start) * 1000 : nil
        }
    }

    private static func gatewayReachable() async -> Bool {
        let route = await Shell.run("/sbin/route", ["-n", "get", "default"])
        guard let line = route.stdout.split(separator: "\n").first(where: { $0.contains("gateway:") }),
              let gateway = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return false }
        let ping = await Shell.run("/sbin/ping", ["-c", "2", "-q", "-t", "3", gateway], timeout: 5)
        return ping.succeeded
    }

    /// Runs Apple's built-in networkQuality tool. Takes 10-20 seconds.
    static func speedTest() async -> SpeedTestResult? {
        let result = await Shell.run("/usr/bin/networkQuality", ["-c", "-M", "20"], timeout: 45)
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else { return nil }
        let down = (json["dl_throughput"] as? Double) ?? 0
        let up = (json["ul_throughput"] as? Double) ?? 0
        return SpeedTestResult(
            downloadMbps: down / 1_000_000,
            uploadMbps: up / 1_000_000,
            responsivenessRPM: (json["responsiveness"] as? Double).map { Int($0) } ?? (json["dl_responsiveness"] as? Double).map { Int($0) },
            idleLatencyMs: json["base_rtt"] as? Double
        )
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
