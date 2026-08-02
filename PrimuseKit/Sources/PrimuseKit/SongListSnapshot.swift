import Foundation

public enum LibrarySongSortOrder: String, CaseIterable, Hashable, Sendable {
    case title
    case artist
    case album
    case dateAdded
    case format
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
        var orderedSongs = songs
        orderedSongs.sort { lhs, rhs in
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
        rows.reserveCapacity(orderedSongs.count)
        orderedSongIDs.reserveCapacity(orderedSongs.count)
        songIDs.reserveCapacity(orderedSongs.count)

        for (offset, song) in orderedSongs.enumerated() {
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
