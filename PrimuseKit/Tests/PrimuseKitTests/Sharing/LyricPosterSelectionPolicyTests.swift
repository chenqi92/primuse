import Foundation
import Testing
@testable import PrimuseKit

struct LyricPosterSelectionPolicyTests {
    private func lines(_ count: Int) -> [LyricPosterLine] {
        (0..<count).map { index in
            LyricPosterLine(
                id: "l\(index)",
                text: "line \(index)",
                timestamp: Double(index) * 3,
                endTimestamp: Double(index) * 3 + 2,
                isSynchronized: true
            )
        }
    }

    @Test func romanizationTravelsWithTheSelectedLine() {
        let document = [
            LyricLine(id: "a", timestamp: 0, text: "君と歩く", romanization: " kimi to aruku "),
            LyricLine(id: "b", timestamp: 3, text: "Plain line"),
        ]
        let selectable = LyricPosterSelectionPolicy.selectableLines(
            from: document,
            translations: ["a": "和你一起走"]
        )

        #expect(selectable[0].romanization == "kimi to aruku")
        #expect(selectable[0].translation == "和你一起走")
        #expect(selectable[1].romanization == nil)

        // A romanization alone still makes the poster's secondary-row switch
        // meaningful, even with translation off.
        let romanizedOnly = LyricPosterContent(
            songTitle: "Song",
            lines: LyricPosterSelectionPolicy.selectableLines(from: document)
        )
        #expect(!romanizedOnly.hasTranslation)
        #expect(romanizedOnly.hasCompanionText)
    }

    @Test func blankAndWhitespaceOnlyLinesAreNotSelectable() {
        let document = [
            LyricLine(id: "a", timestamp: 0, text: "  hello  "),
            LyricLine(id: "b", timestamp: 1, text: "   "),
            LyricLine(id: "c", timestamp: 2, text: ""),
            LyricLine(id: "d", timestamp: 3, text: "world"),
        ]
        let selectable = LyricPosterSelectionPolicy.selectableLines(
            from: document,
            translations: ["a": " 你好 ", "d": "  "]
        )
        #expect(selectable.map(\.id) == ["a", "d"])
        #expect(selectable[0].text == "hello")
        #expect(selectable[0].translation == "你好")
        // A whitespace-only translation must not reserve layout space.
        #expect(selectable[1].translation == nil)
    }

    @Test func defaultSelectionFollowsPlaybackAndStaysOnFirstLineBeforeItStarts() {
        let rows = lines(4)
        #expect(LyricPosterSelectionPolicy.defaultSelection(in: rows, playbackPosition: 0) == ["l0"])
        #expect(LyricPosterSelectionPolicy.defaultSelection(in: rows, playbackPosition: 7) == ["l2"])
        #expect(LyricPosterSelectionPolicy.defaultSelection(in: [], playbackPosition: 7).isEmpty)
    }

    @Test func selectionGrowsOnlyThroughAdjacentRows() {
        let rows = lines(6)
        var selection = ["l2"]

        let farAway = LyricPosterSelectionPolicy.toggling("l5", in: rows, selection: selection)
        #expect(farAway.selection == selection)
        #expect(farAway.rejection == .notAdjacent)
        #expect(!LyricPosterSelectionPolicy.canExtend(to: "l5", in: rows, selection: selection))

        selection = LyricPosterSelectionPolicy.toggling("l3", in: rows, selection: selection).selection
        #expect(selection == ["l2", "l3"])
        selection = LyricPosterSelectionPolicy.toggling("l1", in: rows, selection: selection).selection
        #expect(selection == ["l1", "l2", "l3"])
    }

    @Test func theLineLimitRejectsFurtherRowsInsteadOfSlidingTheWindow() {
        let rows = lines(12)
        var selection = LyricPosterSelectionPolicy.expanded(
            from: ["l0"],
            in: rows,
            toCount: LyricPosterSelectionPolicy.maximumLines
        )
        #expect(selection.count == LyricPosterSelectionPolicy.maximumLines)

        let overflow = LyricPosterSelectionPolicy.toggling("l8", in: rows, selection: selection)
        #expect(overflow.rejection == .limitReached)
        #expect(overflow.selection == selection)

        // Trimming an end frees room again.
        selection = LyricPosterSelectionPolicy.toggling("l0", in: rows, selection: selection).selection
        #expect(selection.first == "l1")
        #expect(LyricPosterSelectionPolicy.canExtend(to: "l8", in: rows, selection: selection))
    }

    @Test func tappingInsideTheRangeTrimsItAndNeverSplitsThePassage() {
        let rows = lines(8)
        let selection = LyricPosterSelectionPolicy.expanded(from: ["l1"], in: rows, toCount: 5)
        #expect(selection == ["l1", "l2", "l3", "l4", "l5"])

        // Interior row closer to the start: keep the longer tail.
        let trimmedHead = LyricPosterSelectionPolicy.toggling("l2", in: rows, selection: selection)
        #expect(trimmedHead.selection == ["l2", "l3", "l4", "l5"])
        #expect(trimmedHead.rejection == nil)

        // Interior row closer to the end: keep the longer head.
        let trimmedTail = LyricPosterSelectionPolicy.toggling("l4", in: rows, selection: selection)
        #expect(trimmedTail.selection == ["l1", "l2", "l3", "l4"])

        let single = LyricPosterSelectionPolicy.toggling("l3", in: rows, selection: ["l3"])
        #expect(single.selection.isEmpty)
    }

    @Test func expansionStopsAtTheDocumentEdgesAndGrowsBackwardWhenNeeded() {
        let rows = lines(4)
        let fromEnd = LyricPosterSelectionPolicy.expanded(from: ["l3"], in: rows, toCount: 3)
        #expect(fromEnd == ["l1", "l2", "l3"])

        let wholeDocument = LyricPosterSelectionPolicy.expanded(from: ["l0"], in: rows, toCount: 99)
        #expect(wholeDocument == ["l0", "l1", "l2", "l3"])

        #expect(LyricPosterSelectionPolicy.expanded(from: [], in: [], toCount: 3).isEmpty)
    }

    @Test func contentKeepsSelectionOrderAndDropsStaleIdentifiers() {
        let rows = lines(5)
        let content = LyricPosterSelectionPolicy.content(
            songTitle: "Song",
            artistName: "",
            albumTitle: "Album",
            year: 2026,
            lines: rows,
            selection: ["l3", "l2", "gone"]
        )
        #expect(content.lines.map(\.id) == ["l2", "l3"])
        // An empty artist string must not print as a blank credit line.
        #expect(content.artistName == nil)
        #expect(content.albumTitle == "Album")
        #expect(content.plainText == "line 2\nline 3")
        #expect(content.isSynchronized)
    }

    @Test func unsynchronizedDocumentsRemainSelectable() {
        let document = [
            LyricLine(id: "a", timestamp: 0, text: "plain one", isSynchronized: false),
            LyricLine(id: "b", timestamp: 0, text: "plain two", isSynchronized: false),
        ]
        let rows = LyricPosterSelectionPolicy.selectableLines(from: document)
        #expect(rows.count == 2)
        #expect(LyricPosterSelectionPolicy.defaultSelection(in: rows, playbackPosition: 30) == ["a"])

        let content = LyricPosterSelectionPolicy.content(
            songTitle: "Song",
            artistName: "Artist",
            albumTitle: nil,
            year: nil,
            lines: rows,
            selection: ["a", "b"]
        )
        #expect(!content.isSynchronized)
    }
}
