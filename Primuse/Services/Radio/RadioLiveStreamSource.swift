import Foundation
import Network
import PrimuseKit

/// Feeds a continuous HTTP(S) response into the live radio decoder without
/// requiring a content length or seek support. ICY metadata is removed before
/// audio bytes enter the decoder.
final class RadioLiveStreamSource: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Container: Sendable {
        case flac
        case oggFLAC
    }

    struct Prepared: @unchecked Sendable {
        let container: Container
        let format: RadioStreamFormat
        let bitRate: Int?
    }

    enum StreamError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case unsupportedFormat
        case endedBeforeAudio
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return String(localized: "error_radio_invalid_response")
            case .httpStatus(let status):
                return String(
                    format: String(localized: "error_radio_http %@"),
                    String(status)
                )
            case .unsupportedFormat:
                return String(localized: "error_radio_unsupported_format")
            case .endedBeforeAudio:
                return String(localized: "error_radio_ended_before_audio")
            case .cancelled:
                return String(localized: "error_radio_cancelled")
            }
        }
    }

    typealias MetadataHandler = @Sendable (String) -> Void

    private static let maximumSniffBytes = 64 * 1_024
    private static let maximumBufferedBytes = 2 * 1_024 * 1_024

    private let url: URL
    private let metadataHandler: MetadataHandler?
    private let condition = NSCondition()

    private var chunks: [Data] = []
    private var firstChunkOffset = 0
    private var bufferedByteCount = 0
    private var sniffData = Data()
    private var terminalError: Error?
    private var reachedEOF = false
    private var cancelled = false
    private var started = false

    private var preparationContinuation: CheckedContinuation<Prepared, Error>?
    private var preparationResult: Result<Prepared, Error>?
    private var contentType: String?
    private var bitRate: Int?

    // Accessed only by the URLSession delegate queue.
    private var icyMetadataInterval: Int?
    private var icyAudioBytesRemaining = 0
    private var icyMetadataBytesRemaining = 0
    private var icyMetadataData = Data()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var plainHTTPTransport: RadioPlainHTTPStreamTransport?

    init(url: URL, metadataHandler: MetadataHandler? = nil) {
        self.url = url
        self.metadataHandler = metadataHandler
        super.init()
    }

    func prepare() async throws -> Prepared {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediateResult: Result<Prepared, Error>?
                condition.lock()
                if let preparationResult {
                    immediateResult = preparationResult
                } else {
                    preparationContinuation = continuation
                }
                let shouldStart = !started
                started = true
                condition.unlock()

                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
                if shouldStart {
                    startRequest()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let completion = finish(with: .failure(StreamError.cancelled), markCancelled: true)
        condition.lock()
        let task = task
        let session = session
        let plainHTTPTransport = plainHTTPTransport
        condition.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        plainHTTPTransport?.cancel()
        resume(completion)
    }

    private func startRequest() {
        condition.lock()
        let shouldStart = !cancelled
        condition.unlock()
        guard shouldStart else { return }

        if InsecureHTTPHostPolicy.requiresExplicitTrust(for: url) {
            startPlainHTTPRequest()
            return
        }

        startURLSessionRequest()
    }

    private func startURLSessionRequest() {

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("Primuse/Radio", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.name = "com.welape.yuanyin.radio-live-stream"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            session.invalidateAndCancel()
            return
        }
        self.session = session
        self.task = task
        condition.unlock()
        task.resume()
    }

    private func startPlainHTTPRequest() {
        #if !os(tvOS)
        guard let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
              SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) else {
            let completion = finish(with: .failure(
                TrustedHTTPTransportError.permissionRequired(
                    host: TrustedHTTPTransport.trustTarget(for: url) ?? url.host ?? ""
                )
            ))
            resume(completion)
            return
        }
        #endif

        do {
            let transport = try RadioPlainHTTPStreamTransport(
                url: url,
                headers: [
                    "Icy-MetaData": "1",
                    "User-Agent": "Primuse/Radio"
                ],
                onResponse: { [weak self] response in
                    self?.accept(response: response) ?? false
                },
                onData: { [weak self] data in
                    self?.receiveBodyData(data)
                },
                onComplete: { [weak self] error in
                    self?.completeStream(with: error)
                }
            )
            condition.lock()
            guard !cancelled else {
                condition.unlock()
                transport.cancel()
                return
            }
            plainHTTPTransport = transport
            condition.unlock()
            transport.start()
        } catch {
            let completion = finish(with: .failure(error))
            resume(completion)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              accept(response: response) else {
            if !(response is HTTPURLResponse) {
                let completion = finish(with: .failure(StreamError.invalidResponse))
                resume(completion)
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    private func accept(response: HTTPURLResponse) -> Bool {
        guard (200..<300).contains(response.statusCode) else {
            let completion = finish(with: .failure(StreamError.httpStatus(response.statusCode)))
            resume(completion)
            return false
        }

        contentType = response.value(forHTTPHeaderField: "Content-Type")
        bitRate = Self.parseBitRate(
            response.value(forHTTPHeaderField: "icy-br")
                ?? response.value(forHTTPHeaderField: "x-audiocast-bitrate")
        )
        if let rawInterval = response.value(forHTTPHeaderField: "icy-metaint"),
           let interval = Int(rawInterval.trimmingCharacters(in: .whitespacesAndNewlines)),
           interval > 0 {
            icyMetadataInterval = interval
            icyAudioBytesRemaining = interval
        } else {
            icyMetadataInterval = nil
        }
        return true
    }

    private func receiveBodyData(_ data: Data) {
        guard !data.isEmpty else { return }
        if icyMetadataInterval == nil {
            appendAudio(data)
        } else {
            consumeICY(data)
        }
    }

    private func completeStream(with error: Error?) {
        if let error {
            let completion = finish(with: .failure(error))
            resume(completion)
            return
        }

        var completion: PreparationCompletion?
        condition.lock()
        reachedEOF = true
        if preparationResult == nil {
            let error: Error = sniffData.isEmpty
                ? StreamError.endedBeforeAudio
                : StreamError.unsupportedFormat
            completion = setPreparationResultLocked(.failure(error))
        }
        condition.broadcast()
        condition.unlock()
        resume(completion)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receiveBodyData(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            condition.lock()
            let wasCancelled = cancelled
            condition.unlock()
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled,
               wasCancelled {
                return
            }
            completeStream(with: error)
        } else {
            completeStream(with: nil)
        }
    }

    private func consumeICY(_ data: Data) {
        guard let interval = icyMetadataInterval else {
            appendAudio(data)
            return
        }

        var index = data.startIndex
        while index < data.endIndex {
            if icyMetadataBytesRemaining > 0 {
                let count = min(icyMetadataBytesRemaining, data.distance(from: index, to: data.endIndex))
                let end = data.index(index, offsetBy: count)
                icyMetadataData.append(contentsOf: data[index..<end])
                icyMetadataBytesRemaining -= count
                index = end
                if icyMetadataBytesRemaining == 0 {
                    publishICYMetadata(icyMetadataData)
                    icyMetadataData.removeAll(keepingCapacity: true)
                    icyAudioBytesRemaining = interval
                }
                continue
            }

            if icyAudioBytesRemaining == 0 {
                let metadataLength = Int(data[index]) * 16
                index = data.index(after: index)
                if metadataLength == 0 {
                    icyAudioBytesRemaining = interval
                } else {
                    icyMetadataBytesRemaining = metadataLength
                }
                continue
            }

            let count = min(icyAudioBytesRemaining, data.distance(from: index, to: data.endIndex))
            let end = data.index(index, offsetBy: count)
            appendAudio(Data(data[index..<end]))
            icyAudioBytesRemaining -= count
            index = end
        }
    }

    private func publishICYMetadata(_ data: Data) {
        let trimmed = Data(data.prefix { $0 != 0 })
        guard !trimmed.isEmpty,
              let text = String(data: trimmed, encoding: .utf8)
                ?? String(data: trimmed, encoding: .isoLatin1),
              let marker = text.range(of: "StreamTitle='", options: .caseInsensitive) else {
            return
        }
        let suffix = text[marker.upperBound...]
        let title = suffix.split(separator: "'", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            metadataHandler?(title)
        }
    }

    private func appendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        var completion: PreparationCompletion?

        condition.lock()
        guard !cancelled, terminalError == nil, !reachedEOF else {
            condition.unlock()
            return
        }
        chunks.append(data)
        bufferedByteCount += data.count
        if sniffData.count < Self.maximumSniffBytes {
            sniffData.append(data.prefix(Self.maximumSniffBytes - sniffData.count))
        }
        if preparationResult == nil,
           let container = Self.sniffContainer(from: sniffData) {
            let prepared = Prepared(
                container: container,
                format: .flac,
                bitRate: bitRate
            )
            completion = setPreparationResultLocked(.success(prepared))
        } else if preparationResult == nil,
                  sniffData.count >= Self.maximumSniffBytes {
            completion = setPreparationResultLocked(.failure(StreamError.unsupportedFormat))
        }
        condition.broadcast()
        condition.unlock()
        resume(completion)

        condition.lock()
        while bufferedByteCount > Self.maximumBufferedBytes,
              !cancelled,
              terminalError == nil,
              !reachedEOF {
            condition.wait()
        }
        condition.unlock()
    }

    func read(
        maximumLength: Int,
        atEOF: UnsafeMutablePointer<ObjCBool>,
        errorOut: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Data? {
        condition.lock()
        defer { condition.unlock() }

        while bufferedByteCount == 0,
              terminalError == nil,
              !reachedEOF,
              !cancelled {
            condition.wait()
        }

        if bufferedByteCount > 0 {
            let requested = max(1, maximumLength)
            var result = Data()
            result.reserveCapacity(min(requested, bufferedByteCount))
            while result.count < requested, let first = chunks.first {
                let available = first.count - firstChunkOffset
                let count = min(requested - result.count, available)
                let start = first.index(first.startIndex, offsetBy: firstChunkOffset)
                let end = first.index(start, offsetBy: count)
                result.append(contentsOf: first[start..<end])
                firstChunkOffset += count
                bufferedByteCount -= count
                if firstChunkOffset == first.count {
                    chunks.removeFirst()
                    firstChunkOffset = 0
                }
            }
            atEOF.pointee = false
            condition.broadcast()
            return result
        }

        if let terminalError {
            errorOut?.pointee = terminalError as NSError
            atEOF.pointee = false
            return nil
        }
        if cancelled {
            errorOut?.pointee = StreamError.cancelled as NSError
            atEOF.pointee = false
            return nil
        }
        atEOF.pointee = true
        return Data()
    }

    private typealias PreparationCompletion = (
        CheckedContinuation<Prepared, Error>,
        Result<Prepared, Error>
    )

    private func finish(
        with result: Result<Prepared, Error>,
        markCancelled: Bool = false
    ) -> PreparationCompletion? {
        condition.lock()
        if markCancelled { cancelled = true }
        if case .failure(let error) = result, terminalError == nil {
            terminalError = error
        }
        let completion = preparationResult == nil
            ? setPreparationResultLocked(result)
            : nil
        condition.broadcast()
        condition.unlock()
        return completion
    }

    private func setPreparationResultLocked(
        _ result: Result<Prepared, Error>
    ) -> PreparationCompletion? {
        preparationResult = result
        guard let continuation = preparationContinuation else { return nil }
        preparationContinuation = nil
        return (continuation, result)
    }

    private func resume(_ completion: PreparationCompletion?) {
        guard let completion else { return }
        completion.0.resume(with: completion.1)
    }

    private static func sniffContainer(from data: Data) -> Container? {
        if data.starts(with: Data("fLaC".utf8)) {
            return .flac
        }
        guard data.starts(with: Data("OggS".utf8)) else { return nil }
        if data.range(of: Data([0x7f, 0x46, 0x4c, 0x41, 0x43])) != nil
            || data.range(of: Data("fLaC".utf8)) != nil {
            return .oggFLAC
        }
        return nil
    }

    private static func parseBitRate(_ value: String?) -> Int? {
        guard let value,
              let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              number.isFinite,
              number > 0 else { return nil }
        return Int((number < 10_000 ? number * 1_000 : number).rounded())
    }
}

private final class RadioPlainHTTPStreamTransport: @unchecked Sendable {
    typealias ResponseHandler = @Sendable (HTTPURLResponse) -> Bool
    typealias DataHandler = @Sendable (Data) -> Void
    typealias CompletionHandler = @Sendable (Error?) -> Void

    private static let headerLimit = 64 * 1_024
    private static let firstResponseTimeout: TimeInterval = 15

    private let url: URL
    private let headers: [String: String]
    private let onResponse: ResponseHandler
    private let onData: DataHandler
    private let onComplete: CompletionHandler
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.welape.yuanyin.radio-plain-http")
    private let lock = NSLock()

    private var didFinish = false
    private var didReceiveResponse = false
    private var headerBuffer = Data()
    private var chunkedDecoder: RadioHTTPChunkedBodyDecoder?

    init(
        url: URL,
        headers: [String: String],
        onResponse: @escaping ResponseHandler,
        onData: @escaping DataHandler,
        onComplete: @escaping CompletionHandler
    ) throws {
        guard url.scheme?.lowercased() == "http",
              let host = url.host,
              let rawPort = UInt16(exactly: url.port ?? 80),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw URLError(.badURL)
        }
        self.url = url
        self.headers = headers
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.firstResponseTimeout) { [weak self] in
            self?.failIfResponseTimedOut()
        }
    }

    func cancel() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: requestData(), completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(error)
                } else {
                    self?.receiveNext()
                }
            })
        case .failed(let error):
            finish(error)
        case .cancelled:
            finish(URLError(.cancelled))
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(error)
                return
            }
            do {
                if let data, !data.isEmpty, try !self.consume(data) {
                    return
                }
            } catch {
                self.finish(error)
                return
            }
            if isComplete || data?.isEmpty == true {
                self.finish(nil)
            } else {
                self.receiveNext()
            }
        }
    }

    private func consume(_ data: Data) throws -> Bool {
        if !didReceiveResponse {
            headerBuffer.append(data)
            let separator = Data("\r\n\r\n".utf8)
            guard let range = headerBuffer.range(of: separator) else {
                guard headerBuffer.count <= Self.headerLimit else {
                    throw URLError(.badServerResponse)
                }
                return true
            }

            let headerData = Data(headerBuffer[..<range.lowerBound])
            let bodyData = Data(headerBuffer[range.upperBound...])
            headerBuffer.removeAll(keepingCapacity: false)
            let response = try Self.parseResponse(headerData, for: url)
            markResponseReceived()
            guard onResponse(response) else {
                cancel()
                return false
            }
            if response.value(forHTTPHeaderField: "Transfer-Encoding")?
                .localizedCaseInsensitiveContains("chunked") == true {
                chunkedDecoder = RadioHTTPChunkedBodyDecoder()
            }
            try consumeBody(bodyData)
            return true
        }

        try consumeBody(data)
        return true
    }

    private func consumeBody(_ data: Data) throws {
        guard !data.isEmpty else { return }
        if chunkedDecoder != nil {
            try chunkedDecoder?.append(data, emit: onData)
        } else {
            onData(data)
        }
    }

    private func requestData() -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = components?.percentEncodedPath ?? url.path
        let path = encodedPath.isEmpty ? "/" : encodedPath
        let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
        let host = url.host ?? ""
        let bracketedHost = host.contains(":") ? "[\(host)]" : host
        let hostHeader = url.port == nil || url.port == 80
            ? bracketedHost
            : "\(bracketedHost):\(url.port!)"
        var values = headers
        values["Host"] = hostHeader
        values["Connection"] = "close"
        values["Accept-Encoding"] = "identity"
        var lines = ["GET \(path)\(query) HTTP/1.1"]
        for key in values.keys.sorted() {
            if let value = values[key] { lines.append("\(key): \(value)") }
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func markResponseReceived() {
        lock.lock()
        didReceiveResponse = true
        lock.unlock()
    }

    private func failIfResponseTimedOut() {
        lock.lock()
        let shouldFail = !didFinish && !didReceiveResponse
        lock.unlock()
        if shouldFail { finish(URLError(.timedOut)) }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        connection.cancel()
        onComplete(error)
    }

    private static func parseResponse(_ data: Data, for url: URL) throws -> HTTPURLResponse {
        let text = String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw URLError(.badServerResponse) }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              (parts[0].hasPrefix("HTTP/") || parts[0].uppercased() == "ICY"),
              let statusCode = Int(parts[1]) else {
            throw URLError(.badServerResponse)
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = fields[key], !existing.isEmpty {
                fields[key] = "\(existing), \(value)"
            } else {
                fields[key] = value
            }
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        ) else {
            throw URLError(.badServerResponse)
        }
        return response
    }
}

private struct RadioHTTPChunkedBodyDecoder {
    private var buffer = Data()
    private var chunkBytesRemaining: Int?
    private var reachedEnd = false

    mutating func append(_ data: Data, emit: (Data) -> Void) throws {
        guard !reachedEnd else { return }
        buffer.append(data)

        while !reachedEnd {
            if chunkBytesRemaining == nil {
                let lineBreak = Data("\r\n".utf8)
                guard let range = buffer.range(of: lineBreak) else {
                    guard buffer.count <= 8 * 1_024 else { throw URLError(.badServerResponse) }
                    return
                }
                let lineData = Data(buffer[..<range.lowerBound])
                buffer.removeFirst(range.upperBound)
                guard let line = String(data: lineData, encoding: .ascii),
                      let token = line.split(separator: ";", maxSplits: 1).first,
                      let count = Int(token.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16),
                      count >= 0 else {
                    throw URLError(.badServerResponse)
                }
                if count == 0 {
                    reachedEnd = true
                    return
                }
                chunkBytesRemaining = count
            }

            if let remaining = chunkBytesRemaining, remaining > 0 {
                guard !buffer.isEmpty else { return }
                let count = min(remaining, buffer.count)
                emit(Data(buffer.prefix(count)))
                buffer.removeFirst(count)
                chunkBytesRemaining = remaining - count
                if remaining - count > 0 { return }
            }

            guard chunkBytesRemaining == 0 else { continue }
            guard buffer.count >= 2 else { return }
            guard buffer.prefix(2).elementsEqual([13, 10]) else {
                throw URLError(.badServerResponse)
            }
            buffer.removeFirst(2)
            chunkBytesRemaining = nil
        }
    }
}
