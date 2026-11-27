import Testing
@testable import PrimuseKit

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
