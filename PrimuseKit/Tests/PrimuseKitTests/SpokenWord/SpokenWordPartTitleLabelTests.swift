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

    @Test func compoundNumberSplitsAwayWhole() {
        #expect(SpokenWordPartTitleLabel("2-4 风起") == SpokenWordPartTitleLabel(number: "2-4", title: "风起"))
        #expect(SpokenWordPartTitleLabel("1.1 序章") == SpokenWordPartTitleLabel(number: "1.1", title: "序章"))
        #expect(SpokenWordPartTitleLabel("10-12、夜航") == SpokenWordPartTitleLabel(number: "10-12", title: "夜航"))
        #expect(SpokenWordPartTitleLabel("1-1-3 Prologue") == SpokenWordPartTitleLabel(number: "1-1-3", title: "Prologue"))
        #expect(SpokenWordPartTitleLabel("2-4【神作】") == SpokenWordPartTitleLabel(number: "2-4", title: "【神作】"))
        #expect(SpokenWordPartTitleLabel("２－４ 风起") == SpokenWordPartTitleLabel(number: "2－4", title: "风起"))
    }

    @Test func compoundNumberKeepsItsZeros() {
        #expect(SpokenWordPartTitleLabel("01-02 风起") == SpokenWordPartTitleLabel(number: "01-02", title: "风起"))
    }

    @Test func compoundNumberAloneIsTheTitle() {
        #expect(SpokenWordPartTitleLabel("1-1") == SpokenWordPartTitleLabel(title: "1-1"))
        #expect(SpokenWordPartTitleLabel("2-4") == SpokenWordPartTitleLabel(title: "2-4"))
        #expect(SpokenWordPartTitleLabel("2.4") == SpokenWordPartTitleLabel(title: "2.4"))
        #expect(SpokenWordPartTitleLabel(" 0-1 ") == SpokenWordPartTitleLabel(title: "0-1"))
        #expect(SpokenWordPartTitleLabel("1-1.") == SpokenWordPartTitleLabel(title: "1-1."))
    }

    @Test func onlyNumbersAfterTheNumberAreNoTitle() {
        #expect(SpokenWordPartTitleLabel("1 - 1") == SpokenWordPartTitleLabel(title: "1 - 1"))
        #expect(SpokenWordPartTitleLabel("3 / 12") == SpokenWordPartTitleLabel(title: "3 / 12"))
    }

    @Test func compoundNumberRunningIntoWordsStaysInTitle() {
        #expect(SpokenWordPartTitleLabel("1.5倍速") == SpokenWordPartTitleLabel(title: "1.5倍速"))
        #expect(SpokenWordPartTitleLabel("2-4集 风起") == SpokenWordPartTitleLabel(title: "2-4集 风起"))
    }

    @Test func separatorNotFollowedByDigitStillEndsTheNumber() {
        #expect(SpokenWordPartTitleLabel("12.风起") == SpokenWordPartTitleLabel(number: "12", title: "风起"))
        #expect(SpokenWordPartTitleLabel("3-A 侧记") == SpokenWordPartTitleLabel(number: "3", title: "A 侧记"))
    }
}
