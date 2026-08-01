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

    @Test("A small duration variance ranks ahead of an unknown-duration sparse result")
    func plausibleDurationOutranksSparseUnknown() {
        let plausible = rank(
            candidateDurationMs: targetMs + 11_000,
            album: "测试专辑",
            hasArtwork: true
        )
        let unknown = rank(candidateDurationMs: nil)

        #expect(plausible.durationTier == .plausible)
        #expect(ScrapeCandidateRankingPolicy.isPreferred(plausible, over: unknown))
    }

    @Test("Richer metadata breaks an unknown-duration identity tie")
    func richerMetadataBreaksUnknownDurationTie() {
        let rich = rank(
            candidateDurationMs: nil,
            album: "测试专辑",
            year: 2026,
            hasArtwork: true,
            trackNumber: 3,
            genreCount: 1
        )
        let sparse = rank(candidateDurationMs: nil)

        #expect(rich.durationTier == .unknown)
        #expect(rich.metadataCompleteness > sparse.metadataCompleteness)
        #expect(ScrapeCandidateRankingPolicy.isPreferred(rich, over: sparse))
    }

    @Test("Known duration and richer metadata break ties when the library duration is unavailable")
    func completenessWinsWithoutTargetDuration() {
        let rich = rank(
            hasTargetDuration: false,
            candidateDurationMs: targetMs,
            album: "测试专辑",
            hasArtwork: true
        )
        let sparse = rank(hasTargetDuration: false, candidateDurationMs: nil)

        #expect(rich.durationTier == .unavailable)
        #expect(sparse.durationTier == .unavailable)
        #expect(ScrapeCandidateRankingPolicy.isPreferred(rich, over: sparse))
    }

    @Test("Closer durations sort first within the same duration tier")
    func closerDurationWins() {
        let twoSecondsAway = rank(candidateDurationMs: targetMs + 2_000)
        let eightSecondsAway = rank(candidateDurationMs: targetMs + 8_000)

        #expect(ScrapeCandidateRankingPolicy.isPreferred(twoSecondsAway, over: eightSecondsAway))
    }

    @Test("Richer metadata wins before a small delta difference within one duration tier")
    func completenessWinsWithinDurationTier() {
        let sparse = rank(candidateDurationMs: targetMs + 2_000)
        let rich = rank(
            candidateDurationMs: targetMs + 8_000,
            album: "测试专辑",
            year: 2026,
            hasArtwork: true
        )

        #expect(sparse.durationTier == rich.durationTier)
        #expect(ScrapeCandidateRankingPolicy.isPreferred(rich, over: sparse))
    }

    @Test("Exact identity outranks plausible duration from the wrong artist")
    func identityOutranksPlausibleDuration() {
        let exactUnknown = rank(candidateDurationMs: nil)
        let wrongArtist = ScrapeCandidateRankingPolicy.rank(
            requestedTitle: "测试歌曲",
            requestedArtist: "测试歌手",
            targetDurationMs: targetMs,
            candidateTitle: "测试歌曲",
            candidateArtist: "另一位歌手",
            candidateDurationMs: targetMs + 1_000,
            candidateAlbum: "完整专辑",
            candidateHasArtwork: true
        )

        #expect(wrongArtist.artistTier == .conflict)
        #expect(wrongArtist.durationTier == .close)
        #expect(ScrapeCandidateRankingPolicy.isPreferred(exactUnknown, over: wrongArtist))
    }

    @Test("Reliable duration and rich metadata outrank an exact-artist result without duration")
    func reliableRichResultOutranksMissingDuration() {
        let sparseExactArtist = rank(candidateDurationMs: nil)
        let richWithoutArtist = rank(
            candidateArtist: nil,
            candidateDurationMs: targetMs + 1_000,
            album: "测试专辑",
            year: 2026,
            hasArtwork: true,
            trackNumber: 3,
            genreCount: 1
        )

        #expect(richWithoutArtist.artistTier == .unavailable)
        #expect(richWithoutArtist.durationTier == .close)
        #expect(ScrapeCandidateRankingPolicy.isPreferred(richWithoutArtist, over: sparseExactArtist))
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

    private func rank(
        hasTargetDuration: Bool = true,
        candidateArtist: String? = "测试歌手",
        candidateDurationMs: Int?,
        album: String? = nil,
        year: Int? = nil,
        hasArtwork: Bool = false,
        trackNumber: Int? = nil,
        genreCount: Int = 0
    ) -> ScrapeCandidateRank {
        ScrapeCandidateRankingPolicy.rank(
            requestedTitle: "测试歌曲",
            requestedArtist: "测试歌手",
            targetDurationMs: hasTargetDuration ? targetMs : nil,
            candidateTitle: "测试歌曲",
            candidateArtist: candidateArtist,
            candidateDurationMs: candidateDurationMs,
            candidateAlbum: album,
            candidateYear: year,
            candidateHasArtwork: hasArtwork,
            candidateTrackNumber: trackNumber,
            candidateGenreCount: genreCount
        )
    }
}
