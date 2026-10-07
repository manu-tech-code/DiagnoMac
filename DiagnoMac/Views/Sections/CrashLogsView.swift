import SwiftUI

struct CrashLogsView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 7

    var body: some View {
        let _ = model.intelligence.checkAvailabilityIfNeeded()
        Page("Crash Logs", subtitle: "Apps that crashed, froze or ran out of memory, grouped by app.") {
            HStack {
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("All").tag(3650)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
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
                    StatTile(title: "Apps affected", value: "\(groups.count)",
                             caption: "\(groups.filter(\.isFirstParty).count) part of macOS")
                }

                Card("By app") {
                    if groups.isEmpty {
                        Text("No crash reports in this period.").foregroundStyle(.secondary)
                    } else {
                        // The columns need about 750 points; below that each app gets two lines instead.
                        WidthSwitch(threshold: 750) {
                            VStack(spacing: 0) {
                                HStack {
                                    Text("App").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("Reports").frame(width: 70, alignment: .trailing)
                                    Text("Kind").frame(width: 150, alignment: .leading)
                                    Text("Last seen").frame(width: 150, alignment: .leading)
                                    Spacer().frame(width: 200)
                                }
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                                ForEach(groups.prefix(40)) { group in
                                    Divider()
                                    row(group, compact: false)
                                }
                            }
                        } narrow: {
                            VStack(spacing: 0) {
                                ForEach(groups.prefix(40)) { group in
                                    Divider()
                                    row(group, compact: true)
                                }
                            }
                        }
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

    private func processName(_ group: CrashGroup) -> some View {
        HStack(spacing: 6) {
            Text(group.process).lineLimit(1)
            if group.isFirstParty {
                Text("macOS").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(.separator))
            }
        }
    }

    private func actions(_ group: CrashGroup, key: String) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.intelligence.isAvailable && model.intelligence.text(for: key) == nil {
                ExplainButton(title: "Explain") { model.explain(group) }.controlSize(.small)
            }
            Button("Open Latest") {
                if let latest = group.reports.max(by: { $0.date < $1.date }) { NSWorkspace.shared.open(latest.url) }
            }
            .buttonStyle(.link)
        }
    }

    private func row(_ group: CrashGroup, compact: Bool) -> some View {
        let key = "crash.\(group.process)"
        let kinds = group.kinds.map(\.rawValue).joined(separator: ", ")
        let lastSeen = group.lastDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return VStack(alignment: .leading, spacing: 8) {
            if compact {
                // The name, then the numbers under it, with the buttons on the right.
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        processName(group)
                        Text("\(group.count) \(group.count == 1 ? "report" : "reports") · \(kinds) · \(lastSeen)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    actions(group, key: key).fixedSize()
                }
            } else {
                HStack {
                    processName(group).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(group.count)").monospacedDigit().frame(width: 70, alignment: .trailing)
                    Text(kinds).foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .leading)
                    Text(lastSeen).frame(width: 150, alignment: .leading)
                    actions(group, key: key).frame(width: 200)
                }
            }
            if let text = model.intelligence.text(for: key) {
                AIBlock(title: "Read the latest report on this Mac", text: text,
                        onDismiss: { model.intelligence.dismiss(key: key) },
                        onRetry: { model.explain(group) })
            }
        }
        .padding(.vertical, 7)
    }
}
