import Foundation

/// Durable playback context used to reconstruct the queue after a process
/// restart. Queue positions are stored instead of song IDs alone because the
/// same song may intentionally appear more than once.
public struct PlaybackSessionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var queueSongIDs: [String]
    public var currentSongID: String
    public var currentIndex: Int
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var wasPlaying: Bool
    public var shuffleEnabled: Bool
    public var shuffledIndices: [Int]
    public var shufflePosition: Int
    public var pendingNextShuffleIndices: [Int]?
    public var repeatMode: RepeatMode
    public var isAtTrackEnd: Bool
    public var updatedAt: Date

    public init(
        version: Int = PlaybackSessionSnapshot.currentVersion,
        queueSongIDs: [String],
        currentSongID: String,
        currentIndex: Int,
        currentTime: TimeInterval,
        duration: TimeInterval,
        wasPlaying: Bool,
        shuffleEnabled: Bool,
        shuffledIndices: [Int],
        shufflePosition: Int,
        pendingNextShuffleIndices: [Int]? = nil,
        repeatMode: RepeatMode,
        isAtTrackEnd: Bool,
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.queueSongIDs = queueSongIDs
        self.currentSongID = currentSongID
        self.currentIndex = currentIndex
        self.currentTime = currentTime
        self.duration = duration
        self.wasPlaying = wasPlaying
        self.shuffleEnabled = shuffleEnabled
        self.shuffledIndices = shuffledIndices
        self.shufflePosition = shufflePosition
        self.pendingNextShuffleIndices = pendingNextShuffleIndices
        self.repeatMode = repeatMode
        self.isAtTrackEnd = isAtTrackEnd
        self.updatedAt = updatedAt
    }
}

/// A validated, library-aware playback session. Missing queue items are
/// removed while the current occurrence and the played/up-next shuffle split
/// remain stable.
public struct PlaybackSessionRestorationPlan: Equatable, Sendable {
    public var queueSongIDs: [String]
    public var currentIndex: Int
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var shuffleEnabled: Bool
    public var shuffledIndices: [Int]
    public var shufflePosition: Int
    public var pendingNextShuffleIndices: [Int]?
    public var repeatMode: RepeatMode
    public var isAtTrackEnd: Bool
}

public enum PlaybackSessionRestorationPolicy {
    public static func plan(
        snapshot: PlaybackSessionSnapshot,
        availableSongIDs: Set<String>
    ) -> PlaybackSessionRestorationPlan? {
        guard snapshot.version == PlaybackSessionSnapshot.currentVersion,
              snapshot.queueSongIDs.indices.contains(snapshot.currentIndex),
              snapshot.queueSongIDs[snapshot.currentIndex] == snapshot.currentSongID,
              availableSongIDs.contains(snapshot.currentSongID) else {
            return nil
        }

        var oldToNew: [Int: Int] = [:]
        var restoredIDs: [String] = []
        restoredIDs.reserveCapacity(snapshot.queueSongIDs.count)
        for (oldIndex, songID) in snapshot.queueSongIDs.enumerated()
            where availableSongIDs.contains(songID) {
            oldToNew[oldIndex] = restoredIDs.count
            restoredIDs.append(songID)
        }

        guard let restoredCurrentIndex = oldToNew[snapshot.currentIndex],
              !restoredIDs.isEmpty else {
            return nil
        }

        let shuffleOrder: [Int]
        let shufflePosition: Int
        let pendingOrder: [Int]?
        if snapshot.shuffleEnabled {
            let mappedOrder = snapshot.shuffledIndices.compactMap { oldToNew[$0] }
            let snapshotPointsAtCurrent = snapshot.shuffledIndices.indices.contains(snapshot.shufflePosition)
                && snapshot.shuffledIndices[snapshot.shufflePosition] == snapshot.currentIndex
            if snapshotPointsAtCurrent,
               isPermutation(mappedOrder, count: restoredIDs.count),
               let mappedPosition = mappedOrder.firstIndex(of: restoredCurrentIndex) {
                shuffleOrder = mappedOrder
                shufflePosition = mappedPosition
            } else {
                // Corrupt or legacy shuffle bookkeeping must never crash queue
                // traversal. Keep the selected track and build a deterministic
                // unplayed tail; a fresh random round starts after this one.
                shuffleOrder = [restoredCurrentIndex]
                    + (0..<restoredIDs.count).filter { $0 != restoredCurrentIndex }
                shufflePosition = 0
            }

            if let storedPending = snapshot.pendingNextShuffleIndices {
                let mappedPending = storedPending.compactMap { oldToNew[$0] }
                pendingOrder = isPermutation(mappedPending, count: restoredIDs.count)
                    ? mappedPending
                    : nil
            } else {
                pendingOrder = nil
            }
        } else {
            shuffleOrder = []
            shufflePosition = 0
            pendingOrder = nil
        }

        let safeDuration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        let unclampedTime = snapshot.currentTime.isFinite ? max(0, snapshot.currentTime) : 0
        let safeTime = safeDuration > 0 ? min(unclampedTime, safeDuration) : unclampedTime

        return PlaybackSessionRestorationPlan(
            queueSongIDs: restoredIDs,
            currentIndex: restoredCurrentIndex,
            currentTime: snapshot.isAtTrackEnd ? 0 : safeTime,
            duration: safeDuration,
            shuffleEnabled: snapshot.shuffleEnabled,
            shuffledIndices: shuffleOrder,
            shufflePosition: shufflePosition,
            pendingNextShuffleIndices: pendingOrder,
            repeatMode: snapshot.repeatMode,
            isAtTrackEnd: snapshot.isAtTrackEnd
        )
    }

    private static func isPermutation(_ indices: [Int], count: Int) -> Bool {
        indices.count == count && Set(indices) == Set(0..<count)
    }
}

/// File-backed storage keeps large library queues out of UserDefaults. Writes
/// use atomic replacement so a terminated process leaves either the old or new
/// complete snapshot on disk.
public struct PlaybackSessionStore: Sendable {
    public let url: URL

    public init(fileManager: FileManager = .default) {
        #if os(tvOS)
        let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        url = base
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("playback-session.json")
    }

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> PlaybackSessionSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlaybackSessionSnapshot.self, from: data)
    }

    public func save(_ snapshot: PlaybackSessionSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
