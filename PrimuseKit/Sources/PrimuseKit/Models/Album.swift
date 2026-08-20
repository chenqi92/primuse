import Foundation
import GRDB

public struct Album: Codable, Identifiable, Hashable, Sendable {
    public var id: String // SHA256 of album artist name + album title
    public var title: String
    public var artistID: String?
    public var artistName: String?
    public var year: Int?
    public var genre: String?
    public var coverArtPath: String?
    public var songCount: Int
    public var totalDuration: TimeInterval
    public var sourceID: String?

    public init(
        id: String,
        title: String,
        artistID: String? = nil,
        artistName: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        coverArtPath: String? = nil,
        songCount: Int = 0,
        totalDuration: TimeInterval = 0,
        sourceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistID = artistID
        self.artistName = artistName
        self.year = year
        self.genre = genre
        self.coverArtPath = coverArtPath
        self.songCount = songCount
        self.totalDuration = totalDuration
        self.sourceID = sourceID
    }
}

extension Album: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "albums" }
}

public enum AlbumArtworkFallbackPolicy {
    public static func preferredSongID(
        orderedSongIDs: [String],
        songIDsWithArtworkReference: Set<String>
    ) -> String? {
        let eligibleSongIDs = orderedSongIDs.filter { !$0.isEmpty }
        return eligibleSongIDs.first(where: songIDsWithArtworkReference.contains)
            ?? eligibleSongIDs.first
    }
}

public struct LibraryArtworkOwner: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case album
        case playlist
    }

    public static let cloudRecordIDPrefix = "__artwork_override__"

    public let kind: Kind
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public var storageKey: String {
        "\(kind.rawValue):\(id)"
    }

    /// Artwork overrides reuse the already-deployed Playlist CloudKit record
    /// type. A reserved local-ID prefix keeps them out of the user's playlist
    /// collection while avoiding a production schema dependency on a new
    /// record type.
    public var cloudRecordID: String {
        "\(Self.cloudRecordIDPrefix):\(kind.rawValue):\(id)"
    }

    public static func fromCloudRecordID(_ value: String) -> LibraryArtworkOwner? {
        let prefix = "\(cloudRecordIDPrefix):"
        guard value.hasPrefix(prefix) else { return nil }
        let remainder = value.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        let kindValue = String(remainder[..<separator])
        let ownerID = String(remainder[remainder.index(after: separator)...])
        guard let kind = Kind(rawValue: kindValue), !ownerID.isEmpty else { return nil }
        return LibraryArtworkOwner(kind: kind, id: ownerID)
    }
}

public enum LibraryArtworkOverrideMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case selectedSong
    case uploaded
}

/// A durable user choice layered above source-provided artwork. Image bytes
/// remain in MetadataAssetStore; this value stores only the content identity or
/// a cross-device song identity.
public struct LibraryArtworkOverride: Codable, Hashable, Identifiable, Sendable {
    public var owner: LibraryArtworkOwner
    public var mode: LibraryArtworkOverrideMode
    public var selectedSongIdentity: SongIdentity?
    public var uploadedContentID: String?
    public var updatedAt: Date
    public var syncRevision: Int64
    public var syncWriterID: String
    public var syncOperationID: String

    public var id: String { owner.storageKey }
    public var cloudRecordID: String { owner.cloudRecordID }

    public init(
        owner: LibraryArtworkOwner,
        mode: LibraryArtworkOverrideMode,
        selectedSongIdentity: SongIdentity? = nil,
        uploadedContentID: String? = nil,
        updatedAt: Date = Date(),
        syncRevision: Int64 = 0,
        syncWriterID: String = "",
        syncOperationID: String = ""
    ) {
        self.owner = owner
        self.mode = mode
        self.selectedSongIdentity = selectedSongIdentity
        self.uploadedContentID = uploadedContentID
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
        self.syncWriterID = syncWriterID
        self.syncOperationID = syncOperationID
    }
}

public enum LibraryArtworkOverrideResolution: Equatable, Sendable {
    case automatic
    case selectedSong(String)
    case uploaded(String)
}

public enum LibraryArtworkContentIDPolicy {
    public static let maximumSyncedArtworkBytes = 600_000

    public static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum LibraryArtworkOverridePolicy {
    public static func resolve(
        override: LibraryArtworkOverride?,
        resolveSelectedSong: () -> (songID: String, isEligible: Bool)?
    ) -> LibraryArtworkOverrideResolution {
        guard let override else { return .automatic }
        switch override.mode {
        case .automatic:
            return .automatic
        case .selectedSong:
            guard let selectedSong = resolveSelectedSong(),
                  !selectedSong.songID.isEmpty,
                  selectedSong.isEligible else {
                return .automatic
            }
            return .selectedSong(selectedSong.songID)
        case .uploaded:
            guard let contentID = override.uploadedContentID,
                  LibraryArtworkContentIDPolicy.isValid(contentID) else {
                return .automatic
            }
            return .uploaded(contentID)
        }
    }

    public static func resolve(
        override: LibraryArtworkOverride?,
        resolvedSongID: String?,
        eligibleSongIDs: Set<String>
    ) -> LibraryArtworkOverrideResolution {
        resolve(override: override) {
            guard let resolvedSongID else { return nil }
            return (
                songID: resolvedSongID,
                isEligible: eligibleSongIDs.contains(resolvedSongID)
            )
        }
    }
}

public enum LibraryArtworkOverrideConflictWinner: Equatable, Sendable {
    case local
    case remote
}

public enum LibraryArtworkOverrideReconciliationPolicy {
    public static func winner(
        local: LibraryArtworkOverride,
        remote: LibraryArtworkOverride
    ) -> LibraryArtworkOverrideConflictWinner {
        precondition(local.owner == remote.owner)
        if local.syncRevision != remote.syncRevision {
            return local.syncRevision > remote.syncRevision ? .local : .remote
        }
        if local.syncWriterID != remote.syncWriterID {
            return local.syncWriterID > remote.syncWriterID ? .local : .remote
        }
        if local.syncOperationID != remote.syncOperationID {
            return local.syncOperationID > remote.syncOperationID ? .local : .remote
        }
        if local.syncRevision == 0, local.updatedAt != remote.updatedAt {
            return local.updatedAt > remote.updatedAt ? .local : .remote
        }
        return .local
    }
}

/// Stored in the Playlist record type's existing `songIdentities` Data field.
/// Keeping uploaded data bounded lets deployed CloudKit schemas accept the
/// envelope without introducing a new field or record type.
public struct LibraryArtworkCloudEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var override: LibraryArtworkOverride
    public var uploadedArtworkData: Data?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        override: LibraryArtworkOverride,
        uploadedArtworkData: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.override = override
        self.uploadedArtworkData = uploadedArtworkData
    }
}
