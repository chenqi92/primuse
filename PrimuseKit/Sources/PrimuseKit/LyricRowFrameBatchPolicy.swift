import Foundation

public enum LyricRowFrameBatchPolicy {
    public static func merging<Frame>(
        id: String,
        frame: Frame,
        into current: [String: Frame],
        retaining validIDs: Set<String>
    ) -> [String: Frame] {
        var next = current.filter { validIDs.contains($0.key) }
        guard validIDs.contains(id) else { return next }
        next[id] = frame
        return next
    }
}

public enum LyricRowLayoutPolicy {
    /// Returns the stable, unscaled text width that keeps a render-layer scale
    /// inside the lyric viewport. Reserving this width for every row also keeps
    /// line wrapping unchanged when playback emphasis moves between rows.
    public static func unscaledContentWidth(
        viewportWidth: Double,
        horizontalPadding: Double,
        maximumVisualScale: Double
    ) -> Double {
        let viewport = viewportWidth.isFinite ? max(0, viewportWidth) : 0
        let padding = horizontalPadding.isFinite ? max(0, horizontalPadding) : 0
        let scale = maximumVisualScale.isFinite ? max(1, maximumVisualScale) : 1
        return max(0, viewport - padding * 2) / scale
    }
}

public enum LyricDepthEffectPolicy {
    private static let radiusStep = 1.25
    private static let maximumRadius = 5.0
    private static let passedLineDepthOffset = 1

    /// Keeps the upcoming lyric readable while pushing already-sung rows one
    /// depth step farther away. The linear progression gives every takeover a
    /// visible focus change, then caps the cost for distant rows.
    public static func blurRadius(
        forRow rowIndex: Int,
        activeRow activeIndex: Int,
        isEnabled: Bool,
        isSynchronized: Bool
    ) -> Double {
        guard isEnabled,
              isSynchronized,
              rowIndex >= 0,
              activeIndex >= 0,
              rowIndex != activeIndex else { return 0 }

        let distance = abs(rowIndex - activeIndex)
        let depth = distance + (rowIndex < activeIndex ? passedLineDepthOffset : 0)
        return min(maximumRadius, Double(depth) * radiusStep)
    }
}

public enum LyricPlaybackPositionPolicy {
    public enum ScrollTarget: Equatable, Sendable {
        case line(Int)
        case interlude(afterLine: Int)
    }

    public static func shouldFollowPlayback(in lyrics: [LyricLine]) -> Bool {
        shouldFollowPlayback(in: lyrics, isSynchronized: \.isSynchronized)
    }

    public static func shouldFollowPlayback<Element>(
        in lyrics: [Element],
        isSynchronized: (Element) -> Bool
    ) -> Bool {
        !lyrics.isEmpty && lyrics.allSatisfy(isSynchronized)
    }

    /// Returns the lyric row that should be active at the supplied playback
    /// time, or `nil` while playback is still before the first timestamp.
    /// Parsed lyric lines are expected to be ordered by timestamp.
    ///
    /// 同一个时间戳上留了好几行时（没能配对的双语 LRC、多声部叠唱）高亮落在
    /// 这一组的第一行：唱的是原文，注音和译文写在它后面。
    public static func activeLineIndex(
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0
    ) -> Int? {
        activeLineIndex(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead,
            timestamp: \.timestamp
        )
    }

    public static func activeLineIndex<Element>(
        in lyrics: [Element],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        timestamp: (Element) -> TimeInterval
    ) -> Int? {
        guard !lyrics.isEmpty else { return nil }

        let target = playbackTime + lookahead
        var lower = 0
        var upper = lyrics.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timestamp(lyrics[middle]) <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        var index = lower - 1
        let activeTimestamp = timestamp(lyrics[index])
        while index > 0,
              abs(activeTimestamp - timestamp(lyrics[index - 1])) <= sameRowTolerance {
            index -= 1
        }
        return index
    }

    /// 同一句的几行来自同一个 `[mm:ss.xx]`，解析出来本应完全相等；留一点余量
    /// 是为了写成 `[00:12.00]` 和 `[00:12.001]` 这种手抄的文件。与
    /// `LyricBilingualPairingPolicy` 判定同一簇用的余量一致。
    private static let sameRowTolerance: TimeInterval = 0.002

    /// Companion rows share the source timestamp and must not end its word
    /// sweep. Only a later timestamp group can take over the highlight.
    public static func wordLevelDeactivationTime(
        in lyrics: [LyricLine],
        afterLine index: Int,
        lookahead: TimeInterval = 0
    ) -> TimeInterval? {
        guard lyrics.indices.contains(index) else { return nil }
        let currentStart = lyrics[index].timestamp
        guard let next = lyrics.dropFirst(index + 1).first(where: {
            $0.timestamp - currentStart > sameRowTolerance
        }) else { return nil }
        return max(currentStart, next.timestamp - max(0, lookahead))
    }

    /// Keeps the semantic active row unchanged during a long instrumental
    /// break while allowing a lyrics surface to move to a dedicated interlude
    /// marker. Line-level lyrics have no explicit end time, so their visible
    /// singing window is conservatively estimated before the break begins.
    public static func scrollTarget(
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        lineLevelEstimatedDuration: TimeInterval = 3.5,
        interludeActivationDelay: TimeInterval = 6,
        minimumInterludeDuration: TimeInterval = 12
    ) -> ScrollTarget? {
        guard let activeIndex = activeLineIndex(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead
        ) else { return nil }
        guard let window = interludeWindow(
            afterLine: activeIndex,
            in: lyrics,
            lineLevelEstimatedDuration: lineLevelEstimatedDuration,
            interludeActivationDelay: interludeActivationDelay,
            minimumInterludeDuration: minimumInterludeDuration
        ) else {
            return .line(activeIndex)
        }

        let targetTime = playbackTime + max(0, lookahead)
        guard targetTime >= window.activation,
              targetTime < window.nextLineStart else {
            return .line(activeIndex)
        }
        return .interlude(afterLine: activeIndex)
    }

    public static func hasLongInterlude(
        afterLine index: Int,
        in lyrics: [LyricLine],
        lineLevelEstimatedDuration: TimeInterval = 3.5,
        minimumInterludeDuration: TimeInterval = 12
    ) -> Bool {
        interludeWindow(
            afterLine: index,
            in: lyrics,
            lineLevelEstimatedDuration: lineLevelEstimatedDuration,
            interludeActivationDelay: 0,
            minimumInterludeDuration: minimumInterludeDuration
        ) != nil
    }

    private static func interludeWindow(
        afterLine index: Int,
        in lyrics: [LyricLine],
        lineLevelEstimatedDuration: TimeInterval,
        interludeActivationDelay: TimeInterval,
        minimumInterludeDuration: TimeInterval
    ) -> (activation: TimeInterval, nextLineStart: TimeInterval)? {
        guard lyrics.indices.contains(index) else { return nil }

        let line = lyrics[index]
        // 同一时间戳上的兄弟行（注音、译文、另一个声部）不是「下一句」，
        // 拿它们当下一句会把每一段间奏的时长算成 0。
        guard let nextLineStart = lyrics[(index + 1)...]
            .first(where: { $0.timestamp > line.timestamp })?.timestamp else {
            return nil
        }
        let fallbackEnd = line.timestamp + max(0, lineLevelEstimatedDuration)
        let explicitEnd = line.endTime.flatMap { $0.isFinite ? $0 : nil }
        let estimatedEnd = max(line.timestamp, explicitEnd ?? fallbackEnd)
        let duration = nextLineStart - estimatedEnd
        guard estimatedEnd.isFinite,
              nextLineStart.isFinite,
              duration >= max(0, minimumInterludeDuration) else { return nil }

        return (
            activation: estimatedEnd + max(0, interludeActivationDelay),
            nextLineStart: nextLineStart
        )
    }
}

public struct NowPlayingLyricsMetadataPresentation: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let lyricLineID: String?

    public init(title: String, artist: String, lyricLineID: String?) {
        self.title = title
        self.artist = artist
        self.lyricLineID = lyricLineID
    }
}

public enum NowPlayingLyricsMetadataPolicy {
    /// Lines that can drive a lock-screen/now-playing update.
    ///
    /// The result only depends on the lyric document, so callers that refresh
    /// on a timer should filter once per song instead of once per tick.
    public static func synchronizedLines(_ lyrics: [LyricLine]) -> [LyricLine] {
        lyrics.filter {
            $0.isSynchronized
                && $0.timestamp.isFinite
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func presentation(
        canonicalTitle: String,
        artistName: String?,
        lyrics: [LyricLine],
        playbackTime: TimeInterval,
        isEnabled: Bool,
        isLiveStream: Bool,
        prefersStableTitle: Bool = false
    ) -> NowPlayingLyricsMetadataPresentation {
        presentation(
            canonicalTitle: canonicalTitle,
            artistName: artistName,
            synchronizedLyrics: synchronizedLines(lyrics),
            playbackTime: playbackTime,
            isEnabled: isEnabled,
            isLiveStream: isLiveStream,
            prefersStableTitle: prefersStableTitle
        )
    }

    /// Variant for callers that already hold `synchronizedLines(_:)` output.
    public static func presentation(
        canonicalTitle: String,
        artistName: String?,
        synchronizedLyrics: [LyricLine],
        playbackTime: TimeInterval,
        isEnabled: Bool,
        isLiveStream: Bool,
        prefersStableTitle: Bool = false
    ) -> NowPlayingLyricsMetadataPresentation {
        let title = canonicalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canonical = NowPlayingLyricsMetadataPresentation(
            title: title,
            artist: artist,
            lyricLineID: nil
        )

        guard isEnabled,
              !isLiveStream,
              playbackTime.isFinite,
              playbackTime >= 0 else { return canonical }

        guard let firstLine = synchronizedLyrics.first,
              playbackTime >= firstLine.timestamp,
              let activeIndex = LyricPlaybackPositionPolicy.activeLineIndex(
                in: synchronizedLyrics,
                at: playbackTime
              ) else { return canonical }

        let line = synchronizedLyrics[activeIndex]
        if prefersStableTitle {
            // CarPlay throttles title changes within the same content item.
            // Keep its track identity stable and advance lyrics in the subtitle.
            return NowPlayingLyricsMetadataPresentation(
                title: title,
                artist: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
                lyricLineID: line.id
            )
        }
        let secondary = [title, artist].filter { !$0.isEmpty }.joined(separator: " · ")
        return NowPlayingLyricsMetadataPresentation(
            title: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: secondary,
            lyricLineID: line.id
        )
    }
}

public enum NowPlayingLyricsLoadRetryPolicy {
    // Keep transient recovery bounded: a cache write notification or foreground
    // transition can trigger another load without repeatedly scraping a song that
    // genuinely has no lyrics.
    private static let retryDelays: [TimeInterval] = [2, 10]

    public static func delay(
        afterEmptyResultCount emptyResultCount: Int,
        hasDemand: Bool,
        isLiveStream: Bool
    ) -> TimeInterval? {
        guard hasDemand,
              !isLiveStream,
              emptyResultCount > 0,
              retryDelays.indices.contains(emptyResultCount - 1) else { return nil }
        return retryDelays[emptyResultCount - 1]
    }
}
