import Foundation
import AVFAudio
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PrimuseKit
import XCTest
@testable import Primuse

final class DirectoryScanCooldownTests: XCTestCase {
    func testDiscFormatErrorsAllowResumeAndIncrementalScanToFinish() async throws {
        let folder = "/Music/Discs"
        let path = folder + "/Archive.iso"
        let items = ["Archive.iso", "Uncatalogued.iso", "Data.iso", "Single.flac"].map {
            RemoteFileItem(name: $0, path: folder + "/" + $0, isDirectory: false,
                           size: 600 * 2048, modifiedDate: nil, parentPath: folder)
        }
        let tracks = [1, 2].map { (number: Int) in
            Song(id: "disc-\(number)", title: "Saved track \(number)", fileFormat: .sacdISO,
                 filePath: path, sourceID: "source", cueSheetPath: path,
                 cueStartTime: 0, sacdTrackNumber: number)
        }
        let connector = IncrementalReconciliationTestConnector(listings: [folder: items]) { path, offset, length in
            var sector = Data(repeating: 0, count: Int(length))
            if path.hasSuffix("/Data.iso") {
                if offset == 16 * 2048 {
                    sector.replaceSubrange(0..<6, with: [1] + Array("CD001".utf8))
                    sector[129] = 4 // ISO 9660 with an unsupported 1024-byte logical block.
                }
                return sector
            }
            if offset == 510 * 2048 {
                sector.replaceSubrange(0..<8, with: "SACDMTOC".utf8)
                sector[8] = 1 // No playable area in this master table.
            }
            return sector
        }
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        let checkpoint = SourceScanResumeState(pendingDirectories: [folder])
        var last: ConnectorScanner.ScanUpdate?
        for try await update in await scanner.scan(directories: ["/Music"], existingSongs: tracks, resumeState: checkpoint) {
            last = update
        }
        let final = try XCTUnwrap(last)
        XCTAssertEqual(final.resumeState?.pendingDirectories, [])
        XCTAssertEqual(final.songs.filter { $0.filePath == path }, tracks)
        XCTAssertEqual(final.songs.map(\.filePath).sorted(), [path, path, folder + "/Single.flac"])
        let index = await scanner.syncIndexSnapshot()
        XCTAssertEqual(index["path:" + path.lowercased()]?.songIDs, tracks.map(\.id))

        let delta = try await scanner.reconcileChangedDirectories(
            [folder], deletedStableKeys: [], existingSongs: final.songs,
            existingIndex: index, scanEpoch: 2, requiresCompleteListings: true
        )
        XCTAssertEqual(delta.songs, final.songs)
        XCTAssertEqual(delta.index["path:" + path.lowercased()]?.songIDs, tracks.map(\.id))
    }

    func testIncompleteSACDTableReadKeepsDirectoryPending() async throws {
        let item = RemoteFileItem(name: "Archive.iso", path: "/Music/Archive.iso", isDirectory: false,
                                  size: 600 * 2048, modifiedDate: nil)
        let connector = IncrementalReconciliationTestConnector(listings: ["/Music": [item]]) { _, offset, length in
            if offset == 520 * 2048 { return Data() }
            var sector = Data(repeating: 0, count: Int(length))
            if offset == 510 * 2048 {
                sector.replaceSubrange(0..<8, with: "SACDMTOC".utf8)
                sector[8] = 1
                sector.replaceSubrange(64..<68, with: [0, 0, 2, 8]) // Area TOC at sector 520.
            }
            return sector
        }
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        var checkpoint: SourceScanResumeState?
        do {
            for try await update in await scanner.scan(directories: ["/Music"]) {
                checkpoint = update.resumeState
            }
            XCTFail("An incomplete range read must remain retryable")
        } catch SACDISOReader.Failure.truncated {
            XCTAssertEqual(checkpoint?.pendingDirectories, ["/Music"])
        }
    }

    func testWebDAVDiscReadFailureCanResumeWithoutLosingSiblingSongs() async throws {
        let folder = "/Music/Discs"
        let listings = [folder: ["Disc.iso", "Single.flac"].map {
            RemoteFileItem(name: $0, path: folder + "/" + $0, isDirectory: false,
                           size: 600 * 2048, modifiedDate: nil)
        }]
        let saved = Song(id: "prior-track", title: "Saved track", fileFormat: .sacdISO,
                         filePath: folder + "/Disc.iso", sourceID: "source",
                         cueSheetPath: folder + "/Disc.iso", cueStartTime: 0, sacdTrackNumber: 1)
        let failures: [any Error] = [
            RemoteMetadataHTTPStatusError(service: "WebDAV", statusCode: 403),
            RemoteMetadataHTTPStatusError(service: "WebDAV", statusCode: 404),
            URLError(.networkConnectionLost)
        ]
        for failure in failures {
            let interrupted = IncrementalReconciliationTestConnector(listings: listings) { _, _, _ in throw failure }
            var state: SourceScanResumeState?
            do {
                for try await update in await ConnectorScanner(connector: interrupted, sourceID: "source")
                    .scan(directories: [folder], existingSongs: [saved]) {
                    state = update.resumeState
                }
                XCTFail("A failed file read must leave the directory available for retry")
            } catch {
                if let httpError = failure as? RemoteMetadataHTTPStatusError {
                    XCTAssertEqual((error as? RemoteMetadataHTTPStatusError)?.statusCode, httpError.statusCode)
                } else {
                    XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
                }
            }
            let checkpoint = try XCTUnwrap(state)
            XCTAssertEqual(checkpoint.pendingDirectories, [folder])
            let recovered = IncrementalReconciliationTestConnector(listings: listings) { _, offset, length in
                var data = Data(repeating: 0, count: Int(length))
                if offset == 510 * 2048 { data.replaceSubrange(0..<8, with: "SACDMTOC".utf8) }
                return data
            }
            var final: ConnectorScanner.ScanUpdate?
            for try await update in await ConnectorScanner(connector: recovered, sourceID: "source")
                .scan(directories: [folder], existingSongs: [saved], resumeState: checkpoint) {
                final = update
            }
            let result = try XCTUnwrap(final)
            XCTAssertEqual(result.songs.filter { $0.id == saved.id }, [saved])
            XCTAssertEqual(result.songs.map(\.filePath).sorted(), [saved.filePath, folder + "/Single.flac"])
            XCTAssertEqual(result.resumeState?.pendingDirectories, [])
        }
    }

    /// 走查每个目录交一份断点快照,之后接着往下记。交出去的快照不能被之后的写入改到;
    /// 从中途任何一份快照续扫,得到的索引与歌曲和一口气走完的完全一样;快照写进断点
    /// (段文件)再读回来也照样能续。
    func testWalkResumeSnapshotsStayFrozenAndResumeReproducesTheFullWalk() async throws {
        var listings: [String: [RemoteFileItem]] = [:]
        var root: [RemoteFileItem] = []
        for artist in 0..<6 {
            let artistPath = "/Music/歌手 \(artist)"
            root.append(RemoteFileItem(name: "歌手 \(artist)", path: artistPath, isDirectory: true, size: 0, modifiedDate: nil))
            var albums: [RemoteFileItem] = [RemoteFileItem(
                name: "artist.jpg", path: "\(artistPath)/artist.jpg", isDirectory: false, size: 10, modifiedDate: nil
            )]
            for album in 0..<5 {
                let albumPath = "\(artistPath)/专辑 \(album)"
                albums.append(RemoteFileItem(name: "专辑 \(album)", path: albumPath, isDirectory: true, size: 0, modifiedDate: nil))
                var tracks: [RemoteFileItem] = []
                for track in 0..<13 {
                    let name = String(format: "%02d 歌 %d.flac", track + 1, artist * 100 + album * 13 + track)
                    tracks.append(RemoteFileItem(name: name, path: "\(albumPath)/\(name)", isDirectory: false,
                                                 size: Int64(1_000 + track), modifiedDate: nil, revision: "e\(track)"))
                }
                tracks.append(RemoteFileItem(name: "cover.jpg", path: "\(albumPath)/cover.jpg", isDirectory: false,
                                             size: 20, modifiedDate: nil))
                listings[albumPath] = tracks
            }
            listings[artistPath] = albums
        }
        listings["/Music"] = root
        let connector = IncrementalReconciliationTestConnector(listings: listings)
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        var snapshots: [(state: SourceScanResumeState, index: [String: SourceSyncIndexedItem], songs: Set<String>)] = []
        var last: ConnectorScanner.ScanUpdate?
        for try await update in await scanner.scan(directories: ["/Music"], scanEpoch: 4) {
            last = update
            if let resume = update.resumeState {
                snapshots.append((resume, resume.index, resume.encounteredSongIDs))
            }
        }
        let full = try XCTUnwrap(last)
        let fullIndex = await scanner.syncIndexSnapshot()
        XCTAssertEqual(full.songs.count, 6 * 5 * 13)
        // 目录 6 + 30、歌 390、图片(歌手图 6、封面 30,自动歌手封面要用)。
        XCTAssertEqual(fullIndex.count, 36 + 390 + 36)
        XCTAssertGreaterThan(snapshots.count, 30)
        for (offset, snapshot) in snapshots.enumerated() {
            XCTAssertEqual(snapshot.state.index, snapshot.index, "snapshot \(offset) was changed after it was handed out")
            XCTAssertEqual(snapshot.state.encounteredSongIDs, snapshot.songs, "snapshot \(offset)")
        }
        let segmentCount = snapshots.last?.state.walkLog.segments.count ?? 0
        XCTAssertLessThanOrEqual(segmentCount, 1, "the terminal snapshot is consolidated")

        let segmentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("walk-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: segmentDirectory) }
        for offset in [1, snapshots.count / 3, snapshots.count / 2, snapshots.count - 2] {
            var resume = snapshots[offset].state
            if offset == snapshots.count / 2 {
                // 走一遍断点文件:段写到旁边,JSON 只留清单,冷启动读回。
                let encoder = JSONEncoder()
                encoder.userInfo[.scanResumeSegmentStore] = ScanResumeSegmentStore(directory: segmentDirectory)
                let decoder = JSONDecoder()
                decoder.userInfo[.scanResumeSegmentStore] = ScanResumeSegmentStore(directory: segmentDirectory)
                resume = try decoder.decode(SourceScanResumeState.self, from: encoder.encode(resume))
                XCTAssertTrue(resume.isUsable)
                XCTAssertEqual(resume, snapshots[offset].state)
            }
            let resumedScanner = ConnectorScanner(connector: connector, sourceID: "source")
            var resumed: ConnectorScanner.ScanUpdate?
            for try await update in await resumedScanner.scan(
                directories: ["/Music"], existingSongs: full.songs, resumeState: resume, scanEpoch: 4
            ) { resumed = update }
            let resumedIndex = await resumedScanner.syncIndexSnapshot()
            XCTAssertEqual(resumedIndex, fullIndex, "resumed from snapshot \(offset)")
            XCTAssertEqual(Set(try XCTUnwrap(resumed).songs.map(\.id)), Set(full.songs.map(\.id)))
        }
    }

    func testLargeDirectoryProgressReusesSafeResumeBoundary() async throws {
        let items = (0..<52_258).map { offset in
            RemoteFileItem(name: "track-\(offset).mp3", path: "/Music/track-\(offset).mp3",
                           isDirectory: false, size: 100, modifiedDate: nil)
        }
        let connector = IncrementalReconciliationTestConnector(listings: ["/Music": items])
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        var last: ConnectorScanner.ScanUpdate?
        var progressCount = 0
        var boundary: SourceScanResumeState?
        for try await update in await scanner.scan(directories: ["/Music"]) {
            last = update
            if !update.currentFile.isEmpty, update.addedCount > 0,
               let resume = update.resumeState {
                progressCount += 1
                XCTAssertTrue(resume.index.isEmpty)
                XCTAssertTrue(resume.encounteredSongIDs.isEmpty)
                XCTAssertEqual(resume.pendingDirectories, ["/Music"])
                boundary = resume
            }
        }
        XCTAssertGreaterThan(progressCount, 0)
        XCTAssertEqual(last?.songs.count, items.count)
        XCTAssertEqual(last?.resumeState?.index.count, items.count)
        let partial = Array(try XCTUnwrap(last).songs.prefix(100))
        for try await update in await scanner.scan(
            directories: ["/Music"], existingSongs: partial,
            resumeState: try XCTUnwrap(boundary)
        ) { last = update }
        XCTAssertEqual(Set(last?.songs.map(\.id) ?? []).count, items.count)
        XCTAssertEqual(last?.resumeState?.pendingDirectories, [])
    }

    @MainActor
    func testGoogleDriveAddingSongsKeepsCompletedTagsAfterWarmAndColdRescan() async throws {
        for storedIdentity in ["warm", "persisted", "missing"] {
            for incremental in [false, true] {
                let fixture = GoogleDriveRescanFixture()
                GoogleDriveRescanProtocol.fixtures.insert(fixture)
                defer { GoogleDriveRescanProtocol.fixtures.remove(fixture.id) }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [GoogleDriveRescanProtocol.self]
                configuration.httpAdditionalHeaders = ["X-Fixture-ID": fixture.id]
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let connector = GoogleDriveSource(sourceID: fixture.id, session: session,
                    tokenProvider: { "fixture-token" }, requests: CloudRequestScheduler())
                let scanner = ConnectorScanner(connector: connector, sourceID: fixture.id)
                var mutationCount = 0
                func scan(_ existing: [Song]) async throws -> [Song] {
                    var songs: [Song] = []
                    for try await update in await scanner.scan(directories: ["folder-id"], existingSongs: existing) {
                        if update.carriesFullSnapshot { songs = update.songs }
                        mutationCount = update.mutationCount
                    }
                    return songs
                }
                let initial = try await scan([])
                XCTAssertEqual(initial.count, 100)
                let index = await scanner.syncIndexSnapshot()
                var completed = initial.map { song -> Song in
                    var song = song
                    song.title = "Embedded \(song.filePath)"
                    song.artistName = "Embedded artist"
                    song.duration = 180
                    song.bitRate = 192
                    song.coverArtFileName = "existing-cover.jpg"
                    song.audioCodec = song.fileFormat == .m4a ? .aac : song.fileFormat
                    song.contentMetadata = .init(isFileInspectionComplete: true)
                    return song
                }
                if storedIdentity == "persisted" {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    completed = try decoder.decode([Song].self, from: encoder.encode(completed))
                } else if storedIdentity == "missing" {
                    for index in completed.indices {
                        completed[index].lastModified = nil
                        completed[index].revision = nil
                    }
                }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(fixture.id)
                defer { try? FileManager.default.removeItem(at: root) }
                let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
                library.addSongs(completed)
                let state = root.appendingPathComponent("state")
                try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
                try JSONEncoder().encode(completed.map(\.id))
                    .write(to: state.appendingPathComponent("backfill-title-checked.json"))
                let sourceID = fixture.id
                let backfill = MetadataBackfillService(library: library,
                    sourceManager: SourceManager(sourcesProvider: { [] }),
                    backfillableSourceIDs: { [sourceID] }, storageDirectory: state)
                backfill.automaticWorkIsAllowed = { false }
                defer { backfill.stop() }
                backfill.refreshStatusSnapshot()
                XCTAssertEqual(backfill.remainingCount(forSource: sourceID), 0)

                fixture.addSongs()
                let rescanned: [Song]
                if incremental {
                    let result = try await scanner.reconcileChangedDirectories(["folder-id"],
                        deletedStableKeys: [], existingSongs: library.songs, existingIndex: index,
                        scanEpoch: 2, requiresCompleteListings: true)
                    rescanned = result.songs
                } else {
                    rescanned = try await scan(library.songs)
                    XCTAssertEqual(mutationCount, storedIdentity == "missing" ? 103 : 3,
                        "Only new rows or newly available identity fields should be published")
                }
                library.addSongs(rescanned)
                backfill.refreshStatusSnapshot()
                let context = "identity=\(storedIdentity), incremental=\(incremental)"
                XCTAssertEqual(library.songs.count, 103, context)
                XCTAssertEqual(backfill.remainingCount(forSource: sourceID), 3, context)
                for original in completed {
                    let retained = try XCTUnwrap(library.song(id: original.id))
                    XCTAssertEqual(retained.title, original.title, context)
                    XCTAssertEqual(retained.duration, original.duration, context)
                    XCTAssertEqual(retained.artistName, original.artistName, context)
                    XCTAssertEqual(retained.coverArtFileName, original.coverArtFileName, context)
                    XCTAssertNotNil(retained.lastModified, context)
                    XCTAssertEqual(retained.revision, "content-\(retained.filePath.replacingOccurrences(of: "track-id-", with: ""))", context)
                    XCTAssertFalse(backfill.needsPlaybackTagRead(songID: original.id,
                        expectedSourceID: sourceID), context)
                }
                XCTAssertEqual(fixture.unexpectedRequests, 0, "Rescans must not open unchanged audio files")

                fixture.replaceFirstSong()
                library.addSongs(try await scan(library.songs))
                backfill.refreshStatusSnapshot()
                XCTAssertEqual(backfill.remainingCount(forSource: sourceID), 4,
                    "A same-size replacement must still reread its tags: \(context)")
                XCTAssertEqual(library.songs.first { $0.filePath == "track-id-0" }?.duration, 0)
            }
        }
    }

    @MainActor
    func testUnchangedFileTreeKeepsTagsWithoutRepublishingButAppliesRealChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = MusicSource(id: UUID().uuidString, name: "File tree", type: .webdav)
        source.extraConfig = MusicSource.encodeScannedDirectories(["/Music"], into: nil, type: source.type)
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let connector = MutableFileTreeConnector(sourceID: source.id)
        let scan = ScanService(fileManager: BaiduRepairFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) })
        let manager = SourceManager(sourcesProvider: { [source] in [source] })
        var completions: [SourceScanLifecycleCompletion] = []
        scan.successfulSourceScanHandler = { _, completion in completions.append(completion) }
        defer { scan.cancelAllActiveScans() }
        func run() async throws {
            XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library,
                sourceStore: store, requestsContinuedProcessing: false))
            let deadline = Date().addingTimeInterval(10)
            while scan.scanStates[source.id]?.isScanning == true, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(scan.scanStates[source.id]?.isScanning == true)
            XCTAssertFalse(scan.scanStates[source.id]?.canResume == true)
            XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        }
        try await run()
        XCTAssertEqual(library.songs.count, 2)
        let tagged = library.songs.map { song -> Song in
            var song = song
            song.duration = 180
            song.artistName = "Existing artist"
            return song
        }
        library.addSongs(tagged)
        let before = library.musicSongsRevision
        let stored = library.songs
        try await run()
        XCTAssertEqual(completions.last, .committedNoChanges)
        XCTAssertEqual(library.musicSongsRevision, before, "Unchanged scans must not invalidate the song library")
        XCTAssertEqual(library.songs, stored)

        await connector.setPhase(1)
        try await run()
        XCTAssertEqual(completions.last, .committedSnapshot)
        XCTAssertEqual(library.songs.count, 3)
        XCTAssertEqual(library.songs.first { $0.filePath.hasSuffix("keep.mp3") }?.fileSize, 200)
        XCTAssertEqual(library.songs.first { $0.filePath.hasSuffix("keep.mp3") }?.duration, 0)
        XCTAssertEqual(library.songs.first { $0.filePath.hasSuffix("remove.mp3") }?.duration, 180)
        await connector.setPhase(2)
        try await run()
        XCTAssertEqual(completions.last, .committedSnapshot)
        XCTAssertEqual(library.songs.count, 2)
        XCTAssertFalse(library.songs.contains { $0.filePath.hasSuffix("remove.mp3") })
    }

    @MainActor
    func testMissingBaiduIndexRescansOnlyRequestedSubtreeAndKeepsOtherSongs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = MusicSource(id: UUID().uuidString, name: "Baidu", type: .baiduPan)
        source.extraConfig = MusicSource.encodeScannedDirectories(["/Music"], into: nil, type: source.type)
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let songs = ["/Music/A/keep.mp3", "/Music/A/Removed/old.mp3", "/Music/B/other.mp3"].enumerated().map { i, path in
            Song(id: "known-\(i)", title: "Tagged \(i)", duration: 180, fileFormat: .mp3,
                 filePath: path, sourceID: source.id, fileSize: 100)
        }
        library.addSongs(songs)
        let connector = ScopedBaiduRepairConnector(sourceID: source.id)
        let scan = ScanService(fileManager: BaiduRepairFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) })
        let manager = SourceManager(sourcesProvider: { [source] in [source] })
        XCTAssertTrue(scan.rescanFolder(of: source, request: SourceFolderRescanRequest(directoryCandidates: ["/Music/A", "/Music", "/"]),
            sourceManager: manager, library: library, sourceStore: store))
        let deadline = Date().addingTimeInterval(15)
        while scan.scanStates[source.id]?.isScanning == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        defer { scan.cancelScan(for: source.id) }
        XCTAssertNotNil(store.source(id: source.id)?.lastScannedAt)
        let paths = await connector.listedPaths
        XCTAssertEqual(paths, ["/Music/A"])
        XCTAssertEqual(Set(library.songs.map(\.id)), ["known-0", "known-2"])
        XCTAssertEqual(library.song(id: "known-0")?.title, "Tagged 0")
        XCTAssertEqual(library.song(id: "known-2")?.duration, 180)

        let index = scan.libraryFolderSyncIndex(for: source.id)
        store.update(source.id) { $0.scannedDirectoryDisplayNames = ["/Music": "Display name"] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scan.libraryFolderSyncIndex(for: source.id), index)
    }

    @MainActor
    func testCapacityEvictionRetainsInspectionAcrossRestartAndRecoversOnPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root.appendingPathComponent("artwork"))
        let data = try artworkData()
        let ids = (0..<200).map { "evicted-\($0)" }
        for id in ids { store.storeCoverSync(data, for: id) }
        let cover = store.expectedCoverFileName(for: ids[0])
        let identifier = try XCTUnwrap(store.coverContentIdentifier(named: cover))
        let content = store.artworkContentDirectoryURL.appendingPathComponent(identifier.replacingOccurrences(of: "sha256:", with: "") + ".jpg")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: content.path)
        let removed = expectation(description: "capacity eviction must not reopen song rows")
        removed.isInverted = true
        let token = NotificationCenter.default.addObserver(forName: .primuseArtworkContentEvicted, object: nil, queue: .main) { _ in removed.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        let completed = await store.performScheduledContentMaintenance(maximumArtworkBytes: 1)
        XCTAssertTrue(completed)
        await fulfillment(of: [removed], timeout: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: content.path))

        let relaunched = MetadataAssetStore(storageDirectory: root.appendingPathComponent("artwork"))
        let songs = ids.map { id -> Song in
            var song = Song(id: id, title: "Tagged", duration: 180, fileFormat: .mp3, filePath: "/Music/\(id).mp3", sourceID: "baidu")
            song.artistName = "Artist"
            song.coverArtFileName = store.expectedCoverFileName(for: id)
            return song
        }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        library.addSongs(songs)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids).write(to: state.appendingPathComponent("backfill-title-checked.json"))
        let backfill = MetadataBackfillService(library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { ["baidu"] }, storageDirectory: state, artworkStore: relaunched)
        defer { backfill.stop() }
        await backfill.reopenSongsWithUnreadableCoverFiles()
        backfill.sourceScanSucceeded(forSourceID: "baidu")
        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCount(forSource: "baidu"), 0)
        XCTAssertEqual(library.song(id: ids[0])?.coverArtFileName, cover)
        XCTAssertTrue(backfill.needsPlaybackTagRead(songID: ids[0], expectedSourceID: "baidu"))
        XCTAssertTrue(relaunched.isCoverContentEvicted(named: cover))
        relaunched.storeCoverSync(data, for: ids[0])
        XCTAssertEqual(relaunched.readCoverData(named: cover), data)
        XCTAssertFalse(relaunched.isCoverContentEvicted(named: cover))
        XCTAssertFalse(backfill.needsPlaybackTagRead(songID: ids[0], expectedSourceID: "baidu"))
        XCTAssertTrue(relaunched.hasReadableCoverFile(named: store.expectedCoverFileName(for: ids[199])), "One recovered content object repairs every shared reference")
        try FileManager.default.removeItem(at: content)
        XCTAssertFalse(relaunched.isCoverContentEvicted(named: cover), "An accidental loss after recovery must not inherit the old capacity marker")
    }

    @MainActor
    func testLegacyArtworkQueueDefersInspectedRowsButKeepsUnreadMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let ids = (0..<500).map { "legacy-artwork-\($0)" }
        var songs = ids.map { id -> Song in
            var song = Song(id: id, title: "Tagged", duration: 180, fileFormat: .mp3, filePath: "/Music/\(id).mp3", sourceID: "baidu")
            song.artistName = "Artist"
            return song
        }
        songs.append(Song(id: "unread", title: "New", fileFormat: .mp3, filePath: "/Music/new.mp3", sourceID: "baidu"))
        library.addSongs(songs)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids).write(to: state.appendingPathComponent("backfill-title-checked.json"))
        let backfill = MetadataBackfillService(library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { ["baidu"] }, storageDirectory: state)
        defer { backfill.stop() }
        // 启动时挑出只差封面的行在后台执行器上做,等它落定再对账;重启那一次靠落盘状态,不用等。
        await backfill.deferInspectedArtworkOnlyRows()?.value
        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCount(forSource: "baidu"), 1)
        XCTAssertTrue(backfill.needsPlaybackTagRead(songID: ids[0], expectedSourceID: "baidu"))
        XCTAssertTrue(backfill.needsPlaybackTagRead(songID: "unread", expectedSourceID: "baidu"))
        XCTAssertEqual(library.song(id: ids[0])?.duration, 180)
        backfill.stop()
        let persisted = state.appendingPathComponent("backfill-peer-seeds.json")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: persisted.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: persisted.path))
        let relaunched = MetadataBackfillService(library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { ["baidu"] }, storageDirectory: state)
        defer { relaunched.stop() }
        relaunched.refreshStatusSnapshot()
        XCTAssertEqual(relaunched.remainingCount(forSource: "baidu"), 1)
        XCTAssertTrue(relaunched.needsPlaybackTagRead(songID: ids[0], expectedSourceID: "baidu"))
    }

    private func artworkData() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testLargeIncrementalReconciliationPreservesMetadataOutsideActualChanges() async throws {
        var existing: [Song] = []
        var index: [String: SourceSyncIndexedItem] = [:]
        var listings: [String: [RemoteFileItem]] = [:]
        for directory in 0..<40 {
            let parent = "/Music/Album-\(directory)"
            for track in 0..<50 {
                let id = "song-\(directory)-\(track)"
                let path = "\(parent)/Track-\(track).mp3"
                var song = Song(id: id, title: "Tagged \(id)", duration: 180,
                                fileFormat: .mp3, filePath: path, sourceID: "source",
                                fileSize: 1_000, revision: "v1")
                song.artistName = "Tagged artist"
                existing.append(song)
                index[id] = SourceSyncIndexedItem(
                    stableKey: id, path: path, parentPath: parent, isDirectory: false,
                    songIDs: [id], size: 1_000, modifiedDate: nil, revision: "v1"
                )
                listings[parent, default: []].append(RemoteFileItem(
                    name: "Track-\(track).mp3", path: path, isDirectory: false,
                    size: 1_000, modifiedDate: nil, revision: "v1", providerID: id,
                    parentPath: parent
                ))
            }
        }
        let removedID = "song-0-0"
        listings["/Music/Album-0"]?.removeFirst()
        listings["/Music/Album-1", default: []].append(RemoteFileItem(
            name: "New.mp3", path: "/Music/Album-1/New.mp3", isDirectory: false,
            size: 2_000, modifiedDate: nil, revision: "v1", providerID: "new",
            parentPath: "/Music/Album-1"
        ))
        let connector = IncrementalReconciliationTestConnector(listings: listings)
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        let result = try await scanner.reconcileChangedDirectories(
            Set((0..<20).map { "/Music/Album-\($0)" }), deletedStableKeys: [removedID],
            existingSongs: existing, existingIndex: SourceSyncIndex(index), scanEpoch: 2,
            requiresCompleteListings: true
        )
        let byID = Dictionary(uniqueKeysWithValues: result.songs.map { ($0.id, $0) })
        XCTAssertEqual(byID.count, existing.count)
        XCTAssertNil(byID[removedID])
        for song in existing where song.id != removedID {
            let retained = try XCTUnwrap(byID[song.id])
            XCTAssertEqual(retained.title, song.title)
            XCTAssertEqual(retained.duration, song.duration)
            XCTAssertEqual(retained.artistName, song.artistName)
            XCTAssertEqual(retained.filePath, song.filePath)
        }
        XCTAssertNotNil(result.index["new"])
        XCTAssertNil(result.index[removedID])
        let listed = await connector.listCount
        let fileReads = await connector.fileReadCount
        XCTAssertEqual(listed, 20)
        XCTAssertEqual(fileReads, 0, "Unchanged audio must retain its tags without opening files")
    }

    func testSharedHTTPQuotaStopsAndResumesWithoutDiscardingUnvisitedSongs() async throws {
        let failures = [
            HTTPResponseFailure(statusCode: 429),
            HTTPResponseFailure(statusCode: 503, retryAfter: 3600),
            HTTPResponseFailure(statusCode: 403, retryAfter: 3600),
            HTTPResponseFailure(statusCode: 200, isRateLimited: true),
        ]
        for failure in failures {
            let connector = DirectoryCooldownConnector(failure: failure)
            let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
            let song = Song(id: "kept", title: "Kept", fileFormat: .flac,
                            filePath: "/Music/D/kept.flac", sourceID: connector.sourceID)
            var last: ConnectorScanner.ScanUpdate?
            do {
                for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song]) {
                    last = update
                }
                XCTFail("A quota must stop the scan")
            } catch let actual as HTTPResponseFailure { XCTAssertEqual(actual.statusCode, failure.statusCode) }
            let listed = await connector.listed
            XCTAssertEqual(listed, ["/Music", "/Music/A", "/Music/B"])
            let checkpoint = try XCTUnwrap(last?.resumeState)
            XCTAssertEqual(Set(checkpoint.pendingDirectories), ["/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.songs.map(\.id), [song.id], "Partial scans cannot delete unvisited songs")

            // A second attempt while still limited must stop at the same
            // directory, leaving all other queued work untouched.
            do {
                for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song], resumeState: checkpoint) {
                    last = update
                }
                XCTFail("Repeated cooldown must remain resumable")
            } catch is HTTPResponseFailure { }
            let repeated = await connector.listed
            XCTAssertEqual(Array(repeated.dropFirst(listed.count)), ["/Music/B"])

            await connector.allowListings()
            let beforeResume = await connector.listed.count
            for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song], resumeState: try XCTUnwrap(last?.resumeState)) {
                last = update
            }
            let resumed = await connector.listed
            XCTAssertEqual(Set(resumed.dropFirst(beforeResume)), ["/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.resumeState?.pendingDirectories, [])
        }
    }

    func testOrdinaryHTTPFailureDoesNotPauseUnrelatedDirectories() async throws {
        for status in [400, 403, 404, 500, 503] {
            let connector = DirectoryCooldownConnector(failure: HTTPResponseFailure(statusCode: status))
            let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
            var last: ConnectorScanner.ScanUpdate?
            do {
                for try await update in await scanner.scan(directories: ["/Music"]) { last = update }
                XCTFail("The failed directory must still be reported")
            } catch is HTTPResponseFailure { }
            let listed = await connector.listed
            XCTAssertEqual(listed, ["/Music", "/Music/A", "/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.resumeState?.pendingDirectories, ["/Music/B"])
        }
    }
}

private final class GoogleDriveRescanFixture: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var count = 100
    private var replaced = false
    private var unexpected = 0
    var unexpectedRequests: Int { lock.withLock { unexpected } }
    func addSongs() { lock.withLock { count = 103 } }
    func replaceFirstSong() { lock.withLock { replaced = true } }
    func response(to request: URLRequest) throws -> Data {
        try lock.withLock {
            guard request.url?.path == "/drive/v3/files" else {
                unexpected += 1
                throw URLError(.unsupportedURL)
            }
            let files: [[String: String]] = (0..<count).map { index in
                ["id": "track-id-\(index)", "name": "Track \(index).\(["mp3", "flac", "m4a"][index % 3])",
                 "mimeType": ["audio/mpeg", "audio/flac", "audio/mp4"][index % 3], "size": "4320000",
                 "modifiedTime": "2026-10-30T10:20:30.123Z",
                 "md5Checksum": "content-\(index)\(index == 0 && replaced ? "-replaced" : "")"]
            }
            return try JSONSerialization.data(withJSONObject: ["files": files])
        }
    }
}

private final class GoogleDriveRescanFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: GoogleDriveRescanFixture] = [:]
    func insert(_ fixture: GoogleDriveRescanFixture) { lock.withLock { values[fixture.id] = fixture } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func get(_ id: String) -> GoogleDriveRescanFixture? { lock.withLock { values[id] } }
}

private final class GoogleDriveRescanProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = GoogleDriveRescanFixtures()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID"),
                  let fixture = Self.fixtures.get(id), let url = request.url else {
                throw URLError(.unsupportedURL)
            }
            let data = try fixture.response(to: request)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor DirectoryCooldownConnector: MusicSourceConnector {
    nonisolated let sourceID = "directory-cooldown-" + UUID().uuidString
    private var failure: HTTPResponseFailure?
    private(set) var listed: [String] = []
    init(failure: HTTPResponseFailure) { self.failure = failure }
    func allowListings() { failure = nil }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listed.append(path)
        if path == "/Music/B", let failure { throw failure }
        guard path == "/Music" else { return [] }
        return ["A", "B", "C", "D"].map {
            RemoteFileItem(name: $0, path: "/Music/\($0)", isDirectory: true, size: 0, modifiedDate: nil)
        }
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

private actor IncrementalReconciliationTestConnector: MusicSourceConnector {
    nonisolated let sourceID = "source"
    let listings: [String: [RemoteFileItem]]
    private(set) var listCount = 0
    private(set) var fileReadCount = 0

    let readRange: (@Sendable (String, Int64, Int64) throws -> Data)?
    init(listings: [String: [RemoteFileItem]], readRange: (@Sendable (String, Int64, Int64) throws -> Data)? = nil) {
        self.listings = listings
        self.readRange = readRange
    }
    func fetchMetadataRange(path: String, offset: Int64, length: Int64, intent: MetadataRangeReadIntent) async throws -> Data {
        guard let readRange else { return try await fetchRange(path: path, offset: offset, length: length, priority: .background) }
        return try readRange(path, offset, length)
    }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listCount += 1
        return listings[path] ?? []
    }
    func localURL(for path: String) async throws -> URL {
        fileReadCount += 1
        throw SourceError.fileNotFound(path)
    }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        fileReadCount += 1
        return .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

private final class BaiduRepairFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}

@MainActor
final class CueTrackLocalRemovalTests: XCTestCase {
    func testRemovingAndRestoringTracksSurvivesLocalRescanAndRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let audioURL = music.appendingPathComponent("disc.wav")
        try writeSilentAudio(to: audioURL)
        let originalAudio = try Data(contentsOf: audioURL)
        let cueURL = music.appendingPathComponent("disc.cue")
        let cue = Data("""
        FILE "disc.wav" WAVE
          TRACK 01 AUDIO
            TITLE "First Light"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Evening Walk"
            INDEX 01 00:01:00
        """.utf8)
        try cue.write(to: cueURL)

        let source = MusicSource(
            id: UUID().uuidString, name: "Tracks", type: .local, basePath: music.path, authType: .none,
            extraConfig: MusicSource.encodeScannedDirectories(["/"], into: nil, type: .local)
        )
        let connector = LocalFileSource(sourceID: source.id, basePath: music)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let sources = SourcesStore(storageDirectoryURL: root.appendingPathComponent("Sources"))
        sources.add(source)
        let scan = ScanService(fileManager: BaiduRepairFileManager(root: root),
                               connectorProvider: { _ in connector }, diagnosticProvider: { source, _ in
            SourceDiagnosticReport(source: source, startedAt: Date(), checks: [])
        })
        func rescan(_ library: MusicLibrary) async {
            XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: sources,
                                          requestsContinuedProcessing: false))
            await scan.waitForActiveScansToComplete()
            await library.waitForPendingIndex()
            XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        }
        let directory = root.appendingPathComponent("Library")
        let library = MusicLibrary(storageDirectory: directory)
        await rescan(library)
        let first = try XCTUnwrap(library.songs.first { $0.trackNumber == 1 })
        let second = try XCTUnwrap(library.songs.first { $0.trackNumber == 2 })
        XCTAssertEqual(first.filePath, second.filePath)
        XCTAssertNotEqual(first.id, second.id)

        try library.removeSongsFromThisDevice([second])
        // Force the directory scan to commit while one CUE track is still visible.
        try originalAudio.write(to: music.appendingPathComponent("bonus.wav"))
        await rescan(library)
        XCTAssertEqual(library.songs.filter(\.isCueTrack).map(\.id), [first.id])
        XCTAssertEqual(library.locallyRemovedSongIDs(forSourceID: source.id), [second.id])
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The library did not persist")
        }

        let reopened = MusicLibrary(storageDirectory: directory)
        XCTAssertEqual(reopened.songs.filter(\.isCueTrack).map(\.id), [first.id])
        try reopened.restoreSongsRemovedFromThisDevice([second.id])
        XCTAssertEqual(Set(reopened.songs.filter(\.isCueTrack).map(\.id)), [first.id, second.id])

        try reopened.removeSongsFromThisDevice([first, second])
        await rescan(reopened)
        XCTAssertTrue(reopened.songs.filter(\.isCueTrack).isEmpty)
        XCTAssertEqual(reopened.locallyRemovedSongIDs(forSourceID: source.id), [first.id, second.id])
        try reopened.restoreSongsRemovedFromThisDevice([first.id])
        XCTAssertEqual(reopened.songs.filter(\.isCueTrack).map(\.id), [first.id])
        XCTAssertTrue(reopened.isExcludedOnThisDevice(second))
        XCTAssertTrue(reopened.deletedSongIdentities.isEmpty)
        XCTAssertEqual(try Data(contentsOf: audioURL), originalAudio)
        XCTAssertEqual(try Data(contentsOf: cueURL), cue)
    }

    func testLegacyFileExclusionRestoresOnlyTheRecordedCueTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func track(_ number: Int) -> Song {
            Song(id: "track-\(number)", title: "Track \(number)", trackNumber: number, duration: 30,
                 fileFormat: .flac, filePath: "/disc.flac", sourceID: "nas",
                 cueSheetPath: "/disc.cue", cueStartTime: Double(number - 1) * 30)
        }
        let first = track(1), second = track(2)
        let store = try IncrementalSongStore(path: root.appendingPathComponent("library-songs.sqlite").path)
        try store.replaceAll(with: [first, second])
        try store.markMigrationCompleted(version: 10)
        let entry = SongLocalRemovalEntry(song: second, reason: .userKeptRemoteFile)
        let oldLedger = SongLocalRemovalLedger(
            formatVersion: 3, identities: ["nas:/disc.flac", "account:/disc.flac"],
            retainedSongs: [second], entries: [entry]
        )
        try JSONEncoder().encode(oldLedger).write(to: root.appendingPathComponent("library-device-local-excluded-songs.json"))

        let preparing = MusicLibrary.makePreparing(storageDirectory: root)
        preparing.sourceIdentityResolver = { _ in "account" }
        let preview = await preparing.prepareStartupSongs(ids: [first.id, second.id], sourceIDs: ["nas"])
        XCTAssertEqual(preview?.map(\.id), [first.id])
        let prepared = await MusicLibrary.prepareStartup(storageDirectory: root, sourceIdentityPrefixes: ["nas": "account"])
        preparing.publish(prepared)
        XCTAssertEqual(preparing.songs.map(\.id), [first.id])
        XCTAssertEqual(preparing.locallyRemovedEntries().map(\.id), [second.id])
        try preparing.restoreSongsRemovedFromThisDevice([second.id])
        preparing.addSongs([first, second])
        XCTAssertEqual(Set(preparing.songs.map(\.id)), [first.id, second.id])
        XCTAssertTrue(preparing.locallyRemovedEntries().isEmpty)
    }

    func testBatchSourceDeletionRemovesSharedTracksOnlyForFilesActuallyDeleted() async throws {
        let suite = "CueDeletion-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let nas = MusicSource(id: UUID().uuidString, name: "NAS", type: .webdav)
        let backup = MusicSource(id: UUID().uuidString, name: "Backup", type: .webdav)
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("Sources"))
        store.add(nas)
        store.add(backup)
        let nasFiles = CueDeletionConnector(sourceID: nas.id, files: ["/one.flac", "/two.flac", "/three.flac", "/disc.cue"],
                                            deniedPaths: ["/two.flac"])
        let backupFiles = CueDeletionConnector(sourceID: backup.id, files: ["/one.flac", "/disc.cue"])
        let manager = SourceManager(sourcesProvider: { [nas, backup] }, connectorFactory: { source in
            source.id == nas.id ? nasFiles : backupFiles
        })
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("Library"))
        func track(_ number: Int, in path: String, sourceID: String) -> Song {
            Song(id: "\(sourceID)-\(number)", title: "Track \(number)", trackNumber: number, duration: 30,
                 fileFormat: .flac, filePath: path, sourceID: sourceID,
                 cueSheetPath: "/disc.cue", cueStartTime: Double(number - 1) * 30)
        }
        let selected = track(1, in: "/one.flac", sourceID: nas.id)
        let alsoSelected = track(2, in: "/one.flac", sourceID: nas.id)
        let visibleSibling = track(3, in: "/one.flac", sourceID: nas.id)
        let hiddenSibling = track(4, in: "/one.flac", sourceID: nas.id)
        let denied = track(5, in: "/two.flac", sourceID: nas.id)
        let deniedSibling = track(6, in: "/two.flac", sourceID: nas.id)
        let hiddenDeniedSibling = track(7, in: "/two.flac", sourceID: nas.id)
        let unselectedFile = track(8, in: "/three.flac", sourceID: nas.id)
        let backupCopy = track(1, in: "/one.flac", sourceID: backup.id)
        library.addSongs([selected, alsoSelected, visibleSibling, hiddenSibling, denied, deniedSibling,
                          hiddenDeniedSibling, unselectedFile, backupCopy])
        try library.removeSongsFromThisDevice([hiddenSibling, hiddenDeniedSibling])

        let settings = PlaybackSettingsStore(defaults: defaults,
            cloudSync: CloudKVSSync(store: nil, defaults: defaults, observing: nil))
        let player = AudioPlayerService(
            sourceManager: manager, library: library, playbackSettings: settings,
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("session.json")),
            musicSessionMemoryStore: MusicSessionMemoryStore(defaults: defaults, url: root.appendingPathComponent("music.json")),
            activateAudioSession: { _ in XCTFail("An empty queue must stay silent") }
        )
        let service = SongBatchRemovalService(library: library, sourceManager: manager, sourcesStore: store, player: player)
        let task = try XCTUnwrap(service.remove([selected, alsoSelected, denied], mode: .sourceFiles))
        await task.value

        let outcome = try XCTUnwrap(service.lastOutcome)
        XCTAssertEqual(outcome.removed, 4)
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.locallyRemovableSongs.map(\.id), [denied.id])
        XCTAssertEqual(Set(library.songs.map(\.id)), [denied.id, deniedSibling.id, unselectedFile.id, backupCopy.id])
        XCTAssertEqual(library.locallyRemovedSongIDs(forSourceID: nas.id), [hiddenDeniedSibling.id])
        XCTAssertFalse(library.isExcludedOnThisDevice(hiddenSibling))
        XCTAssertFalse(library.isExcludedOnThisDevice(denied))
        let nasAttempts = await nasFiles.deletionAttempts
        XCTAssertEqual(nasAttempts.filter { $0.hasSuffix(".flac") }.sorted(), ["/one.flac", "/two.flac"])
        let remainingFiles = await nasFiles.files
        XCTAssertEqual(remainingFiles, ["/two.flac", "/three.flac", "/disc.cue"])
        let backupAttempts = await backupFiles.deletionAttempts
        XCTAssertTrue(backupAttempts.isEmpty)
    }

    private func writeSilentAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.update(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private actor CueDeletionConnector: MusicSourceConnector {
    let sourceID: String
    private(set) var files: Set<String>
    private let deniedPaths: Set<String>
    private(set) var deletionAttempts: [String] = []

    init(sourceID: String, files: Set<String>, deniedPaths: Set<String> = []) {
        self.sourceID = sourceID
        self.files = files
        self.deniedPaths = deniedPaths
    }

    func deleteFile(at path: String) async throws {
        deletionAttempts.append(path)
        if deniedPaths.contains(path) { throw SourceFileMutationError.permissionDenied }
        guard files.remove(path) != nil else { throw SourceError.fileNotFound(path) }
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

private actor MutableFileTreeConnector: MusicSourceConnector {
    let sourceID: String
    var phase = 0
    init(sourceID: String) { self.sourceID = sourceID }
    func setPhase(_ phase: Int) { self.phase = phase }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        var names = ["keep.mp3"]
        if phase < 2 { names.append("remove.mp3") }
        if phase > 0 { names.append("new.mp3") }
        return names.map { name in
            let replaced = phase > 0 && name == "keep.mp3"
            return RemoteFileItem(name: name, path: "/Music/" + name, isDirectory: false,
                size: replaced ? 200 : 100, modifiedDate: nil, revision: replaced ? "v2" : "v1", providerID: name)
        }
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

private actor ScopedBaiduRepairConnector: ResumableSnapshotMusicSourceConnector {
    let sourceID: String
    private(set) var listedPaths: [String] = []
    init(sourceID: String) { self.sourceID = sourceID }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listedPaths.append(path)
        guard path == "/Music/A" else { throw SourceError.pathNotFound(path) }
        return [RemoteFileItem(name: "keep.mp3", path: "/Music/A/keep.mp3", isDirectory: false, size: 100, modifiedDate: nil, providerID: "kept-file")]
    }
    func initialSnapshotMarker(for roots: [String]) async throws -> [String: String] { [:] }
    func snapshotChanges(from state: SourceSyncState, roots: [String], rootIdentities: [SourceSyncRootIdentity],
        resumeState: BaiduSnapshotResumeState?, budget: BaiduSnapshotRefreshBudget,
        progress: @escaping @Sendable (BaiduSnapshotResumeState, SourceSyncTelemetry) async -> Void) async throws -> IncrementalSourceChanges {
        XCTFail("Folder repair must not traverse a whole-source snapshot")
        throw SourceError.fileNotFound("unexpected snapshot")
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

@MainActor
final class BackfillStatusReuseTests: XCTestCase {
    func testLargeLibraryReusesCountsAndInvalidatesAfterSongOrSourceChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let songs = (0..<32_032).map { Song(id: "count-\($0)", title: "Track", fileFormat: .m4a,
            filePath: "/Music/Album\($0 / 50)/\($0).m4a", sourceID: "count-source") }
        library.addSongs(songs)
        var sources: Set<String> = ["count-source"]
        let backfill = MetadataBackfillService(library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { sources }, bareOnlySourceIDs: { sources }, storageDirectory: root.appendingPathComponent("state"))
        defer { backfill.stop() }
        let firstStart = Date()
        await backfill.refreshStatusSnapshotOffMain()
        let firstTime = Date().timeIntervalSince(firstStart)
        XCTAssertEqual(backfill.remainingCount(forSource: "count-source"), songs.count)
        let computations = backfill.remainingCountsComputationCount
        let reuseStart = Date()
        async let first: Void = backfill.refreshStatusSnapshotOffMain()
        async let second: Void = backfill.refreshStatusSnapshotOffMain()
        _ = await (first, second)
        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCountsComputationCount, computations)
        print("BACKFILL_STATUS_32032 first=\(firstTime)s reuse3=\(Date().timeIntervalSince(reuseStart))s")
        var changed = songs[0]
        changed.title = "Updated title"
        library.replaceSongs([changed])
        async let changedFirst: Void = backfill.refreshStatusSnapshotOffMain()
        async let changedSecond: Void = backfill.refreshStatusSnapshotOffMain()
        _ = await (changedFirst, changedSecond)
        XCTAssertEqual(backfill.remainingCountsComputationCount, computations + 1)
        XCTAssertEqual(backfill.statusDisplayItems(forSource: "count-source").first { $0.songID == changed.id }?.title, "Updated title")
        sources = []
        await backfill.refreshStatusSnapshotOffMain()
        XCTAssertEqual(backfill.remainingCount(forSource: "count-source"), 0)
        XCTAssertTrue(backfill.statusDisplayItems(forSource: "count-source").isEmpty)
        sources = ["count-source"]
        await backfill.refreshStatusSnapshotOffMain()
        XCTAssertEqual(backfill.remainingCount(forSource: "count-source"), songs.count)
    }
}

private final class ArtworkLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func load(_ data: Data?) -> Data? { lock.withLock { value += 1 }; return data }
}

final class ArtworkTintCacheTests: XCTestCase {
    private func artwork() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testLargeArtworkDecodesOnlyThumbnailAndIdenticalRequestsShareWork() async throws {
        let data = try artwork()
        let image = try XCTUnwrap(ArtworkTintCache.thumbnail(data: data)?.platformCGImage)
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 40)
        let cache = ArtworkTintCache(capacity: 2)
        let counter = ArtworkLoadCounter()
        async let first = cache.palette(identity: "same-content") { counter.load(data) }
        async let second = cache.palette(identity: "same-content") { counter.load(data) }
        let results = await (first, second)
        XCTAssertTrue(results.0.analyzedImage)
        XCTAssertTrue(results.1.analyzedImage)
        XCTAssertNotNil(results.0.palette)
        XCTAssertEqual(counter.count, 1)
        _ = await cache.palette(identity: "replacement") { counter.load(data) }
        XCTAssertEqual(counter.count, 2)
        _ = await cache.palette(identity: "third") { counter.load(data) }
        _ = await cache.palette(identity: "same-content") { counter.load(data) }
        XCTAssertEqual(counter.count, 4, "Eviction must bound retained palettes")
    }

    func testUnreadableArtworkCanRecoverWithoutChangingItsReference() async throws {
        let cache = ArtworkTintCache()
        let counter = ArtworkLoadCounter()
        let missing = await cache.palette(identity: "recover") { counter.load(nil) }
        XCTAssertFalse(missing.analyzedImage)
        let data = try artwork()
        let recovered = await cache.palette(identity: "recover") { counter.load(data) }
        XCTAssertTrue(recovered.analyzedImage)
        XCTAssertEqual(counter.count, 2)
    }
}
