import Testing
@testable import PrimuseKit

struct RecentlyDeletedPurgePlanTests {
    @Test func countsOnlyPurgeablePrimuseRecords() {
        let plan = RecentlyDeletedPurgePlan(
            playlistIDs: ["playlist-a", "playlist-b"],
            smartPlaylistIDs: ["smart-a"],
            sourceIDs: ["source-a"],
            scraperConfigurationIDs: ["scraper-a", "scraper-b"]
        )

        #expect(plan.count == 6)
        #expect(!plan.isEmpty)
        #expect(!plan.deletesRemoteMedia)
    }

    @Test func emptyPlanHasNoSideEffects() {
        let plan = RecentlyDeletedPurgePlan(
            playlistIDs: [],
            smartPlaylistIDs: [],
            sourceIDs: [],
            scraperConfigurationIDs: []
        )

        #expect(plan.isEmpty)
        #expect(plan.count == 0)
    }
}
