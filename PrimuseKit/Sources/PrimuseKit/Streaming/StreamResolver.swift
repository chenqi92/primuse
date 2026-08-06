import Foundation
#if os(tvOS)
import CryptoKit
import Network
import Observation
import Security
#endif

#if os(tvOS)
/// tvOS-local certificate pins for public NAS endpoints whose certificate does
/// not pass system validation (for example a reverse proxy presenting a NAS
/// certificate for a different hostname). Private/LAN hosts retain the legacy
/// automatic allowance; public endpoints always require an on-TV confirmation.
@MainActor
@Observable
public final class TVServerCertificateTrustStore {
    public struct Request: Identifiable {
        public let id = UUID()
        public let endpoint: String
        let fingerprint: String
        var continuations: [CheckedContinuation<Bool, Never>]
    }

    public struct InsecureHTTPRequest: Identifiable {
        public let id = UUID()
        public let endpoint: String
        var continuations: [CheckedContinuation<Bool, Never>]
    }

    public static let shared = TVServerCertificateTrustStore()
    nonisolated private static let defaultsKey = "primuse.tv.server-certificate-pins.v1"
    nonisolated private static let insecureHTTPDefaultsKey = "primuse.tv.insecure-http-endpoints.v1"

    public private(set) var pendingRequest: Request?
    public private(set) var pendingInsecureHTTPRequest: InsecureHTTPRequest?
    private var waitingRequests: [Request] = []
    private var waitingInsecureHTTPRequests: [InsecureHTTPRequest] = []

    private init() {}

    public func requestTrust(endpoint: String, fingerprint: String) async -> Bool {
        if Self.isTrustedSync(endpoint: endpoint, fingerprint: fingerprint) { return true }
        return await withCheckedContinuation { continuation in
            if pendingRequest?.endpoint == endpoint,
               pendingRequest?.fingerprint == fingerprint {
                pendingRequest?.continuations.append(continuation)
                return
            }
            if let index = waitingRequests.firstIndex(where: {
                $0.endpoint == endpoint && $0.fingerprint == fingerprint
            }) {
                waitingRequests[index].continuations.append(continuation)
                return
            }
            let request = Request(
                endpoint: endpoint,
                fingerprint: fingerprint,
                continuations: [continuation]
            )
            if pendingRequest == nil {
                pendingRequest = request
            } else {
                waitingRequests.append(request)
            }
        }
    }

    public func resolvePendingRequest(approved: Bool) {
        guard let request = pendingRequest else { return }
        if approved {
            var pins = Self.storedPins()
            pins[request.endpoint] = request.fingerprint
            if let data = try? JSONEncoder().encode(pins) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
        pendingRequest = waitingRequests.isEmpty ? nil : waitingRequests.removeFirst()
        for continuation in request.continuations {
            continuation.resume(returning: approved)
        }
    }

    public func requestInsecureHTTPTrust(endpoint: String) async -> Bool {
        if Self.isInsecureHTTPTrustedSync(endpoint: endpoint) { return true }
        return await withCheckedContinuation { continuation in
            if pendingInsecureHTTPRequest?.endpoint == endpoint {
                pendingInsecureHTTPRequest?.continuations.append(continuation)
                return
            }
            if let index = waitingInsecureHTTPRequests.firstIndex(where: {
                $0.endpoint == endpoint
            }) {
                waitingInsecureHTTPRequests[index].continuations.append(continuation)
                return
            }
            let request = InsecureHTTPRequest(
                endpoint: endpoint,
                continuations: [continuation]
            )
            if pendingInsecureHTTPRequest == nil {
                pendingInsecureHTTPRequest = request
            } else {
                waitingInsecureHTTPRequests.append(request)
            }
        }
    }

    public func resolvePendingInsecureHTTPRequest(approved: Bool) {
        guard let request = pendingInsecureHTTPRequest else { return }
        if approved {
            var endpoints = Self.storedInsecureHTTPEndpoints()
            endpoints.insert(request.endpoint)
            UserDefaults.standard.set(
                Array(endpoints).sorted(),
                forKey: Self.insecureHTTPDefaultsKey
            )
        }
        pendingInsecureHTTPRequest = waitingInsecureHTTPRequests.isEmpty
            ? nil
            : waitingInsecureHTTPRequests.removeFirst()
        for continuation in request.continuations {
            continuation.resume(returning: approved)
        }
    }

    nonisolated static func isTrustedSync(endpoint: String, fingerprint: String) -> Bool {
        storedPins()[endpoint] == fingerprint
    }

    nonisolated static func isInsecureHTTPTrustedSync(endpoint: String) -> Bool {
        storedInsecureHTTPEndpoints().contains(endpoint)
    }

    nonisolated private static func storedPins() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let pins = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return pins
    }

    nonisolated private static func storedInsecureHTTPEndpoints() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: insecureHTTPDefaultsKey) ?? [])
    }
}

public enum TVServerTrustPolicy {
    public static func disposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        var trustError: CFError?
        if SecTrustEvaluateWithError(trust, &trustError) {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        if InsecureHTTPHostPolicy.isLocalNetworkHost(host) {
            return (.useCredential, URLCredential(trust: trust))
        }
        guard let endpoint = NetworkEndpointIdentity(
            scheme: challenge.protectionSpace.protocol ?? "https",
            host: host,
            port: challenge.protectionSpace.port > 0 ? challenge.protectionSpace.port : nil
        )?.key,
        let fingerprint = leafFingerprint(trust) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        if TVServerCertificateTrustStore.isTrustedSync(
            endpoint: endpoint,
            fingerprint: fingerprint
        ) {
            return (.useCredential, URLCredential(trust: trust))
        }
        let approved = await TVServerCertificateTrustStore.shared.requestTrust(
            endpoint: endpoint,
            fingerprint: fingerprint
        )
        return approved
            ? (.useCredential, URLCredential(trust: trust))
            : (.cancelAuthenticationChallenge, nil)
    }

    private static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return nil
        }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }
            .joined()
    }
}

public enum StreamResolverHTTPRedirectMode: Sendable {
    case safe
    case fnMusic
}

public enum StreamResolverHTTPEvent: @unchecked Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// URLSession cannot use tvOS' media-only ATS exception for catalogue/login
/// requests. Public cleartext endpoints therefore require an endpoint-scoped
/// confirmation and use a small HTTP/1.1 TCP transport. LAN HTTP and every
/// HTTPS request retain their existing URLSession path.
public enum StreamResolverHTTPTransport {
    public static func requiresPlainHTTPTransport(_ url: URL) -> Bool {
        InsecureHTTPHostPolicy.requiresExplicitTrust(for: url)
    }

    public static func data(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int = 32 * 1_024 * 1_024,
        redirectMode: StreamResolverHTTPRedirectMode = .safe
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw URLError(.dataLengthExceedsMaximum) }
        let events = try await stream(
            for: request,
            session: session,
            redirectMode: redirectMode
        )
        var response: URLResponse?
        var body = Data()
        for try await event in events {
            switch event {
            case .response(let value):
                response = value
                let expected = value.expectedContentLength
                guard expected <= 0 || expected <= Int64(maximumBytes) else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                if expected > 0 { body.reserveCapacity(Int(expected)) }
            case .data(let value):
                guard value.count <= maximumBytes - body.count else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                body.append(value)
            }
        }
        guard let response else { throw URLError(.badServerResponse) }
        return (body, response)
    }

    public static func data(
        from url: URL,
        session: URLSession,
        maximumBytes: Int = 32 * 1_024 * 1_024,
        redirectMode: StreamResolverHTTPRedirectMode = .safe
    ) async throws -> (Data, URLResponse) {
        try await data(
            for: URLRequest(url: url),
            session: session,
            maximumBytes: maximumBytes,
            redirectMode: redirectMode
        )
    }

    public static func download(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int64? = nil,
        redirectMode: StreamResolverHTTPRedirectMode = .safe
    ) async throws -> (URL, URLResponse) {
        guard requiresPlainHTTPTransport(request.url ?? URL(fileURLWithPath: "/")) else {
            return try await session.download(for: request)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Primuse-TV-HTTP-\(UUID().uuidString).download")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        var shouldRemove = true
        defer {
            try? handle.close()
            if shouldRemove { try? FileManager.default.removeItem(at: destination) }
        }

        let events = try await stream(
            for: request,
            session: session,
            redirectMode: redirectMode
        )
        var response: URLResponse?
        var count: Int64 = 0
        for try await event in events {
            switch event {
            case .response(let value):
                response = value
                if let maximumBytes,
                   value.expectedContentLength > maximumBytes {
                    throw URLError(.dataLengthExceedsMaximum)
                }
            case .data(let value):
                guard let added = Int64(exactly: value.count),
                      count <= Int64.max - added else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                count += added
                if let maximumBytes, count > maximumBytes {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                try handle.write(contentsOf: value)
            }
        }
        guard let response else { throw URLError(.badServerResponse) }
        try handle.close()
        shouldRemove = false
        return (destination, response)
    }

    public static func stream(
        for request: URLRequest,
        session: URLSession,
        redirectMode: StreamResolverHTTPRedirectMode = .safe
    ) async throws -> AsyncThrowingStream<StreamResolverHTTPEvent, Error> {
        guard request.url != nil else { throw URLError(.badURL) }

        return AsyncThrowingStream { continuation in
            let driver = Task {
                do {
                    var currentRequest = request
                    var redirectCount = 0

                    while true {
                        try Task.checkCancellation()
                        guard let url = currentRequest.url else { throw URLError(.badURL) }

                        if Self.requiresPlainHTTPTransport(url) {
                            let endpoint = NetworkEndpointIdentity(url: url)?.key
                            guard let endpoint else { throw URLError(.badURL) }
                            let alreadyTrusted = TVServerCertificateTrustStore
                                .isInsecureHTTPTrustedSync(endpoint: endpoint)
                            let approved: Bool
                            if alreadyTrusted {
                                approved = true
                            } else {
                                approved = await TVServerCertificateTrustStore.shared
                                    .requestInsecureHTTPTrust(endpoint: endpoint)
                            }
                            try Task.checkCancellation()
                            guard approved else { throw URLError(.userAuthenticationRequired) }

                            let source = TVPlainHTTPConnection.events(for: currentRequest)
                            var redirectedRequest: URLRequest?
                            var receivedResponse = false
                            for try await event in source {
                                switch event {
                                case .response(let response):
                                    if let next = Self.redirectedRequest(
                                        from: currentRequest,
                                        response: response,
                                        mode: redirectMode
                                    ) {
                                        guard redirectCount < HTTPRedirectRequestPolicy.maximumRedirects else {
                                            throw URLError(.httpTooManyRedirects)
                                        }
                                        redirectCount += 1
                                        redirectedRequest = next
                                    } else {
                                        receivedResponse = true
                                        continuation.yield(event)
                                    }
                                case .data:
                                    if redirectedRequest == nil {
                                        continuation.yield(event)
                                    }
                                }
                                if redirectedRequest != nil { break }
                            }
                            if let redirectedRequest {
                                currentRequest = redirectedRequest
                                continue
                            }
                            guard receivedResponse else { throw URLError(.badServerResponse) }
                            continuation.finish()
                            return
                        }

                        let (bytes, response) = try await session.bytes(for: currentRequest)
                        guard let http = response as? HTTPURLResponse else {
                            throw URLError(.badServerResponse)
                        }
                        continuation.yield(.response(http))
                        var chunk = Data()
                        chunk.reserveCapacity(64 * 1_024)
                        for try await byte in bytes {
                            chunk.append(byte)
                            if chunk.count == 64 * 1_024 {
                                continuation.yield(.data(chunk))
                                chunk.removeAll(keepingCapacity: true)
                            }
                        }
                        if !chunk.isEmpty { continuation.yield(.data(chunk)) }
                        continuation.finish()
                        return
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in driver.cancel() }
        }
    }

    private static func redirectedRequest(
        from original: URLRequest,
        response: HTTPURLResponse,
        mode: StreamResolverHTTPRedirectMode
    ) -> URLRequest? {
        switch mode {
        case .safe:
            return HTTPRedirectRequestPolicy.redirectedRequest(
                from: original,
                response: response
            )
        case .fnMusic:
            guard [301, 302, 303, 307, 308].contains(response.statusCode),
                  let sourceURL = response.url ?? original.url,
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let destination = URL(string: location, relativeTo: sourceURL)?.absoluteURL else {
                return nil
            }
            return FnMusicRedirectPolicy.redirectedRequest(
                from: original,
                to: URLRequest(url: destination)
            )
        }
    }
}

private final class TVPlainHTTPConnection: @unchecked Sendable {
    private struct ParsedHeader {
        let response: HTTPURLResponse
        let contentLength: Int?
        let isChunked: Bool
        let hasBody: Bool
    }

    private final class ChunkDecoder {
        private static let lineBreak = Data([13, 10])
        private static let trailerTerminator = Data([13, 10, 13, 10])

        private var buffer = Data()
        private var expectedChunkSize: Int?
        private var isReadingTrailers = false
        private(set) var isComplete = false

        func append(_ data: Data) throws -> [Data] {
            guard !isComplete else { return [] }
            buffer.append(data)
            var output: [Data] = []

            while !isComplete {
                if isReadingTrailers {
                    if buffer.starts(with: Self.lineBreak) {
                        buffer.removeFirst(Self.lineBreak.count)
                        isComplete = true
                    } else if let trailerRange = buffer.range(of: Self.trailerTerminator) {
                        buffer.removeSubrange(..<trailerRange.upperBound)
                        isComplete = true
                    }
                    break
                }
                if expectedChunkSize == nil {
                    guard let lineRange = buffer.range(of: Self.lineBreak) else {
                        guard buffer.count <= 64 * 1_024 else { throw URLError(.badServerResponse) }
                        break
                    }
                    let line = String(decoding: buffer[..<lineRange.lowerBound], as: UTF8.self)
                    let token = line.split(
                        separator: ";",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    ).first ?? ""
                    guard let size = Int(token.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16),
                          size >= 0 else { throw URLError(.badServerResponse) }
                    buffer.removeSubrange(..<lineRange.upperBound)
                    if size == 0 {
                        isReadingTrailers = true
                        continue
                    }
                    expectedChunkSize = size
                }

                guard let size = expectedChunkSize,
                      size <= buffer.count,
                      buffer.count - size >= Self.lineBreak.count else { break }
                let chunkEnd = buffer.index(buffer.startIndex, offsetBy: size)
                guard buffer[chunkEnd...].starts(with: Self.lineBreak) else {
                    throw URLError(.badServerResponse)
                }
                if size > 0 { output.append(Data(buffer[..<chunkEnd])) }
                buffer.removeFirst(size + Self.lineBreak.count)
                expectedChunkSize = nil
            }
            return output
        }
    }

    private let request: URLRequest
    private let continuation: AsyncThrowingStream<StreamResolverHTTPEvent, Error>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Primuse.TVPlainHTTP.\(UUID().uuidString)")
    private let finishLock = NSLock()
    private var didFinish = false
    private var headerBuffer = Data()
    private var parsedHeader: ParsedHeader?
    private var remainingContentLength: Int?
    private var chunkDecoder: ChunkDecoder?

    static func events(
        for request: URLRequest
    ) -> AsyncThrowingStream<StreamResolverHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let operation = try TVPlainHTTPConnection(
                    request: request,
                    continuation: continuation
                )
                continuation.onTermination = { @Sendable _ in operation.cancel() }
                operation.start()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private init(
        request: URLRequest,
        continuation: AsyncThrowingStream<StreamResolverHTTPEvent, Error>.Continuation
    ) throws {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              let rawPort = UInt16(exactly: url.port ?? 80),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw URLError(.badURL)
        }
        self.request = request
        self.continuation = continuation
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: .tcp
        )
    }

    private func start() {
        let timeout = max(1, request.timeoutInterval > 0 ? request.timeoutInterval : 30)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(throwing: URLError(.timedOut))
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                do {
                    let payload = try Self.requestData(for: request)
                    connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if let error {
                            finish(throwing: error)
                        } else {
                            receiveNext()
                        }
                    })
                } catch {
                    finish(throwing: error)
                }
            case .failed(let error):
                finish(throwing: error)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                finish(throwing: error)
                return
            }
            do {
                if let data, !data.isEmpty { try consume(data) }
                guard !isFinished else { return }
                if isComplete {
                    try finishAtConnectionClose()
                } else {
                    receiveNext()
                }
            } catch {
                finish(throwing: error)
            }
        }
    }

    private func consume(_ data: Data) throws {
        if parsedHeader == nil {
            headerBuffer.append(data)
            let separator = Data([13, 10, 13, 10])
            guard let range = headerBuffer.range(of: separator) else {
                guard headerBuffer.count <= 64 * 1_024 else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                return
            }
            let header = try Self.parseHeader(
                Data(headerBuffer[..<range.lowerBound]),
                request: request
            )
            parsedHeader = header
            remainingContentLength = header.contentLength
            if header.isChunked { chunkDecoder = ChunkDecoder() }
            continuation.yield(.response(header.response))
            let initialBody = Data(headerBuffer[range.upperBound...])
            headerBuffer.removeAll(keepingCapacity: false)
            if !header.hasBody {
                finish()
                return
            }
            if !initialBody.isEmpty { try consumeBody(initialBody) }
            if header.contentLength == 0 { finish() }
            return
        }
        try consumeBody(data)
    }

    private func consumeBody(_ data: Data) throws {
        if let chunkDecoder {
            for chunk in try chunkDecoder.append(data) where !chunk.isEmpty {
                continuation.yield(.data(chunk))
            }
            if chunkDecoder.isComplete { finish() }
            return
        }
        if let remaining = remainingContentLength {
            let amount = min(remaining, data.count)
            if amount > 0 { continuation.yield(.data(Data(data.prefix(amount)))) }
            remainingContentLength = remaining - amount
            if remainingContentLength == 0 { finish() }
            return
        }
        continuation.yield(.data(data))
    }

    private func finishAtConnectionClose() throws {
        guard parsedHeader != nil else { throw URLError(.badServerResponse) }
        if let remainingContentLength, remainingContentLength != 0 {
            throw URLError(.networkConnectionLost)
        }
        if let chunkDecoder, !chunkDecoder.isComplete {
            throw URLError(.networkConnectionLost)
        }
        finish()
    }

    private var isFinished: Bool {
        finishLock.lock()
        defer { finishLock.unlock() }
        return didFinish
    }

    private func cancel() {
        finish(throwing: CancellationError())
    }

    private func finish(throwing error: Error? = nil) {
        finishLock.lock()
        guard !didFinish else {
            finishLock.unlock()
            return
        }
        didFinish = true
        finishLock.unlock()
        connection.cancel()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private static func requestData(for request: URLRequest) throws -> Data {
        guard let url = request.url,
              let host = url.host,
              url.scheme?.lowercased() == "http" else { throw URLError(.badURL) }
        let method = (request.httpMethod ?? "GET").uppercased()
        guard !method.isEmpty,
              !method.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw URLError(.badURL)
        }
        guard request.httpBodyStream == nil else { throw URLError(.requestBodyStreamExhausted) }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? url.path
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty { target += "?\(query)" }

        let formattedHost = host.contains(":") ? "[\(host)]" : host
        let port = url.port ?? 80
        let hostHeader = port == 80 ? formattedHost : "\(formattedHost):\(port)"
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(hostHeader)"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            guard lower != "host",
                  lower != "connection",
                  lower != "accept-encoding",
                  lower != "content-length" else { continue }
            guard !name.contains(":"),
                  !name.contains(where: { $0.isNewline }),
                  !value.contains(where: { $0.isNewline }) else {
                throw URLError(.badURL)
            }
            lines.append("\(name): \(value)")
        }
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        if let body = request.httpBody { lines.append("Content-Length: \(body.count)") }
        lines.append("")
        lines.append("")

        var data = Data(lines.joined(separator: "\r\n").utf8)
        if let body = request.httpBody { data.append(body) }
        return data
    }

    private static func parseHeader(_ data: Data, request: URLRequest) throws -> ParsedHeader {
        let text = String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw URLError(.badServerResponse) }
        let status = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard status.count >= 2, let statusCode = Int(status[1]), (100...599).contains(statusCode) else {
            throw URLError(.badServerResponse)
        }

        var fields: [String: String] = [:]
        var contentLength: Int?
        var isChunked = false
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw URLError(.badServerResponse) }
            if let existing = fields[name], !existing.isEmpty {
                fields[name] = "\(existing), \(value)"
            } else {
                fields[name] = value
            }
            switch name.lowercased() {
            case "content-length":
                guard let parsed = Int(value), parsed >= 0,
                      contentLength == nil || contentLength == parsed else {
                    throw URLError(.badServerResponse)
                }
                contentLength = parsed
            case "transfer-encoding":
                isChunked = value.localizedCaseInsensitiveContains("chunked")
            default:
                break
            }
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: fields
              ) else { throw URLError(.badServerResponse) }
        let method = (request.httpMethod ?? "GET").uppercased()
        let hasBody = method != "HEAD"
            && !(100...199).contains(statusCode)
            && statusCode != 204
            && statusCode != 304
        return ParsedHeader(
            response: response,
            contentLength: isChunked ? nil : contentLength,
            isChunked: isChunked,
            hasBody: hasBody
        )
    }
}
#endif

#if !os(tvOS)
public enum StreamResolverHTTPRedirectMode: Sendable {
    case safe
    case fnMusic
}

public enum StreamResolverHTTPTransport {
    public static func requiresPlainHTTPTransport(_ url: URL) -> Bool { false }

    public static func data(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int = 32 * 1_024 * 1_024,
        redirectMode: StreamResolverHTTPRedirectMode = .safe
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw URLError(.dataLengthExceedsMaximum) }
        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, response)
    }

    public static func data(
        from url: URL,
        session: URLSession,
        maximumBytes: Int = 32 * 1_024 * 1_024,
        redirectMode: StreamResolverHTTPRedirectMode = .safe
    ) async throws -> (Data, URLResponse) {
        try await data(
            for: URLRequest(url: url),
            session: session,
            maximumBytes: maximumBytes,
            redirectMode: redirectMode
        )
    }

    public static func download(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int64? = nil,
        redirectMode: StreamResolverHTTPRedirectMode = .safe
    ) async throws -> (URL, URLResponse) {
        let result = try await session.download(for: request)
        if let maximumBytes,
           let size = try? result.0.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) > maximumBytes {
            try? FileManager.default.removeItem(at: result.0)
            throw URLError(.dataLengthExceedsMaximum)
        }
        return result
    }
}
#endif

/// Resolver 登录请求使用的 session 工厂。tvOS 对私网 NAS 保留原有自签兼容；
/// 公网端点校验失败时由根视图确认并按 scheme/host/port 固定证书指纹。
enum StreamResolverSessionFactory {
    static func make(
        configuration: URLSessionConfiguration,
        fnMusicRedirects: Bool = false
    ) -> URLSession {
#if os(tvOS)
        URLSession(configuration: configuration,
                   delegate: PrivateNetworkTLSDelegate(fnMusicRedirects: fnMusicRedirects),
                   delegateQueue: nil)
#else
        if fnMusicRedirects {
            return URLSession(
                configuration: configuration,
                delegate: FnMusicRedirectSessionDelegate(),
                delegateQueue: nil
            )
        }
        return URLSession(configuration: configuration)
#endif
    }
}

private final class FnMusicRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirectCount = Int(task.taskDescription ?? "0") ?? 0
        guard redirectCount < FnMusicRedirectPolicy.maximumRedirects,
              let current = task.currentRequest ?? task.originalRequest else {
            completionHandler(nil)
            return
        }
        task.taskDescription = String(redirectCount + 1)
        completionHandler(FnMusicRedirectPolicy.redirectedRequest(from: current, to: request))
    }
}

#if os(tvOS)
private final class PrivateNetworkTLSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let fnMusicRedirects: Bool

    init(fnMusicRedirects: Bool) {
        self.fnMusicRedirects = fnMusicRedirects
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await TVServerTrustPolicy.disposition(for: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard fnMusicRedirects else {
            completionHandler(request)
            return
        }
        let redirectCount = Int(task.taskDescription ?? "0") ?? 0
        guard redirectCount < FnMusicRedirectPolicy.maximumRedirects,
              let current = task.currentRequest ?? task.originalRequest else {
            completionHandler(nil)
            return
        }
        task.taskDescription = String(redirectCount + 1)
        completionHandler(FnMusicRedirectPolicy.redirectedRequest(from: current, to: request))
    }

}
#endif

// MARK: - 流式解析(tvOS 播放)
//
// tvOS 不能用 iOS 那套 SFBAudioEngine + primuse-stream:// 自定义流(依赖原生库 +
// 音频引擎,不可移植)。tvOS 走 AVPlayer + HTTP(S) URL。这里定义"按音乐源把一首
// 歌解析成可直连播放的网络 URL"的共享契约,各源 resolver 都通过共享传输层实现,
// 放在 PrimuseKit 里以保持依赖只有 GRDB(不牵入任何 iOS-only 库)。

/// 解析一首歌所需的源凭据。Phase 1 只用到 username/password(Subsonic 家族);
/// Phase 2 会扩展 token / refreshToken / clientID / clientSecret 等。
public struct SourceCredential: Sendable, Equatable {
    public var username: String?
    public var password: String?
    public var token: String?
    public var refreshToken: String?
    public var clientID: String?
    public var clientSecret: String?
    public var extra: [String: String]

    public init(username: String? = nil,
                password: String? = nil,
                token: String? = nil,
                refreshToken: String? = nil,
                clientID: String? = nil,
                clientSecret: String? = nil,
                extra: [String: String] = [:]) {
        self.username = username
        self.password = password
        self.token = token
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.extra = extra
    }
}

public enum StreamResolveError: Error, Sendable, Equatable {
    /// 该音乐源类型在 tvOS 上无法直连播放(原生库源 / 本地文件等)。
    case unsupportedSourceType(MusicSourceType)
    /// 缺少必要凭据(密码 / token 未同步到本机)。
    case missingCredential
    /// 服务端鉴权失败(会话过期 / 密码错误),协调器据此触发刷新+重试。
    case authFailed
    /// 服务端要求两步验证(2FA / OTP),需用户在 TV 上输入一次性验证码。
    case needs2FA
    case badServerResponse(Int)
    case cannotBuildURL
    /// 该源需经 iPhone 中继播放,但中继端点未同步到(iPhone 未开启 / 不在同一局域网)。
    case relayUnavailable
}

/// 解析结果:可播放 URL + 播放时需附带的自定义 HTTP 头(UA / Bearer 等)。
/// 头为空时 AVPlayer 直连;非空时走 AVAssetResourceLoaderDelegate 代理(百度/115/Google)。
public struct ResolvedStream: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// 把一首歌解析成 AVPlayer 可播放的网络流。实现必须是 Sendable 的纯网络逻辑。
public protocol StreamResolver: Sendable {
    /// 解析成可直连播放的 URL(鉴权在 query 的源)。
    func streamURL(for song: Song,
                   source: MusicSource,
                   credential: SourceCredential?) async throws -> URL

    /// 解析成 URL + 播放头。默认包装 `streamURL`(无头);需要自定义播放头的源覆盖本方法。
    func resolve(for song: Song,
                 source: MusicSource,
                 credential: SourceCredential?) async throws -> ResolvedStream

    /// 会话失效时清掉缓存的会话(如 Synology `_sid`)。无状态源(Subsonic)空实现即可。
    func invalidateSession(sourceID: String) async

    /// 2FA:用一次性验证码登录,并申请「受信设备」令牌(deviceId)返回供持久化 ——
    /// 之后该设备登录即可跳过 OTP。不支持 2FA 设备令牌的源用默认实现(抛 authFailed)。
    func loginForDeviceToken(source: MusicSource,
                             credential: SourceCredential?,
                             otp: String) async throws -> String?
}

public extension StreamResolver {
    func resolve(for song: Song,
                 source: MusicSource,
                 credential: SourceCredential?) async throws -> ResolvedStream {
        ResolvedStream(url: try await streamURL(for: song, source: source, credential: credential))
    }

    func invalidateSession(sourceID: String) async {}

    func loginForDeviceToken(source: MusicSource,
                             credential: SourceCredential?,
                             otp: String) async throws -> String? {
        throw StreamResolveError.authFailed
    }
}
