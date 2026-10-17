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
        // 跟读提前量:离下一段开头不到 0.25 秒就换过去,再早一点还停在上一段。
        #expect(Policy.paragraphIndex(at: 3.0, in: paragraphs, lookahead: Policy.followLookahead) == 1)
        #expect(Policy.paragraphIndex(at: 2.9, in: paragraphs, lookahead: Policy.followLookahead) == 0)
        #expect(Policy.paragraphIndex(at: 3.0, in: paragraphs) == 0)
    }

    @Test("Bilingual cues carry their translations into the paragraph, joined like the original")
    func bilingualParagraphs() {
        let cues = [
            Policy.Cue(text: "Welcome back", start: 0, end: 1.5, speaker: "A", translation: "欢迎回来，"),
            Policy.Cue(text: "to the show.", start: 1.6, end: 3, speaker: "A", translation: "继续收听。"),
            Policy.Cue(text: "No translation here.", start: 9, end: 11, speaker: "A"),
            Policy.Cue(text: "Chapter 2", start: 12, end: 13, speaker: "A", translation: "第二章"),
            Policy.Cue(text: "It rained.", start: 13.1, end: 14, speaker: "A", translation: "  "),
            Policy.Cue(text: "All day.", start: 14.1, end: 15, speaker: "A", translation: "Rain all day"),
        ]
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.map(\.text) == ["Welcome back to the show.", "No translation here.", "Chapter 2", "It rained. All day."])
        // 中文译文之间不加空格;只有空白的译文不算;一段里只有部分行有译文时也接上有的那些。
        #expect(paragraphs.map(\.translation) == ["欢迎回来，继续收听。", nil, "第二章", "Rain all day"])
        #expect(Policy.hasTranslation(cues))
        #expect(!Policy.hasTranslation(cues.map { Policy.Cue(text: $0.text, start: $0.start) }))
    }

    @Test("The text mode drops translations, keeps them, or reads the translation instead")
    func textModes() {
        let cues = [
            Policy.Cue(text: "天色渐暗，", start: 0, translation: "Dusk fell,"),
            Policy.Cue(text: "他推门而出。", start: 3, translation: "and he went out."),
            Policy.Cue(text: "第二天清晨", start: 30),
        ]
        let original = Policy.paragraphs(from: Policy.cues(cues, showing: .original))
        #expect(original.map(\.text) == ["天色渐暗，他推门而出。", "第二天清晨"])
        #expect(original.allSatisfy { $0.translation == nil })

        let bilingual = Policy.paragraphs(from: Policy.cues(cues, showing: .bilingual))
        #expect(bilingual.map(\.translation) == ["Dusk fell, and he went out.", nil])

        // 只看译文:分段、整句位置都按译文算;没有译文的那一行留原文。
        let translated = Policy.paragraphs(from: Policy.cues(cues, showing: .translation))
        #expect(translated.map(\.text) == ["Dusk fell, and he went out.", "第二天清晨"])
        #expect(translated.allSatisfy { $0.translation == nil })
        #expect(translated[0].segments.map(\.range) == [0..<10, 11..<27])
        #expect(translated[0].segments.map(\.start) == [0, 3])
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

    @Test("A line holding several sentences is split, each sentence timed by its share of the line")
    func sentencesInsideOneCue() {
        // 18 字、12 秒:三句各 5、6、7 字,后两句从第 5、11 字开始,按字数折成 3.33 秒与 7.33 秒。
        let chinese = Policy.paragraphs(from: [
            Policy.Cue(text: "天色渐暗。他推门而出。远处传来钟声。", start: 0, end: 12),
        ])[0]
        let chineseText = Array(chinese.text)
        #expect(chinese.segments.map { String(chineseText[$0.range]) } == ["天色渐暗。", "他推门而出。", "远处传来钟声。"])
        #expect(chinese.segments.map(\.cue) == [0, 0, 0])
        let chineseStarts: [TimeInterval] = [0, 12.0 * 5 / 18, 12.0 * 11 / 18]
        #expect(Self.approximately(chinese.segments.map(\.start), chineseStarts))
        #expect(Policy.segmentIndex(at: 3, in: chinese) == 0)
        #expect(Policy.segmentIndex(at: 3.5, in: chinese) == 1)
        #expect(Policy.segmentIndex(at: 9, in: chinese) == 2)

        // 拉丁文的句点后面要有空格;句间的空格不属于任何一句。
        let english = Policy.paragraphs(from: [
            Policy.Cue(text: "It rained. Nobody came. We waited.", start: 10, end: 13),
        ])[0]
        let englishText = Array(english.text)
        #expect(english.segments.map { String(englishText[$0.range]) } == ["It rained.", "Nobody came.", "We waited."])
        #expect(english.segments.map(\.range) == [0..<10, 11..<23, 24..<34])
        let englishStarts: [TimeInterval] = [10, 10 + 3.0 * 11 / 34, 10 + 3.0 * 24 / 34]
        #expect(Self.approximately(english.segments.map(\.start), englishStarts))

        // 两行并成一段时,后一行拆出来的句子位置要加上前面的长度。
        let joined = Policy.paragraphs(from: [
            Policy.Cue(text: "你好。再见。", start: 0, end: 2),
            Policy.Cue(text: "走吧。回家。", start: 2.1, end: 4.1),
        ])[0]
        let joinedText = Array(joined.text)
        #expect(joined.segments.map(\.cue) == [0, 0, 1, 1])
        #expect(joined.segments.map { String(joinedText[$0.range]) } == ["你好。", "再见。", "走吧。", "回家。"])
        #expect(Self.approximately(joined.segments.map(\.start), [0, 1, 2.1, 3.1]))
    }

    private static func approximately(_ actual: [TimeInterval?], _ expected: [TimeInterval]) -> Bool {
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { value, target in
            guard let value else { return false }
            return abs(value - target) < 0.001
        }
    }

    @Test("Sentence splitting leaves closers with their sentence and keeps decimals and interjections whole")
    func sentenceBoundaries() {
        #expect(Policy.sentenceRanges(in: "他说:「走吧。」她点头。") == [0..<8, 8..<12])
        #expect(Policy.sentenceRanges(in: "Really?! \"Yes.\" Fine then.") == [0..<8, 9..<15, 16..<26])
        #expect(Policy.sentenceRanges(in: "The value is 3.5 today. Fine then.") == [0..<23, 24..<34])
        #expect(Policy.sentenceRanges(in: "等等……他回头看了一眼。") == [0..<4, 4..<12])
        // 只有一句、叹词、没有标点:不拆。
        #expect(Policy.sentenceRanges(in: "他推门而出。").isEmpty)
        #expect(Policy.sentenceRanges(in: "嗯。好。").isEmpty)
        #expect(Policy.sentenceRanges(in: "A. Never again.").isEmpty)
        #expect(Policy.sentenceRanges(in: "天色渐暗 他推门而出").isEmpty)
    }

    @Test("Lines without a known duration are not split, and a gap before the next line is capped")
    func sentenceTiming() {
        // 不带时间、最后一行没有结束时间:整行一句。
        let untimed = Policy.paragraphs(from: [Policy.Cue(text: "你好。再见。", start: nil)])[0]
        #expect(untimed.segments.count == 1)
        let last = Policy.paragraphs(from: [Policy.Cue(text: "你好。再见。", start: 5)])[0]
        #expect(last.segments.count == 1)
        #expect(last.segments[0].start == 5)

        // 只有开始时间时用下一行的开始当结束;隔了一分钟的静音不算进去,一个字最多 0.6 秒。
        let lrc = Policy.paragraphs(from: [
            Policy.Cue(text: "你好。再见。", start: 0),
            Policy.Cue(text: "第二天清晨。", start: 60),
        ])
        let first = lrc[0]
        #expect(first.segments.count == 2)
        #expect(Self.approximately(first.segments.map(\.start), [0, 1.8]))

        // 结束时间坏了(不晚于开始)也退回到下一行的开始;这两行隔得近,并在同一段里。
        let broken = Policy.paragraphs(from: [
            Policy.Cue(text: "你好。再见。", start: 0, end: 0),
            Policy.Cue(text: "第二天清晨。", start: 2),
        ])
        #expect(broken.count == 1)
        #expect(Self.approximately(broken[0].segments.map(\.start), [0, 1, 2]))
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

    @Test("One paragraph per cue keeps every line apart but still marks chapter titles")
    func perCueParagraphs() {
        let cues = [
            Policy.Cue(text: "第一章 山河", start: 0, end: 1),
            Policy.Cue(text: "天色渐暗，", start: 1.1, end: 3),
            Policy.Cue(text: "他推门而出。", start: 3.1, end: 5),
            Policy.Cue(text: "", start: nil),
            Policy.Cue(text: "雨停了。风也停了。", start: 5.2, end: 9),
        ]
        let merged = Policy.paragraphs(from: cues)
        #expect(merged.map(\.text) == ["第一章 山河", "天色渐暗，他推门而出。", "雨停了。风也停了。"])

        let perCue = Policy.paragraphs(from: cues, mode: .perCue)
        #expect(perCue.map(\.text) == ["第一章 山河", "天色渐暗，", "他推门而出。", "雨停了。风也停了。"])
        #expect(perCue.map(\.firstCue) == [0, 1, 2, 4])
        #expect(perCue.map(\.isHeading) == [true, false, false, false])
        #expect(perCue.map(\.start) == [0, 1.1, 3.1, 5.2])
        // 一行里的两句仍然分开高亮。
        #expect(perCue[3].segments.count == 2)
        #expect(perCue[3].segments.map(\.cue) == [4, 4])
        #expect(Policy.paragraphIndex(at: 4, in: perCue) == 2)

        let plain = ["The rain had stopped", "by morning."].map { Policy.Cue(text: $0, start: nil) }
        #expect(Policy.paragraphs(from: plain, mode: .perCue).map(\.text) == ["The rain had stopped", "by morning."])
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

        // 命中在一行的第二句里:跳到那一句估算的开始时间,不是整行的开始。
        let split = Policy.paragraphs(from: [Policy.Cue(text: "风暴来了。村子一片寂静。", start: 20, end: 32)])
        #expect(Policy.searchMatches(for: "寂静", in: split).map(\.start) == [25])

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

@Suite("Transcript reader swipes")
struct SpokenWordTranscriptSwipePolicyTests {
    private typealias Policy = SpokenWordTranscriptSwipePolicy

    @Test("Only a clearly sideways drag is taken; vertical drags stay with scrolling")
    func beginsOnlySideways() {
        #expect(Policy.shouldBegin(translationX: 20, translationY: 4, velocityX: 0, velocityY: 0))
        #expect(Policy.shouldBegin(translationX: -20, translationY: 4, velocityX: 0, velocityY: 0))
        #expect(!Policy.shouldBegin(translationX: 4, translationY: 20, velocityX: 0, velocityY: 0))
        #expect(!Policy.shouldBegin(translationX: 14, translationY: 12, velocityX: 0, velocityY: 0))
        // 手指在动时按速度判方向。
        #expect(Policy.shouldBegin(translationX: 6, translationY: 6, velocityX: 600, velocityY: 100))
        #expect(!Policy.shouldBegin(translationX: 6, translationY: 2, velocityX: 100, velocityY: 500))
        // 还没动到判断方向的程度。
        #expect(!Policy.shouldBegin(translationX: 4, translationY: 0, velocityX: 20, velocityY: 0))
    }

    @Test("With controls hidden a sideways swipe does nothing; taps on the edges bring them up")
    func ignoredWhenHidden() {
        #expect(Policy.outcome(translationX: 40, translationY: 5, velocityX: 200, chromeVisible: false) == .none)
        #expect(Policy.outcome(translationX: -40, translationY: 5, velocityX: -200, chromeVisible: false) == .none)
        #expect(Policy.outcome(translationX: 200, translationY: 10, velocityX: 1500, chromeVisible: false) == .none)
    }

    @Test("With controls showing only a long or fast swipe closes the reader")
    func dismissesWhenVisible() {
        #expect(Policy.outcome(translationX: 120, translationY: 10, velocityX: 300, chromeVisible: true) == .dismiss)
        #expect(Policy.outcome(translationX: -120, translationY: 10, velocityX: -300, chromeVisible: true) == .dismiss)
        #expect(Policy.outcome(translationX: 60, translationY: 4, velocityX: 1000, chromeVisible: true) == .dismiss)
        // 轻扫只是让控件多留一会儿。
        #expect(Policy.outcome(translationX: 50, translationY: 4, velocityX: 300, chromeVisible: true) == .revealChrome)
        #expect(Policy.outcome(translationX: 40, translationY: 4, velocityX: 1000, chromeVisible: true) == .revealChrome)
    }

    @Test("Diagonal drags and swipes pulled back before lifting do nothing")
    func ignoresDiagonalAndReversed() {
        #expect(Policy.outcome(translationX: 120, translationY: 90, velocityX: 900, chromeVisible: true) == .none)
        #expect(Policy.outcome(translationX: 120, translationY: 10, velocityX: -400, chromeVisible: true) == .none)
        #expect(Policy.outcome(translationX: 50, translationY: 4, velocityX: -300, chromeVisible: true) == .none)
    }
}

@Suite("Transcript reader edge taps")
struct SpokenWordTranscriptEdgeTapPolicyTests {
    private typealias Policy = SpokenWordTranscriptEdgeTapPolicy

    @Test("Each edge strip is about a sixth of the width, at least a finger wide, capped on iPad")
    func edgeWidths() {
        #expect(Policy.edgeWidth(viewportWidth: 393) == 393 * 0.16)
        #expect(Policy.edgeWidth(viewportWidth: 375) == 375 * 0.16)
        #expect(Policy.edgeWidth(viewportWidth: 1024) == 120)
        #expect(Policy.edgeWidth(viewportWidth: 240) == 44)
        // 极窄时两边加起来不超过一半。
        #expect(Policy.edgeWidth(viewportWidth: 120) == 30)
        #expect(Policy.edgeWidth(viewportWidth: 0) == 0)
    }

    @Test("Taps near either edge only toggle the controls; the middle plays from the paragraph")
    func edgeTaps() {
        #expect(Policy.isEdgeTap(x: 10, viewportWidth: 393))
        #expect(Policy.isEdgeTap(x: 60, viewportWidth: 393))
        #expect(Policy.isEdgeTap(x: 385, viewportWidth: 393))
        #expect(Policy.isEdgeTap(x: 340, viewportWidth: 393))
        #expect(!Policy.isEdgeTap(x: 70, viewportWidth: 393))
        #expect(!Policy.isEdgeTap(x: 196, viewportWidth: 393))
        #expect(!Policy.isEdgeTap(x: 320, viewportWidth: 393))
        #expect(!Policy.isEdgeTap(x: 10, viewportWidth: 0))
    }
}

@Suite("Transcript timing offset (#320)")
struct SpokenWordTranscriptOffsetPolicyTests {
    private typealias Policy = SpokenWordTranscriptOffsetPolicy

    @Test("A positive delay shows each line later and keeps the line ids")
    func delayShiftsLater() {
        let lines = [
            LyricLine(id: "a", timestamp: 1, text: "First", endTimestamp: 2.5),
            LyricLine(id: "b", timestamp: 3, text: "Second",
                      syllables: [LyricSyllable(text: "Sec", start: 3, end: 3.4),
                                  LyricSyllable(text: "ond", start: 3.4, end: 4)]),
        ]
        let shifted = Policy.applying(delay: 1.5, to: lines)
        #expect(shifted.map(\.id) == ["a", "b"])
        #expect(shifted.map(\.timestamp) == [2.5, 4.5])
        #expect(shifted[0].endTimestamp == 4)
        #expect(shifted[1].syllables?.map(\.start) == [4.5, 4.9])
    }

    @Test("A negative delay shows lines earlier but never before zero")
    func advanceClampsAtZero() {
        let lines = [
            LyricLine(timestamp: 0.4, text: "Intro"),
            LyricLine(timestamp: 10, text: "Body"),
        ]
        #expect(Policy.applying(delay: -2, to: lines).map(\.timestamp) == [0, 8])
    }

    @Test("Plain text transcripts and a zero delay are left alone")
    func untimedUntouched() {
        let plain = [LyricLine(timestamp: 0, text: "No times", isSynchronized: false)]
        #expect(Policy.applying(delay: 3, to: plain) == plain)
        let timed = [LyricLine(timestamp: 5, text: "Timed")]
        #expect(Policy.applying(delay: 0, to: timed) == timed)
    }

    @Test("Global and per-item layers add up, rounded and clamped")
    func layersAdd() {
        #expect(Policy.effectiveDelay(global: 1.2, item: 0.5) == 1.7)
        #expect(Policy.effectiveDelay(global: -0.5, item: nil) == -0.5)
        #expect(Policy.normalized(0.04) == 0)
        #expect(Policy.normalized(2.26) == 2.3)
        #expect(Policy.normalized(10_000) == Policy.limit)
        #expect(Policy.normalized(.nan) == 0)
    }

    @Test("Podcast episodes keep their own offset, book chapters share the book's")
    func itemKeys() {
        #expect(Policy.itemKey(songID: "ep1", bookID: "show", isPodcastEpisode: true) == "song:ep1")
        #expect(Policy.itemKey(songID: "ch3", bookID: "book9", isPodcastEpisode: false) == "book:book9")
        #expect(Policy.itemKey(songID: "single", bookID: nil, isPodcastEpisode: false) == "song:single")
    }
}
