import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI smart playlist persistence")
struct SmartPlaylistAITests {
    @Test func editingSceneReplacesSongsAndRoundTripsThePrompt() throws {
        let old = selection(songID: "old", filePath: "/old.flac")
        let new = selection(songID: "new", filePath: "/new.flac")
        let initial = AISmartPlaylistConfiguration(generationSongCount: 50)
            .appending(prompt: "sad", selections: [old])
        let scene = initial.replacingScene(prompt: "  sweet\nromantic music  ", selections: [new, new])
        let restored = try JSONDecoder().decode(AISmartPlaylistConfiguration.self, from: JSONEncoder().encode(scene))
        #expect(restored.isListeningScene == true)
        #expect(restored.effectiveGenerationSongCount == 50)
        #expect(restored.lastPrompt == "sweet romantic music")
        #expect(restored.selections.map(\.identity.songID) == ["new"])
        #expect(initial.selections.map(\.identity.songID) == ["old"])
    }

    @Test func olderAIPlaylistsRemainOrdinaryPlaylists() throws {
        let data = Data(#"{"prompts":[],"selections":[]}"#.utf8)
        let restored = try JSONDecoder().decode(AISmartPlaylistConfiguration.self, from: data)
        #expect(restored.isListeningScene == nil)
        #expect(restored.effectiveGenerationSongCount == 25)
        #expect(restored.appending(prompt: "more", selections: []).isListeningScene == nil)
    }

    @Test(arguments: [0, 1001])
    func outOfRangeGenerationCountUsesTheDefault(count: Int) {
        let config = AISmartPlaylistConfiguration(generationSongCount: count)
        #expect(config.effectiveGenerationSongCount == 25)
    }

    @Test func aThousandTracksCanBeEnteredInTheEditorsLocaleAndRestored() throws {
        for identifier in ["en_US", "fr_FR", "ar_EG"] {
            let locale = Locale(identifier: identifier)
            let formatted = 1000.formatted(.number.locale(locale))
            #expect(AISmartPlaylistConfiguration.generationSongCount(from: formatted, locale: locale) == 1000)
            #expect(AISmartPlaylistConfiguration.generationSongCount(from: "１０１", locale: locale) == 101)
            #expect(AISmartPlaylistConfiguration.generationSongCount(from: "1.5", locale: locale) == nil)
        }
        let selections = (0..<1000).map { selection(songID: String($0), filePath: "/\($0).flac") }
        let original = AISmartPlaylistConfiguration(selections: selections, generationSongCount: 1000)
        let decoded = try JSONDecoder().decode(AISmartPlaylistConfiguration.self, from: JSONEncoder().encode(original))
        #expect(decoded.effectiveGenerationSongCount == 1000)
        #expect(decoded.selections == selections)
    }

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
