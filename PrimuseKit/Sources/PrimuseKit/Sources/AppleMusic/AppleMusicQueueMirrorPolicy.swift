import Foundation

/// Pure policy for deciding whether a MusicKit queue snapshot may replace
/// Primuse's canonical playback queue.
public enum AppleMusicQueueMirrorPolicy {
    /// Local-library entries can expose display metadata without a Song item.
    /// Resolve only an unambiguous identity; an entry ID is not a music item ID.
    public static func songID(
        resolvedIdentity: AppleMusicTrackIdentity?,
        entryTitle: String,
        entrySubtitle: String?,
        identities: AppleMusicTrackIdentityIndex
    ) -> String? {
        identities.canonicalID(for: resolvedIdentity ?? AppleMusicTrackIdentity(
            itemID: "", title: entryTitle, artist: entrySubtitle
        ))
    }

    /// A filtered native queue can identify a unique song without resolving
    /// every entry. Repeated occurrences still require the full order mapping.
    public static func uniqueEntryID(
        songID: String?, expectedSongIDs: [String], queueEntryIDs: [UUID]
    ) -> UUID? {
        guard let songID, expectedSongIDs.count == queueEntryIDs.count,
              let index = expectedSongIDs.firstIndex(of: songID),
              !expectedSongIDs[(index + 1)...].contains(songID) else { return nil }
        return queueEntryIDs[index]
    }

    /// Bind repeated occurrences only after the complete song order matches.
    /// Other unresolved entries must not block a uniquely identified song.
    public static func resolvedEntryIDs(
        nativeEntryIDs: [String],
        nativeSongIDs: [String?],
        expectedSongIDs: [String],
        queueEntryIDs: [UUID]
    ) -> [String: UUID]? {
        guard !queueEntryIDs.isEmpty,
              nativeEntryIDs.count == nativeSongIDs.count,
              expectedSongIDs.count == queueEntryIDs.count,
              Set(nativeEntryIDs).count == nativeEntryIDs.count,
              Set(queueEntryIDs).count == queueEntryIDs.count else { return nil }
        if nativeSongIDs.count == expectedSongIDs.count,
           zip(nativeSongIDs, expectedSongIDs).allSatisfy({ $0 == $1 }) {
            return Dictionary(uniqueKeysWithValues: zip(nativeEntryIDs, queueEntryIDs))
        }
        var resolved: [String: UUID] = [:]
        let nativeOccurrences = Dictionary(grouping: nativeSongIDs.compactMap { $0 }, by: { $0 })
        let expectedOccurrences = Dictionary(grouping: zip(expectedSongIDs, queueEntryIDs), by: { $0.0 })
        for (nativeID, songID) in zip(nativeEntryIDs, nativeSongIDs) {
            guard let songID, nativeOccurrences[songID]?.count == 1,
                  let occurrences = expectedOccurrences[songID], occurrences.count == 1 else { continue }
            resolved[nativeID] = occurrences[0].1
        }
        return resolved.isEmpty ? nil : resolved
    }

    public static func isActiveSession(
        sessionGeneration: UInt64,
        activeGeneration: UInt64,
        isCancelled: Bool
    ) -> Bool {
        sessionGeneration == activeGeneration && !isCancelled
    }

    public static func shouldApplySnapshot(
        sessionGeneration: UInt64,
        activeGeneration: UInt64,
        isCancelled: Bool,
        primuseOwnsCanonicalQueue: Bool,
        snapshotCount: Int
    ) -> Bool {
        isActiveSession(
            sessionGeneration: sessionGeneration,
            activeGeneration: activeGeneration,
            isCancelled: isCancelled
        )
            && !primuseOwnsCanonicalQueue
            && snapshotCount > 0
    }
}
