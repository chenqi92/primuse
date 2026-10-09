import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric document sources")
struct LyricsDocumentSourcesTests {
    // MARK: - Listing

    @Test("Every document of the song is listed in a stable format order")
    func listsEveryDocument() {
        let names = [
            "Night Changes.yrc", "cover.jpg", "Night Changes.flac", "Night Changes.ttml",
            "Night Changes.lrc", "Night Changes.elrc", "Other.lrc", "Night Changes.txt",
        ]
        let listed = LyricsSidecarSelectionPolicy.documents(baseName: "Night Changes", names: names)
            .map { names[$0] }
        #expect(listed == [
            "Night Changes.lrc", "Night Changes.ttml", "Night Changes.elrc", "Night Changes.yrc",
        ])
    }

    @Test("Language-tagged subtitles follow the exact-name file of their format")
    func listsLanguageTaggedSubtitles() {
        let names = ["song.zh-Hans.vtt", "song.vtt", "song.en.vtt", "song.lrc", "song.en.srt"]
        let listed = LyricsSidecarSelectionPolicy.documents(baseName: "song", names: names)
            .map { names[$0] }
        #expect(listed == ["song.lrc", "song.vtt", "song.en.vtt", "song.zh-Hans.vtt", "song.en.srt"])
    }

    @Test("Another song's exact-name subtitle is not listed as a language track")
    func skipsAnotherSongsSubtitle() {
        let names = ["Track.flac", "Track.it.flac", "Track.it.vtt", "Track.vtt"]
        let listed = LyricsSidecarSelectionPolicy.documents(baseName: "Track", names: names)
            .map { names[$0] }
        #expect(listed == ["Track.vtt"])
    }

    // MARK: - Requests

    @Test("A pin picks its file even beside a writable sibling")
    func pinWinsOverDefaultRanking() {
        let names = ["song.lrc", "song.yrc"]
        let pinned = LyricsSidecarSelectionPolicy.select(
            .current(pinned: "song.yrc"), baseName: "song", names: names
        )
        #expect(pinned == .item(1))
        let unpinned = LyricsSidecarSelectionPolicy.select(
            .current(pinned: nil), baseName: "song", names: names
        )
        #expect(unpinned == .item(0))
    }

    @Test("A pin settles two writable documents")
    func pinResolvesWritableConflict() {
        let names = ["song.lrc", "song.ttml"]
        #expect(LyricsSidecarSelectionPolicy.select(
            .current(pinned: nil), baseName: "song", names: names
        ) == .conflict)
        #expect(LyricsSidecarSelectionPolicy.select(
            .current(pinned: "song.ttml"), baseName: "song", names: names
        ) == .item(1))
    }

    @Test("A pin whose file is gone falls back to the default ranking")
    func stalePinFallsBack() {
        let names = ["song.vtt", "song.lrc"]
        #expect(LyricsSidecarSelectionPolicy.select(
            .current(pinned: "song.ttml"), baseName: "song", names: names
        ) == .item(1))
    }

    @Test("A pin never reaches a file that is not the song's")
    func pinIgnoresForeignFile() {
        let names = ["other.lrc", "song.vtt"]
        #expect(LyricsSidecarSelectionPolicy.select(
            .current(pinned: "other.lrc"), baseName: "song", names: names
        ) == .item(1))
    }

    @Test("Pins and names match case-insensitively, the listed spelling first")
    func matchesNamesWithoutCase() {
        let names = ["SONG.LRC", "song.ttml"]
        #expect(LyricsSidecarSelectionPolicy.select(
            .current(pinned: "song.lrc"), baseName: "song", names: names
        ) == .item(0))
        let twins = ["song.vtt", "SONG.VTT"]
        #expect(LyricsSidecarSelectionPolicy.select(
            .named("SONG.VTT"), baseName: "song", names: twins
        ) == .item(1))
    }

    @Test("A named request returns that file or nothing")
    func namedRequest() {
        let names = ["song.lrc", "song.ttml", "song.lys"]
        #expect(LyricsSidecarSelectionPolicy.select(
            .named("song.lys"), baseName: "song", names: names
        ) == .item(2))
        #expect(LyricsSidecarSelectionPolicy.select(
            .named("song.qrc"), baseName: "song", names: names
        ) == .none)
    }

    @Test("Listing never reports a conflict")
    func catalogNeverConflicts() {
        let names = ["song.ttml", "song.lrc"]
        #expect(LyricsSidecarSelectionPolicy.select(
            .catalog(pinned: nil), baseName: "song", names: names
        ) == .item(1))
        #expect(LyricsSidecarSelectionPolicy.select(
            .catalog(pinned: "song.ttml"), baseName: "song", names: names
        ) == .item(0))
    }

    // MARK: - Formats

    @Test("Formats are read off the extension")
    func readsFormats() {
        #expect(LyricsDocumentFormat(fileName: "a.TTML") == .ttml)
        #expect(LyricsDocumentFormat(fileName: "a.en.vtt") == .vtt)
        #expect(LyricsDocumentFormat(fileName: "a.txt") == nil)
        #expect(LyricsDocumentFormat.elrc.family == .lrc)
        #expect(LyricsDocumentFormat.qrc.family == .wordTimed)
        #expect(LyricsDocumentFormat.ttml.isSerializable)
        #expect(!LyricsDocumentFormat.yrc.isSerializable)
        #expect(LyricsDocumentFormat.ttml.label == "TTML")
    }

    // MARK: - Raw validation

    private static let ttml = """
    <tt xmlns="http://www.w3.org/ns/ttml"><body><div>\
    <p begin="00:01.000" end="00:03.000"><span begin="00:01.000" end="00:02.000">Hello</span> \
    <span begin="00:02.000" end="00:03.000">world</span></p>\
    </div></body></tt>
    """

    @Test("A TTML file keeps its word timing through validation")
    func validatesTTML() {
        let result = LyricsRawDocumentPolicy.validate(Self.ttml, fileName: "song.ttml")
        guard case .valid(let summary) = result.outcome else {
            Issue.record("expected a valid TTML document, got \(result.outcome)")
            return
        }
        #expect(summary.isWordLevel)
        #expect(summary.lineCount == 1)
        #expect(result.lines.first?.syllables?.count == 2)
    }

    @Test("Text of another kind is refused for the file's format")
    func refusesFormatMismatch() {
        let lrc = "[00:01.00]Hello"
        #expect(LyricsRawDocumentPolicy.validate(lrc, fileName: "song.ttml").outcome
            == .formatMismatch(expected: .ttml, found: .lrc))
        #expect(LyricsRawDocumentPolicy.validate(Self.ttml, fileName: "song.lrc").outcome
            == .formatMismatch(expected: .lrc, found: .ttml))
        #expect(LyricsRawDocumentPolicy.validate(lrc, fileName: "song.yrc").outcome
            == .formatMismatch(expected: .wordTimed, found: .lrc))
    }

    @Test("Word-timed and subtitle files validate by their own readers")
    func validatesWordTimedAndSubtitles() {
        let yrc = "[1000,2000](1000,1000,0)Hello (2000,1000,0)world"
        #expect(LyricsRawDocumentPolicy.validate(yrc, fileName: "song.yrc").outcome.isValid)
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello world"
        #expect(LyricsRawDocumentPolicy.validate(vtt, fileName: "song.en.vtt").outcome.isValid)
    }

    @Test("Empty text is not a document")
    func refusesEmptyText() {
        #expect(LyricsRawDocumentPolicy.validate(" \n\n", fileName: "song.lrc").outcome == .empty)
    }

    @Test("Real-world LRC quirks pass, broken time tags are reported without blocking")
    func keepsLRCQuirks() {
        let quirky = """
        [ti:Song]
        [00:20.00]Second
        [00:10.00]First
        [03:58.00]
        [0x:12.00]Typo
        """
        let result = LyricsRawDocumentPolicy.validate(quirky, fileName: "song.lrc")
        #expect(result.outcome.isValid)
        #expect(result.unreadableLineNumbers == [5])
    }

    @Test("Markup without a single lyric line is unreadable")
    func refusesUnreadableTTML() {
        let empty = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body></body></tt>"
        #expect(LyricsRawDocumentPolicy.validate(empty, fileName: "song.ttml").outcome == .unreadable)
    }

    // MARK: - Encoding

    @Test("A file is written back with the byte-order mark it had")
    func keepsByteOrderMark() {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("[00:01.00]a".utf8)
        let encoding = LyricsRawDocumentEncoding(original: original, decodedEncoding: .utf8)
        #expect(encoding.data(for: "[00:01.00]b") == Data([0xEF, 0xBB, 0xBF]) + Data("[00:01.00]b".utf8))

        let utf16 = Data([0xFF, 0xFE]) + "x".data(using: .utf16LittleEndian)!
        let littleEndian = LyricsRawDocumentEncoding(original: utf16, decodedEncoding: .utf16LittleEndian)
        #expect(littleEndian.data(for: "y") == Data([0xFF, 0xFE]) + "y".data(using: .utf16LittleEndian)!)
    }

    @Test("Text the old encoding cannot hold is written as UTF-8")
    func fallsBackToUTF8() {
        let latin1 = LyricsRawDocumentEncoding(original: Data("abc".utf8), decodedEncoding: .isoLatin1)
        #expect(latin1.data(for: "é") == "é".data(using: .isoLatin1))
        #expect(latin1.data(for: "歌") == Data("歌".utf8))
    }

    // MARK: - Pins

    @Test("Pins survive a reload and follow saves only when set")
    func pinStoreLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pins-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pins.json")

        let store = LyricsDocumentPinStore(fileURL: url)
        store.followSave(toFileName: "song.ttml", forSongID: "a")
        #expect(store.pinnedFileName(forSongID: "a") == nil)

        store.pin("song.yrc", forSongID: "a")
        store.followSave(toFileName: "song.ttml", forSongID: "a")
        #expect(store.pinnedFileName(forSongID: "a") == "song.ttml")

        let reloaded = LyricsDocumentPinStore(fileURL: url)
        #expect(reloaded.pinnedFileName(forSongID: "a") == "song.ttml")

        reloaded.forgetFile(named: "SONG.TTML", forSongID: "a")
        #expect(reloaded.pinnedFileName(forSongID: "a") == nil)
        #expect(LyricsDocumentPinStore(fileURL: url).pinnedFileName(forSongID: "a") == nil)
    }

    @Test("Forgetting another file leaves the pin alone")
    func forgetOnlyMatchingFile() {
        let store = LyricsDocumentPinStore(fileURL: nil)
        store.pin("song.lrc", forSongID: "a")
        store.forgetFile(named: "song.ttml", forSongID: "a")
        #expect(store.pinnedFileName(forSongID: "a") == "song.lrc")
        store.clearPin(forSongID: "a")
        #expect(store.pinnedFileName(forSongID: "a") == nil)
    }
}
