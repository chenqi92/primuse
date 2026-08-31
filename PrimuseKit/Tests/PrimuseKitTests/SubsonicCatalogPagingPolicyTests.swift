import Foundation
import Testing
@testable import PrimuseKit

struct SubsonicCatalogPagingPolicyTests {
    @Test func weakServerRevisionNeverAuthorizesMissingSongDeletion() {
        #expect(!SubsonicCatalogPagingPolicy.authorizesMissingSongDeletion)
    }

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
        #expect(SubsonicCatalogPagingPolicy.terminalVerificationOffset(
            currentOffset: 500,
            receivedCount: 300,
            nextOffset: nil
        ) == 800)
        #expect(SubsonicCatalogPagingPolicy.terminalVerificationOffset(
            currentOffset: 0,
            receivedCount: 500,
            nextOffset: 500
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

    @Test func resumeStateRequiresMatchingSchemaPageSizeAndStagedCount() {
        let state = SubsonicCatalogResumeState(
            stageSessionID: "session-a",
            catalogRevision: "scan:2",
            nextOffset: 500,
            completedPageCount: 1,
            stagedSongCount: 2,
            stagedItemCount: 2,
            firstPageItemIDs: ["one", "two"],
            seenItemIDs: ["one", "two"]
        )
        #expect(SubsonicCatalogPagingPolicy.canResume(state, stagedSongCount: 2))
        #expect(!SubsonicCatalogPagingPolicy.canResume(state, stagedSongCount: 1))

        var oldSchema = state
        oldSchema.schemaVersion = 0
        #expect(!SubsonicCatalogPagingPolicy.canResume(oldSchema, stagedSongCount: 2))

        var oldPageSize = state
        oldPageSize.pageSize = 250
        #expect(!SubsonicCatalogPagingPolicy.canResume(oldPageSize, stagedSongCount: 2))
    }

    @Test func completedResumeStateCanCommitWithoutAnotherPage() {
        let state = SubsonicCatalogResumeState(
            stageSessionID: "session-b",
            catalogRevision: "scan:800",
            nextOffset: nil,
            completedPageCount: 2,
            stagedSongCount: 800,
            stagedItemCount: 800,
            firstPageItemIDs: ["first"],
            seenItemIDs: Set((0..<800).map { String($0) })
        )
        #expect(state.isUsable(stagedSongCount: 800))
    }
}

@Suite("Paged Subsonic catalogue staging")
struct PagedSongCatalogStagingStoreTests {
    @Test("A page and its duplicate receipts commit atomically")
    func duplicatePageRollsBack() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-a",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            let first = makeSong(index: 1)
            let initial = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-a",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: 500,
                itemIDs: ["item-1"],
                songs: [first],
                metadataInspectedSongIDs: [first.id],
                hierarchyItems: [],
                addedSongCount: 1
            )

            #expect(throws: PagedSongCatalogStagingError.duplicateItemID("item-1")) {
                try store.stagePage(
                    sourceID: "source",
                    stageSessionID: "session-a",
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-a",
                    offset: 500,
                    nextOffset: nil,
                    itemIDs: ["item-2", "item-1"],
                    songs: [makeSong(index: 2)],
                    metadataInspectedSongIDs: [],
                    hierarchyItems: [],
                    addedSongCount: 1
                )
            }

            #expect(try store.snapshot(sourceID: "source") == initial)
            let delta = try store.delta(sourceID: "source", existingByID: [:])
            #expect(delta.upserts == [first])
            #expect(delta.authoritativeSongIDs == [first.id])
            #expect(delta.metadataInspectedSongIDs == [first.id])
        }
    }

    @Test("A newer scan generation owns reset and stale cancellation cannot erase it")
    func resetUsesGenerationCompareAndSwap() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-a",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-b",
                ownerGeneration: 2,
                replacingStageSessionID: "unknown-session",
                scopeFingerprint: "account-b",
                catalogRevision: "scan-b"
            )

            #expect(throws: PagedSongCatalogStagingError.scopeChanged) {
                try store.reset(
                    sourceID: "source",
                    stageSessionID: "stale-session",
                    ownerGeneration: 1,
                    replacingStageSessionID: "session-a",
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-a"
                )
            }
            let storedSnapshot = try store.snapshot(sourceID: "source")
            let snapshot = try #require(storedSnapshot)
            #expect(snapshot.stageSessionID == "session-b")
            #expect(snapshot.ownerGeneration == 2)
            #expect(snapshot.scopeFingerprint == "account-b")

            try store.discard(sourceID: "source", stageSessionID: "session-a")
            #expect(try store.snapshot(sourceID: "source")?.stageSessionID == "session-b")
            try store.discard(sourceID: "source", stageSessionID: "session-b")
            #expect(try store.snapshot(sourceID: "source") == nil)
        }
    }

    @Test("Staged progress survives reopening the SQLite store")
    func stagedProgressSurvivesColdRestart() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        do {
            let store = try PagedSongCatalogStagingStore(path: url.path)
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-cold",
                ownerGeneration: 7,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            _ = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-cold",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: 500,
                itemIDs: ["item-1"],
                songs: [makeSong(index: 1)],
                metadataInspectedSongIDs: [],
                hierarchyItems: [],
                addedSongCount: 1
            )
        }

        let reopened = try PagedSongCatalogStagingStore(path: url.path)
        let storedSnapshot = try reopened.snapshot(sourceID: "source")
        let snapshot = try #require(storedSnapshot)
        #expect(snapshot.stageSessionID == "session-cold")
        #expect(snapshot.ownerGeneration == 7)
        #expect(snapshot.nextOffset == 500)
        #expect(snapshot.stagedSongCount == 1)
        #expect(try reopened.delta(sourceID: "source", existingByID: [:]).upserts.count == 1)
    }

    @Test("Delta emits only changed rows and keeps a complete authoritative ID set")
    func deltaIsIncrementalAndAuthoritative() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-a",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            let unchanged = makeSong(index: 1)
            let added = makeSong(index: 2)
            _ = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-a",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: nil,
                itemIDs: ["item-1", "item-2"],
                songs: [unchanged, added],
                metadataInspectedSongIDs: [added.id],
                hierarchyItems: [],
                addedSongCount: 1
            )
            let removed = makeSong(index: 3)

            let delta = try store.delta(
                sourceID: "source",
                existingByID: [unchanged.id: unchanged, removed.id: removed]
            )

            #expect(delta.upserts == [added])
            #expect(delta.authoritativeSongIDs == [unchanged.id, added.id])
            #expect(!delta.authoritativeSongIDs.contains(removed.id))
            #expect(delta.metadataInspectedSongIDs == [added.id])
        }
    }

    @Test("Fractional server mtimes preserve local enrichment across staging")
    func fractionalModificationDateRoundTripsLosslessly() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-fractional",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            var existing = makeSong(index: 1)
            existing.lastModified = Date(timeIntervalSince1970: 1_700_000_000.123_456)
            existing.lyricsText = "device lyrics"
            existing.replayGainTrackGain = -7.25
            var incoming = existing
            incoming.lyricsText = nil
            incoming.replayGainTrackGain = nil
            _ = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-fractional",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: nil,
                itemIDs: ["item-1"],
                songs: [incoming],
                metadataInspectedSongIDs: [],
                hierarchyItems: [],
                addedSongCount: 0
            )

            let delta = try store.delta(
                sourceID: "source",
                existingByID: [existing.id: existing]
            )
            #expect(delta.upserts.isEmpty)
            #expect(delta.authoritativeSongIDs == [existing.id])
        }
    }

    @Test("Fifty thousand staged songs stay bounded and keyset-linear")
    func fiftyThousandSongDeltaStaysLinear() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-large",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-large"
            )
            var existing: [String: Song] = [:]
            existing.reserveCapacity(50_000)
            let clock = ContinuousClock()
            let start = clock.now
            for pageStart in stride(from: 0, to: 50_000, by: 500) {
                let songs = (pageStart..<pageStart + 500).map(makeSong(index:))
                for song in songs { existing[song.id] = song }
                _ = try store.stagePage(
                    sourceID: "source",
                    stageSessionID: "session-large",
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-large",
                    offset: pageStart,
                    nextOffset: pageStart + 500 < 50_000 ? pageStart + 500 : nil,
                    itemIDs: songs.map { "item-\($0.id)" },
                    songs: songs,
                    metadataInspectedSongIDs: [],
                    hierarchyItems: [],
                    addedSongCount: 0
                )
            }

            let delta = try store.delta(
                sourceID: "source",
                existingByID: existing,
                batchSize: 500
            )
            #expect(delta.upserts.isEmpty)
            #expect(delta.authoritativeSongIDs.count == 50_000)
            #expect(start.duration(to: clock.now) < .seconds(30))
        }
    }

    private func withStore(
        _ body: (PagedSongCatalogStagingStore) throws -> Void
    ) throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        try body(PagedSongCatalogStagingStore(path: url.path))
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-paged-catalog-\(UUID().uuidString).sqlite")
    }

    private func removeStoreFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
    }

    private func makeSong(index: Int) -> Song {
        Song(
            id: "song-\(index)",
            title: "Song \(index)",
            duration: 180,
            fileFormat: .mp3,
            filePath: "/Music/song-\(index).mp3",
            sourceID: "source",
            fileSize: 1_024,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            revision: "r1"
        )
    }
}
