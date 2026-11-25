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
        shortcuts(priorityIDs: priorityIDs, limit: limit) { body in
            for song in songs where !body(song) { return }
        }
    }

    /// 同 `shortcuts(from:priorityIDs:limit:)`,但歌按库内顺序流式交进来(`body` 返回 false 时停):
    /// 只留下够格的优先歌和其余够格歌里最新的 `limit` 首,不需要整库数组。
    public static func shortcuts(
        priorityIDs: [String],
        limit: Int,
        forEachSong: (_ body: (Song) -> Bool) throws -> Void
    ) rethrows -> [Song] {
        guard limit > 0 else { return [] }
        let priority = Set(priorityIDs)
        var prioritized: [String: Song] = [:]
        // 其余够格的歌,按(加入时间新的在前,同时间按 id)排好,至多 `limit` 首。
        var newest: [Song] = []
        func newer(_ lhs: Song, _ rhs: Song) -> Bool {
            lhs.dateAdded != rhs.dateAdded ? lhs.dateAdded > rhs.dateAdded : lhs.id < rhs.id
        }
        var seen = 0
        var cancelled = false
        try forEachSong { song in
            if seen.isMultiple(of: 256), Task.isCancelled {
                cancelled = true
                return false
            }
            seen += 1
            guard song.isPlayable, isShortcutEligible(song) else { return true }
            if priority.contains(song.id) {
                prioritized[song.id] = song
                return true
            }
            if newest.count == limit, let last = newest.last, !newer(song, last) { return true }
            var low = 0
            var high = newest.count
            while low < high {
                let middle = (low + high) / 2
                if newer(newest[middle], song) { low = middle + 1 } else { high = middle }
            }
            newest.insert(song, at: low)
            if newest.count > limit { newest.removeLast() }
            return true
        }
        guard !cancelled else { return [] }
        var selected: [Song] = []
        for id in priorityIDs {
            if let song = prioritized.removeValue(forKey: id) {
                selected.append(song)
                if selected.count == limit { return selected }
            }
        }
        guard !Task.isCancelled else { return [] }
        selected.append(contentsOf: newest.prefix(limit - selected.count))
        return selected
    }

    /// 能当快捷指令短语的歌:三个字以内、显示名与 id 都安全。
    private static func isShortcutEligible(_ song: Song) -> Bool {
        autoreleasepool {
            let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return !title.isEmpty && title.count <= 3
                && SiriRadioStationCatalog.safeDisplayName(title) != nil
                && SiriRadioStationCatalog.isSafeIdentifier(song.id)
        }
    }
}
