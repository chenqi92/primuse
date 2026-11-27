import Foundation

/// Keeps duplicate cleanup selections conservative across every UI. Catalogue
/// entries are immutable, and at least one writable copy always remains in a
/// group even when a read-only streaming version is also present.
public enum DuplicateCleanupSelectionPolicy {
    public static func defaultKeptSongIDs(
        readOnlySongIDs: Set<String>,
        writableSongIDs: [String],
        preferredWritableSongID: String?
    ) -> Set<String> {
        var keptSongIDs = readOnlySongIDs
        if let preferredWritableSongID,
           writableSongIDs.contains(preferredWritableSongID) {
            keptSongIDs.insert(preferredWritableSongID)
        } else if let firstWritableSongID = writableSongIDs.first {
            keptSongIDs.insert(firstWritableSongID)
        }
        return keptSongIDs
    }

    public static func toggledKeptSongIDs(
        currentKeptSongIDs: Set<String>,
        toggledSongID: String,
        readOnlySongIDs: Set<String>,
        writableSongIDs: [String]
    ) -> Set<String> {
        let writableSongIDSet = Set(writableSongIDs)
        let validSongIDs = readOnlySongIDs.union(writableSongIDSet)
        var keptSongIDs = currentKeptSongIDs.intersection(validSongIDs)
        keptSongIDs.formUnion(readOnlySongIDs)

        guard writableSongIDSet.contains(toggledSongID) else {
            return keptSongIDs
        }

        if keptSongIDs.contains(toggledSongID) {
            let keptWritableCount = writableSongIDs.reduce(into: 0) { count, songID in
                if keptSongIDs.contains(songID) {
                    count += 1
                }
            }
            guard keptWritableCount > 1 else {
                return keptSongIDs
            }
            keptSongIDs.remove(toggledSongID)
        } else {
            keptSongIDs.insert(toggledSongID)
        }
        return keptSongIDs
    }

    public static func removableSongIDs(
        writableSongIDs: [String],
        keptSongIDs: Set<String>
    ) -> Set<String> {
        Set(writableSongIDs.lazy.filter { !keptSongIDs.contains($0) })
    }
}
