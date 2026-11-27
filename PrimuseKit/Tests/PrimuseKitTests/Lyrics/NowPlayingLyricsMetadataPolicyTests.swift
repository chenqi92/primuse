import Foundation
import Testing
@testable import PrimuseKit

@Suite("Now playing lyrics metadata policy")
struct NowPlayingLyricsMetadataPolicyTests {
    /// Mixes the shapes the filter has to reject: unsynchronized, blank and
    /// non-finite lines.
    private var mixedLyrics: [LyricLine] {
        [
            LyricLine(id: "plain", timestamp: 0, text: "plain text line", isSynchronized: false),
            LyricLine(id: "blank", timestamp: 1, text: "   "),
            LyricLine(id: "nan", timestamp: .nan, text: "broken timestamp"),
            LyricLine(id: "infinite", timestamp: .infinity, text: "unreachable"),
            LyricLine(id: "first", timestamp: 2, text: "first sung line"),
            LyricLine(id: "empty", timestamp: 3, text: ""),
            LyricLine(id: "second", timestamp: 4, text: "second sung line"),
        ]
    }

    @Test("Only synchronized, timed, non-empty lines survive the filter")
    func filtersUnusableLines() {
        let lines = NowPlayingLyricsMetadataPolicy.synchronizedLines(mixedLyrics)

        #expect(lines.map(\.id) == ["first", "second"])
    }

    @Test("The pre-filtered overload matches the filtering overload")
    func overloadsAgree() {
        let lyrics = mixedLyrics
        let prefiltered = NowPlayingLyricsMetadataPolicy.synchronizedLines(lyrics)

        for time in [0.0, 1.5, 2.0, 3.9, 4.0, 120.0] {
            for prefersStableTitle in [false, true] {
                let filtering = NowPlayingLyricsMetadataPolicy.presentation(
                    canonicalTitle: " Song ",
                    artistName: " Artist ",
                    lyrics: lyrics,
                    playbackTime: time,
                    isEnabled: true,
                    isLiveStream: false,
                    prefersStableTitle: prefersStableTitle
                )
                let cached = NowPlayingLyricsMetadataPolicy.presentation(
                    canonicalTitle: " Song ",
                    artistName: " Artist ",
                    synchronizedLyrics: prefiltered,
                    playbackTime: time,
                    isEnabled: true,
                    isLiveStream: false,
                    prefersStableTitle: prefersStableTitle
                )

                #expect(filtering == cached)
            }
        }
    }

    @Test("Both overloads fall back to the canonical title when lyrics are unusable")
    func overloadsAgreeWithoutSynchronizedLines() {
        let lyrics = [
            LyricLine(id: "plain", timestamp: 0, text: "plain text line", isSynchronized: false),
            LyricLine(id: "blank", timestamp: 9, text: "\n"),
        ]
        let filtering = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 30,
            isEnabled: true,
            isLiveStream: false
        )
        let cached = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            synchronizedLyrics: NowPlayingLyricsMetadataPolicy.synchronizedLines(lyrics),
            playbackTime: 30,
            isEnabled: true,
            isLiveStream: false
        )

        #expect(filtering == cached)
        #expect(filtering.lyricLineID == nil)
        #expect(filtering.title == "Song")
    }

    @Test("Disabled and live-stream states keep both overloads on the canonical title")
    func overloadsAgreeWhenDisabled() {
        let lyrics = mixedLyrics
        let prefiltered = NowPlayingLyricsMetadataPolicy.synchronizedLines(lyrics)

        for (isEnabled, isLiveStream) in [(false, false), (true, true), (false, true)] {
            let filtering = NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: lyrics,
                playbackTime: 4,
                isEnabled: isEnabled,
                isLiveStream: isLiveStream
            )
            let cached = NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                synchronizedLyrics: prefiltered,
                playbackTime: 4,
                isEnabled: isEnabled,
                isLiveStream: isLiveStream
            )

            #expect(filtering == cached)
            #expect(filtering.lyricLineID == nil)
        }
    }
}
