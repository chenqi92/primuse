import Foundation
import PrimuseKit

/// Keeps the two things spoken-word listening needs that music does not: which
/// items are spoken word, and where each one was left off.
///
/// Classification itself is inference (`SpokenWordContentPolicy`) and is not
/// stored — only the listener's explicit corrections are, so a re-scan or a
/// genre fix never fights a stale flag. Positions are per item rather than per
/// session: a book is listened to across days with music in between, and the
/// single playback-session snapshot cannot express that.
///
/// Positions, finished marks, bookmarks, per-book speeds and kind corrections
/// follow the listener to their other devices through the key-value store
/// (`SpokenWordSyncPolicy` merges; every entry is last-writer-wins with
/// tombstones for removals). The local JSON file stays the source of truth.
@MainActor
@Observable
final class SpokenWordStore {
    struct StoredPosition: Codable, Equatable, Sendable {
        var position: TimeInterval
        var duration: TimeInterval
        var updatedAt: Date

        var fractionComplete: Double {
            guard duration > 0, position.isFinite else { return 0 }
            return min(1, max(0, position / duration))
        }
    }

    private struct Payload: Codable {
        var overrides: [String: String]
        var positions: [String: StoredPosition]
        // Optional so files written before bookmarks existed still decode.
        var bookmarks: [String: [SpokenWordBookmark]]?
        var finishedAt: [String: Date]?
        var bookRates: [String: Float]?
        var ledger: SpokenWordSyncLedger?
    }

    /// How soon a change should reach the other devices.
    private enum CloudUrgency: Int, Comparable {
        /// Only a resume position moved: batched, it changes every 15 s.
        case relaxed
        /// Something the listener did on purpose.
        case prompt

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Key-value store key for the synced document.
    static let cloudStorageKey = "primuse_spoken_word_sync_v1"
    private static let promptCloudPushDelay: Duration = .seconds(3)
    private static let relaxedCloudPushDelay: Duration = .seconds(90)

    static let shared = SpokenWordStore()

    /// Explicit per-song corrections. Absent means "whatever the file says".
    private(set) var overrides: [String: ListeningContentKind] = [:]
    private(set) var positions: [String: StoredPosition] = [:]
    /// Marks the listener set inside items, ordered by position.
    private(set) var bookmarks: [String: [SpokenWordBookmark]] = [:]
    /// Items listened to the end (or marked so by hand). A book's shelf
    /// progress and "continue from" are built from this and `positions`.
    private(set) var finishedAt: [String: Date] = [:]
    /// Speeds the listener picked for single books, by `SpokenWordBook.id`.
    /// Absent means the global spoken-word speed.
    private(set) var bookRates: [String: Float] = [:]
    /// When removals and edits happened, so they survive a merge with a
    /// device that has not seen them yet.
    @ObservationIgnored private var ledger = SpokenWordSyncLedger()
    /// Bumped on every change so views and the library aggregation can depend
    /// on one cheap value instead of observing two dictionaries.
    @ObservationIgnored private(set) var revision = 0

    private let storeURL: URL
    private var saveTask: Task<Void, Never>?
    private let syncsThroughICloud: Bool
    @ObservationIgnored private var cloudPushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCloudUrgency: CloudUrgency?
    @ObservationIgnored private var isRegisteredWithCloud = false

    /// `storeURL` is for tests; the app uses `shared`, the only instance that
    /// syncs.
    init(storeURL: URL? = nil) {
        syncsThroughICloud = storeURL == nil
        if let storeURL {
            self.storeURL = storeURL
        } else {
            #if os(tvOS)
            let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                .appendingPathComponent("Primuse", isDirectory: true)
            #else
            let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
                .appendingPathComponent("Primuse", isDirectory: true)
            #endif
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("spoken_word.json")
        }
        load()
        if syncsThroughICloud {
            CloudKVSSync.shared.register(key: Self.cloudStorageKey) { [weak self] in
                guard let self else { return }
                if self.isRegisteredWithCloud {
                    self.mergeCloudCopy()
                } else {
                    // The first reload runs inside `register`, i.e. while
                    // `shared` is still being created; a change notification
                    // from here would reach observers that read `shared`.
                    Task { @MainActor [weak self] in self?.mergeCloudCopy() }
                }
            }
            isRegisteredWithCloud = true
        }
    }

    // MARK: - Classification

    func kind(for song: Song) -> ListeningContentKind {
        classificationSnapshot.kind(
            songID: song.id,
            sourceID: song.sourceID,
            filePath: song.filePath,
            genre: song.genre
        )
    }

    func isSpokenWord(_ song: Song) -> Bool { kind(for: song) == .spokenWord }

    /// Whether this song's kind was set by hand rather than inferred.
    func hasOverride(songID: String) -> Bool { overrides[songID] != nil }

    /// Snapshot for the library aggregation, which classifies off the main
    /// actor and must not reach back into this object.
    var overrideSnapshot: [String: ListeningContentKind] { overrides }

    /// Per-song corrections plus folder tags, for the library's
    /// classification pass and for the player, which must agree with it.
    var classificationSnapshot: SpokenWordClassificationInputs {
        SpokenWordClassificationInputs(overrides: overrides, folderRules: folderRules)
    }

    // MARK: - Folder tags

    /// How each source spells its paths, which folder rules need to match
    /// songs. Kept current by `AppServices` from the source list.
    @ObservationIgnored private var folderTagSources: [LibraryFolderSourceDescriptor] = []
    @ObservationIgnored private var cachedFolderRules: (revision: Int, rules: SpokenWordFolderRules)?
    @ObservationIgnored private var folderTagRefreshTask: Task<Void, Never>?

    private var folderRules: SpokenWordFolderRules {
        if let cached = cachedFolderRules, cached.revision == revision { return cached.rules }
        let rules = SpokenWordFolderRules(
            folders: SpokenWordFolderTag.spokenWordFolders(in: overrides),
            sources: folderTagSources
        )
        cachedFolderRules = (revision, rules)
        return rules
    }

    /// Whether `path` of a source is tagged as spoken word.
    func isSpokenWordFolder(sourceID: String, path: String) -> Bool {
        overrides[SpokenWordFolderTag.overrideKey(sourceID: sourceID, path: path)] == .spokenWord
    }

    /// Tags (or untags) a scanned folder. The library is reclassified shortly
    /// after, once for a burst of changes.
    func setSpokenWordFolder(_ isSpokenWord: Bool, sourceID: String, path: String) {
        let key = SpokenWordFolderTag.overrideKey(sourceID: sourceID, path: path)
        let kind: ListeningContentKind? = isSpokenWord ? .spokenWord : nil
        guard overrides[key] != kind else { return }
        overrides[key] = kind
        ledger.overrideChangedAt[key] = Date()
        didChange(cloud: .prompt)
        scheduleFolderTagReclassification()
    }

    /// Takes the current source list: path spelling for the rules, and tags
    /// on folders a source no longer scans are dropped, so a tag never keeps
    /// acting through a folder that was deselected. A source whose folders
    /// are still being chosen (none saved yet) keeps its tags.
    func updateFolderTagSources(_ sources: [MusicSource]) {
        let descriptors = sources.filter { !$0.isDeleted }.map(LibraryFolderSourceDescriptor.init(source:))
        let scanned = Dictionary(
            sources.map { ($0.id, Set($0.scannedDirectories)) },
            uniquingKeysWith: { first, _ in first }
        )
        var removed = false
        let now = Date()
        for key in overrides.keys where SpokenWordFolderTag.isFolderKey(key) {
            guard let tag = SpokenWordFolderTag.parse(overrideKey: key),
                  let directories = scanned[tag.sourceID],
                  !directories.isEmpty,
                  !directories.contains(tag.path) else { continue }
            overrides.removeValue(forKey: key)
            ledger.overrideChangedAt[key] = now
            removed = true
        }
        let descriptorsChanged = descriptors != folderTagSources
        folderTagSources = descriptors
        if removed {
            didChange(cloud: .prompt)
        } else if descriptorsChanged {
            cachedFolderRules = nil
        }
        let hasTags = overrides.keys.contains(where: SpokenWordFolderTag.isFolderKey)
        if removed || (descriptorsChanged && hasTags) {
            scheduleFolderTagReclassification()
        }
    }

    private func scheduleFolderTagReclassification() {
        folderTagRefreshTask?.cancel()
        folderTagRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: .primuseSpokenWordClassificationDidChange, object: nil)
        }
    }

    /// Applies an explicit kind to whole selections (a song, an album, a
    /// folder). Passing nil returns those songs to inference.
    func setKind(_ kind: ListeningContentKind?, forSongIDs songIDs: [String]) {
        guard !songIDs.isEmpty else { return }
        var changed = false
        let now = Date()
        for songID in songIDs where overrides[songID] != kind {
            overrides[songID] = kind
            // Stamped so a later correction on another device wins, and a
            // return to inference is not undone by an older override.
            ledger.overrideChangedAt[songID] = now
            changed = true
        }
        // Music does not carry a resume position, so dropping it here keeps a
        // reclassified item from resuming mid-file later.
        if kind == .music {
            for songID in songIDs {
                if removePosition(songID, at: now) { changed = true }
                if removeFinished(songID, at: now) { changed = true }
            }
        }
        guard changed else { return }
        didChange(cloud: .prompt)
    }

    // MARK: - Positions

    func position(forSongID songID: String) -> StoredPosition? { positions[songID] }

    func resumePosition(for song: Song) -> TimeInterval? {
        SpokenWordProgressPolicy.resumePosition(
            stored: positions[song.id]?.position,
            duration: resolvedDuration(for: song)
        )
    }

    /// Records where playback is. Called on pause, track change, seek,
    /// backgrounding and on a timer while playing.
    func rememberPosition(
        _ position: TimeInterval,
        duration: TimeInterval,
        forSongID songID: String
    ) {
        guard SpokenWordProgressPolicy.shouldRemember(
            position: position,
            duration: duration
        ) else {
            // Inside the closing stretch the item counts as heard: the
            // position goes and the item is marked finished, so the book
            // moves on to the next chapter.
            if duration > 0, position.isFinite,
               position > duration - SpokenWordProgressPolicy.completionTailThreshold {
                markFinished(true, songIDs: [songID])
            } else {
                clearPosition(forSongID: songID)
            }
            return
        }
        let stored = StoredPosition(
            position: position,
            duration: duration,
            updatedAt: Date()
        )
        guard positions[songID] != stored else { return }
        positions[songID] = stored
        ledger.positionClearedAt.removeValue(forKey: songID)
        // Listening again to a finished item reopens it.
        let reopened = removeFinished(songID, at: stored.updatedAt)
        evictOldestIfNeeded()
        didChange(cloud: reopened ? .prompt : .relaxed)
    }

    // MARK: - Finished

    func isFinished(songID: String) -> Bool { finishedAt[songID] != nil }

    func finishedDate(forSongID songID: String) -> Date? { finishedAt[songID] }

    /// Marks items heard (or not). Marking heard drops the resume position;
    /// marking unheard only clears the mark.
    func markFinished(_ finished: Bool, songIDs: [String]) {
        guard !songIDs.isEmpty else { return }
        var changed = false
        let now = Date()
        for songID in songIDs {
            if finished {
                if finishedAt[songID] == nil {
                    finishedAt[songID] = now
                    ledger.unfinishedAt.removeValue(forKey: songID)
                    changed = true
                }
                if removePosition(songID, at: now) { changed = true }
            } else if removeFinished(songID, at: now) {
                changed = true
            }
        }
        guard changed else { return }
        evictOldestIfNeeded()
        didChange(cloud: .prompt)
    }

    /// Removes a position as a listener's decision (a tombstone goes with
    /// it), unlike eviction or pruning, which only forget locally.
    @discardableResult
    private func removePosition(_ songID: String, at date: Date) -> Bool {
        guard positions.removeValue(forKey: songID) != nil else { return false }
        ledger.positionClearedAt[songID] = date
        return true
    }

    @discardableResult
    private func removeFinished(_ songID: String, at date: Date) -> Bool {
        guard finishedAt.removeValue(forKey: songID) != nil else { return false }
        ledger.unfinishedAt[songID] = date
        return true
    }

    // MARK: - Bookmarks

    func bookmarks(forSongID songID: String) -> [SpokenWordBookmark] {
        bookmarks[songID] ?? []
    }

    @discardableResult
    func addBookmark(_ bookmark: SpokenWordBookmark) -> Bool {
        let existing = bookmarks[bookmark.songID] ?? []
        let updated = SpokenWordBookmarkPolicy.inserting(bookmark, into: existing)
        guard updated != existing else { return false }
        bookmarks[bookmark.songID] = updated
        let now = Date()
        // The policy drops the oldest past its limit; that is a deletion too.
        let kept = Set(updated.map(\.id))
        for dropped in existing where !kept.contains(dropped.id) {
            ledger.bookmarkEditedAt.removeValue(forKey: dropped.id.uuidString)
            ledger.bookmarkDeletedAt[dropped.id.uuidString] = now
        }
        didChange(cloud: .prompt)
        return true
    }

    func removeBookmark(id: UUID, songID: String) {
        guard var list = bookmarks[songID] else { return }
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return }
        bookmarks[songID] = list.isEmpty ? nil : list
        ledger.bookmarkEditedAt.removeValue(forKey: id.uuidString)
        ledger.bookmarkDeletedAt[id.uuidString] = Date()
        didChange(cloud: .prompt)
    }

    func renameBookmark(id: UUID, songID: String, title: String) {
        guard var list = bookmarks[songID],
              let index = list.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, list[index].title != trimmed else { return }
        list[index].title = trimmed
        bookmarks[songID] = list
        ledger.bookmarkEditedAt[id.uuidString] = Date()
        didChange(cloud: .prompt)
    }

    func clearPosition(forSongID songID: String) {
        guard removePosition(songID, at: Date()) else { return }
        didChange(cloud: .prompt)
    }

    // MARK: - Per-book speed

    /// The speed the listener picked for this book, nil when it follows the
    /// global spoken-word speed.
    func playbackRate(forBookID bookID: String) -> Float? { bookRates[bookID] }

    /// Stores (or with nil, forgets) a book's own speed.
    func setPlaybackRate(_ rate: Float?, forBookID bookID: String) {
        let value = rate.map(SpokenWordPlaybackRatePolicy.clamped)
        guard bookRates[bookID] != value else { return }
        bookRates[bookID] = value
        ledger.rateChangedAt[bookID] = Date()
        didChange(cloud: .prompt)
    }

    /// Drops positions for songs that no longer exist. Called after a library
    /// removal rather than on every change: the map is small and a missing
    /// entry is harmless.
    func pruneMissingSongs(existingIDs: Set<String>) {
        let stale = positions.keys.filter { !existingIDs.contains($0) }
        // Folder tags are not songs; they go with their folder instead
        // (`updateFolderTagSources`).
        let staleOverrides = overrides.keys.filter {
            !existingIDs.contains($0) && !SpokenWordFolderTag.isFolderKey($0)
        }
        let staleBookmarks = bookmarks.keys.filter { !existingIDs.contains($0) }
        let staleFinished = finishedAt.keys.filter { !existingIDs.contains($0) }
        guard !stale.isEmpty || !staleOverrides.isEmpty
            || !staleBookmarks.isEmpty || !staleFinished.isEmpty else { return }
        for songID in stale { positions.removeValue(forKey: songID) }
        for songID in staleOverrides { overrides.removeValue(forKey: songID) }
        for songID in staleBookmarks { bookmarks.removeValue(forKey: songID) }
        for songID in staleFinished { finishedAt.removeValue(forKey: songID) }
        // Forgotten locally only: another device may still have these songs,
        // so no tombstones and nothing to push.
        didChange(cloud: nil)
    }

    private func resolvedDuration(for song: Song) -> TimeInterval {
        // A bare row can still have a remembered duration from when it played.
        song.duration > 0 ? song.duration : (positions[song.id]?.duration ?? 0)
    }

    private func evictOldestIfNeeded() {
        let limit = SpokenWordProgressPolicy.maximumRememberedItems
        if positions.count > limit {
            let ordered = positions.sorted { $0.value.updatedAt < $1.value.updatedAt }
            for (songID, _) in ordered.prefix(positions.count - limit) {
                positions.removeValue(forKey: songID)
            }
        }
        if finishedAt.count > limit * 4 {
            let ordered = finishedAt.sorted { $0.value < $1.value }
            for (songID, _) in ordered.prefix(finishedAt.count - limit * 4) {
                finishedAt.removeValue(forKey: songID)
            }
        }
    }

    // MARK: - Persistence

    private func didChange(cloud urgency: CloudUrgency?) {
        revision &+= 1
        scheduleSave()
        if let urgency { scheduleCloudPush(urgency) }
        NotificationCenter.default.post(name: .primuseSpokenWordDidChange, object: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        overrides = payload.overrides.compactMapValues(ListeningContentKind.init(rawValue:))
        positions = payload.positions
        bookmarks = payload.bookmarks ?? [:]
        finishedAt = payload.finishedAt ?? [:]
        bookRates = payload.bookRates ?? [:]
        ledger = payload.ledger ?? SpokenWordSyncLedger()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the local file now, without the two-second debounce and without
    /// touching iCloud. The player calls it with each listening position, so
    /// a crash loses at most one autosave interval, not that plus the debounce.
    func persistLocally() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    /// Writes immediately. Used when the app is about to lose the foreground,
    /// where a debounced save would never run.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
        if pendingCloudUrgency != nil { pushToCloudNow() }
    }

    private func saveNow() {
        let payload = Payload(
            overrides: overrides.mapValues(\.rawValue),
            positions: positions,
            bookmarks: bookmarks,
            finishedAt: finishedAt,
            bookRates: bookRates,
            ledger: ledger
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - iCloud

    private var localRecords: SpokenWordLocalRecords {
        SpokenWordLocalRecords(
            positions: positions.mapValues {
                .init(position: $0.position, duration: $0.duration, updatedAt: $0.updatedAt)
            },
            finishedAt: finishedAt,
            bookmarks: bookmarks,
            overrides: overrides.mapValues(\.rawValue),
            bookRates: bookRates,
            ledger: ledger
        )
    }

    /// Batches pushes: a position alone waits up to a minute and a half (it
    /// moves every 15 s while a book plays), a deliberate change goes within
    /// seconds. `flush()` sends whatever is pending right away.
    private func scheduleCloudPush(_ urgency: CloudUrgency) {
        guard syncsThroughICloud else { return }
        if let pending = pendingCloudUrgency, pending >= urgency, cloudPushTask != nil { return }
        pendingCloudUrgency = max(pendingCloudUrgency ?? urgency, urgency)
        cloudPushTask?.cancel()
        let delay = urgency == .prompt ? Self.promptCloudPushDelay : Self.relaxedCloudPushDelay
        cloudPushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pushToCloudNow()
        }
    }

    /// Merges with whatever the cloud copy holds first, so a push never
    /// replaces another device's entries it has not seen.
    private func pushToCloudNow() {
        cloudPushTask?.cancel()
        cloudPushTask = nil
        pendingCloudUrgency = nil
        guard syncsThroughICloud else { return }
        let remote = SpokenWordSyncPolicy.decode(
            UserDefaults.standard.data(forKey: Self.cloudStorageKey)
        ) ?? .empty
        let local = SpokenWordSyncPolicy.state(from: localRecords)
        let merged = SpokenWordSyncPolicy.pruned(
            SpokenWordSyncPolicy.merge(local, remote),
            now: Date()
        )
        adopt(merged)
        publish(merged, over: remote)
    }

    /// The cloud copy changed (another device pushed, or sync was switched
    /// on): take what it has that this device does not, and push back only
    /// if this device has something it lacks.
    private func mergeCloudCopy() {
        guard let remote = SpokenWordSyncPolicy.decode(
            UserDefaults.standard.data(forKey: Self.cloudStorageKey)
        ) else { return }
        let local = SpokenWordSyncPolicy.state(from: localRecords)
        let merged = SpokenWordSyncPolicy.pruned(
            SpokenWordSyncPolicy.merge(local, remote),
            now: Date()
        )
        adopt(merged)
        publish(merged, over: remote)
    }

    /// Replaces the local dictionaries with a merged state when it differs.
    private func adopt(_ merged: SpokenWordSyncState) {
        let records = SpokenWordSyncPolicy.records(from: merged)
        let nextPositions = records.positions.mapValues {
            StoredPosition(position: $0.position, duration: $0.duration, updatedAt: $0.updatedAt)
        }
        let nextOverrides = records.overrides.compactMapValues(ListeningContentKind.init(rawValue:))
        let contentChanged = nextPositions != positions
            || records.finishedAt != finishedAt
            || records.bookmarks != bookmarks
            || nextOverrides != overrides
            || records.bookRates != bookRates
        let overridesChanged = nextOverrides != overrides
        guard contentChanged || records.ledger != ledger else { return }
        positions = nextPositions
        finishedAt = records.finishedAt
        bookmarks = records.bookmarks
        overrides = nextOverrides
        bookRates = records.bookRates
        ledger = records.ledger
        guard contentChanged else {
            scheduleSave()
            return
        }
        didChange(cloud: nil)
        if overridesChanged {
            NotificationCenter.default.post(name: .primuseSpokenWordClassificationDidChange, object: nil)
        }
    }

    /// Writes the upload document and pushes it, unless the cloud already
    /// holds exactly that.
    private func publish(_ merged: SpokenWordSyncState, over remote: SpokenWordSyncState) {
        let upload = SpokenWordSyncPolicy.uploadState(merged)
        guard upload != remote, let data = SpokenWordSyncPolicy.encode(upload) else { return }
        UserDefaults.standard.set(data, forKey: Self.cloudStorageKey)
        CloudKVSSync.shared.markChanged(key: Self.cloudStorageKey)
    }
}

extension Notification.Name {
    static let primuseSpokenWordDidChange = Notification.Name("primuse.spokenWordDidChange")
    /// Posted when kind corrections arrived from another device, so the
    /// library can re-run the music / spoken-word split.
    static let primuseSpokenWordClassificationDidChange =
        Notification.Name("primuse.spokenWordClassificationDidChange")
}
