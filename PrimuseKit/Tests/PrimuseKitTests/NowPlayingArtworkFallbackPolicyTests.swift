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
