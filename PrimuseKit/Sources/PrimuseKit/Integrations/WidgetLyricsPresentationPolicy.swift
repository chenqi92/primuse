import Foundation

public enum WidgetLyricPresentationRole: String, Hashable, Sendable {
    case previous
    case current
    case next
}

public struct WidgetLyricPresentationRow: Identifiable, Hashable, Sendable {
    public let index: Int
    public let text: String
    public let role: WidgetLyricPresentationRole

    public var id: Int { index }

    public init(index: Int, text: String, role: WidgetLyricPresentationRole) {
        self.index = index
        self.text = text
        self.role = role
    }
}

/// Chooses a stable lyric window for fixed-height widgets. Reducing the row
/// budget always preserves the current line before dropping surrounding lines.
public enum WidgetLyricsPresentationPolicy {
    /// Returns the last line that has started at `playbackPosition`.
    public static func anchorIndex(
        for playbackPosition: TimeInterval,
        in lines: [WidgetLyricLine]
    ) -> Int {
        guard !lines.isEmpty else { return 0 }
        var index = 0
        for (candidate, line) in lines.enumerated() where line.time <= playbackPosition {
            index = candidate
        }
        return index
    }

    /// New snapshots preserve the exact playback position. Legacy snapshots
    /// use the start time of their clamped anchor line.
    public static func playbackPosition(in snapshot: LyricsSnapshot) -> TimeInterval {
        if let position = snapshot.playbackPosition,
           position.isFinite,
           position >= 0 {
            return position
        }
        guard !snapshot.lines.isEmpty else { return 0 }
        let index = min(max(snapshot.anchorIndex, 0), snapshot.lines.count - 1)
        return snapshot.lines[index].time
    }

    /// Dates at which the displayed lyric changes. An index of -1 means the
    /// first line has not started. Long timelines overlap at the next reload.
    public static func timeline(
        for snapshot: LyricsSnapshot,
        from now: Date,
        maximumFutureEntries: Int
    ) -> (entries: [(date: Date, index: Int)], nextReloadDate: Date?) {
        let lines = snapshot.lines
        let rate = snapshot.playbackRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
        let elapsed = snapshot.isPlaying ? max(0, now.timeIntervalSince(snapshot.updatedAt)) : 0
        let position = playbackPosition(in: snapshot) + elapsed * rate
        let current = lines.first.map { $0.time <= position ? anchorIndex(for: position, in: lines) : -1 } ?? -1
        var entries = [(date: now, index: current)]
        guard snapshot.isPlaying, maximumFutureEntries > 0 else { return (entries, nil) }

        var index = current + 1
        while index < lines.count {
            let start = lines[index].time
            while index + 1 < lines.count, lines[index + 1].time == start {
                index += 1
            }
            if start.isFinite, start > position {
                if entries.count > maximumFutureEntries {
                    // Keep planned entries available while WidgetKit requests the next batch.
                    return (entries, entries[max(1, (entries.count - 1) * 3 / 4)].date)
                }
                entries.append((now.addingTimeInterval((start - position) / rate), index))
            }
            index += 1
        }
        return (entries, nil)
    }

    /// Applies a newer persisted playback sample to lyric timing without
    /// reloading or rewriting the lyric text. A different current song makes
    /// the snapshot invalid immediately; a missing playback payload keeps the
    /// lyric snapshot usable when the standalone lyrics widget is enabled on
    /// its own.
    public static func snapshotAlignedWithPlayback(
        _ snapshot: LyricsSnapshot?,
        playback: PlaybackState?
    ) -> LyricsSnapshot? {
        guard var snapshot else { return nil }
        guard let playback else { return snapshot }
        guard let currentSongID = playback.currentSongID,
              currentSongID == snapshot.songID else {
            return nil
        }
        // 封面以播放状态那一份为准：歌词快照在歌词读完那一刻抄的封面名，那时封面可能还没写好
        // （Mac 上播放状态在后台写，晚一步；Apple Music 等后到的封面更晚），之后不会再抄一次，
        // 歌词小组件就一直没有封面或停在上一首的封面。
        snapshot.coverImageName = playback.coverImageName
        guard let playbackUpdatedAt = playback.updatedAt,
              playbackUpdatedAt > snapshot.updatedAt,
              playback.currentTime.isFinite else {
            return snapshot
        }

        let position = max(0, playback.currentTime)
        snapshot.playbackPosition = position
        snapshot.anchorIndex = anchorIndex(for: position, in: snapshot.lines)
        snapshot.isPlaying = playback.isPlaying
        snapshot.updatedAt = playbackUpdatedAt
        return snapshot
    }

    /// Mirrors a newer lyric-side playback sample into the Now Playing state.
    /// Lyrics may finish loading after a pause/seek while the macOS state
    /// publisher is still doing App Group I/O, so whichever sample is newer
    /// must also supply the authoritative play/pause bit.
    public static func playbackStateAlignedWithLyrics(
        _ playback: PlaybackState?,
        lyrics: LyricsSnapshot?
    ) -> PlaybackState? {
        guard var playback,
              let lyrics,
              playback.currentSongID == lyrics.songID,
              let position = lyrics.playbackPosition,
              position.isFinite,
              lyrics.updatedAt > (playback.updatedAt ?? .distantPast) else {
            return playback
        }
        playback.currentTime = max(0, position)
        playback.isPlaying = lyrics.isPlaying
        playback.updatedAt = lyrics.updatedAt
        return playback
    }

    public static func rows(
        in lines: [WidgetLyricLine],
        anchorIndex: Int,
        maximumRowCount: Int
    ) -> [WidgetLyricPresentationRow] {
        guard !lines.isEmpty, maximumRowCount > 0 else { return [] }

        let currentIndex = min(max(anchorIndex, 0), lines.count - 1)
        let rowCount = min(lines.count, min(maximumRowCount, 3))

        let startIndex: Int
        switch rowCount {
        case 1:
            startIndex = currentIndex
        case 2:
            startIndex = currentIndex < lines.count - 1
                ? currentIndex
                : max(0, currentIndex - 1)
        default:
            startIndex = min(max(0, currentIndex - 1), lines.count - rowCount)
        }

        return (startIndex..<(startIndex + rowCount)).map { index in
            let role: WidgetLyricPresentationRole
            if index < currentIndex {
                role = .previous
            } else if index == currentIndex {
                role = .current
            } else {
                role = .next
            }
            return WidgetLyricPresentationRow(index: index, text: lines[index].text, role: role)
        }
    }

    /// New snapshots carry the direction resolved from the complete LRC/ELRC
    /// document, including `[la:]` metadata. Legacy snapshots fall back to
    /// dominant-script inference without changing mixed-direction text order.
    public static func writingDirection(
        for lines: [WidgetLyricLine],
        preferredDirection: LyricWritingDirection?
    ) -> LyricWritingDirection {
        if let preferredDirection { return preferredDirection }

        let lyricLines = lines.enumerated().map { index, line in
            LyricLine(
                id: "widget-\(index)",
                timestamp: line.time,
                text: line.text,
                isSynchronized: false
            )
        }
        return LyricWritingDirectionPolicy.resolve(in: lyricLines)
    }
}

/// 小组件拿不到正在放的这首的歌词时叫一声 App(达尔文通知,跨进程,不带数据)。
/// App 只在切歌、回到前台时才查桌面上放没放带歌词的小组件;后台播放时新放上去的,
/// 不叫这一声就要等到下一首才有歌词。
public enum WidgetLyricsDemandSignal {
    public static let name = PrimuseConstants.appGroupIdentifier + ".widget.lyricsDemand"

    /// 正在放一首歌(不是电台),却没有这首的歌词快照。
    public static func shouldRequest(playback: PlaybackState?, snapshot: LyricsSnapshot?) -> Bool {
        guard let playback, let songID = playback.currentSongID,
              playback.playbackKind != .liveRadio else { return false }
        guard let snapshot, snapshot.songID == songID, !snapshot.lines.isEmpty else { return true }
        return false
    }

    public static func post() {
        #if canImport(Darwin)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
        #endif
    }
}
