import Charts
import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .ok: .green
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Page scaffold: title, subtitle, optional toolbar content, scrolling body.
struct Page<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.largeTitle.weight(.semibold))
                        Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    actions()
                }
                content()
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, trailing: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                    Spacer()
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var unit: String?
    var caption: String?
    var severity: Severity?

    var body: some View {
        Card(title) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                    if let unit { Text(unit).foregroundStyle(.secondary) }
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                if let severity {
                    SeverityPill(severity: severity, text: caption ?? severity.label)
                } else if let caption {
                    Text(caption).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

struct SeverityPill: View {
    let severity: Severity
    var text: String?

    var body: some View {
        Text(text ?? severity.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(severity.color)
            .background(severity.color.opacity(0.14), in: Capsule())
    }
}

struct SeverityDot: View {
    let severity: Severity
    var body: some View {
        Circle().fill(severity.color).frame(width: 7, height: 7)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).monospacedDigit().textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}

/// A horizontal bar split into labelled segments.
struct SegmentBar: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var detail: String
        var id: String { label }
    }

    let segments: [Segment]
    var height: CGFloat = 16

    var body: some View {
        let total = max(segments.map(\.value).reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments) { s in
                        Rectangle().fill(s.color).frame(width: max(0, geo.size.width * s.value / total))
                            .help("\(s.label): \(s.detail)")
                    }
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            FlowLegend(segments: segments)
        }
    }
}

private struct FlowLegend: View {
    let segments: [SegmentBar.Segment]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(segments) { s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 9, height: 9)
                    Text(s.label).foregroundStyle(.secondary)
                    Text(s.detail).monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}

struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 132

    var color: Color { score >= 90 ? .green : score >= 75 ? .orange : .red }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 10)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: score)
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: size * 0.33, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text("of 100").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score \(score) of 100")
    }
}

struct FindingRow: View {
    let finding: Finding
    let perform: (Finding) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(finding.severity.color).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(finding.title).fontWeight(.semibold)
                    SeverityPill(severity: finding.severity)
                }
                Text(finding.detail).foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let title = finding.actionTitle {
                Button(title) { perform(finding) }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Placeholder shown while a section's collector is still running.
struct LoadingCard: View {
    var text = "Collecting…"
    var body: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}

struct Columns<Content: View>: View {
    var minimum: CGFloat = 200
    @ViewBuilder var content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            content()
        }
    }
}

// MARK: - Findings

extension Severity {
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .info: "lightbulb.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

/// One finding with room to breathe: icon, title, explanation, area, and its actions.
struct FindingCard: View {
    let finding: Finding
    var explanation: AIText?
    var canExplain: Bool
    let perform: (Finding) -> Void
    let explain: (Finding) -> Void
    var dismissExplanation: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: finding.severity.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(finding.severity.color)
                .frame(width: 36, height: 36)
                .background(finding.severity.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 6) {
                Text(finding.title).font(.headline)
                Text(finding.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(finding.area.title, systemImage: finding.area.systemImage)
                    .font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
                if let explanation {
                    AIBlock(title: "Explained on this Mac", text: explanation, onDismiss: dismissExplanation,
                            onRetry: { explain(finding) })
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                if let title = finding.actionTitle {
                    if finding.severity >= .warning {
                        Button(title) { perform(finding) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(title) { perform(finding) }
                    }
                }
                if canExplain && explanation == nil {
                    ExplainButton { explain(finding) }
                }
            }
            .fixedSize()
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

// MARK: - Apple Intelligence

/// The color used for anything written by the on-device model.
extension Color {
    static let intelligence = Color.purple
}

struct ExplainButton: View {
    var title = "Explain"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .tint(.intelligence)
        .help("Explain with Apple Intelligence, on this Mac")
    }
}

/// Text from the on-device model, streamed in as it's written.
struct AIBlock: View {
    let title: String
    let text: AIText
    var onDismiss: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.intelligence)
                Spacer()
                if text.isStreaming { ProgressView().controlSize(.mini) }
                if let onDismiss, !text.isStreaming {
                    Button { onDismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Hide")
                }
            }
            if let error = text.error {
                HStack(alignment: .firstTextBaseline) {
                    Text(error).foregroundStyle(.secondary)
                    if let onRetry { Button("Try Again", action: onRetry).buttonStyle(.link) }
                }
            } else if text.text.isEmpty {
                Text("Thinking…").foregroundStyle(.secondary)
            } else {
                Text(AIPrompts.clean(text.text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.15), value: text.text)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.intelligence.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.intelligence.opacity(0.22)))
    }
}

/// A small pulsing dot with a label, for things that are happening right now.
struct LiveBadge: View {
    let text: String
    var color: Color = .green
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(pulse ? 0.3 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .onAppear { pulse = true }
    }
}

/// Small line chart for a series of 0...1 values, newest on the right.
struct SparklineChart: View {
    let values: [Double]
    var color: Color = .accentColor
    var height: CGFloat = 140

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("Sample", index), y: .value("Load", value * 100))
                .foregroundStyle(color.opacity(0.15))
            LineMark(x: .value("Sample", index), y: .value("Load", value * 100))
                .foregroundStyle(color)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
        .frame(height: height)
    }
}
