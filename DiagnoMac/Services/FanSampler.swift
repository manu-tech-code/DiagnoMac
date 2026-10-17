import Foundation
import IOKit

/// Read-only fan and temperature readings from AppleSMC.
///
/// The SMC doesn't expose the same keys on every Mac. This sampler discovers the
/// temperature sensors once, then reads only those keys. Nothing is ever written
/// to the SMC: DiagnoMac reports the fan, it doesn't control it.
@MainActor
final class FanSampler {
    private let reader: SMCReader?
    private var cpuTemperatureKeys: [String]?
    private var gpuTemperatureKeys: [String]?
    private var lastTemperatureProbe = Date.distantPast

    /// CPU cluster sensors, roughly hottest first. The lower-case keys are the
    /// Apple Silicon ones; the upper-case ones are used by Intel Macs.
    private static let cpuCandidates = [
        "Tp0p", "Tp0R", "Tp0X", "Tp0a", "Tp0u", "Tp0y", "Tp0T", "Tp0P", "Tp0D", "Tp0F",
        "Tp0H", "Tp0J", "Tp09", "Tp0E", "Tp0K", "Tp0L", "Tp0M", "Tp0N", "Tp0V",
        "Te05", "Te09", "Te0L", "Te0P", "Te0T",
        "TC0P", "TC0D", "TC0F", "TC0H", "TC0E", "TC0J", "TC0T",
    ]
    private static let gpuCandidates = [
        "Tg0p", "Tg0d", "Tg0g", "Tg0j", "Tg0m", "Tg0P", "Tg0D", "Tg0H", "Tg0T",
        "TG0D", "TG0P", "TG0H",
    ]

    init() {
        reader = SMCReader()
    }

    func sample() -> FanInfo {
        let now = Date()
        guard let reader else {
            return FanInfo(availability: .unavailable, sampledAt: now)
        }

        if cpuTemperatureKeys == nil || (cpuTemperatureKeys?.isEmpty == true && now.timeIntervalSince(lastTemperatureProbe) > 30) {
            probeTemperatures(using: reader, now: now)
        }

        let cpu = hottest(temperatureKeys: cpuTemperatureKeys ?? [], reader: reader)
        let gpu = hottest(temperatureKeys: gpuTemperatureKeys ?? [], reader: reader)

        // The fan count tells us whether this Mac is passively cooled. If the key
        // is missing (some models hide it), a readable F0Ac still means one fan.
        let count = Int((reader.number("FNum") ?? 0).rounded())
        if count == 0, reader.number("F0Ac") == nil {
            return FanInfo(availability: .fanless, fanCount: 0,
                           cpuTemperature: cpu, gpuTemperature: gpu, sampledAt: now)
        }

        guard let actual = reader.number("F0Ac"), actual >= 0 else {
            return FanInfo(availability: .unavailable, fanCount: max(count, 1),
                           cpuTemperature: cpu, gpuTemperature: gpu, sampledAt: now)
        }

        let minRPM = reader.number("F0Mn").map { Int($0.rounded()) }
        let maxRPM = reader.number("F0Mx").map { Int($0.rounded()) }
        let target = reader.number("F0Tg").map { Int($0.rounded()) }

        return FanInfo(
            availability: .available,
            rpm: Int(actual.rounded()),
            minRPM: minRPM,
            maxRPM: maxRPM,
            targetRPM: target,
            fanCount: max(count, 1),
            cpuTemperature: cpu,
            gpuTemperature: gpu,
            sampledAt: now
        )
    }

    private func probeTemperatures(using reader: SMCReader, now: Date) {
        lastTemperatureProbe = now
        cpuTemperatureKeys = Self.cpuCandidates.filter { reader.number($0).map { $0 > 0 && $0 < 130 } ?? false }
        gpuTemperatureKeys = Self.gpuCandidates.filter { reader.number($0).map { $0 > 0 && $0 < 130 } ?? false }
    }

    private func hottest(temperatureKeys: [String], reader: SMCReader) -> Double? {
        let values = temperatureKeys.compactMap { key -> Double? in
            guard let value = reader.number(key), value > 0, value < 130 else { return nil }
            return value
        }
        return values.max()
    }
}

// MARK: - AppleSMC

/// A minimal, read-only AppleSMC client. The structs match the layout AppleSMC
/// expects (80 bytes); changing them will break every call.
private final class SMCReader {
    private enum Selector: UInt8 {
        case readKey = 5
        case getKeyInfo = 9
    }

    private var connection: io_connect_t = 0
    private var isOpen = false

    init?() {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        isOpen = true
    }

    deinit {
        if isOpen { IOServiceClose(connection) }
    }

    /// Reads a key and returns its type string and raw bytes. Returns nil for a
    /// missing key or any SMC error, so callers can fall back cleanly.
    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard isOpen else { return nil }

        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = Self.fourCC(key)
        input.data8 = Selector.getKeyInfo.rawValue
        guard call(&input, &output) else { return nil }
        let info = output.keyInfo
        guard info.dataSize > 0, info.dataSize <= 32 else { return nil }

        input = SMCParamStruct()
        input.key = Self.fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.readKey.rawValue
        guard call(&input, &output) else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return (Self.typeString(info.dataType), bytes)
    }

    /// Reads a key as a number. Apple Silicon reports fan RPM and temperatures as
    /// little-endian floats; Intel Macs generally use fpe2/sp78.
    func number(_ key: String) -> Double? {
        guard let value = read(key) else { return nil }
        return Self.decode(type: value.type, bytes: value.bytes)
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> Bool {
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.stride,
                                               &output, &outputSize)
        return result == KERN_SUCCESS && output.result == 0
    }

    private static func fourCC(_ string: String) -> UInt32 {
        var value: UInt32 = 0
        let bytes = Array(string.utf8.prefix(4))
        for index in 0..<4 {
            value = (value << 8) | UInt32(index < bytes.count ? bytes[index] : 0x20)
        }
        return value
    }

    private static func typeString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            // SMC floats are little-endian, unlike the fpe2/sp78 integers below.
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 ", "flag":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
