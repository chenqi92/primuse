import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class RemoteMediaHTTPErrorTests: XCTestCase {
    func testWebDAVListingsExcludeRecycleDirectoryAndDescendants() {
        for path in ["/podcast/#recycle", "/podcast/#RECYCLE/", "/podcast/#recycle/old"] {
            XCTAssertFalse(WebDAVDirectoryVisibilityPolicy.includes(path: path, isDirectory: true))
        }
        for path in ["/podcast/#recycle/episode.mp3", "/podcast/#RECYCLE/old/episode.mp3"] {
            XCTAssertFalse(WebDAVDirectoryVisibilityPolicy.includes(path: path, isDirectory: false))
        }
    }

    func testWebDAVRecycleFilterPreservesOrdinarySimilarNames() {
        for path in ["/podcast", "/podcast/recycle", "/podcast/#recycle collection"] {
            XCTAssertTrue(WebDAVDirectoryVisibilityPolicy.includes(path: path, isDirectory: true))
        }
        for path in ["/podcast/episode.mp3", "/podcast/#recycle.mp3", "/podcast/#recycle"] {
            XCTAssertTrue(WebDAVDirectoryVisibilityPolicy.includes(path: path, isDirectory: false))
        }
    }

    func testWebDAVDirectoryRemovalRequiresConsistentIndependentListings() {
        let previous: Set<String> = ["/Music/A.flac", "/Music/B.flac"]
        let firstMissing = WebDAVDirectoryListingConfirmationPolicy.missingPaths(
            previouslyObserved: previous,
            listed: ["/Music/A.flac"]
        )

        XCTAssertFalse(firstMissing.isEmpty)
        XCTAssertTrue(WebDAVDirectoryListingConfirmationPolicy.acceptsIndependentConfirmation(
            firstMissing: firstMissing,
            secondMissing: firstMissing
        ))
        XCTAssertTrue(WebDAVDirectoryListingConfirmationPolicy.acceptsIndependentConfirmation(
            firstMissing: firstMissing,
            secondMissing: []
        ))
        XCTAssertFalse(WebDAVDirectoryListingConfirmationPolicy.acceptsIndependentConfirmation(
            firstMissing: firstMissing,
            secondMissing: ["/music/a.flac"]
        ))
    }

    func testWebDAVDirectoryComparisonNormalizesCaseAndUnicode() {
        XCTAssertTrue(WebDAVDirectoryListingConfirmationPolicy.missingPaths(
            previouslyObserved: ["/Music/Caf\u{00E9}.flac"],
            listed: ["/music/Cafe\u{0301}.flac"]
        ).isEmpty)
    }

    func testWebDAVConfirmationIncludesPreviouslyIndexedAndLegacySongChildren() {
        let indexed = SourceSyncIndexedItem(
            stableKey: "path:/music/indexed",
            path: "/Music/Indexed",
            parentPath: "/Music",
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            revision: nil
        )
        let legacySong = Song(
            id: "legacy",
            title: "Legacy",
            fileFormat: .flac,
            filePath: "/Music/Legacy/Track.flac",
            sourceID: "source"
        )

        XCTAssertEqual(
            ConnectorScanner.previouslyObservedChildPaths(
                in: "/Music/",
                identityIndex: [indexed.stableKey: indexed],
                existingSongs: [legacySong]
            ),
            ["/Music/Indexed", "/Music/Legacy"]
        )
    }

    func testRetryAfterParsesWholeSecondsWithoutClampingServerDelay() throws {
        for (header, expected) in [("120", 120.0), (" 0 ", 0.0), ("3600", 3600.0)] {
            XCTAssertEqual(
                RemoteMediaHTTPError.retryDelay(from: try response(retryAfter: header)),
                expected
            )
        }
    }

    func testRetryAfterParsesHTTPDatesAgainstProvidedTime() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "1994-11-06T08:49:37Z"))
        for header in [
            "Sun, 06 Nov 1994 08:51:37 GMT",
            "Sunday, 06-Nov-94 08:51:37 GMT",
            "Sun Nov  6 08:51:37 1994"
        ] {
            XCTAssertEqual(
                RemoteMediaHTTPError.retryDelay(from: try response(retryAfter: header), now: now),
                120,
                header
            )
        }
    }

    func testPastRetryAfterDateDoesNotCreateNegativeDelay() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "1994-11-06T08:51:37Z"))
        XCTAssertEqual(
            RemoteMediaHTTPError.retryDelay(
                from: try response(retryAfter: "Sun, 06 Nov 1994 08:49:37 GMT"),
                now: now
            ),
            0
        )
    }

    func testMissingOrMalformedRetryAfterDoesNotInventDelay() throws {
        XCTAssertNil(RemoteMediaHTTPError.retryDelay(from: try response()))
        for header in ["", " ", "-1", "1.5", "1e2", "NaN", "Infinity", "later", "Sun, 40 Nov 1994 08:49:37 GMT"] {
            XCTAssertNil(RemoteMediaHTTPError.retryDelay(from: try response(retryAfter: header)), header)
        }
    }

    func testWebDAVHTTPFailuresPreserveStatusBeforeInspectingHTML() async throws {
        let source = makeWebDAV()
        for status in [401, 403, 404, 429, 503] {
            do {
                _ = try await source.validateStrictRangeResponse(
                    response(status: status, retryAfter: "17", contentType: "text/html"),
                    data: Data("<html>Request failed</html>".utf8),
                    path: "/song.flac",
                    offset: 0,
                    length: 4
                )
                XCTFail("HTTP \(status) must fail before its body can be treated as audio")
            } catch let error as RemoteMediaHTTPError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertEqual(error.retryAfter, 17)
                XCTAssertEqual(error.service, "WebDAV")
            } catch {
                XCTFail("HTTP \(status) was hidden by a different error: \(error)")
            }
        }
    }

    func testWebDAVSuccessfulStatusStillRejectsLoginPageAndIgnoredRange() async throws {
        let source = makeWebDAV()
        let cases: [(Int, String, Data, Int64)] = [
            (200, "text/html", Data("<html>Log in</html>".utf8), 0),
            (206, "text/html", Data("<html>Log in</html>".utf8), 0),
            (200, "audio/flac", Data([0xFF, 0xFA, 0x00, 0x01]), 4)
        ]
        for (status, contentType, data, offset) in cases {
            do {
                _ = try await source.validateStrictRangeResponse(
                    response(status: status, contentType: contentType),
                    data: data,
                    path: "/song.flac",
                    offset: offset,
                    length: 4
                )
                XCTFail("An HTTP success status must not bypass media and Range validation")
            } catch {
                XCTAssertTrue(error is SourceError, "Unexpected error: \(error)")
                XCTAssertFalse(error is RemoteMediaHTTPError)
            }
        }
    }

    func testWebDAVExactRangeStillReturnsAudio() async throws {
        let source = makeWebDAV()
        let data = Data([0xFF, 0xFA, 0x00, 0x01])
        let http = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://media-errors.invalid/song.flac")!,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "audio/flac",
                "Content-Range": "bytes 0-3/8",
                "Content-Length": "4"
            ]
        ))
        let result = try await source.validateStrictRangeResponse(
            http,
            data: data,
            path: "/song.flac",
            offset: 0,
            length: 4
        )
        XCTAssertEqual(result, data)
    }

    private func response(
        status: Int = 503,
        retryAfter: String? = nil,
        contentType: String = "audio/flac"
    ) throws -> HTTPURLResponse {
        var headers = ["Content-Type": contentType]
        headers["Retry-After"] = retryAfter
        return try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://media-errors.invalid/song.flac")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
    }

    @MainActor
    func testWebDAVDeleteSendsRequestAndRequiresConfirmedCompletionForHTTPAndHTTPS() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeletionStatusURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for useSSL in [false, true] {
            let sourceID = UUID().uuidString
            let source = WebDAVSource(sourceID: sourceID, host: "127.0.0.1", useSsl: useSSL,
                                      username: "", password: "", mutationSession: session)
            for status in [200, 204, 401, 403, 404, 405, 410, 202, 207] {
                let path = "/\(sourceID)/\(status).flac"
                do {
                    try await source.deleteFile(at: path)
                    XCTAssertTrue([200, 204].contains(status), "HTTP \(status) must not confirm deletion")
                } catch {
                    switch status {
                    case 401: XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), .authenticationRequired)
                    case 403: XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), .permissionDenied)
                    case 405: XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), .readOnly)
                    case 404, 410: XCTAssertTrue(SourceManager.isMissingFileError(error))
                    case 202, 207: XCTAssertFalse(SourceManager.isMissingFileError(error))
                    default: XCTFail("Unexpected DELETE failure: \(error)")
                    }
                }
                let requests = DeletionStatusURLProtocol.requests(path: path)
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(requests.first?.httpMethod, "DELETE")
                XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
            }
            await source.disconnect()
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(sourceID)
            try? FileManager.default.removeItem(at: cache)
        }
    }

    private func makeWebDAV() -> WebDAVSource {
        let sourceID = "media-http-errors-\(UUID().uuidString)"
        let source = WebDAVSource(
            sourceID: sourceID,
            host: "media-errors.invalid",
            useSsl: true,
            username: "",
            password: ""
        )
        addTeardownBlock {
            await source.disconnect()
            let cache = FileManager.default.temporaryDirectory
                .appendingPathComponent("primuse_webdav_cache")
                .appendingPathComponent(sourceID)
            try? FileManager.default.removeItem(at: cache)
        }
        return source
    }
}

private final class DeletionStatusURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]
    static func requests(path: String) -> [URLRequest] { lock.withLock { recorded[path] ?? [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.recorded[url.path, default: []].append(request) }
        let status = Int(url.deletingPathExtension().lastPathComponent) ?? 500
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
