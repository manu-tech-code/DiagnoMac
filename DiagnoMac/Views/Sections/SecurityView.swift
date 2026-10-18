import SwiftUI

struct SecurityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page("Security", subtitle: "Whether the protections built into macOS are on, and whether anything suspicious is running in the background.") {
            SuspiciousProcessesCard()
            if let sec = model.snapshot.security {
                Columns(minimum: 320) {
                    ForEach(sec.checks) { check in
                        Card {
                            HStack {
                                Text(check.title).font(.headline)
                                Spacer()
                                SeverityPill(severity: check.severity, text: check.status)
                            }
                            Text(check.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if check.id == "firewall" && check.severity > .ok {
                                HStack {
                                    Button("Turn On Firewall…") { Task { await model.enableFirewall() } }
                                        .buttonStyle(.borderedProminent)
                                    Button("Open Settings") {
                                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")!)
                                    }
                                }
                                Text("macOS asks for your administrator password.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                LoadingCard()
            }
        }
    }
}
