import Foundation

public enum SiriSongCatalog {
    /// App Shortcuts share 1,000 expanded phrases per language. Reserve the
    /// largest localized phrase count for every existing parameter first.
    public static func shortcutLimit(
        appNameCount: Int,
        settingsCount: Int,
        stationCount: Int,
        bookCount: Int,
        podcastCount: Int
    ) -> Int {
        let reserved = 5 + 6 * 3 + 8 * 4 + max(0, settingsCount)
            + max(0, stationCount) * 4 + max(0, bookCount) * 3
            + max(0, podcastCount) * 3
        return max(0, 1_000 / max(1, appNameCount) - reserved)
    }

    /// Supplement Core Spotlight's short-title results without duplicating
    /// the whole library into the much smaller App Shortcut phrase budget.
    /// Callers supply the visible music library; IDs, not titles, identify
    /// tracks, including different recordings with the same title.
    public static func shortcuts(from songs: [Song], priorityIDs: [String], limit: Int) -> [Song] {
        guard limit > 0 else { return [] }
        var byID: [String: Song] = [:]
        for song in songs where song.isPlayable {
            guard let title = SiriRadioStationCatalog.safeDisplayName(song.title),
                  title.count <= 3,
                  SiriRadioStationCatalog.isSafeIdentifier(song.id) else { continue }
            byID[song.id] = song
        }
        var selected: [Song] = []
        for id in priorityIDs {
            if let song = byID.removeValue(forKey: id) {
                selected.append(song)
                if selected.count == limit { return selected }
            }
        }
        let remaining = byID.values.sorted {
            $0.dateAdded != $1.dateAdded ? $0.dateAdded > $1.dateAdded : $0.id < $1.id
        }
        selected.append(contentsOf: remaining.prefix(limit - selected.count))
        return selected
    }
}
