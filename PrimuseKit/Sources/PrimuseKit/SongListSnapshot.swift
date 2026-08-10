import Foundation

public enum LibrarySongSortOrder: String, CaseIterable, Hashable, Sendable {
    case title
    case artist
    case album
    case dateAdded
    case format
}

public struct SongListSnapshotVersion: Hashable, Sendable {
    public let collectionRevision: Int
    public let replacementToken: UUID

    public init(collectionRevision: Int, replacementToken: UUID) {
        self.collectionRevision = collectionRevision
        self.replacementToken = replacementToken
    }
}

/// Keeps every visited ordering for the current version of a song-list scope.
/// Switching back to an earlier ordering can therefore reuse the immutable
/// result instead of repeating a full localized sort.
public actor SongListSnapshotStore {
    public static let shared = SongListSnapshotStore()
    public static let libraryScopeKey = "library"

    private struct Key: Hashable, Sendable {
        let scopeKey: String
        let version: SongListSnapshotVersion
        let order: LibrarySongSortOrder
    }

    private struct PendingEntry: Sendable {
        let token: UUID
        let task: Task<SongListSnapshot, Never>
    }

    private var versionByScope: [String: SongListSnapshotVersion] = [:]
    private var cachedByKey: [Key: SongListSnapshot] = [:]
    private var pendingByKey: [Key: PendingEntry] = [:]

    public init() {}

    public static func sourceScopeKey(_ sourceID: String) -> String {
        "source:\(sourceID)"
    }

    public func snapshot(
        scopeKey: String,
        version: SongListSnapshotVersion,
        order: LibrarySongSortOrder,
        songs: [Song]
    ) async -> SongListSnapshot {
        prepareScope(scopeKey, for: version)

        let key = Key(scopeKey: scopeKey, version: version, order: order)
        if let cached = cachedByKey[key] {
            return cached
        }
        if let pending = pendingByKey[key] {
            return await pending.task.value
        }

        let token = UUID()
        let task = Task.detached(priority: .userInitiated) {
            SongListSnapshotBuilder.build(songs: songs, order: order)
        }
        pendingByKey[key] = PendingEntry(token: token, task: task)

        let prepared = await task.value
        if versionByScope[scopeKey] == version,
           pendingByKey[key]?.token == token {
            cachedByKey[key] = prepared
            pendingByKey[key] = nil
        }
        return prepared
    }

    private func prepareScope(
        _ scopeKey: String,
        for version: SongListSnapshotVersion
    ) {
        guard versionByScope[scopeKey] != version else { return }
        versionByScope[scopeKey] = version

        cachedByKey = cachedByKey.filter { $0.key.scopeKey != scopeKey }
        let obsoletePendingKeys = pendingByKey.keys.filter { $0.scopeKey == scopeKey }
        for key in obsoletePendingKeys {
            pendingByKey.removeValue(forKey: key)?.task.cancel()
        }
    }
}

/// Lightweight identity consumed by large song lists. Keeping `Song` values
/// out of SwiftUI's structural data prevents equality checks from walking
/// large metadata fields such as `lyricsText`.
public struct SongListRowIdentity: Identifiable, Hashable, Sendable {
    public let id: String
    public let offset: Int

    public init(id: String, offset: Int) {
        self.id = id
        self.offset = offset
    }
}

/// Immutable, reference-backed result that can be built away from the main
/// actor and published to the UI with a single identity assignment.
public final class SongListSnapshot: Sendable {
    public let rows: [SongListRowIdentity]
    public let orderedSongIDs: [String]
    public let songIDs: Set<String>
    public let sourceCounts: [String: Int]
    public let playableCount: Int
    public let totalDuration: TimeInterval

    public init(
        rows: [SongListRowIdentity],
        orderedSongIDs: [String],
        songIDs: Set<String>,
        sourceCounts: [String: Int],
        playableCount: Int,
        totalDuration: TimeInterval
    ) {
        self.rows = rows
        self.orderedSongIDs = orderedSongIDs
        self.songIDs = songIDs
        self.sourceCounts = sourceCounts
        self.playableCount = playableCount
        self.totalDuration = totalDuration
    }
}

public enum SongListSnapshotBuilder {
    /// Sorting, aggregation, and membership-index construction are deliberately
    /// bundled into one worker operation so callers only publish the finished
    /// immutable reference on the main actor.
    public static func build(
        songs: [Song],
        order: LibrarySongSortOrder
    ) -> SongListSnapshot {
        // Sort lightweight indices rather than repeatedly moving complete Song
        // values (which may retain large lyrics and metadata payloads).
        var orderedIndices = Array(songs.indices)
        orderedIndices.sort { lhsIndex, rhsIndex in
            let lhs = songs[lhsIndex]
            let rhs = songs[rhsIndex]
            let comparison: ComparisonResult
            switch order {
            case .title:
                comparison = lhs.title.localizedCompare(rhs.title)
            case .artist:
                comparison = (lhs.artistName ?? "").localizedCompare(rhs.artistName ?? "")
            case .album:
                comparison = (lhs.albumTitle ?? "").localizedCompare(rhs.albumTitle ?? "")
            case .dateAdded:
                if lhs.dateAdded != rhs.dateAdded {
                    return lhs.dateAdded > rhs.dateAdded
                }
                comparison = .orderedSame
            case .format:
                comparison = lhs.fileFormat.displayName.compare(rhs.fileFormat.displayName)
            }

            if comparison == .orderedSame {
                return lhs.id < rhs.id
            }
            return comparison == .orderedAscending
        }

        var rows: [SongListRowIdentity] = []
        var orderedSongIDs: [String] = []
        var songIDs: Set<String> = []
        var sourceCounts: [String: Int] = [:]
        var playableCount = 0
        var totalDuration: TimeInterval = 0
        rows.reserveCapacity(orderedIndices.count)
        orderedSongIDs.reserveCapacity(orderedIndices.count)
        songIDs.reserveCapacity(orderedIndices.count)

        for (offset, songIndex) in orderedIndices.enumerated() {
            let song = songs[songIndex]
            rows.append(SongListRowIdentity(id: song.id, offset: offset))
            orderedSongIDs.append(song.id)
            songIDs.insert(song.id)
            sourceCounts[song.sourceID, default: 0] += 1
            if song.isPlayable {
                playableCount += 1
            }
            if song.duration.isFinite {
                totalDuration += max(0, song.duration)
            }
        }

        return SongListSnapshot(
            rows: rows,
            orderedSongIDs: orderedSongIDs,
            songIDs: songIDs,
            sourceCounts: sourceCounts,
            playableCount: playableCount,
            totalDuration: totalDuration
        )
    }
}
