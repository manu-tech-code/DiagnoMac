import SwiftUI

@main
struct DiagnoMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var loginItem = LoginItem()
    @AppStorage(Preferences.showMenuBarIconKey) private var showMenuBarIcon = true

    var body: some Scene {
        Window("DiagnoMac", id: AppDelegate.mainWindowID) {
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

        Settings {
            SettingsView().environment(loginItem)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView().environment(model)
        } label: {
            Label("DiagnoMac", systemImage: model.score >= 90 || model.findings.isEmpty ? "stethoscope" : "stethoscope.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
