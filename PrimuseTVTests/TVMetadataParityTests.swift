#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
import UIKit
@testable import PrimuseTV

@MainActor
final class TVMetadataParityTests: XCTestCase {
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
        for type in [MusicSourceType.local, .smb, .nfs, .ftp, .webdav, .oneDrive, .dropbox] {
            XCTAssertTrue(TVPlaybackMetadataPolicy.supports(type), type.rawValue)
        }
        for type in [MusicSourceType.subsonic, .navidrome, .jellyfin, .emby, .plex, .fnMusic, .daoliyu, .songloft] {
            XCTAssertFalse(TVPlaybackMetadataPolicy.supports(type), type.rawValue)
        }
        XCTAssertEqual(TVLyricsLoadingPolicy.strategy(for: .daoliyu), .daoLiYuService)
        XCTAssertEqual(TVLyricsLoadingPolicy.strategy(for: .songloft), .songloftService)
        XCTAssertTrue(TVSourceAssetReader.supports(.songloft))
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

    func testBuiltInArtistLookupRequiresExplicitOptInAndPreservesConfiguredSources() {
        let empty = ScraperSettings(sources: [])
        XCTAssertTrue(ArtworkFetchService.artistLookupSources(settings: empty, allowBuiltInFallback: false).isEmpty)
        XCTAssertEqual(ArtworkFetchService.artistLookupSources(settings: empty, allowBuiltInFallback: true).map(\.type), [.itunes])
        let configured = ScraperSourceConfig(id: "configured", type: .musicBrainz, isEnabled: true, priority: 0)
        let settings = ScraperSettings(sources: [configured])
        XCTAssertEqual(ArtworkFetchService.artistLookupSources(settings: settings, allowBuiltInFallback: true), [configured])
        XCTAssertTrue(empty.sources.isEmpty)
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

#endif
