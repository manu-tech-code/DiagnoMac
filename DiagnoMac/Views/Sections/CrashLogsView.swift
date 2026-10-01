import SwiftUI

struct CrashLogsView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 7

    var body: some View {
        Page("Crash Logs", subtitle: "Apps that crashed, froze or ran out of memory, grouped by app.") {
            HStack {
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("All").tag(3650)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Button("Refresh") { Task { await model.refresh(.logs) } }
            }
        } content: {
            if let logs = model.snapshot.logs {
                let since = Date().addingTimeInterval(-Double(days) * 86_400)
                let groups = logs.groups(since: since)
                let panics = logs.panics.filter { $0.date >= since }

                Columns(minimum: 200) {
                    StatTile(title: "Kernel panics", value: "\(panics.count)", caption: panics.isEmpty ? "None" : "Last \(Format.relative(panics[0].date))",
                             severity: panics.isEmpty ? .ok : .critical)
                    StatTile(title: "Reports", value: "\(groups.map(\.count).reduce(0, +))", caption: "In this period")
                    StatTile(title: "Apps affected", value: "\(groups.count)")
                }

                Card("By app") {
                    if groups.isEmpty {
                        Text("No crash reports in this period.").foregroundStyle(.secondary)
                    } else {
                        Table(groups) {
                            TableColumn("App") { Text($0.process) }
                            TableColumn("Reports") { Text("\($0.count)").monospacedDigit() }.width(70)
                            TableColumn("Kind") { Text($0.kinds.map(\.rawValue).joined(separator: ", ")).foregroundStyle(.secondary) }
                            TableColumn("Last seen") { Text($0.lastDate.formatted(date: .abbreviated, time: .shortened)) }.width(160)
                            TableColumn("") { group in
                                Button("Open Latest") {
                                    if let latest = group.reports.max(by: { $0.date < $1.date }) { NSWorkspace.shared.open(latest.url) }
                                }
                                .buttonStyle(.link)
                            }.width(90)
                        }
                        .frame(minHeight: 300)
                    }
                }

                if !logs.unreadableFolders.isEmpty {
                    Text("Couldn't read \(logs.unreadableFolders.joined(separator: ", ")). Grant DiagnoMac Full Disk Access in System Settings → Privacy & Security to include them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                LoadingCard()
            }
        }
    }
}
