import AppKit
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
        // Fill the row: cards next to each other are as tall as the tallest.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Cards side by side, all as tall as the tallest.
struct CardRow<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) { content() }
            .fixedSize(horizontal: false, vertical: true)
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
                    RollingText(text: value)
                        // SwiftUI can't read an AppKit view's baseline, so it's given here.
                        .alignmentGuide(.firstTextBaseline) { _ in RollingText.baseline(size: 26) }
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
    var showsLegend = true

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

            if showsLegend { FlowLegend(segments: segments) }
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
                .animation(.smooth(duration: 0.9), value: score)
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

/// A grid of cards with equal widths and, within each row, equal heights. It picks a column count
/// the cards fill: three tiles get three columns rather than three of four, and a short last row
/// shares the width between its cards.
struct Columns<Content: View>: View {
    var minimum: CGFloat = 200
    var spacing: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        EqualColumnsLayout(minimum: minimum, spacing: spacing) { content() }
    }
}

/// Shows `wide` when it has at least `threshold` points of width and `narrow` when it has less. Only the
/// layout in use counts toward the page's minimum width, so a table with fixed columns can keep them in a
/// big window and still let a small one shrink (`ViewThatFits` holds the window open at the wider size).
struct WidthSwitch<Wide: View, Narrow: View>: View {
    let threshold: CGFloat
    @ViewBuilder var wide: () -> Wide
    @ViewBuilder var narrow: () -> Narrow

    // Starts wide: the first measurement comes in the same layout pass.
    @State private var width: CGFloat = .infinity

    var body: some View {
        Group {
            if width >= threshold { wide() } else { narrow() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct EqualColumnsLayout: Layout {
    var minimum: CGFloat
    var spacing: CGFloat

    /// As many columns as fit, balanced so rows hold nearly the same number of cards.
    private func columns(width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 1 }
        let fit = max(1, Int((width + spacing) / (minimum + spacing)))
        let rows = (count + min(fit, count) - 1) / min(fit, count)
        return (count + rows - 1) / rows
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(range: Range<Int>, height: CGFloat, cardWidth: CGFloat)] {
        let cols = columns(width: width, count: subviews.count)
        return stride(from: 0, to: subviews.count, by: cols).map { start in
            let range = start..<min(start + cols, subviews.count)
            let n = CGFloat(range.count)
            let cardWidth = (width - spacing * (n - 1)) / n
            let height = range.map { subviews[$0].sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height }.max() ?? 0
            return (range, height, cardWidth)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let rows = rows(subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            for (i, index) in row.range.enumerated() {
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(i) * (row.cardWidth + spacing), y: y),
                                      proposal: ProposedViewSize(width: row.cardWidth, height: row.height))
            }
            y += row.height + spacing
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

    var body: some View {
        HStack(spacing: 6) {
            PulsingDot(color: NSColor(color)).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A dot whose pulse Core Animation runs on its own, so the app does no work per frame.
struct PulsingDot: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> DotView { DotView() }
    func updateNSView(_ view: DotView, context: Context) { view.color = color }

    final class DotView: NSView {
        var color: NSColor = .systemGreen { didSet { updateColor() } }
        private let dot = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.cornerRadius = bounds.width / 2
            CATransaction.commit()
            updateColor()
            guard dot.animation(forKey: "pulse") == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            dot.add(pulse, forKey: "pulse")
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }

        private func updateColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance { dot.backgroundColor = color.cgColor }
        }
    }
}

/// A live line chart for 0...1 values, newest on the right. Each new sample scrolls in smoothly
/// over the time until the next one, at the display's full refresh rate. Core Animation does the
/// motion, so the app only builds one path per sample.
struct SparklineChart: View {
    let values: [Double]
    var color: Color = .accentColor
    var height: CGFloat = 140
    /// How many samples fill the width; fewer leave the left side empty.
    var capacity: Int = 120
    /// Seconds between samples: how long each new one takes to scroll in.
    var interval: TimeInterval = 1

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ScrollingLine(values: values, capacity: capacity, interval: interval, color: NSColor(color))
            VStack {
                Text("100%"); Spacer(); Text("50%"); Spacer(); Text("0%")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Load over time")
        .accessibilityValue(values.last.map { "\(Int($0 * 100)) percent now" } ?? "No readings yet")
    }
}

private struct ScrollingLine: NSViewRepresentable {
    let values: [Double]
    let capacity: Int
    let interval: TimeInterval
    let color: NSColor

    func makeNSView(context: Context) -> LineView { LineView() }
    func updateNSView(_ view: LineView, context: Context) {
        view.update(values: values, capacity: capacity, interval: interval, color: color)
    }

    final class LineView: NSView {
        private let grid = CAShapeLayer()
        /// Holds the line and its fill; slides left by one step while a new sample comes in.
        private let content = CALayer()
        private let fill = CAShapeLayer()
        private let line = CAShapeLayer()
        private var values: [Double] = []
        private var capacity = 120
        private var interval: TimeInterval = 1
        private var color: NSColor = .controlAccentColor
        private var drawnSize: CGSize = .zero

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            for shape in [grid, fill, line] { shape.fillColor = nil }
            grid.lineWidth = 0.5
            line.lineWidth = 1.5
            line.lineJoin = .round
            line.lineCap = .round
            content.addSublayer(fill)
            content.addSublayer(line)
            layer?.addSublayer(grid)
            layer?.addSublayer(content)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func update(values: [Double], capacity: Int, interval: TimeInterval, color: NSColor) {
            let newSample = values != self.values
            self.values = values
            self.capacity = capacity
            self.interval = interval
            self.color = color
            // Only a new sample redraws: an unrelated SwiftUI update mustn't restart the scroll.
            if newSample { redraw(animated: values.count > 1 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
        }

        override func layout() {
            super.layout()
            if bounds.size != drawnSize { redraw(animated: false) }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }

        private func applyColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                grid.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
                line.strokeColor = color.cgColor
                fill.fillColor = color.withAlphaComponent(0.15).cgColor
            }
        }

        private func redraw(animated: Bool) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            drawnSize = bounds.size
            let w = bounds.width, h = bounds.height
            let step = w / CGFloat(max(capacity - 1, 1))
            // While scrolling, the newest point starts one step past the right edge.
            let start = w + (animated ? step : 0) - step * CGFloat(max(values.count - 1, 0))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let gridPath = CGMutablePath()
            for fraction in [0.0, 0.5, 1.0] {
                let y = h * (1 - fraction)
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: w, y: y))
            }
            grid.frame = bounds
            grid.path = gridPath
            for shape in [content, fill, line] as [CALayer] { shape.frame = bounds }

            let path = CGMutablePath()
            for (i, value) in values.enumerated() {
                let point = CGPoint(x: start + step * CGFloat(i), y: h * (1 - min(1, max(0, value))))
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            line.path = path
            if values.count > 1 {
                let area = path.mutableCopy()!
                area.addLine(to: CGPoint(x: start + step * CGFloat(values.count - 1), y: h))
                area.addLine(to: CGPoint(x: start, y: h))
                area.closeSubpath()
                fill.path = area
            } else {
                fill.path = nil
            }
            applyColors()
            content.removeAnimation(forKey: "scroll")
            CATransaction.commit()

            guard animated else { return }
            let scroll = CABasicAnimation(keyPath: "transform.translation.x")
            scroll.fromValue = 0
            scroll.toValue = -step
            scroll.duration = interval
            scroll.timingFunction = CAMediaTimingFunction(name: .linear)
            scroll.fillMode = .forwards
            scroll.isRemovedOnCompletion = false
            content.add(scroll, forKey: "scroll")
        }
    }
}

// MARK: - Rolling numbers

/// Text that rolls to its new value. Core Animation slides the old value out and the new one in,
/// so a reading that changes every second costs one text render per change, not one per frame.
struct RollingText: NSViewRepresentable {
    let text: String
    var size: CGFloat = 26

    nonisolated static func font(size: CGFloat) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// Distance from the top of the view to the text's baseline.
    nonisolated static func baseline(size: CGFloat) -> CGFloat { ceil(font(size: size).ascender) }

    func makeNSView(context: Context) -> RollingTextView { RollingTextView(size: size) }
    func updateNSView(_ view: RollingTextView, context: Context) { view.setText(text) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingTextView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class RollingTextView: NSView {
        private let textLayer = CATextLayer()
        private let font: NSFont
        private var current = ""

        init(size: CGFloat) {
            font = RollingText.font(size: size)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            textLayer.alignmentMode = .left
            textLayer.truncationMode = .end
            layer?.addSublayer(textLayer)
            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var intrinsicContentSize: NSSize {
            let width = (current as NSString).size(withAttributes: [.font: font]).width
            return NSSize(width: ceil(width) + 1, height: ceil(font.ascender - font.descender))
        }

        func setText(_ new: String) {
            guard new != current else { return }
            let animate = !current.isEmpty && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let rising = (Double(new.filter { $0.isNumber || $0 == "." }) ?? 0) >= (Double(current.filter { $0.isNumber || $0 == "." }) ?? 0)
            current = new
            if animate {
                let roll = CATransition()
                roll.type = .push
                roll.subtype = rising ? .fromBottom : .fromTop
                roll.duration = 0.4
                roll.timingFunction = CAMediaTimingFunction(name: .easeOut)
                textLayer.add(roll, forKey: "roll")
            }
            applyText()
            invalidateIntrinsicContentSize()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayer.frame = bounds
            textLayer.contentsScale = window?.backingScaleFactor ?? 2
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            textLayer.contentsScale = window?.backingScaleFactor ?? 2
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyText()
        }

        private func applyText() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // CATextLayer draws with Core Text, which reads its own color key.
                textLayer.string = NSAttributedString(string: current, attributes: [
                    .font: font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.labelColor.cgColor,
                ])
            }
            CATransaction.commit()
        }
    }
}

/// The update button in the sidebar and the menu bar panel: Check for Updates, until a check finds
/// a version. Then it turns into the update, in the app icon's cobalt, so it's noticed.
struct UpdateButton: View {
    let available: String?
    /// Read on each refresh: Sparkle's last check date isn't observable.
    let lastChecked: () -> Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: available == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(available == nil ? AnyShapeStyle(Brand.light) : AnyShapeStyle(.white))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(available.map { "Update to \($0)" } ?? "Check for Updates")
                        .font(.system(size: 13, weight: .semibold))
                    // Once a minute, so "checked 5 min ago" stays true.
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(subtitle).font(.caption).opacity(0.75).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(UpdateButtonStyle(prominent: available != nil))
        .help(available.map { "Install DiagnoMac \($0)" } ?? "See if there's a newer DiagnoMac")
        .animation(.smooth(duration: 0.4), value: available)
    }

    private var subtitle: String {
        if available != nil { return "Ready to install" }
        return lastChecked().map { "Checked \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" } ?? "See what's new"
    }
}

private struct UpdateButtonStyle: ButtonStyle {
    let prominent: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(shape.fill(prominent ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.quaternary)))
            .overlay(shape.strokeBorder(.white.opacity(prominent ? 0.25 : 0.08)))
            .shadow(color: prominent ? Brand.mid.opacity(0.35) : .clear, radius: 8, y: 3)
            .brightness(hovering ? 0.06 : 0)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A row of choices, one selected, like a segmented control but laid out by us: its size comes from its
/// labels alone, so selecting a choice never changes the width. (The native segmented Picker grew and
/// spilled over what was beside it.) Falls back to the short labels when the full ones don't fit.
struct SegmentedFilter<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var shortLabel: ((Option) -> String)?

    @Namespace private var highlight

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(label)
            if let shortLabel { row(shortLabel) }
        }
    }

    private func row(_ text: @escaping (Option) -> String) -> some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.smooth(duration: 0.3)) { selection = option }
                } label: {
                    Text(text(option))
                        // One weight for all, or the selected one is wider and the whole control shifts.
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
    }
}
