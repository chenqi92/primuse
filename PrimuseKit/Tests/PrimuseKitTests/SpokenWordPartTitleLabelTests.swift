import Testing
@testable import PrimuseKit

@Suite("Spoken word part title label")
struct SpokenWordPartTitleLabelTests {
    @Test func splitsNumberClosedOffBySpace() {
        let label = SpokenWordPartTitleLabel("36 【神作｜宿环】")
        #expect(label == SpokenWordPartTitleLabel(number: "36", title: "【神作｜宿环】"))
    }

    @Test func keepsOpeningBracketWithTitle() {
        let label = SpokenWordPartTitleLabel("36【神作｜宿环】")
        #expect(label == SpokenWordPartTitleLabel(number: "36", title: "【神作｜宿环】"))
    }

    @Test func dropsSeparatorsAndLeadingZeros() {
        #expect(SpokenWordPartTitleLabel("012. 风起") == SpokenWordPartTitleLabel(number: "12", title: "风起"))
        #expect(SpokenWordPartTitleLabel("007、开端") == SpokenWordPartTitleLabel(number: "7", title: "开端"))
        #expect(SpokenWordPartTitleLabel("05 - Chapter Five") == SpokenWordPartTitleLabel(number: "5", title: "Chapter Five"))
        #expect(SpokenWordPartTitleLabel("000_序章") == SpokenWordPartTitleLabel(number: "0", title: "序章"))
    }

    @Test func readsFullWidthDigits() {
        #expect(SpokenWordPartTitleLabel("３６　风起") == SpokenWordPartTitleLabel(number: "36", title: "风起"))
    }

    @Test func numberRunningIntoWordsStaysInTitle() {
        #expect(SpokenWordPartTitleLabel("3体") == SpokenWordPartTitleLabel(title: "3体"))
        #expect(SpokenWordPartTitleLabel("36集 风起") == SpokenWordPartTitleLabel(title: "36集 风起"))
        #expect(SpokenWordPartTitleLabel("2001: A Space Odyssey").number == "2001")
    }

    @Test func numberAloneIsTheTitle() {
        #expect(SpokenWordPartTitleLabel("1984") == SpokenWordPartTitleLabel(title: "1984"))
        #expect(SpokenWordPartTitleLabel("12 . ") == SpokenWordPartTitleLabel(title: "12 ."))
    }

    @Test func titlesWithoutLeadingNumberAreUntouched() {
        #expect(SpokenWordPartTitleLabel("  第十二回 风起  ") == SpokenWordPartTitleLabel(title: "第十二回 风起"))
        #expect(SpokenWordPartTitleLabel("Part 3") == SpokenWordPartTitleLabel(title: "Part 3"))
        #expect(SpokenWordPartTitleLabel("") == SpokenWordPartTitleLabel(title: ""))
    }

    @Test func overlongDigitRunsAreNotEpisodeNumbers() {
        #expect(SpokenWordPartTitleLabel("20260917 直播回放").number == nil)
    }
}
