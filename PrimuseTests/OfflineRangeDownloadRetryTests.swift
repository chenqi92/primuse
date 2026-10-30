import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class OfflineRangeDownloadRetryTests: XCTestCase {
    private actor Script {
        var responses: [Result<Data, Error>]
        var offsets: [Int64] = []
        var delays: [TimeInterval] = []

        init(_ responses: [Result<Data, Error>]) { self.responses = responses }

        func fetch(offset: Int64, length: Int64) throws -> Data {
            offsets.append(offset)
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            return try responses.removeFirst().get()
        }

        func wait(_ delay: TimeInterval) { delays.append(delay) }
    }

    func testOnlyFailedChunkIsRetriedAtTheSameOffset() async throws {
        let script = Script([
            .success(Data("abcd".utf8)),
            .failure(URLError(.networkConnectionLost)),
            .success(Data("efgh".utf8)),
        ])
        var bytes = Data()
        for offset: Int64 in [0, 4] {
            bytes.append(try await OfflineRangeDownloadRetry.fetch(
                offset: offset, length: 4,
                wait: { await script.wait($0) },
                request: { try await script.fetch(offset: $0, length: $1) }
            ))
        }
        let offsets = await script.offsets
        XCTAssertEqual(offsets, [0, 4, 4])
        XCTAssertEqual(bytes, Data("abcdefgh".utf8))
    }

    func testPersistentServerFailureStopsAfterThreeAttempts() async {
        let failure = RemoteMediaHTTPError(service: "Fixture", statusCode: 503)
        let script = Script(Array(repeating: .failure(failure), count: 3))
        do {
            _ = try await OfflineRangeDownloadRetry.fetch(
                offset: 16, length: 4,
                wait: { await script.wait($0) },
                request: { try await script.fetch(offset: $0, length: $1) }
            )
            XCTFail("Expected the final server error")
        } catch {
            XCTAssertEqual((error as? RemoteMediaHTTPError)?.statusCode, 503)
        }
        let offsets = await script.offsets
        let delays = await script.delays
        XCTAssertEqual(offsets, [16, 16, 16])
        XCTAssertEqual(delays, [1, 2])
    }

    func testRateLimitHonorsRetryAfterBeforeRecovering() async throws {
        let script = Script([
            .failure(RemoteMediaHTTPError(service: "Fixture", statusCode: 429, retryAfter: 7)),
            .success(Data([1, 2])),
        ])
        let data = try await OfflineRangeDownloadRetry.fetch(
            offset: 0, length: 2,
            wait: { await script.wait($0) },
            request: { try await script.fetch(offset: $0, length: $1) }
        )
        let delays = await script.delays
        XCTAssertEqual(delays, [7])
        XCTAssertEqual(data, Data([1, 2]))
    }

    func testPermanentAndCancelledFailuresDoNotRetry() async {
        let errors: [Error] = [
            RemoteMediaHTTPError(service: "Fixture", statusCode: 401),
            RemoteMediaHTTPError(service: "Fixture", statusCode: 403),
            RemoteMediaHTTPError(service: "Fixture", statusCode: 404),
            RemoteMediaHTTPError(service: "Fixture", statusCode: 429, retryAfter: 120),
            URLError(.serverCertificateUntrusted), URLError(.cancelled), CancellationError(),
            OfflineTransferValidationError.invalidContentRange,
            OfflineTransferValidationError.oversized(actual: 8, maximum: 4),
        ]
        for error in errors {
            let script = Script([.failure(error)])
            do {
                _ = try await OfflineRangeDownloadRetry.fetch(
                    offset: 0, length: 4,
                    wait: { await script.wait($0) },
                    request: { try await script.fetch(offset: $0, length: $1) }
                )
                XCTFail("Expected failure: \(error)")
            } catch {}
            let offsets = await script.offsets
            let delays = await script.delays
            XCTAssertEqual(offsets.count, 1)
            XCTAssertTrue(delays.isEmpty)
        }
    }

    func testCancellationDuringBackoffDoesNotStartAnotherRequest() async {
        let script = Script([.failure(URLError(.timedOut))])
        do {
            _ = try await OfflineRangeDownloadRetry.fetch(
                offset: 0, length: 4,
                wait: { _ in throw CancellationError() },
                request: { try await script.fetch(offset: $0, length: $1) }
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let offsets = await script.offsets
        XCTAssertEqual(offsets.count, 1)
    }

    func testShortResponseIsDiscardedBeforeRetrying() async throws {
        let script = Script([.success(Data([9])), .success(Data([1, 2]))])
        let data = try await OfflineRangeDownloadRetry.fetch(
            offset: 10, length: 2,
            wait: { await script.wait($0) },
            request: { try await script.fetch(offset: $0, length: $1) }
        )
        let offsets = await script.offsets
        XCTAssertEqual(offsets, [10, 10])
        XCTAssertEqual(data, Data([1, 2]))
    }

    @MainActor
    func testLegacyServerSTRMUsesMediaEndpointWithoutReadingDescriptorBytes() async throws {
        for type: MusicSourceType in [.emby, .jellyfin, .plex, .subsonic, .navidrome, .airsonic, .gonic] {
            let source = MusicSource(id: UUID().uuidString, name: "Fixture", type: type)
            let manager = SourceManager(sourcesProvider: { [source] })
            let connector = DescriptorConnector(sourceID: source.id)
            let song = Song(id: "legacy", title: "Legacy", fileFormat: .mp3,
                            filePath: "/items/track.strm", sourceID: source.id, fileSize: 64)
            let target = try await manager.resolveSTRMTarget(for: song, connector: connector)
            guard case .sourcePath(let path) = target else {
                XCTFail("Expected the server item endpoint")
                continue
            }
            XCTAssertEqual(path, song.filePath)
            let reads = await connector.reads
            XCTAssertEqual(reads, 0)
        }
    }

    @MainActor
    func testFileSourceSTRMStillReadsAndResolvesDescriptor() async throws {
        let source = MusicSource(id: UUID().uuidString, name: "Fixture", type: .webdav)
        let manager = SourceManager(sourcesProvider: { [source] })
        let connector = DescriptorConnector(sourceID: source.id)
        let song = Song(id: "descriptor", title: "Descriptor", fileFormat: .mp3,
                        filePath: "/music/track.strm", sourceID: source.id, fileSize: 64)
        let target = try await manager.resolveSTRMTarget(for: song, connector: connector)
        guard case .remote(let url) = target else { return XCTFail("Expected the descriptor URL") }
        XCTAssertEqual(url.absoluteString, "https://cdn.example/audio.flac")
        let reads = await connector.reads
        XCTAssertEqual(reads, 1)
    }

    private actor DescriptorConnector: MusicSourceConnector {
        nonisolated let sourceID: String
        var reads = 0

        init(sourceID: String) { self.sourceID = sourceID }
        func connect() async throws {}
        func disconnect() async {}
        func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
        func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func localURL(for path: String) async throws -> URL { throw URLError(.unsupportedURL) }
        func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
            throw URLError(.unsupportedURL)
        }
        func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
            reads += 1
            return Data("https://cdn.example/audio.flac\n".utf8)
        }
    }
}
