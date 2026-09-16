import CryptoKit
import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class FnMusicSourceTests: XCTestCase {
    func testLateLoginCancellationKeepsEstablishedSession() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        FnMusicSourceURLProtocol.register(host: host, loginDelay: 0, discoveryDelay: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FnMusicSourceURLProtocol.self]
        let api = FnMusicAPI(sourceID: host, host: host, port: 5667, useSSL: true,
                             basePath: nil, connectionMode: .address, accessCode: nil,
                             session: URLSession(configuration: configuration))
        try await api.login(username: "qa", password: "test")
        await api.cancelPendingLogin()
        let loggedIn = await api.isLoggedIn
        XCTAssertTrue(loggedIn)
        XCTAssertEqual(FnMusicSourceURLProtocol.loginCount(host: host), 1)
    }

    func testCancelledFNLoginWaiterDoesNotCancelAnotherSourceOrSharedLogin() async throws {
        let source = makeSource(loginDelay: 0.5)
        let first = Task { try await source.connect() }
        let second = Task { try await source.connect() }
        try await Task.sleep(for: .milliseconds(100))
        first.cancel()
        do { try await first.value; XCTFail("Cancelled waiter should return") } catch is CancellationError {}
        let otherSource = makeSource()
        try await otherSource.connect()
        try await second.value
        let sourceID = await source.sourceID
        XCTAssertEqual(FnMusicSourceURLProtocol.loginCount(host: sourceID), 1)
    }

    func testFNLoginDeadlineReleasesWaitingPlaybackAndCanRetry() async throws {
        let source = makeSource(loginDelay: 5, loginTimeout: 0.1)
        let start = Date()
        do { try await source.connect(); XCTFail("Expected bounded login timeout") }
        catch { XCTAssertTrue(error is FnMusicSource.LoginTimeoutError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let sourceID = await source.sourceID
        FnMusicSourceURLProtocol.setLoginDelay(0, host: sourceID)
        try await source.connect()
        XCTAssertEqual(FnMusicSourceURLProtocol.loginCount(host: sourceID), 2)
    }

    func testDisconnectCancelsFNDiscoveryAndNextGenerationCanConnect() async throws {
        let source = makeSource(connectionMode: .fnConnect, discoveryDelay: 5)
        let pending = Task { try await source.connect() }
        try await Task.sleep(for: .milliseconds(100))
        await source.disconnect()
        do { try await pending.value; XCTFail("Retired discovery must be cancelled") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        let sourceID = await source.sourceID
        FnMusicSourceURLProtocol.setDiscoveryDelay(0, host: sourceID)
        try await source.connect()
        XCTAssertEqual(FnMusicSourceURLProtocol.loginCount(host: sourceID), 1)
    }

    func testFNDiagnosticAllowsLoginBeyondTheGenericFifteenSecondBudget() async throws {
        let connector = makeSource(loginDelay: 16)
        let sourceID = await connector.sourceID
        XCTAssertTrue(KeychainService.setPassword("test", for: sourceID))
        defer { _ = KeychainService.deletePassword(for: sourceID) }
        let source = MusicSource(id: sourceID, name: "FN diagnostic", type: .fnMusic,
                                 host: sourceID, username: "qa")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let report = await manager.diagnose(source: source)
        XCTAssertEqual(report.summaryStatus, .passed)
        XCTAssertEqual(FnMusicSourceURLProtocol.loginCount(host: sourceID), 1)
    }

    func testLibraryIdentityEncodingPreservesExistingIDs() {
        for input in ["", "Artist:Album", "陈奕迅:十年", "a\u{0}b", String(repeating: "音乐", count: 500)] {
            let expected = SHA256.hash(data: Data(input.utf8)).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(MusicLibrary.hashID(input), expected)
        }
    }

    func testInterruptedAtomicScanPublishesWalkedRowsAndRemovesNothing() async throws {
        let fixture = try makeScanFixture(count: 250, failAfterPage: true)
        let old = Song(id: "old", title: "Old", fileFormat: .flac,
                       filePath: "/old.flac", sourceID: fixture.source.id)
        fixture.library.addSongs([old], affectedSourceIDs: [fixture.source.id])
        await fixture.library.waitForPendingIndex()
        fixture.library.ensurePlaylist(id: "saved", name: "Saved")
        fixture.library.replacePlaylistSongs(playlistID: "saved", songIDs: [old.id])
        XCTAssertEqual(fixture.library.rawSongIDs(forPlaylist: "saved"), [old.id])
        let baseline = fixture.library.songs
        var inspectedIDs: Set<String> = []
        fixture.scan.metadataInspectionHandler = { inspectedIDs.formUnion($0) }
        XCTAssertTrue(fixture.start())
        let deadline = Date().addingTimeInterval(10)
        while await !fixture.connector.isWaiting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reachedPage = await fixture.connector.isWaiting
        XCTAssertTrue(reachedPage)
        // Let the main-actor consumer drain the first page while the producer
        // remains blocked.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(inspectedIDs.count, 250)
        // 整库源边走边发: 走完的行在整轮结束前就已经进资料库,
        // 7 万首的服务器不再整轮扫完之前都是空库。
        let published = fixture.library.songs
        XCTAssertGreaterThan(published.count, baseline.count)
        XCTAssertTrue(published.contains(where: { $0.id == old.id }))
        await fixture.connector.release()
        await fixture.scan.waitForActiveScansToComplete()
        XCTAssertNotNil(fixture.scan.scanStates[fixture.source.id]?.failureMessage)
        // 中途失败仍然不做删除对账: 既有歌与歌单成员一首都不能少。
        XCTAssertGreaterThanOrEqual(fixture.library.songs.count, published.count)
        XCTAssertTrue(fixture.library.songs.contains(where: { $0.id == old.id }))
        XCTAssertEqual(fixture.library.rawSongIDs(forPlaylist: "saved"), [old.id])
    }

    func testUnchangedFnMusicRescanDoesNotInvalidateLibrary() async throws {
        let fixture = try makeScanFixture(count: 500, failAfterPage: false)
        XCTAssertTrue(fixture.start())
        await fixture.scan.waitForActiveScansToComplete()
        await fixture.library.waitForPendingIndex()
        XCTAssertNil(fixture.scan.scanStates[fixture.source.id]?.failureMessage)
        XCTAssertEqual(fixture.library.songs.count, 500)
        let baseline = fixture.library.songs
        let generation = fixture.library.songMutationGenerationForMaintenance
        let searchRevision = fixture.library.searchRevision
        let spotlightRevision = fixture.library.spotlightIndexRevision
        XCTAssertTrue(fixture.start())
        await fixture.scan.waitForActiveScansToComplete()
        await fixture.library.waitForPendingIndex()
        XCTAssertNil(fixture.scan.scanStates[fixture.source.id]?.failureMessage)
        XCTAssertEqual(fixture.library.songs, baseline)
        XCTAssertEqual(fixture.library.songMutationGenerationForMaintenance, generation)
        XCTAssertEqual(fixture.library.searchRevision, searchRevision)
        XCTAssertEqual(fixture.library.spotlightIndexRevision, spotlightRevision)
    }

    func testDeferredForegroundResumeWaitsForBackoffAndStartsOnlyOnce() async throws {
        let resumeAfter = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 1)
        let fixture = try makeScanFixture(count: 1, failAfterPage: false, resumeAfter: resumeAfter)
        defer { fixture.scan.cancelAllActiveScans() }
        fixture.resume()
        fixture.resume()
        try await Task.sleep(for: .milliseconds(100))
        let initialCount = await fixture.connector.scanCount
        XCTAssertEqual(initialCount, 0)
        let deadline = resumeAfter.addingTimeInterval(5)
        while fixture.library.songs.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.library.songs.count, 1)
        let finalCount = await fixture.connector.scanCount
        XCTAssertEqual(finalCount, 1)
    }

    func testSceneTransitionCancelsDeferredForegroundResume() async throws {
        let resumeAfter = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 1)
        let fixture = try makeScanFixture(count: 1, failAfterPage: false, resumeAfter: resumeAfter)
        fixture.resume()
        fixture.scan.cancelAllActiveScans()
        try await Task.sleep(for: .seconds(max(0, resumeAfter.timeIntervalSinceNow) + 1.3))
        let scanCount = await fixture.connector.scanCount
        XCTAssertEqual(scanCount, 0)
        XCTAssertTrue(fixture.scan.scanStates[fixture.source.id]?.canResume == true)
        XCTAssertTrue(fixture.library.songs.isEmpty)
    }

    func testExplicitScanBypassesAutomaticResumeBackoff() async throws {
        let fixture = try makeScanFixture(
            count: 1, failAfterPage: false, resumeAfter: Date().addingTimeInterval(300)
        )
        defer { fixture.scan.cancelAllActiveScans() }
        XCTAssertTrue(fixture.start())
        let deadline = Date().addingTimeInterval(5)
        while fixture.library.songs.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.library.songs.count, 1)
    }

    func testDeferredResumeKeepsManagedLocalImportIndependentOfNetwork() throws {
        let key = "local_import_source_id"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let sourceID = UUID().uuidString
        UserDefaults.standard.set(sourceID, forKey: key)
        let source = MusicSource(
            id: sourceID, name: "Local fixture", type: .local,
            basePath: LocalImportService.musicDirectory.path
        )
        let now = Date(timeIntervalSince1970: 10_000)
        let resumeAfter = now.addingTimeInterval(300)
        let fixture = try makeScanFixture(
            count: 0, failAfterPage: false, source: source, resumeAfter: resumeAfter
        )
        XCTAssertTrue(LocalImportService.isManagedSource(source))
        XCTAssertEqual(fixture.scan.nextAutomaticResumeDate(at: now, sourceStore: fixture.store), resumeAfter)
        XCTAssertNil(fixture.scan.nextAutomaticResumeDate(
            at: now, sourceStore: fixture.store, networkSourcesOnly: true
        ))
        let network = try makeScanFixture(count: 0, failAfterPage: false, resumeAfter: resumeAfter)
        XCTAssertEqual(network.scan.nextAutomaticResumeDate(
            at: now, sourceStore: network.store, networkSourcesOnly: true
        ), resumeAfter)
        network.store.updateLocal(network.source.id) { $0.isEnabled = false }
        XCTAssertNil(network.scan.nextAutomaticResumeDate(at: now, sourceStore: network.store))
    }

    func testEmptyAppleMusicLocalScanRemovesOnlyItsLegacyRows() async throws {
        let source = MusicSource(id: UUID().uuidString, name: "Local Music", type: .appleMusicLibrary)
        let fixture = try makeScanFixture(count: 0, failAfterPage: false, source: source)
        let removed = Song(id: "managed-download", title: "Old download", duration: 60,
                           fileFormat: .m4a, filePath: "persistent-id", sourceID: source.id)
        let cloud = Song(id: "cloud-song", title: "Cloud song", duration: 60,
                         fileFormat: .m4a, filePath: "i.cloud", sourceID: AppleMusicLibraryIdentity.sourceID)
        fixture.library.addSongs([removed, cloud], affectedSourceIDs: [source.id, cloud.sourceID])
        XCTAssertTrue(fixture.start())
        await fixture.scan.waitForActiveScansToComplete()
        await fixture.library.waitForPendingIndex()
        XCTAssertNil(fixture.scan.scanStates[source.id]?.failureMessage)
        XCTAssertEqual(fixture.library.songs.map(\.id), [cloud.id])
    }

    func testWebDAVCleanupDeletesFilesAndRetainsPermissionFailuresAcrossRescanAndReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateCleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var source = MusicSource(id: UUID().uuidString, name: "WebDAV fixture", type: .webdav)
        source.extraConfig = MusicSource.encodeScannedDirectories(["/"], into: nil, type: source.type)
        let fixture = try makeScanFixture(count: 3, failAfterPage: false, source: source, root: root)
        XCTAssertTrue(fixture.start())
        await fixture.scan.waitForActiveScansToComplete()
        await fixture.library.waitForPendingIndex()
        let songs = fixture.library.songs.sorted { $0.id < $1.id }
        XCTAssertEqual(songs.count, 3)
        let connector = try DuplicateDeletionFixtureConnector(sourceID: source.id, root: root.appendingPathComponent("audio"), paths: songs.map(\.filePath))
        await connector.setDeniedPaths([songs[1].filePath])
        let savedSource = source
        let manager = SourceManager(sourcesProvider: { [savedSource] }, connectorFactory: { _ in connector })
        let cleanup = DuplicateCleanupService(library: fixture.library, sourceManager: manager, sourcesStore: fixture.store)
        try await XCTUnwrap(cleanup.cleanup(Array(songs.dropFirst()))).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: connector.fileURL(songs[2].filePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: connector.fileURL(songs[1].filePath).path))
        XCTAssertEqual(Set(fixture.library.songs.map(\.id)), [songs[0].id, songs[1].id])
        XCTAssertEqual(fixture.store.source(id: source.id)?.songCount, 2)
        XCTAssertEqual(cleanup.lastCompletedCount, 1)
        XCTAssertEqual(cleanup.lastSourceFailures.first?.reasons, [.permissionDenied])
        XCTAssertEqual(cleanup.completionRevision, 1)

        XCTAssertTrue(fixture.start())
        await fixture.scan.waitForActiveScansToComplete()
        XCTAssertEqual(Set(fixture.library.songs.map(\.id)), [songs[0].id, songs[1].id])
        try await fixture.library.persistNowAndWait().get()
        let reloaded = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        await reloaded.waitForPendingIndex()
        XCTAssertEqual(Set(reloaded.songs.map(\.id)), [songs[0].id, songs[1].id])
        await connector.setDeniedPaths([])
        try await XCTUnwrap(cleanup.retryFailedSource(source.id)).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: connector.fileURL(songs[1].filePath).path))
        XCTAssertEqual(fixture.library.songs.map(\.id), [songs[0].id])
        XCTAssertTrue(cleanup.lastSourceFailures.isEmpty)
    }

    func testDuplicateCleanupContinuesOtherSourcesAndRetriesOnlyTheFailedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MixedDeletion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = [MusicSource(id: UUID().uuidString, name: "Denied", type: .webdav),
                       MusicSource(id: UUID().uuidString, name: "Writable", type: .local),
                       MusicSource(id: UUID().uuidString, name: "Also denied", type: .smb)]
        let songs = sources.enumerated().map { i, source in
            Song(id: "song-\(i)", title: "Song \(i)", fileFormat: .flac, filePath: "/song.flac", sourceID: source.id)
        }
        let connectors = try sources.enumerated().map { i, source in
            try DuplicateDeletionFixtureConnector(sourceID: source.id, root: root.appendingPathComponent("source-\(i)"), paths: ["/song.flac"])
        }
        await connectors[0].setDeniedPaths(["/song.flac"])
        await connectors[2].setDeniedPaths(["/song.flac"])
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        for source in sources { store.add(source) }
        library.addSongs(songs, affectedSourceIDs: Set(sources.map(\.id)))
        await library.waitForPendingIndex()
        let manager = SourceManager(sourcesProvider: { sources }, connectorFactory: { source in connectors[sources.firstIndex { $0.id == source.id }!] })
        let cleaner = DuplicateCleanupService(library: library, sourceManager: manager, sourcesStore: store)
        try await XCTUnwrap(cleaner.cleanup(songs)).value
        XCTAssertEqual(Set(library.songs.map(\.id)), [songs[0].id, songs[2].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: connectors[1].fileURL("/song.flac").path))
        XCTAssertEqual(cleaner.lastSourceFailures.count, 2)
        await connectors[0].setDeniedPaths([])
        try await XCTUnwrap(cleaner.retryFailedSource(sources[0].id)).value
        XCTAssertEqual(library.songs.map(\.id), [songs[2].id])
        XCTAssertEqual(cleaner.lastSourceFailures.map(\.id), [sources[2].id])
        let writableAttempts = await connectors[1].attempts(for: "/song.flac")
        let otherFailedAttempts = await connectors[2].attempts(for: "/song.flac")
        XCTAssertEqual(writableAttempts, 1)
        XCTAssertEqual(otherFailedAttempts, 1)
    }

    func testDuplicateCleanupRetainsInaccessibleNFSExportAndContinuesWritableSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NFSDeletion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nfs = MusicSource(id: UUID().uuidString, name: "NFS", type: .nfs)
        let local = MusicSource(id: UUID().uuidString, name: "Writable", type: .local)
        let path = NFSSelectionPathCodec.makeSelectionPath(exportPath: "/original", relativePath: "/song.flac")
        let songs = [Song(id: "nfs-song", title: "NFS song", fileFormat: .flac, filePath: path, sourceID: nfs.id),
                     Song(id: "local-song", title: "Local song", fileFormat: .flac, filePath: "/song.flac", sourceID: local.id)]
        let nfsConnector = try DuplicateDeletionFixtureConnector(sourceID: nfs.id, root: root.appendingPathComponent("nfs"), paths: [path])
        let localConnector = try DuplicateDeletionFixtureConnector(sourceID: local.id, root: root.appendingPathComponent("local"), paths: [songs[1].filePath])
        await nfsConnector.setNFSExportConstraint("/replacement")
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(nfs)
        store.add(local)
        library.addSongs(songs, affectedSourceIDs: [nfs.id, local.id])
        await library.waitForPendingIndex()
        let manager = SourceManager(sourcesProvider: { [nfs, local] }, connectorFactory: {
            $0.id == nfs.id ? nfsConnector : localConnector
        })
        let cleaner = DuplicateCleanupService(library: library, sourceManager: manager, sourcesStore: store)

        try await XCTUnwrap(cleaner.cleanup(songs)).value

        XCTAssertEqual(library.songs.map(\.id), [songs[0].id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: nfsConnector.fileURL(path).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localConnector.fileURL(songs[1].filePath).path))
        XCTAssertEqual(cleaner.lastCompletedCount, 1)
        XCTAssertEqual(cleaner.lastSourceFailures.first?.reasons, [.unavailable])
        await nfsConnector.setNFSExportConstraint("/original")
        try await XCTUnwrap(cleaner.retryFailedSource(nfs.id)).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: nfsConnector.fileURL(path).path))
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(cleaner.lastSourceFailures.isEmpty)
    }

    func testBatchPartialDeletionConfirmsEachAudioResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchDeletion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: UUID().uuidString, name: "Batch", type: .baiduPan)
        let songs = ["first", "denied"].map { Song(id: $0, title: $0, fileFormat: .flac, filePath: "/\($0).flac", sourceID: source.id) }
        let connector = try DuplicateDeletionFixtureConnector(sourceID: source.id, root: root, paths: songs.map(\.filePath), batchSize: 2)
        await connector.setDeniedPaths([songs[1].filePath])
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let outcomes = await manager.deleteSourceFiles(for: songs, deleteSidecarsForSongIDs: [], onProgress: { _ in })
        XCTAssertEqual(outcomes.map { $0.result.shouldRemoveLibraryRecord }, [true, false])
        XCTAssertEqual(outcomes[0].result.audioStatus, .alreadyMissing)
        XCTAssertEqual(outcomes[1].result.failedPaths.first?.reason, .permissionDenied)
    }

    func testLocalDeletionPermissionErrorNeverRemovesLibraryRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionDeletion-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("song.flac")
        try Data([1, 2, 3]).write(to: file)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let source = MusicSource(id: UUID().uuidString, name: "Local", type: .local, basePath: root.path)
        let song = Song(id: "locked", title: "Locked", fileFormat: .flac, filePath: "/locked/song.flac", sourceID: source.id)
        let manager = SourceManager(sourcesProvider: { [source] })
        let result = await manager.deleteSourceFiles(for: song, deleteSidecars: false)
        XCTAssertFalse(result.shouldRemoveLibraryRecord)
        XCTAssertEqual(result.failedPaths.first?.reason, .permissionDenied)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }

    func testDuplicateCleanupKeepsSidecarsStillUsedByFailedCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SidecarDeletion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: UUID().uuidString, name: "Share", type: .webdav)
        let kept = Song(id: "denied", title: "Song", fileFormat: .mp3, filePath: "/song.mp3", sourceID: source.id)
        let removed = Song(id: "removed", title: "Song", fileFormat: .flac, filePath: "/song.flac", sourceID: source.id)
        let connector = try DuplicateDeletionFixtureConnector(sourceID: source.id, root: root.appendingPathComponent("files"), paths: [kept.filePath, removed.filePath, "/song.lrc"])
        await connector.setDeniedPaths([kept.filePath])
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        library.addSongs([kept, removed], affectedSourceIDs: [source.id])
        await library.waitForPendingIndex()
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let cleaner = DuplicateCleanupService(library: library, sourceManager: manager, sourcesStore: store)
        try await XCTUnwrap(cleaner.cleanup([kept, removed])).value
        XCTAssertEqual(library.songs.map(\.id), [kept.id])
        XCTAssertEqual(try Data(contentsOf: connector.fileURL("/song.lrc")), Data([1, 2, 3]))
        let sidecarAttempts = await connector.attempts(for: "/song.lrc")
        XCTAssertEqual(sidecarAttempts, 0)
    }

    func testDeletionMissingDetectionRejectsAmbiguousProviderMessages() {
        XCTAssertFalse(SourceManager.isMissingFileError(SourceError.connectionFailed("Account not found or access denied")))
        XCTAssertFalse(SourceManager.isMissingFileError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertTrue(SourceManager.isMissingFileError(SourceError.fileNotFound("/song.flac")))
        XCTAssertTrue(SourceManager.isMissingFileError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        XCTAssertEqual(SourceFileDeletionFailureReason.classify(SourceError.authenticationFailed), .authenticationRequired)
        XCTAssertEqual(SourceFileDeletionFailureReason.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))), .readOnly)
    }

    func testLocalReauthorizationPreservesRootMappingAndRejectsAnotherDisk() {
        XCTAssertEqual(LocalBookmarkStore.reauthorizationIndices(originalPaths: ["/Volumes/First", "/Volumes/Second"], selectedPaths: ["/Volumes/Second"]), [1])
        XCTAssertEqual(LocalBookmarkStore.reauthorizationIndices(originalPaths: ["/Volumes/First", "/Volumes/Second"], selectedPaths: ["/Volumes/Second", "/Volumes/First"]), [1, 0])
        XCTAssertNil(LocalBookmarkStore.reauthorizationIndices(originalPaths: ["/Volumes/First"], selectedPaths: ["/Volumes/Other"]))
        XCTAssertNil(LocalBookmarkStore.reauthorizationIndices(originalPaths: ["/Volumes/First"], selectedPaths: ["/Volumes/First", "/Volumes/First"]))
    }

    private struct ScanFixture {
        let source: MusicSource
        let connector: FnMusicScanFixtureConnector
        let scan: ScanService
        let library: MusicLibrary
        let store: SourcesStore
        let manager: SourceManager

        @MainActor func start() -> Bool {
            scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store)
        }

        @MainActor func resume() {
            scan.resumePendingScans(
                sourceManager: manager, library: library, sourceStore: store, scraperService: nil
            )
        }
    }

    private func makeScanFixture(
        count: Int,
        failAfterPage: Bool,
        source: MusicSource? = nil,
        resumeAfter: Date? = nil,
        root: URL? = nil
    ) throws -> ScanFixture {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("FnMusicScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = source ?? MusicSource(id: UUID().uuidString, name: "Scan fixture", type: .fnMusic)
        let connector = FnMusicScanFixtureConnector(sourceID: source.id, count: count, failAfterPage: failAfterPage)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        if let resumeAfter {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Primuse"), withIntermediateDirectories: true
            )
            var checkpoint = ScanCheckpointPreparationPolicy.preparingCheckpoint(
                existing: nil, directories: ["/"], mode: .automatic,
                scopeFingerprint: ScanService.scopeFingerprint(for: source, directories: ["/"])
            )
            checkpoint.automaticResumeAfter = resumeAfter
            try ScanCheckpointFileStore.writeSnapshot(
                [source.id: checkpoint], to: root.appendingPathComponent("Primuse/scan-checkpoints.json")
            )
        }
        let scan = ScanService(fileManager: FnMusicScanFileManager(root: root), connectorProvider: { _ in connector },
                               diagnosticProvider: { source, _ in
            SourceDiagnosticReport(source: source, startedAt: Date(), checks: [])
        })
        return ScanFixture(source: source, connector: connector, scan: scan, library: library, store: store,
                           manager: SourceManager(sourcesProvider: { [] }))
    }

    func testRangeRefreshesBusinessAuthenticationFailure() async throws {
        let source = makeSource()
        let data = try await source.fetchRange(path: "/fnmusic/tracks/song.flac", offset: 0, length: 2)
        XCTAssertEqual(data, Data([1, 2]))
        let sourceID = await source.sourceID
        XCTAssertEqual(FnMusicSourceURLProtocol.loginCount(host: sourceID), 2)
    }

    func testPlaylistAndFavoriteConnectorsUseAuthenticatedLibraryEndpoints() async throws {
        let source = makeSource()
        let snapshot = try await source.fetchServerPlaylists()
        XCTAssertEqual(snapshot.playlists.map(\.id), ["playlist"])
        XCTAssertEqual(snapshot.playlists.first?.trackIDs, ["song"])
        XCTAssertTrue(snapshot.failedPlaylistIDs.isEmpty)
        let added = try await source.setServerFavorite(itemID: "song", isFavorite: true)
        XCTAssertEqual(added.itemIDs, ["song"])
        let removed = try await source.setServerFavorite(itemID: "song", isFavorite: false)
        XCTAssertTrue(removed.itemIDs.isEmpty)
    }

    func testMirrorPreservesFailedDetailsAndPrunesOnlyDeletedPlaylistsFromTheSameSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FnMusicMirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: root)
        let source = MusicSource(id: "fn", name: "Feiniu", type: .fnMusic)
        library.addSongs([
            Song(id: "one", title: "One", fileFormat: .flac, filePath: "/fnmusic/tracks/one.flac", sourceID: source.id),
            Song(id: "two", title: "Two", fileFormat: .flac, filePath: "/fnmusic/tracks/two.flac", sourceID: source.id),
        ], affectedSourceIDs: [source.id])
        await library.waitForPendingIndex()
        func id(_ name: String, sourceID: String = "fn") -> String {
            ServerPlaylistIdentity.playlistID(sourceID: sourceID, serverPlaylistID: name)
        }
        for playlistID in [id("failed"), id("deleted"), id("other", sourceID: "elsewhere")] {
            library.ensurePlaylist(id: playlistID, name: playlistID)
            library.replaceMirrorPlaylistSongs(playlistID: playlistID, songIDs: ["one"], coverArtPath: nil)
        }
        let result = ServerPlaylistMirror.apply(snapshot: ServerPlaylistSnapshot(playlists: [
            ServerPlaylist(id: "new", name: "New", trackIDs: ["two", "one", "two"], reportedTrackCount: 3),
            ServerPlaylist(id: "empty", name: "Empty", trackIDs: [], reportedTrackCount: 0),
        ], failedPlaylistIDs: ["failed"]), source: source, library: library)
        XCTAssertEqual(result.syncedPlaylistCount, 2)
        XCTAssertEqual(library.songs(forPlaylist: id("new")).map(\.id), ["two", "one"])
        XCTAssertEqual(library.songs(forPlaylist: id("failed")).map(\.id), ["one"])
        XCTAssertNotNil(library.playlist(id: id("empty")))
        XCTAssertNil(library.playlist(id: id("deleted")))
        XCTAssertNotNil(library.playlist(id: id("other", sourceID: "elsewhere")))
    }

    /// 探测失败发生在 connect() 之后时, 被探测的实例可能同时被扫描 / 播放
    /// 持有: 只能把它踢出连接缓存, 不能 disconnect —— 否则 WebDAV 会连带
    /// invalidate 正在拉 range 的 session, 让不相干的播放报错。
    func testPostConnectDiagnosticFailureDoesNotDisconnectSharedConnector() async {
        let source = MusicSource(
            id: UUID().uuidString, name: "Diag WebDAV", type: .webdav,
            host: "nas.invalid", authType: .none
        )
        let connector = DiagnosticProbeConnector(sourceID: source.id, failsConnect: false)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        // 模拟「扫描 / 播放正持有同一个共享实例」。
        let held = manager.connector(for: source)
        XCTAssertTrue(held is DiagnosticProbeConnector)

        let report = await manager.diagnose(source: source, directories: ["/music"])

        XCTAssertTrue(report.checks.contains { $0.status == .failed })
        let connects = await connector.connectCount
        XCTAssertEqual(connects, 1)
        // 退休是异步的; 给它足够时间真的跑一次才判定「没有断开」。
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(20))
            let disconnects = await connector.disconnectCount
            if disconnects > 0 { break }
        }
        let disconnects = await connector.disconnectCount
        XCTAssertEqual(disconnects, 0)
    }

    /// connect() 本身失败时没有别的持有者依赖这个传输, 保持原有的断开语义。
    func testConnectFailureStillRetiresDiagnosticConnector() async {
        let source = MusicSource(
            id: UUID().uuidString, name: "Diag WebDAV", type: .webdav,
            host: "nas.invalid", authType: .none
        )
        let connector = DiagnosticProbeConnector(sourceID: source.id, failsConnect: true)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })

        let report = await manager.diagnose(source: source, directories: ["/music"])

        XCTAssertTrue(report.checks.contains { $0.status == .failed })
        var disconnects = 0
        let deadline = Date().addingTimeInterval(5)
        while disconnects == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            disconnects = await connector.disconnectCount
        }
        XCTAssertEqual(disconnects, 1)
    }

    private func makeSource(
        connectionMode: FnMusicConnectionMode = .address,
        loginDelay: TimeInterval = 0,
        discoveryDelay: TimeInterval = 0,
        loginTimeout: TimeInterval = FnMusicSource.connectionTimeout
    ) -> FnMusicSource {
        let host = UUID().uuidString.lowercased() + (connectionMode == .address ? ".invalid" : "")
        FnMusicSourceURLProtocol.register(host: host, loginDelay: loginDelay, discoveryDelay: discoveryDelay)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FnMusicSourceURLProtocol.self]
        return FnMusicSource(sourceID: host, host: host, port: 5667, useSSL: true,
                             basePath: nil, connectionMode: connectionMode, accessCode: nil,
                             username: "qa", password: "test", session: URLSession(configuration: configuration),
                             loginTimeout: loginTimeout)
    }
}

private final class FnMusicScanFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}

private actor FnMusicScanFixtureConnector: RefreshingMetadataSongConnector {
    let sourceID: String
    let count: Int
    let failAfterPage: Bool
    private(set) var isWaiting = false
    private(set) var scanCount = 0
    private var released = false

    init(sourceID: String, count: Int, failAfterPage: Bool) {
        self.sourceID = sourceID; self.count = count; self.failAfterPage = failAfterPage
    }
    func release() { released = true }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        scanCount += 1
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for index in 0..<count {
                        try Task.checkCancellation()
                        var song = Song(id: "track-\(index)", title: "Track \(index)", fileFormat: .flac,
                                        filePath: "/fnmusic/tracks/\(index).flac", sourceID: sourceID)
                        song.dateAdded = Date(timeIntervalSince1970: 1_000)
                        continuation.yield(ConnectorScannedSong(song: song, displayName: song.title,
                                                               titleMetadataInspected: true))
                    }
                    if failAfterPage {
                        isWaiting = true
                        while !released { try await Task.sleep(for: .milliseconds(10)) }
                        throw SourceError.connectionFailed("Fixture page failed")
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private final class FnMusicSourceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private struct State {
        var logins = 0
        var favorite = false
        var loginDelay: TimeInterval
        var discoveryDelay: TimeInterval
    }
    nonisolated(unsafe) private static var states: [String: State] = [:]
    private let responseLock = NSLock()
    private var stopped = false
    static func register(host: String, loginDelay: TimeInterval, discoveryDelay: TimeInterval) {
        lock.withLock { states[host] = State(loginDelay: loginDelay, discoveryDelay: discoveryDelay) }
    }
    static func setLoginDelay(_ delay: TimeInterval, host: String) {
        lock.withLock { states[host]?.loginDelay = delay }
    }
    static func setDiscoveryDelay(_ delay: TimeInterval, host: String) {
        lock.withLock { states[host]?.discoveryDelay = delay }
    }
    static func loginCount(host: String) -> Int { lock.withLock { states[host]?.logins ?? 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/api/v1/fn/con" {
            let body: Data
            if let data = request.httpBody {
                body = data
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var result = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    result.append(buffer, count: count)
                }
                body = result
            } else { body = Data() }
            let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            guard let fnID = payload?["fnId"] else { return }
            let delay = Self.lock.withLock { Self.states[fnID]?.discoveryDelay ?? 0 }
            let data = try! JSONSerialization.data(withJSONObject: [
                "code": 0, "data": ["fn": ["\(fnID).fnos.net"]]
            ])
            respond(status: 200, headers: ["Content-Type": "application/json"], data: data, delay: delay)
            return
        }
        let host = url.host!.hasSuffix(".fnos.net") ? String(url.host!.dropLast(".fnos.net".count)) : url.host!
        let delay = Self.lock.withLock {
            url.lastPathComponent == "password-login" ? Self.states[host]?.loginDelay ?? 0 : 0
        }
        let (status, headers, data): (Int, [String: String], Data) = Self.lock.withLock {
            var state = Self.states[host]!
            defer { Self.states[host] = state }
            let jsonHeaders = ["Content-Type": "application/json"]
            func json(_ payload: Any) -> Data { try! JSONSerialization.data(withJSONObject: payload) }
            func page(_ items: [[String: Any]]) -> Data { json(["code": 0, "data": ["list": items, "total": items.count]]) }
            switch url.lastPathComponent {
            case "access_code_verify":
                return (204, [:], Data())
            case "config":
                return (200, jsonHeaders, json(["code": 0, "data": [:]]))
            case "list" where url.path.contains("/track/list"):
                return (200, jsonHeaders, page([]))
            case "password-login":
                state.logins += 1
                return (200, jsonHeaders, json(["code": 200, "data": ["userToken": "token-\(state.logins)"]]))
            case "stream":
                if state.logins == 1 { return (200, jsonHeaders, json(["code": 120001, "msg": "INVALID TOKEN"])) }
                return (206, ["Content-Type": "audio/flac", "Content-Range": "bytes 0-1/8", "Content-Length": "2"], Data([1, 2]))
            case "list" where url.path.contains("/playlist/list"):
                return (200, jsonHeaders, page([["guid": "playlist", "name": "Playlist", "trackCount": 1]]))
            case "list" where url.path.contains("/playlist-detail/"):
                return (200, jsonHeaders, page([["guid": "song"]]))
            case "list" where url.path.contains("/favorite-track/"):
                return (200, jsonHeaders, page(state.favorite ? [["guid": "song"]] : []))
            case "create", "delete":
                state.favorite = url.lastPathComponent == "create"
                return (200, jsonHeaders, json(["code": 0, "data": NSNull()]))
            default:
                return (404, jsonHeaders, Data())
            }
        }
        respond(status: status, headers: headers, data: data, delay: delay)
    }
    private func respond(status: Int, headers: [String: String], data: Data, delay: TimeInterval) {
        let deliver: @Sendable () -> Void = { [self] in
            responseLock.withLock {
                guard !stopped else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }
    override func stopLoading() {
        responseLock.withLock { stopped = true }
    }
}

/// connect() 成功、目录探测失败的假 connector, 记录 connect/disconnect 次数。
private actor DiagnosticProbeConnector: MusicSourceConnector {
    nonisolated let sourceID: String
    private let failsConnect: Bool
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(sourceID: String, failsConnect: Bool) {
        self.sourceID = sourceID
        self.failsConnect = failsConnect
    }

    func connect() async throws {
        connectCount += 1
        if failsConnect { throw SourceError.connectionFailed("probe") }
    }
    func disconnect() async { disconnectCount += 1 }
    func listFiles(at path: String) async throws -> [RemoteFileItem] { throw SourceError.timeout }
    func localURL(for path: String) async throws -> URL { throw URLError(.unsupportedURL) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw URLError(.unsupportedURL)
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor DuplicateDeletionFixtureConnector: MusicSourceConnector {
    let sourceID: String
    nonisolated let root: URL
    nonisolated let preferredDeleteBatchSize: Int
    private var deniedPaths: Set<String> = []
    private var deleteAttempts: [String: Int] = [:]
    private var nfsExportConstraint: String?

    init(sourceID: String, root: URL, paths: [String], batchSize: Int = 1) throws {
        self.sourceID = sourceID
        self.root = root
        self.preferredDeleteBatchSize = batchSize
        for path in paths {
            let file = root.appendingPathComponent(String(path.dropFirst()))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: file)
        }
    }
    nonisolated func fileURL(_ path: String) -> URL { root.appendingPathComponent(String(path.dropFirst())) }
    func setDeniedPaths(_ paths: Set<String>) { deniedPaths = paths }
    func setNFSExportConstraint(_ path: String) { nfsExportConstraint = path }
    func attempts(for path: String) -> Int { deleteAttempts[path, default: 0] }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { fileURL(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func deleteFile(at path: String) async throws {
        deleteAttempts[path, default: 0] += 1
        if deniedPaths.contains(path) { throw SourceFileMutationError.permissionDenied }
        if let nfsExportConstraint {
            _ = try NFSSelectionPathCodec.parse(path, constrainedToExport: nfsExportConstraint)
        }
        try FileManager.default.removeItem(at: fileURL(path))
    }
    func deleteFiles(at paths: [String]) async throws {
        for path in paths { try await deleteFile(at: path) }
    }
}
