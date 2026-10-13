import Foundation
import Security
import Testing
@testable import PrimuseKit

@Suite("NAS session invalidation", .serialized, .timeLimit(.minutes(1)))
struct NasSessionInvalidationTests {
    enum Route: CaseIterable { case concrete, existential, registry }

    @Test(arguments: [MusicSourceType.qnap, .synology, .ugreen], Route.allCases)
    func invalidationClearsOnlyTheSelectedSource(type: MusicSourceType, route: Route) async throws {
        let fixture = try NasSessionFixture()
        let resolver = fixture.resolver(type)
        let source = fixture.source(type)
        var other = source; other.id += "-other"
        let first = try await fixture.resolve(resolver, source)
        let unaffected = try await fixture.resolve(resolver, other)
        #expect(try await fixture.resolve(resolver, source) == first)
        await invalidate(resolver, source, route)
        #expect(try await fixture.resolve(resolver, other) == unaffected)
        #expect(try await fixture.resolve(resolver, source) != first)
        #expect(await fixture.server.logins == 3)
    }

    @Test(arguments: [MusicSourceType.qnap, .synology, .ugreen], Route.allCases)
    func invalidatedLoginCannotReturnOrCacheItsCredential(type: MusicSourceType, route: Route) async throws {
        let fixture = try NasSessionFixture(holdLogin: true)
        let resolver = fixture.resolver(type)
        let source = fixture.source(type)
        let pending = Task { try await fixture.resolve(resolver, source) }
        await fixture.server.waitForLogin()
        await invalidate(resolver, source, route)
        await fixture.server.release()
        do { _ = try await pending.value; Issue.record("Invalidated login returned a stream") }
        catch { #expect((error as? URLError)?.code == .userAuthenticationRequired) }
        let fresh = try await fixture.resolve(resolver, source)
        #expect(fresh.absoluteString.contains("session-2"))
        #expect(await fixture.server.logins == 2)
    }

    @Test(arguments: [MusicSourceType.qnap, .synology, .ugreen])
    func callerCancellationDoesNotInvalidateSharedLogin(type: MusicSourceType) async throws {
        let fixture = try NasSessionFixture(holdLogin: true)
        let resolver = fixture.resolver(type)
        let source = fixture.source(type)
        let pending = Task { try await fixture.resolve(resolver, source) }
        await fixture.server.waitForLogin()
        pending.cancel()
        await fixture.server.release()
        do { _ = try await pending.value; Issue.record("Cancelled caller returned a stream") }
        catch { #expect(OperationCancellationPolicy.isCancellation(error)) }
        let fresh = try await fixture.resolve(resolver, source)
        #expect(fresh.absoluteString.contains("session-1"))
        #expect(await fixture.server.logins == 1)
    }

    @Test func invalidationAlsoCancelsExplicitTwoFactorLogin() async throws {
        let fixture = try NasSessionFixture(holdLogin: true)
        let resolver = SynologyStreamResolver(session: fixture.session)
        let source = fixture.source(.synology)
        let pending = Task { try await resolver.loginForDeviceToken(source: source,
            credential: .init(username: "fixture", password: "fixture"), otp: "123456") }
        await fixture.server.waitForLogin()
        await resolver.invalidateSession(sourceID: source.id)
        await fixture.server.release()
        do { _ = try await pending.value; Issue.record("Invalidated OTP returned credentials") }
        catch { #expect((error as? URLError)?.code == .userAuthenticationRequired) }
        #expect(try await fixture.resolve(resolver, source).absoluteString.contains("session-2"))
    }

    @Test func invalidationDuringQuickConnectCannotStartAnOldLogin() async throws {
        let fixture = try NasSessionFixture(holdLogin: true)
        let resolver = SynologyStreamResolver(session: fixture.session, quickConnectResolver: { _ in
            _ = await fixture.server.reply(URLRequest(url: URL(string: "https://nas.example/route")!))
            return URL(string: "https://nas.example")!
        })
        var source = fixture.source(.synology)
        source.synologyConnectionMode = .quickConnect
        let routed = source
        let pending = Task { try await fixture.resolve(resolver, routed) }
        await fixture.server.waitForLogin()
        await resolver.invalidateSession(sourceID: source.id)
        await fixture.server.release()
        do { _ = try await pending.value; Issue.record("Invalidated QuickConnect started login") }
        catch { #expect((error as? URLError)?.code == .userAuthenticationRequired) }
        #expect(await fixture.server.logins == 1)
        #expect(try await fixture.resolve(resolver, source).absoluteString.contains("session-3"))
    }

    private func invalidate(_ resolver: any StreamResolver, _ source: MusicSource, _ route: Route) async {
        switch route {
        case .concrete:
            if let resolver = resolver as? NasHttpStreamResolver { await resolver.invalidateSession(sourceID: source.id) }
            if let resolver = resolver as? SynologyStreamResolver { await resolver.invalidateSession(sourceID: source.id) }
            if let resolver = resolver as? UgreenStreamResolver { await resolver.invalidateSession(sourceID: source.id) }
        case .existential: await resolver.invalidateSession(sourceID: source.id)
        case .registry:
            let registry = StreamResolverRegistry()
            await registry.register(resolver, for: [source.type])
            await registry.invalidateSession(for: source)
        }
    }
}

private final class NasSessionFixture: Sendable {
    let server: NasSessionServer
    let session: URLSession
    init(holdLogin: Bool = false) throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let data = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let server = NasSessionServer(key: data.base64EncodedString(), hold: holdLogin)
        self.server = server
        NasSessionProtocol.lock.withLock { NasSessionProtocol.server = server }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NasSessionProtocol.self]
        session = URLSession(configuration: configuration)
    }
    func resolver(_ type: MusicSourceType) -> any StreamResolver {
        switch type {
        case .qnap: NasHttpStreamResolver(session: session)
        case .synology: SynologyStreamResolver(session: session)
        default: UgreenStreamResolver(session: session)
        }
    }
    func source(_ type: MusicSourceType) -> MusicSource {
        MusicSource(id: UUID().uuidString, name: "Fixture", type: type, host: "nas.example", useSsl: true)
    }
    func resolve(_ resolver: any StreamResolver, _ source: MusicSource) async throws -> URL {
        try await resolver.streamURL(for: Song(id: "track", title: "Track", fileFormat: .flac, filePath: "/track.flac", sourceID: source.id),
            source: source, credential: .init(username: "fixture", password: "fixture"))
    }
}

private actor NasSessionServer {
    let key: String
    let hold: Bool
    private(set) var logins = 0
    private var started = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var response: CheckedContinuation<Void, Never>?
    init(key: String, hold: Bool) { self.key = key; self.hold = hold }
    func reply(_ request: URLRequest) async -> ([String: String], Data) {
        if request.url!.path.hasSuffix("/check") { return (["x-rsa-token": key], Data()) }
        logins += 1
        let token = "session-\(logins)"
        if hold && logins == 1 {
            await withCheckedContinuation { continuation in
                response = continuation; started = true
                observers.forEach { $0.resume() }; observers.removeAll()
            }
        }
        let body: String
        if request.url!.path.contains("authLogin") { body = "{\"authPassed\":1,\"authSid\":\"\(token)\"}" }
        else if request.url!.path.contains("auth.cgi") { body = "{\"success\":true,\"data\":{\"sid\":\"\(token)\",\"did\":\"device\"}}" }
        else { body = "{\"code\":200,\"data\":{\"token\":\"\(token)\"}}" }
        return ([:], Data(body.utf8))
    }
    func waitForLogin() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { response?.resume(); response = nil }
}

private final class NasSessionProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var server: NasSessionServer?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "nas.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var loading: Task<Void, Never>?
    override func startLoading() {
        let server = Self.lock.withLock { Self.server! }
        loading = Task {
            let (headers, body) = await server.reply(request)
            guard !Task.isCancelled else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { loading?.cancel() }
}
