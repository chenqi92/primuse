import Testing
@testable import PrimuseKit

@Suite("Lyric playback positioning")
struct LyricPlaybackPositionPolicyTests {
    @Test("Companion rows do not deactivate the source word timeline")
    func deactivationSkipsTheCurrentTimestampGroup() throws {
        let lyrics = [
            LyricLine(timestamp: 61.364, text: "Source"),
            LyricLine(timestamp: 61.364, text: "Reading"),
            LyricLine(timestamp: 61.365, text: "Translation"),
            LyricLine(timestamp: 64.166, text: "Next"),
        ]
        let end = try #require(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics, afterLine: 0, lookahead: 0.1
        ))
        #expect(abs(end - 64.066) < 0.000001)
        #expect(63.0 < end)
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics, at: 63, lookahead: 0.1
        ) == 0)
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics, at: end + 0.001, lookahead: 0.1
        ) == 3)
    }

    @Test("A final timestamp group has no next-line deactivation")
    func finalGroupKeepsItsWordTimeline() {
        let lyrics = [
            LyricLine(timestamp: 88.507, text: "Source"),
            LyricLine(timestamp: 88.507, text: "Reading"),
            LyricLine(timestamp: 88.507, text: "Translation"),
        ]
        for index in lyrics.indices {
            #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
                in: lyrics, afterLine: index, lookahead: 0.1
            ) == nil)
        }
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics, afterLine: -1
        ) == nil)
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: [], afterLine: 0
        ) == nil)
    }

    @Test("Ordinary line takeovers retain lookahead and the current start bound")
    func deactivationPreservesOrdinaryTakeovers() {
        let lyrics = [
            LyricLine(timestamp: 1, text: "First"),
            LyricLine(timestamp: 1.05, text: "Second"),
        ]
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics, afterLine: 0, lookahead: 0.1
        ) == 1)
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics, afterLine: 0, lookahead: -1
        ) == 1.05)
    }

    @Test("Lyrics loaded in the middle of playback select the current row")
    func selectsCurrentRowAfterDelayedLoad() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 12, text: "Second"),
            LyricLine(id: "third", timestamp: 24, text: "Third"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 19
        ) == 1)
    }

    @Test("Lookahead can advance to an imminent lyric row")
    func appliesLookahead() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 10, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 9.8,
            lookahead: 0.25
        ) == 1)
    }

    @Test("Playback waits before the first synchronized lyric")
    func waitsBeforeFirstLyric() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 3.1, text: "First"),
            LyricLine(id: "second", timestamp: 8, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 2.99,
            lookahead: 0.1
        ) == nil)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 2.99,
            lookahead: 0.1
        ) == nil)
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 3,
            lookahead: 0.1
        ) == 0)
    }

    @Test("Empty lyrics have no active row")
    func emptyLyricsHaveNoActiveRow() {
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: [],
            at: 30
        ) == nil)
    }

    @Test("Only synchronized lyrics follow playback")
    func synchronizationControlsAutomaticFollow() {
        let plain = [
            LyricLine(timestamp: 0, text: "First", isSynchronized: false),
            LyricLine(timestamp: 0, text: "Second", isSynchronized: false),
        ]
        let synchronized = [
            LyricLine(timestamp: 0, text: "First", isSynchronized: true),
            LyricLine(timestamp: 10, text: "Second", isSynchronized: true),
        ]

        #expect(!LyricPlaybackPositionPolicy.shouldFollowPlayback(in: plain))
        #expect(LyricPlaybackPositionPolicy.shouldFollowPlayback(in: synchronized))
    }

    @Test("A platform lyric model can reuse timestamp positioning")
    func supportsPlatformSpecificLyricModels() {
        struct Line { let time: Double }
        let lyrics = [Line(time: 0), Line(time: 8), Line(time: 16)]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 12,
            timestamp: { $0.time }
        ) == 1)
    }

    @Test("Long line-level gaps scroll to an interlude without advancing the active lyric")
    func longLineLevelGapUsesInterludeTarget() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 20
        ) == 0)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 20
        ) == .interlude(afterLine: 0))
    }

    @Test("Interlude scrolling waits until the current lyric has visibly finished")
    func interludeTargetHonorsActivationDelay() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 9.4
        ) == .line(0))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 9.5
        ) == .interlude(afterLine: 0))
    }

    @Test("Ordinary lyric spacing never creates an interlude target")
    func ordinaryGapStaysOnActiveLine() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 10, text: "Second"),
        ]

        #expect(!LyricPlaybackPositionPolicy.hasLongInterlude(
            afterLine: 0,
            in: lyrics
        ))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 9
        ) == .line(0))
    }

    @Test("Word-level interludes use the final syllable end time")
    func wordLevelGapUsesExplicitEndTime() {
        let lyrics = [
            LyricLine(
                id: "first",
                timestamp: 0,
                text: "First",
                syllables: [LyricSyllable(text: "First", start: 0, end: 20)]
            ),
            LyricLine(id: "second", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 25.9
        ) == .line(0))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 26
        ) == .interlude(afterLine: 0))
    }

    @Test("The next timestamp ends the interlude and selects its lyric")
    func nextLineEndsInterlude() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 40
        ) == .line(1))
    }

    /// refs #152 —— 配对不成立时（多声部，或结构本身就说不清的文件）同一个
    /// 时间戳上会留着好几行。高亮落在最后一行等于把译文当成正在唱的那一句：
    /// 原文反而是灰的。唱的是第一行。
    @Test("同一时间戳的多行高亮落在第一行")
    func picksTheFirstRowOfATimestampCluster() {
        let lyrics = [
            LyricLine(id: "source", timestamp: 12, text: "두고 봐 Babe"),
            LyricLine(id: "roman", timestamp: 12, text: "du go bwa Babe"),
            LyricLine(id: "translation", timestamp: 12, text: "走着瞧吧 宝贝"),
            LyricLine(id: "next", timestamp: 20, text: "Next"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(in: lyrics, at: 15) == 0)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 15) == .line(0))
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(in: lyrics, at: 21) == 3)
    }

    /// 同一时间戳上的兄弟行不是「下一句」：拿它们当下一句，每一段间奏的时长
    /// 都会算成 0，间奏标记就永远不出现。
    @Test("间奏判定跳过同一时间戳的兄弟行")
    func interludeLooksPastSiblingRows() {
        let lyrics = [
            LyricLine(id: "source", timestamp: 0, text: "First"),
            LyricLine(id: "translation", timestamp: 0, text: "第一句"),
            LyricLine(id: "next", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.hasLongInterlude(afterLine: 0, in: lyrics))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 26
        ) == .interlude(afterLine: 0))
    }

    @Test("Now Playing metadata uses the active synchronized lyric")
    func nowPlayingMetadataUsesActiveLyric() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First", isSynchronized: true),
            LyricLine(id: "second", timestamp: 12, text: "Second", isSynchronized: true),
        ]

        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 15,
            isEnabled: true,
            isLiveStream: false
        )

        #expect(presentation.title == "Second")
        #expect(presentation.artist == "Song · Artist")
        #expect(presentation.lyricLineID == "second")
    }

    @Test("Now Playing metadata advances one synchronized lyric at a time")
    func nowPlayingMetadataAdvancesWithPlayback() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First", isSynchronized: true),
            LyricLine(id: "second", timestamp: 12, text: "Second", isSynchronized: true),
        ]

        let first = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 3,
            isEnabled: true,
            isLiveStream: false
        )
        let second = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 15,
            isEnabled: true,
            isLiveStream: false
        )

        #expect(first.title == "First")
        #expect(first.lyricLineID == "first")
        #expect(second.title == "Second")
        #expect(second.lyricLineID == "second")
    }

    @Test("CarPlay keeps the title stable across lyric changes and seeks")
    func carPlayLyricsAdvanceInSubtitle() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 8, text: "First", isSynchronized: true),
            LyricLine(id: "second", timestamp: 12, text: "Second", isSynchronized: true),
        ]
        let presentations = [3.0, 9, 15, 9].map { time in
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: lyrics,
                playbackTime: time,
                isEnabled: true,
                isLiveStream: false,
                prefersStableTitle: true
            )
        }

        #expect(presentations.map(\.title) == ["Song", "Song", "Song", "Song"])
        #expect(presentations.map(\.artist) == ["Artist", "First", "Second", "First"])
        #expect(presentations.map(\.lyricLineID) == [nil, "first", "second", "first"])
    }

    @Test("Connecting and disconnecting CarPlay changes layout without changing the lyric")
    func carPlayConnectionChangesLyricsLayout() {
        let lyrics = [LyricLine(id: "line", timestamp: 0, text: "Lyric", isSynchronized: true)]
        let presentations = [false, true, false].map { connected in
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: lyrics,
                playbackTime: 10,
                isEnabled: true,
                isLiveStream: false,
                prefersStableTitle: connected
            )
        }

        #expect(presentations.map(\.title) == ["Lyric", "Song", "Lyric"])
        #expect(presentations.map(\.artist) == ["Song · Artist", "Lyric", "Song · Artist"])
        #expect(presentations.allSatisfy { $0.lyricLineID == "line" })
    }

    @Test("Now Playing metadata keeps the song title before the first lyric", arguments: [false, true])
    func nowPlayingMetadataWaitsForFirstLyric(prefersStableTitle: Bool) {
        let lyrics = [
            LyricLine(id: "first", timestamp: 8, text: "First", isSynchronized: true),
        ]

        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 3,
            isEnabled: true,
            isLiveStream: false,
            prefersStableTitle: prefersStableTitle
        )

        #expect(presentation.title == "Song")
        #expect(presentation.artist == "Artist")
        #expect(presentation.lyricLineID == nil)
    }

    @Test("Disabled, live and plain lyrics preserve canonical Now Playing metadata", arguments: [false, true])
    func unsupportedNowPlayingLyricsPreserveCanonicalMetadata(prefersStableTitle: Bool) {
        let synchronized = [
            LyricLine(id: "line", timestamp: 0, text: "Lyric", isSynchronized: true),
        ]
        let plain = [
            LyricLine(id: "plain", timestamp: 0, text: "Plain", isSynchronized: false),
        ]

        for presentation in [
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: synchronized,
                playbackTime: 10,
                isEnabled: false,
                isLiveStream: false,
                prefersStableTitle: prefersStableTitle
            ),
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: synchronized,
                playbackTime: 10,
                isEnabled: true,
                isLiveStream: true,
                prefersStableTitle: prefersStableTitle
            ),
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: plain,
                playbackTime: 10,
                isEnabled: true,
                isLiveStream: false,
                prefersStableTitle: prefersStableTitle
            ),
        ] {
            #expect(presentation.title == "Song")
            #expect(presentation.artist == "Artist")
            #expect(presentation.lyricLineID == nil)
        }
    }

    @Test("Missing lyrics preserve canonical Now Playing metadata", arguments: [false, true])
    func missingNowPlayingLyricsPreserveCanonicalMetadata(prefersStableTitle: Bool) {
        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: [],
            playbackTime: 10,
            isEnabled: true,
            isLiveStream: false,
            prefersStableTitle: prefersStableTitle
        )

        #expect(presentation.title == "Song")
        #expect(presentation.artist == "Artist")
        #expect(presentation.lyricLineID == nil)
    }

    @Test("Empty system lyrics retry transient failures with a bounded backoff")
    func emptySystemLyricsUseBoundedRetry() {
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 1,
            hasDemand: true,
            isLiveStream: false
        ) == 2)
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 2,
            hasDemand: true,
            isLiveStream: false
        ) == 10)
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 3,
            hasDemand: true,
            isLiveStream: false
        ) == nil)
    }

    @Test("System lyrics do not retry without demand or for live streams")
    func unsupportedSystemLyricsDoNotRetry() {
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 1,
            hasDemand: false,
            isLiveStream: false
        ) == nil)
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 1,
            hasDemand: true,
            isLiveStream: true
        ) == nil)
    }
}
