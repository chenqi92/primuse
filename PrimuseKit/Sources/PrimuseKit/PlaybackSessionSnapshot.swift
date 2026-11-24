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
    /// Token of the `QueueContinuation` that tops up this queue, if any.
    /// Optional so older session files decode unchanged.
    public var queueContinuationToken: String?
    public var radioStation: RadioStation?
    public var radioStationOrderIDs: [String]?
    /// Feed episodes are not library rows. Keep their metadata in the same
    /// atomic write as the selected occurrence and position.
    public var podcastQueue: [Song]?
    /// 「单曲播一遍」「逐首播放」。Optional so older session files decode unchanged.
    public var eachTrackStop: EachTrackStop?
    /// False for single-song requests, even after autoplay adds more songs.
    public var remembersMusicQueue: Bool?
    public var queueIdentity: UUID?

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
        updatedAt: Date = Date(),
        queueContinuationToken: String? = nil,
        radioStation: RadioStation? = nil,
        radioStationOrderIDs: [String]? = nil,
        podcastQueue: [Song]? = nil,
        eachTrackStop: EachTrackStop? = nil,
        remembersMusicQueue: Bool? = nil,
        queueIdentity: UUID? = nil
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
        self.queueContinuationToken = queueContinuationToken
        self.radioStation = radioStation
        self.radioStationOrderIDs = radioStationOrderIDs
        self.podcastQueue = podcastQueue
        self.eachTrackStop = eachTrackStop
        self.remembersMusicQueue = remembersMusicQueue
        self.queueIdentity = queueIdentity
    }
}

/// Coordinates the one-time launch restore with transport actions that may
/// arrive while its file/queue work is still in flight. An empty player is not
/// proof that the user stopped playback until the initial restore has either
/// completed or been explicitly superseded.
public struct PlaybackSessionRestoreLifecycle: Equatable, Sendable {
    public static let launchAutoplayKey = "primuse.playback.autoplayOnLaunch"
    public enum Phase: Equatable, Sendable {
        case pending
        case restoring
        case superseded
        case completed
    }

    public private(set) var phase: Phase = .pending
    private var generation: UInt64 = 0
    private var receivedTransportIntent = false
    private var decidedLaunchAutoplay = false

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
        receivedTransportIntent = true
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
        receivedTransportIntent = true
        generation &+= 1
        phase = .completed
    }

    /// Wait for the first foreground restore, then decide exactly once. A
    /// manual transport command always wins, including one issued during I/O.
    public mutating func takeLaunchAutoplayDecision(
        enabled: Bool,
        isForeground: Bool,
        canResume: Bool,
        otherAudioIsPlaying: Bool = false
    ) -> Bool {
        guard phase == .completed, isForeground, !decidedLaunchAutoplay else { return false }
        decidedLaunchAutoplay = true
        return enabled && !receivedTransportIntent && canResume && !otherAudioIsPlaying
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
    public var eachTrackStop: EachTrackStop? = nil
    public var remembersMusicQueue: Bool? = nil
    public var queueIdentity: UUID? = nil
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
            shouldStartPlayback: false,
            eachTrackStop: snapshot.repeatMode == .off ? snapshot.eachTrackStop : nil,
            remembersMusicQueue: snapshot.remembersMusicQueue,
            queueIdentity: snapshot.queueIdentity
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

// MARK: - Queue window

/// A very large play request (a 200K-song "play all") is not installed as one
/// live queue: every queue-sized structure — entries, shuffle order, the next
/// repeat round, the session file — would scale with the whole library. The
/// player keeps a window of at most `windowLimit` songs and tops it up from a
/// `QueueContinuation` (the remaining song IDs, in order) as playback nears
/// the end of the window.
public enum QueueWindowPolicy {
    public static let windowLimit = 1_000
    /// Songs kept before the selected one so "previous" still works.
    public static let leadingHistory = 50
    /// Top up once fewer than this many songs remain ahead of the current one.
    public static let refillThreshold = 200
    public static let refillBatch = 500

    /// The slice of a `count`-song request to install, or nil when the whole
    /// request fits.
    public static func window(count: Int, selectedIndex: Int) -> Range<Int>? {
        guard count > windowLimit else { return nil }
        let selected = max(0, min(selectedIndex, count - 1))
        let lower = max(0, min(selected - leadingHistory, count - windowLimit))
        return lower..<(lower + windowLimit)
    }

    public static func shouldRefill(upcomingCount: Int) -> Bool {
        upcomingCount < refillThreshold
    }

    /// Pairs a loaded snapshot with its saved continuation. A snapshot whose
    /// continuation token matches is already windowed — a window that has been
    /// topped up is legitimately larger than `windowLimit` — and must keep that
    /// continuation. Only a snapshot without a usable continuation is treated
    /// as a legacy whole-library queue and reshaped.
    public static func restoring(
        _ snapshot: PlaybackSessionSnapshot,
        savedContinuation: QueueContinuation?
    ) -> (snapshot: PlaybackSessionSnapshot, continuation: QueueContinuation?, reshapedLegacyQueue: Bool) {
        if let token = snapshot.queueContinuationToken,
           let savedContinuation, savedContinuation.token == token {
            return (snapshot, savedContinuation, false)
        }
        if let windowed = windowed(snapshot) {
            return (windowed.snapshot, windowed.continuation, true)
        }
        return (snapshot, nil, false)
    }

    /// Session files written before the window existed can hold the whole
    /// library. Restore them as a window plus continuation: in order around
    /// the current song, or — under shuffle — the rest of the current round in
    /// its saved random order, starting with the current song. Nil when the
    /// saved queue already fits.
    public static func windowed(
        _ snapshot: PlaybackSessionSnapshot
    ) -> (snapshot: PlaybackSessionSnapshot, continuation: QueueContinuation)? {
        let ids = snapshot.queueSongIDs
        guard ids.count > windowLimit, ids.indices.contains(snapshot.currentIndex) else { return nil }
        var windowed = snapshot
        let continuation: QueueContinuation
        if snapshot.shuffleEnabled {
            let order = snapshot.shuffledIndices
            var sequence: [String]
            if order.indices.contains(snapshot.shufflePosition),
               order[snapshot.shufflePosition] == snapshot.currentIndex,
               order.allSatisfy({ ids.indices.contains($0) }) {
                sequence = order[snapshot.shufflePosition...].map { ids[$0] }
            } else {
                sequence = [ids[snapshot.currentIndex]]
                    + ids.indices.filter { $0 != snapshot.currentIndex }.map { ids[$0] }
            }
            let count = min(windowLimit, sequence.count)
            continuation = QueueContinuation(requestedIDs: sequence, window: 0..<count)
            windowed.queueSongIDs = Array(sequence.prefix(count))
            windowed.currentIndex = 0
            windowed.shuffledIndices = Array(0..<count)
            windowed.shufflePosition = 0
            sequence = []
        } else {
            guard let window = window(count: ids.count, selectedIndex: snapshot.currentIndex) else { return nil }
            continuation = QueueContinuation(requestedIDs: ids, window: window)
            windowed.queueSongIDs = Array(ids[window])
            windowed.currentIndex = snapshot.currentIndex - window.lowerBound
            windowed.shuffledIndices = []
            windowed.shufflePosition = 0
        }
        windowed.pendingNextShuffleIndices = nil
        windowed.queueContinuationToken = continuation.token
        return (windowed, continuation)
    }
}

/// How a whole-list play request orders its songs before the window is cut.
public enum LargeQueueRequestOrder: Sendable, Equatable {
    /// Keep the list order and start at the requested song.
    case asGiven
    /// Start at the requested song and wrap round to the songs before it.
    case rotatedToStart
    /// A fresh random order starting with its first song.
    case shuffled
    /// Start at the requested song; every other song follows once, in a fresh
    /// random order. The requested ID may appear again further down the list
    /// (a caller can prepend it to the whole library); it still plays once.
    /// When the requested song cannot be queued, the whole list is shuffled.
    case shuffledAfterStart
}

/// The part of a play request the player installs now, plus the rest.
public struct PreparedQueueRequest<Item: Sendable>: Sendable {
    public let items: [Item]
    public let selectedIndex: Int
    /// Nil when the whole request fits in one window.
    public let continuation: QueueContinuation?

    public init(items: [Item], selectedIndex: Int, continuation: QueueContinuation?) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.continuation = continuation
    }
}

/// Prepares "play all", "shuffle all" and "play from this song" over lists
/// that can hold the whole library. Everything here works on song IDs, so a
/// caller can run it off the main actor: filtering, rotating and shuffling
/// never copy `Song` values, and only the installed window is resolved.
public enum LargeQueueRequestPlanner {
    /// - Parameters:
    ///   - ids: The list in display order.
    ///   - startIndex: The requested song. When `includes` rejects it, the
    ///     next kept song after it starts instead.
    ///   - includes: Whether an ID still names a song that may be queued.
    ///   - resolve: Materializes one queued song.
    ///   - linkGraph: 随机时连着放的歌(#335)。随机的请求里连着的歌排在一起, 列表里缺的那一首
    ///     按设了开关的一边补进来。
    ///   - shuffle: Injected for tests.
    public static func plan<Item: Sendable>(
        ids: [String],
        startIndex: Int,
        order: LargeQueueRequestOrder,
        includes: (String) -> Bool,
        resolve: (String) -> Item?,
        linkGraph: ShuffleLinkGraph = .empty,
        shuffle: ([String]) -> [String]
    ) -> PreparedQueueRequest<Item>? {
        plan(ids: ids, startIndex: startIndex, order: order, includes: includes, resolve: resolve,
             linkGraph: linkGraph, shuffleInPlace: { $0 = shuffle($0) })
    }

    public static func plan<Item: Sendable>(
        ids: [String],
        startIndex: Int,
        order: LargeQueueRequestOrder,
        includes: (String) -> Bool,
        resolve: (String) -> Item?,
        linkGraph: ShuffleLinkGraph = .empty,
        shuffleInPlace: (inout [String]) -> Void = { $0.shuffle() }
    ) -> PreparedQueueRequest<Item>? {
        var sequence: [String] = []
        sequence.reserveCapacity(ids.count)
        var startPosition: Int?
        var requestedStartID: String?
        for (index, id) in ids.enumerated() where includes(id) {
            if startPosition == nil, index >= startIndex { startPosition = sequence.count }
            if index == startIndex { requestedStartID = id }
            sequence.append(id)
        }
        guard !sequence.isEmpty else { return nil }

        let selected: Int
        switch order {
        case .asGiven:
            selected = startPosition ?? 0
        case .rotatedToStart:
            let start = startPosition ?? 0
            if start > 0 {
                var rotated = Array(sequence[start...])
                rotated.append(contentsOf: sequence[..<start])
                sequence = rotated
            }
            selected = 0
        case .shuffled, .shuffledAfterStart:
            let first = order == .shuffledAfterStart ? requestedStartID : nil
            if let first { sequence.removeAll { $0 == first } }
            if linkGraph.isEmpty {
                shuffleInPlace(&sequence)
                if let first { sequence.insert(first, at: 0) }
            } else {
                if let first { sequence.insert(first, at: 0) }
                let brought = ShuffleLinkPolicy.bringingLinkedSongs(sequence, graph: linkGraph, includes: includes)
                sequence = ShuffleLinkPolicy.shuffled(brought, graph: linkGraph, id: { $0 }, leading: first) { groups in
                    var order = groups
                    shuffleInPlace(&order)
                    return order
                }
            }
            selected = 0
        }

        let window = QueueWindowPolicy.window(count: sequence.count, selectedIndex: selected)
        let range = window ?? sequence.indices
        var items: [Item] = []
        items.reserveCapacity(range.count)
        var itemSelected: Int?
        for position in range {
            guard let item = resolve(sequence[position]) else { continue }
            if itemSelected == nil, position >= selected { itemSelected = items.count }
            items.append(item)
        }
        guard !items.isEmpty else { return nil }
        let continuation = window.map { QueueContinuation(requestedIDs: sequence, window: $0) }
        return PreparedQueueRequest(
            items: items,
            selectedIndex: itemSelected ?? items.count - 1,
            continuation: continuation
        )
    }
}

/// Songs of the original request that are not in the live queue yet. The
/// window covers `requestedIDs[lower..<nextOffset]`; songs after it are handed
/// out first. Under repeat-all the songs before the window follow once, so a
/// full cycle still plays every requested song before the queue wraps.
///
/// 整库请求的 id 列表放在映射文件里(`QueueContinuationIDFile`),取窗口时按段读出;
/// 常驻内存里不再有整库规模的 `[String]`。
public struct QueueContinuation: Codable, Equatable, Sendable {
    public let token: String
    /// A disk-backed whole-library request holds candidate IDs until each window is resolved.
    public let musicSourceIDs: Set<String>?
    private var storage: QueueContinuationIDStorage
    public private(set) var nextOffset: Int
    /// Songs before the window (`requestedIDs[0..<leadingEnd]`).
    public private(set) var leadingEnd: Int
    public private(set) var leadingOffset: Int

    /// 整张请求。整库请求时这里会临时建一份整库规模的数组:只要条数用 `requestedCount`,
    /// 只要一段用 `requestedIDs(in:)`。
    public var requestedIDs: [String] { storage.materialized }

    public var requestedCount: Int { storage.count }

    /// 请求里的一段(越界部分截掉)。
    public func requestedIDs(in range: Range<Int>) -> [String] {
        let lower = min(max(0, range.lowerBound), storage.count)
        let upper = min(max(lower, range.upperBound), storage.count)
        return storage.ids(in: lower..<upper)
    }

    public init(token: String = UUID().uuidString, requestedIDs: [String], window: Range<Int>, musicSourceIDs: Set<String>? = nil) {
        self.token = token
        self.musicSourceIDs = musicSourceIDs
        self.storage = .make(requestedIDs)
        nextOffset = min(window.upperBound, requestedIDs.count)
        leadingEnd = max(0, min(window.lowerBound, requestedIDs.count))
        leadingOffset = 0
    }

    /// Restores a stored continuation; offsets are clamped to the IDs.
    init(token: String, requestedIDs: [String], nextOffset: Int, leadingEnd: Int, leadingOffset: Int, musicSourceIDs: Set<String>? = nil) {
        self.init(
            token: token, storage: .make(requestedIDs), nextOffset: nextOffset,
            leadingEnd: leadingEnd, leadingOffset: leadingOffset, musicSourceIDs: musicSourceIDs
        )
    }

    init(
        token: String,
        storage: QueueContinuationIDStorage,
        nextOffset: Int,
        leadingEnd: Int,
        leadingOffset: Int,
        musicSourceIDs: Set<String>?
    ) {
        self.token = token
        self.musicSourceIDs = musicSourceIDs
        self.storage = storage
        self.nextOffset = max(0, min(nextOffset, storage.count))
        self.leadingEnd = max(0, min(leadingEnd, storage.count))
        self.leadingOffset = max(0, min(leadingOffset, self.leadingEnd))
    }

    var idStorage: QueueContinuationIDStorage { storage }

    private enum CodingKeys: String, CodingKey {
        case token, musicSourceIDs, requestedIDs, nextOffset, leadingEnd, leadingOffset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        musicSourceIDs = try container.decodeIfPresent(Set<String>.self, forKey: .musicSourceIDs)
        storage = .make(try container.decode([String].self, forKey: .requestedIDs))
        nextOffset = try container.decode(Int.self, forKey: .nextOffset)
        leadingEnd = try container.decode(Int.self, forKey: .leadingEnd)
        leadingOffset = try container.decode(Int.self, forKey: .leadingOffset)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(musicSourceIDs, forKey: .musicSourceIDs)
        try container.encode(storage.materialized, forKey: .requestedIDs)
        try container.encode(nextOffset, forKey: .nextOffset)
        try container.encode(leadingEnd, forKey: .leadingEnd)
        try container.encode(leadingOffset, forKey: .leadingOffset)
    }

    /// Nothing more can ever be handed out, whatever the repeat mode.
    public var isExhausted: Bool {
        nextOffset >= storage.count && leadingOffset >= leadingEnd
    }

    /// Follows song ID migrations so owed songs still resolve afterwards.
    /// A request can hold both the legacy and the canonical ID of one song;
    /// once mapped they collide and only one copy is kept — the one already
    /// in the window if any, else the first still owed, else the first before
    /// the window. Repeats that no migration touched stay as requested.
    public mutating func remapIDs(_ replacements: [String: String]) {
        guard !replacements.isEmpty else { return }
        let requestedIDs = storage.materialized
        let mapped = requestedIDs.map { replacements[$0] ?? $0 }
        var migrated = Set<String>()
        for (old, new) in zip(requestedIDs, mapped) where old != new { migrated.insert(new) }
        guard !migrated.isEmpty else { return }
        let window = leadingEnd..<max(leadingEnd, nextOffset)
        let ordered = Array(window) + Array(window.upperBound..<mapped.count) + Array(0..<leadingEnd)
        var kept = Set<String>()
        var dropped = IndexSet()
        for index in ordered where migrated.contains(mapped[index]) {
            if !kept.insert(mapped[index]).inserted { dropped.insert(index) }
        }
        guard !dropped.isEmpty else {
            storage = .make(mapped)
            return
        }
        func shifted(_ offset: Int) -> Int { offset - dropped.count(in: 0..<offset) }
        nextOffset = shifted(nextOffset)
        leadingOffset = shifted(leadingOffset)
        leadingEnd = shifted(leadingEnd)
        storage = .make(mapped.indices.filter { !dropped.contains($0) }.map { mapped[$0] })
    }

    /// Songs moved to Up Next must not be appended again when the window fills.
    /// Keep the installed window and the already-consumed prefixes intact.
    public mutating func removePendingSongs(withIDs songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        let leading = leadingOffset..<leadingEnd
        let count = storage.count
        let dropped = IndexSet((0..<count).filter {
            ($0 >= nextOffset || leading.contains($0)) && songIDs.contains(storage[$0])
        })
        guard !dropped.isEmpty else { return }
        func shifted(_ offset: Int) -> Int { offset - dropped.count(in: 0..<offset) }
        nextOffset = shifted(nextOffset)
        leadingOffset = shifted(leadingOffset)
        leadingEnd = shifted(leadingEnd)
        storage = .make((0..<count).filter { !dropped.contains($0) }.map { storage[$0] })
    }

    /// Removes deleted songs from every segment of the continuation (leading,
    /// active window, and trailing) while keeping cursor offsets aligned.
    public mutating func removeSongs(withIDs songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        let count = storage.count
        let dropped = IndexSet((0..<count).filter { songIDs.contains(storage[$0]) })
        guard !dropped.isEmpty else { return }
        func shifted(_ offset: Int) -> Int { offset - dropped.count(in: 0..<offset) }
        nextOffset = shifted(nextOffset)
        leadingOffset = shifted(leadingOffset)
        leadingEnd = shifted(leadingEnd)
        storage = .make((0..<count).filter { !dropped.contains($0) }.map { storage[$0] })
    }

    /// Up to `maxCount` IDs in playback order. The leading part is only used
    /// under repeat-all, after the trailing part has run out.
    public mutating func takeNext(maxCount: Int, repeatsAll: Bool) -> [String] {
        guard maxCount > 0 else { return [] }
        if nextOffset < storage.count {
            let end = min(storage.count, nextOffset + maxCount)
            defer { nextOffset = end }
            return storage.ids(in: nextOffset..<end)
        }
        guard repeatsAll, leadingOffset < leadingEnd else { return [] }
        let end = min(leadingEnd, leadingOffset + maxCount)
        defer { leadingOffset = end }
        return storage.ids(in: leadingOffset..<end)
    }
}

/// Stored next to the session file. Written only when a continuation starts
/// or advances (every few hundred songs), never on each playback update.
///
/// 整库请求欠着的 id(上百万条)放在单独的二进制文件里(`QueueContinuationIDFile`,读回时映射,
/// 不逐条建字符串),只在列表本身变了时重写;前进只重写一个小的状态文件。旧版的纯文本 id 文件
/// 与单个 JSON 文件读回时转成新格式一次,旧文件随即删掉。
public struct QueueContinuationStore: Sendable {
    public let url: URL

    public init(sessionStore: PlaybackSessionStore) {
        url = sessionStore.url.deletingLastPathComponent()
            .appendingPathComponent("playback-queue-continuation.json")
    }

    public init(url: URL) {
        self.url = url
    }

    /// 二进制 id 文件(映射读)。
    var idsURL: URL {
        url.deletingPathExtension().appendingPathExtension("qids")
    }

    /// 旧版的纯文本 id 文件(一行一个),读回时转换。
    var legacyIDsURL: URL {
        url.deletingPathExtension().appendingPathExtension("ids")
    }

    private struct State: Codable {
        let token: String
        let musicSourceIDs: Set<String>?
        let nextOffset: Int
        let leadingEnd: Int
        let leadingOffset: Int
        let idsCount: Int
        let idsFingerprint: UInt64
        /// 2:二进制 id 文件;没有这一项的是旧版的纯文本文件。
        let idsFormat: Int?
    }

    private static let idsHeaderPrefix = "primuse-queue-ids v1 "
    static let currentIDsFormat = 2

    public func load() -> QueueContinuation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let state = try? JSONDecoder().decode(State.self, from: data) {
            if state.idsFormat == Self.currentIDsFormat { return mapped(state) }
            return convertLegacyIDs(state)
        }
        // 更早的单个 JSON 文件:读回后按新格式存一次,再从新文件映射。
        guard let legacy = try? JSONDecoder().decode(QueueContinuation.self, from: data) else { return nil }
        save(legacy)
        guard let saved = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: saved),
              state.idsFormat == Self.currentIDsFormat else { return legacy }
        return mapped(state) ?? legacy
    }

    /// 新格式:id 文件映射进来,条数与指纹对得上才用。
    private func mapped(_ state: State) -> QueueContinuation? {
        guard let file = QueueContinuationIDFile.open(url: idsURL),
              file.count == state.idsCount, file.fingerprint == state.idsFingerprint else { return nil }
        return QueueContinuation(
            token: state.token, storage: .file(file), nextOffset: state.nextOffset,
            leadingEnd: state.leadingEnd, leadingOffset: state.leadingOffset,
            musicSourceIDs: state.musicSourceIDs
        )
    }

    public func save(_ continuation: QueueContinuation?) {
        guard let continuation else {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: idsURL)
            try? FileManager.default.removeItem(at: legacyIDsURL)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let storage = continuation.idStorage
        let fingerprint = storage.fingerprint
        if let stored = QueueContinuationIDFile.header(at: idsURL),
           stored.count == storage.count, stored.fingerprint == fingerprint {
            // 列表没变:只重写状态文件。
        } else {
            do {
                try QueueContinuationIDFile.write(
                    (0..<storage.count).lazy.map { storage[$0] }, count: storage.count, to: idsURL
                )
            } catch {
                return
            }
        }
        let state = State(
            token: continuation.token,
            musicSourceIDs: continuation.musicSourceIDs,
            nextOffset: continuation.nextOffset,
            leadingEnd: continuation.leadingEnd,
            leadingOffset: continuation.leadingOffset,
            idsCount: storage.count,
            idsFingerprint: fingerprint,
            idsFormat: Self.currentIDsFormat
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: legacyIDsURL)
    }

    // MARK: - Fingerprint

    static let fingerprintSeed: UInt64 = 0xcbf2_9ce4_8422_2325
    static let fingerprintPrime: UInt64 = 0x0000_0100_0000_01B3

    /// FNV-1a over every ID and a separator: stable across launches.
    static func fingerprint(_ ids: [String]) -> UInt64 {
        var hash = fingerprintSeed
        for id in ids {
            for byte in id.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* fingerprintPrime
            }
            hash ^= 10
            hash = hash &* fingerprintPrime
        }
        return hash
    }

    // MARK: - Former plain-text ID list

    private static func header(count: Int, fingerprint: UInt64) -> String {
        idsHeaderPrefix + "\(count) \(String(fingerprint, radix: 16))"
    }

    /// 旧版纯文本 id 文件:逐行流式转成二进制文件(不先建整张字符串数组),转好后删掉旧文件。
    private func convertLegacyIDs(_ state: State) -> QueueContinuation? {
        guard let data = try? Data(contentsOf: legacyIDsURL, options: .alwaysMapped),
              let headerEnd = data.firstIndex(of: 10),
              String(decoding: data[data.startIndex..<headerEnd], as: UTF8.self)
                == Self.header(count: state.idsCount, fingerprint: state.idsFingerprint) else { return nil }
        let lines = LegacyIDLines(data: data, start: headerEnd + 1)
        guard lines.isWellFormed(count: state.idsCount) else { return nil }
        let fingerprint: UInt64
        do {
            fingerprint = try QueueContinuationIDFile.write(lines, count: state.idsCount, to: idsURL)
        } catch {
            return nil
        }
        guard fingerprint == state.idsFingerprint, let file = QueueContinuationIDFile.open(url: idsURL) else {
            try? FileManager.default.removeItem(at: idsURL)
            return nil
        }
        let converted = QueueContinuation(
            token: state.token, storage: .file(file), nextOffset: state.nextOffset,
            leadingEnd: state.leadingEnd, leadingOffset: state.leadingOffset,
            musicSourceIDs: state.musicSourceIDs
        )
        save(converted)
        return converted
    }

    /// 旧版文件里头行之后的各行(每行一个 id,以换行结尾)。
    private struct LegacyIDLines: Sequence {
        let data: Data
        let start: Int

        func isWellFormed(count: Int) -> Bool {
            var lines = 0
            var position = start
            while position < data.endIndex {
                guard let newline = data[position...].firstIndex(of: 10) else { return false }
                lines += 1
                position = newline + 1
            }
            return lines == count
        }

        func makeIterator() -> AnyIterator<String> {
            var position = start
            return AnyIterator {
                guard position < data.endIndex, let newline = data[position...].firstIndex(of: 10) else { return nil }
                defer { position = newline + 1 }
                return String(decoding: data[position..<newline], as: UTF8.self)
            }
        }
    }
}


public struct RecentPlaybackItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case song, album, playlist, artist }
    public let kind: Kind
    public let entityID: String
    public var playedAt: Date
    public var id: String { "\(kind.rawValue):\(entityID)" }

    public init(kind: Kind, entityID: String, playedAt: Date = Date()) {
        self.kind = kind
        self.entityID = entityID
        self.playedAt = playedAt
    }
}

public enum RecentPlaybackHistory {
    public static let limit = 40

    public static func merging(_ items: [RecentPlaybackItem], limit: Int = limit) -> [RecentPlaybackItem] {
        var seen = Set<String>()
        return Array(items.sorted {
            $0.playedAt == $1.playedAt ? $0.id < $1.id : $0.playedAt > $1.playedAt
        }.filter { !$0.entityID.isEmpty && seen.insert($0.id).inserted }.prefix(max(0, limit)))
    }
}
