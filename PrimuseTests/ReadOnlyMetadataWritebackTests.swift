import Foundation
import PrimuseKit
import XCTest
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
            CloudDriveError.permissionDenied(.fileWrite)
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
}

/// Only the remote filesystem is replaced; services above this connector are production code.
private actor DeniedMetadataConnector: EmbeddedMetadataWritebackAdapter {
    nonisolated let sourceID = "readonly-fixture"
    nonisolated let supportsSidecarWriting = true
    let error: any Error
    private(set) var attempts = 0
    init(error: any Error) { self.error = error }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw error }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func writeFile(data: Data, to path: String) async throws { attempts += 1; throw error }
    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState { throw error }
    func replaceMetadataFile(at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState) async throws { throw error }
    func writeEmbeddedMetadata(original: Song, updated: Song, coverData: Data?, lyrics: EmbeddedLyricsEdit,
                               writesTextTags: Bool) async throws -> EmbeddedMetadataWritebackResult { throw error }
}
