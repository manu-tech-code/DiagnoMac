import Foundation

enum MachineCollector {
    static func collect() async -> MachineInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var info = MachineInfo(
            modelName: "Mac",
            modelIdentifier: Sysctl.string("hw.model") ?? "Unknown",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Unknown",
            performanceCores: Int(Sysctl.int("hw.perflevel0.physicalcpu") ?? Sysctl.int("hw.physicalcpu") ?? 0),
            efficiencyCores: Int(Sysctl.int("hw.perflevel1.physicalcpu") ?? 0),
            gpuCores: nil,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            osVersion: "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""),
            osBuild: Sysctl.string("kern.osversion") ?? "",
            bootTime: Sysctl.bootTime(),
            firmware: nil,
            displays: []
        )

        let result = await Shell.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "SPDisplaysDataType", "-json", "-detailLevel", "mini"], timeout: 30)
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else { return info }

        if let hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first {
            info.modelName = hw["machine_name"] as? String ?? info.modelName
            info.firmware = hw["boot_rom_version"] as? String
        }

        if let gpus = json["SPDisplaysDataType"] as? [[String: Any]] {
            info.gpuCores = gpus.compactMap { ($0["sppci_cores"] as? String).flatMap(Int.init) }.first
            var index = 0
            for gpu in gpus {
                for display in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                    let builtIn = (display["spdisplays_connection_type"] as? String) == "spdisplays_internal"
                    info.displays.append(DisplayInfo(
                        id: index,
                        name: builtIn ? "Built-in display" : (display["_name"] as? String ?? "External display"),
                        pixels: display["_spdisplays_pixels"] as? String ?? "",
                        resolution: display["_spdisplays_resolution"] as? String ?? "",
                        isBuiltIn: builtIn
                    ))
                    index += 1
                }
            }
        }
        return info
    }
}
