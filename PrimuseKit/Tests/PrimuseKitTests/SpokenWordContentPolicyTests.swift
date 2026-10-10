import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word classification")
struct SpokenWordContentPolicyTests {
    @Test("An .m4b container is an audiobook on its own")
    func audiobookContainer() {
        #expect(
            SpokenWordContentPolicy.classify(filePath: "/Books/Dune.m4b", genre: nil)
                == .spokenWord
        )
        #expect(
            SpokenWordContentPolicy.classify(filePath: "/Books/Dune.M4B", genre: nil)
                == .spokenWord
        )
    }

    @Test("Ordinary music containers stay music without other evidence")
    func musicContainers() {
        for path in ["/Music/song.m4a", "/Music/song.mp3", "/Music/song.flac"] {
            #expect(SpokenWordContentPolicy.classify(filePath: path, genre: nil) == .music)
        }
    }

    @Test("Genres that name the category are recognized across languages")
    func categoryGenres() {
        let genres = [
            "Audiobook", "audio book", "Spoken Word", "Radio Drama",
            "Hörbuch", "Livre audio", "Audiolibro", "Lecture", "Storytelling",
        ]
        for genre in genres {
            #expect(
                SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .spokenWord,
                "\(genre) should be spoken word"
            )
        }
    }

    @Test("A genre that names a podcast files the episode with the podcasts")
    func podcastGenres() {
        for genre in ["Podcast", "Podcasts", "播客", "ポッドキャスト", "팟캐스트", "Tech Podcast"] {
            #expect(SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .podcast, "\(genre)")
            #expect(SpokenWordContentPolicy.genreNamesSpokenWord(genre), "\(genre) is still not music")
        }
        // A book container is a book whatever the genre says.
        #expect(SpokenWordContentPolicy.classify(filePath: "/a.m4b", genre: "Podcast") == .spokenWord)
        #expect(ListeningContentKind.podcast.isSpokenWordListening)
        #expect(!ListeningContentKind.music.isSpokenWordListening)
    }

    @Test("Chinese spoken-word categories are recognized")
    func chineseCategoryGenres() {
        let genres = ["\u{6709}\u{58F0}\u{4E66}", "\u{8BC4}\u{4E66}", "\u{76F8}\u{58F0}",
                      "\u{5E7F}\u{64AD}\u{5267}", "\u{8BF4}\u{4E66}", "\u{8131}\u{53E3}\u{79C0}"]
        for genre in genres {
            #expect(
                SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .spokenWord
            )
        }
    }

    @Test("Music genres are never reclassified")
    func musicGenresUntouched() {
        let genres = [
            "Rock", "Pop", "Classical", "Jazz", "Soundtrack", "Electronic",
            "Comedy", "Folk", "Hip-Hop", "Blues", "World", "Vocal", "New Age",
            "\u{6D41}\u{884C}", "\u{6C11}\u{8C23}", "\u{53E4}\u{5178}",
        ]
        for genre in genres {
            #expect(
                SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .music,
                "\(genre) should stay music"
            )
        }
    }

    @Test("Duration is never evidence: long music stays music")
    func lengthIsNotEvidence() {
        // A 74-minute symphony movement, a DJ set and a live set are all music.
        #expect(
            SpokenWordContentPolicy.classify(filePath: "/Live/set.flac", genre: "Electronic")
                == .music
        )
    }

    @Test("An explicit choice overrides inference in both directions")
    func userOverrideWins() {
        #expect(
            SpokenWordContentPolicy.classify(
                filePath: "/Books/Dune.m4b",
                genre: "Audiobook",
                userOverride: .music
            ) == .music
        )
        #expect(
            SpokenWordContentPolicy.classify(
                filePath: "/Music/track.mp3",
                genre: "Rock",
                userOverride: .spokenWord
            ) == .spokenWord
        )
    }

    @Test("A junk genre value cannot be a category name")
    func junkGenre() {
        #expect(SpokenWordContentPolicy.genreNamesSpokenWord("") == false)
        #expect(SpokenWordContentPolicy.genreNamesSpokenWord("   ") == false)
        #expect(
            SpokenWordContentPolicy.genreNamesSpokenWord(String(repeating: "audiobook", count: 20))
                == false
        )
    }
}

@Suite("Spoken word progress")
struct SpokenWordProgressPolicyTests {
    @Test("A position is kept once past the opening seconds")
    func remembersAfterOpening() {
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 5, duration: 3600) == false)
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 20, duration: 3600))
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 1800, duration: 3600))
    }

    @Test("A finished item drops its position")
    func forgetsWhenFinished() {
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 3590, duration: 3600) == false)
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 3570, duration: 3600))
    }

    @Test("An unknown duration cannot prove the item was finished")
    func unknownDurationKeepsPosition() {
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 900, duration: 0))
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 5, duration: 0) == false)
    }

    @Test("Resuming rewinds a few seconds to pick up the sentence")
    func resumeRewinds() {
        #expect(SpokenWordProgressPolicy.resumePosition(stored: 600, duration: 3600) == 595)
        #expect(SpokenWordProgressPolicy.resumePosition(stored: nil, duration: 3600) == nil)
        #expect(SpokenWordProgressPolicy.resumePosition(stored: 3, duration: 3600) == nil)
        #expect(SpokenWordProgressPolicy.resumePosition(stored: 3599, duration: 3600) == nil)
    }

    @Test("Non-finite values never become a seek target")
    func rejectsNonFinite() {
        #expect(
            SpokenWordProgressPolicy.shouldRemember(position: .infinity, duration: 3600) == false
        )
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 100, duration: .nan) == false)
        #expect(SpokenWordProgressPolicy.resumePosition(stored: .nan, duration: 3600) == nil)
    }
}

@Suite("Spoken word skipping")
struct SpokenWordSkipPolicyTests {
    @Test("Skipping stays inside the item")
    func clampsToItem() {
        #expect(
            SpokenWordSkipPolicy.position(from: 100, offset: 30, duration: 3600) == 130
        )
        #expect(SpokenWordSkipPolicy.position(from: 10, offset: -15, duration: 3600) == 0)
        #expect(
            SpokenWordSkipPolicy.position(from: 3590, offset: 30, duration: 3600) == 3600
        )
    }

    @Test("An unknown duration still allows forward skipping")
    func unknownDuration() {
        #expect(SpokenWordSkipPolicy.position(from: 100, offset: 30, duration: 0) == 130)
        #expect(SpokenWordSkipPolicy.position(from: 5, offset: -15, duration: 0) == 0)
    }

    @Test("The intervals are the audiobook conventions")
    func intervals() {
        #expect(SpokenWordSkipPolicy.backwardInterval == 15)
        #expect(SpokenWordSkipPolicy.forwardInterval == 30)
    }
}

@Suite("Transcript reading paragraphs")
struct SpokenWordTranscriptReadingPolicyTests {
    private typealias Policy = SpokenWordTranscriptReadingPolicy

    @Test("Subtitle cues join into paragraphs that break at pauses and speaker changes")
    func joinsCues() {
        let cues = [
            Policy.Cue(text: "Welcome back", start: 0, end: 1.5, speaker: "A"),
            Policy.Cue(text: "to the show.", start: 1.6, end: 3, speaker: "A"),
            Policy.Cue(text: "Thanks for having me.", start: 3.2, end: 5, speaker: "B"),
            Policy.Cue(text: "So, where were we?", start: 9, end: 11, speaker: "B"),
        ]
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.map(\.text) == ["Welcome back to the show.", "Thanks for having me.", "So, where were we?"])
        #expect(paragraphs.map(\.firstCue) == [0, 2, 3])
        #expect(paragraphs.map(\.start) == [0, 3.2, 9])
        #expect(Policy.paragraphIndex(at: 4, in: paragraphs) == 1)
        #expect(Policy.paragraphIndex(at: 0, in: paragraphs) == 0)
        #expect(Policy.paragraphIndex(at: 100, in: paragraphs) == 2)
    }

    @Test("Chinese joins without spaces and LRC lines break only at long gaps")
    func chineseAndLRC() {
        let cues = [
            Policy.Cue(text: "第一章 山河", start: 0),
            Policy.Cue(text: "天色渐暗，", start: 4),
            Policy.Cue(text: "他推门而出。", start: 7),
            Policy.Cue(text: "第二天清晨", start: 30),
        ]
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.map(\.text) == ["第一章 山河", "天色渐暗，他推门而出。", "第二天清晨"])
        #expect(paragraphs.map(\.isHeading) == [true, false, false])
    }

    @Test("A chapter title stays its own paragraph between timed lines and in plain text")
    func headingsStandAlone() {
        let timed = [
            Policy.Cue(text: "他终于睡着了。", start: 0, end: 2),
            Policy.Cue(text: "第三章 风起云涌", start: 2.2, end: 4),
            Policy.Cue(text: "第二天一早，", start: 4.1, end: 6),
            Policy.Cue(text: "雨停了。", start: 6.1, end: 7),
        ]
        let paragraphs = Policy.paragraphs(from: timed)
        #expect(paragraphs.map(\.text) == ["他终于睡着了。", "第三章 风起云涌", "第二天一早，雨停了。"])
        #expect(paragraphs.map(\.isHeading) == [false, true, false])
        #expect(paragraphs[1].start == 2.2)
        #expect(Policy.paragraphIndex(at: 3, in: paragraphs) == 1)

        let plain = ["Chapter 3", "The rain had stopped", "by morning."].map { Policy.Cue(text: $0, start: nil) }
        #expect(Policy.paragraphs(from: plain).map(\.text) == ["Chapter 3", "The rain had stopped by morning."])
    }

    @Test("Chapter titles are recognised, ordinary short lines are not", arguments: [
        ("第三章 风起云涌", true),
        ("第12回", true),
        ("第一百二十章：决战", true),
        ("第三章。", true),
        ("第五集 归来", true),
        ("序章", true),
        ("楔子", true),
        ("番外一 重逢", true),
        ("卷三 江湖", true),
        ("제3장 시작", true),
        ("Chapter 3", true),
        ("CHAPTER XII", true),
        ("Chapter One: The Hunt", true),
        ("Chapter 3.", true),
        ("Part Two", true),
        ("Part 2: Return", true),
        ("Prologue", true),
        ("Epilogue - Home", true),
        ("第二回合他赢了", false),
        ("第一集团军", false),
        ("第三章讲的是什么呢。", false),
        ("第二天清晨", false),
        ("序列号", false),
        ("天色渐暗，", false),
        ("Part of me wanted to stay", false),
        ("Introduction of the new rules was slow", false),
        ("Welcome back", false),
        ("第三章" + String(repeating: "很长的正文", count: 10), false),
    ])
    func headingDetection(text: String, isHeading: Bool) {
        #expect(Policy.isHeading(text) == isHeading)
    }

    @Test("Each cue keeps its place in the paragraph text for sentence highlighting")
    func segments() {
        let cues = [
            Policy.Cue(text: "Welcome back", start: 0, end: 1.5),
            Policy.Cue(text: "to the show.", start: 1.6, end: 3),
            Policy.Cue(text: "  It's good.", start: 3.1, end: 4),
        ]
        let paragraph = Policy.paragraphs(from: cues)[0]
        #expect(paragraph.text == "Welcome back to the show. It's good.")
        #expect(paragraph.segments.map(\.cue) == [0, 1, 2])
        let text = Array(paragraph.text)
        #expect(paragraph.segments.map { String(text[$0.range]) } == ["Welcome back", "to the show.", "It's good."])
        #expect(Policy.segmentIndex(at: 0.5, in: paragraph) == 0)
        #expect(Policy.segmentIndex(at: 2, in: paragraph) == 1)
        #expect(Policy.segmentIndex(at: 99, in: paragraph) == 2)

        let chinese = Policy.paragraphs(from: [
            Policy.Cue(text: "天色渐暗，", start: 0, end: 1),
            Policy.Cue(text: "他推门而出。", start: 1.2, end: 2),
        ])[0]
        let chineseText = Array(chinese.text)
        #expect(chinese.segments.map { String(chineseText[$0.range]) } == ["天色渐暗，", "他推门而出。"])

        let untimed = Policy.paragraphs(from: [Policy.Cue(text: "Plain", start: nil)])[0]
        #expect(Policy.segmentIndex(at: 10, in: untimed) == nil)
    }

    @Test("Plain text keeps the author's blank lines as paragraph breaks and is never timed")
    func plainText() {
        let cues = ["First line", "continues here.", "", "Second paragraph."].map { Policy.Cue(text: $0, start: nil) }
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.map(\.text) == ["First line continues here.", "Second paragraph."])
        #expect(paragraphs.allSatisfy { $0.start == nil })
        #expect(Policy.paragraphIndex(at: 10, in: paragraphs) == nil)
    }

    @Test("A long paragraph breaks at the next sentence end")
    func longParagraphs() {
        let sentence = String(repeating: "字", count: 100) + "。"
        let cues = (0..<5).map { Policy.Cue(text: sentence, start: Double($0), end: Double($0) + 0.9) }
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].lastCue == 2)
        #expect(paragraphs.allSatisfy { $0.text.count <= Policy.hardLength })
    }
}

@Suite("Transcript search")
struct SpokenWordTranscriptSearchTests {
    private typealias Policy = SpokenWordTranscriptReadingPolicy

    private var paragraphs: [Policy.Paragraph] {
        Policy.paragraphs(from: [
            Policy.Cue(text: "The Storm came early.", start: 0, end: 2),
            Policy.Cue(text: "Nobody saw the storm coming.", start: 2.1, end: 4),
            Policy.Cue(text: "第二章 风暴", start: 10, end: 11),
            Policy.Cue(text: "风暴过后，", start: 11.1, end: 12),
            Policy.Cue(text: "村子里一片寂静。", start: 12.1, end: 13),
        ])
    }

    @Test("Matches ignore case and width, and point at the cue they start in")
    func matches() {
        let paragraphs = paragraphs
        let storms = Policy.searchMatches(for: " STORM ", in: paragraphs)
        #expect(storms.map(\.paragraph) == [0, 0])
        #expect(storms.map(\.range) == [4..<9, 37..<42])
        #expect(storms.map(\.start) == [0, 2.1])

        let chinese = Policy.searchMatches(for: "风暴", in: paragraphs)
        #expect(chinese.map(\.paragraph) == [1, 2])
        #expect(chinese.map(\.range) == [4..<6, 0..<2])
        #expect(chinese.map(\.start) == [10, 11.1])

        #expect(Policy.searchMatches(for: "ＳＴＯＲＭ", in: paragraphs).count == 2)
        #expect(Policy.searchMatches(for: "   ", in: paragraphs).isEmpty)
        #expect(Policy.searchMatches(for: "hurricane", in: paragraphs).isEmpty)
    }

    @Test("Searching starts at the paragraph being read and steps around the ends")
    func stepping() {
        let matches = Policy.searchMatches(for: "风暴", in: paragraphs)
            + Policy.searchMatches(for: "storm", in: paragraphs)
        let ordered = matches.sorted { ($0.paragraph, $0.range.lowerBound) < ($1.paragraph, $1.range.lowerBound) }
        #expect(Policy.initialMatchIndex(ordered, currentParagraph: nil) == 0)
        #expect(Policy.initialMatchIndex(ordered, currentParagraph: 1) == 2)
        #expect(Policy.initialMatchIndex(ordered, currentParagraph: 5) == 0)
        #expect(Policy.initialMatchIndex([], currentParagraph: 1) == nil)

        #expect(Policy.steppedMatchIndex(3, count: 4, forward: true) == 0)
        #expect(Policy.steppedMatchIndex(0, count: 4, forward: false) == 3)
        #expect(Policy.steppedMatchIndex(nil, count: 4, forward: false) == 3)
        #expect(Policy.steppedMatchIndex(1, count: 0, forward: true) == nil)
    }
}
