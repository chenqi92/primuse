import Testing
@testable import PrimuseKit

@Suite("CUE scrape identity")
struct ScrapeCueIdentityPolicyTests {
    @Test("Forced file metadata cannot collapse CUE segment identity")
    func preservesCueIdentity() {
        #expect(ScrapeCueIdentityPolicy.resolvedTitle(
            original: "CUE Segment 440 Hz",
            scraped: "21-CUE-PCM",
            isCueTrack: true
        ) == "CUE Segment 440 Hz")
        #expect(ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: "Codex QA CUE Artist",
            scraped: "Unknown Artist",
            isCueTrack: true
        ) == "Codex QA CUE Artist")
        #expect(ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: "Codex QA CUE Album",
            scraped: "21-CUE-PCM",
            isCueTrack: true
        ) == "Codex QA CUE Album")
    }

    @Test("Ordinary tracks still accept scraped identity")
    func ordinaryTracksUseScrapedIdentity() {
        #expect(ScrapeCueIdentityPolicy.resolvedTitle(
            original: "track-01",
            scraped: "Correct Title",
            isCueTrack: false
        ) == "Correct Title")
        #expect(ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: "Unknown Artist",
            scraped: "Correct Artist",
            isCueTrack: false
        ) == "Correct Artist")
    }

    @Test("Missing CUE optional fields may still be filled")
    func fillsMissingCueFields() {
        #expect(ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: nil,
            scraped: "Recovered Album",
            isCueTrack: true
        ) == "Recovered Album")
    }
}
