import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album and playlist artwork overrides")
struct LibraryArtworkOverrideTests {
    @Test("Album and playlist owners round-trip through reserved CloudKit IDs")
    func ownerCloudRecordRoundTrip() {
        let owners = [
            LibraryArtworkOwner(kind: .album, id: "album:artist/title"),
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
        let owner = LibraryArtworkOwner(kind: .playlist, id: "shared")
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
}
