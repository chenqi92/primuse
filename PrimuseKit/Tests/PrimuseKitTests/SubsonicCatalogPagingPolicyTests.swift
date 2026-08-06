import Testing
@testable import PrimuseKit

struct SubsonicCatalogPagingPolicyTests {
    @Test func directSongSearchIsLimitedToOpenSubsonicAndNavidrome() {
        #expect(SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: true,
            serverType: "gonic"
        ))
        #expect(SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: false,
            serverType: "Navidrome"
        ))
        #expect(!SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: false,
            serverType: "airsonic"
        ))
    }

    @Test func searchRequestFetchesOnlyOneFullSongPage() {
        let items = SubsonicCatalogPagingPolicy.search3QueryItems(
            songOffset: 500,
            musicFolderID: "7"
        )
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(values["query"] == "")
        #expect(values["artistCount"] == "0")
        #expect(values["albumCount"] == "0")
        #expect(values["songCount"] == "500")
        #expect(values["songOffset"] == "500")
        #expect(values["musicFolderId"] == "7")
    }

    @Test func fullPagesAdvanceAndFinalPagesStop() {
        #expect(SubsonicCatalogPagingPolicy.nextOffset(
            currentOffset: 0,
            receivedCount: 500
        ) == 500)
        #expect(SubsonicCatalogPagingPolicy.nextOffset(
            currentOffset: 500,
            receivedCount: 300
        ) == nil)
    }

    @Test func eightHundredSongsNeedOnlyTwoCatalogPages() {
        var requestedOffsets: [Int] = []
        var offset = 0
        for receivedCount in [500, 300] {
            requestedOffsets.append(offset)
            guard let next = SubsonicCatalogPagingPolicy.nextOffset(
                currentOffset: offset,
                receivedCount: receivedCount
            ) else { break }
            offset = next
        }

        #expect(requestedOffsets == [0, 500])
    }

    @Test func legacyAlbumWalkUsesBoundedConcurrencyAndWideSafetyLimits() {
        #expect(SubsonicCatalogPagingPolicy.legacyAlbumConcurrency == 6)
        #expect(SubsonicCatalogPagingPolicy.isWithinAlbumLimit(100_000))
        #expect(!SubsonicCatalogPagingPolicy.isWithinAlbumLimit(100_001))
        #expect(SubsonicCatalogPagingPolicy.isWithinSongLimit(10_000_000))
        #expect(!SubsonicCatalogPagingPolicy.isWithinSongLimit(10_000_001))
    }
}
