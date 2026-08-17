import Testing
@testable import PrimuseKit

@Suite("Now Playing artwork fallback policy")
struct NowPlayingArtworkFallbackPolicyTests {
    @Test("Source sidecar paths fall back to the authenticated connector")
    func sourcePathUsesConnector() {
        #expect(NowPlayingArtworkFallbackPolicy.shouldFetchFromConnector(
            reference: "/Music/Album/cover.jpg",
            directImageLoaded: false
        ))
    }

    @Test("Opaque cloud artwork identifiers also use the connector")
    func opaqueIdentifierUsesConnector() {
        #expect(NowPlayingArtworkFallbackPolicy.shouldFetchFromConnector(
            reference: "cloud-cover-123",
            directImageLoaded: false
        ))
    }

    @Test("A decoded direct image prevents duplicate source requests")
    func loadedDirectImageSkipsConnector() {
        #expect(!NowPlayingArtworkFallbackPolicy.shouldFetchFromConnector(
            reference: "/Music/Album/cover.jpg",
            directImageLoaded: true
        ))
    }

    @Test("Absolute URLs and missing references are not connector paths")
    func directURLsAndMissingReferencesSkipConnector() {
        #expect(!NowPlayingArtworkFallbackPolicy.shouldFetchFromConnector(
            reference: "https://media.example.test/cover.jpg",
            directImageLoaded: false
        ))
        #expect(!NowPlayingArtworkFallbackPolicy.shouldFetchFromConnector(
            reference: nil,
            directImageLoaded: false
        ))
        #expect(!NowPlayingArtworkFallbackPolicy.shouldFetchFromConnector(
            reference: "",
            directImageLoaded: false
        ))
    }
}

@Suite("Now Playing artwork publication policy")
struct NowPlayingArtworkPublicationPolicyTests {
    @Test("Same-track artwork refresh avoids an empty intermediate snapshot")
    func sameTrackRefreshKeepsPublishedArtworkWhileLoading() {
        #expect(!NowPlayingArtworkPublicationPolicy.shouldClearArtworkBeforeLoading(
            isSameItemRefresh: true
        ))
    }

    @Test("Track changes clear artwork owned by the previous item")
    func trackChangeClearsPublishedArtworkWhileLoading() {
        #expect(NowPlayingArtworkPublicationPolicy.shouldClearArtworkBeforeLoading(
            isSameItemRefresh: false
        ))
    }

    @Test("Artwork is retained for updates to the same track")
    func sameTrackRetainsArtwork() {
        #expect(NowPlayingArtworkPublicationPolicy.shouldReuseArtwork(
            ownedBy: "song-a",
            for: "song-a"
        ))
    }

    @Test("Artwork from the previous track is never attached to the next track")
    func trackChangeDropsPreviousArtwork() {
        #expect(!NowPlayingArtworkPublicationPolicy.shouldReuseArtwork(
            ownedBy: "song-a",
            for: "song-b"
        ))
    }

    @Test("Missing item identity cannot establish artwork ownership")
    func missingIdentityDropsArtwork() {
        #expect(!NowPlayingArtworkPublicationPolicy.shouldReuseArtwork(
            ownedBy: nil,
            for: "song-a"
        ))
        #expect(!NowPlayingArtworkPublicationPolicy.shouldReuseArtwork(
            ownedBy: "song-a",
            for: nil
        ))
    }
}
