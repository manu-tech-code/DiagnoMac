# DiagnoMac

A native macOS app that checks the health of your Mac, explains what it finds in plain English, and helps you fix it.

## Install

Paste this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/manu-tech-code/DiagnoMac/HEAD/scripts/install.sh | bash
```

It downloads the latest release, checks that the app is signed by the project's
certificate, installs it in Applications and opens it. Run it again any time to
reinstall. After that, the app updates itself.

Or download `DiagnoMac-<version>.dmg` from [Releases](https://github.com/manu-tech-code/DiagnoMac/releases) and drag
DiagnoMac to Applications. A copy downloaded with a browser needs **Open Anyway** in System Settings › Privacy &
Security the first time, because it's signed for development rather than notarized.

## Build and run

Requirements: Xcode 16 or newer, macOS 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The Apple Intelligence features need macOS 26+ with Apple Intelligence turned on; everything else works without them.

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
| Battery & charging | IOKit `AppleSmartBattery` (capacity, adapter details, power telemetry), IOPowerSources, `pmset -g custom` |
| CPU & GPU | `host_processor_info` (per-core, every second), `getloadavg`, `ps`, thermal state; IOAccelerator `PerformanceStatistics` and per-app `accumulatedGPUTime` |
| Memory | `host_statistics64`, `vm.swapusage`, `kern.memorystatus_*` |
| Running apps | `NSWorkspace.runningApplications`, `proc_pid_rusage` (physical footprint and CPU time, including helper processes) |
| Storage & backups | URL volume resource values, `diskutil info disk0` (SMART), `du` per folder for the breakdown, `diskutil apfs list` (macOS's volumes), `tmutil` |
| Network | `NWPathMonitor`, CoreWLAN, `ping`, `getaddrinfo`, `networkQuality` (run under a pseudo-terminal for live progress) |
| Security | `fdesetup`, `csrutil`, `spctl`, `socketfilterfw`, XProtect bundle, `profiles` |
| Startup items | LaunchAgents / LaunchDaemons plists, `launchctl list` / `print-disabled` |
| Devices | `system_profiler SPBluetoothDataType SPUSBHostDataType`, displays, charger |
| Crash logs | `DiagnosticReports` `.ips` headers and crash backtraces |
| Hardware tests | Keyboard (raw key codes), full-screen display test, stereo speaker tones, trackpad canvas, live camera preview, microphone level meter |

Live readings: CPU every second; GPU, battery and charging power every 2 seconds; memory and apps every 5 seconds.
DiagnoMac itself uses about 2% CPU while open.

Findings are produced by `FindingsEngine` and ranked into a 0–100 score. A daily history is kept in
`~/Library/Application Support/DiagnoMac/history.json`, and every charger connection in `charge-log.json` next to it.
A menu bar extra shows the score and live CPU, GPU, memory, swap and battery.

## Apple Intelligence

DiagnoMac uses Apple's on-device Foundation Models framework. Nothing leaves the Mac and no internet is needed.

- **Assistant:** ask questions in plain English. DiagnoMac picks the readings the question is about and gives them to the
  model; the model can also read any other part of the scan through a `readMac` tool. Each answer shows which checks it used.
- **Explain:** on every finding, startup item and crash group. Crash explanations read the report's exception and top stack frames.
- **Summary:** a short health summary on the Overview after each scan.

The on-device model is small and can get details wrong, so prompts include only real readings plus a few facts it tends to
confuse (for example that clearing caches frees disk space, not memory). Prompts live in `AIPrompts` and `FMBridge`.

## Actions that change your Mac

All are user-initiated and confirmed:

- **Quit apps:** asks the app to quit normally, so it can save work. If it hasn't closed after 5 seconds, Force Quit appears.
- **Restart:** shows macOS's own restart dialog.
- **Turn on firewall:** macOS shows its own administrator prompt.
- **Cleanup:** folder contents move to the Trash (restorable); unavailable simulators are removed with `xcrun simctl delete unavailable`.
- **Startup items:** user agents are switched with `launchctl disable/bootout` and `enable/bootstrap`. The plist is never deleted. System-wide items are read-only.

## Settings

DiagnoMac → Settings (⌘,), or the gear in the menu bar panel:

- **Open DiagnoMac at login** registers the app with `SMAppService`. It appears in System Settings → General → Login Items.
- **Start in the menu bar only:** when macOS opens the app at login, it skips the window and the Dock icon. Choosing Open DiagnoMac from the menu bar brings both back.
- **Show DiagnoMac in the menu bar** shows or hides the menu bar icon.

Login Items records the path of the copy you registered. Register from the copy you'll keep (for example in /Applications), not from `build/`.

## App icon

Generated by a script so it can be changed and re-rendered:

```bash
swift scripts/make-icon.swift
```

## Notes

- The app is not sandboxed because it reads system state and runs Apple's command-line tools.
- Grant Full Disk Access (System Settings → Privacy & Security) to include system-wide crash logs.
- Per-app GPU use comes from the graphics driver's counters and needs no admin rights. GPU power and frequency would need `powermetrics` (root).
- Debug builds accept `-captureScreens <dir>`, which saves a PNG of each page after the first scan and quits. Add
  `-captureDelay <seconds>`, `-captureAsk "<question>"` (also runs the Explain features), `-captureSpeedTest` or
  `-capturePowerHistory` (fills the power chart with made-up readings and a gap); a `dump.txt` with the AI output and
  report is written alongside.

## Updates

DiagnoMac updates itself with [Sparkle](https://sparkle-project.org). Once a day it reads `appcast.xml` from the latest
GitHub release, checks the download's EdDSA signature, and installs on relaunch. **Check for Updates…** is in the
DiagnoMac menu and in Settings. The update window shows a timeline of releases, built from their release notes.
Development builds don't check the real feed; point one at a local appcast with
`defaults write com.amalitech.DiagnoMac DebugFeedURL file:///…/appcast.xml`.

## Contributing and releases

`develop` is the default branch; changes reach it through pull requests from `feat/`, `fix/`, `chore/` and similar
branches, and `main` only through a pull request from `develop`. Merging into `main` drafts the GitHub release.
See [CONTRIBUTING.md](CONTRIBUTING.md).

## Project layout

```
DiagnoMac/
  App/        App entry, AppModel (state, live sampling, actions), login item, debug capture
  Models/     Area, Severity, Finding, snapshot and live-data value types
  Services/   One collector per area, samplers (CPU, GPU, apps), speed test runner, Intelligence (Foundation Models),
              FindingsEngine, DiagnosticsDescriber, HistoryStore, ReportBuilder, Shell, Sysctl
  Views/      RootView, MenuBarView, SettingsView, Components/, Sections/ (one view per area)
Packages/DiagnoKit/   UI-free logic with tests (release notes, networkQuality parsing): `swift test`
.github/              PR rules, tests, and the Release workflow
scripts/ci/           What the workflows run
```
