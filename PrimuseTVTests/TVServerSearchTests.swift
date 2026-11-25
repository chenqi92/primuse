#if os(tvOS)
import Foundation
import Testing
@testable import PrimuseTV
@testable import PrimuseKit

@Suite("TV server search catalog")
struct TVServerSearchTests {
    @Test("TVServerSearchCatalog debounces, filters local songs, isolates errors, and publishes previews")
    @MainActor
    func catalogDebouncesFiltersAndPublishes() async throws {
        let navidrome = MusicSource(id: "tv-s1", name: "Navidrome", type: .navidrome, isEnabled: true)
        let broken = MusicSource(id: "tv-s2", name: "Offline", type: .emby, isEnabled: true)
        let localSong = Song(
            id: "tv-local",
            title: "In Library",
            duration: 180,
            fileFormat: .flac,
            filePath: "/songs/1.flac",
            sourceID: "tv-s1",
            fileSize: 100
        )
        let remoteSong = Song(
            id: "tv-remote",
            title: "Server Only",
            duration: 210,
            fileFormat: .mp3,
            filePath: "/songs/2.mp3",
            sourceID: "tv-s1",
            fileSize: 100
        )

        var publishedPreviewIDs: [String] = []
        let catalog = TVServerSearchCatalog(
            debounce: .milliseconds(25),
            perSourceLimit: 10,
            perSourceTimeout: .seconds(2)
        )

        catalog.search(
            query: "server",
            sources: [navidrome, broken],
            fetcher: { source, _, _ in
                if source.id == "tv-s2" {
                    throw TVScanError.connectFailed
                }
                return [localSong, remoteSong]
            },
            isLocalSongIndexed: { $0.id == "tv-local" },
            onHitsUpdated: { hits in
                publishedPreviewIDs = hits.map(\.song.id)
            }
        )

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !catalog.hasCompletedQuery || catalog.isSearching {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for TVServerSearchCatalog")
                return
            }
            try await Task.sleep(for: .milliseconds(15))
        }

        #expect(catalog.hits.map(\.song.id) == ["tv-remote"])
        #expect(publishedPreviewIDs == ["tv-remote"])
    }
}
#endif
