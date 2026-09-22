import AVFoundation
import CryptoKit
import Foundation
import Network
import PrimuseKit
import XCTest
@testable import Primuse

final class CloudPlaybackSourceConcurrencyTests: XCTestCase {
    @MainActor
    func testFileRequestFailuresNeverImmediatelyParkOtherSongs() {
        let errors: [Error] = [
            URLError(.timedOut), URLError(.badServerResponse), URLError(.fileDoesNotExist),
            SourceError.connectionFailed("short range"), SourceError.timeout,
            MetadataBackfillService.BackfillRangeExpansionError(format: "FLAC"),
            MetadataBackfillService.BackfillRangeExpansionError(format: "ogg"),
            CloudDriveError.invalidResponse, CloudDriveError.permissionDenied(.fileRead),
            CloudDriveError.apiError(403, "file access denied"),
            CloudDriveError.apiError(503, "object temporarily unavailable"),
        ]
        for error in errors {
            XCTAssertFalse(MetadataBackfillService.isSourceUnavailableBackfillError(error))
        }
        XCTAssertTrue(MetadataBackfillService.needsSourceEndpointProbe(URLError(.timedOut)))
        XCTAssertTrue(MetadataBackfillService.needsSourceEndpointProbe(SourceError.timeout))
        XCTAssertFalse(MetadataBackfillService.needsSourceEndpointProbe(URLError(.badServerResponse)))
        let rangeError = MetadataBackfillService.BackfillRangeExpansionError(format: "FLAC")
        XCTAssertTrue(MetadataBackfillService.isTransientBackfillError(rangeError))
        XCTAssertFalse(MetadataBackfillService.needsSourceEndpointProbe(rangeError))

        // 网盘自家的业务码和 HTTP 码不共用编号空间 —— 光鸭的 101(内部错误)、
        // 116(签名无效)与文件本身无关,按 HTTP 语义判成永久失败,会让一整批
        // 标签完好的歌显示成「信息不完善」,非得用户手动重新检查才恢复。
        XCTAssertTrue(
            MetadataBackfillService.isTransientBackfillError(
                CloudDriveError.apiError(101, "internal business error")
            )
        )
        XCTAssertTrue(
            MetadataBackfillService.isTransientBackfillError(
                CloudDriveError.apiError(116, "invalid sign")
            )
        )
        // 资源本身读不到的仍然是永久失败,不该反复消耗配额。
        XCTAssertFalse(
            MetadataBackfillService.isTransientBackfillError(
                CloudDriveError.apiError(404, "not found")
            )
        )
        XCTAssertFalse(
            MetadataBackfillService.isTransientBackfillError(
                CloudDriveError.apiError(410, "gone")
            )
        )
    }

    @MainActor
    func testSourceAccountAndRateLimitFailuresStillParkTheSource() {
        let errors: [Error] = [
            SourceConnectionTerminalError(message: "Account locked"),
            SourceError.authenticationFailed, SourceError.credentialUnavailable("Unavailable"),
            CloudDriveError.notAuthenticated, CloudDriveError.tokenExpired,
            CloudDriveError.permissionDenied(.accountAccess),
            CloudDriveError.rateLimited, CloudDriveError.apiError(429, "Retry later"),
            CloudDriveError.apiError(401, "Authentication required"),
        ]
        for error in errors {
            XCTAssertTrue(MetadataBackfillService.isSourceUnavailableBackfillError(error))
        }
    }

    func testWebDAVLateReadsAfterDisconnectReturnCancellation() async throws {
        let source = WebDAVSource(
            sourceID: "webdav-disconnected-\(UUID().uuidString)",
            host: "webdav-disconnected.invalid",
            useSsl: true,
            username: "",
            password: ""
        )
        await source.disconnect()

        do {
            _ = try await source.fetchRange(path: "/song.flac", offset: 0, length: 128)
            XCTFail("A disconnected playback read must stop")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        for offset: Int64 in [0, -128] {
            do {
                _ = try await source.fetchMetadataRange(
                    path: "/song.flac", offset: offset, length: 128, intent: .bulkBounded
                )
                XCTFail("A disconnected metadata read must stop")
            } catch {
                XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
            }
        }
    }

    func testWebDAVCancelledMetadataReadDoesNotStartNetworkRequest() async throws {
        let source = WebDAVSource(
            sourceID: "webdav-cancelled-\(UUID().uuidString)",
            host: "webdav-cancelled.invalid",
            useSsl: true,
            username: "",
            password: ""
        )
        let gate = AsyncStream<Void>.makeStream()
        let read = Task {
            for await _ in gate.stream { break }
            return try await source.fetchMetadataRange(
                path: "/song.flac", offset: 0, length: 128, intent: .bulkBounded
            )
        }
        read.cancel()
        gate.continuation.finish()
        do {
            _ = try await read.value
            XCTFail("A cancelled metadata read must stop")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        await source.disconnect()
    }

    func testWebDAVConcurrentConnectDisconnectAndReconnect() async throws {
        let server = try WebDAVLifecycleHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let sourceID = "webdav-lifecycle-\(UUID().uuidString)"
                    let source = WebDAVSource(sourceID: sourceID, host: "127.0.0.1", port: Int(port),
                                              useSsl: false, basePath: "/Music", username: "", password: "")
                    do {
                        for _ in 0..<3 {
                            try await source.connect()
                            let files = try await source.listFiles(at: "/")
                            XCTAssertEqual(files.map(\.path), ["/song.flac"])
                            await source.disconnect()
                        }
                    } catch {
                        await source.disconnect()
                        throw error
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(server.requests.count, 96)
        XCTAssertTrue(server.requests.allSatisfy { $0.method == "PROPFIND" && $0.authorization == nil })
    }

    func testWebDAVHTTPDownloadUsesCredentialsAndPublishesOnlySuccessfulFiles() async throws {
        let server = try WebDAVLifecycleHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let sourceID = "webdav-download-\(UUID().uuidString)"
        let source = WebDAVSource(sourceID: sourceID, host: "127.0.0.1", port: Int(port),
                                  useSsl: false, basePath: "/Music", username: "reader", password: "fixture")
        addTeardownBlock { await source.disconnect() }
        try await source.connect()
        let url = try await source.localURL(for: "/song.flac")
        XCTAssertEqual(try Data(contentsOf: url), WebDAVLifecycleHTTPServer.audio)
        let cachedURL = try await source.localURL(for: "/song.flac")
        XCTAssertEqual(url, cachedURL)
        XCTAssertEqual(server.requests.filter { $0.method == "GET" && $0.path == "/Music/song.flac" }.count, 1)
        for _ in 0..<2 {
            do {
                _ = try await source.localURL(for: "/denied.flac")
                XCTFail("An authentication error must not publish a cache file")
            } catch {
                XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), .authenticationRequired)
            }
        }
        XCTAssertEqual(server.requests.filter { $0.path == "/Music/denied.flac" }.count, 2)
        XCTAssertTrue(server.requests.allSatisfy {
            $0.authorization == "Basic \(Data("reader:fixture".utf8).base64EncodedString())"
        })
    }

    func testWebDAVDisconnectCancelsPendingConnectAndAllowsFreshConnection() async throws {
        let server = try WebDAVLifecycleHTTPServer(holdFirstListing: true)
        let port = try await server.start()
        defer { server.stop() }
        let source = WebDAVSource(sourceID: "webdav-reconnect-\(UUID().uuidString)", host: "127.0.0.1",
                                  port: Int(port), useSsl: false, basePath: "/Music", username: "", password: "")
        addTeardownBlock { await source.disconnect() }
        let pending = Task { try await source.connect() }
        for _ in 0..<200 where server.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.requests.count, 1)
        await source.disconnect()
        async let replacement: Void = source.connect()
        do {
            try await pending.value
            XCTFail("The old connection must not complete after disconnect")
        } catch {
            XCTAssertTrue(OperationCancellationPolicy.isCancellation(error))
        }
        try await replacement
        let files = try await source.listFiles(at: "/")
        XCTAssertEqual(files.map(\.path), ["/song.flac"])
        XCTAssertEqual(server.requests.count, 3)
    }

    @MainActor
    func testReadingConfigurationNotificationsNeverWaitForMainThread() async {
        let center = NotificationCenter()
        let names = [UserDefaults.didChangeNotification,
                     ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange]
        let updated = expectation(description: "configuration updates reach the main actor")
        updated.expectedFulfillmentCount = names.count
        var received: [Notification.Name] = []
        let observers = MetadataBackfillService.observeReadingConfigurationChanges(center: center) { name in
            XCTAssertTrue(Thread.isMainThread)
            received.append(name)
            updated.fulfill()
        }
        defer { observers.forEach(center.removeObserver) }

        for name in names {
            let returned = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                center.post(name: name, object: NSObject())
                returned.signal()
            }
            // Hold the main thread as MusicKit does while waiting for its
            // identity queue. The sender must finish without a main run loop.
            XCTAssertEqual(returned.wait(timeout: .now() + 1), .success)
        }
        XCTAssertTrue(received.isEmpty)
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(Set(received), Set(names))
    }

    @MainActor
    func testReadingPreferenceNotificationsApplyEveryModeAsynchronously() async throws {
        let center = NotificationCenter()
        let suite = "metadata-notification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var mode = MetadataReadingMode.automatic
        let observers = MetadataBackfillService.observeReadingConfigurationChanges(center: center) { name in
            guard name == UserDefaults.didChangeNotification else { return }
            mode = MetadataReadingMode.resolve(
                storedValue: defaults.string(forKey: MetadataBackfillExecutionPolicy.readingModeDefaultsKey),
                legacyFastEnabled: false
            )
        }
        defer { observers.forEach(center.removeObserver) }

        for selected in [MetadataReadingMode.fast, .energySaving, .automatic] {
            defaults.set(selected.rawValue, forKey: MetadataBackfillExecutionPolicy.readingModeDefaultsKey)
            await Task.detached {
                center.post(name: UserDefaults.didChangeNotification, object: nil)
            }.value
            let deadline = ContinuousClock.now + .seconds(2)
            while mode != selected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(mode, selected)
        }
    }

    func testForegroundJoinsSlowPrefetchWithoutOverlappingTrailingFill() async throws {
        let sourceID = "cloud-shared-prefetch-\(UUID().uuidString)"
        let directory = try makeTemporaryDirectory()
        let cacheURL = directory.appendingPathComponent("song.bin")
        let payload = Data(repeating: 0x35, count: Int(CloudPlaybackSource.chunkSize) * 3)
        let gate = BlockingFetchGate()
        let connector = FixtureRangeConnector(sourceID: sourceID, payload: payload, trailingGate: gate)
        defer {
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            Task { await gate.release() }
            try? FileManager.default.removeItem(at: directory)
        }
        let input = try makeInputSource(
            sourceID: sourceID, cacheURL: cacheURL, payload: payload,
            connector: connector, allowsTrailingFill: true, prefetchAhead: 2
        )
        XCTAssertTrue(Self.read(input, byteCount: 4096).success)
        let started = await Self.waitUntilAsync(timeout: 2) {
            await connector.backgroundFetchCount() == 2
        }
        XCTAssertTrue(started)
        let finished = expectation(description: "foreground received shared bytes")
        let result = LockedReadResult()
        let box = InputSourceBox(input)
        DispatchQueue.global(qos: .userInitiated).async {
            result.store(Self.read(box.input, byteCount: 4096, offset: Int(CloudPlaybackSource.chunkSize)))
            finished.fulfill()
        }
        try await Task.sleep(for: .milliseconds(350))
        let pendingRequests = await connector.requests()
        XCTAssertEqual(pendingRequests.count, 3, "A waiting read must reuse the two outstanding chunks")
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(result.value.success, result.value.error ?? "shared read failed")
        XCTAssertEqual(result.value.data, Data(repeating: 0x35, count: 4096))
        let promoted = await waitUntil(timeout: 2) { FileManager.default.fileExists(atPath: cacheURL.path) }
        XCTAssertTrue(promoted)
        XCTAssertEqual(try Data(contentsOf: cacheURL), payload)
        let requests = await connector.requests()
        XCTAssertEqual(requests.map(\.offset).sorted(), [0, CloudPlaybackSource.chunkSize, 2 * CloudPlaybackSource.chunkSize])
        XCTAssertEqual(requests.reduce(Int64(0)) { $0 + $1.length }, Int64(payload.count))
    }

    func testCancellingSessionReleasesReaderWaitingForPrefetch() async throws {
        let sourceID = "cloud-shared-cancel-\(UUID().uuidString)"
        let directory = try makeTemporaryDirectory()
        let cacheURL = directory.appendingPathComponent("song.bin")
        let payload = Data(repeating: 0x49, count: Int(CloudPlaybackSource.chunkSize) * 2)
        let gate = BlockingFetchGate()
        let connector = FixtureRangeConnector(sourceID: sourceID, payload: payload, trailingGate: gate)
        defer {
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            Task { await gate.release() }
            try? FileManager.default.removeItem(at: directory)
        }
        let input = try makeInputSource(
            sourceID: sourceID, cacheURL: cacheURL, payload: payload,
            connector: connector, allowsTrailingFill: false, prefetchAhead: 1
        )
        XCTAssertTrue(Self.read(input, byteCount: 4096).success)
        let started = await Self.waitUntilAsync(timeout: 2) { await gate.hasStarted() }
        XCTAssertTrue(started)
        let finished = expectation(description: "cancelled shared reader returned")
        let result = LockedReadResult()
        let box = InputSourceBox(input)
        DispatchQueue.global(qos: .userInitiated).async {
            result.store(Self.read(box.input, byteCount: 4096, offset: Int(CloudPlaybackSource.chunkSize)))
            finished.fulfill()
        }
        try await Task.sleep(for: .milliseconds(350))
        CloudPlaybackSource.cancelSessions(sourceID: sourceID)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(result.value.success)
        await gate.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testFailedPrefetchFallsBackToForegroundRead() async throws {
        let sourceID = "cloud-shared-failure-\(UUID().uuidString)"
        let directory = try makeTemporaryDirectory()
        let cacheURL = directory.appendingPathComponent("song.bin")
        let payload = Data(repeating: 0x62, count: Int(CloudPlaybackSource.chunkSize) * 2)
        let connector = FixtureRangeConnector(sourceID: sourceID, payload: payload, failsBackgroundFetch: true)
        defer {
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            try? FileManager.default.removeItem(at: directory)
        }
        let input = try makeInputSource(
            sourceID: sourceID, cacheURL: cacheURL, payload: payload,
            connector: connector, allowsTrailingFill: false, prefetchAhead: 1
        )
        XCTAssertTrue(Self.read(input, byteCount: 4096).success)
        let attempted = await Self.waitUntilAsync(timeout: 2) { await connector.backgroundFetchCount() == 1 }
        XCTAssertTrue(attempted)
        let result = Self.read(input, byteCount: 4096, offset: Int(CloudPlaybackSource.chunkSize))
        XCTAssertTrue(result.success, result.error ?? "foreground fallback failed")
        XCTAssertEqual(result.data, Data(repeating: 0x62, count: 4096))
    }

    @MainActor
    func testFailedUserSeekKeepsRequestedPositionInsteadOfRestartingSong() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("seek.wav")
        try Self.writeSilentAudio(to: audioURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "seek-failure-\(UUID().uuidString)"))
        let settings = PlaybackSettingsStore(defaults: defaults)
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        var activationCount = 0
        let player = AudioPlayerService(
            playbackSettings: settings,
            playbackSessionStore: store,
            activateAudioSession: { _ in
                activationCount += 1
                if activationCount > 1 { throw AudioDecoderError.seekUnavailable }
                try AudioSessionManager.shared.requirePlaybackSession()
            }
        )
        let song = Song(
            id: "seek-fixture",
            title: "Seek Fixture",
            duration: 10,
            fileFormat: .wav,
            filePath: audioURL.path,
            sourceID: "local"
        )
        player.setQueue([song])
        await player.play(song: song)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(activationCount, 1)

        for (offset, target) in [6.0, 8.0].enumerated() {
            player.seek(to: target, startPlaying: true)
            let settled = await Self.waitUntilAsync(timeout: 5) {
                await MainActor.run { !player.isLoading }
            }
            XCTAssertTrue(settled)
            XCTAssertEqual(player.currentTime, target, accuracy: 0.001)
            XCTAssertEqual(player.currentSong?.id, song.id)
            XCTAssertEqual(player.currentIndex, 0)
            XCTAssertEqual(player.queue.map(\.id), [song.id])
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(activationCount, offset + 2, "seek failure must not issue a new play request")
        }
    }

    private static func writeSilentAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testMiddleAudioRangeIsNotMistakenForAnErrorPage() throws {
        let sampleBytes = Data([
            0x3c, 0x01, 0x8a, 0x11, 0x74, 0x01, 0x8e, 0x07,
            0xfe, 0x02, 0x48, 0x00, 0x23, 0x00, 0x1f, 0x11,
        ])
        for contentType in ["audio/wav", "application/octet-stream", ""] {
            for firstByte in [UInt8(0x3c), 0x7b] {
                var body = sampleBytes
                body[0] = firstByte
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: URL(string: "https://media.invalid/song.wav")!,
                    statusCode: 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": contentType,
                        "Content-Range": "bytes 13631488-13631503/137674442",
                    ]
                ))
                XCTAssertFalse(httpMediaResponseLooksLikeErrorBody(response, data: body))
            }
        }
    }

    func testMediaRangesStillRejectExplicitErrorContentTypes() throws {
        for contentType in ["text/html", "application/json", "text/plain"] {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: URL(string: "https://media.invalid/song.wav")!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": contentType,
                    "Content-Range": "bytes 13631488-13631503/137674442",
                ]
            ))
            XCTAssertTrue(httpMediaResponseLooksLikeErrorBody(response, data: Data("login required".utf8)))
        }
    }

    func testWholeMediaAndFirstRangeStillRejectDisguisedLoginPages() throws {
        for status in [200, 206] {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: URL(string: "https://media.invalid/song.wav")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/octet-stream",
                    "Content-Range": "bytes 0-15/137674442",
                ]
            ))
            for text in [
                " {\"error\":401}", "<html>Login</html>", "<!DOCTYPE html>",
                "<html>" + String(repeating: "需登录", count: 100),
            ] {
                XCTAssertTrue(httpMediaResponseLooksLikeErrorBody(response, data: Data(text.utf8)))
            }
            XCTAssertFalse(httpMediaResponseLooksLikeErrorBody(
                response,
                data: Data([0x3c, 0x01, 0x8a, 0x11])
            ))
        }
    }

    @MainActor
    func testUnavailableAudioSessionPreservesQueueAndAllowsSameSongRetry() async throws {
        let directory = try makeTemporaryDirectory()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "audio-session-\(UUID().uuidString)"))
        let settings = PlaybackSettingsStore(defaults: defaults)
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let seekActivation = expectation(description: "seek attempted audio activation")
        var activationCount = 0
        let player = AudioPlayerService(
            playbackSettings: settings,
            playbackSessionStore: store,
            activateAudioSession: { _ in
                activationCount += 1
                if activationCount == 3 { seekActivation.fulfill() }
                throw PlaybackAudioSessionFailure(NSError(
                    domain: NSOSStatusErrorDomain,
                    code: 560557684
                ))
            }
        )
        let songs = ["first", "second"].map {
            Song(
                id: $0,
                title: $0,
                duration: 100,
                fileFormat: .flac,
                filePath: "http://127.0.0.1/\($0).flac",
                sourceID: "audio-session-fixture"
            )
        }
        player.setQueue(songs)
        for attempt in 1...2 {
            await player.play(song: songs[0])
            XCTAssertEqual(activationCount, attempt)
            XCTAssertEqual(player.currentSong?.id, songs[0].id)
            XCTAssertEqual(player.currentIndex, 0)
            XCTAssertEqual(player.queue.map(\.id), songs.map(\.id))
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.isLoading)
        }
        player.seek(to: 42, startPlaying: false)
        await fulfillment(of: [seekActivation], timeout: 5)
        XCTAssertEqual(player.currentTime, 42)
        XCTAssertEqual(player.currentSong?.id, songs[0].id)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.queue.map(\.id), songs.map(\.id))
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
    }

    func testFirstChunkCanRegisterTrailingFillWithoutDeadlocking() async throws {
        let sourceID = "cloud-trailing-first-chunk-\(UUID().uuidString)"
        let directory = try makeTemporaryDirectory()
        let cacheURL = directory.appendingPathComponent("song.bin")
        let payload = Data(repeating: 0x31, count: Int(CloudPlaybackSource.chunkSize))
            + Data(repeating: 0x72, count: 32)
        let connector = FixtureRangeConnector(sourceID: sourceID, payload: payload)
        defer {
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            try? FileManager.default.removeItem(at: directory)
        }

        let input = try makeInputSource(
            sourceID: sourceID,
            cacheURL: cacheURL,
            payload: payload,
            connector: connector,
            allowsTrailingFill: true
        )
        let readFinished = expectation(description: "first chunk read returned")
        let readResult = LockedReadResult()
        let inputBox = InputSourceBox(input)
        DispatchQueue.global(qos: .userInitiated).async {
            readResult.store(Self.read(inputBox.input, byteCount: 4_096))
            readFinished.fulfill()
        }

        await fulfillment(of: [readFinished], timeout: 2)
        XCTAssertTrue(readResult.value.success, readResult.value.error ?? "read failed")
        XCTAssertEqual(readResult.value.bytesRead, 4_096)
        let promoted = await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: cacheURL.path)
        }
        XCTAssertTrue(
            promoted,
            "trailing fill did not promote the complete cache file"
        )
        XCTAssertEqual(try Data(contentsOf: cacheURL), payload)
        let backgroundFetchCount = await connector.backgroundFetchCount()
        XCTAssertEqual(backgroundFetchCount, 1)

        _ = CloudPlaybackSource.finalizeSession(
            partialPath: cacheURL.path + ".partial"
        )
        XCTAssertFalse(
            CloudPlaybackSource.activeSessionPaths().contains(cacheURL.path + ".partial")
        )
    }

    func testCancellationDuringTrailingFillCannotPolluteReplacementSession() async throws {
        let sourceID = "cloud-trailing-cancel-\(UUID().uuidString)"
        let directory = try makeTemporaryDirectory()
        let cacheURL = directory.appendingPathComponent("song.bin")
        let trailingGate = BlockingFetchGate()
        let oldPayload = Data(repeating: 0x11, count: Int(CloudPlaybackSource.chunkSize))
            + Data(repeating: 0x22, count: 64)
        let oldConnector = FixtureRangeConnector(
            sourceID: sourceID,
            payload: oldPayload,
            trailingGate: trailingGate
        )
        defer {
            Task { await trailingGate.release() }
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            try? FileManager.default.removeItem(at: directory)
        }

        let oldInput = try makeInputSource(
            sourceID: sourceID,
            cacheURL: cacheURL,
            payload: oldPayload,
            connector: oldConnector,
            allowsTrailingFill: true
        )
        let oldReadFinished = expectation(description: "old first chunk read returned")
        let oldInputBox = InputSourceBox(oldInput)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.read(oldInputBox.input, byteCount: 4_096)
            oldReadFinished.fulfill()
        }
        await fulfillment(of: [oldReadFinished], timeout: 2)
        let trailingStarted = await Self.waitUntilAsync(timeout: 2) {
            await trailingGate.hasStarted()
        }
        XCTAssertTrue(trailingStarted, "trailing fill did not start")
        guard trailingStarted else { return }

        let oldFinalization = CloudPlaybackSource.finalizeSession(
            partialPath: cacheURL.path + ".partial"
        )
        CloudPlaybackSource.cancelSessions(sourceID: sourceID)

        let replacementPayload = Data(
            repeating: 0x7E,
            count: Int(CloudPlaybackSource.chunkSize) + 64
        )
        let replacementConnector = FixtureRangeConnector(
            sourceID: sourceID,
            payload: replacementPayload
        )
        let replacementInput = try makeInputSource(
            sourceID: sourceID,
            cacheURL: cacheURL,
            payload: replacementPayload,
            connector: replacementConnector,
            allowsTrailingFill: false
        )
        let replacementRead = Self.read(replacementInput, byteCount: 4_096)
        XCTAssertTrue(replacementRead.success, replacementRead.error ?? "replacement read failed")

        await trailingGate.release()
        if let oldFinalization {
            let finalizationFinished = expectation(description: "cancelled trailing fill finished")
            Task {
                await oldFinalization.value
                finalizationFinished.fulfill()
            }
            await fulfillment(of: [finalizationFinished], timeout: 2)
        }

        let partialURL = URL(fileURLWithPath: cacheURL.path + ".partial")
        let replacementPrefix = try Data(contentsOf: partialURL)
        XCTAssertEqual(
            replacementPrefix,
            Data(replacementPayload.prefix(replacementPrefix.count))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        let oldBackgroundFetchCount = await oldConnector.backgroundFetchCount()
        XCTAssertEqual(oldBackgroundFetchCount, 1)
    }

    func testDisablingPersistenceDuringFinalizingFillCannotPromoteCache() async throws {
        let sourceID = "cloud-trailing-disable-\(UUID().uuidString)"
        let directory = try makeTemporaryDirectory()
        let cacheURL = directory.appendingPathComponent("song.bin")
        let trailingGate = BlockingFetchGate()
        let payload = Data(repeating: 0x45, count: Int(CloudPlaybackSource.chunkSize))
            + Data(repeating: 0x67, count: 48)
        let connector = FixtureRangeConnector(
            sourceID: sourceID,
            payload: payload,
            trailingGate: trailingGate
        )
        defer {
            Task { await trailingGate.release() }
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            try? FileManager.default.removeItem(at: directory)
        }

        var input: CloudInputSourceObjC? = try makeInputSource(
            sourceID: sourceID,
            cacheURL: cacheURL,
            payload: payload,
            connector: connector,
            allowsTrailingFill: true
        )
        let firstRead = Self.read(try XCTUnwrap(input), byteCount: 4_096)
        XCTAssertTrue(firstRead.success, firstRead.error ?? "read failed")
        let trailingStarted = await Self.waitUntilAsync(timeout: 2) {
            await trailingGate.hasStarted()
        }
        XCTAssertTrue(trailingStarted, "trailing fill did not start")
        guard trailingStarted else { return }

        let finalization = CloudPlaybackSource.finalizeSession(
            partialPath: cacheURL.path + ".partial"
        )
        input = nil
        CloudPlaybackSource.disablePersistenceForActiveSessions()
        await trailingGate.release()
        if let finalization {
            let finalizationFinished = expectation(description: "disabled trailing fill finished")
            Task {
                await finalization.value
                finalizationFinished.fulfill()
            }
            await fulfillment(of: [finalizationFinished], timeout: 2)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path + ".partial"))
        XCTAssertFalse(
            CloudPlaybackSource.activeSessionPaths().contains(cacheURL.path + ".partial")
        )
    }

    @MainActor
    func testPrewarmSeedPreservesBytesOwnedByActiveStreamingSession() async throws {
        let sourceID = "prewarm-ownership-\(UUID().uuidString)"
        let source = MusicSource(id: sourceID, name: "Prewarm Fixture", type: .webdav)
        let manager = SourceManager(sourcesProvider: { [source] })
        manager.setAutomaticAudioCachingEnabled(true)
        let song = Song(
            id: UUID().uuidString, title: "Prewarm Fixture", fileFormat: .flac,
            filePath: "/fixtures/\(UUID().uuidString).flac", sourceID: sourceID
        )
        let cache = manager.cacheURL(for: song)
        let partial = URL(fileURLWithPath: cache.path + ".partial")
        let marker = URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix)
        defer {
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }

        // Confirm the source is validated and ordinary seeds really write;
        // otherwise an unrelated scope guard could make this test pass.
        await manager.ensureOfflineAudioSnapshot(for: song)
        let initialHead = Data(repeating: 0x21, count: 4_096)
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            manager.seedPrewarmCache(song: song, head: initialHead)
            if !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertEqual(try Data(contentsOf: partial), initialHead)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.removeItem(at: partial)

        let payload = Data(repeating: 0x35, count: Int(CloudPlaybackSource.chunkSize) * 2)
        let connector = FixtureRangeConnector(sourceID: sourceID, payload: payload)
        let input = try makeInputSource(
            sourceID: sourceID, cacheURL: cache, payload: payload,
            connector: connector, allowsTrailingFill: false, prefetchAhead: 0
        )
        XCTAssertTrue(Self.read(input, byteCount: 4_096).success)
        XCTAssertTrue(CloudPlaybackSource.activeSessionPaths().contains(partial.path))
        XCTAssertFalse(manager.isPrewarmed(song: song))
        let before = try Data(contentsOf: partial)

        manager.seedPrewarmCache(song: song, head: Data(repeating: 0x79, count: 8_192))

        XCTAssertEqual(try Data(contentsOf: partial), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(Self.read(input, byteCount: 4_096, offset: 0).data, Data(repeating: 0x35, count: 4_096))
    }

    private func makeInputSource(
        sourceID: String,
        cacheURL: URL,
        payload: Data,
        connector: FixtureRangeConnector,
        allowsTrailingFill: Bool,
        prefetchAhead: Int = 0
    ) throws -> CloudInputSourceObjC {
        let song = Song(
            id: UUID().uuidString,
            title: "Concurrency Fixture",
            fileFormat: .flac,
            filePath: "/fixtures/song.flac",
            sourceID: sourceID
        )
        let ticket = CloudPlaybackSource.streamEpochTicket(sourceID: sourceID)
        let source = CloudPlaybackSource.makeInputSource(
            song: song,
            totalLength: Int64(payload.count),
            connector: connector,
            cacheURL: cacheURL,
            streamEpoch: ticket,
            persistOnComplete: true,
            prefetchAhead: prefetchAhead,
            allowsTrailingFill: allowsTrailingFill
        )
        return try XCTUnwrap(source as? CloudInputSourceObjC)
    }

    func testDefaultSidecarVerificationRejectsPartialAndTrailingPayloads() async throws {
        let expected = Data("[00:01.000]完整歌词".utf8)
        let exact = FixtureRangeConnector(sourceID: "sidecar-exact", payload: expected)
        try await exact.verifySidecarWrite(data: expected, at: "/song.lrc")

        let partial = FixtureRangeConnector(
            sourceID: "sidecar-partial",
            payload: Data(expected.dropLast())
        )
        do {
            try await partial.verifySidecarWrite(data: expected, at: "/song.lrc")
            XCTFail("partial sidecar unexpectedly passed verification")
        } catch is EmbeddedMetadataWritebackSourceError {}

        let trailing = FixtureRangeConnector(
            sourceID: "sidecar-trailing",
            payload: expected + Data("\n旧歌词残留".utf8)
        )
        do {
            try await trailing.verifySidecarWrite(data: expected, at: "/song.lrc")
            XCTFail("sidecar with stale trailing bytes unexpectedly passed verification")
        } catch is EmbeddedMetadataWritebackSourceError {}
    }

    @MainActor
    func testAdaptiveReadingPreservesAudioMetadata() async throws {
        var wav = Data("RIFF".utf8)
        func append16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
        func append32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
        append32(16_036)
        wav.append(Data("WAVEfmt ".utf8))
        append32(16); append16(1); append16(1)
        append32(8_000); append32(16_000); append16(2); append16(16)
        wav.append(Data("data".utf8)); append32(16_000)
        wav.append(Data(repeating: 0, count: 16_000))
        let audio = wav
        let profiles: [(String, MetadataBackfillExecutionLimits)] = [
            ("previous-foreground", .init(workerCount: 1, snapshotLimit: 24, interRequestDelay: 0.75, flushInterval: 15)),
            ("automatic", MetadataBackfillExecutionPolicy.limits(for: .foregroundAfterSourceScan, preference: .automatic))
        ]
        for (name, limits) in profiles {
            var completed: [Int] = []
            let scheduler = MetadataReadScheduler<Int, FileMetadataReader.Metadata>()
            let start = ContinuousClock.now
            await scheduler.run(items: Array(0..<12), limits: { limits }) { _ in
                await FileMetadataReader.read(from: audio, fileExtension: "wav")
            } completed: { index, metadata in
                XCTAssertEqual(metadata.duration ?? 0, 1, accuracy: 0.02)
                XCTAssertEqual(metadata.sampleRate, 8_000)
                completed.append(index)
            }
            XCTAssertEqual(completed.sorted(), Array(0..<12))
            print("MetadataReadingBenchmark profile=\(name) files=12 elapsed=\(start.duration(to: .now))")
        }
    }

    @MainActor
    func testLocalBackfillRecoversMiddleArtworkAndDoesNotRepeatACompleteMiss() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = "local-artwork-fallback-\(UUID().uuidString)"
        let source = MusicSource(
            id: sourceID,
            name: "Local artwork fixture",
            type: .local,
            basePath: directory.path
        )
        let coverData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let coveredPayload = Self.makeWaveFixture(middleCover: coverData)
        let uncoveredPayload = Self.makeWaveFixture(middleCover: nil)
        let coveredPath = "/covered.wav"
        let uncoveredPath = "/uncovered.wav"
        let coveredURL = directory.appendingPathComponent(String(coveredPath.dropFirst()))
        let uncoveredURL = directory.appendingPathComponent(String(uncoveredPath.dropFirst()))
        try coveredPayload.write(to: coveredURL)
        try uncoveredPayload.write(to: uncoveredURL)

        let connector = CompleteArtworkFixtureConnector(
            sourceID: sourceID,
            payloads: [coveredPath: coveredPayload, uncoveredPath: uncoveredPayload],
            localURLs: [coveredPath: coveredURL, uncoveredPath: uncoveredURL]
        )
        let manager = SourceManager(
            sourcesProvider: { [source] },
            connectorFactory: { _ in connector }
        )
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        let coveredSong = Song(
            id: "covered-\(UUID().uuidString)",
            title: "Covered",
            artistName: "Fixture Artist",
            duration: 1,
            fileFormat: .wav,
            filePath: coveredPath,
            sourceID: sourceID,
            fileSize: Int64(coveredPayload.count)
        )
        let uncoveredSong = Song(
            id: "uncovered-\(UUID().uuidString)",
            title: "Uncovered",
            artistName: "Fixture Artist",
            duration: 1,
            fileFormat: .wav,
            filePath: uncoveredPath,
            sourceID: sourceID,
            fileSize: Int64(uncoveredPayload.count)
        )
        library.addSongs([coveredSong, uncoveredSong], affectedSourceIDs: [sourceID])
        await library.waitForPendingIndex()

        let defaults = UserDefaults.standard
        let readingModeKey = MetadataBackfillExecutionPolicy.readingModeDefaultsKey
        let previousReadingMode = defaults.object(forKey: readingModeKey)
        defaults.set(MetadataReadingMode.automatic.rawValue, forKey: readingModeKey)
        defer {
            if let previousReadingMode {
                defaults.set(previousReadingMode, forKey: readingModeKey)
            } else {
                defaults.removeObject(forKey: readingModeKey)
            }
        }
        let backfill = MetadataBackfillService(
            library: library,
            sourceManager: manager,
            backfillableSourceIDs: { [sourceID] },
            offlineReadableSourceIDs: { [sourceID] },
            localFileSourceIDs: { [sourceID] },
            directFileSourceIDs: { [sourceID] }
        )
        defer { backfill.stop() }
        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCount(forSource: sourceID), 2)

        backfill.start()
        await backfill.waitUntilIdle()
        await library.waitForPendingIndex()

        let recovered = try XCTUnwrap(library.song(id: coveredSong.id))
        XCTAssertNotNil(recovered.coverArtFileName)
        let cachedCover = await MetadataAssetStore.shared.cachedCoverData(forSongID: coveredSong.id)
        XCTAssertEqual(cachedCover, coverData)
        XCTAssertNil(library.song(id: uncoveredSong.id)?.coverArtFileName)
        let firstCoveredRequestCount = await connector.localURLRequestCount(for: coveredPath)
        let firstUncoveredRequestCount = await connector.localURLRequestCount(for: uncoveredPath)
        XCTAssertEqual(firstCoveredRequestCount, 1)
        XCTAssertEqual(firstUncoveredRequestCount, 1)

        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCount(forSource: sourceID), 0)
        backfill.start()
        await backfill.waitUntilIdle()
        let finalCoveredRequestCount = await connector.localURLRequestCount(for: coveredPath)
        let finalUncoveredRequestCount = await connector.localURLRequestCount(for: uncoveredPath)
        XCTAssertEqual(finalCoveredRequestCount, 1)
        XCTAssertEqual(
            finalUncoveredRequestCount,
            1,
            "A confirmed complete-file artwork miss must remain in artworkGivenUpIDs"
        )
    }

    @MainActor
    func testOpaqueCloudFileTitleSurvivesFirstReadAndRepeatedTagReads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = "cloud-title-\(UUID().uuidString)"
        let source = MusicSource(id: sourceID, name: "Cloud title fixture", type: .pan123)
        let fileName = "走在冷风中 (Live) - 刘思涵.mp3"
        let payload = Self.duplicatedArtistTitleFixture()
        let localURL = directory.appendingPathComponent("cached.mp3")
        try payload.write(to: localURL)
        let connector = CompleteArtworkFixtureConnector(
            sourceID: sourceID, payloads: ["12345678": payload], localURLs: ["12345678": localURL]
        )
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        let song = Song(
            id: "title-\(UUID().uuidString)", title: "走在冷风中 (Live) - 刘思涵",
            fileFormat: .mp3, filePath: "12345678", sourceID: sourceID, fileSize: Int64(payload.count)
        )
        library.addSongs([song], affectedSourceIDs: [sourceID])
        await library.waitForPendingIndex()
        var indexedFileName: String?
        let defaults = UserDefaults.standard
        let readingModeKey = MetadataBackfillExecutionPolicy.readingModeDefaultsKey
        let previousReadingMode = defaults.object(forKey: readingModeKey)
        defaults.set(MetadataReadingMode.automatic.rawValue, forKey: readingModeKey)
        defer {
            if let previousReadingMode {
                defaults.set(previousReadingMode, forKey: readingModeKey)
            } else {
                defaults.removeObject(forKey: readingModeKey)
            }
        }
        let backfill = MetadataBackfillService(
            library: library, sourceManager: manager, backfillableSourceIDs: { [sourceID] },
            offlineReadableSourceIDs: { [sourceID] }, sourceFileName: { _ in indexedFileName }
        )
        defer { backfill.stop() }
        // The initial inventory row can be read before its directory index is committed.
        backfill.start()
        await backfill.waitUntilIdle()
        await library.waitForPendingIndex()
        XCTAssertEqual(library.song(id: song.id)?.title, "走在冷风中 (Live)")
        XCTAssertEqual(library.song(id: song.id)?.artistName, "刘思涵")

        indexedFileName = fileName
        var previouslyMisread = try XCTUnwrap(library.song(id: song.id))
        previouslyMisread.title = "刘思涵"
        library.addSongs([previouslyMisread], affectedSourceIDs: [sourceID])
        await library.waitForPendingIndex()
        for _ in 0..<2 {
            let result = await backfill.rereadTags(songID: song.id, expectedSourceID: sourceID)
            guard case .completed = result else { return XCTFail("Tag read did not complete: \(result)") }
            XCTAssertEqual(library.song(id: song.id)?.title, "走在冷风中 (Live)")
            XCTAssertEqual(library.song(id: song.id)?.filePath, "12345678")
        }
        XCTAssertEqual(try Data(contentsOf: localURL), payload)
        await library.waitForPendingIndex()
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Title corrections must finish persistence")
        }
    }

    @MainActor
    func testScrapingKeepsCorrectedTitleAcrossLocalAndRemoteReads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileName = "走在冷风中 (Live) - 刘思涵.mp3"
        let expectedTitle = "走在冷风中 (Live)"
        let payload = Self.duplicatedArtistTitleFixture()
        let localURL = directory.appendingPathComponent("cached.mp3")
        try payload.write(to: localURL)

        let defaults = UserDefaults.standard
        let previousSettings = defaults.object(forKey: ScraperSettings.defaultsKey)
        defer {
            if let previousSettings {
                defaults.set(previousSettings, forKey: ScraperSettings.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScraperSettings.defaultsKey)
            }
        }
        var settings = ScraperSettings.load()
        for index in settings.sources.indices { settings.sources[index].isEnabled = false }
        settings.save()
        XCTAssertTrue(ScraperSettings.load().enabledSources.isEmpty)

        let metadataService = MetadataService()
        let local = await metadataService.loadMetadata(
            for: localURL, allowOnlineFetch: false, trustedSource: false,
            fallbackTitle: (fileName as NSString).deletingPathExtension, discoverSidecars: false
        )
        let remote = await metadataService.loadEmbeddedMetadata(
            from: payload, fileExtension: "mp3", fallbackTitle: (fileName as NSString).deletingPathExtension
        )
        for metadata in [local, remote] {
            XCTAssertEqual(metadata.title, expectedTitle)
            XCTAssertEqual(metadata.artist, "刘思涵")
            XCTAssertEqual(metadata.embeddedTitle, "刘思涵", "Filename inference must not become an embedded tag")
        }

        // Local and streaming URLs enter the same branches used by cached and uncached cloud songs.
        for sourceType in [MusicSourceType.local, .pan123] {
            let sourceID = "scrape-title-\(UUID().uuidString)"
            let source = MusicSource(id: sourceID, name: "Title fixture", type: sourceType)
            let connector = CompleteArtworkFixtureConnector(
                sourceID: sourceID, payloads: ["12345678": payload], localURLs: ["12345678": localURL]
            )
            let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
            let scraper = MusicScraperService(sourceManager: manager, sourceFileName: { _ in fileName })
            var song = Song(
                id: "title-\(UUID().uuidString)", title: expectedTitle, artistName: "刘思涵",
                fileFormat: .mp3, filePath: "12345678", sourceID: sourceID, fileSize: Int64(payload.count)
            )
            let fallback = await scraper.suggestedScrapeTitle(for: song)
            let query = await scraper.suggestedSearchQuery(for: song)
            XCTAssertEqual(fallback, "走在冷风中 (Live) - 刘思涵")
            XCTAssertEqual(query, "走在冷风中 刘思涵")

            for onlyFillMissing in [true, false] {
                settings.onlyFillMissingFields = onlyFillMissing
                settings.save()
                for forceRescrape in [false, true] {
                    song.title = expectedTitle
                    let result = try await scraper.processedSongWithAssets(
                        song, forceRescrape: forceRescrape, storeAssets: false
                    )
                    XCTAssertEqual(result?.song.title, expectedTitle)
                    XCTAssertEqual(result?.song.artistName, "刘思涵")
                    if forceRescrape || !onlyFillMissing {
                        song.title = "刘思涵"
                        let repaired = try await scraper.processedSongWithAssets(
                            song, forceRescrape: forceRescrape, storeAssets: false
                        )
                        XCTAssertEqual(repaired?.song.title, expectedTitle)
                        XCTAssertEqual(repaired?.song.filePath, song.filePath)
                        let manualQuery = await scraper.suggestedSearchQuery(for: song)
                        XCTAssertEqual(manualQuery, "走在冷风中 刘思涵")
                    }
                }
            }
            let localReads = await connector.localURLRequestCount(for: song.filePath)
            if sourceType == .pan123 {
                XCTAssertEqual(localReads, 0, "Remote scraping must not download audio to repair its title")
            } else {
                XCTAssertGreaterThan(localReads, 0)
            }
        }
        XCTAssertEqual(try Data(contentsOf: localURL), payload)
    }

    fileprivate static func duplicatedArtistTitleFixture() -> Data {
        var body = Data()
        for (key, value) in [("TIT2", "刘思涵"), ("TPE1", "刘思涵"), ("TALB", "拥抱你")] {
            let text = Data([1]) + value.data(using: .utf16)!
            body += Data(key.utf8)
            body += Data([24, 16, 8, 0].map { UInt8((text.count >> $0) & 0xFF) })
            body += Data([0, 0]) + text
        }
        let size = Data([21, 14, 7, 0].map { UInt8((body.count >> $0) & 0x7F) })
        var payload = Data([0x49, 0x44, 0x33, 3, 0, 0]) + size + body
        for _ in 0..<100 {
            payload += Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        }
        return payload
    }

    func testLocalLyricsCreateAndReplaceThroughCanonicalRoot() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let source = LocalFileSource(sourceID: UUID().uuidString, basePath: alias)
        let path = "/2002 - Anne-Marie.lrc"
        let original = Data("[00:01]original lyrics with a longer ending".utf8)
        let replacement = Data("[00:01]updated".utf8)
        try await source.writeFile(data: original, to: path)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(String(path.dropFirst()))), original)
        try await source.writeFile(data: replacement, to: path)
        let readback = try await source.fetchRange(path: path, offset: 0, length: 1024)
        XCTAssertEqual(readback, replacement)
    }

    func testLocalLyricsRejectTraversalAndEscapingDirectorySymlink() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("music", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )
        let source = LocalFileSource(sourceID: UUID().uuidString, basePath: root)
        let sentinel = outside.appendingPathComponent("existing.lrc")
        let original = Data("original".utf8)
        try original.write(to: sentinel)
        for path in ["/../outside/new.lrc", "/escape/new.lrc", "/escape/existing.lrc"] {
            do {
                try await source.writeFile(data: Data("wrong".utf8), to: path)
                XCTFail("Unexpected write outside the selected music directory")
            } catch is SourceError {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.lrc").path))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
    }

    func testLocalLyricsUseMatchingBookmarkRoot() async throws {
        struct Reference: Encodable {
            let virtualPathComponent: String
            let bookmarkData: Data
            let isDirectory: Bool
        }
        let directory = try makeTemporaryDirectory()
        let sourceID = UUID().uuidString
        defer {
            LocalBookmarkStore.remove(sourceID: sourceID)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = directory.appendingPathComponent("first", isDirectory: true)
        let second = directory.appendingPathComponent("second", isDirectory: true)
        for root in [first, second] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let references = try [first, second].map { root in
            Reference(
                virtualPathComponent: root.lastPathComponent,
                bookmarkData: try root.bookmarkData(options: .minimalBookmark),
                isDirectory: true
            )
        }
        UserDefaults.standard.set(
            try JSONEncoder().encode(references), forKey: "primuse.localBookmarks.v1." + sourceID
        )
        let source = LocalFileSource(sourceID: sourceID, basePath: first)
        let bytes = Data("[00:01]second folder".utf8)
        try await source.writeFile(data: bytes, to: "/second/song.lrc")
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("song.lrc")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("song.lrc").path))
    }

    /// 「清缓存」的跳过判定必须挂在 session 是否还活着上, 而不是文件名后缀:
    /// 正在播放的 `.partial` 与正在下载的 `.offline` 要留下, 早就中断的
    /// `.partial` 照删; session 结束之后同一个文件立刻恢复可删。
    @MainActor
    func testClearSkipsOnlyLiveSessionPartialsAndRunningOfflineStaging() async throws {
        let sourceID = "cloud-clear-skip-\(UUID().uuidString)"
        let directory = try makeTemporaryDirectory()
        let cacheURL = directory.appendingPathComponent("song.bin")
        let payload = Data(repeating: 0x42, count: Int(CloudPlaybackSource.chunkSize) * 2)
        let connector = FixtureRangeConnector(sourceID: sourceID, payload: payload)
        defer {
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            try? FileManager.default.removeItem(at: directory)
        }

        let input = try makeInputSource(
            sourceID: sourceID,
            cacheURL: cacheURL,
            payload: payload,
            connector: connector,
            allowsTrailingFill: false
        )
        XCTAssertTrue(Self.read(input, byteCount: 4_096).success)
        let livePartial = cacheURL.path + ".partial"
        XCTAssertTrue(CloudPlaybackSource.activeSessionPaths().contains(livePartial))

        let stalePartial = directory.appendingPathComponent("other.bin.partial")
        let runningOffline = directory.appendingPathComponent("pinning.bin.offline")
        try Data(repeating: 9, count: 128).write(to: stalePartial)
        try Data(repeating: 9, count: 128).write(to: runningOffline)

        var protectedPaths = CloudPlaybackSource.activeSessionPaths()
        protectedPaths.insert(runningOffline.path)

        func shouldSkip(_ url: URL) -> Bool {
            SourceManager.audioCacheClearShouldSkip(
                fileURL: url,
                basePath: directory,
                pinnedRelativePaths: [],
                protectedAbsolutePaths: protectedPaths
            )
        }

        XCTAssertTrue(shouldSkip(URL(fileURLWithPath: livePartial)))
        XCTAssertTrue(shouldSkip(runningOffline))
        XCTAssertFalse(shouldSkip(stalePartial))

        // session 结束后同一个 `.partial` 不再受保护。
        CloudPlaybackSource.cancelSessions(sourceID: sourceID)
        XCTAssertFalse(
            SourceManager.audioCacheClearShouldSkip(
                fileURL: URL(fileURLWithPath: livePartial),
                basePath: directory,
                pinnedRelativePaths: [],
                protectedAbsolutePaths: CloudPlaybackSource.activeSessionPaths()
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrimuseCloudPlaybackConcurrency-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static func read(
        _ input: CloudInputSourceObjC,
        byteCount: Int,
        offset: Int? = nil
    ) -> ReadResult {
        do {
            try input.open()
            if let offset { try input.seek(toOffset: offset) }
            var buffer = [UInt8](repeating: 0, count: byteCount)
            let bytesRead = try buffer.withUnsafeMutableBytes { bytes in
                try input.read(bytes.baseAddress!, length: byteCount)
            }
            return ReadResult(
                success: true,
                bytesRead: bytesRead,
                error: nil,
                data: Data(buffer.prefix(bytesRead))
            )
        } catch {
            return ReadResult(
                success: false,
                bytesRead: 0,
                error: error.localizedDescription
            )
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func waitUntilAsync(
        timeout: TimeInterval,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: - Stream epoch registry

    /// 4MB 分块写入放在 `withCurrentStreamEpoch` 的闭包里。闭包执行期间, 解码
    /// 线程的 `isStreamEpochTicketCurrent` 与主 actor 的 `streamEpochTicket`/
    /// `activeSessionPaths` 不能再被全局 registryLock 挡在磁盘 I/O 后面。
    func testStreamEpochOperationDoesNotHoldTheRegistryDuringIO() async throws {
        let sourceID = "cloud-epoch-io-\(UUID().uuidString)"
        let otherSourceID = "cloud-epoch-other-\(UUID().uuidString)"
        let ticket = CloudPlaybackSource.streamEpochTicket(sourceID: sourceID)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let operationFinished = expectation(description: "epoch operation returned")
        DispatchQueue.global(qos: .userInitiated).async {
            let performed = CloudPlaybackSource.withCurrentStreamEpoch(
                sourceID: sourceID,
                epoch: ticket
            ) {
                entered.signal()
                release.wait()
                return true
            }
            XCTAssertTrue(performed == true)
            operationFinished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        let registryReadsFinished = expectation(description: "registry reads returned")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertTrue(
                CloudPlaybackSource.isStreamEpochTicketCurrent(sourceID: sourceID, ticket: ticket)
            )
            _ = CloudPlaybackSource.streamEpochTicket(sourceID: otherSourceID)
            _ = CloudPlaybackSource.activeSessionPaths()
            registryReadsFinished.fulfill()
        }
        await fulfillment(of: [registryReadsFinished], timeout: 1)

        release.signal()
        await fulfillment(of: [operationFinished], timeout: 5)
        CloudPlaybackSource.cancelSessions(sourceID: sourceID)
        CloudPlaybackSource.cancelSessions(sourceID: otherSourceID)
    }

    /// 排干语义不变: bump epoch 之后 `cancelSessions` 仍然要等已经通过校验的
    /// 那次写入结束才返回, 返回后旧 ticket 再也拿不到写入许可。
    func testCancelSessionsStillDrainsAnInFlightEpochOperation() async throws {
        let sourceID = "cloud-epoch-drain-\(UUID().uuidString)"
        let ticket = CloudPlaybackSource.streamEpochTicket(sourceID: sourceID)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        let operationFinished = expectation(description: "epoch operation returned")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CloudPlaybackSource.withCurrentStreamEpoch(
                sourceID: sourceID,
                epoch: ticket
            ) {
                entered.signal()
                release.wait()
                return true
            }
            operationFinished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        let cancelFinished = expectation(description: "cancelSessions returned")
        DispatchQueue.global(qos: .userInitiated).async {
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            cancelReturned.signal()
            cancelFinished.fulfill()
        }
        XCTAssertEqual(
            cancelReturned.wait(timeout: .now() + 0.3),
            .timedOut,
            "cancelSessions returned while an old-epoch write was still in flight"
        )

        release.signal()
        await fulfillment(of: [operationFinished, cancelFinished], timeout: 5)
        let afterCancel = CloudPlaybackSource.withCurrentStreamEpoch(
            sourceID: sourceID,
            epoch: ticket
        ) { true }
        XCTAssertNil(afterCancel)
    }

    // MARK: - Backfill batch selection

    /// 选取仍然从 index 0 开始按资料库顺序取到 limit 为止 —— runWorker 的
    /// 「同一批 ID 反复出现就停摆」保护依赖这个顺序; 同时它必须能在主 actor
    /// 之外跑出同样的结果。
    func testBackfillBatchSelectionKeepsLibraryOrderAndStopsAtTheLimit() async {
        let songs = Self.makeSelectionFixtureSongs()
        let input = Self.makeSelectionInput(songs: songs, limit: 8)
        let selection = MetadataBackfillService.selectBatch(input)
        XCTAssertEqual(selection.map(\.id), (0..<8).map { "bare-\($0)" })

        let offMain = await Task.detached { MetadataBackfillService.selectBatch(input) }.value
        XCTAssertEqual(offMain.map(\.id), selection.map(\.id))
    }

    func testBackfillBatchSelectionHonoursSourceGatesAndLimitFloor() {
        let songs = Self.makeSelectionFixtureSongs()
        XCTAssertEqual(
            MetadataBackfillService.selectBatch(
                Self.makeSelectionInput(songs: songs, limit: 0)
            ).map(\.id),
            ["bare-0"]
        )
        XCTAssertTrue(
            MetadataBackfillService.selectBatch(
                Self.makeSelectionInput(songs: songs, limit: 8, allowedSourceIDs: ["other"])
            ).isEmpty
        )
        XCTAssertTrue(
            MetadataBackfillService.selectBatch(
                Self.makeSelectionInput(songs: songs, limit: 8, disabledSourceIDs: ["remote"])
            ).isEmpty
        )
    }

    /// 只差专辑艺术家复查的行必须让位给刚扫进来的裸行。资料库按发现顺序
    /// 追加, 新行永远在数组末尾, 所以没有这一层分级, 一整轮全库复查就会把
    /// 用户刚加的那几首歌饿死在队尾。
    func testBackfillBatchSelectionDefersAlbumArtistRecheckBehindRealWork() {
        var songs: [Song] = []
        for index in 0..<30 {
            songs.append(
                Song(
                    id: "recheck-\(index)",
                    title: "Recheck \(index)",
                    albumTitle: "Compilation",
                    artistName: "Artist \(index)",
                    albumArtistName: "Artist \(index)",
                    duration: 200,
                    fileFormat: .flac,
                    filePath: "/recheck-\(index).flac",
                    sourceID: "remote"
                )
            )
        }
        // 扫描刚提交的新行: 没时长, 排在资料库数组的最后。
        songs.append(
            Song(
                id: "fresh-0",
                title: "Fresh",
                duration: 0,
                fileFormat: .flac,
                filePath: "/fresh-0.flac",
                sourceID: "remote"
            )
        )
        let input = Self.makeSelectionInput(
            songs: songs,
            limit: 4,
            bareOnlySourceIDs: ["remote"],
            failedSongIDs: [],
            titleCheckedIDs: Set((0..<30).map { "recheck-\($0)" }),
            albumArtistCheckedIDs: Set((0..<30).map { "recheck-\($0)" }),
            albumArtistUnconfirmedIDs: Set((0..<30).map { "recheck-\($0)" })
        )

        let selection = MetadataBackfillService.selectBatch(input)
        XCTAssertEqual(selection.first?.id, "fresh-0")
        XCTAssertEqual(
            selection.map(\.id),
            ["fresh-0", "recheck-0", "recheck-1", "recheck-2"]
        )
    }

    /// 队列里只剩复查行时仍然按资料库顺序取满一批 —— runWorker 的停摆保护
    /// 依赖这个顺序。
    func testBackfillBatchSelectionStillDrainsAlbumArtistRechecksWhenAlone() {
        var songs: [Song] = []
        for index in 0..<10 {
            songs.append(
                Song(
                    id: "recheck-\(index)",
                    title: "Recheck \(index)",
                    albumTitle: "Compilation",
                    artistName: "Artist \(index)",
                    albumArtistName: "Artist \(index)",
                    duration: 200,
                    fileFormat: .flac,
                    filePath: "/recheck-\(index).flac",
                    sourceID: "remote"
                )
            )
        }
        let input = Self.makeSelectionInput(
            songs: songs,
            limit: 3,
            bareOnlySourceIDs: ["remote"],
            failedSongIDs: [],
            titleCheckedIDs: Set((0..<10).map { "recheck-\($0)" }),
            albumArtistCheckedIDs: Set((0..<10).map { "recheck-\($0)" }),
            albumArtistUnconfirmedIDs: Set((0..<10).map { "recheck-\($0)" })
        )
        XCTAssertEqual(
            MetadataBackfillService.selectBatch(input).map(\.id),
            ["recheck-0", "recheck-1", "recheck-2"]
        )
    }

    /// 前 40 行被 failedSongIDs 排除, 后 10 行是可处理的空元数据行。
    private static func makeSelectionFixtureSongs() -> [Song] {
        var songs: [Song] = []
        for index in 0..<40 {
            songs.append(
                Song(
                    id: "skip-\(index)",
                    title: "Skip \(index)",
                    duration: 0,
                    fileFormat: .mp3,
                    filePath: "/skip-\(index).mp3",
                    sourceID: "remote"
                )
            )
        }
        for index in 0..<10 {
            songs.append(
                Song(
                    id: "bare-\(index)",
                    title: "Bare \(index)",
                    duration: 0,
                    fileFormat: .mp3,
                    filePath: "/bare-\(index).mp3",
                    sourceID: "remote"
                )
            )
        }
        return songs
    }

    private static func makeSelectionInput(
        songs: [Song],
        limit: Int,
        allowedSourceIDs: Set<String>? = nil,
        disabledSourceIDs: Set<String> = [],
        bareOnlySourceIDs: Set<String> = [],
        failedSongIDs: Set<String> = Set((0..<40).map { "skip-\($0)" }),
        titleCheckedIDs: Set<String> = [],
        albumArtistCheckedIDs: Set<String> = [],
        albumArtistUnconfirmedIDs: Set<String> = []
    ) -> MetadataBackfillService.BatchSelectionInput {
        MetadataBackfillService.BatchSelectionInput(
            songs: songs,
            limit: limit,
            scopedSourceID: nil,
            allowedSourceIDs: allowedSourceIDs,
            sourceIDs: ["remote"],
            bareOnlySourceIDs: bareOnlySourceIDs,
            disabledSourceIDs: disabledSourceIDs,
            manuallyReadingSongIDs: [],
            pendingFlushSongIDs: [],
            failedSongIDs: failedSongIDs,
            sourceIssueSongIDs: [],
            sessionGivenUpIDs: [],
            transientFailureCounts: [:],
            sourceTransientFailureCounts: [:],
            artworkGivenUpIDs: [],
            titleCheckedIDs: titleCheckedIDs,
            albumArtistCheckedIDs: albumArtistCheckedIDs,
            albumArtistUnconfirmedIDs: albumArtistUnconfirmedIDs,
            artistCheckedIDs: [],
            incompleteSongIDs: []
        )
    }

    private static func makeWaveFixture(middleCover: Data?) -> Data {
        func appendUInt16LE(_ value: UInt16, to data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt32LE(_ value: UInt32, to data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt32BE(_ value: UInt32, to data: inout Data) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        func syncSafe(_ value: Int) -> [UInt8] {
            [
                UInt8((value >> 21) & 0x7f),
                UInt8((value >> 14) & 0x7f),
                UInt8((value >> 7) & 0x7f),
                UInt8(value & 0x7f)
            ]
        }

        var wave = Data("RIFF".utf8)
        appendUInt32LE(0, to: &wave)
        wave.append(Data("WAVEfmt ".utf8))
        appendUInt32LE(16, to: &wave)
        appendUInt16LE(1, to: &wave)
        appendUInt16LE(1, to: &wave)
        appendUInt32LE(8_000, to: &wave)
        appendUInt32LE(16_000, to: &wave)
        appendUInt16LE(2, to: &wave)
        appendUInt16LE(16, to: &wave)
        let audioByteCount = 4 * 1_024 * 1_024 + 64 * 1_024
        wave.append(Data("data".utf8))
        appendUInt32LE(UInt32(audioByteCount), to: &wave)
        wave.append(Data(repeating: 0, count: audioByteCount))

        if let middleCover {
            var picturePayload = Data([0])
            picturePayload.append(Data("image/png".utf8))
            picturePayload.append(contentsOf: [0, 3, 0])
            picturePayload.append(middleCover)
            var pictureFrame = Data("APIC".utf8)
            appendUInt32BE(UInt32(picturePayload.count), to: &pictureFrame)
            pictureFrame.append(contentsOf: [0, 0])
            pictureFrame.append(picturePayload)
            var id3 = Data([0x49, 0x44, 0x33, 3, 0, 0])
            id3.append(contentsOf: syncSafe(pictureFrame.count))
            id3.append(pictureFrame)
            wave.append(Data("id3 ".utf8))
            appendUInt32LE(UInt32(id3.count), to: &wave)
            wave.append(id3)
            if id3.count % 2 != 0 { wave.append(0) }
            let trailingByteCount = 512 * 1_024
            wave.append(Data("JUNK".utf8))
            appendUInt32LE(UInt32(trailingByteCount), to: &wave)
            wave.append(Data(repeating: 0, count: trailingByteCount))
        }

        var riffSize = UInt32(wave.count - 8).littleEndian
        withUnsafeBytes(of: &riffSize) { bytes in
            wave.replaceSubrange(4..<8, with: bytes)
        }
        return wave
    }
}

private struct ReadResult: Sendable {
    let success: Bool
    let bytesRead: Int
    let error: String?
    var data: Data = Data()
}

private final class LockedReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ReadResult(success: false, bytesRead: 0, error: nil)

    var value: ReadResult {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: ReadResult) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class InputSourceBox: @unchecked Sendable {
    let input: CloudInputSourceObjC

    init(_ input: CloudInputSourceObjC) {
        self.input = input
    }
}

private actor BlockingFetchGate {
    private var started = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitAtGate() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor FetchRequestRecorder {
    private var backgroundCount = 0
    private var recordedRequests: [FixtureRangeRequest] = []

    func record(offset: Int64, length: Int64, priority: RangeFetchPriority) {
        recordedRequests.append(FixtureRangeRequest(offset: offset, length: length))
        if case .background = priority {
            backgroundCount += 1
        }
    }

    func backgroundFetchCount() -> Int {
        backgroundCount
    }

    func requests() -> [FixtureRangeRequest] { recordedRequests }
}

private struct FixtureRangeRequest: Sendable {
    let offset: Int64
    let length: Int64
}

private actor CompleteArtworkFixtureConnector: MusicSourceConnector {
    let sourceID: String
    private let payloads: [String: Data]
    private let localURLs: [String: URL]
    private var localURLRequests: [String: Int] = [:]

    init(sourceID: String, payloads: [String: Data], localURLs: [String: URL]) {
        self.sourceID = sourceID
        self.payloads = payloads
        self.localURLs = localURLs
    }

    func connect() async throws {}
    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }

    func localURL(for path: String) async throws -> URL {
        guard let url = localURLs[path] else { throw SourceError.fileNotFound(path) }
        localURLRequests[path, default: 0] += 1
        return url
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let payload = payloads[path]
        return AsyncThrowingStream { continuation in
            if let payload { continuation.yield(payload) }
            continuation.finish()
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchRange(
        path: String,
        offset: Int64,
        length: Int64,
        priority _: RangeFetchPriority
    ) async throws -> Data {
        guard let payload = payloads[path] else { throw SourceError.fileNotFound(path) }
        let start = offset >= 0 ? offset : Int64(payload.count) + offset
        guard start >= 0,
              length > 0,
              start < Int64(payload.count),
              let requestedEnd = SafeByteRange.exclusiveEnd(offset: start, length: length) else {
            return Data()
        }
        let end = min(requestedEnd, Int64(payload.count))
        return payload.subdata(in: Int(start)..<Int(end))
    }

    func localURLRequestCount(for path: String) -> Int {
        localURLRequests[path, default: 0]
    }
}

private final class FixtureRangeConnector: MusicSourceConnector, @unchecked Sendable {
    let sourceID: String
    private let payload: Data
    private let trailingGate: BlockingFetchGate?
    private let failsBackgroundFetch: Bool
    private let recorder = FetchRequestRecorder()

    init(
        sourceID: String,
        payload: Data,
        trailingGate: BlockingFetchGate? = nil,
        failsBackgroundFetch: Bool = false
    ) {
        self.sourceID = sourceID
        self.payload = payload
        self.trailingGate = trailingGate
        self.failsBackgroundFetch = failsBackgroundFetch
    }

    func connect() async throws {}
    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        []
    }

    func localURL(for path: String) async throws -> URL {
        throw SourceError.fileNotFound(path)
    }

    func streamData(
        for path: String
    ) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func scanAudioFiles(
        from path: String
    ) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchRange(
        path: String,
        offset: Int64,
        length: Int64,
        priority: RangeFetchPriority
    ) async throws -> Data {
        await recorder.record(offset: offset, length: length, priority: priority)
        if case .background = priority, let trailingGate {
            await trailingGate.waitAtGate()
        }
        if case .background = priority, failsBackgroundFetch { throw URLError(.networkConnectionLost) }
        guard offset >= 0,
              length > 0,
              offset < Int64(payload.count),
              let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
            return Data()
        }
        let upper = min(end, Int64(payload.count))
        return payload.subdata(in: Int(offset)..<Int(upper))
    }

    func backgroundFetchCount() async -> Int {
        await recorder.backgroundFetchCount()
    }

    func requests() async -> [FixtureRangeRequest] { await recorder.requests() }
}

private final class WebDAVLifecycleHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let authorization: String?
    }

    static let audio = Data("fLaC-webdav-lifecycle-fixture".utf8)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "WebDAVLifecycleHTTPServer")
    private let lock = NSLock()
    private let holdFirstListing: Bool
    private var recorded: [Request] = []
    private var connections: [NWConnection] = []
    private var didFinishStarting = false

    var requests: [Request] { lock.withLock { recorded } }

    init(holdFirstListing: Bool = false) throws {
        self.holdFirstListing = holdFirstListing
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<UInt16, Error>
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    result = .success(port.rawValue)
                case .failed(let error): result = .failure(error)
                default: return
                }
                let shouldResume = self.lock.withLock {
                    guard !self.didFinishStarting else { return false }
                    self.didFinishStarting = true
                    return true
                }
                if shouldResume { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.receive(on: connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        let active = lock.withLock { connections }
        active.forEach { $0.cancel() }
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            bytes.append(data ?? Data())
            if let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: bytes[..<headerEnd.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let requestLine = lines[0].split(separator: " ")
                let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                    guard let separator = line.firstIndex(of: ":") else { return nil }
                    return (line[..<separator].lowercased(),
                            line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
                }, uniquingKeysWith: { _, last in last })
                let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
                if requestLine.count >= 2, bytes.count >= headerEnd.upperBound + bodyLength {
                    self.respond(on: connection, request: Request(
                        method: String(requestLine[0]), path: String(requestLine[1]),
                        authorization: headers["authorization"]
                    ))
                    return
                }
            }
            guard !complete, error == nil, bytes.count < 1_048_576 else { connection.cancel(); return }
            self.receive(on: connection, accumulated: bytes)
        }
    }

    private func respond(on connection: NWConnection, request: Request) {
        let shouldHold = lock.withLock {
            recorded.append(request)
            return holdFirstListing && recorded.count == 1 && request.method == "PROPFIND"
        }
        if shouldHold { return }

        let status: String
        let contentType: String
        let body: Data
        if request.method == "PROPFIND", request.path == "/Music/" {
            status = "207 Multi-Status"
            contentType = "application/xml"
            body = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/Music/</D:href><D:propstat><D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
              <D:response><D:href>/Music/song.flac</D:href><D:propstat><D:prop>
                <D:displayname>song.flac</D:displayname><D:resourcetype/>
                <D:getcontentlength>\(Self.audio.count)</D:getcontentlength>
              </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            </D:multistatus>
            """.utf8)
        } else if request.method == "GET", request.path == "/Music/song.flac" {
            status = "200 OK"
            contentType = "audio/flac"
            body = Self.audio
        } else {
            status = "401 Unauthorized"
            contentType = "text/plain"
            body = Data()
        }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}


final class Pan123MetadataWritebackTests: XCTestCase {
    func testChunkedAndReusedUploadsPreserveNameAndReturnCommittedIdentity() async throws {
        for mode in [Pan123MetadataHTTPFixture.Mode.chunked, .reuse, .sameID, .lostComplete] {
            let fixture = Pan123MetadataHTTPFixture(mode: mode)
            let (connector, session) = fixture.connector()
            defer { session.invalidateAndCancel(); fixture.remove() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try fixture.payload.write(to: url)
            let expected = try await connector.metadataWritebackState(for: "42")
            let path = try await connector.replaceMetadataFileReturningPath(at: "42", with: url, expected: expected)
            XCTAssertEqual(path, mode == .sameID ? "42" : "99")
            XCTAssertEqual(fixture.createCount, 1)
            XCTAssertEqual(fixture.completeCount, mode == .reuse ? 0 : 1)
            if mode != .reuse { XCTAssertEqual(fixture.receivedSlices, fixture.payload) }
        }
    }

    func testConflictingAndAmbiguousFilesAreNeverCommitted() async throws {
        for mode in [Pan123MetadataHTTPFixture.Mode.changedDuringUpload, .ambiguousName] {
            let fixture = Pan123MetadataHTTPFixture(mode: mode)
            let (connector, session) = fixture.connector()
            defer { session.invalidateAndCancel(); fixture.remove() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try fixture.payload.write(to: url)
            let expected = try await connector.metadataWritebackState(for: "42")
            do {
                _ = try await connector.replaceMetadataFileReturningPath(at: "42", with: url, expected: expected)
                XCTFail("A conflicting source must not be replaced")
            } catch EmbeddedMetadataWritebackSourceError.conflict { }
            XCTAssertEqual(fixture.completeCount, 0)
            if mode == .ambiguousName { XCTAssertEqual(fixture.createCount, 0) }
        }
    }

    func testCommittedIDSurvivesFailedProviderVerification() async throws {
        let fixture = Pan123MetadataHTTPFixture(mode: .wrongReadback)
        let (connector, session) = fixture.connector()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.payload.write(to: url)
        let expected = try await connector.metadataWritebackState(for: "42")
        do {
            _ = try await connector.replaceMetadataFileReturningPath(at: "42", with: url, expected: expected)
            XCTFail("A mismatched remote file must fail verification")
        } catch let error as EmbeddedMetadataReplacementReadbackError {
            XCTAssertEqual(error.filePath, "99")
        }
    }

    @MainActor
    func testTagAndLyricsWritebackRetargetExistingSongEvenWhenReadbackFails() async throws {
        for failReadback in [false, true] {
            for lyricsOnly in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("original.mp3")
                let payload = CloudPlaybackSourceConcurrencyTests.duplicatedArtistTitleFixture()
                try payload.write(to: url)
                let connector = RelocatingMetadataFixture(sourceURL: url, failReadback: failReadback)
                let source = MusicSource(id: connector.sourceID, name: "123 fixture", type: .pan123)
                let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
                let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
                let scan = ScanService(fileManager: MetadataWritebackTestFileManager(root: directory))
                let song = Song(id: "kept-song", title: "Original", artistName: "Artist", fileFormat: .mp3,
                                filePath: "42", sourceID: source.id, fileSize: Int64(payload.count), revision: "before")
                var requested = song
                requested.title = "Corrected"
                library.addSongs([song], affectedSourceIDs: [source.id])
                await library.waitForPendingIndex()
                manager.metadataFileReplacementHandler = { original, updated in
                    try await scan.recordMetadataFileReplacement(original: original, updated: updated, in: library)
                }
                if lyricsOnly {
                    do {
                        let updated = try await manager.writeEmbeddedLyrics(.keep, for: song)
                        XCTAssertFalse(failReadback)
                        XCTAssertEqual(updated.filePath, "99")
                    } catch {
                        XCTAssertTrue(failReadback, "Unexpected error: \(error)")
                    }
                } else {
                    let report = try await manager.writeTagMetadata(original: song, updated: requested, coverData: nil)
                    XCTAssertEqual(report.hasFailures, failReadback)
                    XCTAssertEqual(report.shouldAbortLocalSave, failReadback)
                    if !failReadback { XCTAssertEqual(report.updatedSong.filePath, "99") }
                }
                XCTAssertEqual(library.song(id: song.id)?.filePath, "99")
                // Location persistence must not prematurely apply requested tags.
                XCTAssertEqual(library.song(id: song.id)?.title, "Original")
                XCTAssertEqual(library.songs.count, 1)
                let reads = await connector.readPaths
                XCTAssertEqual(reads, ["42", "99"])
                try await library.persistIncrementalNowAndWait().get()
            }
        }
    }
}

private final class MetadataWritebackTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}

private actor RelocatingMetadataFixture: EmbeddedMetadataWritebackAdapter {
    nonisolated let sourceID = "relocating-fixture"
    let sourceURL: URL
    let failReadback: Bool
    var replacedURL: URL?
    private(set) var readPaths: [String] = []
    init(sourceURL: URL, failReadback: Bool) { self.sourceURL = sourceURL; self.failReadback = failReadback }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func localURL(for path: String) async throws -> URL {
        readPaths.append(path)
        if path == "99", failReadback { throw URLError(.networkConnectionLost) }
        return path == "42" ? sourceURL : replacedURL!
    }
    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        let url = path == "42" ? sourceURL : replacedURL!
        return .init(fileSize: Int64(try Data(contentsOf: url).count), modifiedDate: nil, revision: path == "42" ? "before" : "after")
    }
    func replaceMetadataFile(at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState) async throws {
        XCTFail("Coordinator must use the returned location")
    }
    func replaceMetadataFileReturningPath(at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState) async throws -> String {
        let destination = sourceURL.deletingLastPathComponent().appendingPathComponent("replaced.mp3")
        try FileManager.default.copyItem(at: localURL, to: destination)
        replacedURL = destination
        return "99"
    }
}

private final class Pan123MetadataHTTPFixture: @unchecked Sendable {
    enum Mode { case chunked, reuse, sameID, lostComplete, changedDuringUpload, ambiguousName, wrongReadback }
    let mode: Mode
    let token = UUID().uuidString
    let payload = Data("audio-tag-replacement-contents".utf8)
    var createCount = 0
    var completeCount = 0
    var receivedSlices = Data()
    private var committed = false
    private var editedMD5 = ""
    private var editedSize = 0
    private let lock = NSLock()
    init(mode: Mode) { self.mode = mode }
    func connector() -> (Pan123Source, URLSession) {
        Pan123MetadataURLProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Pan123MetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (Pan123Source(sourceID: token, session: session, tokenProvider: { [token] in token }), session)
    }
    func remove() { Pan123MetadataURLProtocol.remove(token) }
    func response(_ request: URLRequest) throws -> Data {
        try lock.withLock {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Platform"), "open_platform")
            let oldMD5 = String(repeating: mode == .changedDuringUpload && !receivedSlices.isEmpty ? "b" : "a", count: 32)
            let id = committed && mode != .sameID ? 99 : 42
            let md5 = committed ? (mode == .wrongReadback ? String(repeating: "c", count: 32) : editedMD5) : oldMD5
            let size = committed ? editedSize : 123
            func file() -> [String: Any] {
                ["fileID": id, "fileId": id, "filename": "Song - Artist.mp3", "parentFileID": 7,
                 "type": 0, "trashed": 0, "size": size, "etag": md5]
            }
            let data: [String: Any]
            switch url.path {
            case "/api/v1/file/detail": data = file()
            case "/api/v2/file/list":
                data = ["fileList": mode == .ambiguousName ? [file(), file()] : [file()], "lastFileId": -1]
            case "/upload/v2/file/create":
                createCount += 1
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                XCTAssertEqual(body["filename"] as? String, "Song - Artist.mp3")
                XCTAssertEqual(body["parentFileID"] as? Int, 7)
                XCTAssertEqual(body["duplicate"] as? Int, 2)
                editedMD5 = try XCTUnwrap(body["etag"] as? String)
                editedSize = try XCTUnwrap(body["size"] as? Int)
                XCTAssertEqual(editedMD5, Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined())
                if mode == .reuse { committed = true; data = ["reuse": true, "fileID": 99] }
                else { data = ["reuse": false, "preuploadID": "fixture-upload", "sliceSize": 7, "servers": ["https://upload.example.test"]] }
            case "/upload/v2/file/slice":
                let body = try Self.body(request)
                let marker = Data("Content-Type: application/octet-stream\r\n\r\n".utf8)
                let start = try XCTUnwrap(body.range(of: marker)).upperBound
                let end = try XCTUnwrap(body.range(of: Data("\r\n--".utf8), in: start..<body.endIndex)).lowerBound
                let slice = body.subdata(in: start..<end)
                let hash = Insecure.MD5.hash(data: slice).map { String(format: "%02x", $0) }.joined()
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("name=\"sliceMD5\"\r\n\r\n\(hash)\r\n"))
                XCTAssertLessThanOrEqual(slice.count, 7)
                receivedSlices.append(slice)
                data = [:]
            case "/upload/v2/file/upload_complete":
                completeCount += 1
                XCTAssertEqual(receivedSlices, payload)
                committed = true
                if mode == .lostComplete { throw URLError(.networkConnectionLost) }
                data = ["completed": true, "fileID": mode == .sameID ? 42 : 99]
            default: throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
        }
    }
    fileprivate static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.unknown) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class Pan123MetadataURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: Pan123MetadataHTTPFixture] = [:]
    static func register(_ fixture: Pan123MetadataHTTPFixture) { lock.withLock { fixtures[fixture.token] = fixture } }
    static func remove(_ token: String) { _ = lock.withLock { fixtures.removeValue(forKey: token) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
            let fixture = try XCTUnwrap(Self.lock.withLock { Self.fixtures[token] })
            let data = try fixture.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}


final class DrimeMetadataWritebackTests: XCTestCase {
    func testReplacementStreamsChunksAndVerifiesBeforeRetiringOriginal() async throws {
        for size in [37, DrimeAPIProtocol.multipartPartSize + 17] {
            let fixture = DrimeMetadataHTTPFixture(mode: .success, size: size)
            try await exercise(fixture) { connector, url, expected in
                let path = try await connector.replaceMetadataFileReturningPath(at: "42", with: url, expected: expected)
                XCTAssertEqual(path, "99")
                XCTAssertTrue(fixture.oldTrashed)
                XCTAssertFalse(fixture.stagedTrashed)
                XCTAssertEqual(fixture.stageName, "Song - Artist.mp3")
                XCTAssertEqual(fixture.uploaded, fixture.payload)
                XCTAssertEqual(fixture.parts.count, size > DrimeAPIProtocol.multipartPartSize ? 2 : 1)
                XCTAssertLessThanOrEqual(fixture.parts.map(\.count).max() ?? 0, DrimeAPIProtocol.multipartPartSize)
            }
        }
    }

    func testConflictOrBadUploadNeverRemovesOriginal() async throws {
        for mode in [DrimeMetadataHTTPFixture.Mode.conflict, .badUpload] {
            let fixture = DrimeMetadataHTTPFixture(mode: mode)
            try await exercise(fixture) { connector, url, expected in
                do {
                    _ = try await connector.replaceMetadataFileReturningPath(at: "42", with: url, expected: expected)
                    XCTFail("Conflicting or corrupt replacement must fail")
                } catch {
                    XCTAssertFalse(error is EmbeddedMetadataReplacementReadbackError)
                }
                XCTAssertFalse(fixture.oldTrashed)
                XCTAssertTrue(fixture.stagedTrashed)
                XCTAssertEqual(fixture.originalDeleteAttempts, 0)
            }
        }
    }

    func testFailedRenameRestoresOriginalAndLostResponseResolvesCommittedFile() async throws {
        for mode in [DrimeMetadataHTTPFixture.Mode.renameFailure, .lostRename, .trashFailure] {
            let fixture = DrimeMetadataHTTPFixture(mode: mode)
            try await exercise(fixture) { connector, url, expected in
                do {
                    let path = try await connector.replaceMetadataFileReturningPath(at: "42", with: url, expected: expected)
                    XCTAssertEqual(mode, .lostRename)
                    XCTAssertEqual(path, "99")
                    XCTAssertEqual(fixture.stageName, "Song - Artist.mp3")
                } catch { XCTAssertNotEqual(mode, .lostRename) }
                if mode != .lostRename {
                    XCTAssertFalse(fixture.oldTrashed)
                    XCTAssertTrue(fixture.stagedTrashed)
                }
            }
        }
    }

    func testFailedRestoreRetainsVerifiedReplacementAndReturnsItsLocation() async throws {
        let fixture = DrimeMetadataHTTPFixture(mode: .restoreFailure)
        try await exercise(fixture) { connector, url, expected in
            do {
                _ = try await connector.replaceMetadataFileReturningPath(at: "42", with: url, expected: expected)
                XCTFail("A failed restoration must be reported")
            } catch let error as EmbeddedMetadataReplacementReadbackError {
                XCTAssertEqual(error.filePath, "99")
                XCTAssertEqual(error.fileSize, Int64(fixture.payload.count))
            }
            XCTAssertTrue(fixture.verified)
            XCTAssertTrue(fixture.oldTrashed)
            XCTAssertFalse(fixture.stagedTrashed, "Keep the verified copy reachable if restoration fails")
        }
    }

    private func exercise(
        _ fixture: DrimeMetadataHTTPFixture,
        operation: (DrimeSource, URL, EmbeddedMetadataRemoteFileState) async throws -> Void
    ) async throws {
        let (connector, session) = fixture.connector()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.payload.write(to: url)
        let expected = try await connector.metadataWritebackState(for: "42")
        try await operation(connector, url, expected)
    }
}

private final class DrimeMetadataHTTPFixture: @unchecked Sendable {
    enum Mode { case success, conflict, badUpload, renameFailure, lostRename, trashFailure, restoreFailure }
    let mode: Mode
    let token = UUID().uuidString.lowercased()
    let payload: Data
    private let lock = NSLock()
    var oldTrashed = false
    var stagedTrashed = false
    var stageName = ""
    var parts: [Data] = []
    var uploaded = Data()
    var verified = false
    var originalDeleteAttempts = 0
    private var registered = false
    private var originalChanged = false
    init(mode: Mode, size: Int = 37) { self.mode = mode; payload = Data(repeating: 0x57, count: size) }
    func connector() -> (DrimeSource, URLSession) {
        DrimeMetadataURLProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DrimeMetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (DrimeSource(sourceID: token, session: session, tokenProvider: { [token] in token }), session)
    }
    func remove() { DrimeMetadataURLProtocol.remove(token) }
    func response(_ request: URLRequest) throws -> Data {
        try lock.withLock {
            let url = try XCTUnwrap(request.url)
            if url.host?.hasSuffix(".uploads.example.test") != true {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            } else {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "S3 presigned PUT must not receive the account token")
            }
            func entry(_ id: Int, _ name: String, _ size: Int) -> [String: Any] {
                ["id": id, "name": name, "file_size": size, "parent_id": 7, "type": "audio",
                 "file_hash": String(repeating: id == 42 ? (originalChanged ? "b" : "a") : "c", count: 64),
                 "updated_at": "2026-09-22T00:00:00.000Z", "url": "/api/v1/file-entries/\(id)"]
            }
            let body = try Pan123MetadataHTTPFixture.body(request)
            let json = body.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            var result: [String: Any] = ["status": "success"]
            switch url.path {
            case "/api/v1/drive/file-entries":
                let parent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "parentIds" }?.value
                var entries: [[String: Any]] = []
                if parent == nil { entries = [["id": 7, "name": "Music", "type": "folder"]] }
                else {
                    if !oldTrashed { entries.append(entry(42, "Song - Artist.mp3", 123)) }
                    if registered && !stagedTrashed { entries.append(entry(99, stageName, payload.count)) }
                }
                result = ["data": entries, "current_page": 1, "last_page": 1]
            case "/api/v1/s3/multipart/create":
                stageName = try XCTUnwrap(json["filename"] as? String)
                XCTAssertTrue(stageName.hasSuffix(".tmp"))
                XCTAssertEqual(json["mime"] as? String, "audio/mpeg")
                XCTAssertEqual(json["extension"] as? String, "mp3")
                result.merge(["key": "uploads/object-storage-name", "uploadId": "upload-fixture"]) { _, new in new }
            case "/api/v1/s3/multipart/batch-sign-part-urls":
                let numbers = try XCTUnwrap(json["partNumbers"] as? [Int])
                result["urls"] = numbers.map { ["partNumber": $0, "url": "https://\(token).uploads.example.test/part/\($0)"] as [String: Any] }
            case let path where path.hasPrefix("/part/"):
                parts.append(body)
                uploaded.append(body)
            case "/api/v1/s3/multipart/complete":
                XCTAssertEqual(uploaded, payload)
            case "/api/v1/s3/entries":
                registered = true
                XCTAssertEqual(json["clientName"] as? String, stageName)
                XCTAssertEqual(json["clientExtension"] as? String, "mp3")
                XCTAssertEqual(json["parentId"] as? String, "7")
                result["fileEntry"] = entry(99, stageName, payload.count)
            case "/api/v1/file-entries/99/verify-integrity":
                let hash = SHA256.hash(data: uploaded).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(json["sha256"] as? String, hash)
                verified = mode != .badUpload
                result["verified"] = verified
                result["serverHash"] = hash
                if mode == .conflict { originalChanged = true }
            case "/api/v1/file-entries/delete":
                let ids = try XCTUnwrap(json["entryIds"] as? [String])
                XCTAssertEqual(json["deleteForever"] as? Bool, false)
                if ids.contains("42") {
                    originalDeleteAttempts += 1
                    XCTAssertTrue(verified, "Never remove the original before verifying replacement bytes")
                    if mode == .trashFailure { throw URLError(.cannotConnectToHost) }
                    oldTrashed = true
                }
                if ids.contains("99") { stagedTrashed = true }
            case "/api/v1/file-entries/restore":
                if mode == .restoreFailure { throw URLError(.cannotConnectToHost) }
                oldTrashed = false
            case "/api/v1/file-entries/99":
                XCTAssertEqual(request.httpMethod, "PUT")
                if mode == .renameFailure || mode == .restoreFailure { throw URLError(.cannotConnectToHost) }
                stageName = try XCTUnwrap(json["name"] as? String)
                if mode == .lostRename { throw URLError(.networkConnectionLost) }
                result["fileEntry"] = entry(99, stageName, payload.count)
            case "/api/v1/s3/multipart/abort": break
            default: throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }
}

private final class DrimeMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: DrimeMetadataHTTPFixture] = [:]
    static func register(_ fixture: DrimeMetadataHTTPFixture) { lock.withLock { fixtures[fixture.token] = fixture } }
    static func remove(_ token: String) { _ = lock.withLock { fixtures.removeValue(forKey: token) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
            let fixture = try XCTUnwrap(Self.lock.withLock {
                Self.fixtures[token] ?? request.url?.host.flatMap { host in
                    guard host.hasSuffix(".uploads.example.test") else { return nil }
                    return Self.fixtures[String(host.dropLast(".uploads.example.test".count))]
                }
            })
            let data = try fixture.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "fixture-part-hash"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
