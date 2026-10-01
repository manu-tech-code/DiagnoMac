# DiagnoMac

A native macOS app that checks the health of your Mac and tells you what to fix.

## Build and run

Requirements: Xcode 16 or newer, macOS 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open DiagnoMac.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project DiagnoMac.xcodeproj -scheme DiagnoMac -derivedDataPath build build
open build/Build/Products/Debug/DiagnoMac.app
```

The `.xcodeproj` is generated from `project.yml` and is not checked in.

## What it checks

| Area | Source |
|---|---|
| Battery | IOKit `AppleSmartBattery`, IOPowerSources, `system_profiler SPPowerDataType`, `pmset -g custom` |
| Performance | `host_processor_info` (live per-core, 1 s), `getloadavg`, `ps`, thermal state |
| Memory | `host_statistics64`, `vm.swapusage`, `kern.memorystatus_*` |
| Storage | URL volume resource values, `diskutil info disk0` (SMART), folder sizes |
| Network | `NWPathMonitor`, CoreWLAN, `ping`, `getaddrinfo`, `networkQuality` |
| Security | `fdesetup`, `csrutil`, `spctl`, `socketfilterfw`, XProtect bundle, `profiles` |
| Startup items | LaunchAgents / LaunchDaemons plists, `launchctl list` / `print-disabled` |
| Crash logs | `DiagnosticReports` `.ips` headers |
| Hardware tests | Keyboard (raw key codes), full-screen display test, stereo speaker tones, trackpad canvas |

Findings are produced by `FindingsEngine` and ranked into a 0–100 score. A daily history is kept in
`~/Library/Application Support/DiagnoMac/history.json`. A menu bar extra shows live CPU, memory, swap and battery.

## Actions that change your Mac

All are user-initiated and confirmed:

- **Turn on firewall:** macOS shows its own administrator prompt.
- **Cleanup:** folder contents move to the Trash (restorable); unavailable simulators are removed with `xcrun simctl delete unavailable`.
- **Startup items:** user agents are switched with `launchctl disable/bootout` and `enable/bootstrap`. The plist is never deleted. System-wide items are read-only.

## Notes

- The app is not sandboxed because it reads system state and runs Apple's command-line tools.
- Grant Full Disk Access (System Settings → Privacy & Security) to include system-wide crash logs.
- Debug builds accept `-captureScreens <dir>`, which saves a PNG of each page after the first scan and quits.

## Project layout

```
DiagnoMac/
  App/        App entry, AppModel (state + actions), debug capture
  Models/     Area, Severity, Finding, snapshot value types
  Services/   One collector per area, FindingsEngine, HistoryStore, ReportBuilder, Shell, Sysctl
  Views/      RootView, MenuBarView, Components/, Sections/ (one view per area)
```
