import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class SearchExperienceTests: XCTestCase {
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
