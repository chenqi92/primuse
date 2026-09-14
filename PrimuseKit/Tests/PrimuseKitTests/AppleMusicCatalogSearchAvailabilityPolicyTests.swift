import Testing
@testable import PrimuseKit

@Suite("Apple Music catalog search availability")
struct AppleMusicCatalogSearchAvailabilityPolicyTests {
    @Test("Search is available only when the catalog and source are enabled")
    func enablesSearchWhenEveryGateIsOpen() {
        #expect(AppleMusicCatalogSearchAvailabilityPolicy.isEnabled(
            catalogSearchEnabled: true,
            sourceInstalled: true,
            disabledSourceIDs: []
        ))
    }

    @Test("The catalog preference disables search")
    func catalogPreferenceDisablesSearch() {
        #expect(!AppleMusicCatalogSearchAvailabilityPolicy.isEnabled(
            catalogSearchEnabled: false,
            sourceInstalled: true,
            disabledSourceIDs: []
        ))
    }

    @Test("Disabling the Apple Music source disables search")
    func sourceDisablesSearch() {
        #expect(!AppleMusicCatalogSearchAvailabilityPolicy.isEnabled(
            catalogSearchEnabled: true,
            sourceInstalled: true,
            disabledSourceIDs: [AppleMusicLibraryIdentity.sourceID]
        ))
    }

    @Test("Removing the Apple Music source removes it from search too")
    func uninstalledSourceDisablesSearch() {
        #expect(!AppleMusicCatalogSearchAvailabilityPolicy.isEnabled(
            catalogSearchEnabled: true,
            sourceInstalled: false,
            disabledSourceIDs: []
        ))
    }

    @Test("Disabling another source does not disable Apple Music search")
    func unrelatedSourceDoesNotDisableSearch() {
        #expect(AppleMusicCatalogSearchAvailabilityPolicy.isEnabled(
            catalogSearchEnabled: true,
            sourceInstalled: true,
            disabledSourceIDs: ["another-source"]
        ))
    }
}
