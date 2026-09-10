import AVFoundation
import Foundation
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
