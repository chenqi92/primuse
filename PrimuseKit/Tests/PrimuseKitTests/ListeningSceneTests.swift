import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple TV home scenes")
struct ListeningSceneTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func songs(_ genre: String, _ count: Int, duration: TimeInterval = 240) -> [ListeningTestSong] {
        (0..<count).map { ListeningTestSong(id: "\(genre)-\($0)", genre: genre, duration: duration) }
    }

    private func shelf(_ library: [ListeningTestSong]) throws -> [ListeningSceneEntry] {
        let availability = try #require(ListeningIntentEngine.availability(
            songs: library,
            intents: ListeningIntentShelfPolicy.builtInCatalog + ListeningScene.intents,
            history: .empty(now: now),
            libraryGeneration: 1
        ))
        return ListeningScene.shelf(availability: availability)
    }

    @Test("Each scene is an intent of its own with a title, an icon and a rule")
    func catalog() {
        #expect(ListeningScene.intents.count == ListeningScene.allCases.count)
        for scene in ListeningScene.allCases {
            let intent = scene.intent
            #expect(intent.id == "scene:" + scene.rawValue)
            #expect(intent.source == .scene(id: scene.rawValue))
            #expect(intent.category == .scene)
            #expect(intent.titleKey == "listening_scene_" + scene.rawValue)
            #expect(scene.subtitleKey == "listening_scene_" + scene.rawValue + "_hint")
            #expect(intent.rule != nil)
            #expect(ListeningScene(intentID: intent.id) == scene)
        }
        #expect(ListeningScene(intentID: "builtin:jazz") == nil)
        #expect(ListeningScene(intentID: "scene:nope") == nil)
    }

    @Test("Night listening sets an hour's sleep timer and asks to rest; only party shuffles")
    func playback() {
        #expect(ListeningScene.night.intent.playback.sleepTimerMinutes == 60)
        #expect(ListeningScene.night.intent.playback.startsResting)
        for scene in ListeningScene.allCases where scene != .night {
            #expect(scene.intent.playback.sleepTimerMinutes == nil)
            #expect(!scene.intent.playback.startsResting)
        }
        #expect(ListeningScene.allCases.filter(\.turnsShuffleOn) == [.party])
        #expect(ListeningScene.allCases.allSatisfy { $0.intent.playback.continuesWithSimilarSongs })
    }

    @Test("Scenes pick songs by genre and length")
    func rules() {
        let history = ListeningHistoryIndex.empty(now: now)
        func matches(_ scene: ListeningScene, genre: String, duration: TimeInterval = 240) -> Bool {
            ListeningIntentEngine.matches(
                ListeningTestSong(id: "s", genre: genre, duration: duration),
                rule: scene.rule,
                families: ListeningGenreClassifier.families(for: genre),
                history: history
            )
        }
        #expect(matches(.guests, genre: "Mandopop"))
        #expect(matches(.guests, genre: "Lounge"))
        #expect(!matches(.guests, genre: "Pop Rock"))
        #expect(!matches(.guests, genre: "Pop", duration: 60))
        #expect(matches(.leisure, genre: "Bossa Nova"))
        #expect(matches(.leisure, genre: "民谣"))
        #expect(matches(.night, genre: "Classical", duration: 600))
        #expect(!matches(.night, genre: "Techno"))
        #expect(matches(.focus, genre: "Piano"))
        #expect(!matches(.focus, genre: "J-Pop"))
        #expect(matches(.party, genre: "House"))
        #expect(matches(.party, genre: "Hip-Hop"))
        #expect(!matches(.party, genre: "Ambient"))
    }

    @Test("The home row lights scenes the library has enough songs for, in a fixed order")
    func shelfLighting() throws {
        var library = songs("Pop", 30) + songs("Jazz", 20) + songs("House", 15)
        var entries = try shelf(library)
        #expect(entries.map(\.scene) == [.guests, .leisure, .night, .party])
        #expect(entries.first { $0.scene == .guests }?.songCount == 30)
        #expect(entries.first { $0.scene == .party }?.songCount == 45)
        // Jazz is gentle: it counts towards night listening too.
        #expect(entries.first { $0.scene == .night }?.songCount == 20)

        library += songs("Classical", 12, duration: 400)
        entries = try shelf(library)
        #expect(entries.map(\.scene) == ListeningScene.allCases)
        #expect(entries.count == ListeningScene.shelfLimit)

        #expect(try shelf(songs("Rock", 100)).isEmpty)
        #expect(ListeningScene.shelf(availability: nil).isEmpty)
    }
}
