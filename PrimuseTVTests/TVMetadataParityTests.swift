#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
import UIKit
@testable import PrimuseTV

@MainActor
final class TVMetadataParityTests: XCTestCase {
    func testDirectoryInventoryDefersEveryMetadataReadAcrossSourceFamilies() async throws {
        for type in [MusicSourceType.local, .smb, .nfs, .ftp, .webdav, .oneDrive, .dropbox, .pcloud] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: url) }
            let probe = MetadataQueueProbe()
            let scanner = TVSourceScanner(metadataInspections: TVMetadataInspectionStore(url: url),
                readMetadata: { song, _, _ in await probe.read(song) })
            let source = MusicSource(id: UUID().uuidString, name: "Inventory", type: type)
            var delivered: [Song] = []
            let result = await scanner.scan(source: source,
                lister: ListedFiles(entries: [.init(name: "Track.mp3", isDir: false, size: 4096, path: "/Track.mp3")]),
                dirs: ["/"], credential: nil, existingSongs: [], defersMetadata: true,
                onSkeletonBatch: { delivered += $0 }, onMetadataBatch: { _ in XCTFail("metadata during inventory") })
            let reads = await probe.started
            XCTAssertTrue(result.canCommit, "\(type)")
            XCTAssertTrue(result.canPrune, "\(type)")
            XCTAssertFalse(result.metadataCompleted)
            XCTAssertEqual(delivered.count, 1)
            XCTAssertTrue(reads.isEmpty)
        }
    }

    func testDeferredInspectionReopensOnlyWhenInventorySidecarsChange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inspections = TVMetadataInspectionStore(url: url)
        let original = song()
        func sidecars(_ size: Int64) -> SidecarDirectoryIndex<TVDirEntry> {
            .init([.init(name: "Track.lrc", isDir: false, size: size, path: "/Music/Track.lrc")])
        }
        func index(_ size: Int64) -> [String: SourceSyncIndexedItem] {
            ["audio": .init(stableKey: "audio", path: original.filePath, parentPath: "/Music", isDirectory: false,
                songIDs: [original.id], size: original.fileSize, modifiedDate: nil, revision: nil,
                sidecarFingerprint: sidecars(size).snapshotFingerprint(selectedPaths: [nil, "/Music/Track.lrc", nil], includingCueTrackLyrics: false))]
        }
        await inspections.observeCommittedIndex(sourceID: original.sourceID, index: index(100))
        await inspections.record(original, complete: true)
        await inspections.observeCommittedIndex(sourceID: original.sourceID, index: index(100))
        let unchanged = await inspections.isCurrent(original)
        XCTAssertTrue(unchanged)
        await inspections.observeCommittedIndex(sourceID: original.sourceID, index: index(200))
        let changed = await inspections.isCurrent(original)
        XCTAssertFalse(changed)
        await inspections.record(original, complete: true)
        await inspections.flush()
        let restored = TVMetadataInspectionStore(url: url)
        let current = await restored.isCurrent(original, sidecars: sidecars(200))
        XCTAssertTrue(current)
    }

    func testDeferredMetadataUsesCommittedRowsAndInspectionCheckpoint() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = MetadataQueueProbe()
        await probe.releaseAll()
        let scanner = TVSourceScanner(metadataInspections: TVMetadataInspectionStore(url: url),
            readMetadata: { song, _, _ in await probe.read(song) })
        let source = MusicSource(id: "source", name: "Files", type: .webdav)
        let bare = Song(id: "song", title: "Track", fileFormat: .mp3, filePath: "/Track.mp3", sourceID: source.id)
        var committed: [Song] = []
        try await scanner.enrichDeferredMetadata(songs: [bare], source: source, credential: nil) { committed += $0 }
        XCTAssertEqual(committed.count, 1)
        let readsBefore = await probe.started.count
        try await scanner.enrichDeferredMetadata(songs: committed, source: source, credential: nil) { _ in XCTFail("already inspected") }
        let readsAfter = await probe.started.count
        XCTAssertEqual(readsBefore, readsAfter)
    }

    func testSongArtworkUsesSelectedAssetInsteadOfSongMirror() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let selected = try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.jpegData(compressionQuality: 1))
        let stored = await assets.storeAttributedCover(selected, songID: "song", origin: .selected)
        let reference = try XCTUnwrap(stored)
        let mirror = try XCTUnwrap(renderer.image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.jpegData(compressionQuality: 1))
        await assets.cacheCover(mirror, forSongID: "song")
        await assets.clearAll()
        let loaded = await TVArtworkLoader(assets: assets).songCover(songID: "song", coverRef: reference)
        XCTAssertEqual(loaded, selected)
    }

    func testLargeTVArtworkUsesFullSourceVariant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let source = MusicSource(id: "server", name: "Fixture", type: .navidrome, host: "artwork.invalid")
        let reference = "subsonic-cover/album"
        for size in [480, 1536] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }.pngData())
            await assets.cacheSourceCover(data, songID: "song", sourceID: source.id, reference: reference, maximumPixels: size)
        }
        let result = await TVArtworkLoader(assets: assets).songCover(songID: "song", coverRef: reference, source: source, maximumPixels: 1536)
        let data = try XCTUnwrap(result)
        XCTAssertEqual(UIImage(data: data)?.cgImage?.width, 1536)
    }

    func testServerRescanUpdatesCoverAfterTitleEditAndPreservesSelection() {
        var old = Song(id: "song", title: "My title", fileFormat: .mp3, filePath: "/song.mp3", sourceID: "server", coverArtFileName: "subsonic-cover/old")
        old.userMetadataEditedAt = Date()
        var fresh = old; fresh.title = "Server title"; fresh.coverArtFileName = "subsonic-cover/new"
        let refreshed = TVSourceScanner.rereadServerSong(existing: old, incoming: fresh)
        XCTAssertEqual(refreshed.title, "My title")
        XCTAssertEqual(refreshed.coverArtFileName, fresh.coverArtFileName)
        old.coverArtFileName = "selected-" + String(repeating: "a", count: 64) + ".jpg"
        XCTAssertEqual(TVSourceScanner.rereadServerSong(existing: old, incoming: fresh).coverArtFileName, old.coverArtFileName)
    }

    func testSynologySidecarArtworkUsesTrustedSourceAndBoundsDownload() async throws {
        let registry = StreamResolverRegistry(endpointProbe: { _ in })
        await registry.register(SynologyArtworkResolver(), for: [.synology])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SynologyArtworkURLProtocol.self]
        let reader = TVSourceAssetReader(registry: registry, session: URLSession(configuration: configuration))
        var source = MusicSource(id: "book-nas", name: "Books", type: .synology, host: "nas.example")
        source.deviceId = "fixture-trust"
        let credential = SourceCredential(username: "reader", password: "fixture-password")
        let data = await reader.artworkData(reference: "/books/cover.jpg", source: source, credential: credential, maximumBytes: 32)
        XCTAssertEqual(data, Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let oversized = await reader.artworkData(reference: "/books/cover.jpg", source: source, credential: credential, maximumBytes: 2)
        XCTAssertNil(oversized)
        source.deviceId = nil
        let unauthorized = await reader.artworkData(reference: "/books/cover.jpg", source: source, credential: credential, maximumBytes: 32)
        XCTAssertNil(unauthorized)
        let foreignURL = await reader.artworkData(reference: "https://foreign.example/cover.jpg", source: source, credential: credential, maximumBytes: 32)
        XCTAssertNil(foreignURL)
    }

    func testDeviceResizeAndThermalRecoveryDoNotWaitForSlowSibling() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = MetadataQueueProbe()
        var environment = MetadataReadingEnvironment(device: .init(
            platform: .television, activeProcessorCount: 6, physicalMemory: 2 * 1_024 * 1_024 * 1_024
        ))
        let scanner = TVSourceScanner(
            metadataInspections: TVMetadataInspectionStore(url: url),
            readingEnvironment: { _ in environment }, readingMode: { .fast },
            readMetadata: { song, _, _ in await probe.read(song) }
        )
        let entries = (0..<10).map { index in
            TVDirEntry(name: "\(index).mp3", isDir: false, size: 4096, path: "/\(index).mp3")
        }
        let source = MusicSource(id: UUID().uuidString, name: "Queue fixture", type: .smb)
        let task = Task {
            await scanner.scan(source: source, lister: ListedFiles(entries: entries), dirs: ["/"],
                               credential: nil, existingSongs: [], onSkeletonBatch: { _ in }, onMetadataBatch: { _ in })
        }
        defer { task.cancel() }
        try await waitForMetadataReads(2, probe: probe)
        let initial = await probe.started
        await probe.release(initial[1])
        try await waitForMetadataReads(3, probe: probe)
        let started = await probe.started
        // The first read remains blocked while a freed slot accepts new work.
        environment.thermalState = .critical
        scanner.readingConfigurationChanged()
        await probe.release(started[2])
        try await Task.sleep(for: .milliseconds(50))
        let pausedCount = await probe.started.count
        XCTAssertEqual(pausedCount, 3)
        environment.thermalState = .nominal
        environment.device = .init(platform: .television, activeProcessorCount: 6,
                                   physicalMemory: 4 * 1_024 * 1_024 * 1_024)
        scanner.readingConfigurationChanged()
        try await waitForMetadataReads(6, probe: probe)
        await probe.releaseAll()
        let result = await task.value
        let allReads = await probe.started
        XCTAssertEqual(allReads.count, 10)
        XCTAssertEqual(Set(allReads).count, 10)
        XCTAssertTrue(result.metadataCompleted)
        XCTAssertEqual(result.songs.count, 10)
    }

    func testMetadataDeliveryFailureExitsEvenDuringThermalPause() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var thermal = MetadataReadingThermalState.nominal
        let scanner = TVSourceScanner(
            metadataInspections: TVMetadataInspectionStore(url: url),
            readingEnvironment: { _ in .init(thermalState: thermal) }, readingMode: { .energySaving },
            readMetadata: { song, _, _ in
                TVMetadataEnrichmentResult(song: song, status: .enriched, errorDescription: nil, inspectionComplete: true)
            }
        )
        let entries = (0..<25).map {
            TVDirEntry(name: "\($0).mp3", isDir: false, size: 4096, path: "/\($0).mp3")
        }
        let result = await scanner.scan(
            source: MusicSource(id: UUID().uuidString, name: "Queue fixture", type: .smb),
            lister: ListedFiles(entries: entries), dirs: ["/"], credential: nil, existingSongs: [],
            onSkeletonBatch: { _ in }, onMetadataBatch: { _ in
                thermal = .critical
                throw CocoaError(.fileWriteOutOfSpace)
            }
        )
        if case .metadataDeliveryFailed = result.completion {} else {
            XCTFail("Publication errors must leave the queue through the existing failure path")
        }
        XCTAssertFalse(result.metadataCompleted)
        XCTAssertFalse(result.enumerationCompleted, "A failed scan must not authorize pruning")
        XCTAssertEqual(result.songs.count, 25)
    }

    private func waitForMetadataReads(_ count: Int, probe: MetadataQueueProbe) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await probe.started.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let actual = await probe.started.count
        XCTAssertEqual(actual, count)
        guard actual == count else { throw URLError(.timedOut) }
    }

    private actor MetadataQueueProbe {
        var started: [String] = []
        private var gates: [String: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<String> = []
        private var allReleased = false

        func read(_ song: Song) async -> TVMetadataEnrichmentResult {
            started.append(song.id)
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if allReleased || released.contains(song.id) || Task.isCancelled {
                        continuation.resume()
                    } else { gates[song.id] = continuation }
                }
            } onCancel: {
                Task { await self.release(song.id) }
            }
            return TVMetadataEnrichmentResult(song: song, status: Task.isCancelled ? .cancelled : .enriched,
                                              errorDescription: nil, inspectionComplete: true)
        }

        func release(_ id: String) {
            released.insert(id)
            gates.removeValue(forKey: id)?.resume()
        }

        func releaseAll() {
            allReleased = true
            let active = Array(gates.values)
            gates.removeAll()
            active.forEach { $0.resume() }
        }
    }

    private func song() -> Song {
        Song(id: UUID().uuidString, title: "Track", albumTitle: "Album", artistName: "Folder",
             albumArtistName: "Folder", duration: 120, fileFormat: .mp3,
             filePath: "/Music/Track.mp3", sourceID: "source", fileSize: 4096,
             lastModified: Date(timeIntervalSince1970: 100))
    }

    func testEmbeddedArtistReplacesDirectoryAlbumArtistFallback() {
        var metadata = FileMetadataReader.Metadata()
        metadata.artist = "Tagged Artist"
        let updated = TVMetadataEnricher.applying(metadata, to: song(), duration: 180)
        XCTAssertEqual(updated.artistName, "Tagged Artist")
        XCTAssertEqual(updated.albumArtistName, "Tagged Artist")
        metadata.albumArtist = "Compilation Artist"
        XCTAssertEqual(TVMetadataEnricher.applying(metadata, to: song(), duration: 180).albumArtistName,
                       "Compilation Artist")
    }

    /// #338 电视端:电视自己读标签建的行,合唱那首也并进主唱那张。
    func testDuetReadOnTVJoinsTheSoloAlbum() {
        let rows = ["李荣浩", "李荣浩", "李荣浩 & 张惠妹"].enumerated().map { index, singer in
            var metadata = FileMetadataReader.Metadata()
            metadata.artist = singer
            metadata.albumTitle = "纵横四海"
            metadata.trackNumber = index + 1
            var base = song()
            base.id = "track-\(index)"
            return TVMetadataEnricher.applying(metadata, to: base, duration: 180)
        }
        XCTAssertEqual(rows.last?.albumArtistName, "李荣浩 & 张惠妹")
        let result = MusicLibrary.computeAlbumsAndArtists(songs: rows)
        XCTAssertEqual(result.albums.count, 1)
        XCTAssertEqual(result.albums.first?.artistName, "李荣浩")
        XCTAssertEqual(result.albums.first?.songCount, 3)
    }

    func testMissingEmbeddedTitleKeepsExistingLibraryTitle() {
        var existing = song()
        existing.title = "Correct library title"
        let metadata = FileMetadataReader.Metadata()

        let updated = TVMetadataEnricher.applying(metadata, to: existing, duration: 120)

        XCTAssertEqual(updated.title, "Correct library title")
    }

    func testMetadataRefreshPreservesUserIdentityAndUpdatesTechnicalFields() {
        var original = song()
        original.userMetadataEditedAt = Date()
        var metadata = FileMetadataReader.Metadata()
        metadata.title = "Embedded title"
        metadata.artist = "Embedded artist"
        metadata.albumArtist = "Embedded album artist"
        metadata.sampleRate = 96000
        let updated = TVMetadataEnricher.applying(metadata, to: original, duration: 180)
        XCTAssertEqual(updated.title, original.title)
        XCTAssertEqual(updated.artistName, original.artistName)
        XCTAssertEqual(updated.albumArtistName, original.albumArtistName)
        XCTAssertEqual(updated.sampleRate, 96000)
        XCTAssertEqual(updated.duration, 180)
    }

    func testCueLastTrackDurationUsesRemainingAudioLength() {
        var last = song()
        last.cueSheetPath = "/Music/Album.cue"
        last.cueStartTime = 2336.786
        last.cueEndTime = nil
        last.duration = 0
        let metadata = FileMetadataReader.Metadata()
        let updated = TVMetadataEnricher.applying(metadata, to: last, duration: 2500.587)
        XCTAssertEqual(updated.duration, 163.801, accuracy: 0.001)

        var earlier = last
        earlier.cueStartTime = 100
        earlier.cueEndTime = 240
        earlier.duration = 140
        XCTAssertEqual(TVMetadataEnricher.applying(metadata, to: earlier, duration: 2500.587).duration, 140)
    }

    func testEmbeddedAuthoredTranslationsReachTVPlayback() throws {
        var metadata = FileMetadataReader.Metadata()
        metadata.lyricsText = "[00:01.00]First line\n[00:03.00]Second line"
        metadata.lyricsLanguageCode = "en"
        metadata.translatedLyricsText = "[00:01.00]第一行\n[00:03.00]第二行"
        metadata.translatedLyricsLanguageCode = "zh-Hans"
        let parsed = try XCTUnwrap(FileMetadataReader.parsedEmbeddedLyrics(from: metadata))
        XCTAssertEqual(parsed.map { $0.manualTranslation?.languageCode }, ["zh-Hans", "zh-Hans"])
        XCTAssertTrue(parsed.first?.metadataLines?.contains("[la:en]") == true)
        let displayed = TVPlaybackCoordinator.toTVLyrics(parsed, duration: 120)
        XCTAssertEqual(displayed.map(\.translation), ["第一行", "第二行"])
        XCTAssertEqual(displayed.map(\.time), [1, 3])
    }

    func testOnlyConfirmedEndpointFailuresAllowRouteFallback() async throws {
        let endpoint = SourceConnectionEndpoint(host: "lan.invalid", port: 4533, useSsl: false)
        let errors: [any Error] = [StreamResolveError.badServerResponse(503),
                                  URLError(.serverCertificateUntrusted), URLError(.cancelled),
                                  SongloftServiceError.authenticationFailed,
                                  TVRoutedByteRangeReaderError.contentLengthMismatch]
        for error in errors {
            let allowed = await TVSourceConnectionFailoverPolicy.confirmsUnreachableEndpoint(
                after: error, endpoint: endpoint, probe: { _ in
                    XCTFail("Business errors must not trigger a reachability probe")
                    throw URLError(.cannotConnectToHost)
                }
            )
            XCTAssertFalse(allowed)
        }
        let retained = await TVSourceConnectionFailoverPolicy.confirmsUnreachableEndpoint(
            after: URLError(.timedOut), endpoint: endpoint, probe: { _ in }
        )
        XCTAssertFalse(retained)
        let fallback = await TVSourceConnectionFailoverPolicy.confirmsUnreachableEndpoint(
            after: URLError(.timedOut), endpoint: endpoint, probe: { _ in throw URLError(.cannotConnectToHost) }
        )
        XCTAssertTrue(fallback)
    }

    func testByteReaderRequestTimeoutKeepsReachableRoute() async throws {
        for reachable in [true, false] {
            let sourceID = UUID().uuidString
            await SourceConnectionRuntime.shared.observeNetworkPath(prefersLocalNetwork: true, pathChanged: false)
            let local = RouteHealthByteReader(failReads: true)
            let remote = RouteHealthByteReader(failReads: false)
            let reader = TVRoutedByteRangeReader(sourceID: sourceID, candidates: [
                .init(kind: .localAddress, endpoint: .init(host: "lan.invalid", port: 445, useSsl: false), reader: local),
                .init(kind: .publicAddress, endpoint: .init(host: "wan.invalid", port: 445, useSsl: false), reader: remote)
            ], endpointProbe: { _ in
                if !reachable { throw URLError(.cannotConnectToHost) }
            })
            _ = try await reader.contentLength()
            do {
                let data = try await reader.read(offset: 0, length: 1)
                XCTAssertFalse(reachable)
                XCTAssertEqual(data, Data([1]))
            } catch {
                XCTAssertTrue(reachable)
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
            let active = await SourceConnectionRuntime.shared.activeKind(for: sourceID)
            let remoteReads = await remote.reads
            XCTAssertEqual(active, reachable ? .localAddress : .publicAddress)
            XCTAssertEqual(remoteReads, reachable ? 0 : 1)
            await reader.close()
            await SourceConnectionRuntime.shared.invalidate(sourceID: sourceID)
        }
    }

    func testSourceRoutesDoNotReadTranscodedServerFilesAsTags() {
        for type in [MusicSourceType.local, .smb, .nfs, .ftp, .webdav, .oneDrive, .dropbox, .pcloud] {
            XCTAssertTrue(TVPlaybackMetadataPolicy.supports(type), type.rawValue)
        }
        for type in [MusicSourceType.subsonic, .navidrome, .jellyfin, .emby, .plex, .fnMusic, .daoliyu, .songloft,
                     .audiobookshelf, .synologyAudioStation, .tingReader] {
            XCTAssertFalse(TVPlaybackMetadataPolicy.supports(type), type.rawValue)
        }
        XCTAssertTrue(TVSourceAssetReader.supports(.audiobookshelf))
        XCTAssertTrue(TVSourceAssetReader.supports(.tingReader))
        XCTAssertEqual(TVLyricsLoadingPolicy.strategy(for: .daoliyu), .daoLiYuService)
        XCTAssertEqual(TVLyricsLoadingPolicy.strategy(for: .songloft), .songloftService)
        XCTAssertTrue(TVSourceAssetReader.supports(.songloft))
        XCTAssertEqual(
            TVLyricsLoadingPolicy.strategy(for: .synologyAudioStation),
            .synologyAudioStationService
        )
        XCTAssertTrue(TVSourceAssetReader.supports(.synologyAudioStation))
        XCTAssertFalse(TVSourceConnectionFailoverPolicy.allowsRetry(after: SongloftServiceError.authenticationFailed))
        for type in [MusicSourceType.jellyfin, .emby, .plex] {
            XCTAssertEqual(TVLyricsLoadingPolicy.strategy(for: type), .mediaServer)
        }
    }

    func testCompletedAbsencePersistsButFailedOrChangedMetadataMustRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inspections = TVMetadataInspectionStore(url: url)
        let original = song()
        await inspections.record(original, complete: false)
        let failed = await inspections.isCurrent(original)
        XCTAssertFalse(failed)
        await inspections.record(original, complete: true)
        await inspections.flush()
        let reloaded = TVMetadataInspectionStore(url: url)
        let completed = await reloaded.isCurrent(original)
        XCTAssertTrue(completed, "Missing optional artwork or lyrics is a valid inspected result")
        var changed = original
        changed.lastModified = Date(timeIntervalSince1970: 200)
        let changedBytes = await reloaded.isCurrent(changed)
        XCTAssertFalse(changedBytes)
        changed = original
        changed.artistName = "Snapshot replacement"
        let replaced = await reloaded.isCurrent(changed)
        XCTAssertFalse(replaced)
    }

    func testExplicitFlushOnlyWritesNewInspections() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inspections = TVMetadataInspectionStore(url: url)
        // 扫描收尾与进后台都会调 flush:什么都没读过时不该写出(或重写)文件。
        await inspections.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let original = song()
        await inspections.record(original, complete: true)
        await inspections.flush()
        let written = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        await inspections.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Nothing new since the last write")
        let reloaded = TVMetadataInspectionStore(url: url)
        let current = await reloaded.isCurrent(original)
        XCTAssertFalse(current)
        XCTAssertFalse(written.isEmpty)
    }

    func testChangedSidecarInvalidatesInspection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inspections = TVMetadataInspectionStore(url: url)
        let original = song()
        func sidecars(_ size: Int64) -> SidecarDirectoryIndex<TVDirEntry> {
            .init([.init(name: "Track.lrc", isDir: false, size: size, path: "/Music/Track.lrc")])
        }
        await inspections.record(original, sidecars: sidecars(100), complete: true)
        let same = await inspections.isCurrent(original, sidecars: sidecars(100))
        let changed = await inspections.isCurrent(original, sidecars: sidecars(200))
        XCTAssertTrue(same)
        XCTAssertFalse(changed)
        await inspections.flush()
    }

    private struct ListedFiles: TVDirectoryLister {
        let entries: [TVDirEntry]
        var usesStableProviderSongIdentity = false
        func list(_ path: String) async throws -> [TVDirEntry] { entries }
    }

    private struct TwoFactorRequiredLister: TVDirectoryLister {
        func list(_ path: String) async throws -> [TVDirEntry] {
            throw StreamResolveError.needs2FA
        }
    }

    func testScanTwoFactorRequirementResetsBeforeNextScan() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TVSourceScanner(metadataInspections: TVMetadataInspectionStore(url: url))
        let source = MusicSource(id: UUID().uuidString, name: "Two-factor NAS", type: .smb)
        XCTAssertFalse(scanner.needsTwoFactor)

        let failed = await scanner.scan(
            source: source, lister: TwoFactorRequiredLister(), dirs: ["/"],
            credential: nil, existingSongs: [],
            onSkeletonBatch: { _ in }, onMetadataBatch: { _ in }
        )
        XCTAssertTrue(scanner.needsTwoFactor)
        XCTAssertFalse(failed.enumerationCompleted)
        guard case .failed = scanner.phase else {
            return XCTFail("Two-factor authentication must leave the scan in the failed state")
        }

        let retried = await scanner.scan(
            source: source, lister: ListedFiles(entries: []), dirs: ["/"],
            credential: nil, existingSongs: [],
            onSkeletonBatch: { _ in }, onMetadataBatch: { _ in }
        )
        XCTAssertFalse(scanner.needsTwoFactor)
        XCTAssertTrue(retried.enumerationCompleted)
    }

    func testRepeatedScanKeepsInspectedAssetReferencesWithoutReopeningSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inspections = TVMetadataInspectionStore(url: url)
        let source = MusicSource(id: UUID().uuidString, name: "Offline NAS", type: .smb)
        let entries: [TVDirEntry] = [
            .init(name: "Track.mp3", isDir: false, size: 4096, path: "/Music/Track.mp3",
                  modifiedDate: Date(timeIntervalSince1970: 100)),
            .init(name: "Track.lrc", isDir: false, size: 100, path: "/Music/Track.lrc"),
            .init(name: "Track.jpg", isDir: false, size: 100, path: "/Music/Track.jpg"),
        ]
        var original = song()
        original.id = TVScanPipelinePolicy.songID(sourceID: source.id, path: original.filePath)
        original.sourceID = source.id
        original.coverArtFileName = "preserved-cover.jpg"
        original.lyricsFileName = "preserved-lyrics.json"
        await inspections.record(original, sidecars: .init(entries), complete: true)
        let scanner = TVSourceScanner(metadataInspections: inspections)
        var songs = [original]
        for _ in 0..<3 {
            let result = await scanner.scan(source: source, lister: ListedFiles(entries: entries),
                dirs: ["/Music"], credential: nil, existingSongs: songs,
                onSkeletonBatch: { _ in }, onMetadataBatch: { _ in })
            XCTAssertTrue(result.enumerationCompleted)
            XCTAssertEqual(result.metadataFailureCount, 0, "An offline source must not be reopened for inspected unchanged files")
            let updated = try XCTUnwrap(result.songs.first)
            XCTAssertEqual(updated.coverArtFileName, original.coverArtFileName)
            XCTAssertEqual(updated.lyricsFileName, original.lyricsFileName)
            songs = result.songs
        }
        await inspections.flush()
    }

    func testSynologyRescanReusesInspectionAfterInterruptedSkeletonWrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inspections = TVMetadataInspectionStore(url: url)
        let source = MusicSource(id: UUID().uuidString, name: "Synology", type: .synology)
        let entry = TVDirEntry(
            name: "Track.mp3", isDir: false, size: 4096, path: "/Music/Track.mp3",
            modifiedDate: Date(timeIntervalSince1970: 100)
        )
        let entries = [
            entry,
            TVDirEntry(name: "Track.jpg", isDir: false, size: 100, path: "/Music/Track.jpg"),
            TVDirEntry(name: "Track.lrc", isDir: false, size: 100, path: "/Music/Track.lrc"),
        ]
        var inspected = song()
        inspected.sourceID = source.id
        inspected.id = TVScanPipelinePolicy.songID(sourceID: source.id, path: entry.path)
        inspected.coverArtFileName = "cached-cover.jpg"
        inspected.lyricsFileName = "cached-lyrics.json"
        inspected.revision = SynologyFileRevisionPolicy.revision(
            size: entry.size, modifiedDate: entry.modifiedDate
        )
        await inspections.record(inspected, sidecars: .init(entries), complete: true)
        var interrupted = inspected
        interrupted.revision = nil

        let scanner = TVSourceScanner(
            metadataInspections: inspections,
            readMetadata: { song, _, _ in
                TVMetadataEnrichmentResult(
                    song: song, status: .failed,
                    errorDescription: "Unexpected remote read", inspectionComplete: false
                )
            }
        )
        let result = await scanner.scan(
            source: source, lister: ListedFiles(entries: entries), dirs: ["/Music"],
            credential: nil, existingSongs: [interrupted],
            onSkeletonBatch: { _ in }, onMetadataBatch: { _ in }
        )
        XCTAssertTrue(result.enumerationCompleted)
        XCTAssertEqual(result.metadataFailureCount, 0)
        XCTAssertEqual(result.songs.first?.revision, inspected.revision)
        XCTAssertEqual(result.songs.first?.coverArtFileName, inspected.coverArtFileName)
        XCTAssertEqual(result.songs.first?.lyricsFileName, inspected.lyricsFileName)
    }

    func testUnchangedCloudFileKeepsItsNewPathWhenInspectionIsReused() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inspections = TVMetadataInspectionStore(url: url)
        let source = MusicSource(id: UUID().uuidString, name: "Cloud", type: .oneDrive)
        var original = song()
        original.sourceID = source.id
        original.id = TVScanPipelinePolicy.songID(sourceID: source.id, path: original.filePath,
                                                 providerID: "stable-file", usesStableProviderIdentity: true)
        await inspections.record(original, sidecars: .init([]), complete: true)
        let entry = TVDirEntry(name: "Renamed.mp3", isDir: false, size: original.fileSize,
                               path: "/Music/Renamed.mp3", providerID: "stable-file", modifiedDate: original.lastModified)
        let scanner = TVSourceScanner(metadataInspections: inspections)
        let result = await scanner.scan(source: source, lister: ListedFiles(entries: [entry], usesStableProviderSongIdentity: true),
            dirs: ["/Music"], credential: nil, existingSongs: [original],
            onSkeletonBatch: { _ in }, onMetadataBatch: { _ in })
        XCTAssertEqual(result.metadataFailureCount, 0)
        XCTAssertEqual(result.songs.first?.id, original.id)
        XCTAssertEqual(result.songs.first?.filePath, entry.path)
        await inspections.flush()
    }

    func testExplicitRereadRefreshesUnchangedFilesAndAssetsFromAllRoots() async throws {
        let folderName = "MetadataReread-" + UUID().uuidString
        let folder = TVLocalTransferSource.root.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = MusicSource(id: TVLocalTransferSource.sourceID, name: "Local", type: .local,
                                 basePath: TVLocalTransferSource.root.path)
        let inspections = TVMetadataInspectionStore(url: folder.appendingPathComponent("inspection.json"))
        let scanner = TVSourceScanner(metadataInspections: inspections)
        let audio = folder.appendingPathComponent("Track.wav")
        let cover = folder.appendingPathComponent("Track.png")
        let lyrics = folder.appendingPathComponent("Track.lrc")
        let modified = Date(timeIntervalSince1970: 100)
        func writeFiles(title: String, genre: String, color: UIColor, line: String) throws {
            try taggedWave(title: title, genre: genre, album: folderName).write(to: audio)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            try XCTUnwrap(image.pngData()).write(to: cover)
            try "[00:00.00]\(line)".write(to: lyrics, atomically: true, encoding: .utf8)
            for url in [audio, cover, lyrics] {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
        }
        try writeFiles(title: "Before", genre: "Rock", color: .red, line: "Before")
        let first = await scanner.scan(source: source, lister: TVLocalDirectoryLister(), dirs: ["/" + folderName],
            credential: nil, existingSongs: [], onSkeletonBatch: { _ in }, onMetadataBatch: { _ in })
        XCTAssertEqual(first.metadataFailureCount, 0)
        let original = try XCTUnwrap(first.songs.first)
        XCTAssertEqual(original.title, "Before")
        let albumID = try XCTUnwrap(original.albumID)
        let oldCover = await MetadataAssetStore.shared.cachedAlbumCover(forAlbumID: albumID)
        XCTAssertNotNil(oldCover)
        try writeFiles(title: "After!", genre: "Jazz", color: .blue, line: "After!")
        // Keep an inspection for the unchanged byte identity to model stale
        // source timestamps and a previous scan that had already checked tags.
        let entries = try await TVLocalDirectoryLister().list("/" + folderName)
        await inspections.record(original, sidecars: .init(entries), complete: true)
        let normal = await scanner.scan(source: source, lister: TVLocalDirectoryLister(), dirs: ["/" + folderName],
            credential: nil, existingSongs: first.songs, onSkeletonBatch: { _ in }, onMetadataBatch: { _ in })
        XCTAssertEqual(normal.songs.first?.title, "Before")
        let forced = await scanner.scan(source: source, lister: TVLocalDirectoryLister(), dirs: ["/" + folderName],
            credential: nil, existingSongs: normal.songs, rereadMetadata: true,
            resumeState: SourceScanResumeState(pendingDirectories: ["/missing-checkpoint-folder"]),
            onSkeletonBatch: { _ in }, onMetadataBatch: { _ in })
        XCTAssertEqual(forced.metadataFailureCount, 0)
        XCTAssertTrue(forced.enumerationCompleted)
        let updated = try XCTUnwrap(forced.songs.first)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.dateAdded, original.dateAdded)
        XCTAssertEqual(updated.title, "After!")
        XCTAssertEqual(updated.artistName, "Tagged Artist")
        XCTAssertEqual(updated.albumArtistName, "Album Artist")
        XCTAssertEqual(updated.genre, "Jazz")
        XCTAssertEqual(updated.year, 2001)
        XCTAssertEqual(updated.trackNumber, 3)
        XCTAssertEqual(updated.discNumber, 2)
        XCTAssertEqual(updated.sampleRate, 8000)
        XCTAssertTrue(updated.lyricsText?.contains("After!") == true)
        let newCover = await MetadataAssetStore.shared.cachedAlbumCover(forAlbumID: albumID)
        XCTAssertNotEqual(newCover, oldCover)
        await inspections.flush()
    }

    func testForcedRereadFailurePreservesExistingSongAndReportsIssue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inspections = TVMetadataInspectionStore(url: url)
        let source = MusicSource(id: UUID().uuidString, name: "Unavailable", type: .local)
        var original = song()
        original.sourceID = source.id
        original.filePath = "/missing-" + UUID().uuidString + ".mp3"
        original.id = TVScanPipelinePolicy.songID(sourceID: source.id, path: original.filePath)
        let entry = TVDirEntry(name: (original.filePath as NSString).lastPathComponent, isDir: false,
            size: original.fileSize, path: original.filePath, modifiedDate: original.lastModified)
        await inspections.record(original, sidecars: .init([entry]), complete: true)
        let scanner = TVSourceScanner(metadataInspections: inspections)
        let result = await scanner.scan(source: source, lister: ListedFiles(entries: [entry]), dirs: ["/"],
            credential: nil, existingSongs: [original], rereadMetadata: true,
            onSkeletonBatch: { _ in }, onMetadataBatch: { _ in })
        XCTAssertEqual(result.metadataFailureCount, 1)
        XCTAssertEqual(scanner.metadataIssueCount, 1)
        XCTAssertEqual(result.songs.first?.id, original.id)
        XCTAssertEqual(result.songs.first?.title, original.title)
        await inspections.flush()
    }

    func testServerRereadUpdatesUnchangedCatalogAndPreservesManualEdits() {
        var original = song()
        original.replayGainTrackGain = -6
        original.artistArtworkFileName = "/artist.jpg"
        var incoming = original
        incoming.replayGainTrackGain = nil
        incoming.artistArtworkFileName = nil
        incoming.title = "Updated server title"
        incoming.artistName = "Updated server artist"
        incoming.genre = "Jazz"
        let updated = TVSourceScanner.rereadServerSong(existing: original, incoming: incoming)
        XCTAssertEqual(updated.title, incoming.title)
        XCTAssertEqual(updated.artistName, incoming.artistName)
        XCTAssertEqual(updated.genre, "Jazz")
        XCTAssertEqual(updated.replayGainTrackGain, -6)
        XCTAssertEqual(updated.artistArtworkFileName, "/artist.jpg")
        XCTAssertEqual(updated.dateAdded, original.dateAdded)
        var edited = original
        edited.userMetadataEditedAt = Date()
        let preserved = TVSourceScanner.rereadServerSong(existing: edited, incoming: incoming)
        XCTAssertEqual(preserved.title, original.title)
        XCTAssertEqual(preserved.artistName, original.artistName)
    }

    func testServerRereadCorrectsAddedDatesAndKeepsUndatedImportTime() {
        var original = song()
        original.userMetadataEditedAt = Date()
        var incoming = original
        incoming.title = "Remote title"
        incoming.serverDateAdded = Date(timeIntervalSince1970: 1_600_000_000)
        incoming.serverAlbumDateAdded = Date(timeIntervalSince1970: 1_500_000_000)
        for replaced in [false, true] {
            if replaced { incoming.fileSize += 1 }
            let repaired = TVSourceScanner.rereadServerSong(existing: original, incoming: incoming)
            XCTAssertEqual(repaired.dateAdded, incoming.serverDateAdded)
            XCTAssertEqual(repaired.serverAlbumDateAdded, incoming.serverAlbumDateAdded)
            XCTAssertEqual(repaired.title, original.title)
            var undated = incoming
            undated.serverDateAdded = nil
            undated.serverAlbumDateAdded = nil
            undated.dateAdded = Date()
            let retained = TVSourceScanner.rereadServerSong(existing: repaired, incoming: undated)
            XCTAssertEqual(retained.dateAdded, repaired.dateAdded)
            XCTAssertEqual(retained.serverAlbumDateAdded, repaired.serverAlbumDateAdded)
        }
    }

    private func taggedWave(title: String, genre: String, album: String) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data {
            var encoded = value.littleEndian
            return withUnsafeBytes(of: &encoded) { Data($0) }
        }
        func chunk(_ name: String, _ payload: Data) -> Data {
            var data = Data(name.utf8) + le(UInt32(payload.count)) + payload
            if payload.count % 2 != 0 { data.append(0) }
            return data
        }
        var tags = Data()
        for (id, value) in [("TIT2", title), ("TPE1", "Tagged Artist"), ("TPE2", "Album Artist"),
                            ("TALB", album), ("TCON", genre), ("TYER", "2001"),
                            ("TRCK", "3"), ("TPOS", "2")] {
            let payload = Data([0]) + Data(value.utf8)
            var size = UInt32(payload.count).bigEndian
            tags += Data(id.utf8) + withUnsafeBytes(of: &size) { Data($0) } + Data([0, 0]) + payload
        }
        let size = tags.count
        let tag = Data([0x49, 0x44, 0x33, 3, 0, 0, UInt8((size >> 21) & 127),
                        UInt8((size >> 14) & 127), UInt8((size >> 7) & 127), UInt8(size & 127)]) + tags
        let format = le(UInt16(1)) + le(UInt16(1)) + le(UInt32(8000)) + le(UInt32(16000)) + le(UInt16(2)) + le(UInt16(16))
        let body = Data("WAVE".utf8) + chunk("fmt ", format) + chunk("id3 ", tag) + chunk("data", Data(repeating: 0, count: 1600))
        return Data("RIFF".utf8) + le(UInt32(body.count)) + body
    }

    func testServerArtworkCacheSeparatesCredentialsAndEndpoints() {
        var source = MusicSource(id: "server", name: "Server", type: .navidrome, host: "example.invalid")
        let first = TVSourceAssetReader.cacheIdentity(source: source, credential: .init(password: "first"))
        let second = TVSourceAssetReader.cacheIdentity(source: source, credential: .init(password: "second"))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("first"))
        source.host = "another.invalid"
        XCTAssertNotEqual(first, TVSourceAssetReader.cacheIdentity(source: source, credential: .init(password: "first")))
    }
}
private struct SynologyArtworkResolver: StreamResolver {
    func streamURL(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> URL {
        guard source.deviceId == "fixture-trust", credential?.password == "fixture-password",
              song.filePath == "/books/cover.jpg" else { throw StreamResolveError.needs2FA }
        return URL(string: "https://nas.example/artwork?session=fixture-session")!
    }
}

private final class SynologyArtworkURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/jpeg", "Content-Length": "4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor RouteHealthByteReader: ByteRangeReader {
    let failReads: Bool
    var reads = 0
    init(failReads: Bool) { self.failReads = failReads }
    func contentLength() async throws -> Int64 { 10 }
    func read(offset: Int64, length: Int64) async throws -> Data {
        reads += 1
        if failReads { throw URLError(.timedOut) }
        return Data([1])
    }
}


@MainActor
final class FocusedArtworkRefreshTests: XCTestCase {
    private func image(_ color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.pngData())
    }

    func testOldArtworkRemainsUsableForBrowsingButConfigurationChangeInvalidatesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let bytes = try image(.red)
        let reference = "subsonic-cover/album"
        let source = MusicSource(id: "source", name: "Fixture", type: .navidrome, host: "artwork.invalid")
        await assets.cacheSourceCover(bytes, songID: "song", sourceID: source.id, reference: reference, maximumPixels: 1536)
        let key = try XCTUnwrap(SourceArtworkPolicy.cacheID(sourceID: source.id, reference: reference, maximumPixels: 1536))
        let url = assets.artworkDirectoryURL.appendingPathComponent(assets.expectedCoverFileName(for: key))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172_800)], ofItemAtPath: url.path)
        let loaded = await TVArtworkLoader(assets: assets).songCover(songID: "song", coverRef: reference, source: source, maximumPixels: 1536)
        XCTAssertEqual(loaded, bytes)
        assets.revalidateArtwork(sourceID: source.id)
        XCTAssertNil(assets.cachedSourceCover(sourceID: source.id, reference: reference, maximumPixels: 1536, checksAge: false))
        let updated = await assets.refreshFocusedArtwork(songID: "song", sourceID: source.id, reference: reference) { bytes }
        XCTAssertTrue(updated)
        XCTAssertEqual(assets.cachedSourceCover(sourceID: source.id, reference: reference, maximumPixels: 1536, checksAge: false), bytes)
    }

    func testRefreshKeepsOldImageUntilReadyAndOnlyChangesFocusedReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let old = try image(.red), new = try image(.blue)
        for ref in ["subsonic-cover/a", "subsonic-cover/b"] {
            await assets.cacheSourceCover(old, songID: ref, sourceID: "source", reference: ref, maximumPixels: 1536)
            let key = try XCTUnwrap(SourceArtworkPolicy.cacheID(sourceID: "source", reference: ref, maximumPixels: 1536))
            let url = assets.artworkDirectoryURL.appendingPathComponent(assets.expectedCoverFileName(for: key))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path)
        }
        let aToken = assets.artworkFreshnessToken(sourceID: "source", reference: "subsonic-cover/a")
        let bToken = assets.artworkFreshnessToken(sourceID: "source", reference: "subsonic-cover/b")
        let sourceToken = assets.artworkFreshnessToken(sourceID: "source")
        let gate = ArtworkNetworkProbe()
        let task = Task {
            await assets.refreshFocusedArtwork(songID: "subsonic-cover/a", sourceID: "source", reference: "subsonic-cover/a") {
                await gate.fetch("refresh", pixels: 1536)
                return new
            }
        }
        await eventually { await gate.started.count == 1 }
        XCTAssertEqual(assets.cachedSourceCover(sourceID: "source", reference: "subsonic-cover/a", maximumPixels: 1536), old)
        await gate.release("refresh")
        let changed = await task.value
        XCTAssertTrue(changed)
        XCTAssertEqual(assets.cachedSourceCover(sourceID: "source", reference: "subsonic-cover/a", maximumPixels: 480), new)
        XCTAssertEqual(assets.cachedSourceCover(sourceID: "source", reference: "subsonic-cover/b", maximumPixels: 1536), old)
        XCTAssertNotEqual(assets.artworkFreshnessToken(sourceID: "source", reference: "subsonic-cover/a"), aToken)
        XCTAssertEqual(assets.artworkFreshnessToken(sourceID: "source", reference: "subsonic-cover/b"), bToken)
        XCTAssertEqual(assets.artworkFreshnessToken(sourceID: "source"), sourceToken)
        let repeated = await assets.refreshFocusedArtwork(songID: "subsonic-cover/a", sourceID: "source", reference: "subsonic-cover/a") {
            XCTFail("Repeated entry must reuse the recent focused check")
            return old
        }
        XCTAssertFalse(repeated)
    }

    func testRecentFullFetchAvoidsImmediateDuplicateOnPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let bytes = try image(.blue)
        await assets.cacheSourceCover(bytes, songID: "song", sourceID: "source", reference: "subsonic-cover/a", maximumPixels: 1536)
        let refreshed = await assets.refreshFocusedArtwork(songID: "song", sourceID: "source", reference: "subsonic-cover/a") {
            XCTFail("The player must reuse a full cover that just finished downloading")
            return bytes
        }
        XCTAssertFalse(refreshed)
    }

    func testCancellationRejectsLateResultAndAllowsNextVisitToRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MetadataAssetStore(storageDirectory: root)
        let bytes = try image(.blue)
        let gate = ArtworkNetworkProbe()
        let task = Task {
            await assets.refreshFocusedArtwork(songID: "song", sourceID: "source", reference: "subsonic-cover/a") {
                await gate.fetch("cancelled", pixels: 1536)
                return bytes
            }
        }
        await eventually { await gate.started.count == 1 }
        task.cancel()
        await gate.release("cancelled")
        let changed = await task.value
        XCTAssertFalse(changed)
        XCTAssertNil(assets.cachedSourceCover(sourceID: "source", reference: "subsonic-cover/a", maximumPixels: 1536))
        let retried = await assets.refreshFocusedArtwork(songID: "song", sourceID: "source", reference: "subsonic-cover/a") { bytes }
        XCTAssertTrue(retried)
        let selection = await assets.storeAttributedCover(bytes, songID: "selected", origin: .selected)
        let selectedRefresh = await assets.refreshFocusedArtwork(songID: "selected", sourceID: "source", reference: selection) {
            XCTFail("Explicitly selected artwork must not request the server")
            return bytes
        }
        XCTAssertFalse(selectedRefresh)
    }

    private func eventually(_ predicate: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for artwork operation", file: file, line: line)
    }
}

final class ArtworkRequestCoordinatorTests: XCTestCase {
    private func request(_ coordinator: ArtworkRequestCoordinator, _ probe: ArtworkNetworkProbe, _ key: String,
                         pixels: Int = 480, priority: ArtworkRequestCoordinator.Priority = .background) -> Task<Data?, Never> {
        Task { await coordinator.request(identity: key, maximumPixels: pixels, priority: priority) { pixels in
            await probe.fetch(key, pixels: pixels)
        } }
    }

    func testBackgroundLimitReservesForegroundSlotAndQueuedCancellationDoesNotStartNetwork() async {
        let coordinator = ArtworkRequestCoordinator(), probe = ArtworkNetworkProbe()
        let a = request(coordinator, probe, "a"), b = request(coordinator, probe, "b")
        await eventually { await probe.started.count == 2 }
        let queued = request(coordinator, probe, "queued")
        let foreground = request(coordinator, probe, "playing", pixels: 1536, priority: .foreground)
        await eventually { await coordinator.waitingConsumerCount == 4 }
        await eventually { await probe.started.count == 3 }
        let started = await probe.started
        XCTAssertEqual(Set(started.map(\.0)), Set(["a", "b", "playing"]))
        queued.cancel()
        let cancelled = await queued.value
        XCTAssertNil(cancelled)
        await probe.release("a"); await probe.release("b"); await probe.release("playing")
        _ = await (a.value, b.value, foreground.value)
        let final = await probe.started
        let peak = await probe.peak
        XCTAssertEqual(final.count, 3)
        XCTAssertEqual(peak, 3)
    }

    func testQueuedThumbnailUpgradesToFullAndOneCancelledConsumerDoesNotCancelSharedWork() async {
        let coordinator = ArtworkRequestCoordinator(), probe = ArtworkNetworkProbe()
        let a = request(coordinator, probe, "a"), b = request(coordinator, probe, "b")
        await eventually { await probe.started.count == 2 }
        let thumbnail = request(coordinator, probe, "shared")
        await eventually { await coordinator.waitingConsumerCount == 3 }
        let full = request(coordinator, probe, "shared", pixels: 1536)
        await eventually { await coordinator.waitingConsumerCount == 4 }
        thumbnail.cancel()
        _ = await thumbnail.value
        await probe.release("a")
        await eventually { await probe.started.count == 3 }
        let shared = await probe.started.filter { $0.0 == "shared" }
        XCTAssertEqual(shared.map(\.1), [1536])
        await probe.release("shared"); await probe.release("b")
        let fullData = await full.value
        XCTAssertEqual(fullData, Data("shared:1536".utf8))
        _ = await (a.value, b.value)
    }

    func testRunningThumbnailAndFullDoNotOverlapAndFullSatisfiesLaterThumbnail() async {
        let coordinator = ArtworkRequestCoordinator(), probe = ArtworkNetworkProbe()
        let low = request(coordinator, probe, "shared")
        await eventually { await probe.started.count == 1 }
        let full = request(coordinator, probe, "shared", pixels: 1536, priority: .foreground)
        await eventually { await coordinator.waitingConsumerCount == 2 }
        let initial = await probe.started
        XCTAssertEqual(initial.count, 1)
        await probe.release("shared")
        _ = await low.value
        await eventually { await probe.started.count == 2 }
        let anotherLow = request(coordinator, probe, "shared")
        await eventually { await coordinator.waitingConsumerCount == 2 }
        await probe.release("shared")
        let fullData = await full.value, lowData = await anotherLow.value
        XCTAssertEqual(fullData, lowData)
        XCTAssertEqual(lowData, Data("shared:1536".utf8))
        let peak = await probe.peak
        XCTAssertEqual(peak, 1)
    }

    func testCancelledTransportHoldsSlotUntilItActuallyFinishes() async {
        let coordinator = ArtworkRequestCoordinator(), probe = ArtworkNetworkProbe()
        let a = request(coordinator, probe, "a"), b = request(coordinator, probe, "b")
        await eventually { await probe.started.count == 2 }
        a.cancel()
        _ = await a.value
        let queued = request(coordinator, probe, "queued")
        await eventually { await coordinator.waitingConsumerCount == 2 }
        let initial = await probe.started
        XCTAssertEqual(initial.count, 2)
        await probe.release("a")
        await eventually { await probe.started.count == 3 }
        await probe.release("b"); await probe.release("queued")
        _ = await (b.value, queued.value)
        let peak = await probe.peak
        XCTAssertEqual(peak, 2)
    }

    private func eventually(_ predicate: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for artwork operation", file: file, line: line)
    }
}

private actor ArtworkNetworkProbe {
    var started: [(String, Int)] = []
    var peak = 0
    private var active = 0
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    @discardableResult
    func fetch(_ key: String, pixels: Int) async -> Data {
        started.append((key, pixels)); active += 1; peak = max(peak, active)
        await withCheckedContinuation { continuations[key] = $0 }
        active -= 1
        return Data("\(key):\(pixels)".utf8)
    }
    func release(_ key: String) { continuations.removeValue(forKey: key)?.resume() }
}


@MainActor
final class SourceMaintenanceQueueTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("maintenance queue did not settle")
    }

    func testPausedQueueRunsSeriallyAndRotatesContinuation() async throws {
        let queue = SourceMaintenanceQueue()
        defer { queue.stop() }
        queue.isPaused = true
        var events: [String] = []
        var attempt = 0
        queue.enqueue(sourceID: "files") {
            attempt += 1
            events.append("files")
            if attempt == 1 { throw SourceMaintenanceQueue.Continuation(delay: 0) }
        }
        queue.enqueue(sourceID: "server") { events.append("server") }
        await Task.yield()
        XCTAssertTrue(events.isEmpty)
        queue.isPaused = false
        try await waitUntil { queue.pendingSourceIDs.isEmpty }
        XCTAssertEqual(events, ["files", "server", "files"])
    }

    func testReplacementWaitsForCancelledTransportToFinish() async throws {
        let queue = SourceMaintenanceQueue()
        defer { queue.stop() }
        var release: CheckedContinuation<Void, Never>?
        var started = false
        var replacementStarted = false
        var firstTicket: UUID?
        queue.enqueue(sourceID: "source") {
            started = true
            firstTicket = queue.operationToken(for: "source")
            await withCheckedContinuation { release = $0 }
        }
        try await waitUntil { started }
        queue.enqueue(sourceID: "source") { replacementStarted = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(replacementStarted)
        XCTAssertNotNil(firstTicket)
        XCTAssertNil(queue.operationToken(for: "source"))
        release?.resume()
        try await waitUntil { queue.pendingSourceIDs.isEmpty }
        XCTAssertTrue(replacementStarted)
    }

    func testPendingIntentSurvivesRestartAndClearsOnlyAfterCompletion() async throws {
        let name = "Maintenance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = SourceMaintenanceQueue(defaults: defaults)
        original.isPaused = true
        original.enqueue(sourceID: "source") { XCTFail("paused job ran") }
        original.stop()
        let resumed = SourceMaintenanceQueue(defaults: defaults)
        defer { resumed.stop() }
        XCTAssertEqual(resumed.pendingSourceIDs, ["source"])
        resumed.enqueue(sourceID: "source") { }
        try await waitUntil { resumed.pendingSourceIDs.isEmpty }
        XCTAssertTrue(SourceMaintenanceQueue(defaults: defaults).pendingSourceIDs.isEmpty)
    }

    func testInvalidationKeepsIntentButRemovalDiscardsIt() async throws {
        let queue = SourceMaintenanceQueue()
        defer { queue.stop() }
        queue.isPaused = true
        queue.enqueue(sourceID: "source") { XCTFail("invalidated job ran") }
        queue.invalidate(sourceID: "source")
        XCTAssertEqual(queue.pendingSourceIDs, ["source"])
        queue.isPaused = false
        await Task.yield()
        queue.discard(sourceID: "source")
        XCTAssertTrue(queue.pendingSourceIDs.isEmpty)
    }

    func testIndexedSnapshotKeepsFirstIdentityAndSmallChangedOverlay() {
        let original = Song(id: "song", title: "Original", fileFormat: .mp3, filePath: "/song.mp3", sourceID: "files")
        var updated = original
        updated.title = "Changed"
        var snapshot = IndexedSongSnapshot([original, updated], sourceID: "files")
        XCTAssertEqual(snapshot["song"]?.title, "Original")
        snapshot.update(updated)
        XCTAssertEqual(snapshot["song"]?.title, "Changed")
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.keys, ["song"])
        XCTAssertNil(IndexedSongSnapshot([original], sourceID: "server")["song"])
    }
}
#endif
