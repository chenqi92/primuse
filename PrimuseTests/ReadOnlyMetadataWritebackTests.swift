import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
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
            XCTAssertFalse(report.embeddedWriteFailed, "\(error)")
            XCTAssertFalse(report.remoteMutationOccurred)
            XCTAssertEqual(report.updatedSong.title, "Edited title")
            XCTAssertEqual(report.fields.first(where: { $0.field == .title })?.disposition, .localOnly)
            XCTAssertNotNil(report.issueMessage, "Must disclose local-only persistence")
        }
    }

    func testLocalOnlyTagSaveDisclosesPersistenceWithoutAttemptingUpload() async {
        let connector = DeniedMetadataConnector(error: SourceFileMutationError.readOnly)
        let original = song()
        var edited = original
        edited.title = "Edited title"
        let report = await TagMetadataWritebackCoordinator.write(mode: .localOnly, connector: connector,
            original: original, updated: edited, coverData: nil)
        XCTAssertFalse(report.embeddedWriteFailed)
        XCTAssertFalse(report.remoteMutationOccurred)
        XCTAssertEqual(report.updatedSong.title, edited.title)
        XCTAssertNotNil(report.issueMessage)
        let attempts = await connector.attempts
        XCTAssertEqual(attempts, 0)
        let unchanged = await TagMetadataWritebackCoordinator.write(mode: .localOnly, connector: connector,
            original: original, updated: original, coverData: nil)
        XCTAssertNil(unchanged.issueMessage)
    }

    func testUncertainTagFailuresAreReportedAsFailedWrites() async {
        for error: any Error in [URLError(.timedOut), CancellationError(), SourceError.authenticationFailed,
                                 EmbeddedMetadataWritebackSourceError.conflict,
                                 EmbeddedMetadataWritebackSourceError.remoteVerificationFailed] {
            let original = song()
            var edited = original
            edited.title = "Edited title"
            let report = await TagMetadataWritebackCoordinator.write(mode: .embedded,
                connector: DeniedMetadataConnector(error: error), original: original, updated: edited, coverData: nil)
            XCTAssertTrue(report.embeddedWriteFailed, "\(error)")
            XCTAssertFalse(report.remoteMutationOccurred)
        }
    }

    @MainActor
    private func editingFixture() throws -> (library: MusicLibrary, player: AudioPlayerService, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TagKeep-\(UUID())")
        let suite = "TagKeep-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        let player = AudioPlayerService(library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Editing tags must not start playback") })
        return (library, player, {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    /// 写进文件失败(连不上、超时):整条修改照样存在 Primuse,列进补写清单,不算失败。
    @MainActor
    func testBatchEditKeepsTheWholeEditWhenTheFileWriteFails() async throws {
        let fixture = try editingFixture()
        defer { fixture.cleanup() }
        let original = song()
        fixture.library.addSongs([original])
        let source = MusicSource(id: original.sourceID, name: "Fixture", type: .webdav, host: "offline.invalid")
        let manager = SourceManager(sourcesProvider: { [source] },
                                    connectorFactory: { _ in DeniedMetadataConnector(error: URLError(.timedOut)) })
        var updated = original
        updated.title = "Edited title"
        updated.albumTitle = "Edited album"
        let outcome = await BatchTagEditService.apply([(original, updated)], coverData: nil,
            sourceManager: manager, library: fixture.library, player: fixture.player) { _, _ in }
        defer { PendingTagWritebackStore.shared.remove(songIDs: [original.id]) }
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.localOnlySongIDs, [original.id])
        let entry = try XCTUnwrap(outcome.localOnlyWrites.first)
        XCTAssertTrue(entry.canRetry)
        XCTAssertTrue(entry.missedWrite)
        XCTAssertTrue(PendingTagWritebackStore.shared.entries.contains { $0.songID == original.id })
        let stored = try XCTUnwrap(fixture.library.song(id: original.id))
        XCTAssertEqual(stored.title, "Edited title")
        XCTAssertEqual(stored.albumTitle, "Edited album")
        XCTAssertNotNil(stored.userMetadataEditedAt)
    }

    /// 只读音乐源(Apple Music 资料库)不连音乐源,修改存在 Primuse,也不进补写清单。
    @MainActor
    func testReadOnlySourceSavesWithoutConnectingOrQueueingRetries() async throws {
        let fixture = try editingFixture()
        defer { fixture.cleanup() }
        let original = Song(id: UUID().uuidString, title: "Original", fileFormat: .aac,
                            filePath: "i.fixture", sourceID: AppleMusicLibraryIdentity.sourceID)
        fixture.library.addSongs([original])
        let source = MusicSource(id: AppleMusicLibraryIdentity.sourceID, name: "Apple Music", type: .appleMusic)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in
            UnsupportedSourceConnector(sourceID: AppleMusicLibraryIdentity.sourceID, sourceType: .appleMusic)
        })
        var updated = original
        updated.title = "Edited title"
        let report = try await manager.writeTagMetadata(original: original, updated: updated, coverData: Data([1]))
        XCTAssertEqual(report.mode, .localOnly)
        XCTAssertFalse(report.hasFailures)
        XCTAssertEqual(report.keepOutcome, TagWritebackKeepPolicy.Outcome(isLocalOnly: true, missedWrite: false, canRetry: false))
        XCTAssertNotNil(report.issueMessage)

        let outcome = await BatchTagEditService.apply([(original, updated)], coverData: nil,
            sourceManager: manager, library: fixture.library, player: fixture.player) { _, _ in }
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.localOnlyWrites.map(\.canRetry), [false])
        XCTAssertFalse(PendingTagWritebackStore.shared.entries.contains { $0.songID == original.id })
        XCTAssertEqual(fixture.library.song(id: original.id)?.title, "Edited title")
        XCTAssertNotNil(fixture.library.song(id: original.id)?.userMetadataEditedAt)
    }

    /// 音乐源连不上:按写入失败报,不抛错;旁路文件源只改文字时根本不连。
    @MainActor
    func testUnreachableSourceReportsFailedFieldsInsteadOfThrowing() async throws {
        let original = song()
        var updated = original
        updated.title = "Edited title"
        for type in [MusicSourceType.webdav, .jellyfin] {
            let source = MusicSource(id: original.sourceID, name: "Fixture", type: type, host: "offline.invalid")
            let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in
                UnsupportedSourceConnector(sourceID: original.sourceID, sourceType: type)
            })
            let report = try await manager.writeTagMetadata(original: original, updated: updated, coverData: nil)
            guard case .failed? = report.fields.first(where: { $0.field == .title })?.disposition else {
                return XCTFail("Title should be reported as not written for \(type)")
            }
            XCTAssertEqual(report.keepOutcome.canRetry, true, "\(type)")
        }
        var cueTrack = original
        cueTrack.cueSheetPath = "/Music/album.cue"
        cueTrack.cueStartTime = 0
        var cueEdit = cueTrack
        cueEdit.title = "Edited title"
        let source = MusicSource(id: original.sourceID, name: "Fixture", type: .webdav, host: "offline.invalid")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in
            UnsupportedSourceConnector(sourceID: original.sourceID, sourceType: .webdav)
        })
        let report = try await manager.writeTagMetadata(original: cueTrack, updated: cueEdit, coverData: nil)
        XCTAssertEqual(report.mode, .sidecarOnly)
        XCTAssertFalse(report.hasFailures)
        XCTAssertEqual(report.keepOutcome, TagWritebackKeepPolicy.Outcome(isLocalOnly: true, missedWrite: false, canRetry: false))
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
            publishesOntoLiveRows: true) { _, _ in }
        XCTAssertEqual(outcome.applied.count, 1)
        XCTAssertEqual(outcome.localOnlySongIDs, [original.id])
        XCTAssertTrue(outcome.failures.isEmpty)
        let localOnly = try XCTUnwrap(outcome.localOnlyWrites.first)
        XCTAssertEqual(localOnly.filePath, original.filePath)
        XCTAssertEqual(localOnly.sourceID, original.sourceID)
        XCTAssertEqual(localOnly.original.artistName, "English B; Guest")
        XCTAssertNotNil(localOnly.reason)
        XCTAssertTrue(localOnly.canRetry)
        XCTAssertTrue(outcome.noticesOutsideLocalOnly.isEmpty)
        let stored = try XCTUnwrap(library.song(id: original.id))
        XCTAssertEqual(stored.sourceArtistNames, ["中文A", "Guest"])
        XCTAssertEqual(stored.albumArtistName, "中文A")
        XCTAssertNotNil(stored.userMetadataEditedAt)

        // The source still fails: the song stays listed, the merged values
        // stay in the library, and undo still has exactly one target.
        let retry = await BatchTagEditService.retryLocalOnlyWrites(outcome.localOnlyWrites,
            sourceManager: manager, library: library, player: player) { _, _ in }
        var merged = outcome
        let rewritten = merged.mergeRetry(retry)
        XCTAssertEqual(rewritten, 0)
        XCTAssertEqual(merged.localOnlySongIDs, [original.id])
        XCTAssertEqual(merged.localOnlyWrites.first?.original.artistName, "English B; Guest")
        XCTAssertEqual(merged.applied.count, 1)
        XCTAssertEqual(merged.originals.map(\.artistName), outcome.originals.map(\.artistName))
        XCTAssertEqual(library.song(id: original.id)?.sourceArtistNames, ["中文A", "Guest"])
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persistence failed") }
        let restored = MusicLibrary(storageDirectory: directory)
        XCTAssertEqual(restored.song(id: original.id)?.artistName, "中文A; Guest")
        XCTAssertEqual(SongUserMetadataPolicy.preservingUserEdits(from: stored, in: original).albumArtistName, "中文A")
    }

    func testRetryMergeDropsWrittenSongsAndKeepsUndoTargets() {
        typealias Service = BatchTagEditService
        func row(_ id: String, title: String? = nil) -> Song {
            Song(id: id, title: title ?? id, fileFormat: .flac, filePath: "/Music/\(id).flac", sourceID: "source")
        }
        func entry(_ id: String, reason: String, canRetry: Bool = true, original: Song) -> Service.LocalOnlyWrite {
            Service.LocalOnlyWrite(songID: id, title: id, artist: nil, sourceID: "source", filePath: "/Music/\(id).flac",
                                   reason: reason, canRetry: canRetry, original: original)
        }
        var outcome = Service.Outcome()
        outcome.applied = ["a", "b", "c", "d"].map { row($0) }
        outcome.originals = ["a", "b", "c", "d"].map { row($0, title: "Before \($0)") }
        outcome.localOnlyWrites = ["a", "b", "c"].map { entry($0, reason: "Timed out", original: row($0, title: "Before \($0)")) }
        outcome.noticeEntries = [
            Service.Notice(songID: "a", text: "a: Timed out"),
            Service.Notice(songID: "b", text: "b: Timed out"),
            Service.Notice(songID: "c", text: "c: Timed out"),
            Service.Notice(songID: "d", text: "d: Genre unsupported"),
        ]
        XCTAssertEqual(outcome.noticesOutsideLocalOnly, ["d: Genre unsupported"])

        // "a" went through, "b" failed again for another reason, "c" was
        // not reached (stopped before it).
        var retry = Service.Outcome()
        var written = row("a")
        written.revision = "after-retry"
        retry.applied = [written, row("b")]
        retry.originals = retry.applied
        retry.localOnlyWrites = [entry("b", reason: "Permission denied", canRetry: false, original: row("b"))]
        retry.noticeEntries = [Service.Notice(songID: "b", text: "b: Permission denied")]

        let rewritten = outcome.mergeRetry(retry)
        XCTAssertEqual(rewritten, 1)
        XCTAssertEqual(outcome.localOnlyWrites.map(\.songID), ["b", "c"])
        XCTAssertEqual(outcome.localOnlyWrites.map(\.reason), ["Permission denied", "Timed out"])
        XCTAssertEqual(outcome.localOnlyWrites.map(\.canRetry), [false, true])
        XCTAssertEqual(outcome.localOnlyWrites.map(\.original.title), ["Before b", "Before c"])
        XCTAssertEqual(outcome.applied.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(outcome.applied.first?.revision, "after-retry")
        XCTAssertEqual(outcome.originals.map(\.title), ["Before a", "Before b", "Before c", "Before d"])
        XCTAssertEqual(outcome.notices, ["c: Timed out", "d: Genre unsupported", "b: Permission denied"])
        XCTAssertEqual(outcome.noticesOutsideLocalOnly, ["d: Genre unsupported"])
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
            publishesOntoLiveRows: true, shouldCancel: { true }) { _, _ in }
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
                publishesOntoLiveRows: true, publishesIncrementally: true) { done, _ in
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
                publishesOntoLiveRows: true, publishesIncrementally: true,
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

/// Fails each embedded write with the next queued error, then succeeds.
private actor FlakyMetadataConnector: MusicSourceConnector {
    nonisolated let sourceID = "flaky-writeback"
    private var failures: [any Error]
    private(set) var attempts = 0
    init(failures: [any Error]) { self.failures = failures }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func writeEmbeddedMetadata(original: Song, updated: Song, coverData: Data?, lyrics: EmbeddedLyricsEdit,
                               writesTextTags: Bool) async throws -> EmbeddedMetadataWritebackResult {
        attempts += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        return EmbeddedMetadataWritebackResult(
            fileSize: 10, modifiedDate: Date(timeIntervalSince1970: 1), revision: "after", fileSHA256: "sha",
            verification: EmbeddedMetadataVerification(title: updated.title, artist: updated.artistName,
                albumTitle: nil, genre: nil, year: nil, trackNumber: nil, discNumber: nil, coverData: nil),
            filePath: original.filePath
        )
    }
}

final class TransientTagWriteRetryTests: XCTestCase {
    private func edit() -> (Song, Song) {
        let original = Song(id: "song", title: "Old", fileFormat: .flac, filePath: "/Music/a.flac", sourceID: "flaky-writeback")
        var edited = original
        edited.title = "New"
        return (original, edited)
    }

    func testTimeoutBeforeTheReplacementIsTriedOnceMore() async {
        let (original, edited) = edit()
        let connector = FlakyMetadataConnector(failures: [
            EmbeddedMetadataCoordinatedWritebackError.operationFailed(
                source: "SMB", stage: .download, detail: "timed out", isTransient: true),
        ])
        let report = await TagMetadataWritebackCoordinator.write(mode: .embedded, connector: connector,
            original: original, updated: edited, coverData: nil)
        let attempts = await connector.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(report.remoteMutationOccurred)
        XCTAssertEqual(report.fields.first(where: { $0.field == .title })?.disposition, .written)
    }

    func testOnlyOneRetryAndTheFirstFailureWinsOverAConflict() async {
        let (original, edited) = edit()
        let first = EmbeddedMetadataCoordinatedWritebackError.operationFailed(
            source: "SMB", stage: .replace, detail: "connection reset", isTransient: true)
        let connector = FlakyMetadataConnector(failures: [first, EmbeddedMetadataCoordinatedWritebackError.conflict])
        let report = await TagMetadataWritebackCoordinator.write(mode: .embedded, connector: connector,
            original: original, updated: edited, coverData: nil)
        let attempts = await connector.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(report.fields.first(where: { $0.field == .title })?.disposition,
                       .failed(first.localizedDescription))
    }

    func testRefusalsLocalEditsAndReadbacksAreNotRetried() async {
        let (original, edited) = edit()
        for error: any Error in [
            SourceFileMutationError.readOnly,
            EmbeddedMetadataCoordinatedWritebackError.operationFailed(
                source: "SMB", stage: .edit, detail: "bad file", isTransient: false),
            EmbeddedMetadataCoordinatedWritebackError.operationFailed(
                source: "SMB", stage: .readback, detail: "timed out", isTransient: true),
            EmbeddedMetadataCoordinatedWritebackError.operationFailed(
                source: "SMB", stage: .download, detail: "not found", isTransient: false),
        ] {
            let connector = FlakyMetadataConnector(failures: [error])
            _ = await TagMetadataWritebackCoordinator.write(mode: .embedded, connector: connector,
                original: original, updated: edited, coverData: nil)
            let attempts = await connector.attempts
            XCTAssertEqual(attempts, 1, "\(error)")
        }
    }

    func testTransientClassification() {
        XCTAssertTrue(MetadataWriteFailurePolicy.isTransient(URLError(.timedOut)))
        XCTAssertTrue(MetadataWriteFailurePolicy.isTransient(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))))
        XCTAssertTrue(MetadataWriteFailurePolicy.isTransient(SourceError.timeout))
        XCTAssertTrue(MetadataWriteFailurePolicy.isTransient(FTPClientError.timedOut("data")))
        XCTAssertTrue(MetadataWriteFailurePolicy.isTransient(CloudDriveError.apiError(503, "busy")))
        XCTAssertFalse(MetadataWriteFailurePolicy.isTransient(SourceFileMutationError.readOnly))
        XCTAssertFalse(MetadataWriteFailurePolicy.isTransient(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertFalse(MetadataWriteFailurePolicy.isTransient(SourceError.authenticationFailed))
        XCTAssertFalse(MetadataWriteFailurePolicy.isTransient(SourceError.fileNotFound("/a")))
        XCTAssertFalse(MetadataWriteFailurePolicy.isTransient(CancellationError()))
        let wrapped = NSError(domain: "Wrapper", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])
        XCTAssertTrue(MetadataWriteFailurePolicy.isTransient(wrapped))
    }
}

/// 原地改写(单独添加的文件、文件夹里不让新建文件时):写失败从备份放回原文件;放回也失败就
/// 留着备份、记一笔待恢复,下次用到这个源时自动放回;空间不够不动文件。
final class InPlaceFileRewriteTests: XCTestCase {
    private var directory: URL!
    private var backups: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InPlaceRewrite-\(UUID().uuidString)", isDirectory: true)
        backups = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func backupFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0 != "pending-restores.json" }
    }

    private func fileNumber(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }

    func testRewriteOverwritesInPlaceTruncatesAndDropsTheBackup() throws {
        let original = Data(repeating: 1, count: 300_000)
        let edited = Data(repeating: 2, count: 200_000)
        let song = try file("song.flac", original)
        let source = try file("edited.flac", edited)
        let number = try fileNumber(song)
        try InPlaceFileRewrite.rewrite(song, with: source, sourceID: "fixture", backupDirectory: backups)
        XCTAssertEqual(try Data(contentsOf: song), edited, "Overwritten from the start, then cut to the new length")
        XCTAssertEqual(try fileNumber(song), number, "The same file, not a replacement")
        XCTAssertEqual(backupFiles(), [])
        XCTAssertTrue(InPlaceFileRewrite.pendingRestores(in: backups).isEmpty)
    }

    func testFailedWritePutsTheOriginalBack() throws {
        let original = Data(repeating: 1, count: 2_000_000)
        let song = try file("song.flac", original)
        let source = try file("edited.flac", Data(repeating: 2, count: 3_000_000))
        XCTAssertThrowsError(try InPlaceFileRewrite.rewrite(
            song, with: source, sourceID: "fixture", backupDirectory: backups,
            faults: .init(failWriteAfterBytes: 1_000_000)
        )) { error in
            guard case InPlaceFileRewrite.Failure.restored = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: song), original)
        XCTAssertEqual(backupFiles(), [])
        XCTAssertTrue(InPlaceFileRewrite.pendingRestores(in: backups).isEmpty)
    }

    func testFailedRestoreKeepsTheBackupAndRestoresOnNextAccess() throws {
        let original = Data(repeating: 1, count: 2_000_000)
        let song = try file("song.flac", original)
        let source = try file("edited.flac", Data(repeating: 2, count: 3_000_000))
        XCTAssertThrowsError(try InPlaceFileRewrite.rewrite(
            song, with: source, sourceID: "fixture", backupDirectory: backups,
            faults: .init(failWriteAfterBytes: 1_000_000, failRestore: true)
        )) { error in
            guard case InPlaceFileRewrite.Failure.backupKept = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertNotEqual(try Data(contentsOf: song), original, "The file is damaged now")
        XCTAssertEqual(backupFiles().count, 1, "The only complete copy must survive")
        let pending = InPlaceFileRewrite.pendingRestores(in: backups)
        XCTAssertEqual(pending.map(\.sourceID), ["fixture"])
        XCTAssertEqual(pending.first?.originalSize, Int64(original.count))

        XCTAssertEqual(InPlaceFileRewrite.restorePending(sourceID: "another", backupDirectory: backups), 0)
        XCTAssertEqual(InPlaceFileRewrite.restorePending(sourceID: "fixture", backupDirectory: backups), 1)
        XCTAssertEqual(try Data(contentsOf: song), original)
        XCTAssertEqual(backupFiles(), [])
        XCTAssertTrue(InPlaceFileRewrite.pendingRestores(in: backups).isEmpty)
    }

    func testRestoreLeavesAFileReplacedSinceTheFailureAlone() throws {
        let original = Data(repeating: 1, count: 2_000_000)
        let song = try file("song.flac", original)
        let source = try file("edited.flac", Data(repeating: 2, count: 3_000_000))
        XCTAssertThrowsError(try InPlaceFileRewrite.rewrite(
            song, with: source, sourceID: "fixture", backupDirectory: backups,
            faults: .init(failWriteAfterBytes: 1_000_000, failRestore: true)
        ))
        // 之后别处放上了一份新的完整版本:不能拿旧备份盖掉它。
        let fresh = Data(repeating: 3, count: 1_234)
        try fresh.write(to: song)
        XCTAssertEqual(InPlaceFileRewrite.restorePending(sourceID: "fixture", backupDirectory: backups), 0)
        XCTAssertEqual(try Data(contentsOf: song), fresh)
        XCTAssertTrue(InPlaceFileRewrite.pendingRestores(in: backups).isEmpty)
        XCTAssertEqual(backupFiles(), [])
    }

    func testNotEnoughSpaceLeavesTheFileUntouched() throws {
        let original = Data(repeating: 1, count: 100_000)
        let song = try file("song.flac", original)
        let source = try file("edited.flac", Data(repeating: 2, count: 150_000))
        XCTAssertThrowsError(try InPlaceFileRewrite.rewrite(
            song, with: source, sourceID: "fixture", backupDirectory: backups,
            faults: .init(availableCapacity: 10)
        )) { error in
            guard case InPlaceFileRewrite.Failure.insufficientSpace = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: song), original)
        XCTAssertEqual(backupFiles(), [])
    }
}

@MainActor
final class PendingTagWritebackStoreTests: XCTestCase {
    private func song(_ id: String, title: String, artist: String?) -> Song {
        var song = Song(id: id, title: title, fileFormat: .flac, filePath: "/Music/\(id).flac", sourceID: "source")
        song.artistName = artist
        return song
    }

    private func entry(_ original: Song, now: Song, reason: String?, canRetry: Bool = true,
                       refused: Bool = false) -> BatchTagEditService.LocalOnlyWrite {
        BatchTagEditService.LocalOnlyWrite(songID: now.id, title: now.title, artist: now.artistName,
            sourceID: now.sourceID, filePath: now.filePath, reason: reason, canRetry: canRetry,
            refused: refused, original: original)
    }

    func testKeepsTheFilesTagsFromTheFirstMissedEditAcrossRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PendingTagWritebackStore(fileURL: url)
        let file = song("a", title: "File Title", artist: "File Artist")
        let merged = song("a", title: "File Title", artist: "Merged")
        let renamed = song("a", title: "Renamed", artist: "Merged")
        store.record(entry(file, now: merged, reason: "timed out"))
        // A second edit that also missed the file: the file still holds the first tags.
        store.record(entry(merged, now: renamed, reason: "refused", refused: true))
        // A change a retry cannot bring to the file is not kept.
        let cover = song("b", title: "B", artist: nil)
        store.record(entry(cover, now: cover, reason: nil, canRetry: false))

        XCTAssertEqual(store.entries.map(\.songID), ["a"])
        XCTAssertEqual(store.entries.first?.fileTags, PendingTagWritebackStore.FileTags(file))
        XCTAssertEqual(store.entries.first?.title, "Renamed")
        XCTAssertEqual(store.entries.first?.reason, "refused")
        XCTAssertEqual(store.entries.first?.refused, true)

        store.flushPendingWrite()
        XCTAssertEqual(PendingTagWritebackStore(fileURL: url).entries, store.entries)

        store.removeAll()
        store.flushPendingWrite()
        XCTAssertTrue(PendingTagWritebackStore(fileURL: url).entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRetryBaseWritesEveryFieldTheFileStillLacks() {
        let file = song("a", title: "File Title", artist: "File Artist")
        let current = song("a", title: "Renamed", artist: "Merged")
        let base = BatchTagEditService.retryBase(
            before: PendingTagWritebackStore.FileTags(file).applied(to: current), current: current)
        let changed = TagMetadataWritebackField.changedFields(from: base, to: current, includesCover: false)
        XCTAssertEqual(changed, [.title, .artist])
    }
}

/// 单独添加的文件:没有所在文件夹的授权也能原地写进音频文件,补授权后能在旁边写歌词文件;
/// 写回方式按「歌词保存到」和探测结果分开定。文件在编辑期间被别处改过:重读后不重叠就用新身份
/// 自动再写一次,同一项两边都改了就交给用户选。
final class LocalSaveLocationAndConflictTests: XCTestCase {
    private struct Reference: Encodable {
        let virtualPathComponent: String
        let bookmarkData: Data
        let isDirectory: Bool
        var folderBookmarkData: Data?
    }

    private var directory: URL!
    private var sourceID: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveLocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceID = UUID().uuidString
    }

    override func tearDownWithError() throws {
        LocalBookmarkStore.remove(sourceID: sourceID)
        try? FileManager.default.removeItem(at: directory)
    }

    // 下面这些帮手函数是静态的:主线程上的测试调用它们时不必把测试对象本身送过去。
    private static func makeSilentM4A(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames: AVAudioFrameCount = 22_050
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private static func makeTaggedAudio(in directory: URL, named name: String = "Song.m4a") async throws -> URL {
        let url = try makeSilentM4A(in: directory, named: name)
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(
                tags: .init(title: "Song", artist: "Artist", albumTitle: "Album",
                            genre: "Pop", year: 2001, trackNumber: 1, discNumber: nil),
                coverData: nil,
                lyrics: .keep
            ),
            to: url
        )
        return url
    }

    /// 只选了这个文件(没有文件夹)的本机音乐源;`grantsFolder` 时另外授权过所在文件夹。
    private func storeIndividualReference(_ file: URL, grantsFolder: Bool) throws {
        let reference = Reference(
            virtualPathComponent: file.lastPathComponent,
            bookmarkData: try file.bookmarkData(options: .minimalBookmark),
            isDirectory: false,
            folderBookmarkData: grantsFolder ? try directory.bookmarkData(options: .minimalBookmark) : nil
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode([reference]), forKey: "primuse.localBookmarks.v1." + sourceID
        )
    }

    private static func librarySong(
        _ source: LocalFileSource,
        sourceID: String,
        path: String = "/Song.m4a"
    ) async throws -> Song {
        let state = try await source.metadataWritebackState(for: path)
        var song = Song(id: UUID().uuidString, title: "Song", fileFormat: .m4a, filePath: path, sourceID: sourceID)
        song.artistName = "Artist"
        song.albumTitle = "Album"
        song.genre = "Pop"
        song.year = 2001
        song.trackNumber = 1
        song.fileSize = state.fileSize
        song.lastModified = state.modifiedDate
        song.revision = state.revision
        return song
    }

    /// 另一台设备改了文件:改动发生在稍后,修改时间往后挪,不让「一秒内同样大小」的宽容当成没改。
    private static func changeElsewhere(_ url: URL, artist: String? = nil, genre: String? = nil) async throws {
        let current = try EmbeddedMetadataWriter.currentTags(at: url)
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(
                tags: .init(title: current.title ?? "Song", artist: artist ?? current.artist,
                            albumTitle: current.albumTitle, genre: genre ?? current.genre,
                            year: current.year, trackNumber: current.trackNumber, discNumber: current.discNumber),
                coverData: nil,
                lyrics: .keep
            ),
            to: url
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: url.path
        )
    }

    private func fileNumber(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }

    func testIndividuallyAddedFileIsRewrittenInPlaceWithoutFolderAccess() async throws {
        let file = try await Self.makeTaggedAudio(in: directory)
        try storeIndividualReference(file, grantsFolder: false)
        let source = LocalFileSource(sourceID: sourceID, basePath: file)
        XCTAssertFalse(source.supportsSidecarWriting)
        let access = await source.saveLocationAccess(for: "/Song.m4a")
        XCTAssertEqual(access.folder, .noAccess, "Only the file itself was picked")
        XCTAssertEqual(access.audioFile, .writable)

        let before = try fileNumber(file)
        let original = try await Self.librarySong(source, sourceID: sourceID)
        var edited = original
        edited.title = "Edited"
        let report = await TagMetadataWritebackCoordinator.write(
            mode: .embedded, connector: source, original: original, updated: edited, coverData: nil
        )
        XCTAssertTrue(report.remoteMutationOccurred, report.issueMessage ?? "")
        XCTAssertEqual(try EmbeddedMetadataWriter.currentTags(at: file).title, "Edited")
        XCTAssertEqual(try fileNumber(file), before, "Rewritten in place, not replaced through the folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Song.m4a"],
                       "No staging file may be created beside an individually added file")
    }

    func testGrantedFolderLetsAnIndividualFileWriteFilesBesideIt() async throws {
        let file = try await Self.makeTaggedAudio(in: directory)
        let lyrics = directory.appendingPathComponent("Song.lrc")
        try Data("[00:01.00]old".utf8).write(to: lyrics)
        try storeIndividualReference(file, grantsFolder: true)
        XCTAssertTrue(LocalBookmarkStore.supportsSidecarWriting(sourceID: sourceID))
        let source = LocalFileSource(sourceID: sourceID, basePath: file)
        XCTAssertTrue(source.supportsSidecarWriting)
        let access = await source.saveLocationAccess(for: "/Song.m4a")
        XCTAssertEqual(access.folder, .writable)

        XCTAssertFalse(source.supportsDirectoryMutation, "Writing beside a file is not reorganising folders")
        let canMutateDirectories = await source.canMutateDirectories()
        XCTAssertFalse(canMutateDirectories)
        let notAdded = directory.appendingPathComponent("Song-Remix.flac")
        try Data(repeating: 7, count: 4_096).write(to: notAdded)

        let listing = try await source.listFiles(at: "/")
        XCTAssertEqual(Set(listing.map(\.path)), ["/Song.m4a", "/Song.lrc"],
                       "Audio the user did not add must not show up through the granted folder")
        try await source.writeFile(data: Data("[00:01.00]new".utf8), to: "/Song.lrc")
        XCTAssertEqual(try String(contentsOf: lyrics, encoding: .utf8), "[00:01.00]new")
        do {
            try await source.writeFile(data: Data("x".utf8), to: "/Song-Remix.flac")
            XCTFail("An audio file the user did not add must not be writable through the folder")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: notAdded), Data(repeating: 7, count: 4_096))
        do {
            try await source.writeFile(data: Data("x".utf8), to: "/Other.lrc")
            XCTFail("A name that belongs to no picked file must not reach the folder")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Other.lrc").path))
    }

    @MainActor
    func testLyricsSaveLocationFollowsTheSettingForAnIndividualFile() async throws {
        let file = try await Self.makeTaggedAudio(in: directory)
        try storeIndividualReference(file, grantsFolder: false)
        let musicSource = MusicSource(id: sourceID, name: "Single", type: .local, basePath: file.path, authType: .none)
        let connector = LocalFileSource(sourceID: sourceID, basePath: file)
        let manager = SourceManager(sourcesProvider: { [musicSource] }, connectorFactory: { _ in connector })
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("Sources"))
        sources.add(musicSource)
        let song = try await Self.librarySong(connector, sourceID: sourceID)
        defer { EmbeddedLyricsCopyPolicy.setMode(nil, forSongID: song.id) }

        EmbeddedLyricsCopyPolicy.setMode(.embedOnly, forSongID: song.id)
        var target = await LyricsWriteback.resolveTarget(for: song, sourceManager: manager, sourcesStore: sources)
        guard case .sidecar(let preflight) = target.mode else {
            return XCTFail("Embedding must not be stopped by the folder check: \(target.mode)")
        }
        XCTAssertFalse(preflight.hasLyricsDocument)
        XCTAssertEqual(target.plan.destination, .audioFile)
        XCTAssertEqual(target.plan.reason, .none)

        EmbeddedLyricsCopyPolicy.setMode(.alongside, forSongID: song.id)
        target = await LyricsWriteback.resolveTarget(for: song, sourceManager: manager, sourcesStore: sources)
        XCTAssertEqual(target.plan.destination, .audioFile)
        XCTAssertEqual(target.plan.reason, .noFolderAccessEmbedsOnly)
        let effective = await manager.lyricsEmbeddingMode(for: song)
        XCTAssertEqual(effective, .embedOnly, "The lyrics file half cannot be written, so only embedding is left")

        EmbeddedLyricsCopyPolicy.setMode(.off, forSongID: song.id)
        target = await LyricsWriteback.resolveTarget(for: song, sourceManager: manager, sourcesStore: sources)
        XCTAssertTrue(target.mode.isLocalStructuredOnly)
        XCTAssertEqual(target.plan.reason, .noFolderAccess)
        XCTAssertEqual(target.plan.remedies, [.grantFolderAccess, .embedThisSong, .embedAllSongs])
        XCTAssertNotEqual(target.notice, String(localized: "save_location_lyrics_read_only_source"))
    }

    func testChangeElsewhereToOtherFieldsIsWrittenAgainWithTheCurrentFile() async throws {
        let file = try await Self.makeTaggedAudio(in: directory)
        try storeIndividualReference(file, grantsFolder: false)
        let source = LocalFileSource(sourceID: sourceID, basePath: file)
        let stale = try await Self.librarySong(source, sourceID: sourceID)
        try await Self.changeElsewhere(file, genre: "Jazz")

        var edited = stale
        edited.artistName = "Mine"
        let report = await TagMetadataWritebackCoordinator.write(
            mode: .embedded, connector: source, original: stale, updated: edited, coverData: nil
        )
        XCTAssertTrue(report.recoveredFromConflict, report.issueMessage ?? "")
        XCTAssertNil(report.conflict)
        XCTAssertTrue(report.remoteMutationOccurred)
        let tags = try EmbeddedMetadataWriter.currentTags(at: file)
        XCTAssertEqual(tags.artist, "Mine")
        XCTAssertEqual(tags.genre, "Jazz", "The other device's change stays in the file")
        XCTAssertEqual(report.updatedSong.genre, "Jazz", "The library row follows the change made elsewhere")
        XCTAssertEqual(report.updatedSong.artistName, "Mine")
        let current = try await source.metadataWritebackState(for: "/Song.m4a")
        XCTAssertEqual(report.updatedSong.revision, current.revision)
    }

    func testNewCoverAfterTheFileChangedElsewhereAsksTheUser() async throws {
        let file = try await Self.makeTaggedAudio(in: directory)
        try storeIndividualReference(file, grantsFolder: false)
        let source = LocalFileSource(sourceID: sourceID, basePath: file)
        let stale = try await Self.librarySong(source, sourceID: sourceID)
        try await Self.changeElsewhere(file, genre: "Jazz")
        let cover = try XCTUnwrap(Self.solidJPEG())

        var edited = stale
        edited.title = "Edited"
        let report = await TagMetadataWritebackCoordinator.write(
            mode: .embedded, connector: source, original: stale, updated: edited, coverData: cover
        )
        let conflict = try XCTUnwrap(report.conflict, "Without a baseline a new cover is never written blindly")
        XCTAssertEqual(conflict.fields, [.cover])
        XCTAssertNotNil(conflict.editedCover)
        XCTAssertFalse(report.remoteMutationOccurred)
        let keepFile = conflict.resolved(keepingFileValueFor: [.cover])
        XCTAssertNil(keepFile.coverData)
        XCTAssertEqual(keepFile.updated.title, "Edited", "The title change is not part of the conflict")
        XCTAssertEqual(keepFile.updated.genre, "Jazz")
        XCTAssertEqual(keepFile.original.genre, "Jazz", "Both rows carry the change made elsewhere")
        XCTAssertNotNil(conflict.resolved(keepingFileValueFor: []).coverData)
    }

    func testEmptyFileTitleKeepsTheFileValueAsTheLibraryShowsIt() {
        var library = Song(id: "a", title: "Mine", fileFormat: .flac, filePath: "/Music/01 Track.flac", sourceID: "s")
        library.artistName = "Artist"
        var edited = library
        edited.title = "New Title"
        let conflict = TagWriteConflict(
            refreshedOriginal: library,
            edited: edited,
            fileTags: EmbeddedMetadataVerification(title: nil, artist: "Artist", albumTitle: nil, genre: nil,
                                                   year: nil, trackNumber: nil, discNumber: nil, coverData: nil),
            fields: [.title]
        )
        let keepFile = conflict.resolved(keepingFileValueFor: [.title])
        XCTAssertNotEqual(keepFile.updated.title, "New Title", "Choosing the file's value must not keep the edit")
        XCTAssertEqual(keepFile.updated.title, keepFile.original.title)
        XCTAssertFalse(keepFile.writesSomething)
        XCTAssertEqual(keepFile.updated.userMetadataEditedAt, library.userMetadataEditedAt)
    }

    @MainActor
    func testBatchConflictWritesOnlyTheRestAndAsksLaterInTheEditor() async throws {
        let file = try await Self.makeTaggedAudio(in: directory)
        try storeIndividualReference(file, grantsFolder: false)
        let musicSource = MusicSource(id: sourceID, name: "Single", type: .local, basePath: file.path, authType: .none)
        let connector = LocalFileSource(sourceID: sourceID, basePath: file)
        let manager = SourceManager(sourcesProvider: { [musicSource] }, connectorFactory: { _ in connector })
        let fixture = try editingFixture()
        defer { fixture.cleanup() }
        let stale = try await Self.librarySong(connector, sourceID: sourceID)
        fixture.library.addSongs([stale])
        defer { PendingTagConflictStore.shared.clear(songID: stale.id) }
        try await Self.changeElsewhere(file, artist: "Other device")

        var edited = stale
        edited.artistName = "Mine"
        edited.year = 2002
        let outcome = await BatchTagEditService.apply([(stale, edited)], coverData: nil, sourceManager: manager,
                                                      library: fixture.library, player: fixture.player) { _, _ in }
        let tags = try EmbeddedMetadataWriter.currentTags(at: file)
        XCTAssertEqual(tags.artist, "Other device", "The field both sides changed is not overwritten")
        XCTAssertEqual(tags.year, 2002, "The rest of the edit still reaches the file")
        let row = try XCTUnwrap(fixture.library.song(id: stale.id))
        XCTAssertEqual(row.artistName, "Other device", "The library keeps the file's value for the conflict")
        XCTAssertEqual(row.year, 2002)
        XCTAssertFalse(outcome.notices.isEmpty)
        XCTAssertFalse(PendingTagWritebackStore.shared.entries.contains { $0.songID == stale.id })

        let asked = try XCTUnwrap(PendingTagConflictStore.shared.conflict(for: row))
        XCTAssertEqual(asked.fields, [.artist])
        XCTAssertEqual(asked.fileValue(.artist), "Other device")
        XCTAssertEqual(asked.editedValue(.artist), "Mine")
    }

    @MainActor
    func testBatchConflictWithNothingElseLeavesNoUserEditMark() async throws {
        let file = try await Self.makeTaggedAudio(in: directory)
        try storeIndividualReference(file, grantsFolder: false)
        let musicSource = MusicSource(id: sourceID, name: "Single", type: .local, basePath: file.path, authType: .none)
        let connector = LocalFileSource(sourceID: sourceID, basePath: file)
        let manager = SourceManager(sourcesProvider: { [musicSource] }, connectorFactory: { _ in connector })
        let fixture = try editingFixture()
        defer { fixture.cleanup() }
        let stale = try await Self.librarySong(connector, sourceID: sourceID)
        fixture.library.addSongs([stale])
        defer { PendingTagConflictStore.shared.clear(songID: stale.id) }
        try await Self.changeElsewhere(file, artist: "Other device")

        var edited = stale
        edited.artistName = "Mine"
        _ = await BatchTagEditService.apply([(stale, edited)], coverData: nil, sourceManager: manager,
                                            library: fixture.library, player: fixture.player) { _, _ in }
        let row = try XCTUnwrap(fixture.library.song(id: stale.id))
        XCTAssertEqual(row.artistName, "Other device")
        XCTAssertNil(row.userMetadataEditedAt, "Nothing of the user's was written")
        XCTAssertNotNil(PendingTagConflictStore.shared.conflict(for: row))
    }

    @MainActor
    private func editingFixture() throws -> (library: MusicLibrary, player: AudioPlayerService, cleanup: () -> Void) {
        let storage = directory.appendingPathComponent("Library-\(UUID().uuidString)")
        let suite = "SaveLocationEditing-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = MusicLibrary(storageDirectory: storage, deferredMaintenanceAllowed: { false })
        let player = AudioPlayerService(library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: storage.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Editing tags must not start playback") })
        return (library, player, { defaults.removePersistentDomain(forName: suite) })
    }

    private static func solidJPEG() -> Data? {
        guard let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    func testSameFieldChangedElsewhereAsksTheUserBeforeWriting() async throws {
        let file = try await Self.makeTaggedAudio(in: directory)
        try storeIndividualReference(file, grantsFolder: false)
        let source = LocalFileSource(sourceID: sourceID, basePath: file)
        let stale = try await Self.librarySong(source, sourceID: sourceID)
        try await Self.changeElsewhere(file, artist: "Other device")

        var edited = stale
        edited.artistName = "Mine"
        edited.year = 2002
        let report = await TagMetadataWritebackCoordinator.write(
            mode: .embedded, connector: source, original: stale, updated: edited, coverData: nil
        )
        let conflict = try XCTUnwrap(report.conflict, report.issueMessage ?? "")
        XCTAssertEqual(conflict.fields, [.artist], "Only the field both sides changed is asked about")
        XCTAssertEqual(conflict.fileValue(.artist), "Other device")
        XCTAssertEqual(conflict.editedValue(.artist), "Mine")
        XCTAssertFalse(report.remoteMutationOccurred)
        XCTAssertEqual(try EmbeddedMetadataWriter.currentTags(at: file).artist, "Other device")
        XCTAssertFalse(BatchTagEditService.written(from: report).canRetry,
                       "An automatic retry would hit the same conflict")

        let keepFile = conflict.resolved(keepingFileValueFor: [.artist])
        XCTAssertEqual(keepFile.updated.artistName, "Other device")
        XCTAssertEqual(
            TagMetadataWritebackField.changedFields(from: keepFile.original, to: keepFile.updated, includesCover: false),
            [.year]
        )

        let mine = conflict.resolved(keepingFileValueFor: [])
        let second = await TagMetadataWritebackCoordinator.write(
            mode: .embedded, connector: source, original: mine.original, updated: mine.updated, coverData: nil
        )
        XCTAssertTrue(second.remoteMutationOccurred, second.issueMessage ?? "")
        let tags = try EmbeddedMetadataWriter.currentTags(at: file)
        XCTAssertEqual(tags.artist, "Mine")
        XCTAssertEqual(tags.year, 2002)
    }

    func testRereadFailureKeepsTheDraftAndSaysWhy() async {
        let original = Song(id: UUID().uuidString, title: "Original", fileFormat: .flac,
                            filePath: "/Music/song.flac", sourceID: UUID().uuidString)
        var edited = original
        edited.title = "Edited"
        let connector = ConflictThenUnreadableConnector()
        let report = await TagMetadataWritebackCoordinator.write(
            mode: .embedded, connector: connector, original: original, updated: edited, coverData: nil
        )
        XCTAssertTrue(report.conflictRereadFailed)
        XCTAssertNil(report.conflict)
        XCTAssertTrue(report.embeddedWriteFailed)
        XCTAssertNotNil(report.issueMessage)
    }
}

/// 第一次写回撞上冲突,之后连文件状态都读不出来(文件没了、没权限、连不上)。
private actor ConflictThenUnreadableConnector: MusicSourceConnector {
    nonisolated let sourceID = "conflict-unreadable"
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func writeEmbeddedMetadata(original: Song, updated: Song, coverData: Data?, lyrics: EmbeddedLyricsEdit,
                               writesTextTags: Bool) async throws -> EmbeddedMetadataWritebackResult {
        throw EmbeddedMetadataCoordinatedWritebackError.conflict
    }
    func embeddedMetadataSnapshot(for path: String) async throws -> EmbeddedMetadataFileSnapshot {
        throw SourceError.fileNotFound(path)
    }
}
