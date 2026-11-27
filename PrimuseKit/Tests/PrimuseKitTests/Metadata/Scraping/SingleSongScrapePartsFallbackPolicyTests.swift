import Testing
@testable import PrimuseKit

@Suite("TV single-song scrape parts fallback")
struct SingleSongScrapePartsFallbackPolicyTests {
    @Test("A source the user enabled keeps the full scrape")
    func fullSourceKeepsAllParts() {
        #expect(SingleSongScrapePartsFallbackPolicy.parts(fullSourceCount: 1, lyricsSourceCount: 2) == .all)
        #expect(SingleSongScrapePartsFallbackPolicy.parts(fullSourceCount: 3, lyricsSourceCount: 0) == .all)
    }

    @Test("Only the default-on lyrics source falls back to lyrics only")
    func defaultLyricsSourceSearchesLyrics() {
        let onlyDefaultOn = [true]
        let full = ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: onlyDefaultOn, for: .all)
        let lyrics = ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: onlyDefaultOn, for: .lyrics)
        #expect(SingleSongScrapePartsFallbackPolicy.parts(fullSourceCount: full, lyricsSourceCount: lyrics) == .lyrics)
    }

    @Test("No usable source asks for one")
    func noSourceReturnsNil() {
        #expect(SingleSongScrapePartsFallbackPolicy.parts(fullSourceCount: 0, lyricsSourceCount: 0) == nil)
        let none = ScraperSourceGatePolicy.usableSourceCount(enabledSourcesOnByDefault: [], for: .lyrics)
        #expect(SingleSongScrapePartsFallbackPolicy.parts(fullSourceCount: 0, lyricsSourceCount: none) == nil)
    }
}
