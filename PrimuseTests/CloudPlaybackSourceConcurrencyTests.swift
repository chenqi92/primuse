import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class CloudPlaybackSourceConcurrencyTests: XCTestCase {
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
        let trailingStarted = await waitUntilAsync(timeout: 2) {
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
        let trailingStarted = await waitUntilAsync(timeout: 2) {
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

    private func makeInputSource(
        sourceID: String,
        cacheURL: URL,
        payload: Data,
        connector: FixtureRangeConnector,
        allowsTrailingFill: Bool
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
            prefetchAhead: 0,
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
        byteCount: Int
    ) -> ReadResult {
        do {
            try input.open()
            var buffer = [UInt8](repeating: 0, count: byteCount)
            let bytesRead = try buffer.withUnsafeMutableBytes { bytes in
                try input.read(bytes.baseAddress!, length: byteCount)
            }
            return ReadResult(
                success: true,
                bytesRead: bytesRead,
                error: nil
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

    private func waitUntilAsync(
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

    func record(priority: RangeFetchPriority) {
        if case .background = priority {
            backgroundCount += 1
        }
    }

    func backgroundFetchCount() -> Int {
        backgroundCount
    }
}

private final class FixtureRangeConnector: MusicSourceConnector, @unchecked Sendable {
    let sourceID: String
    private let payload: Data
    private let trailingGate: BlockingFetchGate?
    private let recorder = FetchRequestRecorder()

    init(
        sourceID: String,
        payload: Data,
        trailingGate: BlockingFetchGate? = nil
    ) {
        self.sourceID = sourceID
        self.payload = payload
        self.trailingGate = trailingGate
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
        await recorder.record(priority: priority)
        if case .background = priority, let trailingGate {
            await trailingGate.waitAtGate()
        }
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
}
