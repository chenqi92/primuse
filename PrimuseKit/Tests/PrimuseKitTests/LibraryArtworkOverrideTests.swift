import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library artwork overrides")
struct LibraryArtworkOverrideTests {
    @Test("Album fallback prefers the first explicit song cover and otherwise keeps album order")
    func albumFallbackSelection() {
        #expect(AlbumArtworkFallbackPolicy.preferredSongID(
            orderedSongIDs: ["track-1", "track-2", "track-3"],
            songIDsWithArtworkReference: ["track-2", "track-3"]
        ) == "track-2")
        #expect(AlbumArtworkFallbackPolicy.preferredSongID(
            orderedSongIDs: ["track-1", "track-2"],
            songIDsWithArtworkReference: []
        ) == "track-1")
        #expect(AlbumArtworkFallbackPolicy.preferredSongID(
            orderedSongIDs: ["", "track-2"],
            songIDsWithArtworkReference: []
        ) == "track-2")
        #expect(AlbumArtworkFallbackPolicy.preferredSongID(
            orderedSongIDs: [],
            songIDsWithArtworkReference: []
        ) == nil)
    }

    @Test("Library artwork owners round-trip through reserved CloudKit IDs")
    func ownerCloudRecordRoundTrip() {
        let owners = [
            LibraryArtworkOwner(kind: .album, id: "album:artist/title"),
            LibraryArtworkOwner(kind: .artist, id: "artist:with/slash"),
            LibraryArtworkOwner(kind: .playlist, id: "playlist:with:colons"),
        ]

        for owner in owners {
            #expect(LibraryArtworkOwner.fromCloudRecordID(owner.cloudRecordID) == owner)
            #expect(owner.cloudRecordID.hasPrefix(LibraryArtworkOwner.cloudRecordIDPrefix))
        }
        #expect(LibraryArtworkOwner.fromCloudRecordID("ordinary-playlist") == nil)
    }

    @Test("Manual upload and selected-song modes take precedence over automatic artwork")
    func explicitModesResolve() {
        let owner = LibraryArtworkOwner(kind: .album, id: "album")
        let selected = LibraryArtworkOverride(
            owner: owner,
            mode: .selectedSong,
            selectedSongIdentity: identity("covered")
        )
        let contentID = String(repeating: "a", count: 64)
        let uploaded = LibraryArtworkOverride(
            owner: owner,
            mode: .uploaded,
            uploadedContentID: contentID
        )

        #expect(LibraryArtworkOverridePolicy.resolve(
            override: selected,
            resolvedSongID: "covered",
            eligibleSongIDs: ["missing-first", "covered"]
        ) == .selectedSong("covered"))
        #expect(LibraryArtworkOverridePolicy.resolve(
            override: uploaded,
            resolvedSongID: nil,
            eligibleSongIDs: []
        ) == .uploaded(contentID))
    }

    @Test("A removed selection and malformed upload safely return to automatic artwork")
    func invalidOverridesFallBack() {
        let owner = LibraryArtworkOwner(kind: .playlist, id: "playlist")
        let removedSong = LibraryArtworkOverride(
            owner: owner,
            mode: .selectedSong,
            selectedSongIdentity: identity("removed")
        )
        let malformedUpload = LibraryArtworkOverride(
            owner: owner,
            mode: .uploaded,
            uploadedContentID: "not-a-content-hash"
        )

        #expect(LibraryArtworkOverridePolicy.resolve(
            override: removedSong,
            resolvedSongID: "removed",
            eligibleSongIDs: ["remaining"]
        ) == .automatic)
        #expect(LibraryArtworkOverridePolicy.resolve(
            override: malformedUpload,
            resolvedSongID: nil,
            eligibleSongIDs: []
        ) == .automatic)
        #expect(LibraryArtworkOverridePolicy.resolve(
            override: nil,
            resolvedSongID: nil,
            eligibleSongIDs: []
        ) == .automatic)
    }

    @Test("Automatic and uploaded artwork skip selected-song lookup")
    func nonSelectedModesSkipSongLookup() {
        let owner = LibraryArtworkOwner(kind: .album, id: "album")
        let automatic = LibraryArtworkOverride(owner: owner, mode: .automatic)
        let contentID = String(repeating: "d", count: 64)
        let uploaded = LibraryArtworkOverride(
            owner: owner,
            mode: .uploaded,
            uploadedContentID: contentID
        )
        let selected = LibraryArtworkOverride(
            owner: owner,
            mode: .selectedSong,
            selectedSongIdentity: identity("selected")
        )
        var lookupCount = 0

        func resolve(_ override: LibraryArtworkOverride?) -> LibraryArtworkOverrideResolution {
            LibraryArtworkOverridePolicy.resolve(override: override) {
                lookupCount += 1
                return (songID: "selected", isEligible: true)
            }
        }

        #expect(resolve(nil) == .automatic)
        #expect(resolve(automatic) == .automatic)
        #expect(resolve(uploaded) == .uploaded(contentID))
        #expect(lookupCount == 0)
        #expect(resolve(selected) == .selectedSong("selected"))
        #expect(lookupCount == 1)
    }

    @Test("The same policy result is shared by phone, Mac, TV, and CarPlay adapters")
    func sharedCrossPlatformResolution() {
        let owner = LibraryArtworkOwner(kind: .artist, id: "shared")
        let value = LibraryArtworkOverride(
            owner: owner,
            mode: .selectedSong,
            selectedSongIdentity: identity("later-covered-song")
        )

        func resolveForAdapter() -> LibraryArtworkOverrideResolution {
            LibraryArtworkOverridePolicy.resolve(
                override: value,
                resolvedSongID: "later-covered-song",
                eligibleSongIDs: ["first-without-cover", "later-covered-song"]
            )
        }

        let iOS = resolveForAdapter()
        let macOS = resolveForAdapter()
        let tvOS = resolveForAdapter()
        let carPlay = resolveForAdapter()
        #expect(iOS == .selectedSong("later-covered-song"))
        #expect(iOS == macOS)
        #expect(macOS == tvOS)
        #expect(tvOS == carPlay)
    }

    @Test("Logical clocks reconcile concurrent choices deterministically")
    func reconciliationIsDeterministic() {
        let owner = LibraryArtworkOwner(kind: .album, id: "album")
        let older = LibraryArtworkOverride(
            owner: owner,
            mode: .automatic,
            syncRevision: 3,
            syncWriterID: "phone",
            syncOperationID: "a"
        )
        let newer = LibraryArtworkOverride(
            owner: owner,
            mode: .selectedSong,
            selectedSongIdentity: identity("song"),
            syncRevision: 4,
            syncWriterID: "mac",
            syncOperationID: "b"
        )
        let concurrentWinner = LibraryArtworkOverride(
            owner: owner,
            mode: .uploaded,
            uploadedContentID: String(repeating: "b", count: 64),
            syncRevision: 4,
            syncWriterID: "tablet",
            syncOperationID: "c"
        )

        #expect(LibraryArtworkOverrideReconciliationPolicy.winner(
            local: older,
            remote: newer
        ) == .remote)
        #expect(LibraryArtworkOverrideReconciliationPolicy.winner(
            local: newer,
            remote: concurrentWinner
        ) == .remote)
        #expect(LibraryArtworkOverrideReconciliationPolicy.winner(
            local: concurrentWinner,
            remote: newer
        ) == .local)
    }

    @Test("Cloud envelope keeps bounded uploaded bytes and the exact content identity")
    func cloudEnvelopeRoundTrip() throws {
        let contentID = String(repeating: "c", count: 64)
        let value = LibraryArtworkOverride(
            owner: LibraryArtworkOwner(kind: .album, id: "album"),
            mode: .uploaded,
            uploadedContentID: contentID,
            syncRevision: 8,
            syncWriterID: "phone",
            syncOperationID: "upload"
        )
        let bytes = Data(repeating: 0x5a, count: 128)
        let envelope = LibraryArtworkCloudEnvelope(
            override: value,
            uploadedArtworkData: bytes
        )
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(LibraryArtworkCloudEnvelope.self, from: encoded)

        #expect(decoded == envelope)
        #expect(decoded.override.uploadedContentID == contentID)
        #expect(LibraryArtworkContentIDPolicy.isValid(contentID))
        #expect(!LibraryArtworkContentIDPolicy.isValid(String(repeating: "c", count: 63)))
        #expect(!LibraryArtworkContentIDPolicy.isValid(String(repeating: "C", count: 64)))
    }

    private func identity(_ songID: String) -> SongIdentity {
        SongIdentity(
            songID: songID,
            title: songID,
            artistName: "Artist",
            duration: 180,
            cloudAccountID: "account",
            filePath: "/Music/\(songID).flac"
        )
    }

    private static let identity = SongIdentity(
        songID: "remote-id",
        title: "Title",
        artistName: "Singer",
        duration: 240,
        cloudAccountID: "account",
        filePath: "music/a.flac"
    )

    private static func entry(
        songID: String?,
        generation: UInt64 = 1,
        songCount: Int = 100,
        checkedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> LibraryArtworkSongResolutionCachePolicy.Entry {
        .init(identity: identity, songID: songID, generation: generation, songCount: songCount, checkedAt: checkedAt)
    }

    @Test("Artwork song lookup reuses the same generation and re-verifies a found song after a library change")
    func artworkSongResolutionReuseAndVerify() {
        let now = Date(timeIntervalSince1970: 1_001)
        #expect(LibraryArtworkSongResolutionCachePolicy.decision(
            cached: nil, identity: Self.identity, generation: 1, songCount: 100, now: now
        ) == .resolve)
        #expect(LibraryArtworkSongResolutionCachePolicy.decision(
            cached: Self.entry(songID: "local"), identity: Self.identity, generation: 1, songCount: 100, now: now
        ) == .reuse)
        #expect(LibraryArtworkSongResolutionCachePolicy.decision(
            cached: Self.entry(songID: "local"), identity: Self.identity, generation: 2, songCount: 100, now: now
        ) == .verify(songID: "local"))
        let otherIdentity = SongIdentity(
            songID: "other", title: "Other", artistName: nil, duration: 1, cloudAccountID: nil, filePath: ""
        )
        #expect(LibraryArtworkSongResolutionCachePolicy.decision(
            cached: Self.entry(songID: "local"), identity: otherIdentity, generation: 1, songCount: 100, now: now
        ) == .resolve)
        let carried = Self.entry(songID: "local").carried(to: 7, songCount: 120)
        #expect(carried.generation == 7 && carried.songCount == 120 && carried.songID == "local")
        #expect(carried.checkedAt == Self.entry(songID: "local").checkedAt)
    }

    @Test("A missing artwork song is looked up again only when songs come or go, or after the interval")
    func artworkSongResolutionNegativeThrottle() {
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        let missing = Self.entry(songID: nil, checkedAt: checkedAt)
        let soon = checkedAt.addingTimeInterval(1)
        #expect(LibraryArtworkSongResolutionCachePolicy.decision(
            cached: missing, identity: Self.identity, generation: 2, songCount: 100, now: soon
        ) == .reuse)
        #expect(LibraryArtworkSongResolutionCachePolicy.decision(
            cached: missing, identity: Self.identity, generation: 2, songCount: 101, now: soon
        ) == .resolve)
        let later = checkedAt.addingTimeInterval(LibraryArtworkSongResolutionCachePolicy.unresolvedRecheckInterval)
        #expect(LibraryArtworkSongResolutionCachePolicy.decision(
            cached: missing, identity: Self.identity, generation: 2, songCount: 100, now: later
        ) == .resolve)
    }

    @Test("Artwork song verification uses the same cloud-path and fuzzy rules as the library scan")
    func artworkSongResolutionMatchRules() {
        func matches(
            title: String = "Other", artist: String? = "Singer", duration: Double = 100,
            path: String = "elsewhere.flac", account: String? = "account"
        ) -> Bool {
            LibraryArtworkSongResolutionCachePolicy.song(
                title: title, artistName: artist, duration: duration, filePath: path,
                cloudAccountID: { account }, matches: Self.identity
            )
        }
        #expect(matches(path: "music/a.flac"))
        #expect(!matches(path: "music/a.flac", account: "someone-else"))
        #expect(matches(title: "Title", duration: 240.5))
        #expect(!matches(title: "Title", duration: 241.5))
        #expect(!matches(title: "Title", artist: "Another", duration: 240))
        let noArtist = SongIdentity(
            songID: "x", title: "Title", artistName: nil, duration: 240, cloudAccountID: nil, filePath: ""
        )
        #expect(LibraryArtworkSongResolutionCachePolicy.song(
            title: "Title", artistName: "Anyone", duration: 240, filePath: "", cloudAccountID: { nil }, matches: noArtist
        ))
        let untitled = SongIdentity(
            songID: "x", title: "", artistName: nil, duration: 240, cloudAccountID: nil, filePath: ""
        )
        #expect(!LibraryArtworkSongResolutionCachePolicy.song(
            title: "", artistName: nil, duration: 240, filePath: "", cloudAccountID: { nil }, matches: untitled
        ))
    }
}
