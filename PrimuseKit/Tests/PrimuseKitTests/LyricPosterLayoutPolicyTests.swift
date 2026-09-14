import Foundation
import Testing
@testable import PrimuseKit

struct LyricPosterLayoutPolicyTests {
    private func content(
        _ texts: [String],
        translations: [String?]? = nil
    ) -> LyricPosterContent {
        LyricPosterContent(
            songTitle: "Song",
            artistName: "Artist",
            lines: texts.enumerated().map { index, text in
                LyricPosterLine(
                    id: "l\(index)",
                    text: text,
                    translation: translations?[index],
                    timestamp: Double(index),
                    isSynchronized: true
                )
            }
        )
    }

    @Test func everyPassageFitsInsideItsCanvas() {
        let passages: [[String]] = [
            ["短"],
            ["一句很普通长度的中文歌词"],
            Array(repeating: "这是一句相当长的中文歌词用来测试自动缩放的效果", count: 8),
            Array(repeating: String(repeating: "a very long english lyric line ", count: 4), count: 6),
        ]
        for canvas in LyricPosterCanvas.allCases {
            for passage in passages {
                let subject = content(passage)
                let metrics = LyricPosterLayoutPolicy.metrics(for: subject, canvas: canvas)
                let budget = canvas.pixelHeight * LyricPosterLayoutPolicy.defaultLyricHeightRatio
                #expect(metrics.lyricFontSize > 0)
                #expect(metrics.estimatedHeight <= budget || metrics.lyricFontSize == canvas.pixelWidth * 0.030)
                #expect(metrics.textWidth == canvas.pixelWidth * LyricPosterLayoutPolicy.defaultTextWidthRatio)
            }
        }
    }

    @Test func longerPassagesNeverRenderLargerThanShorterOnes() {
        var previous = Double.greatestFiniteMagnitude
        for count in 1...LyricPosterSelectionPolicy.maximumLines {
            let subject = content(Array(repeating: "一句中文歌词", count: count))
            let size = LyricPosterLayoutPolicy.metrics(for: subject, canvas: .portrait).lyricFontSize
            #expect(size <= previous)
            previous = size
        }
    }

    @Test func translationsAreDroppedOnlyWhenThePassageCannotFitWithThem() {
        let shortPassage = content(["一句歌词"], translations: ["one lyric line"])
        let shortMetrics = LyricPosterLayoutPolicy.metrics(for: shortPassage, canvas: .portrait)
        #expect(!shortMetrics.hidesTranslation)

        let crowded = content(
            Array(repeating: "这是一句非常非常长的中文歌词用于把版面彻底填满", count: 8),
            translations: Array(
                repeating: String(repeating: "and an equally long english translation ", count: 3),
                count: 8
            )
        )
        let crowdedMetrics = LyricPosterLayoutPolicy.metrics(for: crowded, canvas: .square)
        #expect(crowdedMetrics.hidesTranslation)
    }

    @Test func wrappingCountsFullWidthAndLatinTextDifferently() {
        // 20 CJK glyphs at 40pt need 800pt; a 600pt column wraps them twice.
        let cjk = LyricPosterLayoutPolicy.wrappedRowCount(
            of: String(repeating: "字", count: 20),
            fontSize: 40,
            textWidth: 600
        )
        #expect(cjk == 2)

        // The same glyph count in lowercase latin is roughly half as wide.
        let latin = LyricPosterLayoutPolicy.wrappedRowCount(
            of: String(repeating: "a", count: 20),
            fontSize: 40,
            textWidth: 600
        )
        #expect(latin == 1)

        #expect(LyricPosterLayoutPolicy.wrappedRowCount(of: "", fontSize: 40, textWidth: 600) == 1)
        #expect(LyricPosterLayoutPolicy.wrappedRowCount(of: "x", fontSize: 0, textWidth: 600) == 1)
    }

    @Test func emptyPassagesProduceNoHeight() {
        let empty = LyricPosterContent(songTitle: "Song", lines: [])
        #expect(
            LyricPosterLayoutPolicy.estimatedHeight(
                of: empty,
                lyricFontSize: 60,
                textWidth: 800,
                includesTranslation: true
            ) == 0
        )
    }

    @Test func tallerCanvasesGiveThePassageMoreRoom() {
        let passage = content(Array(repeating: "一句中等长度的中文歌词", count: 5))
        let square = LyricPosterLayoutPolicy.metrics(for: passage, canvas: .square).lyricFontSize
        let story = LyricPosterLayoutPolicy.metrics(for: passage, canvas: .story).lyricFontSize
        #expect(story >= square)
    }
}
