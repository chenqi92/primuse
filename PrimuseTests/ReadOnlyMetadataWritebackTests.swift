import Foundation
import PrimuseKit
import XCTest
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
