import Testing
@testable import PrimuseKit

@Suite("Scrape metadata application policy")
struct ScrapeMetadataApplicationPolicyTests {
    @Test("Explicit rescrape requests metadata even when fields are populated")
    func forcedRefreshRequestsMetadata() {
        #expect(ScrapeMetadataApplicationPolicy.shouldRequestMetadata(
            fieldsAreMissing: false,
            forceRefresh: true
        ))
    }

    @Test("Background enrichment skips complete metadata")
    func backgroundRefreshSkipsCompleteMetadata() {
        #expect(!ScrapeMetadataApplicationPolicy.shouldRequestMetadata(
            fieldsAreMissing: false,
            forceRefresh: false
        ))
    }

    @Test("Explicit rescrape replaces known text with a matched candidate")
    func forcedRefreshReplacesKnownText() {
        #expect(ScrapeMetadataApplicationPolicy.resolvedText(
            original: "01 - old filename",
            scraped: "Canonical Song Title",
            overwrite: true
        ) == "Canonical Song Title")
    }

    @Test("Background enrichment preserves known text")
    func fillOnlyPreservesKnownText() {
        #expect(ScrapeMetadataApplicationPolicy.resolvedText(
            original: "Known Title",
            scraped: "Provider Title",
            overwrite: false
        ) == "Known Title")
    }

    @Test("Empty provider text never erases local metadata")
    func emptyProviderTextNeverErasesLocalMetadata() {
        #expect(ScrapeMetadataApplicationPolicy.resolvedText(
            original: "Known Artist",
            scraped: "   ",
            overwrite: true
        ) == "Known Artist")
    }

    @Test("Missing provider numbers never erase local metadata")
    func missingProviderValueNeverErasesLocalMetadata() {
        let resolved: Int? = ScrapeMetadataApplicationPolicy.resolvedValue(
            original: 2026,
            scraped: nil,
            overwrite: true
        )
        #expect(resolved == 2026)
    }
}
