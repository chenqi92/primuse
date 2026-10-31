import Foundation

/// Pure scheduling and invalidation rules shared by the app's library indexes.
public enum LibraryIndexMaintenancePolicy {
    /// Metadata backfill can run for hours. Keep derived collections and
    /// Spotlight reasonably fresh without restarting a whole-library pass for
    /// every small persistence flush.
    public static let maximumDeferredMaintenanceInterval: TimeInterval = 60

    /// Incremental scan flushes land every 1.5 s (200 songs). Rebuilding the
    /// derived collections for each of them republished the whole visible
    /// catalogue while the user was scrolling. Coalescing them with a short
    /// cap keeps the catalogue visibly fresh during a scan while cutting the
    /// number of whole-library applies roughly in half.
    public static let incrementalScanMaintenanceInterval: TimeInterval = 3

    /// A whole-library rebuild costs time proportional to the library: a few
    /// hundred thousand songs take seconds, so a fixed 3 s coalescing window
    /// kept the device rebuilding for the whole scan. The window stretches to
    /// `rebuildDutyMultiplier` times the last rebuild — the rebuild then takes
    /// at most about a fifth of the scan — never shorter than the 3 s cap and
    /// never longer than the backfill cap.
    public static let rebuildDutyMultiplier: Double = 4

    public static func incrementalScanMaintenanceInterval(
        lastRebuildSeconds: TimeInterval
    ) -> TimeInterval {
        guard lastRebuildSeconds.isFinite, lastRebuildSeconds > 0 else {
            return incrementalScanMaintenanceInterval
        }
        return min(
            maximumDeferredMaintenanceInterval,
            max(incrementalScanMaintenanceInterval, lastRebuildSeconds * rebuildDutyMultiplier)
        )
    }

    /// Whether deferred maintenance may run while the device-busy gate (app
    /// not active, thermal state not nominal) is closed.
    ///
    /// The gate exists for hours-long metadata backfills. A scan's intermediate
    /// flush belongs to work the user just started, and the catalogue it feeds
    /// is what the scan is for: gating it leaves songs, albums and artists at
    /// the pre-scan snapshot for the whole scan on a warm or backgrounded
    /// device, so the short timer both arms and fires regardless of the gate.
    public static func allowsDeferredMaintenance(
        isIncrementalScanFlush: Bool,
        deviceMaintenanceAllowed: Bool
    ) -> Bool {
        isIncrementalScanFlush || deviceMaintenanceAllowed
    }

    /// Earliest-deadline-wins arming for the deferred maintenance timer.
    ///
    /// Returns `nil` when the already scheduled flush fires no later than the
    /// new request — re-arming in that case would push the deadline forward on
    /// every flush and a continuous scan would never reach it.
    public static func deferredMaintenanceRearmInterval(
        secondsUntilScheduledFlush: TimeInterval?,
        requestedInterval: TimeInterval
    ) -> TimeInterval? {
        guard let scheduled = secondsUntilScheduledFlush else { return requestedInterval }
        return requestedInterval < scheduled ? requestedInterval : nil
    }

    /// Values consumed by MusicLibrary's album/artist derivation and prepared
    /// visible caches. Technical metadata such as bitrate and sample rate
    /// deliberately stays out so it cannot schedule an unrelated regroup.
    public static func derivedCollectionsChanged(from old: Song, to new: Song) -> Bool {
        old.artistName != new.artistName
            || old.sourceArtistNames != new.sourceArtistNames
            || old.albumArtistName != new.albumArtistName
            || old.albumTitle != new.albumTitle
            || old.year != new.year
            || old.genre != new.genre
            || old.duration.bitPattern != new.duration.bitPattern
            || old.sourceID != new.sourceID
            || old.coverArtFileName != new.coverArtFileName
            || old.artistArtworkFileName != new.artistArtworkFileName
            || old.discNumber != new.discNumber
            || old.trackNumber != new.trackNumber
    }

    /// Generation allocation wraps rather than overflowing. Zero stays reserved
    /// for "never prepared", so the successor of `Int.max` is 1.
    public static func nextPreparationGeneration(current: Int) -> Int {
        current == .max ? 1 : current + 1
    }

    /// Incremental completion is safe only when it directly follows the last
    /// durable completion. A gap means a prior process may have exited before
    /// writing unknown rows, so only a full reconciliation can clear it.
    public static func canCompleteIncrementally(
        completedGeneration: Int,
        firstPendingGeneration: Int
    ) -> Bool {
        if completedGeneration == .max { return firstPendingGeneration == 1 }
        return firstPendingGeneration == completedGeneration + 1
    }
}

/// Serial, restartable work which must not extend a catalogue scan's lifetime.
/// Only source IDs are persisted; callers reconstruct work from committed data.
@MainActor
public final class SourceMaintenanceQueue {
    public typealias Operation = @MainActor () async throws -> Void
    public struct Continuation: Error {
        public let delay: TimeInterval
        public init(delay: TimeInterval = 0.25) { self.delay = delay }
    }
    private struct Job {
        let revision: UUID
        let operation: Operation
        var retryAfter: Date = .distantPast
    }

    private let defaults: UserDefaults?
    private let persistenceKey: String
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var driver: Task<Void, Never>?
    private var active: (sourceID: String, task: Task<Void, Error>)?
    private var activeToken: UUID?
    public private(set) var pendingSourceIDs: Set<String>
    public var isPaused = false {
        didSet {
            if isPaused { activeToken = nil; active?.task.cancel() }
            else { startIfNeeded() }
        }
    }

    public init(defaults: UserDefaults? = nil, persistenceKey: String = "sourceMaintenance.pending") {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        pendingSourceIDs = Set(defaults?.stringArray(forKey: persistenceKey) ?? [])
    }

    public func markPending(_ sourceID: String) {
        if pendingSourceIDs.insert(sourceID).inserted { persist() }
    }

    public func enqueue(sourceID: String, operation: @escaping Operation) {
        markPending(sourceID)
        if jobs[sourceID] == nil { order.append(sourceID) }
        jobs[sourceID] = Job(revision: UUID(), operation: operation)
        if active?.sourceID == sourceID { activeToken = nil; active?.task.cancel() }
        startIfNeeded()
    }

    /// A new scan/configuration invalidates captured work but retains its intent.
    public func invalidate(sourceID: String) {
        jobs[sourceID] = nil
        order.removeAll { $0 == sourceID }
        if active?.sourceID == sourceID { activeToken = nil; active?.task.cancel() }
    }

    public func discard(sourceID: String) {
        invalidate(sourceID: sourceID)
        pendingSourceIDs.remove(sourceID)
        persist()
    }

    public func stop() {
        activeToken = nil
        driver?.cancel()
        active?.task.cancel()
    }

    /// Independent of Task-local cancellation, including callbacks on a different task.
    public func operationToken(for sourceID: String) -> UUID? {
        active?.sourceID == sourceID ? activeToken : nil
    }

    private func persist() {
        defaults?.set(pendingSourceIDs.sorted(), forKey: persistenceKey)
    }

    private func startIfNeeded() {
        guard driver == nil, !jobs.isEmpty else { return }
        driver = Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { driver = nil }
        while !Task.isCancelled, !jobs.isEmpty {
            guard !isPaused,
                  let sourceID = order.first(where: { jobs[$0].map { $0.retryAfter <= Date() } == true }),
                  let job = jobs[sourceID] else {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                continue
            }
            activeToken = UUID()
            let task = Task(priority: .utility) { try await job.operation() }
            active = (sourceID, task)
            let result = await task.result
            active = nil
            activeToken = nil
            guard jobs[sourceID]?.revision == job.revision else { continue }
            if case .success = result, !task.isCancelled {
                jobs[sourceID] = nil
                order.removeAll { $0 == sourceID }
                pendingSourceIDs.remove(sourceID)
                persist()
            } else if !isPaused {
                // Network/storage failures keep their durable intent without a hot retry loop.
                let delay: TimeInterval
                if case .failure(let continuation as Continuation) = result { delay = continuation.delay }
                else { delay = 30 }
                jobs[sourceID]?.retryAfter = Date().addingTimeInterval(delay)
                order.removeAll { $0 == sourceID }
                order.append(sourceID)
            }
        }
    }
}

/// Compact latest-value set used by the persistent search index. Its size is
/// proportional to rows changed since the active transaction began, never to
/// the total library or the number of repeated publications.
public struct IncrementalLibrarySearchMutationState: Equatable, Sendable {
    public private(set) var upsertIDs: Set<String> = []
    public private(set) var deletingIDs: Set<String> = []

    public var isEmpty: Bool { upsertIDs.isEmpty && deletingIDs.isEmpty }
    public var touchedRowCount: Int { upsertIDs.count + deletingIDs.count }

    public init() {}

    public mutating func recordUpserts<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids {
            deletingIDs.remove(id)
            upsertIDs.insert(id)
        }
    }

    public mutating func recordDeletions<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids {
            upsertIDs.remove(id)
            deletingIDs.insert(id)
        }
    }
}

/// State machine for a cancellable worker that may have at most one active
/// request and one replaceable latest request.
public struct LatestOnlyLibraryIndexWorkState: Equatable, Sendable {
    public enum Submission: Equatable, Sendable {
        case start
        case replacePending
    }

    public private(set) var activeGeneration: Int?
    public private(set) var pendingGeneration: Int?

    public init() {}

    public mutating func submit(generation: Int) -> Submission {
        if activeGeneration == nil {
            activeGeneration = generation
            return .start
        }
        pendingGeneration = generation
        return .replacePending
    }

    /// Completes only the active request. Returns the latest pending generation
    /// that should start next, if one exists.
    public mutating func complete(generation: Int) -> Int? {
        guard activeGeneration == generation else { return nil }
        let next = pendingGeneration
        activeGeneration = next
        pendingGeneration = nil
        return next
    }
}

/// Read-only catalogue storage with a small overlay for rows changed during a walk.
/// The initial index stores offsets instead of duplicating every Song value.
public struct IndexedSongSnapshot: Sendable {
    private let songs: [Song]
    private let offsets: [String: Int]
    private var updates: [String: Song] = [:]

    public init(_ songs: [Song], sourceID: String? = nil) {
        self.songs = songs
        var offsets: [String: Int] = [:]
        offsets.reserveCapacity(sourceID == nil ? songs.count : min(songs.count, 4096))
        for (index, song) in songs.enumerated()
            where (sourceID == nil || song.sourceID == sourceID) && offsets[song.id] == nil {
            offsets[song.id] = index
        }
        self.offsets = offsets
    }

    public subscript(_ id: String) -> Song? {
        if let updated = updates[id] { return updated }
        guard let offset = offsets[id] else { return nil }
        return songs[offset]
    }

    public var keys: Set<String> { Set(offsets.keys).union(updates.keys) }
    public var count: Int { offsets.count + updates.keys.lazy.filter { offsets[$0] == nil }.count }
    public mutating func update(_ song: Song) { updates[song.id] = song }
}
