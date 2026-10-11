import Foundation
import Testing
@testable import PrimuseKit

@Suite("Cloud resolver request quotas", .serialized)
struct CloudResolverRequestTests {
    @Test(arguments: [429, 503])
    func directoryReadersShareCooldownAcrossResolverInstances(status: Int) async throws {
        let fixture = CloudResolverFixture { _ in (status, ["Retry-After": "3600"], Data()) }
        let source = MusicSource(id: UUID().uuidString, name: "OneDrive", type: .oneDrive)
        let credential = SourceCredential(token: "fixture")
        for _ in 0..<2 {
            do {
                _ = try await CloudDriveStreamResolver(session: fixture.session).listDirectory(source: source, credential: credential, path: "/")
                Issue.record("Expected quota failure")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == status)
                #expect((failure.retryAfter ?? 0) > 3590)
            } catch { Issue.record("Lost HTTP response: \(error)") }
        }
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [429, 503, 200])
    func baiduRetainsHTTPAndBusinessQuota(status: Int) async throws {
        let fixture = CloudResolverFixture { _ in
            (status, ["Retry-After": "3600"], Data(#"{"errno":31034}"#.utf8))
        }
        let source = MusicSource(id: UUID().uuidString, name: "Baidu", type: .baiduPan)
        let song = Song(id: "track", title: "Track", fileFormat: .flac, filePath: "/music/track.flac", sourceID: source.id)
        for _ in 0..<2 {
            do {
                _ = try await BaiduPanStreamResolver(session: fixture.session).resolve(for: song, source: source, credential: .init(token: "fixture"))
                Issue.record("Expected quota failure")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == status)
                #expect((failure.retryAfter ?? 0) > 3590)
                if status == 200 { #expect(failure.isRateLimited) }
            } catch { Issue.record("Lost Baidu quota: \(error)") }
        }
        #expect(fixture.requests.count == 1)
    }

    @Test func authenticationRecoveryUsesTheSameReadAttemptBudget() async throws {
        let fixture = CloudResolverFixture { request in
            if request.url?.host == "login.microsoftonline.com" {
                return (200, [:], Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.utf8))
            }
            return (request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" ? 500 : 401, [:], Data())
        }
        let source = MusicSource(id: UUID().uuidString, name: "OneDrive", type: .oneDrive)
        do {
            _ = try await CloudDriveStreamResolver(session: fixture.session).listDirectory(source: source,
                credential: .init(token: "expired", refreshToken: "refresh", clientID: "client"), path: "/")
            Issue.record("Expected exhausted HTTP budget")
        } catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 500) }
        #expect(fixture.requests.filter { $0.url?.host == "graph.microsoft.com" }.count == 3)
        #expect(fixture.requests.filter { $0.url?.host == "login.microsoftonline.com" }.count == 1)
    }

    @Test func pan123BusinessQuotaUsesTheDefaultSharedCooldown() async throws {
        let fixture = CloudResolverFixture { request in
            if request.url?.path.hasSuffix("access_token") == true {
                return (200, [:], Data(#"{"code":0,"data":{"accessToken":"fixture"}}"#.utf8))
            }
            return (200, [:], Data(#"{"code":429,"message":"limited"}"#.utf8))
        }
        let source = MusicSource(id: UUID().uuidString, name: "123", type: .pan123)
        let song = Song(id: "track", title: "Track", fileFormat: .flac, filePath: "123", sourceID: source.id)
        for _ in 0..<2 {
            do {
                _ = try await CloudDriveStreamResolver(session: fixture.session).streamURL(for: song, source: source,
                    credential: .init(clientID: "client", clientSecret: "fixture"))
                Issue.record("Expected business quota failure")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == 200); #expect(failure.isRateLimited)
            } catch { Issue.record("Business quota was lost: \(error)") }
        }
        #expect(fixture.requests.count == 2, "Only one token issuance and one download-URL lookup")
    }

    @Test func ordinary403DoesNotRefreshEitherProvider() async throws {
        for type in [MusicSourceType.oneDrive, .baiduPan] {
            let fixture = CloudResolverFixture { _ in (403, [:], Data()) }
            let source = MusicSource(id: UUID().uuidString, name: "Cloud", type: type)
            let credential = SourceCredential(token: "fixture", refreshToken: "refresh", clientID: "client")
            do {
                if type == .oneDrive {
                    _ = try await CloudDriveStreamResolver(session: fixture.session).listDirectory(source: source, credential: credential, path: "/")
                } else {
                    let song = Song(id: "track", title: "Track", fileFormat: .flac, filePath: "/track.flac", sourceID: source.id)
                    _ = try await BaiduPanStreamResolver(session: fixture.session).resolve(for: song, source: source, credential: credential)
                }
                Issue.record("Expected permission failure")
            } catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 403) }
            #expect(fixture.requests.count == 1)
        }
    }

    @Test func concurrentReadersDeduplicateRefreshAndPersistRotatedCredentials() async throws {
        let fixture = CloudResolverFixture { request in
            if request.url?.host == "login.microsoftonline.com" {
                return (200, [:], Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600,"token_type":"Bearer"}"#.utf8))
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                ? (200, [:], Data(#"{"value":[]}"#.utf8)) : (401, [:], Data())
        }
        let source = MusicSource(id: UUID().uuidString, name: "Cloud", type: .oneDrive)
        let credential = SourceCredential(token: "expired", refreshToken: "refresh", clientID: "client")
        let resolver = CloudDriveStreamResolver(session: fixture.session)
        let saved = CloudRefreshRecorder()
        await resolver.setCredentialRefreshHandler { id, refresh in await saved.append(id, refresh) }
        async let first = resolver.listDirectory(source: source, credential: credential, path: "/")
        async let second = resolver.listDirectory(source: source, credential: credential, path: "/other")
        _ = try await (first, second)
        #expect(fixture.requests.filter { $0.url?.host == "login.microsoftonline.com" }.count == 1)
        let records = await saved.values
        #expect(records.count == 1)
        #expect(records.first?.0 == source.id)
        #expect(records.first?.1.credential.refreshToken == "rotated")
        #expect(records.first?.1.tokenType == "Bearer")
        #expect(records.first?.1.expiresAt != nil)
    }

    @Test func oneDrivePaginationKeepsOpaqueQueryAndRejectsForeignNextLink() async throws {
        let opaque = "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=A%2BB%2F%3D"
        for nextLink in [opaque, "https://graph.microsoft.com.evil.invalid/steal"] {
            let fixture = CloudResolverFixture { request in
                if request.url?.absoluteString == opaque {
                    return (200, [:], Data(#"{"value":[{"id":"two","name":"two.flac","size":2,"file":{}}]}"#.utf8))
                }
                let body = try! JSONSerialization.data(withJSONObject: ["value": [["id": "one", "name": "one.flac", "size": 1, "file": [:]]], "@odata.nextLink": nextLink])
                return (200, [:], body)
            }
            let source = MusicSource(id: UUID().uuidString, name: "Cloud", type: .oneDrive)
            do {
                let entries = try await CloudDriveStreamResolver(session: fixture.session).listDirectory(source: source, credential: .init(token: "fixture"), path: "/")
                #expect(nextLink == opaque)
                #expect(entries.map(\.path) == ["one", "two"])
            } catch { #expect(nextLink != opaque) }
            #expect(fixture.requests.count == (nextLink == opaque ? 2 : 1))
            #expect(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" })
        }
    }

    @Test func baiduHeadPreservesDateCooldownAndPlaybackHeaders() async throws {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let retry = date.string(from: Date().addingTimeInterval(3600))
        for headStatus in [302, 503] {
            let fixture = CloudResolverFixture { request in
                if request.httpMethod == "HEAD" {
                    return (headStatus, headStatus == 302 ? ["Location": "https://cdn.invalid/track.flac"] : ["Retry-After": retry], Data())
                }
                if request.url?.path.contains("multimedia") == true {
                    return (200, [:], Data(#"{"errno":0,"list":[{"dlink":"https://d.pcs.baidu.com/file?sign=A%2BB%2F%3D"}]}"#.utf8))
                }
                return (200, [:], Data(#"{"errno":0,"list":[{"server_filename":"track.flac","fs_id":123}]}"#.utf8))
            }
            let source = MusicSource(id: UUID().uuidString, name: "Baidu", type: .baiduPan)
            let song = Song(id: "track", title: "Track", fileFormat: .flac, filePath: "/music/track.flac", sourceID: source.id)
            for _ in 0..<(headStatus == 302 ? 1 : 2) {
                do {
                    let stream = try await BaiduPanStreamResolver(session: fixture.session).resolve(for: song, source: source, credential: .init(token: "fixture+&"))
                    #expect(headStatus == 302)
                    #expect(stream.url.absoluteString == "https://cdn.invalid/track.flac")
                    #expect(stream.headers["User-Agent"] == "pan.baidu.com")
                    #expect(stream.headers["Referer"] == "https://pan.baidu.com/")
                } catch let failure as HTTPResponseFailure {
                    #expect(headStatus == 503); #expect(failure.statusCode == 503)
                    #expect((failure.retryAfter ?? 0) > 3590)
                }
            }
            let heads = fixture.requests.filter { $0.httpMethod == "HEAD" }
            #expect(heads.count == 1)
            #expect(heads.first?.url?.absoluteString == "https://d.pcs.baidu.com/file?sign=A%2BB%2F%3D&access_token=fixture%2B%26")
            #expect(heads.first?.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
            #expect(heads.first?.value(forHTTPHeaderField: "Referer") == "https://pan.baidu.com/")
            #expect(!fixture.requests.contains { $0.url?.host == "cdn.invalid" })
        }
    }

    @Test func cancellationStopsReadWithoutReplay() async throws {
        let fixture = CloudResolverFixture { _ in (0, [:], Data()) }
        let source = MusicSource(id: UUID().uuidString, name: "Cloud", type: .oneDrive)
        let resolver = CloudDriveStreamResolver(session: fixture.session)
        let task = Task { try await resolver.listDirectory(source: source, credential: .init(token: "fixture"), path: "/") }
        for _ in 0..<200 {
            if !fixture.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.requests.count == 1)
        let start = Date()
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        catch let error as URLError { #expect(error.code == .cancelled) }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(fixture.requests.count == 1)
    }
}

private actor CloudRefreshRecorder {
    private(set) var values: [(String, CloudCredentialRefresh)] = []
    func append(_ id: String, _ refresh: CloudCredentialRefresh) { values.append((id, refresh)) }
}

private final class CloudResolverFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    let handler: Handler
    var requests: [URLRequest] { lock.withLock { captured } }
    lazy var session: URLSession = {
        CloudResolverProtocol.fixture = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudResolverProtocol.self]
        return URLSession(configuration: config)
    }()
    init(_ handler: @escaping Handler) { self.handler = handler }
    func response(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock { captured.append(request) }
        return handler(request)
    }
}

private final class CloudResolverProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: CloudResolverFixture?
    static var fixture: CloudResolverFixture? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let (status, headers, body) = fixture.response(request)
        if status == 0 { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
