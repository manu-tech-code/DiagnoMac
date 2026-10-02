import Testing
@testable import DiagnoCore

@Suite struct AssistantRoutingTests {
    @Test("Questions about keeping the Mac plugged in read the battery", arguments: [
        // Word for word from a report where these got answers about backups instead.
        "is advisable to keep this mac plugged in at 80 -> 100% ?",
        "is advisable to keep this mac plugged when the battery is at 80 -> 100% ?",
        "Should I unplug the charger once it's full?",
        "Is it safe to leave it plugged in overnight?",
    ])
    func pluggedIn(question: String) {
        #expect(DiagnosticsSection.relevant(to: question) == [.battery])
    }

    @Test func routesEachPart() {
        #expect(DiagnosticsSection.relevant(to: "Why is my Mac slow?") == [.memory, .cpu])
        #expect(DiagnosticsSection.relevant(to: "Which apps can I quit?") == [.apps, .memory])
        #expect(DiagnosticsSection.relevant(to: "Why does WindowServer use so much CPU?") == [.cpu])
        #expect(DiagnosticsSection.relevant(to: "How can I free up disk space?") == [.storage])
        #expect(DiagnosticsSection.relevant(to: "Is my Wi-Fi connection good?") == [.network])
        #expect(DiagnosticsSection.relevant(to: "When did Time Machine last back up?") == [.backup])
        #expect(DiagnosticsSection.relevant(to: "Why did the kernel_task spike?") == [.cpu])
    }

    @Test func keywordsMatchWholeWords() {
        // Matching inside words read "Apple" as apps and "plugins" as the charger.
        #expect(DiagnosticsSection.relevant(to: "Is Apple Intelligence on?").isEmpty)
        #expect(DiagnosticsSection.relevant(to: "Do Safari plugins slow it down?") == [.memory, .cpu])
        #expect(DiagnosticsSection.relevant(to: "Is it charging?") == [.battery])
    }

    @Test func matchesNamesAsWholeWords() {
        let question = QuestionWords("Can I quit Microsoft Outlook? And what's intelligencetasksd?")
        #expect(question.mention("Microsoft Outlook"))
        #expect(question.mention("intelligencetasksd"))
        #expect(!question.mention("Outlook Express"))
        #expect(!QuestionWords("Do I have new email?").mention("Mail"))
        #expect(QuestionWords("Claude Helper (Renderer) is busy").mention("Claude Helper (Renderer)"))
    }

    @Test func adviceComesOnlyWithItsKindOfQuestion() {
        #expect(DiagnosticsSection.notes(for: "Why is my fan so loud?").count == 1)
        #expect(DiagnosticsSection.notes(for: "Why is my Mac so slow?").count == 1)
        #expect(DiagnosticsSection.notes(for: "Why does WindowServer use so much CPU?").isEmpty)
    }

    @Test func generalQuestionsNameNoPart() {
        // The assistant answers these from the overview.
        #expect(DiagnosticsSection.relevant(to: "How is my Mac doing overall?").isEmpty)
        #expect(DiagnosticsSection.relevant(to: "What is intelligencetasksd?").isEmpty)
    }

    @Test func readsAtMostThreeParts() {
        let question = "My battery drains, the Wi-Fi drops, apps crash and the disk is full"
        #expect(DiagnosticsSection.relevant(to: question) == [.battery, .apps, .memory])
    }
}
