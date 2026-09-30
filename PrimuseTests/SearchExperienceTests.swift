import Foundation
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

@MainActor
final class SearchExperienceTests: XCTestCase {
    func testRecommendationBadgeKeepsAlbumCardHeightAndFitsArtwork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let manager = SourceManager(sourcesProvider: { [] })
        let album = Album(id: "recommendation", title: "夜曲", artistName: "周杰伦", songCount: 12)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(80), 142] {
                let plain = ImageRenderer(content: AlbumCardView(album: album, showsSongCount: true)
                    .frame(width: width).environment(library).environment(manager)
                    .environment(\.locale, Locale(identifier: "zh-Hans")).environment(\.colorScheme, scheme))
                let recommended = ImageRenderer(content: AlbumCardView(album: album, showsSongCount: true,
                                                                        isIntelligentRecommendation: true)
                    .frame(width: width).environment(library).environment(manager)
                    .environment(\.locale, Locale(identifier: "zh-Hans")).environment(\.colorScheme, scheme))
                XCTAssertEqual(try XCTUnwrap(plain.uiImage).size, try XCTUnwrap(recommended.uiImage).size)
            }
            let content = HStack(alignment: .top, spacing: 20) {
                AlbumCardView(album: album, showsSongCount: true, isIntelligentRecommendation: true)
                    .frame(width: 142)
                VStack(spacing: 10) {
                    Circle().fill(.blue.gradient).frame(width: 112, height: 112)
                        .searchRecommendationOverlay(isRecommended: true, iconOnly: true)
                    Circle().fill(.blue.gradient).frame(width: 44, height: 44)
                        .searchRecommendationOverlay(isRecommended: true, iconOnly: true, inset: 3)
                }
            }
            .padding(20).background(scheme == .dark ? Color.black : .white)
            .environment(library).environment(manager)
            .environment(\.locale, Locale(identifier: "zh-Hans")).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            attachment.name = "search-artwork-recommendations-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testIntelligentBadgeOnlyMarksSupplementsFromTheCurrentQuery() {
        XCTAssertEqual(SearchRecommendationOriginPolicy.intelligentIDs(
            primary: ["literal-album", "overlap"], recommended: ["overlap", "recommended-album", "recommended-album"],
            isCurrentQuery: true
        ), ["recommended-album"])
        XCTAssertTrue(SearchRecommendationOriginPolicy.intelligentIDs(
            primary: ["literal-album"], recommended: ["old-album"], isCurrentQuery: false
        ).isEmpty)
        XCTAssertEqual(SearchRecommendationOriginPolicy.intelligentIDs(
            primary: [SearchCollectionResult.Target.playlist("direct")],
            recommended: [.playlist("direct"), .smartPlaylist("recommended")], isCurrentQuery: true
        ), [.smartPlaylist("recommended")])
    }

    func testAlbumLikeAddsAllCurrentTracksAndPersistsWithoutDuplicatingExistingLikes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let tracks = (1...150).map { index in
            Song(id: "album-track-\(index)", title: "Track \(index)", albumTitle: "Large Album", artistName: "Artist",
                 albumArtistName: "Artist", trackNumber: (index - 1) % 75 + 1, discNumber: (index - 1) / 75 + 1,
                 fileFormat: .flac, filePath: "/Large Album/\(index).flac", sourceID: "source")
        }
        let previousLikes = (1...3).map {
            Song(id: "previous-\($0)", title: "Previous \($0)", albumTitle: "Other Album", artistName: "Other Artist",
                 fileFormat: .mp3, filePath: "/Other Album/\($0).mp3", sourceID: "source")
        }
        library.addSongs([tracks[0]] + previousLikes, affectedSourceIDs: ["source"])
        await library.waitForPendingIndex()
        let albumID = try XCTUnwrap(library.song(id: tracks[0].id)?.albumID)
        let target = SearchResultActionTarget.album(albumID)
        XCTAssertEqual(target.songs(in: library).map(\.id), [tracks[0].id])
        library.likeSongs(previousLikes.map(\.id) + [tracks[0].id])
        library.addSongs(Array(tracks.dropFirst()), affectedSourceIDs: ["source"], pruneMissingSongs: false)
        await library.waitForPendingIndex()

        var changedLikes: [String] = []
        library.likedStateMutationHandler = { song, previous, desired in
            XCTAssertFalse(previous)
            XCTAssertTrue(desired)
            changedLikes.append(song.id)
        }
        target.addToLiked(in: library)
        let expected = previousLikes.map(\.id) + tracks.map(\.id)
        XCTAssertEqual(library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID).map(\.id), expected)
        XCTAssertEqual(changedLikes, Array(tracks.dropFirst()).map(\.id))
        target.addToLiked(in: library)
        XCTAssertEqual(changedLikes.count, 149)
        XCTAssertEqual(library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID).count, 153)

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Liked album tracks should persist")
        }
        let restored = MusicLibrary(storageDirectory: directory)
        await restored.waitForPendingIndex()
        XCTAssertEqual(restored.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID).map(\.id), expected)
    }

    func testSingleTrackCollectionsAlwaysAddWhileIndividualSongsCanToggle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Song(id: "single", title: "Single", albumTitle: "Single Album", artistName: "Single Artist",
                        fileFormat: .mp3, filePath: "/Single/track.mp3", sourceID: "source")
        library.addSongs([song], affectedSourceIDs: ["source"])
        await library.waitForPendingIndex()
        let current = try XCTUnwrap(library.song(id: song.id))
        let album = SearchResultActionTarget.album(try XCTUnwrap(current.albumID))
        let artist = SearchResultActionTarget.artist(try XCTUnwrap(library.artistIDs(for: current).first))
        let playlist = library.createPlaylist(name: "Single playlist")
        library.add(songID: song.id, toPlaylist: playlist.id)
        let collection = SearchResultActionTarget.collection(
            SearchCollectionResult(target: .playlist(playlist.id), title: playlist.name, detail: "")
        )
        for target in [album, album, artist, collection] {
            target.addToLiked(in: library)
            XCTAssertTrue(library.isLiked(songID: song.id))
            XCTAssertEqual(library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID).map(\.id), [song.id])
        }
        library.toggleLiked(songID: song.id)
        XCTAssertFalse(library.isLiked(songID: song.id))
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Collection likes should persist")
        }
    }

    func testIndexRefreshKeepsSemanticRequestAndCompletedPlan() {
        let coordinator = SearchWorkCoordinator()
        XCTAssertTrue(coordinator.beginIntelligence(query: "适合夜晚听的", configurationRevision: 2))
        let semanticTask = Task<Void, Never> {}
        let localTask = Task<Void, Never> {}
        coordinator.intelligenceTask = semanticTask
        coordinator.searchTask = localTask
        let generation = coordinator.intelligenceGeneration
        coordinator.cancelLocalSearch()
        XCTAssertTrue(localTask.isCancelled)
        XCTAssertFalse(semanticTask.isCancelled)
        XCTAssertEqual(coordinator.intelligenceGeneration, generation)
        XCTAssertFalse(coordinator.beginIntelligence(query: "适合夜晚听的", configurationRevision: 2))
        coordinator.intelligencePlan = AISemanticSearchPlan(expandedTerms: ["夜曲"])
        coordinator.intelligenceCompleted = true
        XCTAssertFalse(coordinator.beginIntelligence(query: "适合夜晚听的", configurationRevision: 2))
        XCTAssertTrue(coordinator.intelligenceCompleted)
        XCTAssertEqual(coordinator.intelligencePlan?.expandedTerms, ["夜曲"])
    }

    func testNewQueryOrProviderConfigurationCancelsOldSemanticWork() {
        let coordinator = SearchWorkCoordinator()
        coordinator.beginIntelligence(query: "摇滚", configurationRevision: 1)
        let old = Task<Void, Never> {}
        coordinator.intelligenceTask = old
        coordinator.intelligenceCompleted = true
        coordinator.intelligencePlan = AISemanticSearchPlan(expandedTerms: ["Rock"])
        XCTAssertTrue(coordinator.beginIntelligence(query: "爵士", configurationRevision: 1))
        XCTAssertTrue(old.isCancelled)
        XCTAssertNil(coordinator.intelligencePlan)
        XCTAssertFalse(coordinator.intelligenceCompleted)
        XCTAssertTrue(coordinator.beginIntelligence(query: "爵士", configurationRevision: 2))
    }

    func testPlaylistAndCloudFolderNamesAreSearchedWithoutUsingOpaqueIDs() throws {
        let descriptor = LibraryFolderSourceDescriptor(
            sourceID: "cloud", displayName: "Cloud", scanRoots: ["root-id"], pathSemantics: .opaque,
            providerHierarchy: LibraryFolderProviderHierarchy(
                roots: [.init(path: "root-id", displayName: "Music")],
                items: [
                    .init(path: "folder-id", displayName: "夜间歌单", parentPath: "root-id", isDirectory: true),
                    .init(path: "file-id", displayName: "Track.flac", parentPath: "folder-id", isDirectory: false)
                ]
            )
        )
        let song = Song(id: "track", title: "Track", fileFormat: .flac, filePath: "file-id", sourceID: "cloud")
        let index = LibraryFolderIndexBuilder.build(sources: [descriptor], songs: [song])
        let playlist = Playlist(id: "playlist", name: "夜间歌单精选")
        var deleted = Playlist(id: "deleted", name: "夜间歌单旧版")
        deleted.isDeleted = true
        let results = SearchCatalogTextPolicy.collections(
            query: "夜间歌单", playlists: [playlist, deleted], smartPlaylists: [], folderIndex: index
        )
        XCTAssertEqual(results.count, 2)
        let folder = try XCTUnwrap(results.first { $0.section == .folders })
        XCTAssertEqual(folder.folderSongIDs, ["track"])
        XCTAssertEqual(folder.title, "夜间歌单")
        XCTAssertTrue(folder.detail.contains("Cloud"))
        XCTAssertTrue(SearchCatalogTextPolicy.collections(
            query: "folder-id", playlists: [], smartPlaylists: [], folderIndex: index
        ).isEmpty)
    }

    func testFolderSearchKeepsSourcesDistinctAndIncludesNestedSongs() {
        let sources = ["a", "b"].map {
            LibraryFolderSourceDescriptor(sourceID: $0, displayName: $0, scanRoots: ["/Music"], pathSemantics: .hierarchical)
        }
        let songs = [
            Song(id: "a-track", title: "A", fileFormat: .mp3, filePath: "/Music/歌单/Disc 1/one.mp3", sourceID: "a"),
            Song(id: "b-track", title: "B", fileFormat: .mp3, filePath: "/Music/歌单/two.mp3", sourceID: "b")
        ]
        let index = LibraryFolderIndexBuilder.build(sources: sources, songs: songs)
        let results = SearchCatalogTextPolicy.collections(query: "歌单", playlists: [], smartPlaylists: [], folderIndex: index)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map(\.id)).count, 2)
        XCTAssertEqual(Set(results.flatMap(\.folderSongIDs)), ["a-track", "b-track"])
    }

    func testCatalogNamesFoldCaseWidthAndAccents() {
        XCTAssertTrue(SearchCatalogTextPolicy.matches("ＣＡＦÉ 晚间精选", query: "cafe"))
        XCTAssertTrue(SearchCatalogTextPolicy.matches("Jazz for a Rainy Night", query: "rainy jazz"))
        XCTAssertFalse(SearchCatalogTextPolicy.matches("Jazz", query: "  "))
    }

    func testHiddenListeningSpacesCannotBeOfferedBySearch() {
        let hidden = LibraryDisplayConfiguration.encodeHiddenSections([.radio, .spokenWord])
        XCTAssertFalse(SearchResultAvailabilityPolicy.isAvailable(.radio, hiddenLibrarySectionsRawValue: hidden))
        XCTAssertFalse(SearchResultAvailabilityPolicy.isAvailable(.spokenWord, hiddenLibrarySectionsRawValue: hidden))
        XCTAssertTrue(SearchResultAvailabilityPolicy.isAvailable(.metadata, hiddenLibrarySectionsRawValue: hidden))
        XCTAssertTrue(SearchResultAvailabilityPolicy.isAvailable(.radio, hiddenLibrarySectionsRawValue: ""))
        let layout = SearchResultLayout(orderRawValue: "", hiddenRawValue: #"["radio"]"#)
        XCTAssertFalse(layout.shows(.radio))
        XCTAssertTrue(layout.shows(.spokenWord))
    }

    func testPlaybackResolvesCurrentMetadataInsteadOfSearchSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let snapshot = Song(id: "stale", title: "Snapshot", fileFormat: .mp3, filePath: "old-id", sourceID: "cloud", fileSize: 0)
        var current = snapshot
        current.filePath = "current-id"
        current.fileSize = 9_000_000
        library.addSongs([current], affectedSourceIDs: ["cloud"])
        await library.waitForPendingIndex()
        let selected = try XCTUnwrap(SearchPlaybackSelectionPolicy.currentSong(for: snapshot, in: library))
        XCTAssertEqual(selected.fileSize, 9_000_000)
        XCTAssertEqual(selected.filePath, "current-id")
        XCTAssertNil(SearchPlaybackSelectionPolicy.currentSong(
            for: Song(id: "removed", title: "Removed", fileFormat: .mp3, filePath: "42", sourceID: "cloud"), in: library
        ))
    }
}
