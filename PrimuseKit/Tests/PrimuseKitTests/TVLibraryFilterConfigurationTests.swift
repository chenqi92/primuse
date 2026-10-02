import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple TV library filter strip visibility")
struct TVLibraryFilterConfigurationTests {
    @Test("Recommendations and ranking start hidden; the collection filters and years show")
    func defaults() {
        let configuration = TVLibraryFilterConfiguration.decode("")
        #expect(configuration == .default)
        #expect(configuration.visibleFilters == [.albums, .songs, .artists, .genres, .folders, .years])
        #expect(configuration.encoded() == "")
    }

    @Test("Turning a hidden filter back on survives a round trip")
    func reEnableRoundTrip() {
        var configuration = TVLibraryFilterConfiguration.default
        configuration.setShown(true, for: .ranking)
        let raw = configuration.encoded()
        #expect(!raw.isEmpty)
        let decoded = TVLibraryFilterConfiguration.decode(raw)
        #expect(decoded.isShown(.ranking))
        #expect(!decoded.isShown(.recommendations))
        #expect(decoded.visibleFilters.last == .ranking)

        var back = decoded
        back.setShown(false, for: .ranking)
        #expect(back.encoded() == "")
    }

    @Test("Collection filters cannot be hidden, even by a hand-edited value")
    func collectionFiltersStay() {
        var configuration = TVLibraryFilterConfiguration.default
        configuration.setShown(false, for: .albums)
        #expect(configuration.isShown(.albums))
        let decoded = TVLibraryFilterConfiguration.decode(#"{"hidden":["albums","songs","years","gone"]}"#)
        #expect(decoded.isShown(.albums))
        #expect(decoded.isShown(.songs))
        #expect(!decoded.isShown(.years))
        // Recommendations were not listed, so this person turned them on.
        #expect(decoded.isShown(.recommendations))
    }

    @Test("A hidden current filter falls back to the album wall")
    func hiddenSelectionFallsBack() {
        let configuration = TVLibraryFilterConfiguration.default
        #expect(configuration.resolved(.recommendations) == .albums)
        #expect(configuration.resolved(.years) == .years)
        #expect(TVLibraryFilterConfiguration.decode("garbage") == .default)
    }
}
