import Testing
@testable import PrimuseKit

@Suite("Liked songs podcast split policy")
struct LikedSongsPodcastSplitPolicyTests {
    private let podcasts: Set<String> = ["p1", "p2", "p3"]
    private var isPodcast: (String) -> Bool { { podcasts.contains($0) } }

    @Test("The playlist keeps the music in its stored order")
    func keepsMusicOrder() {
        #expect(LikedSongsPodcastSplitPolicy.music(
            ["s1", "p1", "s2", "p2", "s3"],
            isLocalPodcast: isPodcast
        ) == ["s1", "s2", "s3"])
    }

    @Test("Liked podcast episodes list the latest liked first")
    func listsPodcastsNewestFirst() {
        #expect(LikedSongsPodcastSplitPolicy.podcastsNewestFirst(
            ["p1", "s1", "p2", "s2", "p3"],
            isLocalPodcast: isPodcast
        ) == ["p3", "p2", "p1"])
        #expect(LikedSongsPodcastSplitPolicy.podcastsNewestFirst(
            ["s1", "s2"],
            isLocalPodcast: isPodcast
        ).isEmpty)
    }

    @Test("Reordering the music keeps the hidden episodes liked")
    func replacementKeepsHiddenEpisodes() {
        #expect(LikedSongsPodcastSplitPolicy.replacement(
            ["s3", "s1", "s2"],
            keeping: ["s1", "p1", "s2", "p2", "s3"],
            isLocalPodcast: isPodcast
        ) == ["s3", "s1", "s2", "p1", "p2"])
    }

    @Test("A replacement that already lists an episode does not add it twice")
    func replacementDoesNotDuplicate() {
        #expect(LikedSongsPodcastSplitPolicy.replacement(
            ["p2", "s1"],
            keeping: ["s1", "p1", "p2"],
            isLocalPodcast: isPodcast
        ) == ["p2", "s1", "p1"])
        #expect(LikedSongsPodcastSplitPolicy.replacement(
            ["s2", "s1"],
            keeping: ["s1", "s2"],
            isLocalPodcast: isPodcast
        ) == ["s2", "s1"])
    }
}
