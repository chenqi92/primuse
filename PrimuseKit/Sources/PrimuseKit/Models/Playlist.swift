import Foundation
import GRDB

public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var coverArtPath: String?
    /// `coverArtPath` is an upstream or user-provided playlist image rather
    /// than the legacy automatic copy of a member song's cover reference.
    /// Older snapshots decode this as `false`, so stale first-song artwork is
    /// never mistaken for a dedicated playlist cover after upgrading.
    public var hasDedicatedCoverArt: Bool
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
        hasDedicatedCoverArt: Bool = false,
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
        self.hasDedicatedCoverArt = hasDedicatedCoverArt
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
        self.hasDedicatedCoverArt = try c.decodeIfPresent(
            Bool.self,
            forKey: .hasDedicatedCoverArt
        ) ?? false
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

/// A platform-neutral artwork candidate for a playlist. The policy intentionally
/// describes *what* should be tried without claiming that a non-empty reference
/// is displayable. App targets still have to resolve the candidate through their
/// real cache, source connector, or MusicKit loader.
public struct PlaylistArtworkCandidate: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case dedicated
        case song
    }

    public let kind: Kind
    public let id: String
    public let songID: String?
    public let artworkReference: String?

    public init(
        kind: Kind,
        id: String,
        songID: String? = nil,
        artworkReference: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.songID = songID
        self.artworkReference = artworkReference
    }
}

public struct PlaylistArtworkResolutionPlan: Equatable, Sendable {
    /// Changes when the playlist ID, dedicated artwork, membership, or any
    /// member's artwork-loading identity changes. It is deterministic across
    /// launches and Apple platforms (unlike Swift's randomized `Hasher`).
    public let signature: String
    public let candidates: [PlaylistArtworkCandidate]

    public init(signature: String, candidates: [PlaylistArtworkCandidate]) {
        self.signature = signature
        self.candidates = candidates
    }
}

public struct PlaylistArtworkResolution<Value> {
    public let candidate: PlaylistArtworkCandidate
    public let value: Value

    public init(candidate: PlaylistArtworkCandidate, value: Value) {
        self.candidate = candidate
        self.value = value
    }
}

/// Shared ordering policy used by iPhone, iPad, macOS, and tvOS playlist art.
///
/// A dedicated playlist/source image is always attempted first. Song candidates
/// are then arranged with a stable pseudo-random rank derived from the playlist
/// ID and the complete member/artwork set. Input order therefore cannot silently
/// turn the first track into the cover, while membership or artwork changes are
/// allowed to produce a new deterministic choice.
public enum PlaylistArtworkResolutionPolicy {
    public static func makePlan(playlist: Playlist, songs: [Song]) -> PlaylistArtworkResolutionPlan {
        var seenSongIDs = Set<String>()
        let songCandidates = songs.compactMap { song -> PlaylistArtworkCandidate? in
            guard !song.id.isEmpty, seenSongIDs.insert(song.id).inserted else { return nil }
            let reference = cleaned(song.coverArtFileName)
            let identity = [
                "song",
                song.id,
                reference ?? "",
                song.sourceID,
                song.filePath,
                song.fileFormat.rawValue,
            ].joined(separator: "\u{1F}")
            return PlaylistArtworkCandidate(
                kind: .song,
                id: identity,
                songID: song.id,
                artworkReference: reference
            )
        }

        let dedicatedReference = playlist.hasDedicatedCoverArt
            ? cleaned(playlist.coverArtPath)
            : nil

        let memberSet = songCandidates.map(\.id).sorted()
        let seedMaterial = ([playlist.id, dedicatedReference ?? ""] + memberSet)
            .joined(separator: "\u{0}")
        // FNV-1a is incremental. Hash the shared member seed once, then extend
        // it with each candidate ID before sorting. The previous comparator
        // rebuilt and re-hashed the complete playlist twice for every
        // comparison, which made rendering a playlist cover grow roughly with
        // the square of its song count on the main actor.
        let candidateHashSeed = stableHash("\u{0}", startingAt: stableHash(seedMaterial))
        let rankedSongs = songCandidates
            .map { candidate in
                (candidate: candidate, rank: stableHash(candidate.id, startingAt: candidateHashSeed))
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.candidate.id < rhs.candidate.id
            }
            .map(\.candidate)

        var candidates: [PlaylistArtworkCandidate] = []
        if let dedicatedReference {
            candidates.append(PlaylistArtworkCandidate(
                kind: .dedicated,
                id: "dedicated\u{1F}\(dedicatedReference)",
                artworkReference: dedicatedReference
            ))
        }
        candidates.append(contentsOf: rankedSongs)

        let signatureMaterial = ([playlist.id] + candidates.map(\.id)).joined(separator: "\u{0}")
        let signature = String(stableHash(signatureMaterial), radix: 16)
        return PlaylistArtworkResolutionPlan(signature: signature, candidates: candidates)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// FNV-1a has deliberately fixed constants and byte order, so its result is
    /// identical across processes and platforms. It is a selection hash, not a
    /// security primitive.
    private static func stableHash(
        _ value: String,
        startingAt initialHash: UInt64 = 14_695_981_039_346_656_037
    ) -> UInt64 {
        var hash = initialHash
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

/// Shared fallback runner. Each platform supplies its actual resource loader;
/// failed dedicated or song artwork automatically advances to the next stable
/// candidate instead of leaving a transparent result.
public enum PlaylistArtworkResolver {
    public static func resolve<Value>(
        plan: PlaylistArtworkResolutionPlan,
        isolation: isolated (any Actor)? = #isolation,
        using load: (PlaylistArtworkCandidate) async -> Value?
    ) async -> PlaylistArtworkResolution<Value>? {
        for candidate in plan.candidates {
            if Task.isCancelled { return nil }
            if let value = await load(candidate) {
                return PlaylistArtworkResolution(candidate: candidate, value: value)
            }
        }
        return nil
    }
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
            if !names.contains("hasDedicatedCoverArt") {
                table.add(column: "hasDedicatedCoverArt", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
        }
    }
}
