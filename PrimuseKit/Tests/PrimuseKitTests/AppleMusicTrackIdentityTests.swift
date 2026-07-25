import Testing
@testable import PrimuseKit

@Suite("Apple Music track identity")
struct AppleMusicTrackIdentityTests {
    @Test("Catalog ID resolves to its user-library ID")
    func resolvesAlternateCatalogID() {
        let library = AppleMusicTrackIdentity(
            itemID: "i.library-song",
            alternateIDs: ["1592372522"],
            title: "变心的翅膀",
            artist: "陈明真",
            album: "变心的翅膀",
            duration: 256
        )
        let playback = AppleMusicTrackIdentity(
            itemID: "1592372522",
            title: "變心的翅膀",
            artist: "陳明真",
            album: "變心的翅膀",
            duration: 256
        )

        #expect(
            AppleMusicTrackIdentityResolver.canonicalID(for: playback, in: [library])
                == library.itemID
        )
    }

    @Test("Punctuation differences in multi-artist names remain matchable")
    func normalizesArtistPunctuation() {
        let library = AppleMusicTrackIdentity(
            itemID: "i.library-song",
            title: "笨小孩",
            artist: "刘德华, 吴宗宪 & 柯受良",
            album: "The Melody Andy, Vol. 8",
            duration: 241
        )
        let playback = AppleMusicTrackIdentity(
            itemID: "catalog-song",
            title: "笨小孩",
            artist: "刘德华、吴宗宪、柯受良",
            album: "The Melody Andy Vol. 8",
            duration: 241.4
        )

        #expect(
            AppleMusicTrackIdentityResolver.canonicalID(for: playback, in: [library])
                == library.itemID
        )
    }

    @Test("Ambiguous metadata never guesses a canonical song")
    func rejectsAmbiguousMetadata() {
        let candidates = [
            AppleMusicTrackIdentity(itemID: "i.one", title: "Intro", duration: 30),
            AppleMusicTrackIdentity(itemID: "i.two", title: "Intro", duration: 30),
        ]
        let playback = AppleMusicTrackIdentity(itemID: "catalog", title: "Intro", duration: 30)

        #expect(AppleMusicTrackIdentityResolver.canonicalID(for: playback, in: candidates) == nil)
    }

    @Test("Partial fallback never authorizes destructive reconciliation")
    func partialFallbackIsNonDestructive() {
        #expect(AppleMusicLibrarySyncMode.authoritative.shouldPruneMissingSongs)
        #expect(AppleMusicLibrarySyncMode.authoritative.shouldReplaceMirrorPlaylist)
        #expect(!AppleMusicLibrarySyncMode.partialFallback.shouldPruneMissingSongs)
        #expect(!AppleMusicLibrarySyncMode.partialFallback.shouldReplaceMirrorPlaylist)
    }
}
