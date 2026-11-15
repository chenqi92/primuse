import Foundation
import Network
import PrimuseKit
import XCTest
@testable import Primuse

/// 公网明文 http 下载的分块响应：1.12.0(108)–1.12.1(111) 在第一块之后读块大小越界闪退；
/// 只要前缀的请求(电台探测、主页取台标)遇到分块也得整段收完，电台流因此一直收到超时。
final class HTTPChunkedBodyDecodingTests: XCTestCase {
    private let url = URL(string: "http://example.com/stream")!

    func testChunkedDownloadFinishesAtLastChunkWithoutWaitingForClose() throws {
        let payload = Data(repeating: 0x41, count: 100) + Self.randomPayload(count: 300_000)
        let response = Self.header("200 OK")
            + Self.chunked(payload, sizes: [100, 3, 70_000, 1, 65_536], extensions: true)
        let box = try PlainHTTPClient.DownloadStateBox()
        defer { box.cleanup() }
        XCTAssertEqual(try feed(response, to: box, split: 4_096), response.count)
        XCTAssertEqual(try finalizedBody(box), payload)
    }

    func testChunkedPrefixDownloadStopsOnceThePrefixIsDecoded() throws {
        let payload = Self.randomPayload(count: 500_000)
        var body = Self.chunked(payload, sizes: [16_384, 7, 8_000])
        body.removeLast(5)
        let response = Self.header("200 OK") + body
        let box = try PlainHTTPClient.DownloadStateBox(wholeResponsePrefixLimit: 65_536)
        defer { box.cleanup() }
        let consumed = try XCTUnwrap(feed(response, to: box, split: 4_096))
        XCTAssertLessThan(consumed, 80_000)
        XCTAssertEqual(try finalizedBody(box), payload.prefix(65_536))
    }

    func testChunkedDownloadWithoutLastChunkIsTruncated() throws {
        var body = Self.chunked(Data("hello world".utf8), sizes: [5, 6])
        body.removeLast(5)
        let box = try PlainHTTPClient.DownloadStateBox()
        defer { box.cleanup() }
        XCTAssertNil(try feed(Self.header("200 OK") + body, to: box, split: 3))
        XCTAssertThrowsError(try box.finalize())
    }

    func testChunkedRangeResponseLimitCountsDecodedBytes() throws {
        let payload = Self.randomPayload(count: 1_024)
        let response = Self.header("206 Partial Content") + Self.chunked(payload, sizes: [512])
        let box = try PlainHTTPClient.DownloadStateBox(maximumRangedBodyBytes: 1_024)
        defer { box.cleanup() }
        XCTAssertEqual(try feed(response, to: box, split: 4_096), response.count)
        XCTAssertEqual(try finalizedBody(box), payload)

        let oversized = Self.header("206 Partial Content")
            + Self.chunked(Self.randomPayload(count: 2_000), sizes: [512])
        let limited = try PlainHTTPClient.DownloadStateBox(maximumRangedBodyBytes: 1_024)
        defer { limited.cleanup() }
        XCTAssertThrowsError(try feed(oversized, to: limited, split: 4_096))
    }

    /// 按 split 分段喂给下载状态机，返回它说「收够了」时已经喂了多少字节。
    private func feed(_ response: Data, to box: PlainHTTPClient.DownloadStateBox, split: Int) throws -> Int? {
        var offset = 0
        while offset < response.count {
            let end = min(offset + split, response.count)
            if try box.consume(response[offset..<end], responseURL: url) { return end }
            offset = end
        }
        return nil
    }

    private func finalizedBody(_ box: PlainHTTPClient.DownloadStateBox) throws -> Data {
        let (file, _) = try box.finalize()
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    private static func header(_ status: String) -> Data {
        Data("HTTP/1.1 \(status)\r\nTransfer-Encoding: chunked\r\nContent-Type: audio/mpeg\r\n\r\n".utf8)
    }

    private static func chunked(_ payload: Data, sizes: [Int], extensions: Bool = false) -> Data {
        var body = Data()
        var offset = 0
        var index = 0
        while offset < payload.count {
            let count = min(sizes[index % sizes.count], payload.count - offset)
            let extensionText = extensions && index % 2 == 1 ? ";name=value" : ""
            body.append(Data((String(count, radix: 16) + extensionText + "\r\n").utf8))
            body.append(payload[offset..<(offset + count)])
            body.append(Data("\r\n".utf8))
            offset += count
            index += 1
        }
        body.append(Data("0\r\n\r\n".utf8))
        return body
    }

    private static func randomPayload(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

/// 公网明文 http 的音乐源取封面时连接被对端提前关掉：请求按 host:port 排队限流，
/// GET 被截断时安静地再试一次；截断的正文决不能当成完整响应交出去。
final class PlainHTTPClientExchangeTests: XCTestCase {
    private static let cover = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x5A, count: 2_000)

    func testConnectionClosedBeforeTheResponseIsTriedOnceMore() async throws {
        let server = try ScriptedHTTPServer(script: [.closeWithoutReply], otherwise: .reply(Self.ok(Self.cover)))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent("rest/getCoverArt.view")

        let (data, response) = try await PlainHTTPClient.data(for: Self.request(url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Self.cover)
        XCTAssertEqual(server.requestCount, 2)
    }

    func testBodyCutShortIsTriedOnceMoreInsteadOfReturnedShort() async throws {
        let short = Data("HTTP/1.1 200 OK\r\nContent-Length: \(Self.cover.count)\r\n\r\n".utf8) + Self.cover.prefix(100)
        let server = try ScriptedHTTPServer(script: [.reply(short)], otherwise: .reply(Self.ok(Self.cover)))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent("rest/getCoverArt.view")

        let (data, _) = try await PlainHTTPClient.data(for: Self.request(url))
        XCTAssertEqual(data, Self.cover)
        XCTAssertEqual(server.requestCount, 2)
    }

    func testChunkedBodyStoppingAtAChunkBoundaryIsNeverAccepted() async throws {
        let cut = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n".utf8)
        let server = try ScriptedHTTPServer(script: [], otherwise: .reply(cut))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent("rest/getCoverArt.view")

        do {
            _ = try await PlainHTTPClient.data(for: Self.request(url))
            XCTFail("A chunked body without its last chunk must not pass for the whole response")
        } catch {
            XCTAssertTrue(PlainHTTPClient.isInterruptedExchange(error), "\(error)")
        }
        XCTAssertEqual(server.requestCount, 2)
    }

    func testOnlyOneRetryAndOnlyForGET() async throws {
        let server = try ScriptedHTTPServer(script: [], otherwise: .closeWithoutReply)
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent("rest/getCoverArt.view")
        do {
            _ = try await PlainHTTPClient.data(for: Self.request(url))
            XCTFail("A server that never answers must fail")
        } catch {
            XCTAssertTrue(PlainHTTPClient.isInterruptedExchange(error), "\(error)")
        }
        XCTAssertEqual(server.requestCount, 2)

        let postServer = try ScriptedHTTPServer(script: [], otherwise: .closeWithoutReply)
        defer { postServer.stop() }
        var post = Self.request(try await postServer.start().appendingPathComponent("rest/scrobble.view"))
        post.httpMethod = "POST"
        post.httpBody = Data("id=1".utf8)
        do {
            _ = try await PlainHTTPClient.data(for: post)
            XCTFail("A POST the server never answered must fail")
        } catch {
            XCTAssertTrue(PlainHTTPClient.isInterruptedExchange(error), "\(error)")
        }
        XCTAssertEqual(postServer.requestCount, 1, "A request with a body is never sent twice")
    }

    func testHTTPStatusRepliesAreNotRetried() async throws {
        let unavailable = Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 4\r\n\r\nbusy".utf8)
        let server = try ScriptedHTTPServer(script: [], otherwise: .reply(unavailable))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent("rest/getCoverArt.view")

        let (data, response) = try await PlainHTTPClient.data(for: Self.request(url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(data, Data("busy".utf8))
        XCTAssertEqual(server.requestCount, 1)
    }

    func testInterimAndHeadRepliesFinishWithoutWaitingForClose() async throws {
        let interim = Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8)
        let headReply = Data("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n".utf8)
        let server = try ScriptedHTTPServer(
            script: [.replyAndStayOpen(interim), .replyAndStayOpen(headReply)],
            otherwise: .closeWithoutReply
        )
        defer { server.stop() }
        let base = try await server.start()

        var get = Self.request(base.appendingPathComponent("ping.view"))
        get.timeoutInterval = 8
        let (body, response) = try await PlainHTTPClient.data(for: get)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body, Data("ok".utf8))

        var head = Self.request(base.appendingPathComponent("rest/stream.view"))
        head.httpMethod = "HEAD"
        head.timeoutInterval = 8
        let (headBody, headResponse) = try await PlainHTTPClient.data(for: head)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(headBody.isEmpty)
        XCTAssertEqual(server.requestCount, 2)
    }

    func testABurstToOneServerOpensAtMostSixConnectionsAtOnce() async throws {
        let server = try ScriptedHTTPServer(script: [], otherwise: .hold(Self.ok(Self.cover)))
        defer { server.stop() }
        let base = try await server.start()
        let endpoint = try XCTUnwrap(NetworkEndpointIdentity(url: base)?.key)
        let limit = HTTPEndpointConnectionGate.defaultLimit

        let requests = (0..<(limit + 3)).map { index in
            Task { try await PlainHTTPClient.data(for: Self.request(base.appendingPathComponent("cover/\(index)"))).0 }
        }
        try await waitUntil { server.requestCount == limit }
        try await waitUntil { HTTPEndpointConnectionGate.shared.occupancy(endpoint: endpoint).queued == 3 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.requestCount, limit, "Requests past the limit must wait for a free slot")

        server.releaseHeld()
        for request in requests {
            let data = try await request.value
            XCTAssertEqual(data, Self.cover)
        }
        XCTAssertEqual(server.requestCount, limit + 3)
        XCTAssertLessThanOrEqual(server.peakConcurrentRequests, limit)
        XCTAssertEqual(HTTPEndpointConnectionGate.shared.occupancy(endpoint: endpoint).running, 0)
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    private static func ok(_ body: Data) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    private func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Loopback server that answers each request with the next scripted behaviour.
private final class ScriptedHTTPServer: @unchecked Sendable {
    enum Behaviour: Sendable {
        /// Reads the request, then closes without sending a byte.
        case closeWithoutReply
        /// Reads the request, sends these bytes, then closes.
        case reply(Data)
        /// Reads the request, sends these bytes and leaves the connection open.
        case replyAndStayOpen(Data)
        /// Reads the request and replies only after `releaseHeld()`.
        case hold(Data)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ScriptedHTTPServer")
    private let lock = NSLock()
    private let fallback: Behaviour
    private var script: [Behaviour]
    private var connections: [NWConnection] = []
    private var held: [(NWConnection, Data)] = []
    private var releasedHeld = false
    private var requests = 0
    private var inFlight = 0
    private var peak = 0

    var requestCount: Int { lock.withLock { requests } }
    var peakConcurrentRequests: Int { lock.withLock { peak } }

    init(script: [Behaviour], otherwise fallback: Behaviour) throws {
        self.script = script
        self.fallback = fallback
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.readRequest(connection, buffered: Data())
        }
    }

    func start() async throws -> URL {
        listener.start(queue: queue)
        for _ in 0..<500 {
            if let port = listener.port, port.rawValue != 0 {
                return URL(string: "http://127.0.0.1:\(port.rawValue)/")!
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    func releaseHeld() {
        let pending: [(NWConnection, Data)] = lock.withLock {
            releasedHeld = true
            defer { held.removeAll() }
            return held
        }
        for (connection, bytes) in pending { perform(.reply(bytes), on: connection) }
    }

    private func readRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var input = buffered
            input.append(data ?? Data())
            guard input.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.readRequest(connection, buffered: input) }
                return
            }
            let behaviour: Behaviour = self.lock.withLock {
                self.requests += 1
                self.inFlight += 1
                self.peak = max(self.peak, self.inFlight)
                return self.script.isEmpty ? self.fallback : self.script.removeFirst()
            }
            self.perform(behaviour, on: connection)
        }
    }

    private func perform(_ behaviour: Behaviour, on connection: NWConnection) {
        switch behaviour {
        case .closeWithoutReply:
            answered()
            connection.cancel()
        case .reply(let bytes):
            answered()
            connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
        case .replyAndStayOpen(let bytes):
            answered()
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        case .hold(let bytes):
            let repliesNow: Bool = lock.withLock {
                if releasedHeld { return true }
                held.append((connection, bytes))
                return false
            }
            if repliesNow { perform(.reply(bytes), on: connection) }
        }
    }

    /// Counted before any byte goes out: the client cannot finish, and free
    /// its slot for the next request, until the reply has started.
    private func answered() {
        lock.withLock { inFlight -= 1 }
    }
}
