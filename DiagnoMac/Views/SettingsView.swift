import SwiftUI

struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem
    @AppStorage(Preferences.startInMenuBarKey) private var startInMenuBar = true
    @AppStorage(Preferences.showMenuBarIconKey) private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section {
                Toggle("Open DiagnoMac at login", isOn: Binding(
                    get: { loginItem.isEnabled || loginItem.needsApproval },
                    set: { loginItem.setEnabled($0) }))
                Toggle("Start in the menu bar only", isOn: $startInMenuBar)
                    .disabled(!loginItem.isEnabled || !showMenuBarIcon)
                Text("At login, DiagnoMac runs in the menu bar without a window or Dock icon. Choose Open DiagnoMac from the menu bar to bring the window back.")
                    .font(.caption).foregroundStyle(.secondary)

                if loginItem.needsApproval {
                    HStack {
                        Label("Waiting for your approval in System Settings.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { loginItem.openLoginItemsSettings() }
                    }
                }
                if let error = loginItem.error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Login")
            }

            Section {
                Toggle("Show DiagnoMac in the menu bar", isOn: $showMenuBarIcon)
                Text("Shows the health score and live CPU, memory, swap and battery readings.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Menu bar")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh() }
        // Approval happens in System Settings, so re-check whenever the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}
