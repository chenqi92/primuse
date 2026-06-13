#if os(tvOS)
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 一个可随机读字节的远端文件源(SMB / NFS / FTP / SFTP 等非 HTTP 协议)。各协议读取器
/// 实现它,`TVProtocolResourceLoader` 据此把字节流喂给 AVPlayer(Infuse 式直连)。
public protocol ByteRangeReader: Sendable {
    /// 文件总长度(用于 AVPlayer 的 contentLength / seek 上界)。
    func contentLength() async throws -> Int64
    /// 读取 `[offset, offset+length)` 的字节。返回可能短于 length(到文件末尾)。
    func read(offset: Int64, length: Int64) async throws -> Data
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
