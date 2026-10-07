import SwiftUI

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @State private var question: String = {
        #if DEBUG
        // `-assistantDraft "text"`: start with that typed into the input, for screenshots.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-assistantDraft"), i + 1 < args.count { return args[i + 1] }
        #endif
        return ""
    }()
    @FocusState private var inputFocused: Bool

    private var ai: Intelligence { model.intelligence }

    private let suggestions = [
        "Why is my Mac slow?", "Is my battery healthy?", "What can I safely delete?",
        "Which apps should I quit?", "What's using the GPU?", "Is my Mac secure?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant").font(.largeTitle.weight(.semibold))
                    Text("Ask about this Mac in plain English. Answers use the readings from your latest scan.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !ai.messages.isEmpty {
                    Button("New Conversation") { ai.resetChat() }.disabled(ai.isResponding)
                }
            }

            // The "How it works" card beside the chat when there's room for both, otherwise a line under the
            // header: squeezed beside it, the chat and its input were too narrow to use.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    mainColumn.frame(minWidth: 440, idealWidth: 440, maxWidth: .infinity)
                    // Its own height, not the chat's.
                    infoCard.frame(width: 270).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Runs on this Mac. Nothing is sent anywhere, and the model can get details wrong.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    mainColumn
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { ai.refreshAvailability() }
    }

    @ViewBuilder
    private var mainColumn: some View {
        if ai.isAvailable { chat } else { unavailable.fixedSize(horizontal: false, vertical: true) }
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if ai.messages.isEmpty {
                            Card {
                                Text("Try one of these, or type your own question.").foregroundStyle(.secondary)
                                suggestionChips
                            }
                        }
                        ForEach(ai.messages) { message in
                            MessageView(message: message).id(message.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: ai.messages.last?.text) {
                    if let last = ai.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if !ai.messages.isEmpty && !ai.isResponding { suggestionChips }

            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { inputFocused = true }
    }

    /// One rounded box that grows with what you type, with the send button inside it, like a message field.
    private var composer: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this Mac…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.leading, 16)
                .padding(.vertical, 12)
            sendButton.padding(.trailing, 8).padding(.bottom, 8)
        }
        .frame(minHeight: 48)
        .background(.background.secondary, in: shape)
        .overlay(shape.strokeBorder(inputFocused ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.separator),
                                    lineWidth: inputFocused ? 1.5 : 1))
        .contentShape(shape)
        .onTapGesture { inputFocused = true }
        .animation(.smooth(duration: 0.2), value: inputFocused)
    }

    @ViewBuilder
    private var sendButton: some View {
        let isEmpty = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if ai.isResponding {
            Button { ai.stopResponding() } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isEmpty)
            .help("Ask (⌘↩)")
        }
    }

    private var suggestionChips: some View {
        FlowChips(items: suggestions) { ask($0) }
            .disabled(ai.isResponding)
    }

    private func send() {
        ask(question)
        question = ""
    }

    private func ask(_ text: String) {
        ai.send(text)
    }

    private var unavailable: some View {
        Card {
            Label("Apple Intelligence isn't available", systemImage: "sparkles")
                .font(.headline).foregroundStyle(Color.intelligence)
            Text(ai.availability.message).fixedSize(horizontal: false, vertical: true)
            HStack {
                if ai.availability == .appleIntelligenceOff {
                    Button("Open Apple Intelligence Settings") { ai.openSettings() }.buttonStyle(.borderedProminent)
                }
                Button("Check Again") { ai.refreshAvailability() }
            }
            Text("Every other part of DiagnoMac works without it.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var infoCard: some View {
        Card("How it works") {
            Text("Uses Apple's on-device Foundation Models. The model reads DiagnoMac's checks through a tool, so answers come from your real readings rather than guesses.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 7) {
                KeyValueRow(key: "Runs on", value: "This Mac")
                KeyValueRow(key: "Needs internet", value: "No")
                KeyValueRow(key: "Data sent anywhere", value: "None")
                HStack {
                    Text("Model").foregroundStyle(.secondary)
                    Spacer()
                    Text(ai.isAvailable ? "Available" : "Unavailable").foregroundStyle(ai.isAvailable ? .green : .secondary)
                }
            }
            Text("The model is small and can get details wrong. Each answer lists the checks it read, so you can verify them on that page.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MessageView: View {
    let message: Intelligence.ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                Label("DiagnoMac", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(Color.intelligence)
                if let note = message.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let error = message.error {
                    Text(error).foregroundStyle(.secondary)
                } else if message.text.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(message.sectionsRead.isEmpty ? "Thinking…" : "Reading \(message.sectionsRead.joined(separator: ", ").lowercased())…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(AIPrompts.clean(message.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !message.sectionsRead.isEmpty && !message.isStreaming {
                    HStack(spacing: 6) {
                        Text("Checked").font(.caption).foregroundStyle(.secondary)
                        ForEach(message.sectionsRead, id: \.self) { section in
                            Text(section).font(.caption.monospaced())
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(.separator))
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 640, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
        }
    }
}

/// Wrapping row of tappable suggestion chips.
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        ChipLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(item) { onTap(item) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct ChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
