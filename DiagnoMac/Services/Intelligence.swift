import AppKit
import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Text produced by the on-device model, updated as it streams in.
struct AIText: Sendable, Equatable {
    var text = ""
    var isStreaming = false
    var error: String?
}

/// Apple Intelligence features: the assistant chat, explanations and the scan summary.
/// Everything runs on this Mac through the Foundation Models framework. Nothing is sent anywhere.
@MainActor
@Observable
final class Intelligence {
    enum Availability: Equatable {
        case available, appleIntelligenceOff, deviceNotEligible, modelNotReady, unsupportedOS
        case unknown(String)

        var message: String {
            switch self {
            case .available: "Available on this Mac"
            case .appleIntelligenceOff: "Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri."
            case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
            case .modelNotReady: "The on-device model is still downloading. Try again in a few minutes."
            case .unsupportedOS: "Apple Intelligence features need macOS 26 or later."
            case .unknown(let reason): "The on-device model isn't available (\(reason))."
            }
        }
    }

    struct ChatMessage: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var isStreaming = false
        var error: String?
        var sectionsRead: [String] = []
        var note: String?
    }

    private(set) var availability: Availability = .unsupportedOS
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var texts: [String: AIText] = [:]

    /// Supplies the latest readings to the assistant's tool.
    var context: (@MainActor () -> (DiagnosticsSnapshot, [Finding]))?

    private var chatSession: AnyObject?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var chatTask: Task<Void, Never>?

    var isAvailable: Bool { availability == .available }

    init() { refreshAvailability() }

    func refreshAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            availability = FMBridge.availability()
            return
        }
        #endif
        availability = .unsupportedOS
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
    }

    // MARK: One-shot text

    func text(for key: String) -> AIText? { texts[key] }

    /// Streams a response into `texts[key]`. Does nothing if a good answer already exists, unless forced.
    func generate(key: String, instructions: String, prompt: String, force: Bool = false) {
        guard isAvailable else { return }
        if !force, let existing = texts[key], existing.error == nil, existing.isStreaming || !existing.text.isEmpty { return }
        tasks[key]?.cancel()
        texts[key] = AIText(isStreaming: true)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            tasks[key] = Task { [weak self] in
                do {
                    for try await partial in FMBridge.stream(instructions: instructions, prompt: prompt) {
                        self?.texts[key]?.text = partial
                    }
                    self?.texts[key]?.isStreaming = false
                } catch is CancellationError {
                    self?.texts[key]?.isStreaming = false
                } catch {
                    self?.texts[key] = AIText(error: FMBridge.describe(error))
                }
            }
        }
        #endif
    }

    func dismiss(key: String) {
        tasks[key]?.cancel()
        texts[key] = nil
    }

    // MARK: Chat

    func send(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, isAvailable, !isResponding else { return }
        messages.append(ChatMessage(role: .user, text: q))
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        isResponding = true
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            chatTask = Task { [weak self] in await self?.runChat(q, allowRetry: true) }
        }
        #endif
    }

    func stopResponding() {
        chatTask?.cancel()
        updateLastAssistant { $0.isStreaming = false }
        isResponding = false
    }

    func resetChat() {
        stopResponding()
        messages.removeAll()
        chatSession = nil
    }

    private func updateLastAssistant(_ change: (inout ChatMessage) -> Void) {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        change(&messages[index])
    }

    private func readForTool(_ section: DiagnosticsSection) -> String {
        updateLastAssistant { if !$0.sectionsRead.contains(section.title) { $0.sectionsRead.append(section.title) } }
        guard let current = context?() else { return "No readings yet. A scan is still running." }
        return DiagnosticsDescriber.describe(section, current.0, findings: current.1)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func runChat(_ question: String, allowRetry: Bool) async {
        let session: LanguageModelSession
        if let existing = chatSession as? LanguageModelSession {
            session = existing
        } else {
            session = FMBridge.makeChatSession { [weak self] section in
                await MainActor.run { self?.readForTool(section) ?? "" }
            }
            chatSession = session
        }

        // Give the model the readings this question is about; it can still call readMac for more.
        let sections = DiagnosticsSection.relevant(to: question)
        var context = ""
        if let current = self.context?() {
            context = sections.map { "[\($0.title)]\n" + String(DiagnosticsDescriber.describe($0, current.0, findings: current.1).prefix(900)) }
                .joined(separator: "\n\n")
        }
        updateLastAssistant { message in
            for s in sections where !message.sectionsRead.contains(s.title) { message.sectionsRead.append(s.title) }
        }
        let prompt = context.isEmpty ? question : "Question: \(question)\n\nCurrent readings from this Mac:\n\(context)"

        do {
            for try await partial in FMBridge.stream(session: session, prompt: prompt) {
                updateLastAssistant { $0.text = partial }
            }
            updateLastAssistant { $0.isStreaming = false }
        } catch is CancellationError {
            updateLastAssistant { $0.isStreaming = false }
        } catch let error where allowRetry && FMBridge.isContextOverflow(error) {
            // The model's context window is small; start over and answer the same question.
            chatSession = nil
            updateLastAssistant {
                $0.text = ""
                $0.sectionsRead = []
                $0.note = "Started a fresh conversation because the previous one was too long for the on-device model."
            }
            await runChat(question, allowRetry: false)
            return
        } catch {
            updateLastAssistant {
                $0.isStreaming = false
                $0.error = FMBridge.describe(error)
            }
        }
        isResponding = false
    }
    #endif
}

// MARK: - Prompts

enum AIPrompts {
    /// Facts the on-device model tends to get wrong without being told.
    static let macFacts = """
    Facts: deleting caches or files frees disk space, not memory (RAM). To free memory, quit idle apps, close browser tabs, \
    or restart. Swap is memory stored on the SSD when RAM is full. Crashes in macOS's own processes are fixed by macOS updates, \
    not by the owner. Time Machine needs an external or network disk.
    """

    static let explainInstructions = """
    You explain one Mac diagnostic finding to the Mac's owner, who isn't technical. Use only the facts provided; never invent numbers. \
    Write 2 to 4 short sentences in plain English: what it means, why it matters, and what to do. \
    Talk only about this finding, not other problems. No headings, lists or markdown.
    \(macFacts)
    """

    static func finding(_ f: Finding, snapshot: DiagnosticsSnapshot, findings: [Finding]) -> String {
        """
        Finding: \(f.title). \(f.detail)\(f.actionTitle.map { " DiagnoMac can help with: \($0.replacingOccurrences(of: "…", with: ""))." } ?? "")
        Related readings:
        \(DiagnosticsDescriber.describe(DiagnosticsSection(finding: f), snapshot, findings: findings))
        """
    }

    static let summaryInstructions = """
    You write a short health summary of a Mac for its owner. Use only the facts provided. \
    Write 2 or 3 sentences in plain English. Lead with the most important problem. Mention at most two actions, \
    taken from the findings' "Fix in DiagnoMac" suggestions. Don't repeat the score. No lists or markdown.
    \(macFacts)
    """

    static func summary(snapshot: DiagnosticsSnapshot, findings: [Finding]) -> String {
        DiagnosticsDescriber.describe(.overview, snapshot, findings: findings)
    }

    static func startupItem(_ item: StartupItem) -> String {
        let program = item.program.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "not listed"
        return """
        Explain this background item that starts when the Mac's owner logs in: what it most likely does, judging from its \
        maker and program name, and what happens if they turn it off. Program names usually describe their job, \
        for example an "updater" keeps an app up to date and a "server" runs a service in the background. \
        Turning it off in DiagnoMac is reversible, and the app it belongs to still works when opened by hand. \
        If you're unsure what it is, say what it probably is rather than refusing.
        Made by: \(item.vendor)
        Label: \(item.label)
        Program: \(program) (full path: \(item.program ?? "not listed"))
        Starts at login: \(item.runAtLoad ? "yes" : "no"). Restarted automatically if it quits: \(item.keepAlive ? "yes" : "no"). \
        Scope: \(item.scope.rawValue.lowercased()).
        """
    }

    /// The small model sometimes answers with markdown anyway; show it as plain text.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
    }

    static func crash(_ group: CrashGroup, reportSummary: String) -> String {
        """
        Explain why this app crashed, whether it's the app's fault or macOS's, and what the owner should do. \
        \(group.process) produced \(group.count) reports recently (\(group.kinds.map(\.rawValue).joined(separator: ", "))).
        Latest report:
        \(reportSummary)
        """
    }
}

// MARK: - Foundation Models bridge

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum FMBridge {
    static let chatInstructions = """
    You are the assistant inside DiagnoMac, a diagnostics app running on this Mac. Answer questions about this Mac's health. \
    Each question comes with current readings from this Mac. Answer from those; call readMac only if you need a part that isn't included. \
    Never guess or invent numbers; if something isn't available, say so. Answer the question that was asked, using specific names and numbers. \
    Keep answers under 120 words, in plain sentences: no bullet points, numbered lists, headings or markdown. \
    When something needs fixing, end with one concrete step. \
    Only suggest quitting apps listed as idle, and never suggest quitting Finder or DiagnoMac. \
    DiagnoMac can quit apps (Running Apps), free memory (Memory), clean caches (Storage), turn off startup items (Startup Items) \
    and turn on the firewall (Security).
    \(AIPrompts.macFacts)
    """

    static func availability() -> Intelligence.Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .deviceNotEligible: return .deviceNotEligible
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown(String(describing: reason))
            }
        }
    }

    static func makeChatSession(read: @escaping @Sendable (DiagnosticsSection) async -> String) -> LanguageModelSession {
        LanguageModelSession(tools: [ReadMacTool(read: read)], instructions: chatInstructions)
    }

    static func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        stream(session: LanguageModelSession(instructions: instructions), prompt: prompt)
    }

    /// Each element is the full response so far.
    static func stream(session: LanguageModelSession, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func isContextOverflow(_ error: Error) -> Bool {
        if let generation = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = generation { return true }
        return false
    }

    static func describe(_ error: Error) -> String {
        guard let generation = error as? LanguageModelSession.GenerationError else { return error.localizedDescription }
        switch generation {
        case .exceededContextWindowSize: return "That was too much for the on-device model to read at once."
        case .guardrailViolation: return "Apple's safety filter blocked this answer. Try asking a different way."
        case .unsupportedLanguageOrLocale: return "The on-device model doesn't support this language yet."
        case .assetsUnavailable: return "The on-device model isn't ready yet. Try again in a few minutes."
        case .rateLimited, .concurrentRequests: return "The model is busy with another request. Try again in a moment."
        case .refusal: return "The model declined to answer that."
        default: return generation.localizedDescription
        }
    }
}

/// Lets the model read one part of the latest scan at a time.
@available(macOS 26.0, *)
struct ReadMacTool: Tool {
    let name = "readMac"
    let description = "Reads current diagnostics for one part of this Mac. Call it once per part you need."
    let read: @Sendable (DiagnosticsSection) async -> String

    @Generable
    struct Arguments {
        @Guide(description: "Which part of the Mac to read. Start with overview for the big picture.")
        var section: ToolSection
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await read(arguments.section.diagnosticsSection)
    }
}

@available(macOS 26.0, *)
@Generable
enum ToolSection: String {
    case overview, battery, cpu, gpu, memory, apps, storage, backup, network, security, startup, crashes, devices

    var diagnosticsSection: DiagnosticsSection { DiagnosticsSection(rawValue: rawValue) ?? .overview }
}
#endif
