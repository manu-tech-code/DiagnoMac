import SwiftUI

@main
struct DiagnoMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("DiagnoMac", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Run Full Scan") { Task { await model.scan() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isScanning)
            }
            CommandMenu("Go") {
                ForEach(Array(Area.allCases.enumerated()), id: \.element) { index, area in
                    if index < 9 {
                        Button(area.title) { model.selection = area }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                    } else {
                        Button(area.title) { model.selection = area }
                    }
                }
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Label("DiagnoMac", systemImage: model.score >= 90 || model.findings.isEmpty ? "stethoscope" : "stethoscope.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
