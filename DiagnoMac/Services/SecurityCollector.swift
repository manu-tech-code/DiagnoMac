import Foundation

enum SecurityCollector {
    static func collect() async -> SecurityInfo {
        async let fileVault = Shell.run("/usr/bin/fdesetup", ["status"])
        async let sip = Shell.run("/usr/bin/csrutil", ["status"])
        async let gatekeeper = Shell.run("/usr/sbin/spctl", ["--status"])
        async let firewall = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        async let stealth = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getstealthmode"])
        async let profiles = Shell.run("/usr/bin/profiles", ["status", "-type", "enrollment"])

        var checks: [SecurityCheck] = []

        let fv = await fileVault.stdout
        let fvOn = fv.contains("FileVault is On")
        checks.append(SecurityCheck(id: "filevault", title: "FileVault disk encryption",
                                    status: fvOn ? "On" : "Off", severity: fvOn ? .ok : .critical,
                                    detail: fvOn ? "Your data is encrypted at rest." : "Anyone with physical access to this Mac can read its disk."))

        let sipOn = await sip.stdout.contains("enabled")
        checks.append(SecurityCheck(id: "sip", title: "System Integrity Protection",
                                    status: sipOn ? "Enabled" : "Disabled", severity: sipOn ? .ok : .critical,
                                    detail: sipOn ? "System files are protected from modification." : "Malware can modify protected system files."))

        let gkOn = await gatekeeper.stdout.contains("assessments enabled")
        checks.append(SecurityCheck(id: "gatekeeper", title: "Gatekeeper",
                                    status: gkOn ? "Enabled" : "Disabled", severity: gkOn ? .ok : .warning,
                                    detail: gkOn ? "Only signed, notarized apps open without a warning." : "Unsigned apps open without any check."))

        let fwOut = await firewall.stdout
        let fwOn = fwOut.contains("enabled") || fwOut.contains("State = 1") || fwOut.contains("State = 2")
        let stealthOn = await stealth.stdout.contains("is on")
        checks.append(SecurityCheck(id: "firewall", title: "Firewall",
                                    status: fwOn ? (stealthOn ? "On · stealth" : "On") : "Off", severity: fwOn ? .ok : .critical,
                                    detail: fwOn ? "Incoming connections are filtered." : "Incoming connections to this Mac are not filtered."))

        let xprotect = bundleVersion("/Library/Apple/System/Library/CoreServices/XProtect.bundle")
        checks.append(SecurityCheck(id: "xprotect", title: "XProtect malware definitions",
                                    status: xprotect.map { "v\($0)" } ?? "Unknown", severity: xprotect == nil ? .warning : .ok,
                                    detail: "Apple's built-in malware scanner. Definitions update automatically."))

        let mdm = await profiles.stdout
        let enrolled = mdm.contains("MDM enrollment: Yes")
        checks.append(SecurityCheck(id: "mdm", title: "Device management (MDM)",
                                    status: enrolled ? "Managed" : "Not managed", severity: .ok,
                                    detail: enrolled ? "An organization manages this Mac and can install profiles." : "No organization manages this Mac."))

        return SecurityInfo(checks: checks)
    }

    private static func bundleVersion(_ path: String) -> String? {
        Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Turns the firewall on. macOS shows its own administrator password prompt.
    static func enableFirewall() async -> Bool {
        await Shell.runAsAdmin("/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on").succeeded
    }
}
