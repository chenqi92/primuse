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
/// Local only for now. Nothing here goes through CloudKit yet, so a position
/// does not follow the listener to another device.
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
    }

    static let shared = SpokenWordStore()

    /// Explicit per-song corrections. Absent means "whatever the file says".
    private(set) var overrides: [String: ListeningContentKind] = [:]
    private(set) var positions: [String: StoredPosition] = [:]
    /// Marks the listener set inside items, ordered by position.
    private(set) var bookmarks: [String: [SpokenWordBookmark]] = [:]
    /// Items listened to the end (or marked so by hand). A book's shelf
    /// progress and "continue from" are built from this and `positions`.
    private(set) var finishedAt: [String: Date] = [:]
    /// Bumped on every change so views and the library aggregation can depend
    /// on one cheap value instead of observing two dictionaries.
    @ObservationIgnored private(set) var revision = 0

    private let storeURL: URL
    private var saveTask: Task<Void, Never>?

    private init(storeURL: URL? = nil) {
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
    }

    // MARK: - Classification

    func kind(for song: Song) -> ListeningContentKind {
        SpokenWordContentPolicy.classify(
            filePath: song.filePath,
            genre: song.genre,
            userOverride: overrides[song.id]
        )
    }

    func isSpokenWord(_ song: Song) -> Bool { kind(for: song) == .spokenWord }

    /// Whether this song's kind was set by hand rather than inferred.
    func hasOverride(songID: String) -> Bool { overrides[songID] != nil }

    /// Snapshot for the library aggregation, which classifies off the main
    /// actor and must not reach back into this object.
    var overrideSnapshot: [String: ListeningContentKind] { overrides }

    /// Applies an explicit kind to whole selections (a song, an album, a
    /// folder). Passing nil returns those songs to inference.
    func setKind(_ kind: ListeningContentKind?, forSongIDs songIDs: [String]) {
        guard !songIDs.isEmpty else { return }
        var changed = false
        for songID in songIDs {
            if let kind {
                if overrides[songID] != kind {
                    overrides[songID] = kind
                    changed = true
                }
            } else if overrides.removeValue(forKey: songID) != nil {
                changed = true
            }
        }
        // Music does not carry a resume position, so dropping it here keeps a
        // reclassified item from resuming mid-file later.
        if kind == .music {
            for songID in songIDs {
                if positions.removeValue(forKey: songID) != nil { changed = true }
                if finishedAt.removeValue(forKey: songID) != nil { changed = true }
            }
        }
        guard changed else { return }
        didChange()
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
        // Listening again to a finished item reopens it.
        finishedAt.removeValue(forKey: songID)
        evictOldestIfNeeded()
        didChange()
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
                    changed = true
                }
                if positions.removeValue(forKey: songID) != nil { changed = true }
            } else if finishedAt.removeValue(forKey: songID) != nil {
                changed = true
            }
        }
        guard changed else { return }
        evictOldestIfNeeded()
        didChange()
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
        didChange()
        return true
    }

    func removeBookmark(id: UUID, songID: String) {
        guard var list = bookmarks[songID] else { return }
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return }
        bookmarks[songID] = list.isEmpty ? nil : list
        didChange()
    }

    func renameBookmark(id: UUID, songID: String, title: String) {
        guard var list = bookmarks[songID],
              let index = list.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, list[index].title != trimmed else { return }
        list[index].title = trimmed
        bookmarks[songID] = list
        didChange()
    }

    func clearPosition(forSongID songID: String) {
        guard positions.removeValue(forKey: songID) != nil else { return }
        didChange()
    }

    /// Drops positions for songs that no longer exist. Called after a library
    /// removal rather than on every change: the map is small and a missing
    /// entry is harmless.
    func pruneMissingSongs(existingIDs: Set<String>) {
        let stale = positions.keys.filter { !existingIDs.contains($0) }
        let staleOverrides = overrides.keys.filter { !existingIDs.contains($0) }
        let staleBookmarks = bookmarks.keys.filter { !existingIDs.contains($0) }
        let staleFinished = finishedAt.keys.filter { !existingIDs.contains($0) }
        guard !stale.isEmpty || !staleOverrides.isEmpty
            || !staleBookmarks.isEmpty || !staleFinished.isEmpty else { return }
        for songID in stale { positions.removeValue(forKey: songID) }
        for songID in staleOverrides { overrides.removeValue(forKey: songID) }
        for songID in staleBookmarks { bookmarks.removeValue(forKey: songID) }
        for songID in staleFinished { finishedAt.removeValue(forKey: songID) }
        didChange()
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

    private func didChange() {
        revision &+= 1
        scheduleSave()
        NotificationCenter.default.post(name: .primuseSpokenWordDidChange, object: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        overrides = payload.overrides.compactMapValues(ListeningContentKind.init(rawValue:))
        positions = payload.positions
        bookmarks = payload.bookmarks ?? [:]
        finishedAt = payload.finishedAt ?? [:]
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes immediately. Used when the app is about to lose the foreground,
    /// where a debounced save would never run.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    private func saveNow() {
        let payload = Payload(
            overrides: overrides.mapValues(\.rawValue),
            positions: positions,
            bookmarks: bookmarks,
            finishedAt: finishedAt
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

extension Notification.Name {
    static let primuseSpokenWordDidChange = Notification.Name("primuse.spokenWordDidChange")
}
