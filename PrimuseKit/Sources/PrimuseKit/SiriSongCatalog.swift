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
        var byID: [String: Int] = [:]
        for index in songs.indices {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            let song = songs[index]
            guard song.isPlayable else { continue }
            let eligible = autoreleasepool {
                let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return !title.isEmpty && title.count <= 3
                    && SiriRadioStationCatalog.safeDisplayName(title) != nil
                    && SiriRadioStationCatalog.isSafeIdentifier(song.id)
            }
            if eligible { byID[song.id] = index }
        }
        var selected: [Song] = []
        for id in priorityIDs {
            if let index = byID.removeValue(forKey: id) {
                selected.append(songs[index])
                if selected.count == limit { return selected }
            }
        }
        guard !Task.isCancelled else { return [] }
        let remaining = CarPlayListSelection.firstSorted(byID.values, limit: limit - selected.count) {
            songs[$0].dateAdded != songs[$1].dateAdded
                ? songs[$0].dateAdded > songs[$1].dateAdded
                : songs[$0].id < songs[$1].id
        }
        guard !Task.isCancelled else { return [] }
        selected.append(contentsOf: remaining.map { songs[$0] })
        return selected
    }
}
