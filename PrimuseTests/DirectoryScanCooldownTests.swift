import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class DirectoryScanCooldownTests: XCTestCase {
    func testSharedHTTPQuotaStopsAndResumesWithoutDiscardingUnvisitedSongs() async throws {
        let failures = [
            HTTPResponseFailure(statusCode: 429),
            HTTPResponseFailure(statusCode: 503, retryAfter: 3600),
            HTTPResponseFailure(statusCode: 403, retryAfter: 3600),
            HTTPResponseFailure(statusCode: 200, isRateLimited: true),
        ]
        for failure in failures {
            let connector = DirectoryCooldownConnector(failure: failure)
            let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
            let song = Song(id: "kept", title: "Kept", fileFormat: .flac,
                            filePath: "/Music/D/kept.flac", sourceID: connector.sourceID)
            var last: ConnectorScanner.ScanUpdate?
            do {
                for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song]) {
                    last = update
                }
                XCTFail("A quota must stop the scan")
            } catch let actual as HTTPResponseFailure { XCTAssertEqual(actual.statusCode, failure.statusCode) }
            let listed = await connector.listed
            XCTAssertEqual(listed, ["/Music", "/Music/A", "/Music/B"])
            let checkpoint = try XCTUnwrap(last?.resumeState)
            XCTAssertEqual(Set(checkpoint.pendingDirectories), ["/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.songs.map(\.id), [song.id], "Partial scans cannot delete unvisited songs")

            // A second attempt while still limited must stop at the same
            // directory, leaving all other queued work untouched.
            do {
                for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song], resumeState: checkpoint) {
                    last = update
                }
                XCTFail("Repeated cooldown must remain resumable")
            } catch is HTTPResponseFailure { }
            let repeated = await connector.listed
            XCTAssertEqual(Array(repeated.dropFirst(listed.count)), ["/Music/B"])

            await connector.allowListings()
            let beforeResume = await connector.listed.count
            for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song], resumeState: try XCTUnwrap(last?.resumeState)) {
                last = update
            }
            let resumed = await connector.listed
            XCTAssertEqual(Set(resumed.dropFirst(beforeResume)), ["/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.resumeState?.pendingDirectories, [])
        }
    }

    func testOrdinaryHTTPFailureDoesNotPauseUnrelatedDirectories() async throws {
        for status in [400, 403, 404, 500, 503] {
            let connector = DirectoryCooldownConnector(failure: HTTPResponseFailure(statusCode: status))
            let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
            var last: ConnectorScanner.ScanUpdate?
            do {
                for try await update in await scanner.scan(directories: ["/Music"]) { last = update }
                XCTFail("The failed directory must still be reported")
            } catch is HTTPResponseFailure { }
            let listed = await connector.listed
            XCTAssertEqual(listed, ["/Music", "/Music/A", "/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.resumeState?.pendingDirectories, ["/Music/B"])
        }
    }
}

private actor DirectoryCooldownConnector: MusicSourceConnector {
    nonisolated let sourceID = "directory-cooldown-" + UUID().uuidString
    private var failure: HTTPResponseFailure?
    private(set) var listed: [String] = []
    init(failure: HTTPResponseFailure) { self.failure = failure }
    func allowListings() { failure = nil }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listed.append(path)
        if path == "/Music/B", let failure { throw failure }
        guard path == "/Music" else { return [] }
        return ["A", "B", "C", "D"].map {
            RemoteFileItem(name: $0, path: "/Music/\($0)", isDirectory: true, size: 0, modifiedDate: nil)
        }
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}
