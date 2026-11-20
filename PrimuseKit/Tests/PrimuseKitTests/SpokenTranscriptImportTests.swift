import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken-word transcript batch import")
struct SpokenTranscriptImportTests {
    @Test("Imported transcripts count as the listener's own")
    func importedDocumentIsUserProvided() {
        let plain = [LyricLine(timestamp: 1, text: "Hello", isSynchronized: true)]
        let imported = SpokenTranscriptImportPolicy.importedDocument(plain, fileName: "chapter01.vtt")
        #expect(SpokenTranscriptOrigin(lines: imported) == .userProvided)
        #expect(LyricsDocumentSource.of(imported) == .file("chapter01.vtt"))
        #expect(SpokenTranscriptPrecedencePolicy.automaticServerDecision(current: imported) == .keep)
    }

    @Test("A batch of files is matched to chapters by file name, title and number")
    func matchesBatchImport() {
        typealias Matcher = SpokenTranscriptImportMatcher
        let tracks = [
            Matcher.Track(id: "a", fileName: "chapter01.mp3", title: "Intro", trackNumber: 1),
            Matcher.Track(id: "b", fileName: "chapter02.mp3", title: "Lesson Two", trackNumber: 2),
            Matcher.Track(id: "c", fileName: "03 Review.mp3", title: "Review", trackNumber: 3),
            Matcher.Track(id: "d", fileName: nil, title: "Bonus", trackNumber: 9),
        ]
        let files = [
            Matcher.File(name: "Chapter01.vtt", level: .word),
            Matcher.File(name: "chapter01.srt", level: .line),
            Matcher.File(name: "chapter02.en.vtt", level: .line),
            Matcher.File(name: "Review.lrc", level: .line),
            Matcher.File(name: "lesson-9.vtt", level: .line),
            Matcher.File(name: "broken.vtt", level: nil),
            Matcher.File(name: "appendix.vtt", level: .line),
        ]
        let result = Matcher.match(files: files, tracks: tracks)
        #expect(result.matches.map(\.trackID) == ["a", "b", "c", "d"])
        #expect(result.matches.map(\.fileIndex) == [0, 2, 3, 4])
        #expect(result.matches.map(\.rule) == [.fileName, .languageTagged, .title, .number])
        #expect(result.skipped.map(\.fileIndex) == [1, 5, 6])
        #expect(result.skipped.map(\.reason) == [.duplicate, .unreadable, .noTrack])
    }

    @Test("A file that fits more than one chapter is left alone")
    func leavesAmbiguousImportsAlone() {
        typealias Matcher = SpokenTranscriptImportMatcher
        let tracks = [
            Matcher.Track(id: "disc1", fileName: "01.mp3", title: "One"),
            Matcher.Track(id: "disc2", fileName: "01.mp3", title: "One again"),
        ]
        let result = Matcher.match(files: [Matcher.File(name: "01.vtt", level: .line)], tracks: tracks)
        #expect(result.matches.isEmpty)
        #expect(result.skipped.map(\.reason) == [.noTrack])
        #expect(Matcher.normalizedKey("Ｃhapter_01  Part") == "chapter 01 part")
        #expect(Matcher.lastNumber(in: "lesson 12 part 2") == "2")
        #expect(Matcher.lastNumber(in: "第03章") == "3")
    }
}
