import Testing
@testable import PrimuseKit

@Suite("Artwork cache reload policy")
struct ArtworkCacheReloadPolicyTests {
    @Test("A matching placeholder retries when artwork becomes available")
    func matchingPlaceholderReloads() {
        #expect(ArtworkCacheReloadPolicy.shouldReload(
            cachedSongID: "song-15",
            displayedSongID: "song-15",
            hasResolvedImage: false
        ))
    }

    @Test("Unrelated cache publications do not rebuild the view")
    func unrelatedSongDoesNotReload() {
        #expect(!ArtworkCacheReloadPolicy.shouldReload(
            cachedSongID: "another-song",
            displayedSongID: "song-15",
            hasResolvedImage: false
        ))
    }

    @Test("A resolved image stays visible until explicit invalidation")
    func resolvedImageDoesNotReload() {
        #expect(!ArtworkCacheReloadPolicy.shouldReload(
            cachedSongID: "song-15",
            displayedSongID: "song-15",
            hasResolvedImage: true
        ))
    }

    @Test("Missing identities cannot trigger a reload")
    func missingIdentitiesDoNotReload() {
        #expect(!ArtworkCacheReloadPolicy.shouldReload(
            cachedSongID: nil,
            displayedSongID: "song-15",
            hasResolvedImage: false
        ))
        #expect(!ArtworkCacheReloadPolicy.shouldReload(
            cachedSongID: "song-15",
            displayedSongID: "",
            hasResolvedImage: false
        ))
    }
}
