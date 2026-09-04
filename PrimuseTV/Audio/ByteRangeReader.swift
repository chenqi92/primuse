#if os(tvOS)
import AVFoundation
import Foundation
import PrimuseKit
import UniformTypeIdentifiers

/// 一个可随机读字节的远端文件源(SMB / NFS / FTP / SFTP 等非 HTTP 协议)。各协议读取器
/// 实现它,`TVProtocolResourceLoader` 据此把字节流喂给 AVPlayer(Infuse 式直连)。
public protocol ByteRangeReader: Sendable {
    /// 文件总长度(用于 AVPlayer 的 contentLength / seek 上界)。
    func contentLength() async throws -> Int64
    /// 读取 `[offset, offset+length)` 的字节。返回可能短于 length(到文件末尾)。
    func read(offset: Int64, length: Int64) async throws -> Data
    /// 终止该歌曲仍在进行的协议操作并释放连接。一个 reader 只归一个
    /// resource loader/整文件下载所有，因此换歌时可以整体关闭。
    func close() async
}

public extension ByteRangeReader {
    func close() async {}
}

/// Swift actor 在 `await` 网络 I/O 时会重入。协议客户端通常包装一个可变的 C
/// context，必须把完整请求生命周期串行化，而不只是把属性放进 actor。
actor TVProtocolOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct TVRoutedByteRangeReaderCandidate: Sendable {
    let kind: SourceConnectionCandidateKind
    let reader: any ByteRangeReader
}

enum TVSourceConnectionFailoverPolicy {
    static func allowsRetry(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? StreamResolveError {
            switch error {
            case .missingCredential, .authFailed, .needs2FA:
                return false
            case .unsupportedSourceType, .badServerResponse, .cannotBuildURL, .relayUnavailable:
                return true
            }
        }
        if let error = error as? FnMusicServiceError {
            switch error {
            case .missingCredential, .authenticationFailed:
                return false
            case .invalidURL, .badServerResponse, .invalidResponse:
                return true
            }
        }
        if let error = error as? DaoLiYuServiceError {
            switch error {
            case .missingCredential, .authenticationFailed:
                return false
            case .invalidURL, .badServerResponse, .invalidResponse:
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           [Int(EACCES), Int(EPERM)].contains(nsError.code) {
            return false
        }
        if nsError.domain == NSURLErrorDomain {
            return nsError.code != NSURLErrorCancelled
                && nsError.code != NSURLErrorUserCancelledAuthentication
                && nsError.code != NSURLErrorUserAuthenticationRequired
        }
        return true
    }
}

enum TVRoutedByteRangeReaderError: Error {
    case noConnection
    case contentLengthMismatch
}

/// A protocol reader that keeps one logical file path while moving between
/// saved LAN and public endpoints. Reads are idempotent, so a failed range can
/// be retried on the next route; the file length must match before switching.
actor TVRoutedByteRangeReader: ByteRangeReader {
    private let sourceID: String
    private let candidates: [TVRoutedByteRangeReaderCandidate]
    private var activeIndex: Int?
    private var expectedLength: Int64?
    private var routeGeneration: UInt64?
    private let operationGate = TVProtocolOperationGate()

    init(sourceID: String, candidates: [TVRoutedByteRangeReaderCandidate]) {
        self.sourceID = sourceID
        self.candidates = candidates
    }

    func contentLength() async throws -> Int64 {
        try await withSerializedOperation {
            try await withReader { reader in
                let length = try await reader.contentLength()
                if let expectedLength, expectedLength != length {
                    throw TVRoutedByteRangeReaderError.contentLengthMismatch
                }
                expectedLength = length
                return length
            }
        }
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        try await withSerializedOperation {
            try await withReader { reader in
                if let expectedLength {
                    let candidateLength = try await reader.contentLength()
                    guard candidateLength == expectedLength else {
                        throw TVRoutedByteRangeReaderError.contentLengthMismatch
                    }
                }
                return try await reader.read(offset: offset, length: length)
            }
        }
    }

    func close() async {
        await operationGate.acquire()
        for candidate in candidates {
            await candidate.reader.close()
        }
        activeIndex = nil
        await operationGate.release()
    }

    private func withSerializedOperation<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func withReader<T: Sendable>(
        _ operation: (any ByteRangeReader) async throws -> T
    ) async throws -> T {
        guard candidates.isEmpty == false else {
            throw TVRoutedByteRangeReaderError.noConnection
        }

        let currentGeneration = await SourceConnectionRuntime.shared.routeGeneration()
        if routeGeneration != currentGeneration {
            activeIndex = nil
            routeGeneration = currentGeneration
        }
        var lastError: Error = TVRoutedByteRangeReaderError.noConnection
        let activeKind = await SourceConnectionRuntime.shared.activeKind(for: sourceID)
        var orderedIndices = Array(candidates.indices)
        let preferredIndex = activeIndex
            ?? activeKind.flatMap { kind in
                candidates.firstIndex(where: { $0.kind == kind })
            }
        if let preferredIndex,
           let position = orderedIndices.firstIndex(of: preferredIndex) {
            orderedIndices.remove(at: position)
            orderedIndices.insert(preferredIndex, at: 0)
        }

        for index in orderedIndices {
            do {
                let result = try await operation(candidates[index].reader)
                activeIndex = index
                await SourceConnectionRuntime.shared.record(
                    candidates[index].kind,
                    for: sourceID
                )
                return result
            } catch {
                lastError = error
                guard TVSourceConnectionFailoverPolicy.allowsRetry(after: error) else {
                    throw error
                }
                await candidates[index].reader.close()
                activeIndex = nil
                await SourceConnectionRuntime.shared.invalidate(sourceID: sourceID)
            }
        }
        throw lastError
    }
}

/// 用任意 `ByteRangeReader` 驱动 AVPlayer:把真实文件换成自定义 scheme,AVPlayer 便把每个
/// 字节 range 请求交给本 delegate;我们按 offset/length 调 `reader.read` 分块回填,支持 seek。
/// 与 HTTP 版 `TVStreamResourceLoader` 并列——那个走 URLSession,这个走原生协议库的 fetchRange。
final class TVProtocolResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "primuseproto"

    private let reader: ByteRangeReader
    private let explicitContentType: String?
    private let chunkSize: Int64 = 1 << 20   // 1MB:避免一次把大文件整段读进内存

    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private enum LoadingError: LocalizedError {
        case invalidContentLength(Int64)
        case invalidRange
        case prematureEOF(expectedEnd: Int64, actualOffset: Int64)
        case oversizedChunk(requested: Int64, actual: Int)
        case incomplete(expectedEnd: Int64, actualOffset: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidContentLength(let length):
                return PMString("ext.tv.error.invalidContentLength", String(length))
            case .invalidRange:
                return PMString("ext.tv.error.range.invalidRequest")
            case .prematureEOF(let expectedEnd, let actualOffset):
                return PMString(
                    "ext.tv.error.incompleteDownload",
                    String(expectedEnd),
                    String(actualOffset)
                )
            case .oversizedChunk(let requested, let actual):
                return PMString(
                    "ext.tv.error.oversizedChunk",
                    String(actual),
                    String(requested)
                )
            case .incomplete(let expectedEnd, let actualOffset):
                return PMString(
                    "ext.tv.error.incompleteDownload",
                    String(expectedEnd),
                    String(actualOffset)
                )
            }
        }
    }

    init(reader: ByteRangeReader, fileExtension: String?) {
        self.reader = reader
        self.explicitContentType = fileExtension.flatMap { UTType(filenameExtension: $0)?.identifier }
        super.init()
    }

    deinit {
        lock.lock()
        let activeTasks = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
        let reader = reader
        Task { await reader.close() }
    }

    /// 触发 delegate 的占位 URL(host/path 仅用于满足 AVURLAsset,真实数据来自 reader)。
    static func makeURL() -> URL? { URL(string: "\(scheme)://stream/item") }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        // Hold the registry lock while creating/registering the task. A tiny
        // information-only request can otherwise finish and clear itself before
        // it has been inserted, leaving completed tasks retained indefinitely.
        lock.lock()
        let task = Task { [weak self] in
            await self?.serve(loadingRequest)
            self?.clearTask(id)
        }
        tasks[id] = task
        lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(loadingRequest)
        lock.lock(); let task = tasks[id]; tasks[id] = nil; lock.unlock()
        task?.cancel()
    }

    private func clearTask(_ id: ObjectIdentifier) {
        lock.lock(); tasks[id] = nil; lock.unlock()
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        do {
            let total = try await reader.contentLength()
            try Task.checkCancellation()
            guard total > 0 else { throw LoadingError.invalidContentLength(total) }
            if let info = request.contentInformationRequest {
                info.contentType = explicitContentType
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return
            }
            guard dataRequest.requestedOffset >= 0 else {
                throw LoadingError.invalidRange
            }
            let requestedStart = dataRequest.requestedOffset
            var offset = dataRequest.currentOffset > 0
                ? max(requestedStart, dataRequest.currentOffset)
                : requestedStart
            let endExclusive: Int64
            if dataRequest.requestsAllDataToEndOfResource {
                endExclusive = total
            } else {
                guard let requestedEnd = SafeByteRange.exclusiveEnd(
                    offset: requestedStart,
                    length: Int64(dataRequest.requestedLength)
                ) else { throw LoadingError.invalidRange }
                endExclusive = min(requestedEnd, total)
            }
            guard offset < total, offset < endExclusive else {
                request.finishLoading()
                return
            }
            while offset < endExclusive {
                try Task.checkCancellation()
                let len = min(chunkSize, endExclusive - offset)
                let data = try await reader.read(offset: offset, length: len)
                try Task.checkCancellation()
                guard !data.isEmpty else {
                    throw LoadingError.prematureEOF(
                        expectedEnd: endExclusive,
                        actualOffset: offset
                    )
                }
                guard Int64(data.count) <= len else {
                    throw LoadingError.oversizedChunk(requested: len, actual: data.count)
                }
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            }
            guard offset == endExclusive else {
                throw LoadingError.incomplete(expectedEnd: endExclusive, actualOffset: offset)
            }
            try Task.checkCancellation()
            request.finishLoading()
        } catch {
            if !OperationCancellationPolicy.isCancellation(error) {
                plog("📺 proto loader ERROR — \(error.localizedDescription)")
                request.finishLoading(with: error)
            }
        }
    }
}
#endif
