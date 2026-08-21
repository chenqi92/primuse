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
}
