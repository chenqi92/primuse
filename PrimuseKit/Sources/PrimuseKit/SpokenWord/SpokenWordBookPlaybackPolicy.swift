import Foundation

extension SpokenWordBookGrouping {
    /// The id of the book `item` belongs to — the same id
    /// `books(from:)` gives that book, so a per-book setting can be looked up
    /// from the item that is playing without regrouping the library.
    public static func bookID(for item: SpokenWordBookItem) -> String {
        groupingKey(for: item)
    }

    /// The book that now holds most of `chapterIDs` — for a page keeping a
    /// book open while the library regroups. A book's id changes when the
    /// first tags are read: a folder of untagged files is named after the
    /// folder, and the album its first tagged chapter carries takes over.
    public static func bookID(
        holdingMostOf chapterIDs: Set<String>,
        among books: some Sequence<SpokenWordBook>
    ) -> String? {
        guard !chapterIDs.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for book in books {
            let count = book.items.reduce(0) { $0 + (chapterIDs.contains($1.id) ? 1 : 0) }
            if count > 0 { counts[book.id] = count }
        }
        return mostHeld(counts)?.id
    }

    /// Old book id → the book that took over its chapters, for each book of
    /// `previous` that `current` no longer has (both item id → book id, as
    /// `bookIDs(for:)` gives them). The successor is found the way an open
    /// book page follows its book (`bookID(holdingMostOf:among:)`), and must
    /// hold more than half of the old book's chapters still in the library:
    /// a book whose chapters scattered or went away has none.
    public static func renamedBookIDs(
        from previous: [String: String],
        to current: [String: String]
    ) -> [String: String] {
        guard !previous.isEmpty, !current.isEmpty else { return [:] }
        let currentBookIDs = Set(current.values)
        var tallies: [String: [String: Int]] = [:]
        for (itemID, oldID) in previous where !currentBookIDs.contains(oldID) {
            guard let newID = current[itemID] else { continue }
            tallies[oldID, default: [:]][newID, default: 0] += 1
        }
        var renames: [String: String] = [:]
        for (oldID, counts) in tallies {
            guard let best = mostHeld(counts) else { continue }
            if best.count * 2 > counts.values.reduce(0, +) { renames[oldID] = best.id }
        }
        return renames
    }

    /// The book holding the most, the smaller id on a tie.
    static func mostHeld(_ counts: [String: Int]) -> (id: String, count: Int)? {
        counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }.map { ($0.key, $0.value) }
    }
}

extension SpokenWordPlaybackRatePolicy {
    /// The spoken-word speed for one book: its own when the listener set one,
    /// the global spoken-word speed otherwise.
    public static func bookRate(stored: Float?, globalSpokenWordRate: Float) -> Float {
        if let stored, stored.isFinite { return clamped(stored) }
        return clamped(globalSpokenWordRate)
    }

    /// What to store when the listener picks `rate` for a book: nothing when
    /// it equals the global speed, so a later change of the global speed
    /// still reaches the book.
    public static func storedBookRate(for rate: Float, globalSpokenWordRate: Float) -> Float? {
        let value = clamped(rate)
        return abs(value - clamped(globalSpokenWordRate)) < 0.001 ? nil : value
    }
}

/// Moving through a book whose items carry no chapter marks: the items
/// themselves are the chapters.
public enum SpokenWordBookNavigationPolicy {
    /// The item `offset` steps from `currentItemID` in reading order, or nil
    /// at either end of the book (or when the current item is not in it).
    public static func adjacentItemID(
        from currentItemID: String,
        offset: Int,
        in bookItemIDs: [String]
    ) -> String? {
        guard let index = bookItemIDs.firstIndex(of: currentItemID) else { return nil }
        let target = index + offset
        guard bookItemIDs.indices.contains(target), target != index else { return nil }
        return bookItemIDs[target]
    }
}

/// 有声书「单章循环」锁定的章节。
///
/// 多文件书（或无章节标记的单文件）里 `chapterIndex` 为 `nil`，循环整个 `songID` 文件；
/// 带章节标记的文件（M4B / ID3 / 服务端 / AI 章节）里 `chapterIndex` 指向文件内那一章，
/// 播到下一章起点（或最后一章播到文件尾）时回到本章起点。
public struct SpokenWordChapterRepeatTarget: Equatable, Hashable, Sendable {
    public var songID: String
    public var chapterIndex: Int?
    public var bookID: String?

    public init(songID: String, chapterIndex: Int? = nil, bookID: String? = nil) {
        self.songID = songID
        self.chapterIndex = chapterIndex
        self.bookID = bookID
    }
}

/// 当前锁定章节的循环边界。`end == nil` 表示这一章在文件尾（或片尾跳过处）结束。
public struct SpokenWordChapterRepeatBounds: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval?

    public init(start: TimeInterval, end: TimeInterval? = nil) {
        self.start = start
        self.end = end
    }
}

public enum SpokenWordChapterRepeatPolicy {
    /// 距离文件内章节边界这么近就视为到达，由准点定时与播放时钟共同兜底。
    public static let endTolerance: TimeInterval = 0.05
    /// 防止零长度或重合的异常章节标记触发死循环跳回。
    public static let minimumChapterLength: TimeInterval = 0.5

    /// 计算当前正在播放曲目上锁定章节的起点与文件内终点。
    public static func bounds(
        for target: SpokenWordChapterRepeatTarget,
        songID: String,
        duration: TimeInterval,
        chapters: [MediaChapter],
        introOutro: SpokenWordIntroOutro? = nil
    ) -> SpokenWordChapterRepeatBounds? {
        guard target.songID == songID else { return nil }
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let introStart = introOutro.flatMap {
            SpokenWordIntroOutroPolicy.startPosition(resume: nil, duration: safeDuration, skip: $0)
        } ?? 0

        if let index = target.chapterIndex, chapters.indices.contains(index) {
            let rawStart = chapters[index].startTime.isFinite ? max(0, chapters[index].startTime) : 0
            let nextBoundary = chapters[(index + 1)...].first {
                $0.startTime.isFinite && $0.startTime >= rawStart + minimumChapterLength
            }?.startTime
            var start = rawStart
            if index == 0, introStart > rawStart {
                let upperLimit = nextBoundary ?? (safeDuration > 0 ? safeDuration : nil)
                if upperLimit.map({ introStart < $0 - 1 }) ?? true {
                    start = introStart
                }
            }
            return SpokenWordChapterRepeatBounds(start: start, end: nextBoundary)
        }

        let start: TimeInterval
        if introStart > 0, safeDuration == 0 || introStart < safeDuration - 1 {
            start = introStart
        } else {
            start = 0
        }
        return SpokenWordChapterRepeatBounds(start: start, end: nil)
    }

    /// 播放头是否已到达文件内章节终点（仅对 `bounds.end != nil` 成立）。
    public static func reachedEnd(
        of bounds: SpokenWordChapterRepeatBounds,
        at time: TimeInterval,
        currentChapterIndex: Int?,
        lockedChapterIndex: Int?
    ) -> Bool {
        guard let end = bounds.end, time.isFinite else { return false }
        if time >= end - endTolerance { return true }
        if let locked = lockedChapterIndex, let current = currentChapterIndex, current > locked {
            return true
        }
        return false
    }

    /// 按当前倍速换算距离文件内章节终点还有多少真实秒数；`bounds.end == nil` 时返回 `nil`。
    public static func timeUntilEnd(
        of bounds: SpokenWordChapterRepeatBounds,
        at time: TimeInterval,
        rate: Double
    ) -> TimeInterval? {
        guard let end = bounds.end, time.isFinite else { return nil }
        let safeRate = rate.isFinite && rate > 0 ? rate : 1
        return max(0, end - time) / safeRate
    }

    /// 曲目切换、分类变化或章节标记异步加载/变更后，校准当前的单章循环锁定：
    /// - 离开有声书或换到另一本书时关闭；
    /// - 同一本书内换章时自动跟到新章；
    /// - 同一文件内章节标记加载完成或变更时校准章节下标。
    public static func reconciled(
        target: SpokenWordChapterRepeatTarget?,
        currentSongID: String?,
        currentBookID: String?,
        isAudiobook: Bool,
        chapters: [MediaChapter],
        currentChapterIndex: Int?,
        currentTime: TimeInterval
    ) -> SpokenWordChapterRepeatTarget? {
        guard let target else { return nil }
        guard isAudiobook, let songID = currentSongID else { return nil }
        if let targetBook = target.bookID, let currentBook = currentBookID, targetBook != currentBook {
            return nil
        }
        let resolvedBookID = currentBookID ?? target.bookID
        let safeTime = currentTime.isFinite ? max(0, currentTime) : 0
        if target.songID != songID {
            let index = chapters.isEmpty ? nil : (currentChapterIndex ?? chapters.chapterIndex(at: safeTime) ?? 0)
            return SpokenWordChapterRepeatTarget(songID: songID, chapterIndex: index, bookID: resolvedBookID)
        }
        if chapters.isEmpty {
            return SpokenWordChapterRepeatTarget(songID: songID, chapterIndex: nil, bookID: resolvedBookID)
        }
        if let existing = target.chapterIndex, chapters.indices.contains(existing) {
            return SpokenWordChapterRepeatTarget(songID: songID, chapterIndex: existing, bookID: resolvedBookID)
        }
        let index = currentChapterIndex ?? chapters.chapterIndex(at: safeTime) ?? 0
        return SpokenWordChapterRepeatTarget(songID: songID, chapterIndex: index, bookID: resolvedBookID)
    }

    /// 用户手动拖动或跳秒后更新文件内锁定章节。
    /// `preservesChapterOnBackwardCrossing` 为真时（例如在章首附近按「快退 15 秒」退到上一章末尾），
    /// 保留原锁定章节，让播放回到本章后仍在本章末尾循环。
    public static func retargetedAfterUserSeek(
        _ target: SpokenWordChapterRepeatTarget?,
        songID: String,
        seekTime: TimeInterval,
        chapters: [MediaChapter],
        preservesChapterOnBackwardCrossing: Bool = false
    ) -> SpokenWordChapterRepeatTarget? {
        guard var target, target.songID == songID, !chapters.isEmpty, seekTime.isFinite else {
            return target
        }
        let newIndex = chapters.chapterIndex(at: max(0, seekTime)) ?? 0
        if preservesChapterOnBackwardCrossing, let locked = target.chapterIndex, newIndex < locked {
            return target
        }
        target.chapterIndex = newIndex
        return target
    }

    /// 目录中的某一行是否正是当前单章循环锁定的章节。
    public static func matches(
        _ target: SpokenWordChapterRepeatTarget?,
        row: SpokenWordContentsRow
    ) -> Bool {
        guard let target, target.songID == row.itemID else { return false }
        switch row.kind {
        case .item:
            return target.chapterIndex == nil
        case let .chapter(index, _):
            return target.chapterIndex == index
        }
    }
}
