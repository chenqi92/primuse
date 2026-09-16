import Foundation
import Testing

@testable import PrimuseKit

struct ServerCatalogIncrementalSyncPolicyTests {
    private typealias Policy = ServerCatalogIncrementalSyncPolicy

    private func marker(
        revision: String = "emby:catalog:v1|lib-a=70000@1750000000",
        itemCount: Int = 70_000,
        modifiedSince: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> ServerCatalogSyncMarker {
        ServerCatalogSyncMarker(
            catalogRevision: revision,
            modifiedSince: modifiedSince,
            itemCount: itemCount
        )
    }

    // MARK: - When an incremental pass may run

    @Test func anOrdinaryPassWithAUsableMarkerRunsIncrementally() {
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: marker(),
                lastFullScanAt: Date(),
                requiresDeepScan: false
            ) == nil
        )
    }

    @Test func aDeepScanAlwaysWalksTheWholeCatalogue() {
        #expect(
            Policy.refusal(
                mode: .deep,
                marker: marker(),
                lastFullScanAt: Date(),
                requiresDeepScan: false
            ) == .explicitDeepScan
        )
    }

    @Test func aSourceOwedAReconciliationWalksTheWholeCatalogue() {
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: marker(),
                lastFullScanAt: Date(),
                requiresDeepScan: true
            ) == .deepScanRequired
        )
    }

    @Test func withoutAMarkerThereIsNothingToCompareAgainst() {
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: nil,
                lastFullScanAt: Date(),
                requiresDeepScan: false
            ) == .noUsableMarker
        )
        let stale = ServerCatalogSyncMarker(
            version: 0,
            catalogRevision: "r",
            modifiedSince: Date(),
            itemCount: 1
        )
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: stale,
                lastFullScanAt: Date(),
                requiresDeepScan: false
            ) == .noUsableMarker
        )
        let empty = ServerCatalogSyncMarker(
            catalogRevision: "",
            modifiedSince: Date(),
            itemCount: 1
        )
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: empty,
                lastFullScanAt: Date(),
                requiresDeepScan: false
            ) == .noUsableMarker
        )
    }

    /// The backstop: however good the change feed is, one complete walk has to
    /// happen periodically or a missed report would never be corrected.
    @Test func aCompleteWalkIsForcedOnceItIsDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justInside = now.addingTimeInterval(-Policy.completeWalkInterval + 60)
        let justOutside = now.addingTimeInterval(-Policy.completeWalkInterval - 60)
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: marker(),
                lastFullScanAt: justInside,
                requiresDeepScan: false,
                now: now
            ) == nil
        )
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: marker(),
                lastFullScanAt: justOutside,
                requiresDeepScan: false,
                now: now
            ) == .completeWalkDue
        )
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: marker(),
                lastFullScanAt: nil,
                requiresDeepScan: false,
                now: now
            ) == .completeWalkDue
        )
    }

    // MARK: - Distrusting a filter the server may have ignored

    @Test func aFilterThatReturnsTheWholeCatalogueIsNotAFilter() {
        #expect(Policy.modifiedFilterLooksIgnored(modifiedCount: 70_000, totalCount: 70_000))
        #expect(Policy.modifiedFilterLooksIgnored(modifiedCount: 70_001, totalCount: 70_000))
        #expect(Policy.modifiedFilterLooksIgnored(modifiedCount: 12, totalCount: 70_000) == false)
        #expect(Policy.modifiedFilterLooksIgnored(modifiedCount: 0, totalCount: 70_000) == false)
        // An empty catalogue tells us nothing either way.
        #expect(Policy.modifiedFilterLooksIgnored(modifiedCount: 0, totalCount: 0) == false)
    }

    // MARK: - When the id listing is required

    @Test func anUnchangedCatalogueNeedsNoIdListing() {
        #expect(
            Policy.requiresCatalogEnumeration(
                previousRevision: "r1",
                currentRevision: "r1",
                previousItemCount: 70_000,
                currentItemCount: 70_000,
                changedItemIDs: ["a", "b"],
                knownItemIDs: ["a", "b", "c"]
            ) == false
        )
    }

    @Test func aMovedRevisionAlwaysNeedsTheIdListing() {
        #expect(
            Policy.requiresCatalogEnumeration(
                previousRevision: "r1",
                currentRevision: "r2",
                previousItemCount: 70_000,
                currentItemCount: 70_000,
                changedItemIDs: [],
                knownItemIDs: ["a"]
            )
        )
        #expect(
            Policy.requiresCatalogEnumeration(
                previousRevision: "r1",
                currentRevision: nil,
                previousItemCount: 70_000,
                currentItemCount: 70_000,
                changedItemIDs: [],
                knownItemIDs: ["a"]
            )
        )
    }

    @Test func aChangedCountAlwaysNeedsTheIdListing() {
        #expect(
            Policy.requiresCatalogEnumeration(
                previousRevision: "r1",
                currentRevision: "r1",
                previousItemCount: 70_000,
                currentItemCount: 69_999,
                changedItemIDs: [],
                knownItemIDs: ["a"]
            )
        )
    }

    /// The case a naive implementation gets wrong: one row deleted and one
    /// added leaves the count identical, and the change feed only names the
    /// arrival. The unknown id is the tell that something also left.
    @Test func oneRowInAndOneRowOutStillNeedsTheIdListing() {
        #expect(
            Policy.requiresCatalogEnumeration(
                previousRevision: "r1",
                currentRevision: "r1",
                previousItemCount: 3,
                currentItemCount: 3,
                changedItemIDs: ["brand-new"],
                knownItemIDs: ["a", "b", "c"]
            )
        )
    }

    @Test func metadataEditsToKnownRowsNeedNoIdListing() {
        #expect(
            Policy.requiresCatalogEnumeration(
                previousRevision: "r1",
                currentRevision: "r1",
                previousItemCount: 3,
                currentItemCount: 3,
                changedItemIDs: ["a", "c"],
                knownItemIDs: ["a", "b", "c"]
            ) == false
        )
    }

    // MARK: - What the pass is allowed to conclude about deletions

    /// With an id listing, rows the server no longer lists drop out of the
    /// authoritative set — that is what lets the deletion policy remove them.
    @Test func anIdListingLetsARemovedRowFallOutOfTheAuthoritativeSet() {
        let known = ["item-a": "song-a", "item-b": "song-b", "item-c": "song-c"]
        let result = Policy.authoritativeSongIDs(
            knownSongIDsByItemID: known,
            remoteItemIDs: ["item-a", "item-c"],
            fetchedSongIDs: []
        )
        #expect(result == ["song-a", "song-c"])
        #expect(result.contains("song-b") == false, "the deleted row must not be authoritative")
    }

    /// Without an id listing the pass has seen no evidence of absence, so every
    /// known row stays authoritative and nothing can be removed.
    @Test func withoutAnIdListingNothingIsEverRemoved() {
        let known = ["item-a": "song-a", "item-b": "song-b"]
        let result = Policy.authoritativeSongIDs(
            knownSongIDsByItemID: known,
            remoteItemIDs: nil,
            fetchedSongIDs: ["song-new"]
        )
        #expect(result == ["song-a", "song-b", "song-new"])
    }

    @Test func freshlyFetchedRowsAreAlwaysAuthoritative() {
        let result = Policy.authoritativeSongIDs(
            knownSongIDsByItemID: ["item-a": "song-a"],
            remoteItemIDs: ["item-a", "item-new"],
            fetchedSongIDs: ["song-new"]
        )
        #expect(result == ["song-a", "song-new"])
    }

    @Test func anEmptyRemoteListingRemovesEverything() {
        let result = Policy.authoritativeSongIDs(
            knownSongIDsByItemID: ["item-a": "song-a", "item-b": "song-b"],
            remoteItemIDs: [],
            fetchedSongIDs: []
        )
        #expect(result.isEmpty)
    }

    // MARK: - What has to be fetched in full

    @Test func theChangeFeedDrivesTheFetchList() {
        #expect(
            Policy.itemIDsNeedingFetch(
                changedItemIDs: ["a", "b"],
                remoteItemIDs: nil,
                knownItemIDs: ["a", "b", "c"]
            ) == ["a", "b"]
        )
    }

    @Test func idsTheListingRevealedButTheFeedMissedAreStillFetched() {
        #expect(
            Policy.itemIDsNeedingFetch(
                changedItemIDs: ["a"],
                remoteItemIDs: ["a", "b", "c", "surprise"],
                knownItemIDs: ["a", "b", "c"]
            ) == ["a", "surprise"]
        )
    }

    /// A row named by the feed and then removed before the listing was read has
    /// nothing left to fetch.
    @Test func aRowThatLeftBetweenTheTwoRequestsIsNotFetched() {
        #expect(
            Policy.itemIDsNeedingFetch(
                changedItemIDs: ["a", "vanished"],
                remoteItemIDs: ["a", "b"],
                knownItemIDs: ["a", "b"]
            ) == ["a"]
        )
    }

    @Test func aQuietCatalogueFetchesNothing() {
        #expect(
            Policy.itemIDsNeedingFetch(
                changedItemIDs: [],
                remoteItemIDs: ["a", "b"],
                knownItemIDs: ["a", "b"]
            ).isEmpty
        )
    }

    // MARK: - Seeding the first marker

    @Test func aCompletedWalkLeavesAUsableMarker() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seeded = Policy.seedMarker(catalogRevision: "rev-1", itemCount: 70_000, now: now)
        #expect(seeded?.catalogRevision == "rev-1")
        #expect(seeded?.itemCount == 70_000)
        #expect(seeded?.isUsable == true)
        // The walk never read a server timestamp, so the first window starts
        // behind this device's clock by the skew margin.
        #expect(
            seeded?.modifiedSince == now.addingTimeInterval(-Policy.initialWatermarkMargin)
        )
        #expect(seeded.map { $0.modifiedSince < now } == true)
    }

    @Test func aWalkThatProvedNothingLeavesNoMarker() {
        #expect(Policy.seedMarker(catalogRevision: nil, itemCount: 70_000) == nil)
        #expect(Policy.seedMarker(catalogRevision: "", itemCount: 70_000) == nil)
        #expect(Policy.seedMarker(catalogRevision: "rev-1", itemCount: 0) == nil)
        #expect(Policy.seedMarker(catalogRevision: "rev-1", itemCount: -3) == nil)
    }

    /// The marker a walk seeds must be one an incremental pass will accept,
    /// otherwise the two halves never meet and every scan stays a full walk.
    @Test func aSeededMarkerIsAcceptedByTheNextPass() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seeded = Policy.seedMarker(catalogRevision: "rev-1", itemCount: 70_000, now: now)
        #expect(
            Policy.refusal(
                mode: .automatic,
                marker: seeded,
                lastFullScanAt: now,
                requiresDeepScan: false,
                now: now.addingTimeInterval(3_600)
            ) == nil
        )
    }

    // MARK: - The marker itself

    @Test func theMarkerRoundTrips() throws {
        let original = marker()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ServerCatalogSyncMarker.self, from: data) == original)
    }

    /// End to end on the shape that motivated all of this: the user deletes one
    /// track on the server and rescans.
    @Test func deletingOneTrackOnTheServerRemovesItLocally() {
        let known = ["item-1": "song-1", "item-2": "song-2", "item-3": "song-3"]
        let previous = marker(revision: "rev-3", itemCount: 3)

        // The count dropped, so the pass must read the id listing.
        let needsListing = Policy.requiresCatalogEnumeration(
            previousRevision: previous.catalogRevision,
            currentRevision: "rev-2",
            previousItemCount: previous.itemCount,
            currentItemCount: 2,
            changedItemIDs: [],
            knownItemIDs: Set(known.keys)
        )
        #expect(needsListing)

        let remote: Set<String> = ["item-1", "item-3"]
        #expect(
            Policy.itemIDsNeedingFetch(
                changedItemIDs: [],
                remoteItemIDs: remote,
                knownItemIDs: Set(known.keys)
            ).isEmpty,
            "a pure deletion needs no row fetched"
        )

        let authoritative = Policy.authoritativeSongIDs(
            knownSongIDsByItemID: known,
            remoteItemIDs: remote,
            fetchedSongIDs: []
        )
        let removed = Set(known.values).subtracting(authoritative)
        #expect(removed == ["song-2"])
    }
}

/// Runs the same sequence of decisions the connector makes, over a simulated
/// server, so the composition is exercised and not just each rule on its own.
struct ServerCatalogIncrementalSyncFlowTests {
    private typealias Policy = ServerCatalogIncrementalSyncPolicy

    /// What one pass concluded.
    private struct PassResult: Equatable {
        var fellBackToCompleteWalk = false
        var enumeratedIds = false
        var fetchedItemIDs: Set<String> = []
        var removedSongIDs: Set<String> = []
        var marker: ServerCatalogSyncMarker?
    }

    private struct Server {
        /// item id -> a stand-in for the row's content.
        var items: [String: String]
        /// Items whose `DateLastSaved` is at or after the pass's watermark.
        var changedSinceWatermark: Set<String>
        /// True when the deployment ignores `MinDateLastSaved`.
        var ignoresModifiedFilter = false

        var revision: String { "rev:\(items.count):\(items.keys.sorted().joined(separator: ","))" }
    }

    /// Mirrors `MediaServerSource.songCatalogChanges` step for step.
    private func runPass(
        marker: ServerCatalogSyncMarker,
        server: Server,
        localItemIDs: Set<String>
    ) -> PassResult {
        var result = PassResult()
        let totalCount = server.items.count
        let knownSongIDsByItemID = Dictionary(
            uniqueKeysWithValues: localItemIDs.map { ($0, "song-\($0)") }
        )

        let modifiedCount = server.ignoresModifiedFilter
            ? totalCount
            : server.changedSinceWatermark.count
        if Policy.modifiedFilterLooksIgnored(modifiedCount: modifiedCount, totalCount: totalCount) {
            result.fellBackToCompleteWalk = true
            return result
        }

        let changedItemIDs = server.ignoresModifiedFilter
            ? Set(server.items.keys)
            : server.changedSinceWatermark

        let remoteItemIDs: Set<String>?
        if Policy.requiresCatalogEnumeration(
            previousRevision: marker.catalogRevision,
            currentRevision: server.revision,
            previousItemCount: marker.itemCount,
            currentItemCount: totalCount,
            changedItemIDs: changedItemIDs,
            knownItemIDs: localItemIDs
        ) {
            remoteItemIDs = Set(server.items.keys)
            result.enumeratedIds = true
        } else {
            remoteItemIDs = nil
        }

        result.fetchedItemIDs = Policy.itemIDsNeedingFetch(
            changedItemIDs: changedItemIDs,
            remoteItemIDs: remoteItemIDs,
            knownItemIDs: localItemIDs
        )
        let authoritative = Policy.authoritativeSongIDs(
            knownSongIDsByItemID: knownSongIDsByItemID,
            remoteItemIDs: remoteItemIDs,
            fetchedSongIDs: Set(result.fetchedItemIDs.map { "song-\($0)" })
        )
        result.removedSongIDs = Set(knownSongIDsByItemID.values).subtracting(authoritative)
        result.marker = ServerCatalogSyncMarker(
            catalogRevision: server.revision,
            modifiedSince: marker.modifiedSince,
            itemCount: totalCount
        )
        return result
    }

    private func marker(for server: Server) -> ServerCatalogSyncMarker {
        ServerCatalogSyncMarker(
            catalogRevision: server.revision,
            modifiedSince: Date(timeIntervalSince1970: 1_750_000_000),
            itemCount: server.items.count
        )
    }

    @Test func aQuietCatalogueCostsNothingAndChangesNothing() {
        let server = Server(items: ["a": "1", "b": "1", "c": "1"], changedSinceWatermark: [])
        let pass = runPass(marker: marker(for: server), server: server, localItemIDs: ["a", "b", "c"])
        #expect(pass.fellBackToCompleteWalk == false)
        #expect(pass.enumeratedIds == false, "a quiet catalogue must not be re-listed")
        #expect(pass.fetchedItemIDs.isEmpty)
        #expect(pass.removedSongIDs.isEmpty)
    }

    @Test func aRetaggedTrackIsRefetchedWithoutRelistingTheCatalogue() {
        var server = Server(items: ["a": "1", "b": "1", "c": "1"], changedSinceWatermark: [])
        let before = marker(for: server)
        server.items["b"] = "2"
        server.changedSinceWatermark = ["b"]
        let pass = runPass(marker: before, server: server, localItemIDs: ["a", "b", "c"])
        #expect(pass.enumeratedIds == false)
        #expect(pass.fetchedItemIDs == ["b"])
        #expect(pass.removedSongIDs.isEmpty)
    }

    @Test func anAddedTrackIsFetchedAndNothingIsRemoved() {
        var server = Server(items: ["a": "1", "b": "1"], changedSinceWatermark: [])
        let before = marker(for: server)
        server.items["c"] = "1"
        server.changedSinceWatermark = ["c"]
        let pass = runPass(marker: before, server: server, localItemIDs: ["a", "b"])
        #expect(pass.enumeratedIds, "the count moved, so the listing has to be read")
        #expect(pass.fetchedItemIDs == ["c"])
        #expect(pass.removedSongIDs.isEmpty)
    }

    /// The case the user asked about: a track deleted on the server has to
    /// disappear locally, and no change feed can report it.
    @Test func aDeletedTrackIsRemovedLocally() {
        var server = Server(items: ["a": "1", "b": "1", "c": "1"], changedSinceWatermark: [])
        let before = marker(for: server)
        server.items["b"] = nil
        let pass = runPass(marker: before, server: server, localItemIDs: ["a", "b", "c"])
        #expect(pass.enumeratedIds)
        #expect(pass.fetchedItemIDs.isEmpty, "a deletion needs no row fetched")
        #expect(pass.removedSongIDs == ["song-b"])
    }

    /// One in, one out: the count is unchanged, so only the unknown id in the
    /// feed forces the listing that reveals the departure.
    @Test func oneTrackInAndOneOutIsFullyReconciled() {
        var server = Server(items: ["a": "1", "b": "1", "c": "1"], changedSinceWatermark: [])
        let before = marker(for: server)
        server.items["b"] = nil
        server.items["d"] = "1"
        server.changedSinceWatermark = ["d"]
        let pass = runPass(marker: before, server: server, localItemIDs: ["a", "b", "c"])
        #expect(pass.enumeratedIds)
        #expect(pass.fetchedItemIDs == ["d"])
        #expect(pass.removedSongIDs == ["song-b"])
    }

    /// A server that silently drops the filter must not be read as "everything
    /// changed"; it hands the pass to the complete walk instead.
    @Test func aServerThatIgnoresTheFilterFallsBackToTheCompleteWalk() {
        var server = Server(items: ["a": "1", "b": "1", "c": "1"], changedSinceWatermark: [])
        server.ignoresModifiedFilter = true
        let pass = runPass(marker: marker(for: server), server: server, localItemIDs: ["a", "b", "c"])
        #expect(pass.fellBackToCompleteWalk)
        #expect(pass.removedSongIDs.isEmpty, "a fallback must not conclude anything")
    }

    /// A creation the feed never reports is still picked up, because the
    /// listing names it and it is not one this device knows.
    @Test func aCreationMissedByTheFeedIsStillPickedUp() {
        var server = Server(items: ["a": "1", "b": "1"], changedSinceWatermark: [])
        let before = marker(for: server)
        server.items["silent"] = "1"
        // The feed reports nothing at all.
        let pass = runPass(marker: before, server: server, localItemIDs: ["a", "b"])
        #expect(pass.enumeratedIds)
        #expect(pass.fetchedItemIDs == ["silent"])
        #expect(pass.removedSongIDs.isEmpty)
    }

    /// Several passes in a row: each one starts from the marker the previous
    /// one left, and the library tracks the server exactly.
    @Test func successivePassesKeepTheLibraryInStep() {
        var server = Server(items: ["a": "1", "b": "1", "c": "1"], changedSinceWatermark: [])
        var local: Set<String> = ["a", "b", "c"]
        var current = marker(for: server)

        // 1. Nothing happens.
        var pass = runPass(marker: current, server: server, localItemIDs: local)
        #expect(pass.fetchedItemIDs.isEmpty && pass.removedSongIDs.isEmpty)
        current = try! #require(pass.marker)

        // 2. One added, one deleted, one retagged.
        server.items["c"] = nil
        server.items["d"] = "1"
        server.items["a"] = "2"
        server.changedSinceWatermark = ["d", "a"]
        pass = runPass(marker: current, server: server, localItemIDs: local)
        #expect(pass.enumeratedIds)
        #expect(pass.fetchedItemIDs == ["a", "d"])
        #expect(pass.removedSongIDs == ["song-c"])
        local.formUnion(pass.fetchedItemIDs)
        local.subtract(pass.removedSongIDs.map { String($0.dropFirst("song-".count)) })
        #expect(local == Set(server.items.keys), "library and server agree after the pass")
        current = try! #require(pass.marker)

        // 3. Quiet again — and now cheap again, because the marker caught up.
        server.changedSinceWatermark = []
        pass = runPass(marker: current, server: server, localItemIDs: local)
        #expect(pass.enumeratedIds == false)
        #expect(pass.fetchedItemIDs.isEmpty && pass.removedSongIDs.isEmpty)
    }
}
