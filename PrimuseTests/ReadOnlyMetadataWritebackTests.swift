import Foundation
import PrimuseKit
import XCTest
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif
@testable import Citadel
@testable import Primuse

final class ReadOnlyMetadataWritebackTests: XCTestCase {
    private func song() -> Song {
        Song(id: UUID().uuidString, title: "Original", fileFormat: .flac,
             filePath: "/Music/song.flac", sourceID: UUID().uuidString)
    }

    func testWebDAVWriteDenialsAreNotAuthenticationFailures() async throws {
        let source = WebDAVSource(sourceID: UUID().uuidString, host: "readonly.invalid",
                                  useSsl: true, username: "", password: "")
        for operation in ["PUT", "MOVE"] {
            for (status, expected) in [(403, SourceFileDeletionFailureReason.permissionDenied), (405, .readOnly)] {
                let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://readonly.invalid/song")!,
                    statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
                do {
                    try await source.validateMutationResponse(response, operation: operation)
                    XCTFail("Rejected mutation must fail")
                } catch {
                    XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), expected)
                }
            }
        }
        await source.disconnect()
    }

    func testPermissionFailureStopsBothSidecarsAndReportsNoRemoteSuccess() async {
        let failures: [any Error] = [
            SourceFileMutationError.permissionDenied, SourceFileMutationError.readOnly,
            POSIXError(.EACCES), POSIXError(.EPERM), POSIXError(.EROFS),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
            CloudDriveError.permissionDenied(.fileWrite),
            SFTPMessage.Status(requestId: 1, errorCode: .permissionDenied, message: "Denied", languageTag: "en")
        ]
        for error in failures {
            let connector = DeniedMetadataConnector(error: error)
            let result = await SidecarWriteService.shared.writeSidecars(
                for: song(), using: connector, coverData: Data([1]),
                lyricsLines: [LyricLine(timestamp: 1, text: "Keep my lyrics")])
            XCTAssertTrue(result.sourceUnavailable, "\(error)")
            XCTAssertFalse(result.coverWritten)
            XCTAssertFalse(result.lyricsWritten)
            let attempts = await connector.attempts
            XCTAssertEqual(attempts, 1, "Do not attempt lyrics after cover permission denial")
        }
    }

    func testTransientAndConflictErrorsDoNotDisableSource() async {
        for error: any Error in [URLError(.timedOut), EmbeddedMetadataWritebackSourceError.conflict,
                                 EmbeddedMetadataWritebackSourceError.remoteVerificationFailed, CancellationError()] {
            let result = await SidecarWriteService.shared.writeSidecars(
                for: song(), using: DeniedMetadataConnector(error: error),
                coverData: Data([1]), lyricsLines: nil)
            XCTAssertFalse(result.sourceUnavailable)
        }
    }

    func testDeniedTagSaveKeepsEditLocallyWithNotice() async {
        for error: any Error in [SourceFileMutationError.permissionDenied, SourceFileMutationError.readOnly,
                                 POSIXError(.EROFS), CloudDriveError.permissionDenied(.fileWrite)] {
            let original = song()
            var edited = original
            edited.title = "Edited title"
            let report = await TagMetadataWritebackCoordinator.write(mode: .embedded,
                connector: DeniedMetadataConnector(error: error), original: original, updated: edited, coverData: nil)
            XCTAssertFalse(report.shouldAbortLocalSave, "\(error)")
            XCTAssertFalse(report.remoteMutationOccurred)
            XCTAssertEqual(report.updatedSong.title, "Edited title")
            XCTAssertEqual(report.fields.first(where: { $0.field == .title })?.disposition, .localOnly)
            XCTAssertNotNil(report.issueMessage, "Must disclose local-only persistence")
        }
    }

    func testUncertainTagFailuresStillAbortSave() async {
        for error: any Error in [URLError(.timedOut), CancellationError(), SourceError.authenticationFailed,
                                 EmbeddedMetadataWritebackSourceError.conflict,
                                 EmbeddedMetadataWritebackSourceError.remoteVerificationFailed] {
            let original = song()
            var edited = original
            edited.title = "Edited title"
            let report = await TagMetadataWritebackCoordinator.write(mode: .embedded,
                connector: DeniedMetadataConnector(error: error), original: original, updated: edited, coverData: nil)
            XCTAssertTrue(report.shouldAbortLocalSave, "\(error)")
            XCTAssertFalse(report.remoteMutationOccurred)
        }
    }

    func testEmbeddedCoordinatorRetainsWriteDenialCause() async {
        let original = song()
        do {
            _ = try await EmbeddedMetadataWritebackCoordinator.write(
                adapter: DeniedMetadataConnector(error: SourceFileMutationError.permissionDenied),
                original: original, updated: original, coverData: nil)
            XCTFail("Expected permission denial")
        } catch {
            XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), .permissionDenied)
        }
    }

    func testCircuitPausesQueuedWritesButNewExplicitRunCanRetry() async {
        let circuit = SidecarWriteCircuitBreaker()
        let acquired = await circuit.acquire(sourceID: "source")
        XCTAssertTrue(acquired)
        let queued = Task { await circuit.acquire(sourceID: "source") }
        await Task.yield()
        let opened = await circuit.release(sourceID: "source", sourceUnavailable: true)
        XCTAssertTrue(opened)
        let allowed = await queued.value
        XCTAssertFalse(allowed)
        let other = await circuit.acquire(sourceID: "other")
        XCTAssertTrue(other, "A denied source must not disable other sources")
        await circuit.resetIdleUnavailableSources()
        let retried = await circuit.acquire(sourceID: "source")
        XCTAssertTrue(retried)
    }

    func testPermissionAtReadbackOrInspectionCannotClaimLocalOnlySave() async {
        for stage in [EmbeddedMetadataWritebackStage.readback, .inspect, .download, .edit] {
            let error = EmbeddedMetadataCoordinatedWritebackError.accessDenied(
                source: "WebDAV", stage: stage, reason: .permissionDenied)
            XCTAssertTrue(MetadataWriteFailurePolicy.stopsSourceWrites(error))
            XCTAssertFalse(MetadataWriteFailurePolicy.allowsLocalSave(error))
        }
        XCTAssertTrue(MetadataWriteFailurePolicy.allowsLocalSave(
            EmbeddedMetadataCoordinatedWritebackError.accessDenied(source: "WebDAV", stage: .replace, reason: .readOnly)))
        XCTAssertFalse(MetadataWriteFailurePolicy.allowsLocalSave(CloudDriveError.permissionDenied(.fileRead)))
        let uncertain = EmbeddedMetadataCoordinatedWritebackError.accessDenied(source: "WebDAV", stage: .readback, reason: .permissionDenied)
        let wrapper = NSError(domain: "fixture", code: 1, userInfo: [NSUnderlyingErrorKey: uncertain])
        XCTAssertFalse(MetadataWriteFailurePolicy.allowsLocalSave(wrapper))
    }

    func testFTPWriteRejectionStopsBatchWithoutInventingPermissionOrChangingReads() {
        for code in [550, 553] {
            let rejection = FTPSource.sourceError(for: FTPClientError.replyFailure(command: "STOR", code: code, message: "Rejected"),
                path: "/song.lrc", isDirectory: false)
            XCTAssertTrue(MetadataWriteFailurePolicy.stopsSourceWrites(rejection))
            XCTAssertFalse(MetadataWriteFailurePolicy.allowsLocalSave(rejection), "FTP cannot distinguish ACLs from a missing path")
            let read = FTPSource.sourceError(for: FTPClientError.replyFailure(command: "RETR", code: code, message: "Missing"),
                path: "/song.lrc", isDirectory: false)
            if case SourceError.fileNotFound = read {} else { XCTFail("Read behavior must stay unchanged") }
        }
    }

    func testS3AccessDeniedIsDistinctFromSignatureFailure() {
        for code in ["AccessDenied", "SignatureDoesNotMatch", "ExpiredToken", "InvalidAccessKeyId"] {
            let error = S3Source.uploadAccessError(status: 403, body: Data("<Error><Code>\(code)</Code></Error>".utf8))
            XCTAssertTrue(MetadataWriteFailurePolicy.stopsSourceWrites(error))
            XCTAssertEqual(MetadataWriteFailurePolicy.allowsLocalSave(error), code == "AccessDenied")
        }
    }

    func testDriveQuotaAndRateLimitsDoNotBecomeWritePermissionFailures() throws {
        for reason in ["insufficientFilePermissions", "insufficientPermissions", "rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"] {
            let body = try JSONSerialization.data(withJSONObject: ["error": ["errors": [["reason": reason]]]])
            let error = GoogleDriveSource.sidecarUploadError(status: 403, body: body)
            XCTAssertEqual(MetadataWriteFailurePolicy.allowsLocalSave(error), reason.hasPrefix("insufficient"))
        }
        XCTAssertFalse(MetadataWriteFailurePolicy.allowsLocalSave(
            GoogleDriveSource.sidecarUploadError(status: 403, body: Data("{}".utf8))))
    }

    func testOneDriveConditionalAccessIsNotReadOnly() throws {
        for code in ["accessDenied", "insufficient_claims", "unauthenticated", "activityLimitReached"] {
            let body = try JSONSerialization.data(withJSONObject: ["error": ["code": code]])
            let error = OneDriveSource.uploadAccessError(status: 403, body: body)
            XCTAssertEqual(MetadataWriteFailurePolicy.allowsLocalSave(error), code == "accessDenied")
        }
        let body = try JSONSerialization.data(withJSONObject: ["error": ["code": "accessDenied", "innerError": ["code": "insufficient_claims"]]])
        XCTAssertFalse(MetadataWriteFailurePolicy.allowsLocalSave(OneDriveSource.uploadAccessError(status: 403, body: body)))
    }

    func testDropboxUploadPermissionIsDistinctFromOther409Responses() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://readonly.invalid/upload")!,
            statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil))
        for reason in ["no_write_permission", "conflict", "insufficient_space", "too_many_write_operations"] {
            for field in ["reason", "path"] {
                let data = try JSONSerialization.data(withJSONObject: ["error": [".tag": "path", field: [".tag": reason]]])
                do {
                    _ = try DropboxSource.confirmedUploadMetadata(data: data, response: response)
                    XCTFail("Rejected upload must fail")
                } catch {
                    XCTAssertEqual(MetadataWriteFailurePolicy.stopsSourceWrites(error), reason == "no_write_permission")
                    XCTAssertEqual(MetadataWriteFailurePolicy.allowsLocalSave(error), reason == "no_write_permission")
                }
            }
        }
    }

    func testWebDAVPUTDenialStopsFollowingLyricsRequestThroughRealConnector() async throws {
        for status in [403, 405] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReadOnlyDAVURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let id = UUID().uuidString
            let connector = WebDAVSource(sourceID: id, host: "readonly.invalid", useSsl: true,
                                         username: "", password: "", mutationSession: session)
            var track = song()
            track.filePath = "/\(status)/\(id)/song.flac"
            let result = await SidecarWriteService.shared.writeSidecars(for: track, using: connector,
                coverData: Data([1]), lyricsLines: [LyricLine(timestamp: 1, text: "Keep my lyrics")])
            XCTAssertTrue(result.sourceUnavailable)
            XCTAssertTrue(result.coverWriteDenied)
            XCTAssertFalse(result.coverWritten)
            XCTAssertFalse(result.lyricsWritten)
            let methods = ReadOnlyDAVURLProtocol.methods(id: id)
            XCTAssertEqual(methods, ["PROPFIND", "PUT"], "No lyrics upload or write-verification requests after denial")
            await connector.disconnect()
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
                .appendingPathComponent("primuse_webdav_cache").appendingPathComponent(id))
        }
    }

    func testLyricsReadbackDenialIsNotReportedAsSafeLocalFallback() async throws {
        let connector = DeniedMetadataConnector(error: nil, readbackError: POSIXError(.EACCES))
        let result = await SidecarWriteService.shared.writeSidecars(for: song(), using: connector,
            coverData: nil, lyricsLines: [LyricLine(timestamp: 1, text: "Possibly saved remotely")])
        XCTAssertFalse(result.lyricsWritten)
        XCTAssertFalse(result.lyricsWriteDenied)
        XCTAssertTrue(result.sourceUnavailable)
        let attempts = await connector.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testLyricsTargetReadDenialIsNotReportedAsRejectedWrite() async {
        let connector = DeniedMetadataConnector(error: nil, listingError: POSIXError(.EACCES))
        let result = await SidecarWriteService.shared.writeSidecars(for: song(), using: connector,
            coverData: nil, lyricsLines: [LyricLine(timestamp: 1, text: "Keep my lyrics")])
        XCTAssertFalse(result.lyricsWritten)
        XCTAssertFalse(result.lyricsWriteDenied, "A failed target read does not prove a write was rejected")
        XCTAssertTrue(result.sourceUnavailable)
        let attempts = await connector.attempts
        XCTAssertEqual(attempts, 0)
    }

    func testSynologyFileStationCodesAndWrappedPOSIXErrors() {
        for code in [105, 407, 411] {
            let error = SynologyError.fileOperationError(code: code, message: "Rejected")
            XCTAssertTrue(MetadataWriteFailurePolicy.stopsSourceWrites(error))
            XCTAssertTrue(MetadataWriteFailurePolicy.allowsLocalSave(error))
        }
        for code in [402, 408, 415, 416] {
            XCTAssertFalse(MetadataWriteFailurePolicy.allowsLocalSave(SynologyError.fileOperationError(code: code, message: "Failure")))
        }
        let wrapped = NSError(domain: "fixture", code: 1, userInfo: [NSUnderlyingErrorKey: POSIXError(.EROFS)])
        XCTAssertTrue(MetadataWriteFailurePolicy.stopsSourceWrites(wrapped))
    }

    @MainActor
    func testArtistMergeKeepsCollaboratorsAndPersistsWhenSourceFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtistMerge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ArtistMerge-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        let player = AudioPlayerService(library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Merging must not start playback") })
        var original = song()
        original.artistName = "English B; Guest"
        original.albumArtistName = "English B"
        original.albumTitle = "Album"
        original.duration = 180
        library.addSongs([original])
        let source = MusicSource(id: original.sourceID, name: "Fixture", type: .webdav, host: "readonly.invalid")
        let connector = DeniedMetadataConnector(error: URLError(.timedOut))
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let updated = ArtistMergePolicy.applying(to: original, names: ["English B", "中文A"], canonicalName: "中文A")
        let outcome = await BatchTagEditService.apply([(original, updated)], coverData: nil,
            sourceManager: manager, library: library, player: player,
            keepsLocalEditsOnWriteFailure: true) { _, _ in }
        XCTAssertEqual(outcome.applied.count, 1)
        XCTAssertEqual(outcome.localOnlySongIDs, [original.id])
        XCTAssertTrue(outcome.failures.isEmpty)
        let stored = try XCTUnwrap(library.song(id: original.id))
        XCTAssertEqual(stored.sourceArtistNames, ["中文A", "Guest"])
        XCTAssertEqual(stored.albumArtistName, "中文A")
        XCTAssertNotNil(stored.userMetadataEditedAt)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persistence failed") }
        let restored = MusicLibrary(storageDirectory: directory)
        XCTAssertEqual(restored.song(id: original.id)?.artistName, "中文A; Guest")
        XCTAssertEqual(SongUserMetadataPolicy.preservingUserEdits(from: stored, in: original).albumArtistName, "中文A")
    }

    @MainActor
    func testLyricsEditFallsBackToDurableLocalOverrideOnlyOnWriteDenial() async throws {
        let cases: [(failure: (any Error)?, saves: Bool)] = [
            (SourceFileMutationError.permissionDenied, true),
            (POSIXError(.EROFS), true), (URLError(.timedOut), false),
            (EmbeddedMetadataWritebackSourceError.conflict, false), (nil, true)
        ]
        for testCase in cases {
            let original = song()
            let source = MusicSource(id: original.sourceID, name: "Fixture", type: .webdav, host: "readonly.invalid")
            let connector = DeniedMetadataConnector(error: testCase.failure)
            let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
            // The editor publishes accepted tag edits before lyrics merge
            // into the latest library row, including local-only tag edits.
            var accepted = original
            accepted.title = "Accepted local title"
            accepted.userMetadataEditedAt = Date(timeIntervalSince1970: 1_000)
            library.addSongs([accepted])
            let preflight = try await SidecarWriteService.shared.preflightLyricsWrite(for: original, using: connector)
            let outcome = await LyricsWriteback.save(text: "[00:01.00]Keep my edit", for: original,
                mode: .sidecar(preflight), allowRemoval: false, sourceSnapshot: .absent,
                sourceManager: manager, library: library)
            XCTAssertEqual(outcome.succeeded, testCase.saves, "\(String(describing: testCase.failure)): \(String(describing: outcome.errorMessage))")
            let stored = try XCTUnwrap(library.song(id: original.id))
            XCTAssertEqual(stored.title, accepted.title)
            XCTAssertEqual(stored.userMetadataEditedAt, accepted.userMetadataEditedAt)
            let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: original.id)
            if testCase.saves {
                XCTAssertEqual(outcome.updatedSong.title, accepted.title)
                XCTAssertEqual(stored.lyricsText, "Keep my edit")
                XCTAssertEqual(cached?.first?.text, "Keep my edit")
                XCTAssertEqual(cached?.first?.documentIsLocalOverride, testCase.failure != nil)
                XCTAssertEqual(outcome.persistence, testCase.failure == nil ? .sidecar : .localOnly)
            } else {
                XCTAssertNil(cached)
            }
            let attempts = await connector.attempts
            XCTAssertEqual(attempts, 1, "Local fallback must not issue a second remote write")
            _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: original.id)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Only the remote filesystem is replaced; services above this connector are production code.
private actor DeniedMetadataConnector: EmbeddedMetadataWritebackAdapter {
    nonisolated let sourceID = "readonly-fixture"
    nonisolated let supportsSidecarWriting = true
    let error: (any Error)?
    let readbackError: (any Error)?
    let listingError: (any Error)?
    var files: [String: Data] = [:]
    private(set) var attempts = 0
    init(error: (any Error)?, readbackError: (any Error)? = nil, listingError: (any Error)? = nil) {
        self.error = error
        self.readbackError = readbackError
        self.listingError = listingError
    }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        if let listingError { throw listingError }
        return files.map { RemoteFileItem(name: ($0.key as NSString).lastPathComponent, path: $0.key,
                                  isDirectory: false, size: Int64($0.value.count), modifiedDate: nil) }
    }
    func localURL(for path: String) async throws -> URL { throw error ?? SourceError.fileNotFound(path) }
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        if let readbackError { throw readbackError }
        return files[path] ?? Data()
    }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func writeFile(data: Data, to path: String) async throws {
        attempts += 1
        if let error { throw error }
        files[path] = data
    }
    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState { throw error ?? SourceError.fileNotFound(path) }
    func replaceMetadataFile(at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState) async throws { throw error ?? SourceError.fileNotFound(path) }
    func writeEmbeddedMetadata(original: Song, updated: Song, coverData: Data?, lyrics: EmbeddedLyricsEdit,
                               writesTextTags: Bool) async throws -> EmbeddedMetadataWritebackResult { throw error ?? SourceError.fileNotFound(original.filePath) }
}

private final class ReadOnlyDAVURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String: [String]] = [:]
    static func methods(id: String) -> [String] { lock.withLock { requests.removeValue(forKey: id) ?? [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 3 else { return }
        let method = request.httpMethod ?? "GET"
        Self.lock.withLock { Self.requests[String(parts[1]), default: []].append(method) }
        let status = method == "PROPFIND" ? 404 : (Int(parts[0]) ?? 500)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ArtistMergeBackgroundTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        let library: MusicLibrary
        let player: AudioPlayerService
        let manager: SourceManager
        let connector: GatedArtistMergeConnector
        let songs: [Song]
        let started: [XCTestExpectation]

        var changes: [(original: Song, updated: Song)] {
            songs.map { ($0, ArtistMergePolicy.applying(to: $0, names: ["Before", "After"], canonicalName: "After")) }
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func fixture(count: Int, automaticallyCompletes: Set<String> = []) throws -> Fixture {
        let suite = "ArtistMergeBackground-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        let player = AudioPlayerService(library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Merging must not start playback") })
        addTeardownBlock { [weak library] in
            // SQLite must release its live WAL before removing the fixture.
            if library == nil { try? FileManager.default.removeItem(at: directory) }
        }
        let source = MusicSource(id: UUID().uuidString, name: "Fixture", type: .webdav, host: "merge.invalid")
        let songs = (0..<count).map { index in
            var song = Song(id: "\(suite)-\(index)", title: "Song \(index)", fileFormat: .flac,
                            filePath: "\(index)", sourceID: source.id)
            song.artistName = "Before; Guest"
            song.albumArtistName = "Before"
            return song
        }
        library.addSongs(songs)
        let started = (0..<count).map { expectation(description: "Write \($0) started") }
        let connector = GatedArtistMergeConnector(started: started, automaticallyCompletes: automaticallyCompletes)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        return Fixture(directory: directory, defaults: defaults, suite: suite, library: library,
                       player: player, manager: manager, connector: connector, songs: songs, started: started)
    }

    func testCancelBeforeStartingDoesNotWriteOrApplyLocalFallback() async throws {
        let f = try fixture(count: 5)
        defer { f.cleanUp() }
        f.started.forEach { $0.isInverted = true }
        let result = await BatchTagEditService.apply(f.changes, coverData: nil,
            sourceManager: f.manager, library: f.library, player: f.player,
            keepsLocalEditsOnWriteFailure: true, shouldCancel: { true }) { _, _ in }
        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertTrue(result.localOnlySongIDs.isEmpty)
        XCTAssertTrue(f.library.songs.allSatisfy { $0.artistName == "Before; Guest" })
        let starts = await f.connector.startedPaths
        XCTAssertTrue(starts.isEmpty)
        await fulfillment(of: f.started, timeout: 0.01)
    }

    func testSlowFirstFileDoesNotBlockProgressOrIncrementalSaving() async throws {
        let f = try fixture(count: 30, automaticallyCompletes: Set((1..<30).map(String.init)))
        defer { f.cleanUp() }
        let othersDone = expectation(description: "Other files finish while first is pending")
        var progress: [Int] = []
        let run = Task {
            await BatchTagEditService.apply(f.changes, coverData: nil,
                sourceManager: f.manager, library: f.library, player: f.player,
                keepsLocalEditsOnWriteFailure: true, publishesIncrementally: true) { done, _ in
                    progress.append(done)
                    if done == 29 { othersDone.fulfill() }
                }
        }
        await fulfillment(of: [othersDone], timeout: 5)
        XCTAssertGreaterThanOrEqual(f.library.songs.filter { $0.albumArtistName == "After" }.count, 24)
        XCTAssertEqual(f.library.song(id: f.songs[0].id)?.albumArtistName, "Before")
        await f.connector.release("0")
        let result = await run.value
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.applied.count, 30)
        XCTAssertEqual(progress, Array(0...30))
        XCTAssertEqual(result.applied.map(\.id), result.originals.map(\.id))
        let maximum = await f.connector.maximumInFlight
        XCTAssertLessThanOrEqual(maximum, BatchTagEditService.concurrency)
        await fulfillment(of: f.started, timeout: 1)
    }

    func testCancelStopsNewWritesAndKeepsCompletedFilesAndConcurrentEdits() async throws {
        let f = try fixture(count: 8)
        defer { f.cleanUp() }
        f.started.dropFirst(3).forEach { $0.isInverted = true }
        let stopped = expectation(description: "Stop requested on first completion")
        var cancel = false
        let run = Task {
            await BatchTagEditService.apply(f.changes, coverData: nil,
                sourceManager: f.manager, library: f.library, player: f.player,
                keepsLocalEditsOnWriteFailure: true, publishesIncrementally: true,
                shouldCancel: { cancel }) { done, _ in
                    if done == 1 {
                        cancel = true
                        stopped.fulfill()
                    }
                }
        }
        await fulfillment(of: Array(f.started.prefix(3)), timeout: 5)
        await f.connector.release("1")
        await fulfillment(of: [stopped], timeout: 5)
        var changedElsewhere = f.songs[0]
        changedElsewhere.title = "Edited while merging"
        f.library.replaceSongs([changedElsewhere])
        await f.connector.releaseAll()
        let result = await run.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(Set(result.applied.map(\.id)), Set(f.songs.prefix(3).map(\.id)))
        XCTAssertTrue(result.localOnlySongIDs.isEmpty)
        XCTAssertEqual(f.library.song(id: f.songs[0].id)?.title, "Edited while merging")
        XCTAssertEqual(f.library.song(id: f.songs[0].id)?.sourceArtistNames, ["After", "Guest"])
        for song in f.songs.dropFirst(3) {
            XCTAssertEqual(f.library.song(id: song.id)?.artistName, song.artistName)
            XCTAssertNil(f.library.song(id: song.id)?.userMetadataEditedAt)
        }
        let starts = await f.connector.startedPaths
        XCTAssertEqual(starts, Set(["0", "1", "2"]))
        await fulfillment(of: Array(f.started.dropFirst(3)), timeout: 0.01)
        guard case .success = await f.library.persistNowAndWait() else { return XCTFail("Persistence failed") }
        let restored = MusicLibrary(storageDirectory: f.directory, deferredMaintenanceAllowed: { false })
        await restored.whenReady()
        XCTAssertEqual(restored.song(id: f.songs[0].id)?.artistName, "After; Guest")
        XCTAssertEqual(restored.song(id: f.songs[3].id)?.artistName, "Before; Guest")
    }

    func testServiceOwnsRunAfterCallerLeavesAndRejectsOverlappingMerge() async throws {
        let f = try fixture(count: 5)
        defer { f.cleanUp() }
        f.started.dropFirst(3).forEach { $0.isInverted = true }
        let service = ArtistMergeService.shared
        let caller = Task {
            service.start(songIDs: f.songs.map(\.id), names: ["Before", "After"], canonicalName: "After",
                          library: f.library, sourceManager: f.manager, player: f.player)
        }
        let accepted = await caller.value
        XCTAssertTrue(accepted)
        caller.cancel()
        await fulfillment(of: Array(f.started.prefix(3)), timeout: 5)
        XCTAssertTrue(service.isRunning)
        #if canImport(UIKit)
        try await renderAndCloseMergeSheet(f)
        XCTAssertTrue(service.isRunning, "Closing the sheet must leave the service running")
        #endif
        XCTAssertFalse(service.start(songIDs: f.songs.map(\.id), names: ["Before", "Other"], canonicalName: "Other",
                                     library: f.library, sourceManager: f.manager, player: f.player))
        service.cancel()
        service.clearResult()
        XCTAssertTrue(service.isRunning, "Do not start another merge until remote writes have drained")
        await f.connector.releaseAll()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while service.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(service.isRunning)
        XCTAssertTrue(service.outcome?.wasCancelled == true)
        XCTAssertEqual(service.outcome?.applied.count, 3)
        XCTAssertEqual(service.progress.done, 3)
        XCTAssertEqual(service.canonicalName, "After")
        await fulfillment(of: Array(f.started.dropFirst(3)), timeout: 0.01)
        service.clearResult()
        XCTAssertNil(service.outcome)
    }

    #if canImport(UIKit)
    private func renderAndCloseMergeSheet(_ f: Fixture) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ArtistMergeView()
            .environment(f.library).environment(f.manager).environment(f.player)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "artist-merge-background-controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

}

private actor GatedArtistMergeConnector: EmbeddedMetadataWritebackAdapter {
    nonisolated let sourceID = "merge-fixture"
    let started: [XCTestExpectation]
    let automaticallyCompletes: Set<String>
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var startedPaths: Set<String> = []
    private(set) var maximumInFlight = 0
    private var inFlight = 0
    private var allReleased = false

    init(started: [XCTestExpectation], automaticallyCompletes: Set<String>) {
        self.started = started
        self.automaticallyCompletes = automaticallyCompletes
    }

    func release(_ path: String) { waiting.removeValue(forKey: path)?.resume() }
    func releaseAll() {
        allReleased = true
        let continuations = Array(waiting.values)
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data { Data() }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState { throw SourceError.fileNotFound(path) }
    func replaceMetadataFile(at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState) async throws { throw SourceError.fileNotFound(path) }

    func writeEmbeddedMetadata(original: Song, updated: Song, coverData: Data?, lyrics: EmbeddedLyricsEdit,
                               writesTextTags: Bool) async throws -> EmbeddedMetadataWritebackResult {
        let path = original.filePath
        startedPaths.insert(path)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if allReleased || automaticallyCompletes.contains(path) {
            started[Int(path)!].fulfill()
        } else {
            await withCheckedContinuation { continuation in
                waiting[path] = continuation
                started[Int(path)!].fulfill()
            }
        }
        return EmbeddedMetadataWritebackResult(fileSize: 100, modifiedDate: Date(), revision: "edited-\(path)",
            fileSHA256: "fixture", verification: EmbeddedMetadataVerification(
                title: updated.title, artist: updated.artistName, albumTitle: updated.albumTitle,
                genre: updated.genre, year: updated.year, trackNumber: updated.trackNumber,
                discNumber: updated.discNumber, coverData: nil, albumArtist: updated.albumArtistName))
    }
}

@MainActor
final class LibraryReleaseCategoryIndexTests: XCTestCase {
    private func fixture() async throws -> MusicLibrary {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseIndex-\(UUID())")
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        addTeardownBlock { [weak library] in
            if library == nil { try? FileManager.default.removeItem(at: directory) }
        }
        let songs = (0..<3).map { number in
            var song = Song(id: "release-\(number)", title: "Track \(number)",
                            albumTitle: number < 2 ? "Show - EP" : "Other", artistName: "Artist",
                            albumArtistName: "Artist", fileFormat: .flac, filePath: "\(number).flac",
                            sourceID: number == 1 ? "secondary" : "primary")
            if number == 0 { song.contentMetadata = SongContentMetadata(releaseType: "album") }
            if number == 1 { song.contentMetadata = SongContentMetadata(releaseType: "live") }
            return song
        }
        library.addSongs(songs)
        await library.waitForPendingIndex()
        return library
    }

    private func album(_ library: MusicLibrary, songID: String = "release-0") throws -> Album {
        let id = try XCTUnwrap(library.song(id: songID)?.albumID)
        return try XCTUnwrap(library.visibleAlbum(id: id))
    }

    func testReleaseTagChangesPatchAllThreeMetadataWritePaths() async throws {
        let library = try await fixture()
        let album = try album(library)
        XCTAssertEqual(library.automaticReleaseCategories(for: album), [.album, .live])
        var first = try XCTUnwrap(library.song(id: "release-0"))
        first.contentMetadata = nil
        library.replaceSong(first)
        XCTAssertEqual(library.automaticReleaseCategories(for: album), [.live])
        var second = try XCTUnwrap(library.song(id: "release-1"))
        second.contentMetadata = nil
        library.replaceSongs([second], maintenance: .deferred)
        XCTAssertEqual(library.automaticReleaseCategories(for: album), [.singleEP])
        first.contentMetadata = SongContentMetadata(releaseType: "album")
        await library.replaceSongsPreparedOffMain([first], maintenance: .deferred)
        XCTAssertEqual(library.automaticReleaseCategories(for: album), [.album])
        let revision = library.releaseCategoryRevision
        let membership = library.releaseCategoryMembershipRevision
        library.updateLyricsText([first.id: "Unrelated lyrics"])
        first = try XCTUnwrap(library.song(id: first.id))
        first.sampleRate = 48_000
        library.replaceSongs([first], maintenance: .deferred)
        XCTAssertEqual(library.releaseCategoryRevision, revision)
        XCTAssertEqual(library.releaseCategoryMembershipRevision, membership)
    }

    func testHiddenAndRemovedSourcesDoNotContributeReleaseTypes() async throws {
        let library = try await fixture()
        let album = try album(library)
        await library.updateDisabledSourceIDsInBackground(["secondary"])
        XCTAssertEqual(library.automaticReleaseCategories(for: album), [.album])
        await library.updateDisabledSourceIDsInBackground([])
        XCTAssertEqual(library.automaticReleaseCategories(for: album), [.album, .live])
        await library.removeSongsForSource("primary")
        XCTAssertEqual(library.automaticReleaseCategories(for: album), [.live])
        await library.waitForPendingIndex()
        XCTAssertEqual(library.automaticReleaseCategories(for: album), [.live])
    }

    func testManualChoiceFollowsRenamedAlbumAndResetRejectsPendingResult() async throws {
        let library = try await fixture()
        let suite = "ReleaseIndexOverrides-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumReleaseCategoryStore(defaults: defaults)
        let index = LibraryReleaseCategoryIndex()
        let original = try album(library)
        store.set([.singleEP], albumID: original.id, songIDs: ["release-0", "release-1"])
        let renamed = library.songs(forAlbum: original.id).map { value in
            var song = value
            song.albumTitle = "Renamed"
            return song
        }
        library.replaceSongs(renamed)
        await library.waitForPendingIndex()
        let current = try album(library)
        XCTAssertNotEqual(current.id, original.id)
        _ = index.categories(for: current, in: library, store: store)
        await index.waitForPendingResolution()
        XCTAssertEqual(index.categories(for: current, in: library, store: store), [.singleEP])
        store.set([.live], albumID: current.id, songIDs: renamed.map(\.id))
        _ = index.categories(for: current, in: library, store: store)
        store.set(nil, albumID: current.id, songIDs: renamed.map(\.id))
        _ = index.categories(for: current, in: library, store: store)
        await index.waitForPendingResolution()
        XCTAssertEqual(index.categories(for: current, in: library, store: store), [.album, .live])
    }
}
