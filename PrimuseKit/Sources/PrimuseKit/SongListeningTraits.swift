import Foundation

/// `Song` already carries every field the listening features read; the
/// conformance lives apart from the model so the features' own sources stay
/// free of the database layer.
extension Song: ListeningSongTraits {
    /// The same grading as the quality badge (`audioQuality`), folded to three steps.
    public var listeningQuality: ListeningAudioQuality {
        switch audioQuality {
        case .dsd, .hiRes: .hiRes
        case .lossless: .lossless
        case .standard: .lossy
        }
    }
}

// Entry points for the library's own song arrays. The generic passes are
// specialized here, inside the module, so a whole-library walk from the app
// reads `Song` fields directly instead of through protocol witnesses (about
// twice as fast on a 400K-song library).

public extension AlbumCandidateIndex {
    static func build(
        librarySongs songs: [Song],
        libraryGeneration: UInt64,
        isCancelled: () -> Bool = { false }
    ) -> AlbumCandidateIndex? {
        build(songs: songs, libraryGeneration: libraryGeneration, isCancelled: isCancelled)
    }
}

public extension ListeningIntentEngine {
    static func availability(
        librarySongs songs: [Song],
        intents: [ListeningIntent],
        history: ListeningHistoryIndex,
        libraryGeneration: UInt64,
        isCancelled: () -> Bool = { false }
    ) -> ListeningIntentAvailability? {
        availability(
            songs: songs,
            intents: intents,
            history: history,
            libraryGeneration: libraryGeneration,
            isCancelled: isCancelled
        )
    }

    static func queueSongIDs(
        for intent: ListeningIntent,
        librarySongs songs: [Song],
        history: ListeningHistoryIndex,
        seed: UInt64,
        isCancelled: () -> Bool = { false }
    ) -> [String] {
        queueSongIDs(for: intent, songs: songs, history: history, seed: seed, isCancelled: isCancelled)
    }

    static func matchingSongIDs(
        for intent: ListeningIntent,
        librarySongs songs: [Song],
        history: ListeningHistoryIndex,
        limit: Int,
        isCancelled: () -> Bool = { false }
    ) -> (ids: [String], total: Int)? {
        matchingSongIDs(for: intent, songs: songs, history: history, limit: limit, isCancelled: isCancelled)
    }
}

public extension ListeningProfile {
    static func build(
        librarySongs songs: [Song],
        history: ListeningHistoryIndex,
        isCancelled: () -> Bool = { false }
    ) -> ListeningProfile? {
        build(songs: songs, history: history, isCancelled: isCancelled)
    }
}

// Entry points for the library catalog: the same passes over the songs the
// catalog streams in library order, without materializing the whole library.
// Like the array entry points above they live in this module so the walk is
// specialized for `Song`.

public extension ListeningIntentEngine {
    /// `availability(librarySongs:)` over `scope` in the catalog.
    static func availability(
        catalog: LibraryCatalog,
        scope: LibrarySongScope,
        intents: [ListeningIntent],
        history: ListeningHistoryIndex,
        libraryGeneration: UInt64,
        isCancelled: () -> Bool = { false }
    ) throws -> ListeningIntentAvailability? {
        var tally = AvailabilityTally(intents: intents, history: history)
        guard try streamSongs(catalog, scope, excluding: [], isCancelled: isCancelled, { tally.add($0) }) else { return nil }
        return tally.finish(libraryGeneration: libraryGeneration)
    }

    /// `queueSongIDs(for:librarySongs:)` over `scope` in the catalog, leaving out `excludedIDs`.
    static func queueSongIDs(
        for intent: ListeningIntent,
        catalog: LibraryCatalog,
        scope: LibrarySongScope,
        excluding excludedIDs: Set<String> = [],
        history: ListeningHistoryIndex,
        seed: UInt64,
        isCancelled: () -> Bool = { false }
    ) throws -> [String] {
        guard var sampler = QueueSampler(for: intent, history: history, seed: seed) else { return [] }
        guard try streamSongs(catalog, scope, excluding: excludedIDs, isCancelled: isCancelled, { sampler.add($0) }) else { return [] }
        return sampler.finish()
    }

    /// `matchingSongIDs(for:librarySongs:)` over `scope` in the catalog.
    static func matchingSongIDs(
        for intent: ListeningIntent,
        catalog: LibraryCatalog,
        scope: LibrarySongScope,
        history: ListeningHistoryIndex,
        limit: Int,
        isCancelled: () -> Bool = { false }
    ) throws -> (ids: [String], total: Int)? {
        guard var collector = MatchingCollector(for: intent, history: history, limit: limit) else { return ([], 0) }
        guard try streamSongs(catalog, scope, excluding: [], isCancelled: isCancelled, { collector.add($0) }) else { return nil }
        return (collector.ids, collector.total)
    }

    /// Feeds `scope` to `body` in library order; false when cancelled.
    private static func streamSongs(
        _ catalog: LibraryCatalog,
        _ scope: LibrarySongScope,
        excluding excludedIDs: Set<String>,
        isCancelled: () -> Bool,
        _ body: (Song) -> Void
    ) throws -> Bool {
        var position = 0
        var cancelled = false
        try catalog.forEachSong(scope) { _, song in
            if position.isMultiple(of: 1_024), isCancelled() {
                cancelled = true
                return false
            }
            position += 1
            if excludedIDs.isEmpty || !excludedIDs.contains(song.id) { body(song) }
            return true
        }
        return !cancelled
    }
}

public extension ListeningProfile {
    /// `build(librarySongs:)` over `scope` in the catalog (give it the music scope).
    static func build(
        catalog: LibraryCatalog,
        scope: LibrarySongScope,
        history: ListeningHistoryIndex,
        isCancelled: () -> Bool = { false }
    ) throws -> ListeningProfile? {
        var builder = Builder(history: history)
        var position = 0
        var cancelled = false
        try catalog.forEachSong(scope) { _, song in
            if position.isMultiple(of: 1_024), isCancelled() {
                cancelled = true
                return false
            }
            position += 1
            builder.add(song)
            return true
        }
        guard !cancelled, !isCancelled() else { return nil }
        return builder.finish()
    }
}

