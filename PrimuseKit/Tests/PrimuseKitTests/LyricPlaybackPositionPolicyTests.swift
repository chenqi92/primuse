import Testing
@testable import PrimuseKit

@Suite("Lyric playback positioning")
struct LyricPlaybackPositionPolicyTests {
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

    @Test("Now Playing metadata keeps the song title before the first lyric")
    func nowPlayingMetadataWaitsForFirstLyric() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 8, text: "First", isSynchronized: true),
        ]

        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 3,
            isEnabled: true,
            isLiveStream: false
        )

        #expect(presentation.title == "Song")
        #expect(presentation.artist == "Artist")
        #expect(presentation.lyricLineID == nil)
    }

    @Test("Disabled, live and plain lyrics preserve canonical Now Playing metadata")
    func unsupportedNowPlayingLyricsPreserveCanonicalMetadata() {
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
                isLiveStream: false
            ),
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: synchronized,
                playbackTime: 10,
                isEnabled: true,
                isLiveStream: true
            ),
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: plain,
                playbackTime: 10,
                isEnabled: true,
                isLiveStream: false
            ),
        ] {
            #expect(presentation.title == "Song")
            #expect(presentation.artist == "Artist")
            #expect(presentation.lyricLineID == nil)
        }
    }

    @Test("Missing lyrics preserve canonical Now Playing metadata")
    func missingNowPlayingLyricsPreserveCanonicalMetadata() {
        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: [],
            playbackTime: 10,
            isEnabled: true,
            isLiveStream: false
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
