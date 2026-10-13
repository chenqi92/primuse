#if os(tvOS)
import AVFoundation
import Foundation
import Network
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVStreamResourceLoaderTests: XCTestCase, @unchecked Sendable {
    func testHTTPSQuotaStopsLaterAssetsButKeepsAccountsIndependent() async throws {
        for status in [429, 503] {
            let fixture = PlaybackHTTPFixture(status: status)
            PlaybackHTTPProtocol.lock.withLock { PlaybackHTTPProtocol.fixture = fixture }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [PlaybackHTTPProtocol.self]
            let endpoint = URL(string: "https://\(UUID().uuidString).invalid")!
            for path in ["/limited.wav", "/seek.wav"] {
                do { _ = try await duration(endpoint.appendingPathComponent(path), account: "reader", config: config)
                    XCTFail("A limited source must not become playable")
                } catch {
                    XCTAssertTrue(error.localizedDescription.count > 0)
                }
            }
            XCTAssertEqual(fixture.requests.count, 1, "A new AVAsset/Range must retain the endpoint/account cooldown")
            let result = try await duration(endpoint.appendingPathComponent("healthy.wav"), account: "other", config: config)
            XCTAssertEqual(result, 1, accuracy: 0.01)
            XCTAssertGreaterThan(fixture.requests.count, 1)
            let request = try XCTUnwrap(fixture.requests.first)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "PrimuseFixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://fixture.invalid/")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Range"))
        }
    }

    func testReleasingCancelledAssetLoaderStopsTransportWithoutReplay() async throws {
        let fixture = PlaybackHTTPFixture(status: 200, hold: true)
        let started = expectation(description: "range started")
        let stopped = expectation(description: "range cancelled")
        fixture.started = started; fixture.stopped = stopped
        PlaybackHTTPProtocol.lock.withLock { PlaybackHTTPProtocol.fixture = fixture }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaybackHTTPProtocol.self]
        let url = URL(string: "https://\(UUID().uuidString).invalid/held.wav")!
        var loader: TVStreamResourceLoader? = TVStreamResourceLoader(realURL: url, headers: [:], fileExtension: "wav", sessionConfiguration: config)
        let asset = AVURLAsset(url: try XCTUnwrap(TVStreamResourceLoader.maskedURL(from: url)))
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "PlaybackCancellation"))
        let pending = Task { try await asset.load(.duration) }
        defer { pending.cancel(); asset.cancelLoading(); withExtendedLifetime(loader) {} }
        await fulfillment(of: [started], timeout: 5)
        asset.cancelLoading()
        // AVFoundation may retain resource loading after cancelling a property
        // load. Match the player's replacement of its old loader on a track change.
        asset.resourceLoader.setDelegate(nil, queue: nil)
        loader = nil
        do { _ = try await pending.value; XCTFail("Cancelled asset completed") } catch {}
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testTrustedPlainHTTPRedirectRetainsQuotaAndHeaders() async throws {
        let fixture = PlaybackHTTPFixture(status: 503)
        let server = try PlaybackLoopbackServer(fixture: fixture)
        let port = try await server.start()
        defer { server.stop() }
        // An IPv4-mapped IPv6 loopback address selects the explicit-trust transport
        // without external DNS, certificates or Internet traffic.
        let endpoint = URL(string: "http://[::ffff:127.0.0.1]:\(port)")!
        XCTAssertTrue(StreamResolverHTTPTransport.requiresPlainHTTPTransport(endpoint))
        let key = "primuse.tv.insecure-http-endpoints.v1"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set([try XCTUnwrap(NetworkEndpointIdentity(url: endpoint)).key], forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        for path in ["redirect.wav", "seek.wav"] {
            do { _ = try await duration(endpoint.appendingPathComponent(path), account: "reader", config: .ephemeral)
                XCTFail("The redirected service cooldown must stop subsequent ranges")
            } catch {}
        }
        XCTAssertEqual(fixture.requests.count, 2, "Only the redirect and rejected range may reach the loopback server")
        let redirected = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "User-Agent"), "PrimuseFixture")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Referer"), "https://fixture.invalid/")
        let result = try await duration(endpoint.appendingPathComponent("healthy.wav"), account: "other", config: .ephemeral)
        XCTAssertEqual(result, 1, accuracy: 0.01)
    }

    private func duration(_ url: URL, account: String, config: URLSessionConfiguration) async throws -> Double {
        let loader = TVStreamResourceLoader(realURL: url,
            headers: ["Authorization": "Bearer fixture", "User-Agent": "PrimuseFixture", "Referer": "https://fixture.invalid/"],
            fileExtension: "wav", transferSourceID: account, sessionConfiguration: config)
        let asset = AVURLAsset(url: try XCTUnwrap(TVStreamResourceLoader.maskedURL(from: url)))
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "PlaybackFixture"))
        defer { asset.cancelLoading(); withExtendedLifetime(loader) {} }
        return try await asset.load(.duration).seconds
    }
}

private final class PlaybackHTTPFixture: @unchecked Sendable {
    let status: Int
    let hold: Bool
    var started: XCTestExpectation?
    var stopped: XCTestExpectation?
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    init(status: Int, hold: Bool = false) { self.status = status; self.hold = hold }
    func reply(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock { captured.append(request) }
        if request.url!.path.contains("redirect") { return (302, ["Location": "/limited.wav"], Data()) }
        guard !request.url!.path.contains("limited") else { return (status, ["Retry-After": "3600"], Data()) }
        let wave = Self.wave
        let range = request.value(forHTTPHeaderField: "Range")?.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        let start = range.flatMap { Int($0[0]) } ?? 0
        guard start < wave.count else { return (416, ["Content-Range": "bytes */\(wave.count)", "Content-Length": "0"], Data()) }
        let end = min(range.flatMap { $0.count > 1 ? Int($0[1]) : nil } ?? (wave.count - 1), wave.count - 1)
        let bytes = wave.subdata(in: start..<(end + 1))
        return (206, ["Content-Type": "audio/wav", "Content-Range": "bytes \(start)-\(end)/\(wave.count)", "Content-Length": String(bytes.count)], bytes)
    }
    static let wave: Data = {
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ n: T) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        number(UInt32(8036)); data.append(Data("WAVEfmt ".utf8)); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(8000)); number(UInt32(8000)); number(UInt16(1)); number(UInt16(8)); data.append(Data("data".utf8)); number(UInt32(8000))
        data.append(Data(repeating: 128, count: 8000)); return data
    }()
}

private final class PlaybackHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixture: PlaybackHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixture! }
        let (status, headers, data) = fixture.reply(request)
        fixture.started?.fulfill()
        if fixture.hold { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.fixture }?.stopped?.fulfill() }
}
private final class PlaybackLoopbackServer: @unchecked Sendable {
    private let fixture: PlaybackHTTPFixture
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PlaybackLoopbackServer")
    private let lock = NSLock()
    private var started = false
    private var connections: [NWConnection] = []
    init(fixture: PlaybackHTTPFixture) throws {
        self.fixture = fixture
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<UInt16, Error>
                switch state {
                case .ready: guard let port = self.listener.port else { return }; result = .success(port.rawValue)
                case .failed(let error): result = .failure(error)
                default: return
                }
                let resume = self.lock.withLock { if self.started { return false }; self.started = true; return true }
                if resume { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.receive(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = bytes; bytes.append(data ?? Data())
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count >= 2 else { connection.cancel(); return }
                var request = URLRequest(url: URL(string: "http://127.0.0.1" + first[1])!)
                for line in lines.dropFirst() {
                    guard let index = line.firstIndex(of: ":") else { continue }
                    request.setValue(line[line.index(after: index)...].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: String(line[..<index]))
                }
                let (status, fields, body) = self.fixture.reply(request)
                var headers = fields
                headers["Content-Length"] = String(body.count)
                headers["Connection"] = "close"
                var response = "HTTP/1.1 \(status) Fixture\r\n"
                for (name, value) in headers { response += "\(name): \(value)\r\n" }
                var payload = Data((response + "\r\n").utf8); payload.append(body)
                connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            guard !done, error == nil, bytes.count < 65536 else { connection.cancel(); return }
            self.receive(connection, bytes: bytes)
        }
    }
}
#endif
