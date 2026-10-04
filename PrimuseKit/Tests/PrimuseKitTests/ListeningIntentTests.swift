import Foundation
import Testing
@testable import PrimuseKit

/// A song as the listening features see it.
struct ListeningTestSong: ListeningSongTraits {
    var id: String
    var albumID: String?
    var albumTitle: String?
    var artistName: String?
    var albumArtistName: String?
    var genre: String?
    var year: Int?
    var duration: TimeInterval = 240
    var dateAdded: Date = Date(timeIntervalSince1970: 1_700_000_000)
    var trackNumber: Int?
    var discNumber: Int?
    var cueSheetPath: String?
    var coverArtFileName: String?
    var isPlayable: Bool = true
}

@Suite("Listening intents")
struct ListeningIntentTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Genre tags fall into families in several languages")
    func classifier() {
        #expect(ListeningGenreClassifier.families(for: "J-Pop") == [.pop])
        #expect(ListeningGenreClassifier.families(for: "华语流行") == [.pop])
        #expect(ListeningGenreClassifier.families(for: "Pop Rock") == [.pop, .rock])
        #expect(ListeningGenreClassifier.families(for: "Hip-Hop/Rap") == [.hipHop])
        #expect(ListeningGenreClassifier.families(for: "Drum & Bass") == [.electronic])
        #expect(ListeningGenreClassifier.families(for: "Electronica") == [.electronic])
        #expect(ListeningGenreClassifier.families(for: "Original Soundtrack") == [.soundtrack])
        #expect(ListeningGenreClassifier.families(for: "影视原声") == [.soundtrack])
        #expect(ListeningGenreClassifier.families(for: "New Age") == [.easyListening])
        #expect(ListeningGenreClassifier.families(for: "輕音樂") == [.easyListening])
        #expect(ListeningGenreClassifier.families(for: "民谣") == [.folk])
        #expect(ListeningGenreClassifier.families(for: "Música Clásica").isEmpty)
        #expect(ListeningGenreClassifier.families(for: "Classical") == [.classical])
    }

    @Test("Short Latin words only match whole words")
    func wholeWords() {
        // "ost" must not light up soundtracks for post-rock, "rap" not for "trapeze".
        #expect(ListeningGenreClassifier.families(for: "Post-Rock") == [.rock])
        #expect(!ListeningGenreClassifier.families(for: "Trapeze Artists").contains(.hipHop))
        #expect(ListeningGenreClassifier.families(for: nil).isEmpty)
        #expect(ListeningGenreClassifier.families(for: "   ").isEmpty)
    }

    @Test("Every built-in has a title key, an icon and — except resume — a rule")
    func catalog() {
        #expect(ListeningIntent.builtIns.count == BuiltInListeningIntent.allCases.count)
        #expect(Set(ListeningIntent.builtIns.map(\.id)).count == ListeningIntent.builtIns.count)
        for intent in ListeningIntent.builtIns {
            #expect(intent.titleKey?.hasPrefix("listening_intent_") == true)
            #expect(!intent.symbolName.isEmpty)
            if intent.habit == .resume {
                #expect(intent.rule == nil)
            } else {
                #expect(intent.rule != nil)
            }
        }
        #expect(ListeningIntent.builtIn(.nineties).rule?.years == 1990...1999)
        #expect(ListeningIntent.pinnedSmartPlaylist(id: "p1").source == .smartPlaylist(id: "p1"))
    }

    @Test("Intents round-trip through JSON")
    func codable() throws {
        let scene = ListeningIntent.scene(
            id: "night",
            symbolName: "moon",
            titleKey: "tv_scene_night",
            rule: ListeningIntentRule(genreFamilies: [.jazz, .easyListening], duration: 120...600),
            playback: ListeningIntentPlayback(sleepTimerMinutes: 60, startsResting: true)
        )
        let data = try JSONEncoder().encode([scene, .builtIn(.calm)])
        let decoded = try JSONDecoder().decode([ListeningIntent].self, from: data)
        #expect(decoded == [scene, .builtIn(.calm)])
    }

    @Test("Rules check genre, era, length and history")
    func matching() {
        let history = ListeningHistoryIndex(events: [], now: now)
        let jazz = ListeningTestSong(id: "1", genre: "Jazz", year: 1995, duration: 300)
        let rock = ListeningTestSong(id: "2", genre: "Rock", year: 2015, duration: 200)
        let bedtime = BuiltInListeningIntent.bedtime.rule!
        #expect(ListeningIntentEngine.matches(jazz, rule: bedtime, families: [.jazz], history: history))
        #expect(!ListeningIntentEngine.matches(rock, rule: bedtime, families: [.rock], history: history))
        let nineties = BuiltInListeningIntent.nineties.rule!
        #expect(ListeningIntentEngine.matches(jazz, rule: nineties, families: [.jazz], history: history))
        #expect(!ListeningIntentEngine.matches(rock, rule: nineties, families: [.rock], history: history))
        var unplayable = jazz
        unplayable.isPlayable = false
        #expect(!ListeningIntentEngine.matches(unplayable, rule: ListeningIntentRule(), families: [], history: history))
    }

    @Test("Long unplayed needs a real history and skips what was heard lately")
    func longUnplayed() {
        let rule = BuiltInListeningIntent.longUnplayed.rule!
        let song = ListeningTestSong(id: "old")
        let heard = ListeningTestSong(id: "heard")
        #expect(!ListeningIntentEngine.matches(song, rule: rule, families: [], history: .empty(now: now)))
        var events = (0..<40).map {
            HomeListeningEvent(songID: "filler\($0)", playedAt: now.addingTimeInterval(-Double($0) * 3_600), listenedSeconds: 200)
        }
        events.append(HomeListeningEvent(songID: "heard", playedAt: now.addingTimeInterval(-86_400), listenedSeconds: 200))
        let history = ListeningHistoryIndex(events: events, now: now)
        #expect(ListeningIntentEngine.matches(song, rule: rule, families: [], history: history))
        #expect(!ListeningIntentEngine.matches(heard, rule: rule, families: [], history: history))
    }

    @Test("Lighting counts songs per intent and only lights intents with enough of them")
    func availability() throws {
        var songs: [ListeningTestSong] = []
        for index in 0..<20 { songs.append(ListeningTestSong(id: "j\(index)", genre: "Jazz", year: 1992)) }
        for index in 0..<5 { songs.append(ListeningTestSong(id: "r\(index)", genre: "Rock", year: 2012)) }
        let availability = try #require(ListeningIntentEngine.availability(
            songs: songs,
            intents: ListeningIntent.builtIns,
            history: .empty(now: now),
            libraryGeneration: 7
        ))
        #expect(availability.songCount(for: .builtIn(.jazz)) == 20)
        #expect(availability.songCount(for: .builtIn(.rock)) == 5)
        #expect(availability.isLit(.builtIn(.jazz)))
        #expect(!availability.isLit(.builtIn(.rock)))
        #expect(!availability.isLit(.builtIn(.resume)))
        let lit = availability.litIntents(ListeningIntent.builtIns)
        #expect(lit.first == .builtIn(.anything))
        #expect(lit.contains(.builtIn(.nineties)))
        #expect(!lit.contains(.builtIn(.twentyTens)))
        #expect(availability.libraryGeneration == 7)
    }

    @Test("Each intent gets covers from up to three different albums, the same all day")
    func coverSamples() throws {
        var songs: [ListeningTestSong] = []
        for album in 0..<6 {
            for track in 0..<4 {
                songs.append(ListeningTestSong(
                    id: "j\(album)-\(track)", albumID: "a\(album)", genre: "Jazz", coverArtFileName: "c\(album)"
                ))
            }
        }
        for index in 0..<20 { songs.append(ListeningTestSong(id: "r\(index)", albumID: "rock", genre: "Rock")) }
        func covers(at date: Date, _ songs: [ListeningTestSong]) throws -> [String] {
            let availability = try #require(ListeningIntentEngine.availability(
                songs: songs,
                intents: ListeningIntent.builtIns,
                history: .empty(now: date),
                libraryGeneration: 1
            ))
            #expect(availability.coverSongIDs(for: .builtIn(.rock)).isEmpty)
            return availability.coverSongIDs(for: .builtIn(.jazz))
        }
        let jazz = try covers(at: now, songs)
        #expect(jazz.count == ListeningIntentEngine.coverSampleLimit)
        let albums = jazz.compactMap { id in songs.first { $0.id == id }?.albumID }
        #expect(Set(albums).count == jazz.count)
        // Same day, other library order: the same albums.
        let reordered = try covers(at: now.addingTimeInterval(3_600), Array(songs.reversed()))
        let reorderedAlbums = reordered.compactMap { id in songs.first { $0.id == id }?.albumID }
        #expect(reorderedAlbums == albums)
    }

    @Test("Lighting is cancellable")
    func availabilityCancels() {
        let songs = (0..<5_000).map { ListeningTestSong(id: "s\($0)", genre: "Pop") }
        let result = ListeningIntentEngine.availability(
            songs: songs, intents: ListeningIntent.builtIns, history: .empty(now: now),
            libraryGeneration: 1, isCancelled: { true }
        )
        #expect(result == nil)
    }

    @Test("Lighting refreshes once the library moved on and the last pass is old enough")
    func refreshCadence() {
        let last = ListeningIntentAvailability(songCounts: [:], libraryGeneration: 3, computedAt: now)
        #expect(ListeningIntentEngine.shouldRefresh(last: nil, libraryGeneration: 3, now: now))
        #expect(!ListeningIntentEngine.shouldRefresh(last: last, libraryGeneration: 3, now: now.addingTimeInterval(9_999)))
        #expect(!ListeningIntentEngine.shouldRefresh(last: last, libraryGeneration: 4, now: now.addingTimeInterval(60)))
        #expect(ListeningIntentEngine.shouldRefresh(last: last, libraryGeneration: 4, now: now.addingTimeInterval(301)))
    }

    @Test("An intent's queue is a bounded, seed-stable sample of matching songs")
    func queue() {
        var songs: [ListeningTestSong] = []
        for index in 0..<300 { songs.append(ListeningTestSong(id: "j\(index)", genre: "Jazz")) }
        for index in 0..<300 { songs.append(ListeningTestSong(id: "p\(index)", genre: "Pop")) }
        let intent = ListeningIntent.builtIn(.jazz)
        let first = ListeningIntentEngine.queueSongIDs(for: intent, songs: songs, history: .empty(now: now), seed: 42)
        let again = ListeningIntentEngine.queueSongIDs(for: intent, songs: songs, history: .empty(now: now), seed: 42)
        let other = ListeningIntentEngine.queueSongIDs(for: intent, songs: songs, history: .empty(now: now), seed: 43)
        #expect(first.count == 50)
        #expect(Set(first).count == 50)
        #expect(first.allSatisfy { $0.hasPrefix("j") })
        #expect(first == again)
        #expect(first != other)
        #expect(ListeningIntentEngine.queueSongIDs(for: .builtIn(.resume), songs: songs, history: .empty(now: now), seed: 1).isEmpty)
    }

    @Test("Long unplayed queues the never-heard and longest-unheard songs first")
    func longUnplayedQueue() {
        var events = (0..<60).map {
            HomeListeningEvent(songID: "s\($0)", playedAt: now.addingTimeInterval(-Double(100 + $0) * 86_400), listenedSeconds: 200)
        }
        events.append(HomeListeningEvent(songID: "recent", playedAt: now.addingTimeInterval(-3_600), listenedSeconds: 200))
        let history = ListeningHistoryIndex(events: events, now: now)
        var songs = (0..<60).map { ListeningTestSong(id: "s\($0)") }
        songs.append(ListeningTestSong(id: "never"))
        songs.append(ListeningTestSong(id: "recent"))
        var intent = ListeningIntent.builtIn(.longUnplayed)
        intent.playback.songLimit = 5
        let ids = ListeningIntentEngine.queueSongIDs(for: intent, songs: songs, history: history, seed: 9)
        #expect(ids == ["never", "s59", "s58", "s57", "s56"])
    }

    @Test("The seeded generator is deterministic")
    func seededGenerator() {
        var a = ListeningSeededGenerator(seed: ListeningSeededGenerator.seed("2026-10-01"))
        var b = ListeningSeededGenerator(seed: ListeningSeededGenerator.seed("2026-10-01"))
        #expect(a.next() == b.next())
        let noise = ListeningSeededGenerator.unitNoise("album|day")
        #expect(noise >= 0 && noise < 1)
        #expect(noise == ListeningSeededGenerator.unitNoise("album|day"))
    }
}
