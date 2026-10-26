import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics and transcript export")
struct LyricsExportPolicyTests {
    private static func timed(_ time: TimeInterval, _ text: String, end: TimeInterval? = nil) -> LyricLine {
        LyricLine(timestamp: time, text: text, isSynchronized: true, endTimestamp: end)
    }

    @Test("Timed lines offer LRC, SRT and text; untimed lines only text; empty lines nothing")
    func availableFormats() {
        #expect(LyricsExportPolicy.formats(for: [Self.timed(1, "Hello")]) == [.lrc, .srt, .plainText])
        let plain = [LyricLine(timestamp: 0, text: "Hello", isSynchronized: false)]
        #expect(LyricsExportPolicy.formats(for: plain) == [.plainText])
        #expect(LyricsExportPolicy.formats(for: [Self.timed(1, "  ")]).isEmpty)
        #expect(LyricsExportPolicy.formats(for: []).isEmpty)
        #expect(LyricsExportPolicy.render(plain, as: .srt, readsAsProse: false) == nil)
    }

    @Test("LRC keeps the timestamps")
    func lrcKeepsTiming() throws {
        let output = try #require(LyricsExportPolicy.render(
            [Self.timed(1.5, "First"), Self.timed(62.25, "Second")],
            as: .lrc,
            readsAsProse: false
        ))
        #expect(output.contains("[00:01.500]First"))
        #expect(output.contains("[01:02.250]Second"))
        #expect(output.hasSuffix("\n"))
    }

    @Test("SRT cues run to the next line, an explicit end, or an estimate")
    func subRipTiming() throws {
        let lines = [
            Self.timed(1, "First"),
            Self.timed(4, "Second", end: 6.5),
            Self.timed(30, ""),
            Self.timed(3_725.5, "Last"),
        ]
        let output = try #require(LyricsExportPolicy.render(lines, as: .srt, readsAsProse: false))
        let expected = """
        1
        00:00:01,000 --> 00:00:04,000
        First

        2
        00:00:04,000 --> 00:00:06,500
        Second

        3
        01:02:05,500 --> 01:02:08,500
        Last

        """
        #expect(output == expected)
    }

    @Test("An SRT cue never stays up through a long silence")
    func subRipCapsLongGaps() throws {
        let output = try #require(LyricsExportPolicy.render(
            [Self.timed(10, "Hi"), Self.timed(120, "Later")],
            as: .srt,
            readsAsProse: false
        ))
        #expect(output.contains("00:00:10,000 --> 00:00:13,000\nHi"))
    }

    @Test("A bundled translation rides under its line in SRT, and a cue has no blank rows")
    func subRipTranslation() throws {
        var line = Self.timed(2, "Bonjour\n\ntout le monde")
        line.manualTranslation = LyricManualTranslation(text: "Hello everyone", source: .bilingualLRC)
        let output = try #require(LyricsExportPolicy.render([line], as: .srt, readsAsProse: false))
        #expect(output.contains("Bonjour tout le monde\nHello everyone\n"))
    }

    @Test("Lyrics stay line by line, with one blank row between stanzas")
    func plainLyrics() throws {
        let lines = [
            Self.timed(1, "One"),
            Self.timed(2, "Two"),
            Self.timed(3, ""),
            Self.timed(4, ""),
            Self.timed(5, "Three"),
            Self.timed(6, ""),
        ]
        let output = try #require(LyricsExportPolicy.render(lines, as: .plainText, readsAsProse: false))
        #expect(output == "One\nTwo\n\nThree\n")
    }

    @Test("A transcript reads as paragraphs, split at long pauses")
    func plainTranscript() throws {
        let lines = [
            Self.timed(0, "Welcome back.", end: 1.5),
            Self.timed(1.6, "Today we talk about rivers.", end: 3),
            Self.timed(20, "Chapter two begins here.", end: 22),
        ]
        let output = try #require(LyricsExportPolicy.render(lines, as: .plainText, readsAsProse: true))
        #expect(output == "Welcome back. Today we talk about rivers.\n\nChapter two begins here.\n")
    }

    @Test("Timecodes carry hours and round to the millisecond")
    func timecodes() {
        #expect(LyricsExportPolicy.timecode(0) == "00:00:00,000")
        #expect(LyricsExportPolicy.timecode(59.9996) == "00:01:00,000")
        #expect(LyricsExportPolicy.timecode(3_661.042) == "01:01:01,042")
        #expect(LyricsExportPolicy.timecode(-3) == "00:00:00,000")
    }

    @Test("File names follow title and artist with the format's extension")
    func fileNames() {
        #expect(LyricsExportPolicy.fileName(title: "Song", artist: "Band", format: .srt) == "Song - Band.srt")
        #expect(LyricsExportPolicy.fileName(title: "A/B", artist: nil, format: .plainText) == "A B.txt")
    }
}
