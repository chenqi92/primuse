import Foundation
import Testing
@testable import PrimuseKit
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Expected values are the golden cases of Navidrome's own
/// `db/migrations/id_canonical_test.go` and `model/id/id_test.go` (v0.64.0).
struct NavidromeCanonicalIDPolicyTests {
    private func canonical(_ id: String) -> String {
        NavidromeCanonicalIDPolicy.canonicalID(id) { _ in
            Issue.record("md5 must only be consulted for overflowing 22-character ids")
            return Data()
        }
    }

    @Test func legacyHexAndUUIDIDsAreReencodedByValue() {
        #expect(canonical("e3b7fc2ae9447bbec37a13bf916e3cf6") == "6VHl3uR4kss6sUPKA8Cwnk")
        #expect(canonical("E3B7FC2AE9447BBEC37A13BF916E3CF6") == "6VHl3uR4kss6sUPKA8Cwnk")
        #expect(canonical("f47ac10b-58cc-4372-a567-0e02b2c3d479") == "7rke2SAWaicSeSYzkhww6R")
    }

    @Test func idsThatAlreadyFitAndUnknownShapesPassThrough() {
        for id in [
            "5cLJPkLA5DK2BADhoeotPk",
            "",
            "aB3xY9kQz1",
            "0123456789abcdef",
            "!!!!!!!!!!!!!!!!!!!!!!",
            "-000000000000000000001",
            String(repeating: "z", count: 32),
            String(repeating: "0", count: 36),
            "tr-1234",
        ] {
            #expect(canonical(id) == id)
        }
    }

    @Test func encodingIsZeroPaddedBase62() {
        #expect(NavidromeCanonicalIDPolicy.encode([UInt8](repeating: 0, count: 16))
            == "0000000000000000000000")
        #expect(NavidromeCanonicalIDPolicy.encode([UInt8](repeating: 0xff, count: 16))
            == "7N42dgm5tFLK9N8MT7fHC7")
    }

    @Test func overflowingRandomIDsAreRemappedThroughMD5() {
        var hashedInput: Data?
        let result = NavidromeCanonicalIDPolicy.canonicalID(
            String(repeating: "z", count: 22)
        ) { input in
            hashedInput = input
            return Data([UInt8](repeating: 0, count: 15) + [1])
        }
        #expect(hashedInput == Data(String(repeating: "z", count: 22).utf8))
        #expect(result == "0000000000000000000001")
    }

    #if canImport(CryptoKit)
    @Test func overflowingRandomIDMatchesServerGoldenValue() {
        #expect(NavidromeCanonicalIDPolicy.canonicalID(String(repeating: "z", count: 22))
            == "3LyqmwQBm5IRqlVjNYASwb")
    }
    #endif

    @Test func canonicalizationIsIdempotent() {
        for id in [
            "5cLJPkLA5DK2BADhoeotPk",
            "e3b7fc2ae9447bbec37a13bf916e3cf6",
            "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        ] {
            let once = canonical(id)
            #expect(canonical(once) == once)
        }
    }
}

struct SubsonicSongIdentityCarryPolicyTests {
    private let legacyID = "e3b7fc2ae9447bbec37a13bf916e3cf6"
    private let migratedID = "6VHl3uR4kss6sUPKA8Cwnk"

    private func canonical(_ id: String) -> String {
        NavidromeCanonicalIDPolicy.canonicalID(id) { _ in Data() }
    }

    private func song(id: String, serverID: String, suffix: String = "flac") -> Song {
        Song(
            id: id,
            title: "Song",
            fileFormat: .flac,
            filePath: "/songs/\(serverID).\(suffix)",
            sourceID: "navidrome",
            fileSize: 4_096,
            dateAdded: Date(timeIntervalSince1970: 1)
        )
    }

    private func carried(
        _ incoming: Song,
        existing: [Song]
    ) -> String? {
        let existingIDs = Set(existing.map(\.id))
        return SubsonicSongIdentityCarryPolicy.carriedSongID(
            for: incoming,
            isExistingSongID: { existingIDs.contains($0) },
            songIDsByServerSongID: SubsonicSongIdentityCarryPolicy.songIDsByServerSongID(
                existing,
                canonicalID: canonical
            )
        )
    }

    @Test func serverSongIDIsReadFromTheConnectorPath() {
        #expect(SubsonicSongIdentityCarryPolicy.serverSongID(fromPath: "/songs/abc.flac") == "abc")
        #expect(SubsonicSongIdentityCarryPolicy.serverSongID(fromPath: "/songs/abc") == "abc")
        #expect(SubsonicSongIdentityCarryPolicy.serverSongID(fromPath: "/items/abc.flac") == nil)
        #expect(SubsonicSongIdentityCarryPolicy.serverSongID(fromPath: "/songs/a/b.flac") == nil)
        #expect(SubsonicSongIdentityCarryPolicy.serverSongID(fromPath: "/songs/") == nil)
    }

    @Test func migratedServerIDKeepsTheLibraryRow() {
        let existing = song(id: "library-row", serverID: legacyID)
        let rescanned = song(id: "hash-of-new-path", serverID: migratedID)

        #expect(carried(rescanned, existing: [existing]) == "library-row")
    }

    /// Once carried, the row's path holds the new id while its song ID stays
    /// old, so every later scan has to match it by path again.
    @Test func carriedRowIsCarriedAgainOnTheNextScan() {
        let carriedRow = song(id: "library-row", serverID: migratedID)
        let rescanned = song(id: "hash-of-new-path", serverID: migratedID)

        #expect(carried(rescanned, existing: [carriedRow]) == "library-row")
    }

    @Test func rowsThatAlreadyMatchOrMatchNothingAreLeftAlone() {
        let existing = song(id: "library-row", serverID: legacyID)
        let unchanged = song(id: "library-row", serverID: legacyID)
        let unrelated = song(id: "other", serverID: "5cLJPkLA5DK2BADhoeotPk")

        #expect(carried(unchanged, existing: [existing]) == nil)
        #expect(carried(unrelated, existing: [existing]) == nil)
    }

    @Test func ambiguousServerIDsAreNotGuessed() {
        let first = song(id: "first", serverID: legacyID)
        let duplicate = song(id: "second", serverID: legacyID, suffix: "mp3")
        let rescanned = song(id: "hash-of-new-path", serverID: migratedID)

        #expect(carried(rescanned, existing: [first, duplicate]) == nil)
    }

    @Test func onlyAnExactReencodingCountsAsTheSameObject() {
        #expect(SubsonicSongIdentityCarryPolicy.isCanonicalRekey(
            previousPath: "/songs/\(legacyID).flac",
            currentPath: "/songs/\(migratedID).flac",
            canonicalID: canonical
        ))
        #expect(!SubsonicSongIdentityCarryPolicy.isCanonicalRekey(
            previousPath: "/songs/\(legacyID).flac",
            currentPath: "/songs/\(migratedID).mp3",
            canonicalID: canonical
        ))
        #expect(!SubsonicSongIdentityCarryPolicy.isCanonicalRekey(
            previousPath: "/songs/\(legacyID).flac",
            currentPath: "/songs/5cLJPkLA5DK2BADhoeotPk.flac",
            canonicalID: canonical
        ))
    }

    @Test func coverArtReencodingIsNotAnArtworkChange() {
        #expect(SubsonicSongIdentityCarryPolicy.isCanonicalCoverArtRekey(
            previousReference: "subsonic-cover/mf-\(legacyID)_65f1a2b3",
            currentReference: "subsonic-cover/mf-\(migratedID)_65f1a2b3",
            canonicalID: canonical
        ))
        #expect(!SubsonicSongIdentityCarryPolicy.isCanonicalCoverArtRekey(
            previousReference: "subsonic-cover/mf-\(legacyID)_65f1a2b3",
            currentReference: "subsonic-cover/mf-\(migratedID)_65f1a2b4",
            canonicalID: canonical
        ))
        #expect(!SubsonicSongIdentityCarryPolicy.isCanonicalCoverArtRekey(
            previousReference: "subsonic-cover/mf-\(legacyID)_65f1a2b3",
            currentReference: "subsonic-cover/al-\(migratedID)_65f1a2b3",
            canonicalID: canonical
        ))
        #expect(!SubsonicSongIdentityCarryPolicy.isCanonicalCoverArtRekey(
            previousReference: "subsonic-cover/al-5cLJPkLA5DK2BADhoeotPk_1",
            currentReference: "subsonic-cover/al-5cLJPkLA5DK2BADhoeotPk_2",
            canonicalID: canonical
        ))
    }

    @Test func reencodedCacheFollowsOnlyWhenTheSizeAgrees() {
        #expect(SourceStableCacheTransitionPolicy.decision(
            previousPath: "/songs/\(legacyID).flac",
            currentPath: "/songs/\(migratedID).flac",
            previousRevision: nil,
            currentRevision: nil,
            previousSize: 4_096,
            currentSize: 4_096,
            serverRekeyedSameObject: true
        ) == .migrate)
        #expect(SourceStableCacheTransitionPolicy.decision(
            previousPath: "/songs/\(legacyID).flac",
            currentPath: "/songs/\(migratedID).flac",
            previousRevision: nil,
            currentRevision: nil,
            previousSize: 4_096,
            currentSize: 8_192,
            serverRekeyedSameObject: true
        ) == .invalidate)
        #expect(SourceStableCacheTransitionPolicy.decision(
            previousPath: "/songs/\(legacyID).flac",
            currentPath: "/songs/\(migratedID).flac",
            previousRevision: nil,
            currentRevision: nil,
            previousSize: 4_096,
            currentSize: 4_096
        ) == .invalidate)
    }
}
