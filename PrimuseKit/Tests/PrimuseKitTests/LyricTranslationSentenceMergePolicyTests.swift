import Foundation
import Testing
@testable import PrimuseKit

struct LyricTranslationSentenceMergePolicyTests {
    private func candidate(_ id: String, _ text: String, _ language: String? = "en") -> LyricTranslationCandidate {
        LyricTranslationCandidate(id: id, text: text, sourceLanguageCode: language)
    }

    @Test func fragmentsOfOneSentenceAreTranslatedTogether() {
        let merged = LyricTranslationSentenceMergePolicy.merged([
            candidate("1", "So when we started"),
            candidate("2", "the company back in 2010,"),
            candidate("3", "nobody believed us."),
            candidate("4", "That changed fast."),
        ], targetLanguageCode: "zh-Hans")

        #expect(merged.candidates.map(\.id) == ["1", "4"])
        #expect(merged.candidates.first?.text == "So when we started the company back in 2010, nobody believed us.")
        #expect(merged.mergedLineIDs == ["1": ["2", "3"]])
    }

    @Test func chineseFragmentsJoinWithoutSpaces() {
        let merged = LyricTranslationSentenceMergePolicy.merged([
            candidate("1", "我们当时觉得", "zh-Hans"),
            candidate("2", "这件事做不成。", "zh-Hans"),
            candidate("3", "后来才知道。", "zh-Hans"),
        ], targetLanguageCode: "en")

        #expect(merged.candidates.map(\.text) == ["我们当时觉得这件事做不成。", "后来才知道。"])
    }

    @Test func subtitlesWithoutPunctuationStayLineByLine() {
        let candidates = (1...6).map { candidate("\($0)", "line number \($0)") }
        let merged = LyricTranslationSentenceMergePolicy.merged(candidates, targetLanguageCode: "zh-Hans")

        #expect(merged.candidates == candidates)
        #expect(merged.mergedLineIDs.isEmpty)
    }

    @Test func longRunsAreCutAtTheLineLimit() {
        var candidates = (1...6).map { candidate("\($0)", "part \($0)") }
        candidates.append(candidate("7", "the end."))
        candidates.append(candidate("8", "Done."))
        let merged = LyricTranslationSentenceMergePolicy.merged(candidates, targetLanguageCode: "zh-Hans")

        #expect(merged.candidates.map(\.id) == ["1", "5", "8"])
        #expect(merged.mergedLineIDs["1"] == ["2", "3", "4"])
        #expect(merged.mergedLineIDs["5"] == ["6", "7"])
    }

    @Test func linesInTheTargetLanguageAreNotMerged() {
        let merged = LyricTranslationSentenceMergePolicy.merged([
            candidate("1", "我們當時覺得", "zh-Hant"),
            candidate("2", "這件事做不成。", "zh-Hant"),
            candidate("3", "Then it worked.", "en"),
        ], targetLanguageCode: "zh-Hans")

        #expect(merged.candidates.map(\.id) == ["1", "2", "3"])
        #expect(merged.mergedLineIDs.isEmpty)
    }

    @Test func languageChangeEndsTheSentence() {
        let merged = LyricTranslationSentenceMergePolicy.merged([
            candidate("1", "We said", "en"),
            candidate("2", "bonjour à tous", "fr"),
            candidate("3", "and left.", "en"),
            candidate("4", "Fine.", "en"),
        ], targetLanguageCode: "zh-Hans")

        #expect(merged.candidates.map(\.id) == ["1", "2", "3", "4"])
    }

    @Test func mergedLinesCountTowardCoverageButGetNoTranslationOfTheirOwn() {
        let group = LyricTranslationGroup(
            id: "en",
            sourceLanguageCode: "en",
            candidates: [candidate("1", "So when we started the company, nobody believed us.")]
        )
        let deduplication = LyricTranslationDeduplication(groups: [group], mergedLineIDs: ["1": ["2", "3"]])

        #expect(deduplication.expanding(["1": "译文"]) == ["1": "译文"])
        #expect(deduplication.restoringDuplicates(in: [group]).first?.candidates.map(\.id) == ["1", "2", "3"])
    }
}
