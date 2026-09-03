import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI smart playlist persistence")
struct SmartPlaylistAITests {
    @Test func legacyPlaylistWithoutKindDecodesAsRuleBased() throws {
        let legacy = SmartPlaylist(
            id: "legacy",
            name: "Legacy",
            rules: [
                SmartPlaylistRule(field: .genre, op: .contains, value: "Jazz")
            ]
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SmartPlaylist.self, from: data)

        #expect(decoded.kind == nil)
        #expect(decoded.aiConfiguration == nil)
        #expect(decoded.effectiveKind == .rules)
        #expect(decoded.ruleCount == 1)
    }

    @Test func aiPlaylistRoundTripsPromptHistoryAndSelections() throws {
        let first = selection(songID: "one", filePath: "/one.flac", reason: "  Warm\nopening  ")
        let duplicate = selection(songID: "other-id", filePath: "/one.flac")
        let second = selection(songID: "two", filePath: "/two.flac")
        let configuration = AISmartPlaylistConfiguration()
            .appending(prompt: "  quiet\nnight   music  ", selections: [first, duplicate])
            .appending(prompt: "add something brighter", selections: [second])
        let playlist = SmartPlaylist(
            id: "ai",
            name: "Night",
            kind: .ai,
            aiConfiguration: configuration
        )

        let data = try JSONEncoder().encode(playlist)
        let decoded = try JSONDecoder().decode(SmartPlaylist.self, from: data)

        #expect(decoded.effectiveKind == .ai)
        #expect(decoded.aiConfiguration?.prompts.map(\.text) == [
            "quiet night music",
            "add something brighter",
        ])
        #expect(decoded.aiConfiguration?.selections.map(\.identity.songID) == ["one", "two"])
        #expect(decoded.aiConfiguration?.selections.first?.reason == "Warm opening")
        #expect(decoded.aiConfiguration?.lastPrompt == "add something brighter")
    }

    private func selection(
        songID: String,
        filePath: String,
        reason: String? = nil
    ) -> AISmartPlaylistSelection {
        AISmartPlaylistSelection(
            identity: SongIdentity(
                songID: songID,
                title: songID,
                artistName: "Artist",
                duration: 180,
                cloudAccountID: "account",
                filePath: filePath
            ),
            reason: reason
        )
    }
}
