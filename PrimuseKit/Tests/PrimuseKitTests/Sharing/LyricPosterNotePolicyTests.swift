import Foundation
import Testing
@testable import PrimuseKit

struct LyricPosterNotePolicyTests {
    @Test func inputIsTrimmedAndBlankLinesCollapse() {
        let raw = "  谢谢这首歌，\n\n\n让我在普通的日子里，\n  依然相信温柔。  \n\n"
        let sanitized = LyricPosterNotePolicy.sanitized(raw)
        #expect(sanitized == "谢谢这首歌，\n让我在普通的日子里，\n依然相信温柔。")

        #expect(LyricPosterNotePolicy.sanitized("   \n  \n ").isEmpty)
    }

    @Test func truncationCountsCharactersSoEmojiNeverSplit() {
        let emoji = String(repeating: "👩‍👩‍👧‍👦", count: 40)
        let sanitized = LyricPosterNotePolicy.sanitized(emoji, limit: 5)
        #expect(sanitized.count == 5)
        // 截断没把任何一个组合序列切开。
        #expect(sanitized == String(repeating: "👩‍👩‍👧‍👦", count: 5))
    }

    @Test func remainingGoesNegativeOnceTheUserPastesTooMuch() {
        #expect(LyricPosterNotePolicy.remaining(for: "") == LyricPosterNotePolicy.maximumLength)
        let long = String(repeating: "字", count: LyricPosterNotePolicy.maximumLength + 12)
        #expect(LyricPosterNotePolicy.remaining(for: long) == -12)
    }

    @Test func noteNeedsRealTextButSignatureIsOptional() {
        #expect(LyricPosterNotePolicy.note(text: "   ", signature: "一个听众") == nil)

        let withoutSignature = LyricPosterNotePolicy.note(text: "写给自己", signature: "  ")
        #expect(withoutSignature?.text == "写给自己")
        #expect(withoutSignature?.signature == nil)

        let signed = LyricPosterNotePolicy.note(text: "写给自己", signature: " 一个普通的听众 ")
        #expect(signed?.signature == "一个普通的听众")
    }

    @Test func signatureStaysOnOneLine() {
        let mark = LyricPosterNotePolicy.sanitizedSignature("一个\n普通的\n听众")
        #expect(!mark.contains("\n"))
        #expect(mark == "一个 普通的 听众")
    }

    @Test func noHeightWithoutANote() {
        #expect(
            LyricPosterNotePolicy.estimatedHeight(of: nil, canvasWidth: 1080, textWidth: 800) == 0
        )
        let blank = LyricPosterNote(text: "")
        #expect(
            LyricPosterNotePolicy.estimatedHeight(of: blank, canvasWidth: 1080, textWidth: 800) == 0
        )
    }

    @Test func heightGrowsWithLineBreaksAndSignature() {
        let oneLine = LyricPosterNote(text: "谢谢这首歌")
        let twoLines = LyricPosterNote(text: "谢谢这首歌\n让我相信温柔")
        let signed = LyricPosterNote(text: "谢谢这首歌", signature: "一个普通的听众")

        let a = LyricPosterNotePolicy.estimatedHeight(of: oneLine, canvasWidth: 1080, textWidth: 800)
        let b = LyricPosterNotePolicy.estimatedHeight(of: twoLines, canvasWidth: 1080, textWidth: 800)
        let c = LyricPosterNotePolicy.estimatedHeight(of: signed, canvasWidth: 1080, textWidth: 800)

        #expect(a > 0)
        #expect(b > a)
        #expect(c > a)
    }

    @Test func aNoteTakesRoomAwayFromTheLyrics() {
        let lines = (0..<4).map { index in
            LyricPosterLine(
                id: "l\(index)",
                text: "一句中等长度的中文歌词",
                timestamp: Double(index),
                isSynchronized: true
            )
        }
        let plain = LyricPosterContent(songTitle: "Song", lines: lines)
        let annotated = LyricPosterContent(
            songTitle: "Song",
            lines: lines,
            note: LyricPosterNote(
                text: "最近的我，好像终于学会和自己和解了。\n忙碌、孤独、不确定，但我依然相信。",
                signature: "一个普通的听众"
            )
        )

        let plainMetrics = LyricPosterLayoutPolicy.metrics(for: plain, canvas: .portrait)
        let annotatedMetrics = LyricPosterLayoutPolicy.metrics(for: annotated, canvas: .portrait)

        #expect(annotatedMetrics.lyricFontSize < plainMetrics.lyricFontSize)
        #expect(annotatedMetrics.noteFontSize > 0)
        // 评语 + 歌词仍在这块版面的配额内。
        let budget = LyricPosterCanvas.portrait.pixelHeight
            * LyricPosterLayoutPolicy.defaultLyricHeightRatio
        let noteHeight = LyricPosterNotePolicy.estimatedHeight(
            of: annotated.note,
            canvasWidth: LyricPosterCanvas.portrait.pixelWidth,
            textWidth: annotatedMetrics.textWidth
        )
        #expect(annotatedMetrics.estimatedHeight + noteHeight <= budget + 0.001)
    }
}
