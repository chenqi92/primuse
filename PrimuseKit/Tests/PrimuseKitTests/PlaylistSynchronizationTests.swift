import Foundation
import GRDB
import Testing
@testable import PrimuseKit

@Suite("Playlist deletion synchronization")
struct PlaylistSynchronizationTests {
    @Test("A tombstone beats an unrelated active update regardless of clock or revision")
    func deletionBeatsLateActiveSnapshot() {
        let tombstone = makePlaylist(
            deleted: true,
            revision: 2,
            writer: "phone",
            operation: "delete",
            deleteOperation: "delete-1",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let lateOfflineEdit = makePlaylist(
            deleted: false,
            revision: 99,
            writer: "offline-device",
            operation: "edit",
            updatedAt: Date(timeIntervalSince1970: 9_999_999)
        )

        #expect(PlaylistReconciliationPolicy.winner(
            local: tombstone,
            remote: lateOfflineEdit
        ) == .local)
    }

    @Test("Only an explicit restore of the exact delete operation revives a playlist")
    func explicitRestoreWins() {
        let tombstone = makePlaylist(
            deleted: true,
            revision: 7,
            writer: "phone",
            operation: "delete",
            deleteOperation: "delete-7"
        )
        let restored = makePlaylist(
            deleted: false,
            revision: 8,
            writer: "phone",
            operation: "restore",
            restoredDeleteOperation: "delete-7"
        )

        #expect(PlaylistReconciliationPolicy.winner(local: tombstone, remote: restored) == .remote)
        #expect(PlaylistReconciliationPolicy.winner(local: restored, remote: tombstone) == .local)
    }

    @Test("A restore cannot supersede a different or newer deletion")
    func unrelatedRestoreLoses() {
        let newerDeletion = makePlaylist(
            deleted: true,
            revision: 9,
            writer: "tablet",
            operation: "delete-again",
            deleteOperation: "delete-9"
        )
        let staleRestore = makePlaylist(
            deleted: false,
            revision: 20,
            writer: "phone",
            operation: "restore-old",
            restoredDeleteOperation: "delete-7"
        )

        #expect(PlaylistReconciliationPolicy.winner(
            local: newerDeletion,
            remote: staleRestore
        ) == .local)
    }

    @Test("Duplicate and concurrent events resolve deterministically")
    func eventsAreIdempotentAndDeterministic() {
        let left = makePlaylist(
            deleted: true,
            revision: 4,
            writer: "a",
            operation: "same",
            deleteOperation: "delete-a"
        )
        let duplicate = left
        let right = makePlaylist(
            deleted: true,
            revision: 4,
            writer: "b",
            operation: "same",
            deleteOperation: "delete-b"
        )

        #expect(PlaylistReconciliationPolicy.winner(local: left, remote: duplicate) == .local)
        #expect(PlaylistReconciliationPolicy.winner(local: left, remote: right) == .remote)
        #expect(PlaylistReconciliationPolicy.winner(local: right, remote: left) == .local)
    }

    @Test("Old JSON remains active while a CloudKit envelope preserves the tombstone")
    func jsonAndCloudEnvelopeMigration() throws {
        let legacy = """
        {"id":"playlist","name":"Legacy","createdAt":0,"updatedAt":1}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let migrated = try decoder.decode(Playlist.self, from: legacy)
        #expect(!migrated.isDeleted)
        #expect(migrated.syncRevision == 0)
        #expect(!migrated.hasDedicatedCoverArt)

        let tombstone = makePlaylist(
            deleted: true,
            revision: 5,
            writer: "phone",
            operation: "delete",
            deleteOperation: "delete-5"
        )
        let envelope = PlaylistCloudSyncEnvelope(playlist: tombstone, songIdentities: [])
        let roundTrip = try JSONDecoder().decode(
            PlaylistCloudSyncEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )
        #expect(roundTrip == envelope)
        #expect(roundTrip.playlist.deleteOperationID == "delete-5")
    }

    @Test("SQLite migration preserves old rows and persists tombstones")
    func sqliteMigration() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: Playlist.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("coverArtPath", .text)
            }
            try db.execute(
                sql: "INSERT INTO playlists (id, name, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: ["legacy", "Legacy", Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1)]
            )
            try PlaylistDatabaseMigration.migrate(db)

            let legacy = try Playlist.fetchOne(db, key: "legacy")
            #expect(legacy?.isDeleted == false)
            #expect(legacy?.syncRevision == 0)
            #expect(legacy?.hasDedicatedCoverArt == false)

            let tombstone = makePlaylist(
                id: "deleted",
                deleted: true,
                revision: 3,
                writer: "phone",
                operation: "delete",
                deleteOperation: "delete-3"
            )
            try tombstone.save(db)
            let stored = try Playlist.fetchOne(db, key: "deleted")
            #expect(stored?.isDeleted == true)
            #expect(stored?.deleteOperationID == "delete-3")
        }
    }

    @Test("Mirror rebuild keeps the same ID hidden, accepts a new ID, and restores without deleting songs")
    func mirrorRebuildAndRestore() {
        let hiddenID = ServerPlaylistIdentity.playlistID(
            sourceID: "source-a",
            serverPlaylistID: "remote-1"
        )
        let replacementID = ServerPlaylistIdentity.playlistID(
            sourceID: "source-a",
            serverPlaylistID: "remote-2"
        )
        let hiddenKey = MirrorPlaylistSuppressionPolicy.key(forPlaylistID: hiddenID)!
        let songCatalog = ["song-1", "song-2"]
        let memberships = [
            hiddenID: songCatalog,
            replacementID: ["song-2"],
        ]
        var suppressed: Set<MirrorPlaylistSuppressionKey> = [hiddenKey]

        let firstFullSnapshot = [hiddenID]
        let firstVisible = firstFullSnapshot.filter {
            !MirrorPlaylistSuppressionPolicy.isSuppressed(
                playlistID: $0,
                suppressions: suppressed
            )
        }
        #expect(firstVisible.isEmpty)

        let secondFullSnapshot = [hiddenID, replacementID]
        let secondVisible = secondFullSnapshot.filter {
            !MirrorPlaylistSuppressionPolicy.isSuppressed(
                playlistID: $0,
                suppressions: suppressed
            )
        }
        #expect(secondVisible == [replacementID])

        suppressed.remove(hiddenKey)
        let restoredVisible = secondFullSnapshot.filter {
            !MirrorPlaylistSuppressionPolicy.isSuppressed(
                playlistID: $0,
                suppressions: suppressed
            )
        }
        #expect(restoredVisible == secondFullSnapshot)
        #expect(songCatalog == ["song-1", "song-2"])
        #expect(memberships[hiddenID] == songCatalog)
        #expect(memberships[replacementID] == ["song-2"])
        #expect(MirrorPlaylistSuppressionPolicy.key(
            forPlaylistID: AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.123"
        )?.remotePlaylistID == "p.123")
    }

    private func makePlaylist(
        id: String = "playlist",
        deleted: Bool,
        revision: Int64,
        writer: String,
        operation: String,
        deleteOperation: String? = nil,
        restoredDeleteOperation: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> Playlist {
        Playlist(
            id: id,
            name: "Playlist",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: updatedAt,
            isDeleted: deleted,
            deletedAt: deleted ? updatedAt : nil,
            syncRevision: revision,
            syncWriterID: writer,
            syncOperationID: operation,
            deleteOperationID: deleteOperation,
            restoredDeleteOperationID: restoredDeleteOperation
        )
    }
}
