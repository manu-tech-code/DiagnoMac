import Foundation
import Testing
@testable import DiagnoCore

@Suite struct ReleaseNotesTests {
    @Test func gitHubGeneratedNotes() {
        let body = """
        <!-- Release notes generated using configuration in .github/release.yml at v0.2.0 -->

        ## What's Changed
        ### Features
        * Update checks, with a timeline of what's new by @manu-tech-code in https://github.com/manu-tech-code/DiagnoMac/pull/3
        ### Fixes
        * The speed test shows its progress; version 0.2.1 by @manu-tech-code in https://github.com/manu-tech-code/DiagnoMac/pull/5
        ### Chores
        * Version 0.2.0 (build 2) by @manu-tech-code in https://github.com/manu-tech-code/DiagnoMac/pull/4


        **Full Changelog**: https://github.com/manu-tech-code/DiagnoMac/compare/v0.1.0...v0.2.0
        """
        let n = ReleaseNotes.parseBody(body)
        #expect(n.summary == nil)
        #expect(n.sections == [
            .init(title: "New", items: ["Update checks, with a timeline of what's new"]),
            .init(title: "Fixes", items: ["The speed test shows its progress"]),
        ]) // the version bump on its own isn't news, so "Improvements" is empty and dropped
    }

    @Test func summaryBeforeGeneratedNotes() {
        let body = """
        The first release: a health score with fixes, an on-device assistant, and live CPU, GPU and battery readings.

        <!-- Release notes generated using configuration in .github/release.yml at v0.1.0 -->

        ## What's Changed
        ### Chores
        * Far less CPU, memory and battery while open by @manu-tech-code in https://github.com/manu-tech-code/DiagnoMac/pull/2
        """
        let n = ReleaseNotes.parseBody(body)
        #expect(n.summary == "The first release: a health score with fixes, an on-device assistant, and live CPU, GPU and battery readings.")
        #expect(n.sections == [.init(title: "Improvements", items: ["Far less CPU, memory and battery while open"])])
    }

    @Test func handWrittenNotes() {
        let body = """
        A faster scan and clearer findings.

        ### Battery
        - **Charging**: the power flow shows where the charger's watts go
        - A charge log, with the [charger](https://example.com) and peak power

        ### Install
        Open `DiagnoMac-0.3.0.dmg` and drag it to Applications.
        """
        let n = ReleaseNotes.parseBody(body)
        #expect(n.summary == "A faster scan and clearer findings.")
        #expect(n.sections.map(\.title) == ["Battery"]) // "Install" has no bullets
        #expect(n.sections[0].items == ["Charging: the power flow shows where the charger's watts go",
                                        "A charge log, with the charger and peak power"])
    }

    @Test func gitHubReleasesNewestFirstWithoutDraftsOrOddTags() {
        let json = #"""
        [
          {"tag_name":"v0.7.0","draft":false,"prerelease":false,"published_at":"2026-10-01T09:58:08Z","body":"### Features\n* Reveal animations by @a in https://x.y/pull/18"},
          {"tag_name":"v0.10.0","draft":false,"prerelease":false,"published_at":"2026-12-01T10:00:00Z","body":"### Fixes\n* A fix by @a in https://x.y/pull/30"},
          {"tag_name":"v0.8.0","draft":true,"prerelease":false,"published_at":null,"body":""},
          {"tag_name":"v0.9.0-beta","draft":false,"prerelease":true,"published_at":"2026-11-01T10:00:00Z","body":""},
          {"tag_name":"v0.4.0-installer","draft":false,"prerelease":false,"published_at":"2026-09-30T22:00:00Z","body":""}
        ]
        """#
        let notes = ReleaseNotes.parseGitHubReleases(Data(json.utf8))
        // Newest first by number (0.10 after 0.9), no draft, no pre-release, no odd tag.
        #expect(notes.map(\.version) == ["0.10.0", "0.7.0"])
        #expect(notes.first?.sections.first?.items == ["A fix"])
        #expect(notes.first?.date != nil)
    }

    @Test func comparesVersionsNumerically() {
        #expect(ReleaseNotes.isNewer("0.10.0", than: "0.9.2"))
        #expect(ReleaseNotes.isNewer("0.7.1", than: "0.7"))
        #expect(!ReleaseNotes.isNewer("0.7.0", than: "0.7"))
        #expect(!ReleaseNotes.isNewer("0.6.9", than: "0.7.0"))
    }
}
