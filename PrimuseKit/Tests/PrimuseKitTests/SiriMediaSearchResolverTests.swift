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

    @Test("A namespaced Spotlight song identifier resolves to the exact selection")
    func namespacedResolvedIdentifierWins() throws {
        let first = song(id: "first", title: "Intro", artist: "Band")
        let selected = song(id: "selected", title: "Intro", artist: "Band")

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .song),
            resolvedItemIDs: ["song:stale", "song:selected"],
            songs: [first, selected]
        ))

        #expect(result.queue.map(\.id) == ["selected"])
        #expect(!result.needsDisambiguation)
    }

    @Test("Multiple resolved media items preserve the requested queue order")
    func multipleResolvedSongsPreserveOrder() throws {
        let first = song(id: "first", title: "First")
        let second = song(id: "second", title: "Second")

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .song),
            resolvedItemIDs: ["song:second", "song:first"],
            songs: [first, second]
        ))

        #expect(result.queue.map(\.id) == ["second", "first"])
    }

    @Test("An unresolved typed selection never falls back to text or the full library")
    func unresolvedTypedIdentifierFailsClosed() {
        let fallback = song(id: "fallback", title: "Intro", artist: "Band")

        let result = SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .song, mediaName: "Intro"),
            resolvedItemIDs: ["playlist:not-a-song"],
            songs: [fallback]
        )

        #expect(result == nil)
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

    @Test("A selected album identifier cannot drift to a same-name album")
    func selectedAlbumIdentifierWins() throws {
        var wanted = song(id: "wanted", title: "A", artist: "One", album: "Greatest Hits")
        wanted.albumID = "wanted-album"
        var other = song(id: "other", title: "B", artist: "Two", album: "Greatest Hits")
        other.albumID = "other-album"

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .album, mediaName: "Greatest Hits"),
            resolvedItemIDs: ["album:stale", "album:wanted-album"],
            songs: [other, wanted]
        ))

        #expect(result.queue.map(\.id) == ["wanted"])
    }

    @Test("A selected artist identifier builds only that artist queue")
    func selectedArtistIdentifierWins() throws {
        var wanted = song(id: "wanted", title: "A", artist: "Same Name")
        wanted.artistID = "wanted-artist"
        var other = song(id: "other", title: "B", artist: "Same Name")
        other.artistID = "other-artist"

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .artist, mediaName: "Same Name"),
            resolvedItemIDs: ["artist:wanted-artist"],
            songs: [other, wanted]
        ))

        #expect(result.queue.map(\.id) == ["wanted"])
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

    @Test("Genre requests build a queue containing only matching songs")
    func genreRequest() throws {
        var rock = song(id: "rock", title: "Guitar")
        rock.genre = "Alternative Rock"
        var jazz = song(id: "jazz", title: "Saxophone")
        jazz.genre = "Jazz"

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .genre, genreNames: ["rock"]),
            songs: [jazz, rock]
        ))

        #expect(result.queue.map(\.id) == ["rock"])
    }

    @Test("A selected genre identifier resolves exactly and ignores stale fallbacks")
    func selectedGenreIdentifierWins() throws {
        var rock = song(id: "rock", title: "Guitar")
        rock.genre = "Alternative Rock"
        var jazz = song(id: "jazz", title: "Saxophone")
        jazz.genre = "Jazz"

        let result = try #require(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .genre),
            resolvedItemIDs: ["genre:missing", "genre:Alternative Rock"],
            songs: [jazz, rock]
        ))

        #expect(result.queue.map(\.id) == ["rock"])
    }

    @Test("Named media resolution honors a selected station identifier")
    func selectedNamedMediaIdentifierWins() throws {
        let stations = [
            SiriNamedMediaItem(id: "news", name: "News Radio"),
            SiriNamedMediaItem(id: "jazz", name: "Jazz Radio"),
        ]

        let result = try #require(SiriNamedMediaResolver.resolve(
            query: nil,
            selectedItemIDs: ["station:missing", "station:jazz"],
            namespace: "radio",
            items: stations
        ))

        #expect(result.selected.id == "jazz")
        #expect(result.candidates == [stations[1]])
    }

    @Test("Named media exact matches rank before prefixes")
    func namedMediaExactMatchWins() throws {
        let playlists = [
            SiriNamedMediaItem(id: "live", name: "Road Trip Live"),
            SiriNamedMediaItem(id: "exact", name: "Road Trip"),
        ]

        let result = try #require(SiriNamedMediaResolver.resolve(
            query: "Road Trip",
            namespace: "playlist",
            items: playlists
        ))

        #expect(result.selected.id == "exact")
        #expect(!result.needsDisambiguation)
    }

    @Test("Resolved media item identifiers take priority with search and container fallbacks")
    func identifierFallbackOrder() {
        let identifiers = SiriMediaIdentifier.prioritized(
            mediaItemIdentifier: " song:selected ",
            searchIdentifier: "song:search",
            containerIdentifier: "album:container"
        )

        #expect(identifiers == ["song:selected", "song:search", "album:container"])
    }

    @Test("All resolved media items precede search and container fallbacks")
    func multipleIdentifierFallbackOrder() {
        let identifiers = SiriMediaIdentifier.prioritized(
            mediaItemIdentifiers: ["song:first", "song:second"],
            searchIdentifier: "song:search",
            containerIdentifier: "album:container"
        )

        #expect(identifiers == [
            "song:first", "song:second", "song:search", "album:container",
        ])
    }

    @Test("Resolved items remain separate from search and container fallback tiers")
    func identifierFallbackGroups() {
        let groups = SiriMediaIdentifier.prioritizedGroups(
            mediaItemIdentifiers: ["song:first", "song:second"],
            searchIdentifier: "song:search",
            containerIdentifier: "album:container"
        )

        #expect(groups == [
            ["song:first", "song:second"],
            ["song:search"],
            ["album:container"],
        ])
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
