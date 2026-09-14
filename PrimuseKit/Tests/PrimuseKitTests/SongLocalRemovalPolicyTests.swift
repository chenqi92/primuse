import Foundation
import Testing
@testable import PrimuseKit

struct SongLocalRemovalPolicyTests {
    @Test func everyConfiguredSourceOffersTheLocalFallback() {
        // A protocol with no delete verb and a mount whose account was refused
        // are the same situation to the user, so the offer is not gated on the
        // source type. Only "no source at all" has nothing to offer.
        for type in MusicSourceType.allCases {
            #expect(SongLocalRemovalPolicy.offersLocalRemoval(for: type))
        }
        #expect(!SongLocalRemovalPolicy.offersLocalRemoval(for: nil))
    }

    @Test func readOnlyCataloguesRecordTheUnsupportedReason() {
        for type in [
            MusicSourceType.navidrome, .subsonic, .airsonic, .gonic,
            .upnp, .fnMusic, .daoliyu, .songloft, .appleMusicLibrary,
        ] {
            #expect(
                SongLocalRemovalPolicy.reasonWithoutRemoteDeletion(for: type)
                    == .sourceDoesNotSupportDeletion
            )
            #expect(!SongLocalRemovalPolicy.canDeleteRemoteFile(for: type))
        }
    }

    @Test func deletableSourcesRecordAUserChoice() {
        for type in [MusicSourceType.webdav, .smb, .local, .s3, .dropbox] {
            #expect(
                SongLocalRemovalPolicy.reasonWithoutRemoteDeletion(for: type)
                    == .userKeptRemoteFile
            )
        }
    }

    @Test func onlyPermanentRefusalsMayBeResolvedLocally() {
        // 403 → permissionDenied, 405 / read-only export → readOnly. Those are
        // the outcomes where the file is known to stay put and a retry cannot
        // change anything.
        #expect(SongLocalRemovalPolicy.canResolveLocally(failureReasons: [.permissionDenied]))
        #expect(SongLocalRemovalPolicy.canResolveLocally(failureReasons: [.readOnly]))
        #expect(SongLocalRemovalPolicy.canResolveLocally(
            failureReasons: [.permissionDenied, .readOnly]
        ))
        // 401, timeouts and unknown errors stay retry-only.
        #expect(!SongLocalRemovalPolicy.canResolveLocally(failureReasons: [.authenticationRequired]))
        #expect(!SongLocalRemovalPolicy.canResolveLocally(failureReasons: [.unavailable]))
        #expect(!SongLocalRemovalPolicy.canResolveLocally(failureReasons: [.other]))
        #expect(!SongLocalRemovalPolicy.canResolveLocally(
            failureReasons: [.permissionDenied, .unavailable]
        ))
        #expect(!SongLocalRemovalPolicy.canResolveLocally(failureReasons: []))
    }

    @Test func entriesAreListedNewestFirst() {
        let old = SongLocalRemovalEntry(
            song: makeSong(index: 1),
            reason: .remoteDeletionDenied,
            removedAt: Date(timeIntervalSince1970: 1_000)
        )
        let recent = SongLocalRemovalEntry(
            song: makeSong(index: 2),
            reason: .sourceDoesNotSupportDeletion,
            removedAt: Date(timeIntervalSince1970: 2_000)
        )
        #expect(SongLocalRemovalPolicy.sorted([old, recent]).map(\.id) == [recent.id, old.id])
    }

    @Test func ledgerEntriesSurviveAnEncodeDecodeRoundTrip() {
        let entry = SongLocalRemovalEntry(
            song: makeSong(index: 3),
            reason: .remoteDeletionDenied,
            removedAt: Date(timeIntervalSince1970: 1_700_000_000),
            detail: "403 Forbidden"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try! encoder.encode([entry])
        let restored = try! decoder.decode([SongLocalRemovalEntry].self, from: data)
        #expect(restored == [entry])
        #expect(restored.first?.sourceID == entry.song.sourceID)
    }

    @Test func aVersion2LedgerKeepsItsRowsUnderTheLegacyReason() {
        // v2 files had exactly one producer: duplicate cleanup after a WebDAV
        // share refused DELETE. Upgrading must not drop those rows, and it must
        // not invent a removal date they never recorded.
        let legacy = SongLocalRemovalLedger(
            formatVersion: 2,
            identities: ["acct:/Music/a.mp3"],
            retainedSongs: [makeSong(index: 1)],
            entries: nil
        )
        let resolved = legacy.resolved()
        #expect(resolved.songs.keys.sorted() == ["song-1"])
        #expect(resolved.metadata["song-1"]?.reason == .remoteDeletionDenied)
        #expect(resolved.metadata["song-1"]?.removedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func version3EntriesWinOverTheCompatibilityCatalogue() {
        let song = makeSong(index: 2)
        let ledger = SongLocalRemovalLedger(
            identities: ["acct:/Music/b.mp3"],
            retainedSongs: [song],
            entries: [
                SongLocalRemovalEntry(
                    song: song,
                    reason: .sourceDoesNotSupportDeletion,
                    removedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )
        let resolved = ledger.resolved()
        #expect(resolved.metadata["song-2"]?.reason == .sourceDoesNotSupportDeletion)
        #expect(resolved.metadata["song-2"]?.removedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func theLedgerRoundTripsThroughTheCodersTheLibraryUses() {
        // MusicLibrary writes and reads this file with a plain JSONEncoder /
        // JSONDecoder. An `.iso8601` strategy would truncate `removedAt` to
        // whole seconds, so the ledger must never be routed through one.
        let ledger = SongLocalRemovalLedger(
            identities: ["acct:/Music/c.mp3"],
            entries: [
                SongLocalRemovalEntry(song: makeSong(index: 4), reason: .remoteDeletionDenied)
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let restored = try! JSONDecoder().decode(
            SongLocalRemovalLedger.self,
            from: try! encoder.encode(ledger)
        )
        #expect(restored == ledger)
    }

    @Test func writingV3AlsoLeavesTheCompatibilityCatalogueInPlace() {
        // A downgraded build reads `retainedSongs`; dropping it would make the
        // rows unrecoverable there.
        let entry = SongLocalRemovalEntry(
            song: makeSong(index: 3),
            reason: .userKeptRemoteFile
        )
        let ledger = SongLocalRemovalLedger(identities: ["k"], entries: [entry])
        #expect(ledger.retainedSongs?.map(\.id) == ["song-3"])
        #expect(ledger.formatVersion == SongLocalRemovalLedger.currentFormatVersion)
    }

    private func makeSong(index: Int) -> Song {
        Song(
            id: "song-\(index)",
            title: "Song \(index)",
            duration: 180,
            fileFormat: .mp3,
            filePath: "/Music/song-\(index).mp3",
            sourceID: "source",
            fileSize: 1_024,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            revision: "r1"
        )
    }
}
