import Foundation
import Testing
@testable import PrimuseKit

struct LyricTranslationContentPolicyTests {
    private func line(_ id: String, _ text: String, at time: Double = 0) -> LyricLine {
        LyricLine(id: id, timestamp: time, text: text)
    }

    @Test(arguments: [
        "作词：ASKA", "作詞 / 作曲：ASKA", "词曲：Someone", "编曲 Someone", "編曲：Someone",
        "Lyrics by: Someone", "Lyrics by Someone", "Music and lyrics: Someone", "Written by Someone",
        "Executive producer: Someone", "Produced by Someone", "Mixed by: Someone", "Mastered by Someone",
        "Guitar solo: Someone", "Backing vocals: Someone", "录音师：Someone", "制作统筹：Someone",
        "Title: English Title", "Artist：English Name", "Album: English Album", "[by:Uploader]",
        "[ti:English Title]", "[ar:English Name]", "[al:English Album]", "[offset:100]",
        "作詞：Someone", "作曲 Someone", "작사: Someone", "편곡 Someone", "Paroles: Someone",
        "© 2026 Some Records", "℗ 2026 Some Records",
        "作词 (Lyrics by): Someone", "作曲 Composer：Someone", "音乐总监：Someone", "人声录音：Someone",
        "配唱制作人：Someone", "配唱製作人：Someone", "混音室：Hot Music Studio", "混音工作室：Someone",
        "制作团队：KingStar音乐社团", "製作團隊：Someone", "企划营销：Someone", "企劃營銷：Someone",
        "人声编辑：Someone", "母带工程师：Someone", "母帶工程師：Someone", "联合制作人：Someone",
        "执行制作人：Someone", "執行製作人：Someone", "弦乐录音师：Someone", "音频混音工程师：Someone",
        "配唱制作人 Someone", "混音室 Someone", "制作团队 (Production team)：Someone",
        "Vocal producer: Someone", "Vocal production: Someone", "Mixing studio: Someone",
        "Recording engineer: Someone", "Mastering engineer: Someone", "Production team: Someone",
    ])
    func explicitMetadataNeverBecomesATranslationCandidate(_ credit: String) {
        let lines = [line("before", "第一句歌词", at: 10), line("credit", credit, at: 20), line("after", "第二句歌词", at: 30)]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines).map(\.id) == ["before", "after"])
        #expect(lines[1].text == credit)
    }

    @Test func extendedProductionCreditsAreExcludedThroughoutTheIntro() {
        let credits = [
            "蒋家驹 (蒋蒋) - 悲歌一首", "作词：蒋家驹", "作曲：蒋家驹", "编曲：邱沐阳",
            "录音：浔浔、kent王健", "混音：殇小谨", "吉他：邱沐阳", "和声：kent王健、皎月",
            "和声编写：kent王健、皎月", "制作人：kent王健", "配唱制作人：kent王健",
            "录音室：1803 Studio", "混音室：Hot Music Studio", "制作团队：KingStar音乐社团",
            "企划营销：梦童娱乐", "监制：三千", "OP：千和世纪",
        ]
        let intro = credits.enumerated().map { line("credit\($0.offset)", $0.element, at: Double($0.offset)) }
        let body = [line("zh", "我们一起走在回家的路上", at: 19), line("en", "I will always love you", at: 25)]
        let song = LyricTranslationSongContext(title: "悲歌一首", artist: "蒋家驹[蒋蒋]")
        #expect(LyricTranslationContentPolicy.contentLines(in: intro + body, song: song) == body)
    }

    @Test(arguments: [
        "全世界谁倾听你(Live)-林宥嘉(Yoga Lin)",
        "林宥嘉（Yoga Lin） — 全世界谁倾听你（Live）",
    ])
    func matchesSongIdentityInsteadOfGuessingHeaderLanguage(_ title: String) {
        let lines = [line("title", title), line("lyric", "多希望有一个像你的人", at: 30)]
        let song = LyricTranslationSongContext(title: "全世界谁倾听你", artist: "林宥嘉")
        #expect(LyricTranslationContentPolicy.contentLines(in: lines, song: song).map(\.id) == ["lyric"])
    }

    @Test func lrcMetadataAlsoSuppliesSongIdentity() {
        var header = line("title", "Some Song (Live) - Some Singer")
        header.metadataLines = ["[ti:Some Song]", "[ar:Some Singer]"]
        #expect(LyricTranslationContentPolicy.contentLines(in: [header, line("lyric", "中文歌词", at: 10)]).map(\.id) == ["lyric"])
    }

    @Test func labelledHeaderSuppliesIdentityForUnlabelledRows() {
        let lines = [line("title", "Title: Some Song"), line("artist", "Artist: Some Singer"),
                     line("pair", "Some Singer - Some Song"), line("lyric", "中文歌词", at: 10)]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines).map(\.id) == ["lyric"])
    }

    @Test func separateHeaderFieldsRequireCorroborationAndKeepLaterChoruses() {
        let song = LyricTranslationSongContext(title: "Hello", artist: "Adele")
        let lines = [line("title", "Hello"), line("artist", "Adele", at: 1), line("credit", "Lyrics by: Adele", at: 2),
                     line("chorus", "Hello", at: 10), line("verse", "I was wondering if you would call", at: 15)]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines, song: song).map(\.id) == ["chorus", "verse"])
        let bareChorus = [line("chorus", "Hello"), line("verse", "I was wondering if you would call", at: 15)]
        #expect(LyricTranslationContentPolicy.contentLines(in: bareChorus, song: song) == bareChorus)
    }

    @Test func repeatedTitleAtStartIsNotRemovedWithHeader() {
        let song = LyricTranslationSongContext(title: "Hello", artist: "Adele")
        let lines = [line("title", "Hello"), line("artist", "Adele"), line("chorus", "Hello"), line("verse", "How are you?", at: 10)]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines, song: song).map(\.id) == ["chorus", "verse"])
    }

    @Test func shortDocumentDoesNotTreatItsOnlyChorusAsAFooter() {
        let song = LyricTranslationSongContext(title: "Hello", artist: "Adele")
        for header in [[line("title", "Hello"), line("artist", "Adele")], [line("pair", "Adele - Hello")]] {
            let lines = header + [line("chorus", "Hello")]
            #expect(LyricTranslationContentPolicy.contentLines(in: lines, song: song).map(\.id) == ["chorus"])
        }
    }

    @Test func punctuationAndHyphensInsideNamesRemainMatchable() {
        let song = LyricTranslationSongContext(title: "Re-entry", artist: "Jay-Z")
        let lines = [line("title", "Re-entry - Jay-Z"), line("verse", "你好世界", at: 10)]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines, song: song).map(\.id) == ["verse"])
    }

    @Test func keepsRealMixedLanguageLyricsAndOrdinaryColons() {
        let lines = [line("title", "Song - Singer"), line("credit", "作词：Singer", at: 2),
                     line("en", "I will always love you", at: 10), line("zh", "我说：我爱你", at: 15),
                     line("jp", "君に会いたい", at: 20), line("fr", "Je voudrais te revoir", at: 25),
                     line("prefix", "曲终人散：我还在原地", at: 30), line("noun", "Music is all I need", at: 35),
                     line("vocals", "Vocals fade: we keep dancing", at: 40),
                     line("production", "制作梦想：Together we can fly", at: 45),
                     line("studio", "走出录音室：I miss you", at: 50),
                     line("unknown", "她说：I love you", at: 55)]
        let song = LyricTranslationSongContext(title: "Song", artist: "Singer")
        #expect(LyricTranslationContentPolicy.contentLines(in: lines, song: song) == Array(lines.dropFirst(2)))
    }

    @Test func wordTimingAndSecondaryVoicesProtectUnlabelledSungText() {
        let song = LyricTranslationSongContext(title: "Hello", artist: "Adele")
        var timed = line("timed", "Hello")
        timed.syllables = [.init(text: "Hello", start: 0, end: 1)]
        var background = line("background", "Adele")
        background.voice = .secondary
        let lines = [line("credit", "Lyrics by: Adele"), timed, background]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines, song: song).map(\.id) == ["timed", "background"])
    }

    @Test func trailingCreditsAreExcludedWithoutDroppingLastSungTitle() {
        let song = LyricTranslationSongContext(title: "Hello", artist: "Adele")
        let lines = [line("verse", "How are you?", at: 10), line("chorus", "Hello", at: 20),
                     line("pair", "Adele - Hello", at: 25), line("credit", "Produced by: Someone", at: 30)]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines, song: song).map(\.id) == ["verse", "chorus"])
    }

    @Test func doesNotInventIdentityForUnknownHyphenatedLines() {
        let lines = [line("unknown", "Stay - come back to me"), line("lyric", "再见", at: 10)]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines) == lines)
    }

    @Test func creditsOnlyAndPunctuationDoNotNeedTranslation() {
        let lines = [line("credit", "Composer: Someone"), line("dots", "♪ … ♪"), line("blank", "")]
        #expect(LyricTranslationContentPolicy.contentLines(in: lines).isEmpty)
    }
}
