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
}
