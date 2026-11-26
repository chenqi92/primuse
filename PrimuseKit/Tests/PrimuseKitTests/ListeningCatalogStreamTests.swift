import Foundation
import Testing
@testable import PrimuseKit

/// 听歌意图的点亮、起播抽样(含整张专辑顺序)、「查看歌曲」与个人口味画像,在曲库目录上逐首算
/// 与把同一份歌按库内顺序交给数组入口算,结果相同。
@Suite("Listening intents over the library catalog")
struct ListeningCatalogStreamTests {
    private static let genres = ["Jazz", "Rock", "Pop", "华语流行", "Classical", "Electronic", "Hip-Hop", "Folk", "R&B", nil]
    private static let artists = ["Ada", "Ben", "周杰伦", "The Night", "Carla", "Duo、Trio", "Various Artists"]
    private static let albums = ["Blue Room", "Night Ferry", "夜曲", "Harbour", "Zero", "Live 1999", "Remasters"]

    private static func library(seed: UInt64) -> [Song] {
        var random = CatalogTestRandom(seed: seed)
        var songs: [Song] = []
        for index in 0..<400 {
            let album = random.chance(90) ? random.pick(albums) : nil
            let artist = random.pick(artists)
            let lossless = random.chance(50)
            var song = Song(
                id: "listen-\(seed)-\(index)",
                title: "Track \(index)",
                albumID: album.map { "album-\($0)-\(artist)" },
                artistID: "artist-\(artist)",
                albumTitle: album,
                artistName: artist,
                albumArtistName: random.chance(30) ? random.pick(artists) : nil,
                trackNumber: random.chance(85) ? random.int(1...14) : nil,
                discNumber: random.chance(15) ? 2 : 1,
                duration: random.chance(4) ? 0 : Double(random.int(60...600)),
                fileFormat: lossless ? .flac : .mp3,
                filePath: "/Music/\(random.pick(["Jazz", "Rock", "Mixed", "华语"]))/\(album ?? "Loose")/\(index).\(lossless ? "flac" : "mp3")",
                sourceID: random.pick(["src-a", "src-b"]),
                bitRate: lossless ? nil : 320,
                sampleRate: lossless ? random.pick([44_100, 96_000, 192_000]) : 44_100,
                bitDepth: lossless ? random.pick([16, 24]) : nil,
                genre: random.pick(genres),
                year: random.chance(85) ? random.int(1960...2026) : nil,
                coverArtFileName: random.chance(60) ? "cover-\(album ?? "none").jpg" : nil
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600)
            songs.append(song)
        }
        // 有声、播客、环境音:不在音乐范围里。
        var rngCopy = random
        for index in 0..<12 {
            songs.append(CatalogSongFactory.randomSong(&rngCopy, index: 10_000 + index, exotic: false))
        }
        return songs
    }

    private static func history(_ songs: [Song], seed: UInt64, now: Date) -> ListeningHistoryIndex {
        var random = CatalogTestRandom(seed: seed &* 7)
        var events: [HomeListeningEvent] = []
        for song in songs where random.chance(30) {
            for play in 0..<random.int(1...6) {
                events.append(HomeListeningEvent(
                    songID: song.id,
                    playedAt: now.addingTimeInterval(-Double(random.int(0...120)) * 86_400 - Double(play) * 3_600),
                    listenedSeconds: 200
                ))
            }
        }
        return ListeningHistoryIndex(events: events, now: now)
    }

    @Test("Streaming the catalog answers like the array entry points over the same songs", arguments: [1, 2, 3] as [UInt64])
    func catalogMatchesArrays(seed: UInt64) throws {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let catalog = try TemporaryCatalog()
        let library = Self.library(seed: seed)
        try catalog.catalog.apply(upserts: library)
        // 数组入口拿的是同一个范围里、按库内顺序的那些歌。
        var music: [Song] = []
        try catalog.catalog.forEachSong(.visibleMusic) { _, song in
            music.append(song)
            return true
        }
        #expect(music.count >= 380)
        let history = Self.history(music, seed: seed, now: now)

        let profileFromArray = try #require(ListeningProfile.build(librarySongs: music, history: history))
        let profileFromCatalog = try #require(try ListeningProfile.build(catalog: catalog.catalog, scope: .visibleMusic, history: history))
        #expect(profileFromCatalog.fingerprint == profileFromArray.fingerprint)
        let personal = PersonalListeningIntentPolicy.intents(from: profileFromArray)
        #expect(PersonalListeningIntentPolicy.intents(from: profileFromCatalog) == personal)

        let intents = personal + ListeningIntent.builtIns
        let availability = try ListeningIntentEngine.availability(
            catalog: catalog.catalog, scope: .visibleMusic, intents: intents, history: history, libraryGeneration: 3
        )
        #expect(availability == ListeningIntentEngine.availability(
            librarySongs: music, intents: intents, history: history, libraryGeneration: 3
        ))
        #expect((availability?.songCounts.count ?? 0) > 3, "enough intents light up to compare")

        var random = CatalogTestRandom(seed: seed &* 13)
        let disliked = Set(music.filter { _ in random.chance(10) }.map(\.id))
        let kept = music.filter { !disliked.contains($0.id) }
        for intent in intents {
            let seedValue = random.next()
            let fromCatalog = try ListeningIntentEngine.queueSongIDs(
                for: intent, catalog: catalog.catalog, scope: .visibleMusic, excluding: disliked,
                history: history, seed: seedValue
            )
            let fromArray = ListeningIntentEngine.queueSongIDs(for: intent, librarySongs: kept, history: history, seed: seedValue)
            #expect(fromCatalog == fromArray, "queue \(intent.id)")

            let matchingFromCatalog = try ListeningIntentEngine.matchingSongIDs(
                for: intent, catalog: catalog.catalog, scope: .visibleMusic, history: history, limit: 50
            )
            let matchingFromArray = ListeningIntentEngine.matchingSongIDs(
                for: intent, librarySongs: music, history: history, limit: 50
            )
            #expect(matchingFromCatalog?.ids == matchingFromArray?.ids && matchingFromCatalog?.total == matchingFromArray?.total,
                    "matching \(intent.id)")
        }

        // 取消:目录那条路同数组入口一样给 nil / 空。
        #expect(try ListeningIntentEngine.availability(
            catalog: catalog.catalog, scope: .visibleMusic, intents: intents, history: history, libraryGeneration: 3,
            isCancelled: { true }
        ) == nil)
        #expect(try ListeningProfile.build(catalog: catalog.catalog, scope: .visibleMusic, history: history, isCancelled: { true }) == nil)
    }

    @Test("A whole-album intent plays its albums in order from the catalog too")
    func albumSequence() throws {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let catalog = try TemporaryCatalog()
        let library = Self.library(seed: 9)
        try catalog.catalog.apply(upserts: library)
        var music: [Song] = []
        try catalog.catalog.forEachSong(.visibleMusic) { _, song in
            music.append(song)
            return true
        }
        let albumIDs = Array(Set(music.compactMap(\.albumID))).sorted().prefix(3)
        var rule = ListeningIntentRule()
        rule.albumIDs = Array(albumIDs)
        var intent = ListeningIntent.scene(id: "albums", symbolName: "square.stack", titleKey: "albums", rule: rule)
        intent.playback.playsAlbumsInSequence = true
        intent.playback.songLimit = 40
        let history = ListeningHistoryIndex(events: [], now: now)
        let fromCatalog = try ListeningIntentEngine.queueSongIDs(
            for: intent, catalog: catalog.catalog, scope: .visibleMusic, history: history, seed: 1
        )
        #expect(!fromCatalog.isEmpty)
        #expect(fromCatalog == ListeningIntentEngine.queueSongIDs(for: intent, librarySongs: music, history: history, seed: 1))
    }
}
