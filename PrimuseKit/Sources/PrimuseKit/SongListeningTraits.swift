import Foundation

/// `Song` already carries every field the listening features read; the
/// conformance lives apart from the model so the features' own sources stay
/// free of the database layer.
extension Song: ListeningSongTraits {}

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
