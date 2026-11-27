import Foundation
import Testing
@testable import PrimuseKit

@Suite("CUE per-track lyric sidecars")
struct CueTrackLyricsSidecarPolicyTests {
    private typealias Track = CueTrackLyricsSidecarPolicy.Track

    private static let album: [Track] = [
        Track(number: 1, title: "晴天", performer: "周杰伦"),
        Track(number: 2, title: "七里香", performer: "周杰伦"),
        Track(number: 3, title: "稻香", performer: "周杰伦"),
        Track(number: 4, title: "夜曲", performer: "周杰伦"),
        Track(number: 5, title: "青花瓷", performer: "周杰伦"),
        Track(number: 6, title: "告白气球", performer: "周杰伦"),
    ]

    @Test("Every common per-track naming finds its track")
    func commonNamings() {
        let result = assign(
            [
                "CDImage.wav", "CDImage.cue",
                "01 晴天.lrc",
                "02. 七里香.lrc",
                "03 - 周杰伦 - 稻香.lrc",
                "周杰伦 - 夜曲.lrc",
                "青花瓷.lrc",
                "06.lrc",
            ],
            tracks: Self.album
        )
        #expect(result == [
            1: "01 晴天.lrc",
            2: "02. 七里香.lrc",
            3: "03 - 周杰伦 - 稻香.lrc",
            4: "周杰伦 - 夜曲.lrc",
            5: "青花瓷.lrc",
            6: "06.lrc",
        ])
    }

    @Test("Title before artist, underscores and missing separators still match")
    func separatorVariants() {
        let result = assign(
            [
                "CDImage.flac",
                "1_晴天.lrc",
                "002-七里香.lrc",
                "03稻香.lrc",
                "夜曲 - 周杰伦.lrc",
            ],
            tracks: Self.album
        )
        #expect(result[1] == "1_晴天.lrc")
        #expect(result[2] == "002-七里香.lrc")
        #expect(result[3] == "03稻香.lrc")
        #expect(result[4] == "夜曲 - 周杰伦.lrc")
    }

    @Test("Image-prefixed and Track-prefixed numbers match")
    func prefixedNumbers() {
        let tracks = [
            Track(number: 1, title: nil, performer: nil),
            Track(number: 2, title: nil, performer: nil),
            Track(number: 3, title: nil, performer: nil),
            Track(number: 4, title: "Title", performer: nil),
            Track(number: 5, title: "Five", performer: nil),
            Track(number: 6, title: nil, performer: nil),
            Track(number: 7, title: nil, performer: nil),
        ]
        let result = assign(
            [
                "Album Image.ape", "Disc.cue",
                "Album Image - 01.lrc",
                "Album Image 02.lrc",
                "Disc - 03.lrc",
                "Album Image - 04 - Title.lrc",
                "Track 05 - Five.lrc",
                "Track06.lrc",
                "Album Image_07.lrc",
            ],
            tracks: tracks,
            audio: "Album Image",
            cue: "Disc"
        )
        #expect(result == [
            1: "Album Image - 01.lrc",
            2: "Album Image 02.lrc",
            3: "Disc - 03.lrc",
            4: "Album Image - 04 - Title.lrc",
            5: "Track 05 - Five.lrc",
            6: "Track06.lrc",
            7: "Album Image_07.lrc",
        ])
    }

    @Test("The image's own same-name lyrics are album-level, never a track's")
    func albumLevelDocumentIsExcluded() {
        let names = [
            "CDImage.wav", "CDImage.cue", "CDImage.lrc", "CDImage.en.vtt", "01 晴天.lrc",
        ]
        let candidates = CueTrackLyricsSidecarPolicy.candidateIndices(in: names).map { names[$0] }
        #expect(candidates == ["01 晴天.lrc"])

        // Even unfiltered, the album document is not handed to a track.
        let tracks = [Track(number: 1, title: "CDImage", performer: nil)]
        let unfiltered = CueTrackLyricsSidecarPolicy.assignments(
            tracks: tracks,
            audioBaseName: "CDImage",
            cueBaseName: "CDImage",
            candidateNames: ["CDImage.lrc", "cdimage.TTML"],
            cueImageCount: 1
        )
        #expect(unfiltered.isEmpty)
    }

    @Test("Another audio file's same-name lyrics stay with that file")
    func sameNameSidecarsOfOtherMedia() {
        let result = assign(
            [
                "CDImage.wav", "CDImage.cue",
                "晴天.flac", "晴天.lrc",
                "七里香.mp4", "七里香.lrc",
                "Bonus.it.flac", "Bonus.it.vtt",
            ],
            tracks: Self.album + [Track(number: 7, title: "Bonus", performer: nil)]
        )
        #expect(result.isEmpty)
    }

    @Test("A bare number only counts when the directory holds one CUE image")
    func bareNumberNeedsSingleImage() {
        let tracks = [Track(number: 1, title: "A", performer: nil)]
        #expect(assign(["01.lrc"], tracks: tracks, images: 1) == [1: "01.lrc"])
        #expect(assign(["01.lrc"], tracks: tracks, images: 2).isEmpty)
    }

    @Test("Two CUE images in one directory keep their prefixed files apart")
    func twoImagesInOneDirectory() {
        let names = [
            "Disc 1.flac", "Disc 1.cue", "Disc 2.flac", "Disc 2.cue",
            "Disc 1 - 01.lrc", "Disc 2 - 01.lrc", "01.lrc",
        ]
        let tracks = [Track(number: 1, title: nil, performer: nil)]
        let first = assign(names, tracks: tracks, audio: "Disc 1", cue: "Disc 1", images: 2)
        let second = assign(names, tracks: tracks, audio: "Disc 2", cue: "Disc 2", images: 2)
        #expect(first == [1: "Disc 1 - 01.lrc"])
        #expect(second == [1: "Disc 2 - 01.lrc"])
    }

    @Test("Duplicate titles need a number or a distinguishing artist")
    func duplicateTitles() {
        let tracks = [
            Track(number: 1, title: "Intro", performer: "A"),
            Track(number: 2, title: "Song", performer: "A"),
            Track(number: 5, title: "Intro", performer: "B"),
        ]
        let ambiguous = assign(["Intro.lrc", "Song.lrc"], tracks: tracks)
        #expect(ambiguous == [2: "Song.lrc"])

        let numbered = assign(["01 Intro.lrc", "05 Intro.lrc"], tracks: tracks)
        #expect(numbered == [1: "01 Intro.lrc", 5: "05 Intro.lrc"])

        let byArtist = assign(["B - Intro.lrc", "Intro - A.lrc"], tracks: tracks)
        #expect(byArtist == [1: "Intro - A.lrc", 5: "B - Intro.lrc"])
    }

    @Test("Placeholder titles never match by title alone")
    func placeholderTitles() {
        let tracks = [
            Track(number: 1, title: "Track 01", performer: nil),
            Track(number: 2, title: "Track 02", performer: nil),
        ]
        // `Track 02.lrc` still resolves, through the Track-number rule.
        let result = assign(["Track 01.lrc", "Track 02.lrc"], tracks: tracks)
        #expect(result == [1: "Track 01.lrc", 2: "Track 02.lrc"])

        #expect(CueTrackLyricsSidecarPolicy.isPlaceholderTitle(nil))
        #expect(CueTrackLyricsSidecarPolicy.isPlaceholderTitle("  "))
        #expect(CueTrackLyricsSidecarPolicy.isPlaceholderTitle("Track 07"))
        #expect(CueTrackLyricsSidecarPolicy.isPlaceholderTitle("曲目 03"))
        #expect(CueTrackLyricsSidecarPolicy.isPlaceholderTitle("第3轨"))
        #expect(CueTrackLyricsSidecarPolicy.isPlaceholderTitle("トラック 12"))
        #expect(CueTrackLyricsSidecarPolicy.isPlaceholderTitle("04"))
        #expect(!CueTrackLyricsSidecarPolicy.isPlaceholderTitle("Tracks of My Tears"))
        #expect(!CueTrackLyricsSidecarPolicy.isPlaceholderTitle("晴天"))
    }

    @Test("Characters a file system rejects are tolerated")
    func illegalCharacterReplacement() {
        let tracks = [
            Track(number: 1, title: "What?", performer: nil),
            Track(number: 2, title: "A/B: C", performer: "X*Y"),
            Track(number: 3, title: "\"Quoted\" <Live>", performer: nil),
        ]
        let result = assign(
            ["01 What_.lrc", "X_Y - A_B_ C.lrc", "03 _Quoted_ _Live_.lrc"],
            tracks: tracks
        )
        #expect(result == [
            1: "01 What_.lrc",
            2: "X_Y - A_B_ C.lrc",
            3: "03 _Quoted_ _Live_.lrc",
        ])
    }

    @Test("Full-width, NFD and case variants compare equal")
    func unicodeNormalization() {
        let tracks = [
            Track(number: 1, title: "Café", performer: nil),
            Track(number: 2, title: "夜に駆ける", performer: "YOASOBI"),
            Track(number: 3, title: "がんばれ", performer: nil),
            Track(number: 4, title: "HELLO", performer: nil),
        ]
        let decomposedCafe = "01 Cafe\u{301}.lrc"
        let decomposedGanbare = "03 \u{304B}\u{3099}ん\u{306F}\u{3099}れ.lrc"
        let result = assign(
            [decomposedCafe, "０２　ＹＯＡＳＯＢＩ－夜に駆ける.lrc", decomposedGanbare, "04 hello.LRC"],
            tracks: tracks
        )
        #expect(result[1] == decomposedCafe)
        #expect(result[2] == "０２　ＹＯＡＳＯＢＩ－夜に駆ける.lrc")
        #expect(result[3] == decomposedGanbare)
        #expect(result[4] == "04 hello.LRC")
    }

    @Test("Language-tagged subtitles follow the same tag rules as same-name lyrics")
    func languageTags() {
        let tracks = [Track(number: 1, title: "Title", performer: nil)]
        #expect(CueTrackLyricsSidecarPolicy.documentBaseName(ofFileName: "01 Title.en.vtt") == "01 Title")
        #expect(CueTrackLyricsSidecarPolicy.documentBaseName(ofFileName: "01. Title.vtt") == "01. Title")

        let preferred = assign(
            ["01 Title.en.vtt", "01 Title.ja.vtt"],
            tracks: tracks,
            languages: ["ja"]
        )
        #expect(preferred == [1: "01 Title.ja.vtt"])

        let untagged = assign(["01 Title.en.vtt", "01 Title.vtt"], tracks: tracks, languages: ["en"])
        #expect(untagged == [1: "01 Title.vtt"])

        let lrcFirst = assign(["01 Title.en.srt", "01 Title.lrc", "01 Title.ttml"], tracks: tracks)
        #expect(lrcFirst == [1: "01 Title.lrc"])
    }

    @Test("A stronger match wins a file two tracks could claim")
    func tierPrecedence() {
        let tracks = [
            Track(number: 1, title: "Song", performer: nil),
            Track(number: 2, title: "01 Song", performer: nil),
        ]
        let result = assign(["01 Song.lrc"], tracks: tracks)
        #expect(result == [1: "01 Song.lrc"])
    }

    @Test("Four-digit prefixes are not track numbers")
    func yearIsNotTrackNumber() {
        let tracks = [Track(number: 19, title: "84", performer: nil)]
        #expect(assign(["1984.lrc"], tracks: tracks).isEmpty)
    }

    @Test("The result does not depend on listing order")
    func deterministic() {
        let names = [
            "CDImage.wav", "01 晴天.lrc", "01. 晴天.lrc", "01 晴天.ttml", "晴天.lrc",
            "02 七里香.srt", "02 七里香.vtt", "七里香.lrc",
        ]
        let expected = assign(names, tracks: Self.album)
        // The numbered form is the stronger match even as a subtitle; read
        // priority only orders files of the same strength.
        #expect(expected[1] == "01 晴天.lrc")
        #expect(expected[2] == "02 七里香.vtt")
        for seed in 0..<8 {
            var generator = SeededGenerator(seed: UInt64(seed + 1))
            let shuffled = names.shuffled(using: &generator)
            #expect(assign(shuffled, tracks: Self.album) == expected)
        }
    }

    @Test("A new per-track document is named so the policy recognizes it")
    func newDocumentNames() {
        let tracks = [
            Track(number: 1, title: "晴天", performer: "周杰伦"),
            Track(number: 2, title: "What?", performer: nil),
            Track(number: 3, title: nil, performer: nil),
            Track(number: 4, title: "Track 04", performer: nil),
            Track(number: 12, title: "..Hidden..", performer: nil),
            Track(number: 105, title: "Long", performer: nil),
        ]
        let names = tracks.map {
            CueTrackLyricsSidecarPolicy.newDocumentFileName(for: $0, audioBaseName: "CDImage")
        }
        #expect(names == [
            "01 晴天.lrc",
            "02 What_.lrc",
            "CDImage - 03.lrc",
            "CDImage - 04.lrc",
            "12 Hidden.lrc",
            "105 Long.lrc",
        ])
        for (track, name) in zip(tracks, names) {
            let result = CueTrackLyricsSidecarPolicy.assignments(
                tracks: tracks,
                audioBaseName: "CDImage",
                cueBaseName: "CDImage",
                candidateNames: [name],
                cueImageCount: 2
            )
            #expect(result == [track.number: 0], "\(name)")
        }

        let longTitle = String(repeating: "长", count: 200)
        #expect(CueTrackLyricsSidecarPolicy.newDocumentFileName(
            for: Track(number: 7, title: longTitle, performer: nil),
            audioBaseName: "A/B",
            fileExtension: "ttml"
        ) == "A_B - 07.ttml")
    }

    @Test("Stored references are classified by name alone")
    func trackDocumentReferences() {
        let audio = "/Music/Album/CDImage.wav"
        #expect(CueTrackLyricsSidecarPolicy.referencesTrackDocument("/Music/Album/01 晴天.lrc", audioPath: audio))
        #expect(CueTrackLyricsSidecarPolicy.referencesTrackDocument("/Music/Album/01 晴天.en.vtt", audioPath: audio))
        #expect(!CueTrackLyricsSidecarPolicy.referencesTrackDocument("/Music/Album/CDImage.lrc", audioPath: audio))
        #expect(!CueTrackLyricsSidecarPolicy.referencesTrackDocument("/Music/Album/cdimage.en.vtt", audioPath: audio))
        #expect(!CueTrackLyricsSidecarPolicy.referencesTrackDocument("/Music/Other/01 晴天.lrc", audioPath: audio))
        #expect(!CueTrackLyricsSidecarPolicy.referencesTrackDocument("0a1b2c3d.json", audioPath: audio))
        #expect(!CueTrackLyricsSidecarPolicy.referencesTrackDocument("F1D2E3C4B5A6", audioPath: audio))
        #expect(!CueTrackLyricsSidecarPolicy.referencesTrackDocument("https://x/01.lrc", audioPath: audio))
        #expect(!CueTrackLyricsSidecarPolicy.referencesTrackDocument(nil, audioPath: audio))
        #expect(CueTrackLyricsSidecarPolicy.referencesTrackDocument("01 晴天.lrc", audioPath: "CDImage.wav"))
    }

    // MARK: - Helpers

    /// Runs the policy over a directory listing and answers with file names.
    private func assign(
        _ names: [String],
        tracks: [Track],
        audio: String = "CDImage",
        cue: String? = "CDImage",
        images: Int = 1,
        languages: [String] = ["en"]
    ) -> [Int: String] {
        let candidates = CueTrackLyricsSidecarPolicy.candidateIndices(in: names).map { names[$0] }
        return CueTrackLyricsSidecarPolicy.assignments(
            tracks: tracks,
            audioBaseName: audio,
            cueBaseName: cue,
            candidateNames: candidates,
            cueImageCount: images,
            preferredLanguages: languages
        ).mapValues { candidates[$0] }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("CUE track lyrics on the whole-file timeline")
struct CueTrackLyricsTimelinePolicyTests {
    private typealias Policy = CueTrackLyricsTimelinePolicy

    /// 一本书:序章 0–60s,第一章 60–180s,第二章 180s 起到文件末尾(300s)。
    private static func chapter(
        start: TimeInterval,
        end: TimeInterval?,
        duration: TimeInterval? = nil
    ) -> Song {
        Song(
            id: "book#\(Int(start))",
            title: "Chapter",
            duration: duration ?? end.map { $0 - start } ?? 0,
            fileFormat: .flac,
            filePath: "/books/Book.m4b",
            sourceID: "nas",
            cueSheetPath: "/books/Book.cue",
            cueStartTime: start,
            cueEndTime: end
        )
    }

    private static func stamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }

    /// 整本书一份 ELRC:每 10 秒一句,每句两个逐字时间。
    private static func wholeBookELRC(until end: TimeInterval = 300) -> [LyricLine] {
        let text = stride(from: 0.0, to: end, by: 10).map { time in
            "[\(stamp(time))]<\(stamp(time))>Line <\(stamp(time + 1))>\(Int(time))<\(stamp(time + 2))>"
        }.joined(separator: "\n")
        return LyricsContentParser.parse("[ti:Book]\n" + text)
    }

    @Test("A later chapter continues the whole-book ELRC from its own start")
    func laterChapterShiftsWholeFileDocument() {
        let lines = Self.wholeBookELRC()
        #expect(lines.count == 30)
        let song = Self.chapter(start: 60, end: 180)

        let presented = Policy.presenting(lines, for: song)

        let texts = presented.map(\.text)
        #expect(texts.first == "Line 60")
        #expect(texts.last == "Line 170")
        #expect(presented.count == 12)
        #expect(presented.first?.timestamp == 0)
        // 逐字时间一起挪:原来 61s 的第二个字现在在 1s。
        #expect(presented.first?.syllables?.map(\.start) == [0, 1])
        #expect(presented.first?.syllables?.last?.end == 2)
        // 章内 15 秒对应整本书 75 秒那句。
        let active = LyricPlaybackPositionPolicy.activeLineIndex(in: presented, at: 15)
        #expect(active.map { presented[$0].text } == "Line 70")
        // 文档头跟着挪到新的第一行。
        #expect(presented.first?.metadataLines == lines.first?.metadataLines)
    }

    @Test("The first chapter keeps its times and drops the chapters after it")
    func firstChapterOnlyClips() {
        let lines = Self.wholeBookELRC()
        let presented = Policy.presenting(lines, for: Self.chapter(start: 0, end: 60))
        #expect(presented.map(\.text) == (0..<6).map { "Line \($0 * 10)" })
        #expect(presented.map(\.timestamp) == lines.prefix(6).map(\.timestamp))
        #expect(presented.map(\.id) == lines.prefix(6).map(\.id))
    }

    @Test("The last chapter without a CUE end runs to the end of the document")
    func lastChapterUsesSongDuration() {
        let lines = Self.wholeBookELRC()
        let song = Self.chapter(start: 180, end: nil, duration: 120)
        let presented = Policy.presenting(lines, for: song)
        #expect(presented.map(\.text).first == "Line 180")
        #expect(presented.map(\.text).last == "Line 290")
        #expect(presented.last?.timestamp == 110)

        // 播放时间段的副本时长是区间终点,时间窗仍按整轨。
        let ranged = song.playing(AppliedSongPlaybackRange(start: 10, end: 40, songDuration: 120))
        #expect(Policy.segment(for: ranged) == Policy.Segment(start: 180, end: nil, duration: 120))
    }

    @Test("A chapter's own document is left exactly as it is")
    func perTrackDocumentUnchanged() {
        // 第一章自己的文稿:时间都在 0–120s 之内,哪怕落在 60s 以后也不能当整本书的挪走。
        let own = LyricsContentParser.parse(
            stride(from: 0.0, to: 120, by: 10).map { "[\(Self.stamp($0))]Own \(Int($0))" }
                .joined(separator: "\n")
        )
        let song = Self.chapter(start: 60, end: 180)
        #expect(Policy.presenting(own, for: song) == own)

        // 只有一行写错的尾巴也不算整本书的。
        let stray = own + [LyricLine(timestamp: 900, text: "credits")]
        #expect(Policy.presenting(stray, for: song) == stray)
    }

    @Test("A whole-file document with nothing in this chapter is not blanked")
    func emptyWindowKeepsDocument() {
        let lines = Self.wholeBookELRC().filter { $0.timestamp < 60 || $0.timestamp >= 180 }
        let song = Self.chapter(start: 60, end: 180)
        #expect(Policy.presenting(lines, for: song) == lines)
    }

    @Test("Subtitle cues keep their end times and a cue running into the chapter stays")
    func subtitleCuesShiftWithEnds() {
        let srt = """
        1
        00:00:50,000 --> 00:01:05,000
        Across the boundary

        2
        00:01:10,000 --> 00:01:20,000
        Inside

        3
        00:02:00,000 --> 00:02:10,000
        Later one

        4
        00:03:30,000 --> 00:03:40,000
        Next chapter

        5
        00:04:30,000 --> 00:04:40,000
        Near the end
        """
        let lines = LyricsContentParser.parse(srt)
        #expect(lines.count == 5)
        let presented = Policy.presenting(lines, for: Self.chapter(start: 60, end: 180))
        #expect(presented.map(\.text) == ["Across the boundary", "Inside", "Later one"])
        #expect(presented.map(\.timestamp) == [0, 10, 60])
        #expect(presented.first?.endTimestamp == 5)
        #expect(presented[1].endTimestamp == 20)
    }

    @Test("Translations and the document source ride with their lines")
    func translationsAndDocumentFieldsMove() {
        var lines = Self.wholeBookELRC()
        lines[0].documentSource = .file("/books/Book.elrc")
        lines[7].manualTranslation = LyricManualTranslation(text: "第七十秒", source: .embeddedField)
        lines[7].romanization = "di qi shi miao"
        let presented = Policy.presenting(lines, for: Self.chapter(start: 60, end: 180))
        #expect(presented.first?.documentSource == lines[0].documentSource)
        let seventy = presented.first { $0.text == "Line 70" }
        #expect(seventy?.manualTranslation?.text == "第七十秒")
        #expect(seventy?.romanization == "di qi shi miao")
        #expect(seventy?.timestamp == 10)
    }

    @Test("A medley slice always reads the whole song; real CUE tracks are not slices")
    func medleySlice() {
        let slice = Song(
            id: "song", title: "Song", duration: 30, fileFormat: .flac,
            filePath: "/music/song.flac", sourceID: "nas",
            cueStartTime: 120, cueEndTime: 150
        )
        #expect(Policy.segment(for: slice) == nil)
        let segment = Policy.medleySliceSegment(for: slice)
        #expect(segment == Policy.Segment(start: 120, end: 150, duration: 30))
        #expect(Policy.medleySliceSegment(for: Self.chapter(start: 60, end: 180)) == nil)

        let song = LyricsContentParser.parse(
            stride(from: 0.0, to: 160, by: 10).map { "[\(Self.stamp($0))]S\(Int($0))" }
                .joined(separator: "\n")
        )
        if let segment {
            let presented = Policy.presenting(song, in: segment, assumingWholeFile: true)
            #expect(presented.map(\.text) == ["S120", "S130", "S140"])
            #expect(presented.map(\.timestamp) == [0, 10, 20])
        }
    }

    @Test("Plain unsynchronized text and songs that are not CUE tracks pass through")
    func passThrough() {
        let plain = [LyricLine(timestamp: 0, text: "one", isSynchronized: false),
                     LyricLine(timestamp: 0, text: "two", isSynchronized: false)]
        #expect(Policy.presenting(plain, for: Self.chapter(start: 60, end: 180)) == plain)

        let lines = Self.wholeBookELRC()
        let ordinary = Song(id: "x", title: "x", duration: 60, fileFormat: .flac, filePath: "/x.flac", sourceID: "nas")
        #expect(Policy.presenting(lines, for: ordinary) == lines)
    }
}
