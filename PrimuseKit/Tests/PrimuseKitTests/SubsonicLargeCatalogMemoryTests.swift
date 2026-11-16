import Foundation
import Testing
@testable import PrimuseKit

@Suite("Subsonic large catalogue memory layout")
struct SubsonicLargeCatalogMemoryTests {
    private static func utf8StorageBase(_ string: String) -> UnsafeRawPointer? {
        var copy = string
        return copy.withUTF8 { UnsafeRawPointer($0.baseAddress) }
    }

    @Test("Paged staging delta interns album strings, rare boxes, and existing song IDs")
    func stagedDeltaInternsStringsAndRareBoxes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-stage-intern-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("staging.sqlite")
        let store = try PagedSongCatalogStagingStore(path: storeURL.path)

        let sourceID = "subsonic-source-uuid-0000000000000001"
        let albumID = "navidrome-album-identifier-00000001"
        let artistID = "navidrome-artist-identifier-0000001"
        let albumTitle = "Long Shared Album Title For Interning Verification"
        let artistName = "Long Shared Artist Name For Interning Verification"
        let coverRef = "https://music.example.invalid/rest/getCoverArt?id=al-00000001"

        func makeTrack(_ index: Int) -> Song {
            Song(
                id: "song-long-identifier-000000000000000\(index)",
                title: "Track \(index)",
                albumID: String(albumID),
                artistID: String(artistID),
                albumTitle: String(albumTitle),
                artistName: String(artistName),
                albumArtistName: String(artistName),
                trackNumber: index,
                duration: 210,
                fileFormat: .flac,
                filePath: "/songs/item-\(index).flac",
                sourceID: String(sourceID),
                fileSize: 24_000_000,
                genre: "Classical Orchestra",
                dateAdded: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                coverArtFileName: String(coverRef),
                serverLibraryID: "library-primary-0001",
                serverDateAdded: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                serverAlbumDateAdded: Date(timeIntervalSince1970: 1_690_000_000),
                serverCatalogAlbum: ServerCatalogAlbumReference(
                    id: String(albumID),
                    taggedArtist: String(artistName)
                )
            )
        }

        let first = makeTrack(1)
        let second = makeTrack(2)
        let unchangedExisting = makeTrack(3)

        try store.reset(
            sourceID: sourceID,
            stageSessionID: "s1",
            ownerGeneration: 1,
            replacingStageSessionID: nil,
            scopeFingerprint: "scope-1",
            catalogRevision: "rev-1"
        )
        try store.stagePage(
            sourceID: sourceID,
            stageSessionID: "s1",
            scopeFingerprint: "scope-1",
            catalogRevision: "rev-1",
            offset: 0,
            nextOffset: nil,
            itemIDs: ["1", "2", "3"],
            songs: [first, second, makeTrack(3)],
            metadataInspectedSongIDs: [first.id, second.id, unchangedExisting.id],
            hierarchyItems: [],
            addedSongCount: 3
        )

        let delta = try store.delta(
            sourceID: sourceID,
            existingByID: [unchangedExisting.id: unchangedExisting],
            batchSize: 2
        )

        #expect(delta.upserts.count == 2)
        let outA = try #require(delta.upserts.first { $0.trackNumber == 1 })
        let outB = try #require(delta.upserts.first { $0.trackNumber == 2 })

        #expect(outA.sharesRareFieldBoxForTesting(with: outB))
        #expect(Self.utf8StorageBase(outA.sourceID) == Self.utf8StorageBase(outB.sourceID))
        #expect(Self.utf8StorageBase(outA.albumTitle ?? "") == Self.utf8StorageBase(outB.albumTitle ?? ""))
        #expect(Self.utf8StorageBase(outA.artistName ?? "") == Self.utf8StorageBase(outB.artistName ?? ""))
        #expect(Self.utf8StorageBase(outA.coverArtFileName ?? "") == Self.utf8StorageBase(outB.coverArtFileName ?? ""))

        let authoritativeMatch = try #require(delta.authoritativeSongIDs.first { $0 == unchangedExisting.id })
        #expect(Self.utf8StorageBase(authoritativeMatch) == Self.utf8StorageBase(unchangedExisting.id))
    }

    @Test("SourceSyncStateFileStore evicts clean sync indexes and reloads on demand")
    func syncStateStoreEvictsAndRestoresIndex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-sync-evict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceID = "navidrome-main"
        var index = SourceSyncIndex()
        index["hierarchy-root:1"] = SourceSyncIndexedItem(
            stableKey: "hierarchy-root:1",
            path: "/Music",
            displayName: "Music",
            parentPath: nil,
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            revision: nil
        )
        index["song:1"] = SourceSyncIndexedItem(
            stableKey: "song:1",
            path: "/songs/1.flac",
            displayName: "Track 1",
            parentPath: "/Music",
            isDirectory: false,
            songIDs: ["s1"],
            size: 1234,
            modifiedDate: nil,
            revision: "r1"
        )

        let initialState = SourceSyncState(
            sourceID: sourceID,
            scopeFingerprint: "fp-1",
            index: index,
            scanEpoch: 1
        )
        let store = SourceSyncStateFileStore(directory: directory)
        _ = try await store.upsert(initialState, expectedMutationEpoch: 0)

        let beforeEvict = await store.snapshot()
        #expect(beforeEvict[sourceID]?.index.count == 2)

        await store.evictPersistedIndexes(for: [sourceID])
        let afterEvict = await store.snapshot()
        #expect(afterEvict[sourceID]?.index.isEmpty == true)

        let reloaded = try #require(
            try SourceSyncStateDirectory.readIndex(for: sourceID, in: directory)
        )
        #expect(reloaded.index == index)

        await store.restorePersistedIndex(
            reloaded.index,
            reference: reloaded.reference,
            for: sourceID
        )
        var rescannedMetadataOnly = initialState
        rescannedMetadataOnly.index = reloaded.index
        rescannedMetadataOnly.scanEpoch = 2
        _ = try await store.upsert(rescannedMetadataOnly, expectedMutationEpoch: 0)

        let reloadedFromDisk = SourceSyncStateDirectory.loadDirectory(directory)
        #expect(reloadedFromDisk.states[sourceID]?.scanEpoch == 2)
        #expect(reloadedFromDisk.states[sourceID]?.index == index)
    }
}
