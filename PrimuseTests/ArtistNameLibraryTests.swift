import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class ArtistNameLibraryTests: XCTestCase {
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
        artistName: String,
        sourceArtistNames: [String]? = nil,
        albumArtistName: String? = nil,
        albumTitle: String? = nil
    ) -> Song {
        Song(
            id: UUID().uuidString,
            title: "Track",
            albumTitle: albumTitle,
            artistName: artistName,
            sourceArtistNames: sourceArtistNames,
            albumArtistName: albumArtistName,
            duration: 180,
            fileFormat: .flac,
            filePath: "/track.flac",
            sourceID: "source"
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
