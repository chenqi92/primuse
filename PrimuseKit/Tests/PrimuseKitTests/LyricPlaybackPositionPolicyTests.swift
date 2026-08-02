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
}
