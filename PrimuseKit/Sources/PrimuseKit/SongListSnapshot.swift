import Foundation
import os

private enum SongListSnapshotPerformance {
    static let signposter = OSSignposter(
        subsystem: "com.primuse.performance",
        category: "SongList"
    )
}

public enum LibrarySongSortOrder: String, CaseIterable, Hashable, Sendable {
    case title
    case artist
    case album
    case dateAdded
    case format
}

/// Generation-bound UI state for an explicit song-list sort. The state stays
/// active after the worker finishes when publication is deferred by scrolling,
/// and ignores stale callbacks from superseded requests.
public struct SongListSortProgressState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case requested
        case waitingForPublication
        case published
    }

    public private(set) var phase: Phase = .idle
    public private(set) var generation: Int?
    public private(set) var order: LibrarySongSortOrder?
    public private(set) var isVisible = false

    public init() {}

    public static func acceptsChange(
        from current: LibrarySongSortOrder,
        to requested: LibrarySongSortOrder
    ) -> Bool {
        current != requested
    }

    /// Returns true when an already-visible indicator should update in place
    /// for a latest-wins request instead of restarting its reveal delay.
    @discardableResult
    public mutating func begin(
        generation: Int,
        order: LibrarySongSortOrder
    ) -> Bool {
        let keepsVisibleIndicator = isVisible
        self.generation = generation
        self.order = order
        phase = .requested
        isVisible = keepsVisibleIndicator
        return keepsVisibleIndicator
    }

    /// Returns true exactly once when the delayed indicator becomes visible.
    @discardableResult
    public mutating func reveal(generation: Int) -> Bool {
        guard self.generation == generation,
              phase == .requested || phase == .waitingForPublication,
              !isVisible else {
            return false
        }
        isVisible = true
        return true
    }

    @discardableResult
    public mutating func markWaitingForPublication(generation: Int) -> Bool {
        guard self.generation == generation,
              phase == .requested || phase == .waitingForPublication else {
            return false
        }
        phase = .waitingForPublication
        return true
    }

    /// Returns whether a visible status should receive a completion announcement.
    @discardableResult
    public mutating func markPublished(generation: Int) -> Bool {
        guard self.generation == generation,
              phase == .requested || phase == .waitingForPublication else {
            return false
        }
        phase = .published
        return isVisible
    }

    @discardableResult
    public mutating func finish(generation: Int) -> Bool {
        guard self.generation == generation, phase == .published else { return false }
        self = SongListSortProgressState()
        return true
    }

    @discardableResult
    public mutating func cancel(generation: Int) -> Bool {
        guard self.generation == generation else { return false }
        self = SongListSortProgressState()
        return true
    }
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
        let task: Task<SongListSnapshot?, Never>
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
        songs: [Song],
        cancelSuperseded: Bool = false
    ) async -> SongListSnapshot? {
        prepareScope(scopeKey, for: version)

        let key = Key(scopeKey: scopeKey, version: version, order: order)
        if cancelSuperseded {
            cancelPending(in: scopeKey, except: key)
        }
        if let cached = cachedByKey[key] {
            SongListSnapshotPerformance.signposter.emitEvent(
                "SnapshotCacheHit",
                "scope: \(scopeKey, privacy: .public), order: \(order.rawValue, privacy: .public)"
            )
            return cached
        }
        if let pending = pendingByKey[key] {
            SongListSnapshotPerformance.signposter.emitEvent(
                "SnapshotPendingJoined",
                "scope: \(scopeKey, privacy: .public), order: \(order.rawValue, privacy: .public)"
            )
            return await pending.task.value
        }

        SongListSnapshotPerformance.signposter.emitEvent(
            "SnapshotCacheMiss",
            "scope: \(scopeKey, privacy: .public), order: \(order.rawValue, privacy: .public), count: \(songs.count, privacy: .public)"
        )
        let token = UUID()
        let task = Task.detached(priority: .userInitiated) { () -> SongListSnapshot? in
            do {
                return try SongListSnapshotBuilder.buildCancellable(songs: songs, order: order)
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }
        pendingByKey[key] = PendingEntry(token: token, task: task)

        let prepared = await task.value
        let isCurrentTask = pendingByKey[key]?.token == token
        if isCurrentTask {
            pendingByKey[key] = nil
        }
        if let prepared,
           versionByScope[scopeKey] == version,
           isCurrentTask {
            cachedByKey[key] = prepared
        }
        return prepared
    }

    /// Explicit UI cancellation (selection entry, navigation, or a newer sort)
    /// reaches the detached worker instead of only cancelling its waiter.
    public func cancelPending(scopeKey: String) {
        cancelPending(in: scopeKey, except: nil)
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

    private func cancelPending(in scopeKey: String, except retainedKey: Key?) {
        let supersededKeys = pendingByKey.keys.filter {
            $0.scopeKey == scopeKey && $0 != retainedKey
        }
        for key in supersededKeys {
            pendingByKey.removeValue(forKey: key)?.task.cancel()
            SongListSnapshotPerformance.signposter.emitEvent(
                "SnapshotWorkerCancelled",
                "scope: \(scopeKey, privacy: .public), order: \(key.order.rawValue, privacy: .public)"
            )
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
        // The non-throwing entry point remains useful for deterministic unit
        // construction. Store workers use the cancellable variant below.
        try! build(songs: songs, order: order, checkCancellation: {})
    }

    /// A cooperative merge sort lets a rapid order switch stop obsolete CPU
    /// work. Swift's standard `sort` has no cancellation points once started.
    public static func buildCancellable(
        songs: [Song],
        order: LibrarySongSortOrder
    ) throws -> SongListSnapshot {
        try build(
            songs: songs,
            order: order,
            checkCancellation: { try Task.checkCancellation() }
        )
    }

    private static func build(
        songs: [Song],
        order: LibrarySongSortOrder,
        checkCancellation: () throws -> Void
    ) throws -> SongListSnapshot {
        let interval = SongListSnapshotPerformance.signposter.beginInterval(
            "SnapshotBuild",
            "count: \(songs.count, privacy: .public), order: \(order.rawValue, privacy: .public)"
        )
        do {
            try checkCancellation()
            let orderedIndices = try sortedIndices(
                songs: songs,
                order: order,
                checkCancellation: checkCancellation
            )

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
                if offset.isMultiple(of: 1_024) {
                    try checkCancellation()
                }
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

            let snapshot = SongListSnapshot(
                rows: rows,
                orderedSongIDs: orderedSongIDs,
                songIDs: songIDs,
                sourceCounts: sourceCounts,
                playableCount: playableCount,
                totalDuration: totalDuration
            )
            SongListSnapshotPerformance.signposter.endInterval(
                "SnapshotBuild",
                interval,
                "cancelled: false"
            )
            return snapshot
        } catch {
            SongListSnapshotPerformance.signposter.endInterval(
                "SnapshotBuild",
                interval,
                "cancelled: true"
            )
            throw error
        }
    }

    private static func sortedIndices(
        songs: [Song],
        order: LibrarySongSortOrder,
        checkCancellation: () throws -> Void
    ) throws -> [Int] {
        guard songs.count > 1 else { return Array(songs.indices) }

        var source = Array(songs.indices)
        var destination = source
        var width = 1
        while width < source.count {
            try checkCancellation()
            var lowerBound = 0
            while lowerBound < source.count {
                if lowerBound.isMultiple(of: 4_096) {
                    try checkCancellation()
                }
                let midpoint = min(lowerBound + width, source.count)
                let upperBound = min(lowerBound + (width * 2), source.count)
                var left = lowerBound
                var right = midpoint

                for destinationIndex in lowerBound..<upperBound {
                    if destinationIndex.isMultiple(of: 2_048) {
                        try checkCancellation()
                    }
                    if left >= midpoint {
                        destination[destinationIndex] = source[right]
                        right += 1
                    } else if right >= upperBound {
                        destination[destinationIndex] = source[left]
                        left += 1
                    } else if isOrderedBefore(
                        source[right],
                        source[left],
                        songs: songs,
                        order: order
                    ) {
                        destination[destinationIndex] = source[right]
                        right += 1
                    } else {
                        destination[destinationIndex] = source[left]
                        left += 1
                    }
                }
                lowerBound = upperBound
            }
            swap(&source, &destination)
            width *= 2
        }
        return source
    }

    private static func isOrderedBefore(
        _ lhsIndex: Int,
        _ rhsIndex: Int,
        songs: [Song],
        order: LibrarySongSortOrder
    ) -> Bool {
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
}
