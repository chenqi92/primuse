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

    init(sourceID: String, candidates: [TVRoutedByteRangeReaderCandidate]) {
        self.sourceID = sourceID
        self.candidates = candidates
    }

    func contentLength() async throws -> Int64 {
        try await withReader { reader in
            let length = try await reader.contentLength()
            if let expectedLength, expectedLength != length {
                throw TVRoutedByteRangeReaderError.contentLengthMismatch
            }
            expectedLength = length
            return length
        }
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
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
        let orderedIndices = candidates.indices.sorted { lhs, rhs in
            if candidates[lhs].kind == activeKind { return true }
            if candidates[rhs].kind == activeKind { return false }
            if lhs == activeIndex { return true }
            if rhs == activeIndex { return false }
            return lhs < rhs
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

    init(reader: ByteRangeReader, fileExtension: String?) {
        self.reader = reader
        self.explicitContentType = fileExtension.flatMap { UTType(filenameExtension: $0)?.identifier }
        super.init()
    }

    /// 触发 delegate 的占位 URL(host/path 仅用于满足 AVURLAsset,真实数据来自 reader)。
    static func makeURL() -> URL? { URL(string: "\(scheme)://stream/item") }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(loadingRequest)
            self?.clearTask(id)
        }
        lock.lock(); tasks[id] = task; lock.unlock()
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
            if let info = request.contentInformationRequest {
                info.contentType = explicitContentType
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return
            }
            var offset = max(0, dataRequest.currentOffset)
            let end: Int64 = dataRequest.requestsAllDataToEndOfResource
                ? total - 1
                : min(dataRequest.requestedOffset &+ Int64(dataRequest.requestedLength) - 1, total - 1)
            while offset <= end {
                if Task.isCancelled { return }
                let len = min(chunkSize, end - offset + 1)
                let data = try await reader.read(offset: offset, length: len)
                if data.isEmpty { break }
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            }
            request.finishLoading()
        } catch {
            if !Task.isCancelled {
                plog("📺 proto loader ERROR — \(error.localizedDescription)")
                request.finishLoading(with: error)
            }
        }
    }
}
#endif
