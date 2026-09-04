import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class ArtistNameLibraryTests: XCTestCase {
    func testCatalogSearchFindsAlbumWithoutMatchingSongs() {
        let album = Album(id: "album", title: "独立专辑名称", artistName: "Artist")
        let result = SearchCatalogPolicy.albums(
            query: "独立专辑",
            visibleAlbums: [album],
            relatedAlbums: []
        )
        XCTAssertEqual(result.map(\.id), [album.id])
    }

    func testCatalogSearchPrioritizesDirectMatchesAndDeduplicatesRelatedAlbums() {
        let direct = Album(id: "direct", title: "Moonlight", artistName: "Artist")
        let related = Album(id: "related", title: "Other", artistName: "Artist")
        let hidden = Album(id: "hidden", title: "Hidden source")
        let result = SearchCatalogPolicy.albums(
            query: "moonlight",
            visibleAlbums: [related, direct],
            relatedAlbums: [related, direct, related, hidden]
        )
        XCTAssertEqual(result.map(\.id), [direct.id, related.id])
    }

    func testCatalogSearchKeepsAllArtistAlbumMatches() {
        let albums = (0..<24).map {
            Album(id: "album-\($0)", title: "Release \($0)", artistName: "Artist")
        }
        let result = SearchCatalogPolicy.albums(
            query: "artist",
            visibleAlbums: albums,
            relatedAlbums: []
        )
        XCTAssertEqual(Set(result.map(\.id)), Set(albums.map(\.id)))
    }

    func testCatalogSearchDoesNotReturnRelatedAlbumsForBlankQuery() {
        let album = Album(id: "album", title: "Album")
        XCTAssertTrue(SearchCatalogPolicy.albums(
            query: " \n ",
            visibleAlbums: [album],
            relatedAlbums: [album]
        ).isEmpty)
    }

    func testTextArtistsJoinOneAlbumButCreateContributorEntries() throws {
        let song = makeSong(
            artistName: "Host; Guest",
            albumArtistName: "Host",
            albumTitle: "Collaboration"
        )

        let result = MusicLibrary.computeAlbumsAndArtists(songs: [song])
        let host = try XCTUnwrap(result.artists.first { $0.name == "Host" })
        let guest = try XCTUnwrap(result.artists.first { $0.name == "Guest" })

        XCTAssertEqual(result.albums.count, 1)
        XCTAssertEqual(result.albums.first?.artistName, "Host")
        XCTAssertEqual(host.songCount, 1)
        XCTAssertEqual(host.albumCount, 1)
        XCTAssertEqual(guest.songCount, 1)
        XCTAssertEqual(guest.albumCount, 0)
    }

    func testProtectedNamePreventsConfiguredSymbolFromSplittingArtist() {
        let configuration = ArtistNameConfiguration(
            separators: ["/", ";"],
            protectedNames: ["AC/DC"],
            displaySeparator: " / "
        )
        let song = makeSong(artistName: "AC/DC; Guest")

        let result = MusicLibrary.computeAlbumsAndArtists(
            songs: [song],
            configuration: configuration
        )

        XCTAssertEqual(Set(result.artists.map(\.name)), ["AC/DC", "Guest"])
    }

    func testNativeArtistArrayIsAuthoritativeEvenWhenNamesContainSeparators() {
        let configuration = ArtistNameConfiguration(
            separators: ["/", "&", ";"],
            protectedNames: [],
            displaySeparator: " + "
        )
        let song = makeSong(
            artistName: "AC/DC & Simon & Garfunkel",
            sourceArtistNames: ["AC/DC", "Simon & Garfunkel"]
        )

        let result = MusicLibrary.computeAlbumsAndArtists(
            songs: [song],
            configuration: configuration
        )

        XCTAssertEqual(Set(result.artists.map(\.name)), ["AC/DC", "Simon & Garfunkel"])
    }

    func testCaseVariantsCollapseIntoOneStableArtist() throws {
        let first = makeSong(artistName: "Artist")
        let second = makeSong(artistName: "ARTIST")

        let result = MusicLibrary.computeAlbumsAndArtists(songs: [first, second])
        let artist = try XCTUnwrap(result.artists.first)

        XCTAssertEqual(result.artists.count, 1)
        XCTAssertEqual(artist.id, MusicLibrary.hashID("artist"))
        XCTAssertEqual(artist.name, "Artist")
        XCTAssertEqual(artist.songCount, 2)
    }

    @MainActor
    func testArtistSongLookupIncludesContributorsAndTracksVisibility() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistSongLookupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(
            storageDirectory: storageDirectory,
            artistNameConfiguration: .defaultValue
        )
        let duet = makeSong(
            id: "duet",
            artistName: "Host; Guest",
            sourceArtistNames: ["Host", "Guest"],
            sourceID: "source-a"
        )
        let solo = makeSong(
            id: "solo",
            artistName: "Guest",
            sourceID: "source-b"
        )
        let legacyNativeValue = makeSong(
            id: "legacy-native-value",
            artistName: " ",
            sourceArtistNames: ["Guest; Legacy"],
            sourceID: "source-c"
        )
        library.addSongs(
            [duet, solo, legacyNativeValue],
            affectedSourceIDs: [duet.sourceID, solo.sourceID, legacyNativeValue.sourceID]
        )

        let guestID = MusicLibrary.hashID("guest")
        for _ in 0..<200 where library.songs(forArtist: guestID).count != 3 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let expectedGuestSongIDs = ["duet", "solo", "legacy-native-value"]
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)

        let guestOwner = LibraryArtworkOwner(kind: .artist, id: guestID)
        XCTAssertTrue(library.setArtwork(for: guestOwner, to: duet))
        let artworkPresentation = library.artworkPresentation(for: guestOwner)
        XCTAssertEqual(artworkPresentation.resolution, .selectedSong(duet.id))
        XCTAssertEqual(artworkPresentation.selectedSong?.id, duet.id)

        library.updateDisabledSourceIDs([duet.sourceID])
        XCTAssertEqual(
            library.songs(forArtist: guestID).map(\.id),
            ["solo", "legacy-native-value"]
        )

        library.updateDisabledSourceIDs([])
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)
        _ = await library.persistNowAndWait()
    }

    func testMetadataSearchFindsSecondaryNativeArtist() {
        let song = makeSong(
            artistName: "Primary & Secondary",
            sourceArtistNames: ["Primary", "Secondary"]
        )

        let result = LibrarySearchWorker.compute(
            query: "Secondary",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertEqual(result.songResults.map(\.song.id), [song.id])
        XCTAssertEqual(result.songResults.first?.matchKind, .metadata)
    }

    func testKeywordSearchFindsAUserVisibleRelativePath() {
        let song = makeSong(
            artistName: "Artist",
            filePath: "Archive/Live Sessions/Track.flac"
        )

        let result = LibrarySearchWorker.compute(
            query: "Live Sessions",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertEqual(result.songResults.map(\.song.id), [song.id])
        XCTAssertEqual(result.songResults.first?.matchKind, .path)
    }

    func testKeywordSearchDoesNotMatchAnAppleMusicPath() {
        let song = makeSong(
            artistName: "Artist",
            sourceID: AppleMusicLibraryIdentity.sourceID,
            filePath: "/PrivateFolder/Track.m4a"
        )

        let result = LibrarySearchWorker.compute(
            query: "PrivateFolder",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertTrue(result.songResults.isEmpty)
    }

    @MainActor
    func testSmartPlaylistArtistRulesEvaluateEveryContributor() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistNameSmartPlaylistTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let song = makeSong(
            artistName: "Host; Guest",
            sourceArtistNames: ["Host", "Guest"]
        )
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        for _ in 0..<100 where library.visibleSongs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.map(\.id), [song.id])

        let includesGuest = SmartPlaylist(
            name: "Guest",
            rules: [SmartPlaylistRule(field: .artistName, op: .equals, value: "Guest")]
        )
        let excludesGuest = SmartPlaylist(
            name: "Not Guest",
            rules: [SmartPlaylistRule(field: .artistName, op: .notContains, value: "Guest")]
        )

        XCTAssertEqual(
            SmartPlaylistEngine.match(includesGuest, in: library, history: .shared).map(\.id),
            [song.id]
        )
        XCTAssertTrue(
            SmartPlaylistEngine.match(excludesGuest, in: library, history: .shared).isEmpty
        )
        _ = await library.persistNowAndWait()
    }

    private func makeSong(
        id: String = UUID().uuidString,
        artistName: String,
        sourceArtistNames: [String]? = nil,
        albumArtistName: String? = nil,
        albumTitle: String? = nil,
        sourceID: String = "source",
        filePath: String = "/track.flac"
    ) -> Song {
        Song(
            id: id,
            title: "Track",
            albumTitle: albumTitle,
            artistName: artistName,
            sourceArtistNames: sourceArtistNames,
            albumArtistName: albumArtistName,
            duration: 180,
            fileFormat: .flac,
            filePath: filePath,
            sourceID: sourceID
        )
    }
}

final class MusicDiscoveryRecommendationTests: XCTestCase {
    func testDailyRecommendationsFillFromOtherArtistsBeforeRepeatingOneArtist() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-120 * 24 * 60 * 60)
        let dominant = (0..<8).map { index in
            makeSong(
                id: "artist-a-\(index)",
                artist: "Artist A",
                album: "Album A",
                dateAdded: oldDate
            )
        }
        let alternatives = ["Artist B", "Artist C", "Artist D"].flatMap { artist in
            (0..<2).map { index in
                makeSong(
                    id: "\(artist)-\(index)",
                    artist: artist,
                    album: "\(artist) Album",
                    dateAdded: oldDate
                )
            }
        }
        let songs = dominant + alternatives
        let input = MusicDiscoveryEngine.RecommendationInput(
            songs: songs,
            recentWeekIDs: [],
            recentMonthIDs: [],
            topArtists: ["artist a"],
            seedIDs: ["artist-a-0"],
            now: now
        )

        let recommendations = MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 8)
        let artistCounts = Dictionary(
            grouping: recommendations,
            by: { $0.song.artistName ?? "" }
        ).mapValues(\.count)

        XCTAssertEqual(recommendations.count, 8)
        XCTAssertEqual(artistCounts.count, 4)
        XCTAssertLessThanOrEqual(artistCounts.values.max() ?? 0, 2)
    }

    private func makeSong(
        id: String,
        artist: String,
        album: String,
        dateAdded: Date
    ) -> Song {
        Song(
            id: id,
            title: id,
            albumID: album,
            artistID: artist,
            albumTitle: album,
            artistName: artist,
            duration: 180,
            fileFormat: .flac,
            filePath: "/\(id).flac",
            sourceID: "source",
            dateAdded: dateAdded
        )
    }
}

@MainActor
final class ArtistNameSettingsStoreTests: XCTestCase {
    func testUnsupportedFutureConfigurationIsPreservedUntilUserEdits() throws {
        let suiteName = "ArtistNameSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let future = ArtistNameConfiguration(
            schemaVersion: ArtistNameConfiguration.currentSchemaVersion + 1,
            separators: ["|"],
            protectedNames: ["Future Artist"],
            displaySeparator: " + "
        )
        let futureData = try JSONEncoder().encode(future)
        defaults.set(futureData, forKey: ArtistNameConfiguration.storageKey)

        let store = ArtistNameSettingsStore(
            defaults: defaults,
            syncsThroughICloud: false
        )

        XCTAssertTrue(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration, .defaultValue)
        XCTAssertEqual(defaults.data(forKey: ArtistNameConfiguration.storageKey), futureData)

        XCTAssertTrue(store.addSeparator("|"))
        XCTAssertFalse(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration.separators, [";", "；", "|"])
        XCTAssertEqual(
            ArtistNameConfiguration.load(from: defaults),
            store.configuration
        )
    }

    func testUndecodableConfigurationIsPreservedUntilUserEdits() throws {
        let suiteName = "ArtistNameSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unknownData = try XCTUnwrap(
            "{\"schemaVersion\":2,\"rules\":{\"kind\":\"future\"}}".data(using: .utf8)
        )
        defaults.set(unknownData, forKey: ArtistNameConfiguration.storageKey)

        let store = ArtistNameSettingsStore(
            defaults: defaults,
            syncsThroughICloud: false
        )

        XCTAssertTrue(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration, .defaultValue)
        XCTAssertEqual(defaults.data(forKey: ArtistNameConfiguration.storageKey), unknownData)
    }
}
