import DiagnoCore
import SwiftUI

/// The Security page's scan of background programs: what was checked, and the ones worth a look.
struct SuspiciousProcessesCard: View {
    @Environment(AppModel.self) private var model
    @State private var pendingStop: SuspiciousProcess?

    var body: some View {
        let _ = model.intelligence.checkAvailabilityIfNeeded()
        let scan = model.snapshot.processScan
        Card("Background programs", trailing: scan.map { "Checked \($0.scannedAt.formatted(date: .omitted, time: .shortened))" }) {
            header(scan)
            if let scan, !scan.flagged.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(scan.flagged.enumerated()), id: \.element.id) { index, process in
                        if index > 0 { Divider().padding(.vertical, 12) }
                        row(process)
                    }
                }
            }
            Text("A flag is a hint, not proof. DiagnoMac looks for things malware does and normal software rarely does: running from a temporary or hidden folder, pretending to be part of macOS, having no real signature, or mining cryptocurrency. Nothing leaves this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let scan, scan.trustedByYou > 0 {
                HStack(spacing: 4) {
                    Text("\(scan.trustedByYou) program\(scan.trustedByYou == 1 ? "" : "s") you marked as fine are skipped.")
                    Button("Check Them Again") { model.resetTrustedPrograms() }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Stop \(pendingStop?.name ?? "")?", isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } })) {
            Button("Stop") { if let p = pendingStop { Task { await model.stop(p) } }; pendingStop = nil }
        } message: {
            Text(pendingStop?.ownedByYou == false
                 ? "It belongs to the system, so macOS asks for your administrator password. Unsaved work in it would be lost."
                 : "Unsaved work in it would be lost. If it starts itself again, switch it off in Startup Items.")
        }
    }

    // MARK: Summary

    @ViewBuilder
    private func header(_ scan: ProcessScanResult?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let scan {
                let bad = scan.suspicious.count
                let odd = scan.worthChecking.count
                Image(systemName: bad > 0 ? "exclamationmark.shield.fill" : odd > 0 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .font(.title).foregroundStyle(bad > 0 ? Severity.critical.color : odd > 0 ? Severity.warning.color : Severity.ok.color)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(bad: bad, odd: odd)).font(.headline)
                    Text("\(scan.checked) programs checked: \(scan.fromApple) from Apple, \(scan.fromDevelopers) from registered developers, \(scan.checked - scan.fromApple - scan.fromDevelopers) from other sources.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Image(systemName: "shield.lefthalf.filled").font(.title).foregroundStyle(.secondary)
                Text(model.isScanningProcesses ? "Checking every program running in the background…" : "Not checked yet.")
                    .font(.headline)
            }
            Spacer(minLength: 8)
            if model.isScanningProcesses || (model.isScanning && scan == nil) {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await model.scanProcesses() } } label: { Label(scan == nil ? "Scan Now" : "Scan Again", systemImage: "magnifyingglass") }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func headline(bad: Int, odd: Int) -> String {
        switch (bad, odd) {
        case (0, 0): "Nothing suspicious is running"
        case (let b, 0): b == 1 ? "1 program looks suspicious" : "\(b) programs look suspicious"
        case (0, let o): o == 1 ? "1 program is worth a look" : "\(o) programs are worth a look"
        case (let b, let o): "\(b) look suspicious, \(o) more are worth a look"
        }
    }

    // MARK: Rows

    private func row(_ process: SuspiciousProcess) -> some View {
        let key = "process.\(process.id)"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SeverityPill(severity: process.severity, text: process.concern == .suspicious ? "Suspicious" : "Worth a look")
                Text(process.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("PID \(String(process.facts.pid))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(process.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(process.assessment.signals.enumerated()), id: \.offset) { _, signal in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(process.severity.color)
                        Text(signal.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
            Text("Signed by \(process.signedBy)\(process.facts.isRoot ? " · runs as administrator" : "")")
                .font(.caption).foregroundStyle(.secondary)

            if let text = model.intelligence.text(for: key) {
                AIBlock(title: "Explained on this Mac", text: text,
                        onDismiss: { model.intelligence.dismiss(key: key) }, onRetry: { model.explain(process) })
            }
            actions(process, key: key)
        }
    }

    private func actions(_ process: SuspiciousProcess, key: String) -> some View {
        WrappingButtons {
            Button("Stop…") { pendingStop = process }.buttonStyle(.borderedProminent).tint(process.severity.color)
            if model.processStopRequests[process.facts.pid] != nil {
                Button("Force Quit") { Task { await model.stop(process, force: true) } }.buttonStyle(.bordered)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: process.path)]) }
            if process.facts.launchedBy != nil {
                Button("Startup Items") { model.selection = .startup }
            }
            if model.intelligence.isAvailable && model.intelligence.text(for: key) == nil {
                ExplainButton(title: "Is This Safe?") { model.explain(process) }
            }
            Button("It's Fine") { model.trust(process) }.help("Stop flagging this program")
        }
        .controlSize(.small)
    }
}

/// Buttons in a row that wraps onto the next line when the window is narrow.
struct WrappingButtons<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        WrapLayout(spacing: 8) { content() }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest.isFinite ? widest : 0, height: y + rowHeight))
    }
}
