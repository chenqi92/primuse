import Foundation
import XCTest
@testable import Primuse

final class BaiduWriteReplayTests: XCTestCase {
    func testCommittedWriteWithLostResponseIsNotSentAgain() async throws {
        let fixture = BaiduWriteFixture(mode: .lostResponse)
        let error = try await replacementError(fixture)
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
        XCTAssertEqual(fixture.createCount, 1, "A lost response does not prove the write failed")
    }

    func testHTTPFailuresDoNotReplayWrites() async throws {
        for status in [408, 429, 500, 503] {
            let fixture = BaiduWriteFixture(mode: .httpFailure(status))
            let error = try await replacementError(fixture)
            guard let cloudError = error as? CloudDriveError,
                  case .apiError(let code, _) = cloudError else {
                XCTFail("Expected HTTP \(status), got \(String(describing: error))"); continue
            }
            XCTAssertEqual(code, status)
            XCTAssertEqual(fixture.createCount, 1)
        }
    }

    func testConflictBeforeCommitPreventsAnyReplacement() async throws {
        let fixture = BaiduWriteFixture(mode: .conflict)
        let error = try await replacementError(fixture)
        XCTAssertEqual(error as? EmbeddedMetadataWritebackSourceError, .conflict)
        XCTAssertEqual(fixture.createCount, 0)
    }

    func testExplicitRateLimitRetryRechecksTheFileRevision() async throws {
        let fixture = BaiduWriteFixture(mode: .limitedThenConflict)
        let error = try await replacementError(fixture)
        XCTAssertEqual(error as? EmbeddedMetadataWritebackSourceError, .conflict)
        XCTAssertEqual(fixture.createCount, 1, "Do not replace a file modified during backoff")
    }

    func testSuccessfulReplacementStillVerifiesTheCommittedFile() async throws {
        let fixture = BaiduWriteFixture(mode: .success)
        let error = try await replacementError(fixture)
        XCTAssertNil(error)
        XCTAssertEqual(fixture.createCount, 1)
        XCTAssertEqual(fixture.listCount, 2)
    }

    func testReadOnlyMetadataRequestsCanStillRetry() async throws {
        let fixture = BaiduWriteFixture(mode: .readRetry)
        let error = try await replacementError(fixture)
        XCTAssertNil(error)
        XCTAssertEqual(fixture.createCount, 1)
        XCTAssertEqual(fixture.listCount, 3)
    }

    private func replacementError(_ fixture: BaiduWriteFixture) async throws -> Error? {
        let id = UUID().uuidString
        BaiduWriteProtocol.fixtures.insert(fixture, for: id)
        defer { BaiduWriteProtocol.fixtures.remove(id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BaiduWriteProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let source = BaiduPanSource(sourceID: id, session: session, tokenProvider: { "fixture-token" })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.flac")
        try Data([1, 2, 3, 4]).write(to: file)
        do {
            try await source.replaceMetadataFile(
                at: BaiduWriteFixture.path, with: file,
                expected: .init(fileSize: 4, modifiedDate: nil, revision: "original")
            )
            return nil
        } catch { return error }
    }
}

private final class BaiduWriteFixture: @unchecked Sendable {
    enum Mode: Equatable { case lostResponse, httpFailure(Int), conflict, limitedThenConflict, success, readRetry }
    static let path = "/Music/song.flac"
    let mode: Mode
    private let lock = NSLock()
    private var creates = 0
    private var lists = 0
    var listCount: Int { lock.withLock { lists } }
    var createCount: Int { lock.withLock { creates } }
    init(mode: Mode) { self.mode = mode }

    func response(to request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            let method = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "method" }?.value
            let json: [String: Any]
            switch method {
            case "precreate":
                json = ["errno": 0, "uploadid": "fixture-upload", "block_list": []]
            case "list":
                lists += 1
                if mode == .readRetry, lists == 1 { return (503, Data()) }
                let revision = mode == .conflict ? "edited-elsewhere"
                    : creates == 0 ? "original" : "changed"
                json = ["errno": 0, "list": [["path": Self.path, "server_filename": "song.flac",
                                               "isdir": 0, "size": 4, "fs_id": 1,
                                               "md5": revision]]]
            case "create":
                creates += 1
                if creates == 1 {
                    switch mode {
                    case .lostResponse: throw URLError(.timedOut)
                    case .httpFailure(let status): return (status, Data("Temporary failure".utf8))
                    case .limitedThenConflict:
                        return (200, try JSONSerialization.data(withJSONObject: ["errno": 31034]))
                    default: break
                    }
                }
                json = ["errno": 0]
            default: throw URLError(.unsupportedURL)
            }
            return (200, try JSONSerialization.data(withJSONObject: json))
        }
    }
}

private final class BaiduWriteFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: BaiduWriteFixture] = [:]
    func insert(_ value: BaiduWriteFixture, for id: String) { lock.withLock { values[id] = value } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func get(_ id: String) -> BaiduWriteFixture? { lock.withLock { values[id] } }
}

private final class BaiduWriteProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = BaiduWriteFixtures()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID"),
                  let fixture = Self.fixtures.get(id) else { throw URLError(.unsupportedURL) }
            let (status, data) = try fixture.response(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
