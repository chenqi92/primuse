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

    @Test("ID overlap takes priority over a stronger metadata candidate")
    func prioritizesIDOverlap() {
        let exactIDCandidate = AppleMusicTrackIdentity(
            itemID: "i.exact",
            alternateIDs: ["catalog.playback"],
            title: "Different title"
        )
        let metadataCandidate = AppleMusicTrackIdentity(
            itemID: "i.metadata",
            title: "Playback title",
            artist: "Playback artist",
            album: "Playback album",
            duration: 240
        )
        let playback = AppleMusicTrackIdentity(
            itemID: "catalog.playback",
            title: metadataCandidate.title,
            artist: metadataCandidate.artist,
            album: metadataCandidate.album,
            duration: metadataCandidate.duration
        )
        let identityIndex = AppleMusicTrackIdentityIndex([exactIDCandidate, metadataCandidate])

        #expect(identityIndex.canonicalID(for: playback) == exactIDCandidate.itemID)
    }

    @Test("Repeated lookups reuse one canonical identity projection")
    func repeatedLookupsReuseIndex() {
        var projectionCount = 0
        let library = 0..<200
        let projectedLibrary = library.lazy.map { index in
            projectionCount += 1
            return AppleMusicTrackIdentity(
                itemID: "i.\(index)",
                alternateIDs: ["catalog.\(index)"],
                title: "Track \(index)",
                artist: "Artist \(index)",
                duration: Double(index + 120)
            )
        }
        let identityIndex = AppleMusicTrackIdentityIndex(projectedLibrary)

        for index in 0..<200 {
            let playback = AppleMusicTrackIdentity(
                itemID: "catalog.\(index)",
                title: "Track \(index)"
            )
            #expect(identityIndex.canonicalID(for: playback) == "i.\(index)")
        }

        #expect(identityIndex.count == library.count)
        #expect(projectionCount == library.count)
    }

    @Test("Merge preserves partial identities while replace prunes them")
    func invalidatesIndexForCacheUpdates() {
        let first = AppleMusicTrackIdentity(
            itemID: "i.first",
            alternateIDs: ["catalog.first"],
            title: "First"
        )
        let second = AppleMusicTrackIdentity(
            itemID: "i.second",
            alternateIDs: ["catalog.second"],
            title: "Second"
        )
        var identityIndex = AppleMusicTrackIdentityIndex([first])

        identityIndex.merge([second])
        #expect(identityIndex.canonicalID(for: first) == first.itemID)
        #expect(identityIndex.canonicalID(for: second) == second.itemID)

        identityIndex.replace(with: [second])
        #expect(identityIndex.canonicalID(for: first) == nil)
        #expect(identityIndex.canonicalID(for: second) == second.itemID)
    }

    @Test("Updating one identity removes stale ID and metadata references")
    func upsertInvalidatesPreviousReferences() {
        let previous = AppleMusicTrackIdentity(
            itemID: "i.library-song",
            alternateIDs: ["catalog.old"],
            title: "Old title",
            artist: "Artist"
        )
        let updated = AppleMusicTrackIdentity(
            itemID: previous.itemID,
            alternateIDs: ["catalog.new"],
            title: "New title",
            artist: "Artist"
        )
        var identityIndex = AppleMusicTrackIdentityIndex([previous])
        let previousPlayback = AppleMusicTrackIdentity(
            itemID: "catalog.old",
            title: previous.title,
            artist: previous.artist
        )
        let updatedPlayback = AppleMusicTrackIdentity(
            itemID: "catalog.new",
            title: updated.title,
            artist: updated.artist
        )

        identityIndex.upsert(updated)

        #expect(identityIndex.canonicalID(for: previousPlayback) == nil)
        #expect(identityIndex.canonicalID(for: updatedPlayback) == updated.itemID)
        #expect(identityIndex.count == 1)
    }

    @Test("Partial fallback never authorizes destructive reconciliation")
    func partialFallbackIsNonDestructive() {
        #expect(AppleMusicLibrarySyncMode.authoritative.shouldPruneMissingSongs)
        #expect(AppleMusicLibrarySyncMode.authoritative.shouldReplaceMirrorPlaylist)
        #expect(!AppleMusicLibrarySyncMode.partialFallback.shouldPruneMissingSongs)
        #expect(!AppleMusicLibrarySyncMode.partialFallback.shouldReplaceMirrorPlaylist)
    }
}
