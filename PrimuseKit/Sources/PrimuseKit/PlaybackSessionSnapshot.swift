import Foundation
import os

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

/// Coordinates the one-time launch restore with transport actions that may
/// arrive while its file/queue work is still in flight. An empty player is not
/// proof that the user stopped playback until the initial restore has either
/// completed or been explicitly superseded.
public struct PlaybackSessionRestoreLifecycle: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case pending
        case restoring
        case superseded
        case completed
    }

    public private(set) var phase: Phase = .pending
    private var generation: UInt64 = 0

    public init() {}

    /// Empty-state publications (for example the first scene-active callback)
    /// may clear durable state only after launch restoration has settled.
    public var permitsEmptySessionClear: Bool {
        phase == .completed
    }

    /// Starts the single launch restore and returns a token that must still be
    /// current before applying its asynchronously prepared queue.
    public mutating func begin() -> UInt64? {
        guard phase == .pending else { return nil }
        generation &+= 1
        phase = .restoring
        return generation
    }

    public func permitsApply(token: UInt64) -> Bool {
        phase == .restoring && generation == token
    }

    /// Finishes a restore attempt. A stale completion cannot undo a newer user
    /// intent that superseded the restore while it was awaiting I/O.
    public mutating func complete(token: UInt64) {
        guard permitsApply(token: token) else { return }
        phase = .completed
    }

    /// A new Play request owns the live session, but the previous snapshot is
    /// retained until the replacement has actually been persisted. If the new
    /// transport fails early, the next launch can still recover the old state.
    public mutating func supersedeForPlaybackIntent() {
        guard phase == .pending || phase == .restoring else { return }
        generation &+= 1
        phase = .superseded
    }

    /// Successful persistence of a current item makes subsequent empty state a
    /// meaningful stop rather than a transient launch condition.
    public mutating func didPersistCurrentSession() {
        phase = .completed
    }

    /// Pause/stop is explicit user intent. It invalidates an in-flight restore
    /// and allows the caller to remove the stored snapshot when no item exists.
    public mutating func completeForPauseOrStopIntent() {
        generation &+= 1
        phase = .completed
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
    public var shouldStartPlayback: Bool
}

public enum PlaybackSessionRestorationPolicy {
    /// Positions this close to the beginning are transport jitter, not useful
    /// resume points. Keeping a fractional launch snapshot would send an
    /// uncached remote track through exact-seek recovery and can block first
    /// playback while the complete file is materialized.
    public static let minimumMeaningfulResumeTime: TimeInterval = 3

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
        let restorableTime = safeTime > minimumMeaningfulResumeTime ? safeTime : 0

        return PlaybackSessionRestorationPlan(
            queueSongIDs: restoredIDs,
            currentIndex: restoredCurrentIndex,
            currentTime: snapshot.isAtTrackEnd ? 0 : restorableTime,
            duration: safeDuration,
            shuffleEnabled: snapshot.shuffleEnabled,
            shuffledIndices: shuffleOrder,
            shufflePosition: shufflePosition,
            pendingNextShuffleIndices: pendingOrder,
            repeatMode: snapshot.repeatMode,
            isAtTrackEnd: snapshot.isAtTrackEnd,
            shouldStartPlayback: false
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

/// The durable state a caller wants the session file to end up in.
public enum PlaybackSessionPersistenceRequest: Sendable, Equatable {
    case save(PlaybackSessionSnapshot)
    case clear
}

/// Result of one drain, kept `Sendable` so a background writer can report a
/// failure back to the caller's isolation domain without moving an `Error`.
public struct PlaybackSessionPersistenceOutcome: Sendable, Equatable {
    public let performedWrites: Int
    public let failureDescription: String?
    /// Highest generation whose state is durable on disk once this drain
    /// returned, including generations a previous drain already wrote. A
    /// caller may treat its own request as persisted once this is at least
    /// its own generation, because a newer generation supersedes it. `nil`
    /// means nothing has ever been written successfully.
    public let lastSuccessfulGeneration: UInt64?

    public init(
        performedWrites: Int,
        failureDescription: String?,
        lastSuccessfulGeneration: UInt64? = nil
    ) {
        self.performedWrites = performedWrites
        self.failureDescription = failureDescription
        self.lastSuccessfulGeneration = lastSuccessfulGeneration
    }

    /// Whether the state requested with `generation` is durable. A newer
    /// generation counts: it superseded this request, so the file already
    /// holds state at least as new as the one the caller handed over.
    public func persisted(generation: UInt64) -> Bool {
        guard let lastSuccessfulGeneration else { return false }
        return lastSuccessfulGeneration >= generation
    }
}

/// Keeps the JSON encode and the atomic write off the caller's thread while
/// preserving the caller's ordering.
///
/// The caller captures its snapshot (on its own actor), hands it over with a
/// monotonically increasing generation and then drains from a background task.
/// Only the newest state is written: a request still waiting when a newer one
/// arrives is superseded, and the newest request is always the one left on
/// disk. `clear` travels the same path, so an empty-session clear can never be
/// overtaken by an older in-flight save.
public final class PlaybackSessionPersistenceCoordinator: Sendable {
    private struct PendingRequest: Sendable {
        let generation: UInt64
        let request: PlaybackSessionPersistenceRequest
    }

    private struct State: Sendable {
        var pending: PendingRequest?
        var acceptedGeneration: UInt64 = 0
        var completedWriteCount = 0
        var lastSuccessfulGeneration: UInt64?
    }

    private let store: PlaybackSessionStore
    /// Guards the pending state only; never held across file I/O, so an
    /// enqueue from a latency-critical thread cannot wait for a write.
    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    /// Serialises the writes themselves so two drains cannot interleave.
    private let writeLock = NSLock()

    public init(store: PlaybackSessionStore) {
        self.store = store
    }

    public var url: URL { store.url }

    /// Number of file operations actually performed. Superseded requests never
    /// reach the disk, so this stays well below the number of enqueues.
    public var performedWriteCount: Int {
        state.withLock { $0.completedWriteCount }
    }

    /// Highest generation that actually reached the disk, or `nil` while no
    /// write has succeeded yet.
    public var lastSuccessfulGeneration: UInt64? {
        state.withLock { $0.lastSuccessfulGeneration }
    }

    /// Records the newest requested state. O(1) and lock-free of any I/O.
    public func enqueue(
        _ request: PlaybackSessionPersistenceRequest,
        generation: UInt64
    ) {
        state.withLock { state in
            guard generation >= state.acceptedGeneration else { return }
            state.acceptedGeneration = generation
            state.pending = PendingRequest(generation: generation, request: request)
        }
    }

    /// Writes the newest pending state on the calling thread. Safe to call from
    /// several tasks: the first one in performs the work, the others find
    /// nothing left to do. The outcome always reports the newest generation
    /// that is durable, so a caller whose own request was superseded or was
    /// written by another drain still learns that its state is on disk.
    @discardableResult
    public func drain() -> PlaybackSessionPersistenceOutcome {
        writeLock.lock()
        defer { writeLock.unlock() }
        var writes = 0
        var failureDescription: String?
        while let next = takePending() {
            do {
                switch next.request {
                case let .save(snapshot):
                    try store.save(snapshot)
                case .clear:
                    try store.clear()
                }
                writes += 1
                state.withLock { state in
                    state.completedWriteCount += 1
                    if next.generation > (state.lastSuccessfulGeneration ?? 0) {
                        state.lastSuccessfulGeneration = next.generation
                    }
                }
            } catch {
                failureDescription = error.localizedDescription
            }
        }
        return PlaybackSessionPersistenceOutcome(
            performedWrites: writes,
            failureDescription: failureDescription,
            lastSuccessfulGeneration: state.withLock { $0.lastSuccessfulGeneration }
        )
    }

    private func takePending() -> PendingRequest? {
        state.withLock { (state: inout State) -> PendingRequest? in
            guard let next = state.pending else { return nil }
            state.pending = nil
            return next
        }
    }
}
