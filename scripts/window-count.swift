// Prints how many on-screen windows a process has. Used by scripts/measure.sh.
//   swiftc -O scripts/window-count.swift -o build/window-count && build/window-count <pid>
import CoreGraphics

let pid = Int32(CommandLine.arguments.dropFirst().first ?? "") ?? 0
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count)
