import Foundation
import Testing
@testable import PrimuseKit

@Suite("FN Connect Feiniu Music", .serialized)
struct FnConnectResolverTests {
    @Test func acceptsFNIDInputsAndRejectsServerAddresses() {
        #expect(FnConnectResolver.fnID(from: "  LivingRoom-NAS  ") == "livingroom-nas")
        #expect(FnConnectResolver.fnID(from: "livingroom-nas.5ddd.com") == "livingroom-nas")
        #expect(FnConnectResolver.fnID(from: "https://LivingRoom-NAS.5ddd.com/") == "livingroom-nas")
        #expect(FnConnectResolver.fnID(from: "https://livingroom-nas.5ddd.com/music") == nil)
        #expect(FnConnectResolver.fnID(from: "192.168.1.2") == nil)
        #expect(FnConnectResolver.fnID(from: "short") == nil)
        #expect(FnConnectResolver.fnID(from: "-livingroom") == nil)
        #expect(FnConnectResolver.fnID(from: "livingroom-") == nil)
    }

    @Test func legacyFeiniuMusicSourcesRemainAddressBased() throws {
        let source = MusicSource(
            id: "legacy-fnmusic",
            name: "Feiniu Music",
            type: .fnMusic,
            host: "nas.example.test",
            port: 5666,
            useSsl: false,
            fnMusicConnectionMode: .fnConnect
        )
        let encoded = try JSONEncoder().encode(source)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fnMusicConnectionMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(MusicSource.self, from: legacyData)
        #expect(decoded.fnMusicConnectionMode == nil)
        #expect(decoded.effectiveFnMusicConnectionMode == .address)
        #expect(decoded.host == "nas.example.test")
        #expect(decoded.port == 5666)
    }

    @Test func connectionCredentialsAreEncodedIndependently() {
        #expect(
            FnMusicAPIProtocol.authenticationCookie(
                token: "A+B/C=",
                usesRelay: true
            ) == "music-token=A%2BB%2FC%3D; mode=relay"
        )
        #expect(
            FnMusicAPIProtocol.accessCodeHeaders("open sesame") == [
                "x-access-code": Data("open sesame".utf8).base64EncodedString(),
                "x-access-source": "app",
            ]
        )
        #expect(FnMusicAPIProtocol.accessCodeHeaders(nil).isEmpty)
    }

    @Test func prefersVerifiedPrivateRouteBeforeRelay() async throws {
        FnConnectURLProtocol.configure(.privateRoute)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let endpoint = try await FnConnectResolver(
            session: session,
            lookupTimeout: 1,
            probeTimeout: 1
        ).resolve("livingroom-nas")

        #expect(endpoint.route == .direct)
        #expect(endpoint.baseURL.absoluteString == "http://192.168.50.20:5666")
        #expect(FnConnectURLProtocol.issues.isEmpty)
        #expect(FnConnectURLProtocol.relayRequestCount == 0)
    }

    @Test func relayCarriesModeAndAccessCodeThroughMusicLoginAndCatalog() async throws {
        FnConnectURLProtocol.configure(.relayService)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let source = MusicSource(
            id: "fnconnect-service",
            name: "Feiniu Music",
            type: .fnMusic,
            host: "livingroom-nas",
            useSsl: true,
            fnMusicConnectionMode: .fnConnect,
            username: "music-user"
        )
        let credential = SourceCredential(
            username: "music-user",
            password: "music-password",
            extra: [FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey: "open sesame"]
        )
        let client = FnMusicServiceClient(
            source: source,
            credential: credential,
            session: session
        )

        let total = try await client.validateConnection()

        #expect(total == 0)
        #expect(FnConnectURLProtocol.issues.isEmpty)
        #expect(FnConnectURLProtocol.loginRequestCount == 1)
        #expect(FnConnectURLProtocol.trackRequestCount == 1)
    }

    @Test func distinguishesMissingAndRejectedAccessCodes() async {
        FnConnectURLProtocol.configure(.accessCodeChallenge)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let resolver = FnConnectResolver(
            session: session,
            lookupTimeout: 1,
            probeTimeout: 1
        )

        await #expect(throws: FnConnectError.accessCodeRequired) {
            _ = try await resolver.resolve("livingroom-nas")
        }
        await #expect(throws: FnConnectError.accessCodeRejected) {
            _ = try await resolver.resolve("livingroom-nas", accessCode: "wrong")
        }
        #expect(FnConnectURLProtocol.issues.isEmpty)
    }

    @Test func redirectPolicyResignsSameHostAndRejectsCredentialLeaks() throws {
        var original = URLRequest(
            url: try #require(URL(string: "https://livingroom-nas.5ddd.com/music/api/v1/track/stream?guid=one"))
        )
        original.httpMethod = "GET"
        original.setValue("old-signature", forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField)
        original.setValue("music-token=token; mode=relay", forHTTPHeaderField: "Cookie")
        original.setValue("encoded", forHTTPHeaderField: "x-access-code")
        original.setValue("app", forHTTPHeaderField: "x-access-source")
        original.setValue("bytes=32-63", forHTTPHeaderField: "Range")

        let sameHost = URLRequest(
            url: try #require(URL(string: "https://livingroom-nas.5ddd.com/music/api/v1/track/stream?guid=two"))
        )
        let redirected = try #require(
            FnMusicRedirectPolicy.redirectedRequest(from: original, to: sameHost)
        )
        #expect(redirected.value(forHTTPHeaderField: "Cookie") == "music-token=token; mode=relay")
        #expect(redirected.value(forHTTPHeaderField: "x-access-code") == "encoded")
        #expect(redirected.value(forHTTPHeaderField: "Range") == "bytes=32-63")
        #expect(redirected.value(forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField) != nil)
        #expect(redirected.value(forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField) != "old-signature")

        let loginBody = try JSONSerialization.data(withJSONObject: ["username": "listener"])
        var login = URLRequest(
            url: try #require(URL(string: "https://livingroom-nas.5ddd.com/music/api/v1/user/password-login"))
        )
        login.httpMethod = "POST"
        login.httpBody = loginBody
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FnMusicAPIProtocol.applyAuthx(to: &login, bodyData: loginBody)
        let redirectedLoginURL = try #require(
            URL(string: "https://livingroom-nas.5ddd.com/music/api/v1/user/password-login/")
        )
        let redirectedLogin = try #require(
            FnMusicRedirectPolicy.redirectedRequest(
                from: login,
                to: URLRequest(url: redirectedLoginURL)
            )
        )
        #expect(redirectedLogin.httpMethod == "POST")
        #expect(redirectedLogin.httpBody == loginBody)
        #expect(redirectedLogin.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(redirectedLogin.value(forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField) != nil)

        let otherHost = URLRequest(
            url: try #require(URL(string: "https://attacker.example/music/api/v1/track/stream"))
        )
        let downgrade = URLRequest(
            url: try #require(URL(string: "http://livingroom-nas.5ddd.com/music/api/v1/track/stream"))
        )
        let otherPort = URLRequest(
            url: try #require(URL(string: "https://livingroom-nas.5ddd.com:8443/music/api/v1/track/stream"))
        )
        #expect(FnMusicRedirectPolicy.redirectedRequest(from: original, to: otherHost) == nil)
        #expect(FnMusicRedirectPolicy.redirectedRequest(from: original, to: downgrade) == nil)
        #expect(FnMusicRedirectPolicy.redirectedRequest(from: original, to: otherPort) == nil)
    }

    @Test func mapsCurrentDiscoveryErrors() async {
        for (code, expected) in [(3_000_006, FnConnectError.serverNotFound),
                                 (3_000_037, .serverNotFound), (3_000_009, .discoveryUnavailable)] {
            let resolver = FnConnectResolver(data: { request in
                (Data("{\"code\":\(code),\"data\":null}".utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                 headerFields: nil)!)
            })
            await #expect(throws: expected) { _ = try await resolver.resolve("livingroom-nas") }
        }
    }

    @Test func discoversHTTPSDDNSWhenIPRoutesFail() async throws {
        for (portJSON, expectedPort) in [("{}", nil), ("{\"httpsPort\":8443}", 8443),
                                         ("{\"httpsPort\":\"9443\"}", 9443)] as [(String, Int?)] {
            let resolver = FnConnectResolver(data: { request in
                let url = try #require(request.url)
                if url.path == "/api/v1/fn/con" {
                    return FnConnectDelayedLookup.response(request, json:
                        "{\"code\":0,\"data\":{\"publicIpv4\":[\"203.0.113.10\"],\"ddns\":[\"music.example.test\"],\"port\":\(portJSON)}}")
                }
                if url.host == "203.0.113.10" { throw URLError(.serverCertificateUntrusted) }
                #expect(url.host == "music.example.test")
                #expect(url.scheme == "https")
                #expect(url.port == expectedPort)
                #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("mode=relay") != true)
                #expect(request.value(forHTTPHeaderField: "x-access-code") == Data("access-code".utf8).base64EncodedString())
                return FnConnectDelayedLookup.response(request, json: #"{"code":200,"data":{}}"#)
            })
            let endpoint = try await resolver.resolve("livingroom-nas", accessCode: "access-code")
            #expect(endpoint.route == .direct)
            #expect(endpoint.baseURL.host == "music.example.test")
            #expect(endpoint.baseURL.port == expectedPort)
        }
    }

    @Test func invalidDDNSNeverReceivesCredentialsAndFailedDDNSFallsBackToRelay() async throws {
        let resolver = FnConnectResolver(data: { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/fn/con" {
                return FnConnectDelayedLookup.response(request, json:
                    #"{"code":0,"data":{"ddns":["https://bad.example","user@bad.example","bad.example/path","bad.example?x=1","bad.example#fragment","bad.example:443","-bad.example","bad..example","valid.example"],"fn":["livingroom-nas.5ddd.com"]}}"#)
            }
            if url.host == "valid.example" { throw URLError(.cannotConnectToHost) }
            #expect(url.host == "livingroom-nas.5ddd.com")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "mode=relay")
            return FnConnectDelayedLookup.response(request, json: #"{"code":0,"data":{}}"#)
        })
        let endpoint = try await resolver.resolve("livingroom-nas", accessCode: "access-code")
        #expect(endpoint.route == .relay)
    }

    @Test func musicServiceFailuresAreNotReportedAsUnreachableRoutes() async {
        for (status, body) in [(200, #"{"code":500,"message":"service unavailable"}"#),
                               (200, "<html>Music unavailable</html>"),
                               (503, ""), (401, #"{"code":401}"#)] {
            let resolver = FnConnectResolver(data: { request in
                let url = try #require(request.url)
                if url.path == "/api/v1/fn/con" {
                    return FnConnectDelayedLookup.response(request, json: #"{"code":0,"data":{}}"#)
                }
                if url.path == "/access_code_verify" {
                    return FnConnectDelayedLookup.response(request, json: "", status: 204)
                }
                return FnConnectDelayedLookup.response(request, json: body, status: status)
            })
            await #expect(throws: FnConnectError.musicServiceUnavailable) {
                _ = try await resolver.resolve("livingroom-nas")
            }
        }
    }

    @Test func diagnosticsRetainStagesAndCodesWithoutCredentialsOrServerAddresses() async {
        let log = FnConnectDiagnosticLog()
        let resolver = FnConnectResolver(data: { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/fn/con" {
                return FnConnectDelayedLookup.response(request, json: #"{"code":0,"data":{}}"#)
            }
            if url.path == "/access_code_verify" {
                return FnConnectDelayedLookup.response(request, json: "", status: 204)
            }
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
                          userInfo: [NSLocalizedDescriptionKey: "secret-response-body",
                                     NSURLErrorFailingURLStringErrorKey: "https://private-nas.5ddd.com/?token=secret-token"])
        }, diagnosticLogger: { log.append($0) })
        await #expect(throws: FnConnectError.unreachable) {
            _ = try await resolver.resolve("private-nas", accessCode: "secret-access-code")
        }
        let messages = log.messages.joined(separator: "\n")
        #expect(messages.contains("stage=discovery route=discovery status=200 code=0"))
        #expect(messages.contains("stage=access-code route=relay-https status=204"))
        #expect(messages.contains("stage=music-config route=relay-https error=NSURLErrorDomain/-1200"))
        #expect(messages.contains("elapsed_ms="))
        for secret in ["private-nas", "secret-response-body", "secret-token", "secret-access-code",
                       Data("secret-access-code".utf8).base64EncodedString()] {
            #expect(!messages.contains(secret))
        }
    }

    @Test func discoveryFailureStopsBeforeProbesAndPreservesBusinessCode() async {
        let log = FnConnectDiagnosticLog()
        let resolver = FnConnectResolver(data: { request in
            #expect(request.url?.path == "/api/v1/fn/con")
            return FnConnectDelayedLookup.response(request, json: #"{"code":3000009,"data":null}"#)
        }, diagnosticLogger: { log.append($0) })
        await #expect(throws: FnConnectError.discoveryUnavailable) {
            _ = try await resolver.resolve("livingroom-nas")
        }
        #expect(log.messages.count == 1)
        #expect(log.messages.first?.contains("stage=discovery route=discovery status=200 code=3000009") == true)
    }

    @Test func slowRelayRemainsUsableAfterDirectRoutesFail() async throws {
        let resolver = FnConnectResolver(data: { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/fn/con" {
                return FnConnectDelayedLookup.response(request, json:
                    #"{"code":0,"data":{"ipv4":["192.168.50.20"],"fn":["livingroom-nas.5ddd.com"]}}"#)
            }
            if url.host == "192.168.50.20" { throw URLError(.cannotConnectToHost) }
            // Model a relay response arriving after three seconds, beyond the LAN budget.
            guard request.timeoutInterval >= 3 else { throw URLError(.timedOut) }
            if url.path == "/access_code_verify" {
                return FnConnectDelayedLookup.response(request, json: "", status: 204)
            }
            return FnConnectDelayedLookup.response(request, json: #"{"code":200,"data":{}}"#)
        })
        let endpoint = try await resolver.resolve("livingroom-nas")
        #expect(endpoint.route == .relay)
    }

    @Test func cancellationDuringProbeIsPreserved() async throws {
        let loader = FnConnectDelayedLookup(holdProbe: true)
        let task = Task { try await FnConnectResolver(data: { try await loader.load($0) })
            .resolve("livingroom-nas") }
        await loader.waitForPending(1)
        task.cancel()
        await loader.release(1)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func invalidatedResolutionCannotReplaceFreshEndpoint() async throws {
        let loader = FnConnectDelayedLookup()
        let provider = makeProvider(loader)
        let old = Task { try await provider.endpoint() }
        await loader.waitForPending(1)
        await provider.invalidate()
        let fresh = Task { try await provider.endpoint() }
        await loader.waitForPending(2)
        await loader.release(2)
        let current = try await fresh.value
        await loader.release(1)
        await #expect(throws: CancellationError.self) { _ = try await old.value }
        #expect(try await provider.endpoint() == current)
        #expect(current.baseURL.host == "route-2.5ddd.com")
        #expect(await loader.lookupCount == 2)
    }

    @Test func lateFailureCannotDiscardReplacementResolution() async throws {
        let loader = FnConnectDelayedLookup()
        let provider = makeProvider(loader)
        let old = Task { try await provider.endpoint() }
        await loader.waitForPending(1)
        await provider.invalidate()
        let fresh = Task { try await provider.endpoint() }
        await loader.waitForPending(2)
        await loader.release(1, failure: true)
        _ = await old.result
        // A caller arriving after the old failure must join the second lookup.
        // Only a third lookup completes immediately, so an erroneous duplicate
        // deterministically returns route-3 before the pending second lookup.
        await loader.completeFutureLookups()
        let joined = Task { try await provider.endpoint() }
        try await Task.sleep(for: .milliseconds(50))
        await loader.release(2)
        let current = try await fresh.value
        #expect(try await joined.value == current)
        #expect(await loader.lookupCount == 2)
    }

    private func makeProvider(_ loader: FnConnectDelayedLookup) -> FnMusicEndpointProvider {
        FnMusicEndpointProvider(
            source: MusicSource(name: "FN", type: .fnMusic, host: "livingroom-nas",
                                fnMusicConnectionMode: .fnConnect),
            dataLoader: { try await loader.load($0) }
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FnConnectURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class FnConnectDiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] { lock.withLock { storage } }

    func append(_ message: String) { lock.withLock { storage.append(message) } }
}

private final class FnConnectURLProtocol: URLProtocol, @unchecked Sendable {
    enum Scenario {
        case privateRoute
        case relayService
        case accessCodeChallenge
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenario: Scenario = .privateRoute
    nonisolated(unsafe) private static var issueStorage: [String] = []
    nonisolated(unsafe) private static var relayRequestCountStorage = 0
    nonisolated(unsafe) private static var loginRequestCountStorage = 0
    nonisolated(unsafe) private static var trackRequestCountStorage = 0

    static var issues: [String] {
        lock.withLock { issueStorage }
    }

    static var relayRequestCount: Int {
        lock.withLock { relayRequestCountStorage }
    }

    static var loginRequestCount: Int {
        lock.withLock { loginRequestCountStorage }
    }

    static var trackRequestCount: Int {
        lock.withLock { trackRequestCountStorage }
    }

    static func configure(_ value: Scenario) {
        lock.withLock {
            scenario = value
            issueStorage = []
            relayRequestCountStorage = 0
            loginRequestCountStorage = 0
            trackRequestCountStorage = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host?.lowercased() else {
            fail(.badURL)
            return
        }

        if host == "5ddd.com", url.path == "/api/v1/fn/con" {
            validateLookupRequest()
            respond(status: 200, json: Self.lookupResponse)
            return
        }

        let activeScenario = Self.lock.withLock { Self.scenario }
        if host == "192.168.50.20" {
            if activeScenario != .privateRoute {
                fail(.cannotConnectToHost)
                return
            }
            respondToProbe(isRelay: false)
            return
        }

        if host == "livingroom-nas.5ddd.com" {
            Self.lock.withLock { Self.relayRequestCountStorage += 1 }
            validateRelayHeaders()
            if url.path == "/access_code_verify" {
                if activeScenario == .accessCodeChallenge {
                    respond(status: 401)
                } else {
                    respond(status: 204)
                }
                return
            }
            if url.path == "/music/api/v1/sys/config" {
                validateSignedMusicRequest()
                respond(status: 200, json: #"{"code":200,"data":{}}"#)
                return
            }
            if url.path == "/music/api/v1/user/password-login" {
                Self.lock.withLock { Self.loginRequestCountStorage += 1 }
                validateSignedMusicRequest()
                validateRelayCookie(expectedToken: nil)
                respond(status: 200, json: #"{"code":200,"data":{"userToken":"relay+token="}}"#)
                return
            }
            if url.path == "/music/api/v1/track/list" {
                Self.lock.withLock { Self.trackRequestCountStorage += 1 }
                validateSignedMusicRequest()
                validateRelayCookie(expectedToken: "music-token=relay%2Btoken%3D")
                respond(status: 200, json: #"{"code":200,"data":{"list":[],"total":0}}"#)
                return
            }
        }

        fail(.cannotConnectToHost)
    }

    override func stopLoading() {}

    private func respondToProbe(isRelay: Bool) {
        guard let url = request.url else {
            fail(.badURL)
            return
        }
        if url.path == "/access_code_verify" {
            if isRelay { validateRelayHeaders() }
            respond(status: 204)
        } else if url.path == "/music/api/v1/sys/config" {
            validateSignedMusicRequest()
            respond(status: 200, json: #"{"code":200,"data":{}}"#)
        } else {
            fail(.cannotConnectToHost)
        }
    }

    private func validateLookupRequest() {
        if request.httpMethod != "POST" {
            record("FN Connect lookup was not POST")
        }
        if request.value(forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField) == nil {
            record("FN Connect lookup omitted authx")
        }
        guard let body = requestBodyData(),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
              object["fnId"] == "livingroom-nas" else {
            record("FN Connect lookup body omitted fnId")
            return
        }
    }

    private func validateRelayHeaders() {
        let activeScenario = Self.lock.withLock { Self.scenario }
        if request.value(forHTTPHeaderField: "Cookie")?.contains("mode=relay") != true {
            record("relay request omitted mode=relay")
        }
        if activeScenario == .relayService {
            let expected = Data("open sesame".utf8).base64EncodedString()
            if request.value(forHTTPHeaderField: "x-access-code") != expected {
                record("relay request omitted encoded access code")
            }
            if request.value(forHTTPHeaderField: "x-access-source") != "app" {
                record("relay request omitted access source")
            }
        }
    }

    private func validateRelayCookie(expectedToken: String?) {
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        if !cookie.contains("mode=relay") {
            record("Music request omitted relay cookie")
        }
        if let expectedToken, !cookie.contains(expectedToken) {
            record("Music request omitted encoded music token")
        }
    }

    private func validateSignedMusicRequest() {
        if request.value(forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField) == nil {
            record("Music request omitted authx")
        }
    }

    private func record(_ issue: String) {
        Self.lock.withLock { Self.issueStorage.append(issue) }
    }

    private func requestBodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func respond(status: Int, json: String? = nil) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: json == nil ? nil : ["Content-Type": "application/json"]
              ) else {
            fail(.badServerResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let json { client?.urlProtocol(self, didLoad: Data(json.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }

    private static var lookupResponse: String {
        let activeScenario = lock.withLock { scenario }
        if activeScenario == .privateRoute {
            return #"{"code":0,"data":{"ipv4":["192.168.50.20"],"ipv6":[],"publicIpv4":["203.0.113.20"],"publicIpv6":[],"port":{"httpPort":5666,"httpsPort":5667},"fn":["livingroom-nas.5ddd.com"]}}"#
        }
        return #"{"code":0,"data":{"ipv4":[],"ipv6":[],"publicIpv4":[],"publicIpv6":[],"port":{"httpPort":5666,"httpsPort":5667},"fn":["livingroom-nas.5ddd.com"]}}"#
    }
}

private actor FnConnectDelayedLookup {
    private(set) var lookupCount = 0
    private let holdProbe: Bool
    private var completeFuture = false
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var observers: [Int: CheckedContinuation<Void, Never>] = [:]

    init(holdProbe: Bool = false) { self.holdProbe = holdProbe }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        if url.path == "/api/v1/fn/con" {
            lookupCount += 1
            let number = lookupCount
            if !holdProbe, !completeFuture { try await suspend(number) }
            return Self.response(request, json:
                "{\"code\":0,\"data\":{\"fn\":[\"route-\(number).5ddd.com\"]}}")
        }
        if url.path == "/access_code_verify" {
            if holdProbe { try await suspend(1) }
            return Self.response(request, json: "", status: 204)
        }
        return Self.response(request, json: #"{"code":200,"data":{}}"#)
    }

    private func suspend(_ number: Int) async throws {
        // Deliberately ignore cancellation to exercise a late network callback.
        try await withCheckedThrowingContinuation { continuation in
            pending[number] = continuation
            observers.removeValue(forKey: number)?.resume()
        }
    }

    func waitForPending(_ number: Int) async {
        if pending[number] != nil { return }
        await withCheckedContinuation { observers[number] = $0 }
    }

    func release(_ number: Int, failure: Bool = false) {
        let continuation = pending.removeValue(forKey: number)
        if failure { continuation?.resume(throwing: URLError(.timedOut)) }
        else { continuation?.resume() }
    }

    func completeFutureLookups() { completeFuture = true }

    nonisolated static func response(_ request: URLRequest, json: String, status: Int = 200)
        -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                        httpVersion: nil, headerFields: nil)!)
    }
}
