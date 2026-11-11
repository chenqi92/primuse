import Foundation
import Testing
@testable import PrimuseKit

@Suite("SubStation Alpha karaoke lyrics")
struct ASSKaraokeLyricsParserTests {
    private let document = #"""
    [Script Info]
    Title: Demo
    ScriptType: v4.00+

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\k50}Light {\k30}on {\k40}the {\kf60}water
    Dialogue: 0,0:00:04.00,0:00:06.50,Default,,0,0,0,,{\an8}A plain line, with a comma\Nand a break
    Comment: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,a note
    Dialogue: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,{\k20}{\k30}Hi{\k10} {\ko40}you
    """#

    @Test("Karaoke tags become word timing in a subtitle document")
    func parsesKaraokeTags() throws {
        #expect(SubtitleLyricsParser.detect(document) == .substationAlpha)
        #expect(LyricsContentParser.isSubtitleDocument(document))
        #expect(LyricsFormat.detect(document) == .wordLevel)

        let lines = LyricsContentParser.parseText(document)
        #expect(lines.map(\.text) == [
            "Light on the water", "A plain line, with a comma and a break", "Hi you",
        ])

        let words = try #require(lines[0].syllables)
        #expect(words.map(\.text) == ["Light ", "on ", "the ", "water"])
        #expect(words.map(\.start) == [1, 1.5, 1.8, 2.2])
        #expect(words.map(\.end) == [1.5, 1.8, 2.2, 2.8])
        #expect(words.allSatisfy { $0.endTiming == .explicit })
        #expect(lines[0].endTimestamp == 3)

        #expect(!lines[1].isWordLevel)
        #expect(lines[1].endTimestamp == 6.5)

        // An empty karaoke syllable is a pause, and a lone space joins the
        // word before it.
        #expect(lines[2].syllables?.map(\.text) == ["Hi ", "you"])
        #expect(lines[2].syllables?.map(\.start) == [9.2, 9.6])
    }

    @Test("Template output is skipped in favor of its karaoke source lines")
    func readsKaraokeTemplateSource() {
        let lines = LyricsContentParser.parseText(#"""
        [Script Info]
        ScriptType: v4.00+

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,karaoke,{\k50}Hel{\k50}lo
        Dialogue: 1,0:00:01.00,0:00:01.50,Default,,0,0,0,fx,{\pos(100,100)}Hel
        Dialogue: 1,0:00:01.50,0:00:02.00,Default,,0,0,0,fx,{\pos(140,100)}lo
        """#)
        #expect(lines.map(\.text) == ["Hello"])
        #expect(lines.first?.syllables?.map(\.start) == [1, 1.5])
    }

    @Test("Drawing commands and other overrides never reach the text")
    func dropsDrawingAndOverrides() {
        let lines = LyricsContentParser.parseText(#"""
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\p1}m 0 0 l 10 0 10 10{\p0}{\c&H00FF00&\k100}Glow
        """#)
        #expect(lines.map(\.text) == ["Glow"])
        #expect(lines.first?.syllables?.first?.end == 2)
    }

    @Test("LRC and other subtitles are not taken for SubStation Alpha")
    func keepsOtherFormats() {
        #expect(SubtitleLyricsParser.detect("[00:01.00]Light on the water") == nil)
        #expect(SubtitleLyricsParser.detect("1\n00:00:01,000 --> 00:00:02,000\nLight") == .subRip)
        #expect(SubtitleLyricsParser.detect("[Events]\nNo dialogue here") == nil)
    }

    @Test("SubStation and Lyricify Lines files are read but never written")
    func registersReadOnlyExtensions() {
        for ext in ["ass", "ssa", "lyl"] {
            #expect(PrimuseConstants.readableLyricsExtensions.contains(ext))
            #expect(!PrimuseConstants.supportedLyricsExtensions.contains(ext))
        }
        #expect(LyricsDocumentFormat(fileName: "a.ass")?.family == .subtitle)
        #expect(LyricsDocumentFormat(fileName: "a.SSA")?.family == .subtitle)
        #expect(LyricsDocumentFormat(fileName: "a.lyl")?.family == .lrc)
        #expect(LyricsDocumentFormat.ass.isSerializable == false)
    }

    @Test("Lyricify Lines rows read their start from the millisecond window")
    func readsLyricifyLines() {
        let content = "[type:LyricifyLines]\n[1200,3400]Light on the water\n[3400,5000]Second row"
        let lines = LyricsContentParser.parseText(content)
        #expect(lines.map(\.text) == ["Light on the water", "Second row"])
        #expect(lines.map(\.timestamp) == [1.2, 3.4])
        #expect(LyricsDocumentFormat.Family.lrc == LyricsRawDocumentPolicy.family(of: content))
    }
}
