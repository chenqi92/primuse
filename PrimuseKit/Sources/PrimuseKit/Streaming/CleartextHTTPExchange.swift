import Foundation
import Network

/// Determines when a complete HTTP/1.1 response has arrived without waiting
/// for the peer to close a keep-alive connection, and what a connection that
/// did close left behind.
public enum HTTPResponseFramingPolicy {
    private static let lineBreak = Data([13, 10])
    private static let headerTerminator = Data([13, 10, 13, 10])
    /// A peer may send several 1xx interim heads; past this many it is not a
    /// server worth waiting for.
    private static let maximumInterimResponses = 16
    /// A chunk-size line longer than this is garbage, not a slow peer.
    private static let maximumSizeLineBytes = 8 * 1_024

    /// What the bytes received before the peer closed the connection amount to.
    public enum EndOfStream: Equatable, Sendable {
        /// The first `messageLength` bytes hold the whole response, including
        /// any 1xx interim heads in front of it. A response framed only by the
        /// connection closing is complete here as well.
        case complete(messageLength: Int)
        /// The connection closed before the final status line and headers were all in.
        case closedBeforeResponse
        /// The headers promised a body (Content-Length or chunked) that never fully arrived.
        case truncatedBody
        /// The headers or the chunked body are not valid HTTP/1.1 framing.
        case malformed
    }

    /// Length of the complete response at the front of `data`, or nil while
    /// more bytes are needed. A response without Content-Length or chunked
    /// framing ends only when the connection closes, so it is never complete
    /// here; see `endOfStream(in:requestMethod:)`.
    public static func completeMessageLength(in data: Data, requestMethod: String? = nil) -> Int? {
        guard let head = finalHead(in: data) else { return nil }
        switch bodyFraming(of: head, requestMethod: requestMethod) {
        case .none:
            return head.end
        case .contentLength(let length):
            guard length <= Int.max - head.end else { return nil }
            let messageLength = head.end + length
            return data.count >= messageLength ? messageLength : nil
        case .chunked:
            if case .complete(let messageLength) = chunkedMessage(in: data, bodyOffset: head.end) {
                return messageLength
            }
            return nil
        case .untilClose, .invalid:
            return nil
        }
    }

    /// Classifies everything received once the peer has closed the connection.
    public static func endOfStream(in data: Data, requestMethod: String? = nil) -> EndOfStream {
        guard let head = finalHead(in: data) else { return .closedBeforeResponse }
        switch bodyFraming(of: head, requestMethod: requestMethod) {
        case .none:
            return .complete(messageLength: head.end)
        case .contentLength(let length):
            guard length <= Int.max - head.end, data.count >= head.end + length else { return .truncatedBody }
            return .complete(messageLength: head.end + length)
        case .chunked:
            switch chunkedMessage(in: data, bodyOffset: head.end) {
            case .complete(let messageLength): return .complete(messageLength: messageLength)
            case .incomplete: return .truncatedBody
            case .malformed: return .malformed
            }
        case .untilClose:
            return .complete(messageLength: data.count)
        case .invalid:
            return .malformed
        }
    }

    /// Byte offset of the final response's status line. 1xx interim heads
    /// (other than 101) that precede it are skipped; 0 when there are none or
    /// the final head has not arrived yet.
    public static func finalResponseOffset(in data: Data) -> Int {
        finalHead(in: data)?.start ?? 0
    }

    private struct Head {
        let start: Int
        let end: Int
        let statusCode: Int?
        let contentLength: Int?
        let hasInvalidContentLength: Bool
        let isChunked: Bool
    }

    private enum BodyFraming {
        case none
        case contentLength(Int)
        case chunked
        case untilClose
        case invalid
    }

    private enum ChunkedProgress {
        case complete(Int)
        case incomplete
        case malformed
    }

    private static func finalHead(in data: Data) -> Head? {
        var offset = 0
        for _ in 0...maximumInterimResponses {
            guard let head = parseHead(in: data, from: offset) else { return nil }
            guard let status = head.statusCode, (100..<200).contains(status), status != 101 else {
                return head
            }
            offset = head.end
        }
        return nil
    }

    private static func parseHead(in data: Data, from offset: Int) -> Head? {
        guard offset <= data.count else { return nil }
        let startIndex = data.index(data.startIndex, offsetBy: offset)
        guard let headerRange = data.range(of: headerTerminator, in: startIndex..<data.endIndex) else {
            return nil
        }
        let headerData = Data(data[startIndex..<headerRange.lowerBound])
        let headerText = String(data: headerData, encoding: .isoLatin1)
            ?? String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")

        var statusCode: Int?
        if let statusLine = lines.first {
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count >= 2 { statusCode = Int(parts[1]) }
        }

        var contentLength: Int?
        var hasInvalidContentLength = false
        var isChunked = false
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "content-length":
                if let parsed = Int(value), parsed >= 0 {
                    contentLength = parsed
                } else {
                    hasInvalidContentLength = true
                }
            case "transfer-encoding":
                isChunked = value.localizedCaseInsensitiveContains("chunked")
            default:
                break
            }
        }
        return Head(
            start: offset,
            end: data.distance(from: data.startIndex, to: headerRange.upperBound),
            statusCode: statusCode,
            contentLength: contentLength,
            hasInvalidContentLength: hasInvalidContentLength,
            isChunked: isChunked
        )
    }

    /// RFC 9112 section 6.3: HEAD responses and 1xx/204/304 never carry a
    /// body; chunked framing wins over Content-Length; without either the
    /// body runs until the connection closes.
    private static func bodyFraming(of head: Head, requestMethod: String?) -> BodyFraming {
        if requestMethod?.uppercased() == "HEAD" { return .none }
        if let status = head.statusCode,
           (100..<200).contains(status) || status == 204 || status == 304 {
            return .none
        }
        if head.isChunked { return .chunked }
        if head.hasInvalidContentLength { return .invalid }
        if let length = head.contentLength { return .contentLength(length) }
        return .untilClose
    }

    /// Walks chunk by chunk using the declared sizes, so bytes inside a chunk
    /// that happen to look like `0\r\n\r\n` never end the body early.
    private static func chunkedMessage(in data: Data, bodyOffset: Int) -> ChunkedProgress {
        guard bodyOffset <= data.count else { return .incomplete }
        var cursor = data.index(data.startIndex, offsetBy: bodyOffset)

        while true {
            guard let sizeLineRange = data.range(of: lineBreak, in: cursor..<data.endIndex) else {
                return data.distance(from: cursor, to: data.endIndex) > maximumSizeLineBytes
                    ? .malformed : .incomplete
            }
            let sizeLine = String(decoding: data[cursor..<sizeLineRange.lowerBound], as: UTF8.self)
            let sizeToken = sizeLine
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first ?? ""
            guard let chunkSize = Int(sizeToken.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16),
                  chunkSize >= 0 else {
                return .malformed
            }

            cursor = sizeLineRange.upperBound
            if chunkSize == 0 {
                // Optional trailer fields, then the blank line that ends the message.
                if data[cursor...].starts(with: lineBreak) {
                    return .complete(data.distance(from: data.startIndex, to: cursor) + lineBreak.count)
                }
                guard let trailerEnd = data.range(of: headerTerminator, in: cursor..<data.endIndex) else {
                    return .incomplete
                }
                return .complete(data.distance(from: data.startIndex, to: trailerEnd.upperBound))
            }

            guard let chunkEnd = data.index(cursor, offsetBy: chunkSize, limitedBy: data.endIndex),
                  data.distance(from: chunkEnd, to: data.endIndex) >= lineBreak.count else {
                return .incomplete
            }
            guard data[chunkEnd...].starts(with: lineBreak) else { return .malformed }
            cursor = data.index(chunkEnd, offsetBy: lineBreak.count)
        }
    }
}

/// How a plain-socket HTTP exchange was cut off by the network rather than
/// answered by the server.
public enum CleartextHTTPExchangeFailure: String, CaseIterable, Sendable {
    /// The connection closed before the status line and headers were all in.
    case closedBeforeResponse
    /// The connection closed before the body promised by the headers arrived.
    case truncatedBody
    /// The peer reset the connection after it was established.
    case resetByPeer

    /// The text callers see in error descriptions and diagnostic logs.
    public var diagnosticDescription: String {
        switch self {
        case .closedBeforeResponse: "Connection closed before the HTTP response headers arrived"
        case .truncatedBody: "Connection closed before the HTTP response body was complete"
        case .resetByPeer: "Connection reset during the HTTP exchange"
        }
    }

    /// POSIX codes for a connection the peer dropped once it was up.
    public static func isPeerReset(posixCode code: Int32) -> Bool {
        code == ECONNRESET || code == ECONNABORTED || code == EPIPE || code == ENOTCONN
    }

    public static func isPeerReset(_ error: any Error) -> Bool {
        if let networkError = error as? NWError {
            if case .posix(let code) = networkError { return isPeerReset(posixCode: code.rawValue) }
            return false
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && isPeerReset(posixCode: Int32(clamping: nsError.code))
    }
}

/// One quiet second attempt for an exchange the network cut off. Only a GET
/// without a body is repeated: it cannot change anything on the server. HTTP
/// status replies, timeouts, cancellation and oversized responses never reach
/// this policy, so they are never repeated.
public enum CleartextHTTPRetryPolicy {
    public static let maximumRetries = 1
    /// A second attempt that could not finish before the caller's deadline
    /// only delays the failure.
    public static let minimumRemainingTime: TimeInterval = 2

    public static func shouldRetry(
        method: String?,
        hasBody: Bool,
        failure: CleartextHTTPExchangeFailure,
        retriesSoFar: Int,
        remainingTime: TimeInterval
    ) -> Bool {
        let method = (method ?? "GET").uppercased()
        return method == "GET"
            && !hasBody
            && retriesSoFar < maximumRetries
            && remainingTime >= minimumRemainingTime
    }

    /// A short pause before the second attempt, spread a little so a burst of
    /// requests cut off together does not reconnect in the same instant.
    /// `randomFraction` is clamped to 0...1.
    public static func backoff(randomFraction: Double) -> TimeInterval {
        0.4 + 0.3 * min(max(randomFraction, 0), 1)
    }
}

/// Caps how many plain-socket HTTP exchanges run at once against one
/// host:port. That client opens a fresh TCP connection for every request, so a
/// wall of thumbnails scrolling past would otherwise open a burst of sockets
/// to one home server across the internet, where port forwards and carrier
/// middleboxes start closing them unanswered. Waiters are served first come,
/// first served, except that media range reads queue ahead of other requests
/// so playback never waits behind artwork.
public final class HTTPEndpointConnectionGate: @unchecked Sendable {
    public enum Lane: Sendable {
        case media
        case standard
    }

    /// One running exchange. Release it exactly when the exchange ends; a
    /// second release is ignored, and dropping the last reference releases it.
    public final class Permit: @unchecked Sendable {
        /// Time spent queued before the exchange could start.
        public let waited: Duration
        /// Exchanges already running or queued for this endpoint on arrival.
        public let ahead: Int
        private let gate: HTTPEndpointConnectionGate
        private let endpoint: String
        private let lock = NSLock()
        private var isReleased = false

        fileprivate init(gate: HTTPEndpointConnectionGate, endpoint: String, waited: Duration, ahead: Int) {
            self.gate = gate
            self.endpoint = endpoint
            self.waited = waited
            self.ahead = ahead
        }

        public func release() {
            let releasesNow = lock.withLock {
                guard !isReleased else { return false }
                isReleased = true
                return true
            }
            if releasesNow { gate.release(endpoint: endpoint) }
        }

        deinit { release() }
    }

    public struct Occupancy: Equatable, Sendable {
        public let running: Int
        public let queued: Int
    }

    public static let defaultLimit = 6
    public static let shared = HTTPEndpointConnectionGate(limit: defaultLimit)

    public let limit: Int
    private let lock = NSLock()
    private var endpoints: [String: EndpointState] = [:]

    private struct EndpointState {
        var running = 0
        var queue: [Waiter] = []
    }

    /// Guarded by the gate's lock.
    private final class Waiter: @unchecked Sendable {
        enum State {
            case pending
            case queued(CheckedContinuation<Void, any Error>)
            case granted
            case cancelled
        }

        let lane: Lane
        var state = State.pending
        var ahead = 0

        init(lane: Lane) { self.lane = lane }
    }

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func occupancy(endpoint: String) -> Occupancy {
        lock.withLock {
            let state = endpoints[endpoint]
            return Occupancy(running: state?.running ?? 0, queued: state?.queue.count ?? 0)
        }
    }

    /// Waits for a free slot. A task cancelled while queued leaves the queue
    /// and throws `CancellationError` without taking a slot.
    public func acquire(endpoint: String, lane: Lane = .standard) async throws -> Permit {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let arrival = clock.now
        let waiter = Waiter(lane: lane)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.enqueue(waiter, endpoint: endpoint, continuation: continuation)
            }
        } onCancel: {
            self.cancel(waiter, endpoint: endpoint)
        }
        let ahead = lock.withLock { waiter.ahead }
        return Permit(gate: self, endpoint: endpoint, waited: clock.now - arrival, ahead: ahead)
    }

    private func enqueue(
        _ waiter: Waiter,
        endpoint: String,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        lock.lock()
        if case .cancelled = waiter.state {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        var state = endpoints[endpoint] ?? EndpointState()
        waiter.ahead = state.running + state.queue.count
        // Slots are handed straight to the next waiter on release, so a free
        // slot means nobody is queued.
        if state.running < limit {
            state.running += 1
            waiter.state = .granted
            endpoints[endpoint] = state
            lock.unlock()
            continuation.resume()
            return
        }
        waiter.state = .queued(continuation)
        let position = waiter.lane == .media
            ? (state.queue.firstIndex { $0.lane == .standard } ?? state.queue.endIndex)
            : state.queue.endIndex
        state.queue.insert(waiter, at: position)
        endpoints[endpoint] = state
        lock.unlock()
    }

    private func cancel(_ waiter: Waiter, endpoint: String) {
        lock.lock()
        switch waiter.state {
        case .pending:
            waiter.state = .cancelled
            lock.unlock()
        case .queued(let continuation):
            waiter.state = .cancelled
            if var state = endpoints[endpoint] {
                state.queue.removeAll { $0 === waiter }
                endpoints[endpoint] = state.running == 0 && state.queue.isEmpty ? nil : state
            }
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        case .granted, .cancelled:
            lock.unlock()
        }
    }

    fileprivate func release(endpoint: String) {
        lock.lock()
        guard var state = endpoints[endpoint] else {
            lock.unlock()
            return
        }
        var handOff: CheckedContinuation<Void, any Error>?
        while handOff == nil, !state.queue.isEmpty {
            let next = state.queue.removeFirst()
            if case .queued(let continuation) = next.state {
                next.state = .granted
                handOff = continuation
            }
        }
        if handOff == nil { state.running = max(0, state.running - 1) }
        endpoints[endpoint] = state.running == 0 && state.queue.isEmpty ? nil : state
        lock.unlock()
        handOff?.resume()
    }
}
