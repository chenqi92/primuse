import Foundation
import GRDB

public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var coverArtPath: String?
    /// Soft-delete flag. When true, the playlist is hidden from the regular UI
    /// but kept on disk + in CloudKit so other devices can converge before the
    /// 30-day prune sweeps it for good.
    public var isDeleted: Bool
    public var deletedAt: Date?
    /// Logical mutation version used for cross-device conflict resolution.
    /// Unlike `updatedAt`, this value is not affected by clock skew.
    public var syncRevision: Int64
    /// Stable installation identifier. It deterministically breaks ties when
    /// two offline devices advance the same logical revision.
    public var syncWriterID: String
    /// Unique, idempotent operation identifier for the latest mutation.
    public var syncOperationID: String
    /// Identity of the delete operation represented by this tombstone.
    public var deleteOperationID: String?
    /// An active record may supersede a tombstone only when it explicitly
    /// names the exact delete operation the user restored.
    public var restoredDeleteOperationID: String?
    /// Compacted tombstones no longer retain playlist membership, but remain
    /// syncable indefinitely so a long-offline device cannot resurrect them.
    public var isPurged: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        coverArtPath: String? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        syncRevision: Int64 = 0,
        syncWriterID: String = "",
        syncOperationID: String = "",
        deleteOperationID: String? = nil,
        restoredDeleteOperationID: String? = nil,
        isPurged: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverArtPath = coverArtPath
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.syncRevision = syncRevision
        self.syncWriterID = syncWriterID
        self.syncOperationID = syncOperationID
        self.deleteOperationID = deleteOperationID
        self.restoredDeleteOperationID = restoredDeleteOperationID
        self.isPurged = isPurged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.coverArtPath = try c.decodeIfPresent(String.self, forKey: .coverArtPath)
        self.isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.syncRevision = try c.decodeIfPresent(Int64.self, forKey: .syncRevision) ?? 0
        self.syncWriterID = try c.decodeIfPresent(String.self, forKey: .syncWriterID) ?? ""
        self.syncOperationID = try c.decodeIfPresent(String.self, forKey: .syncOperationID) ?? ""
        self.deleteOperationID = try c.decodeIfPresent(String.self, forKey: .deleteOperationID)
        self.restoredDeleteOperationID = try c.decodeIfPresent(String.self, forKey: .restoredDeleteOperationID)
        self.isPurged = try c.decodeIfPresent(Bool.self, forKey: .isPurged) ?? false
    }
}

extension Playlist: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "playlists" }
}

public struct PlaylistSong: Codable, Sendable {
    public var playlistID: String
    public var songID: String
    public var sortOrder: Int

    public init(playlistID: String, songID: String, sortOrder: Int) {
        self.playlistID = playlistID
        self.songID = songID
        self.sortOrder = sortOrder
    }
}

extension PlaylistSong: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "playlistSongs" }
}

public enum PlaylistConflictWinner: Sendable, Equatable {
    case local
    case remote
}

/// Pure state-machine policy shared by CloudKit and persistence tests.
public enum PlaylistReconciliationPolicy {
    public static func winner(local: Playlist, remote: Playlist) -> PlaylistConflictWinner {
        precondition(local.id == remote.id)

        if local.isDeleted != remote.isDeleted {
            let deleted = local.isDeleted ? local : remote
            let active = local.isDeleted ? remote : local
            let isExplicitRestore = active.restoredDeleteOperationID != nil
                && active.restoredDeleteOperationID == deleted.deleteOperationID
                && compareVersion(active, deleted) == .orderedDescending
            if isExplicitRestore {
                return local.isDeleted ? .remote : .local
            }
            return local.isDeleted ? .local : .remote
        }

        if !local.isDeleted,
           (local.restoredDeleteOperationID == nil) != (remote.restoredDeleteOperationID == nil) {
            return local.restoredDeleteOperationID != nil ? .local : .remote
        }

        switch compareVersion(local, remote) {
        case .orderedAscending:
            return .remote
        case .orderedDescending:
            return .local
        case .orderedSame:
            if local.isPurged != remote.isPurged {
                return local.isPurged ? .local : .remote
            }
            return .local
        }
    }

    private static func compareVersion(_ lhs: Playlist, _ rhs: Playlist) -> ComparisonResult {
        if lhs.syncRevision != rhs.syncRevision {
            return lhs.syncRevision < rhs.syncRevision ? .orderedAscending : .orderedDescending
        }
        if lhs.syncWriterID != rhs.syncWriterID {
            return lhs.syncWriterID < rhs.syncWriterID ? .orderedAscending : .orderedDescending
        }
        if lhs.syncOperationID != rhs.syncOperationID {
            return lhs.syncOperationID < rhs.syncOperationID ? .orderedAscending : .orderedDescending
        }
        // Old snapshots have no logical version. Retain their historical
        // modified-at behavior only within that legacy cohort.
        if lhs.syncRevision == 0, lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

/// Versioned envelope stored in CloudKit's existing `songIdentities` Data
/// field. Reusing the deployed field keeps production schemas compatible.
public struct PlaylistCloudSyncEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var playlist: Playlist
    public var songIdentities: [SongIdentity]

    public init(playlist: Playlist, songIdentities: [SongIdentity]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.playlist = playlist
        self.songIdentities = songIdentities
    }
}

/// Adds deletion/mutation columns to the legacy SQLite playlist table without
/// rewriting existing rows. Defaults preserve old active playlists.
public enum PlaylistDatabaseMigration {
    public static func migrate(_ db: Database) throws {
        let names = Set(try db.columns(in: Playlist.databaseTableName).map(\.name))
        try db.alter(table: Playlist.databaseTableName) { table in
            if !names.contains("isDeleted") {
                table.add(column: "isDeleted", .boolean).notNull().defaults(to: false)
            }
            if !names.contains("deletedAt") { table.add(column: "deletedAt", .datetime) }
            if !names.contains("syncRevision") {
                table.add(column: "syncRevision", .integer).notNull().defaults(to: 0)
            }
            if !names.contains("syncWriterID") {
                table.add(column: "syncWriterID", .text).notNull().defaults(to: "")
            }
            if !names.contains("syncOperationID") {
                table.add(column: "syncOperationID", .text).notNull().defaults(to: "")
            }
            if !names.contains("deleteOperationID") { table.add(column: "deleteOperationID", .text) }
            if !names.contains("restoredDeleteOperationID") {
                table.add(column: "restoredDeleteOperationID", .text)
            }
            if !names.contains("isPurged") {
                table.add(column: "isPurged", .boolean).notNull().defaults(to: false)
            }
        }
    }
}
