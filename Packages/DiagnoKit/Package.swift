// swift-tools-version: 6.2
// Pure, UI-free logic for DiagnoMac: release notes for the update window, the
// networkQuality parsers and which readings the assistant reads for a question.
// Tested with `swift test` without launching the app.
import PackageDescription

let package = Package(
    name: "DiagnoKit",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "DiagnoCore", targets: ["DiagnoCore"]),
    ],
    targets: [
        .target(name: "DiagnoCore"),
        .testTarget(name: "DiagnoCoreTests", dependencies: ["DiagnoCore"]),
    ]
)
