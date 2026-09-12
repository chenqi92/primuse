import Foundation

/// Startup prewarm is a convenience sweep, not a transfer the user asked for.
/// It must never duplicate a prefetch that the player already registered in
/// the single-flight background cache registry, and it must stop entirely when
/// automatic audio caching is off.
public enum StartupPrewarmAdmissionPolicy {
    /// Resume song first, then queue order. Songs that are already seeded or
    /// already have an in-flight background cache task are dropped so the sweep
    /// cannot start a second head+tail fetch for the same song.
    public static func songsToPrewarm(
        resumeSongID: String?,
        queueSongIDs: [String],
        alreadyPrewarmedIDs: Set<String>,
        inFlightBackgroundCacheSongIDs: Set<String>,
        requestedCount: Int,
        automaticCachingEnabled: Bool
    ) -> [String] {
        guard automaticCachingEnabled else { return [] }

        var admitted: [String] = []
        var seen: Set<String> = []

        func admit(_ songID: String) -> Bool {
            guard !songID.isEmpty,
                  !seen.contains(songID),
                  !alreadyPrewarmedIDs.contains(songID),
                  !inFlightBackgroundCacheSongIDs.contains(songID) else { return false }
            seen.insert(songID)
            admitted.append(songID)
            return true
        }

        if let resumeSongID {
            _ = admit(resumeSongID)
        }

        let tailLimit = max(0, requestedCount)
        guard tailLimit > 0 else { return admitted }

        var appended = 0
        for songID in queueSongIDs {
            guard appended < tailLimit else { break }
            if songID == resumeSongID { continue }
            if admit(songID) { appended += 1 }
        }
        return admitted
    }
}
