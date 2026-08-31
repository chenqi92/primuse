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
