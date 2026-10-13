import Foundation
import Testing
@testable import PrimuseKit

@Suite("OAuth token request quotas", .serialized, .timeLimit(.minutes(1)))
struct OAuthTokenRequestTests {
    @Test(arguments: [429, 503], ["3600", "86400"])
    func tokenIssuanceKeepsLongCooldownAcrossInstances(status: Int, delay: String) async throws {
        let fixture = OAuthTokenFixture(status: status, headers: ["Retry-After": delay])
        let registry = RequestQuotaRegistry()
        for _ in 0..<2 {
            do {
                _ = try await OAuthTokenRequests(registry: registry).data(for: fixture.request, clientID: "client", session: fixture.session)
                Issue.record("Token issuance bypassed cooldown")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == status)
                #expect((failure.retryAfter ?? 0) > Double(delay)! - 10)
            }
        }
        #expect(fixture.count == 1)
    }

    @Test func tokenIssuanceRetainsHTTPDateAndIsolatesClients() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let fixture = OAuthTokenFixture(status: 503, headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(3600))])
        let requests = OAuthTokenRequests(registry: RequestQuotaRegistry())
        for client in ["one", "one", "two"] {
            do { _ = try await requests.data(for: fixture.request, clientID: client, session: fixture.session); Issue.record("Expected deferral") }
            catch let failure as HTTPResponseFailure { #expect((failure.retryAfter ?? 0) > 3590) }
        }
        #expect(fixture.count == 2)
    }

    @Test(arguments: [500, 503])
    func ambiguousIssuanceIsNeverReplayed(status: Int) async throws {
        let fixture = OAuthTokenFixture(status: status)
        do { _ = try await OAuthTokenRequests().data(for: fixture.request, clientID: UUID().uuidString, session: fixture.session); Issue.record("Expected failure") }
        catch let failure as HTTPResponseFailure { #expect(failure.statusCode == status) }
        #expect(fixture.count == 1)
    }

    @Test(arguments: [URLError.timedOut, .networkConnectionLost, .cancelled])
    func transportFailuresKeepTheirClassificationAndDoNotReplay(code: URLError.Code) async throws {
        let fixture = OAuthTokenFixture(error: URLError(code))
        do { _ = try await OAuthTokenRequests().data(for: fixture.request, clientID: UUID().uuidString, session: fixture.session); Issue.record("Expected transport failure") }
        catch { #expect(OperationCancellationPolicy.isCancellation(error) && code == .cancelled || (error as? URLError)?.code == code) }
        #expect(fixture.count == 1)
    }

    @Test(arguments: [200, 400])
    func providerRejectionRetainsOnlySafeMachineReadableCode(status: Int) async throws {
        let fixture = OAuthTokenFixture(status: status,
            body: Data(#"{"error":"invalid_grant","error_description":"SECRET","refresh_token":"SECRET"}"#.utf8))
        do {
            _ = try await OAuthTokenRequests().data(for: fixture.request, clientID: UUID().uuidString, session: fixture.session)
            Issue.record("Provider rejection reported success")
        } catch let failure as HTTPResponseFailure {
            #expect(failure.statusCode == status)
            #expect(OAuthTokenRequests.providerErrorCode(in: failure.body) == "invalid_grant")
            #expect(!String(decoding: failure.body, as: UTF8.self).contains("SECRET"))
            #expect(!failure.localizedDescription.contains("SECRET"))
        }
        #expect(fixture.count == 1)
    }

    @Test func tokenOnlyProviderKeepsQuotaWithoutAnAppCredentialLookup() async throws {
        let fixture = OAuthTokenFixture(status: 429, headers: ["Retry-After": "3600"])
        let requests = OAuthTokenRequests(registry: RequestQuotaRegistry())
        var request = fixture.request
        request.url = URL(string: "https://passportapi.115.com/open/refreshToken")!
        for client in ["", "configured-client"] {
            do { _ = try await requests.data(for: request, clientID: client, session: fixture.session); Issue.record("Expected cooldown") }
            catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 429) }
        }
        #expect(fixture.count == 1)
    }

    @Test func successfulRotationAndProviderPayloadArePreserved() async throws {
        let body = Data(#"{"access_token":"new","refresh_token":"rotated","expires_in":3600}"#.utf8)
        let fixture = OAuthTokenFixture(status: 200, body: body)
        var request = fixture.request
        request.httpBody = Data("refresh_token=old%2Btoken&client_id=client".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await OAuthTokenRequests().data(for: request, clientID: UUID().uuidString, session: fixture.session)
        #expect(data == body)
        #expect(fixture.captured?.httpMethod == "POST")
        #expect(fixture.captured?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }
}

private final class OAuthTokenFixture: @unchecked Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let error: URLError?
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var count: Int { lock.withLock { requests.count } }
    var captured: URLRequest? { lock.withLock { requests.last } }
    var request: URLRequest {
        var value = URLRequest(url: URL(string: "https://oauth.example/token")!)
        value.httpMethod = "POST"; return value
    }
    lazy var session: URLSession = {
        OAuthTokenProtocol.lock.withLock { OAuthTokenProtocol.fixture = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthTokenProtocol.self]
        return URLSession(configuration: config)
    }()
    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(), error: URLError? = nil) {
        self.status = status; self.headers = headers; self.body = body; self.error = error
    }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}

private final class OAuthTokenProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixture: OAuthTokenFixture?
    override class func canInit(with request: URLRequest) -> Bool { ["oauth.example", "passportapi.115.com"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixture! }
        fixture.record(request)
        if let error = fixture.error { client?.urlProtocol(self, didFailWithError: error); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: nil, headerFields: fixture.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
