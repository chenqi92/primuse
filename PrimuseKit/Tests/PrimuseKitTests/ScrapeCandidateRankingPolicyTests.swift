import Testing
@testable import PrimuseKit

@Suite("Scrape candidate ranking policy")
struct ScrapeCandidateRankingPolicyTests {
    private let targetMs = 4 * 60 * 1_000 + 20_000

    @Test("A close known duration outranks a provider result without duration")
    func closeDurationOutranksUnknownDuration() {
        let close = rank(candidateDurationMs: targetMs + 1_000)
        let unknown = rank(candidateDurationMs: nil)

        #expect(ScrapeCandidateRankingPolicy.isPreferred(close, over: unknown))
        #expect(close.confidence > unknown.confidence)
    }

    @Test("Missing duration does not become a perfect confidence score")
    func missingDurationKeepsDurationWeight() {
        let unknown = rank(candidateDurationMs: nil)

        #expect(unknown.durationTier == .unknown)
        #expect(unknown.confidence == 0.5)
    }

    @Test("A seven minute result ranks below an unknown-duration result for a four minute song")
    func clearMismatchRanksLast() {
        let unknown = rank(candidateDurationMs: nil)
        let sevenMinutes = rank(candidateDurationMs: 7 * 60 * 1_000)

        #expect(sevenMinutes.durationTier == .mismatch)
        #expect(ScrapeCandidateRankingPolicy.isPreferred(unknown, over: sevenMinutes))
    }

    @Test("Closer durations sort first within the same duration tier")
    func closerDurationWins() {
        let twoSecondsAway = rank(candidateDurationMs: targetMs + 2_000)
        let eightSecondsAway = rank(candidateDurationMs: targetMs + 8_000)

        #expect(ScrapeCandidateRankingPolicy.isPreferred(twoSecondsAway, over: eightSecondsAway))
    }

    @Test("A title-incompatible result cannot win on duration alone")
    func titleCompatibilityRemainsIdentityGate() {
        let compatibleUnknown = rank(candidateDurationMs: nil)
        let wrongTitle = ScrapeCandidateRankingPolicy.rank(
            requestedTitle: "测试歌曲",
            requestedArtist: "测试歌手",
            targetDurationMs: targetMs,
            candidateTitle: "另一首歌",
            candidateArtist: "测试歌手",
            candidateDurationMs: targetMs
        )

        #expect(ScrapeCandidateRankingPolicy.isPreferred(compatibleUnknown, over: wrongTitle))
    }

    private func rank(candidateDurationMs: Int?) -> ScrapeCandidateRank {
        ScrapeCandidateRankingPolicy.rank(
            requestedTitle: "测试歌曲",
            requestedArtist: "测试歌手",
            targetDurationMs: targetMs,
            candidateTitle: "测试歌曲",
            candidateArtist: "测试歌手",
            candidateDurationMs: candidateDurationMs
        )
    }
}
