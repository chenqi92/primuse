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
                // 放不下时必须自报 overflows, 而不是悄悄交出一张被裁的图。
                #expect(metrics.estimatedHeight <= budget || metrics.overflows)
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
        // 版面被压到只剩一条缝时才轮到译文让位。
        let crowdedMetrics = LyricPosterLayoutPolicy.metrics(
            for: crowded,
            canvas: .square,
            lyricHeightRatio: 0.24
        )
        #expect(crowdedMetrics.hidesTranslation)
    }

    @Test func leadingTightensBeforeTypeShrinksToTheFloor() {
        let passage = content(Array(repeating: "一句中等长度的中文歌词", count: 6))
        let roomy = LyricPosterLayoutPolicy.metrics(for: passage, canvas: .story)
        // 宽松时保持默认行距。
        #expect(
            abs(roomy.lyricLineSpacing / roomy.lyricFontSize
                - LyricPosterLayoutPolicy.defaultLineSpacingFactor) < 0.001
        )

        let cramped = LyricPosterLayoutPolicy.metrics(
            for: passage,
            canvas: .square,
            lyricHeightRatio: 0.20
        )
        // 挤的时候先收行距, 换来更大的字 —— 而不是一路把字缩到最小。
        #expect(cramped.lyricLineSpacing / cramped.lyricFontSize < LyricPosterLayoutPolicy.defaultLineSpacingFactor)
    }

    @Test func theSmallestTypeSizeIsActuallyTried() {
        // 字号按 1pt 递减, 起点未必和下限差整数 —— 曾经因此跨过下限,
        // 把只差不到 1pt 就能放下的版面判成放不下。
        let passage = content(Array(repeating: "这是一句相当长的中文歌词用来把版面撑满", count: 8))
        let floor = LyricPosterCanvas.square.pixelWidth * 0.022

        for ratio in stride(from: 0.24, through: 0.60, by: 0.01) {
            let metrics = LyricPosterLayoutPolicy.metrics(
                for: passage,
                canvas: .square,
                lyricHeightRatio: ratio
            )
            #expect(metrics.lyricFontSize >= floor - 0.001)
            if !metrics.overflows {
                #expect(metrics.estimatedHeight <= LyricPosterCanvas.square.pixelHeight * ratio + 0.001)
            }
        }

        // 八句单行 + 最紧行距正好是画布高度的 0.289; 给到 0.29 就必须判定
        // 为放得下 —— 这一档只有真正试到下限字号才够得着。
        let tightest = LyricPosterLayoutPolicy.metrics(
            for: passage,
            canvas: .square,
            lyricHeightRatio: 0.29
        )
        #expect(!tightest.overflows)
        #expect(abs(tightest.lyricFontSize - LyricPosterCanvas.square.pixelWidth * 0.022) < 0.001)

        // 再少一点就真的放不下。
        let justShort = LyricPosterLayoutPolicy.metrics(
            for: passage,
            canvas: .square,
            lyricHeightRatio: 0.28
        )
        #expect(justShort.overflows)
    }

    @Test func impossiblePassagesAreFlaggedInsteadOfSilentlyClipped() {
        let passage = content(Array(repeating: "这是一句相当长的中文歌词用来把版面撑满", count: 8))
        let metrics = LyricPosterLayoutPolicy.metrics(
            for: passage,
            canvas: .square,
            lyricHeightRatio: 0.06
        )
        #expect(metrics.overflows)
        // 仍然给得出一套可渲染的尺寸, 预览不能因此空白。
        #expect(metrics.lyricFontSize > 0)
        #expect(metrics.estimatedHeight > 0)

        let comfortable = LyricPosterLayoutPolicy.metrics(for: passage, canvas: .story)
        #expect(!comfortable.overflows)
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
