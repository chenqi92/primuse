import AVFoundation
import Foundation
import PrimuseKit
import UniformTypeIdentifiers

/// resolveVideoAsset 的返回形态: 直链/本地文件给 AVPlayer(url:),
/// 无直链的 range 源走 resource loader 流式喂数据。
enum MusicVideoPlaybackAsset {
    case url(URL)
    case streaming(AVURLAsset, MusicVideoStreamingLoader)
}

/// 把 `connector.fetchRange` 桥接成 AVPlayer 可流式消费的资源, 让云盘 /
/// WebDAV / SMB 等没有可直链播放 URL 的源即点即播, 不再等全量下载。
///
/// 数据请求按块满足: 优先读本地缓存(完整缓存文件, 或后台顺序下载已
/// 覆盖的 .partial 前缀 —— partial 是顺序写入, 文件长度即有效前缀),
/// 未覆盖的区间直接网络 Range 直取。后台顺序下载持续推进, loader 的读
/// 大多命中本地前缀, 直取只发生在播放位置跑到下载进度前面时(mp4 的
/// moov 探测、拖进度条)。
///
/// 注意 AVAssetResourceLoader 对 delegate 是弱引用, 播放期间必须由外部
/// (AudioPlayerService)强持有本对象; 停止播放时调 invalidate() 取消
/// 所有在途请求。
final class MusicVideoStreamingLoader: NSObject, @unchecked Sendable {
    static let scheme = "primuse-mv"

    private let connector: any MusicSourceConnector
    private let path: String
    private let contentLength: Int64
    private let contentType: String?
    private let cacheTarget: URL
    private let cachePartial: URL
    private let chunkBytes: Int64
    private let queue = DispatchQueue(label: "primuse.mv.resource-loader")
    private let lock = NSLock()
    private var requestTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var invalidated = false

    init(
        connector: any MusicSourceConnector,
        path: String,
        contentLength: Int64,
        cacheTarget: URL,
        chunkBytes: Int64
    ) {
        self.connector = connector
        self.path = path
        self.contentLength = contentLength
        self.cacheTarget = cacheTarget
        self.cachePartial = URL(fileURLWithPath: cacheTarget.path + ".partial")
        self.chunkBytes = max(512 * 1024, chunkBytes)
        let ext = (path as NSString).pathExtension.lowercased()
        self.contentType = UTType(filenameExtension: ext)?.identifier
        super.init()
    }

    /// 自定义 scheme 的占位 URL —— 内容路由全靠本 loader 实例, URL 仅保留
    /// 扩展名帮 AVFoundation 提示容器类型。
    func makeAsset() -> AVURLAsset? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "video"
        let ext = (path as NSString).pathExtension
        components.path = "/" + UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        guard let url = components.url else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let tasks = requestTasks
        requestTasks = [:]
        lock.unlock()
        for task in tasks.values { task.cancel() }
    }

    // MARK: - Serving

    private final class RequestBox: @unchecked Sendable {
        let value: AVAssetResourceLoadingRequest
        init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
    }

    private func serve(_ box: RequestBox) async {
        let request = box.value
        if let info = request.contentInformationRequest {
            info.contentLength = contentLength
            info.isByteRangeAccessSupported = true
            if let contentType { info.contentType = contentType }
        }

        guard let dataRequest = request.dataRequest else {
            finish(box, error: nil)
            return
        }

        var offset = dataRequest.requestedOffset
        let end: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            end = contentLength
        } else if let requestedEnd = SafeByteRange.exclusiveEnd(
            offset: offset,
            length: Int64(dataRequest.requestedLength)
        ) {
            end = min(contentLength, requestedEnd)
        } else {
            finish(box, error: CocoaError(.fileReadInvalidFileName))
            return
        }

        do {
            while offset < end {
                try Task.checkCancellation()
                let length = min(chunkBytes, end - offset)
                let data: Data
                if let local = readLocalRange(offset: offset, length: Int(length)) {
                    data = local
                } else {
                    data = try await connector.fetchRange(path: path, offset: offset, length: length)
                }
                if data.isEmpty { break }
                try Task.checkCancellation()
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            }
            finish(box, error: nil)
        } catch is CancellationError {
            // didCancel / invalidate 已经处理, 不再 finishLoading。
        } catch {
            plog("🎞️ MV loader fetch failed offset=\(offset): \(error.localizedDescription)")
            finish(box, error: error)
        }
    }

    /// 完整缓存 > 顺序下载中的 .partial 前缀。.partial 只会顺序增长, 文件
    /// 长度覆盖请求区间即可信; 下载完成瞬间 partial 被 move 成 target,
    /// 读失败自然落到下一候选或网络直取。
    private func readLocalRange(offset: Int64, length: Int) -> Data? {
        guard length >= 0,
              let end = SafeByteRange.exclusiveEnd(offset: offset, length: Int64(length)) else {
            return nil
        }
        for candidate in [cacheTarget, cachePartial] {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: candidate.path)[.size]) as? Int64,
                  size >= end,
                  let handle = try? FileHandle(forReadingFrom: candidate) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: length),
                  data.count == length else { continue }
            return data
        }
        return nil
    }

    private func finish(_ box: RequestBox, error: Error?) {
        let request = box.value
        guard !request.isFinished, !request.isCancelled else { return }
        if let error {
            request.finishLoading(with: error)
        } else {
            request.finishLoading()
        }
    }

    private func clearTask(for key: ObjectIdentifier) {
        lock.lock()
        requestTasks[key] = nil
        lock.unlock()
    }
}

extension MusicVideoStreamingLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return false
        }
        lock.unlock()

        let box = RequestBox(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(box)
            self?.clearTask(for: key)
        }
        lock.lock()
        requestTasks[key] = task
        lock.unlock()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = requestTasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }
}
