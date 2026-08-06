import Testing
@testable import PrimuseKit

@Suite("Siri media search resolver")
struct SiriMediaSearchResolverTests {
    @Test("Exact song title ranks ahead of longer variants")
    func exactSongWins() throws {
        let exact = song(id: "exact", title: "晴天", artist: "周杰伦")
        let live = song(id: "live", title: "晴天 Live", artist: "周杰伦")

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .song, mediaName: "晴天"),
            songs: [live, exact]
        ))

        #expect(result.queue.map(\.id) == ["exact"])
        #expect(result.candidates.map(\.id) == ["exact", "live"])
        #expect(!result.needsDisambiguation)
    }

    @Test("Artist constraint disambiguates songs with the same title")
    func artistConstraint() throws {
        let first = song(id: "first", title: "唯一", artist: "王力宏")
        let second = song(id: "second", title: "唯一", artist: "告五人")

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(
                kind: .song,
                mediaName: "唯一",
                artistName: "告五人"
            ),
            songs: [first, second]
        ))

        #expect(result.queue.map(\.id) == ["second"])
        #expect(!result.needsDisambiguation)
    }

    @Test("Equally ranked song versions require disambiguation")
    func duplicateTitlesRequireDisambiguation() throws {
        let studio = song(id: "studio", title: "Intro", artist: "Band", album: "Studio")
        let deluxe = song(id: "deluxe", title: "Intro", artist: "Band", album: "Deluxe")

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .song, mediaName: "Intro", artistName: "Band"),
            songs: [studio, deluxe]
        ))

        #expect(result.needsDisambiguation)
        #expect(Set(result.candidates.map(\.id)) == ["studio", "deluxe"])
    }

    @Test("A resolved Siri media identifier overrides fuzzy ranking")
    func resolvedIdentifierWins() throws {
        let first = song(id: "first", title: "Intro", artist: "Band")
        let second = song(id: "second", title: "Intro Live", artist: "Band")

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .song, mediaName: "Intro"),
            resolvedItemIDs: ["second"],
            songs: [first, second]
        ))

        #expect(result.queue.map(\.id) == ["second"])
    }

    @Test("Album playback keeps disc and track order")
    func albumOrdering() throws {
        let tracks = [
            song(id: "d2t1", title: "C", album: "合集", track: 1, disc: 2),
            song(id: "d1t2", title: "B", album: "合集", track: 2, disc: 1),
            song(id: "d1t1", title: "A", album: "合集", track: 1, disc: 1),
        ]

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .album, mediaName: "合集"),
            songs: tracks
        ))

        #expect(result.queue.map(\.id) == ["d1t1", "d1t2", "d2t1"])
    }

    @Test("Pinyin metadata can match a spoken Latin query")
    func pinyinMatch() throws {
        var qingtian = song(id: "qingtian", title: "晴天", artist: "周杰伦")
        qingtian.titlePinyin = "qing tian"

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .song, mediaName: "qing tian"),
            songs: [qingtian]
        ))

        #expect(result.queue.map(\.id) == ["qingtian"])
    }

    @Test("Play music without a name returns the playable library")
    func genericMusicRequest() throws {
        let playable = song(id: "playable", title: "Song")
        let unavailable = Song(
            id: "unavailable",
            title: "Unavailable",
            fileFormat: .mp3,
            filePath: "",
            sourceID: "source"
        )

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .music),
            songs: [unavailable, playable]
        ))

        #expect(result.queue.map(\.id) == ["playable"])
        #expect(result.candidates.isEmpty)
    }

    private func song(
        id: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        track: Int? = nil,
        disc: Int? = nil
    ) -> Song {
        Song(
            id: id,
            title: title,
            albumID: album.map { "album:\($0)" },
            artistID: artist.map { "artist:\($0)" },
            albumTitle: album,
            artistName: artist,
            trackNumber: track,
            discNumber: disc,
            fileFormat: .flac,
            filePath: "/\(id).flac",
            sourceID: "source"
        )
    }
}
