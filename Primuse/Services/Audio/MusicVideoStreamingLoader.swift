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
    private let sourceID: String
    private let streamEpoch: UInt64
    private let scopeIsCurrent: @Sendable () async -> Bool
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
        sourceID: String,
        streamEpoch: UInt64,
        scopeIsCurrent: @escaping @Sendable () async -> Bool,
        path: String,
        contentLength: Int64,
        cacheTarget: URL,
        chunkBytes: Int64
    ) {
        self.connector = connector
        self.sourceID = sourceID
        self.streamEpoch = streamEpoch
        self.scopeIsCurrent = scopeIsCurrent
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
            try await validateScope()
            while offset < end {
                try await validateScope()
                let length = min(chunkBytes, end - offset)
                let data: Data
                if let local = readLocalRange(offset: offset, length: Int(length)) {
                    data = local
                } else {
                    data = try await connector.fetchRange(path: path, offset: offset, length: length)
                }
                try await validateScope()
                if data.isEmpty { break }
                guard CloudPlaybackSource.withCurrentStreamEpoch(
                    sourceID: sourceID,
                    epoch: streamEpoch,
                    {
                        dataRequest.respond(with: data)
                        return ()
                    }
                ) != nil else { throw CancellationError() }
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

    private func validateScope() async throws {
        try Task.checkCancellation()
        guard CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: sourceID,
                ticket: streamEpoch
              ), await scopeIsCurrent() else {
            throw CancellationError()
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
        guard !invalidated,
              CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: sourceID,
                ticket: streamEpoch
              ) else {
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

/// Feeds the same sparse range/cache source used by SFBAudioEngine into
/// AVPlayer. This keeps connector authentication and cache semantics intact
/// while allowing multichannel ISO Base Media audio to remain on Apple's
/// system media pipeline instead of being flattened into PCM first.
final class SystemAudioStreamingLoader: NSObject, @unchecked Sendable {
    static let scheme = "primuse-system-audio"

    private final class InputSourceBox: @unchecked Sendable {
        let value: CloudInputSourceObjC

        init(_ value: CloudInputSourceObjC) {
            self.value = value
        }
    }

    private let inputSource: InputSourceBox
    private let contentLength: Int64
    private let contentType: String?
    private let fileExtension: String
    private let queue = DispatchQueue(label: "primuse.system-audio.resource-loader")
    private let readQueue = DispatchQueue(
        label: "primuse.system-audio.blocking-read",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private final class RequestWork: @unchecked Sendable {
        var task: Task<Void, Never>?
        var isCancelled = false
    }

    private var requestTasks: [ObjectIdentifier: RequestWork] = [:]
    private var invalidated = false

    init(inputSource: CloudInputSourceObjC, fileExtension: String) {
        self.inputSource = InputSourceBox(inputSource)
        self.contentLength = inputSource.totalLength
        self.fileExtension = fileExtension
        self.contentType = UTType(filenameExtension: fileExtension)?.identifier
        super.init()
    }

    func makeAsset() -> AVURLAsset? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "audio"
        components.path = "/\(UUID().uuidString)\(fileExtension.isEmpty ? "" : ".\(fileExtension)")"
        guard let url = components.url else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let tasks = requestTasks.values
        for work in tasks { work.isCancelled = true }
        requestTasks = [:]
        lock.unlock()
        for work in tasks { work.task?.cancel() }
        readQueue.async { [inputSource] in
            try? inputSource.value.close()
        }
    }

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

        let requestedOffset = dataRequest.requestedOffset
        var offset = dataRequest.currentOffset
        guard requestedOffset >= 0, offset >= requestedOffset else {
            finish(box, error: CocoaError(.fileReadInvalidFileName))
            return
        }
        let end: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            end = contentLength
        } else if let requestedEnd = SafeByteRange.exclusiveEnd(
            offset: requestedOffset,
            length: Int64(dataRequest.requestedLength)
        ) {
            end = min(contentLength, requestedEnd)
        } else {
            finish(box, error: CocoaError(.fileReadInvalidFileName))
            return
        }
        guard offset <= end else {
            finish(box, error: CocoaError(.fileReadInvalidFileName))
            return
        }

        do {
            while offset < end {
                try Task.checkCancellation()
                let length = Int(min(CloudPlaybackSource.chunkSize, end - offset))
                let data = try await readData(atOffset: offset, length: length)
                try Task.checkCancellation()
                guard !data.isEmpty else { break }
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            }
            finish(box, error: nil)
        } catch is CancellationError {
            return
        } catch {
            plog("System audio loader fetch failed offset=\(offset): \(error.localizedDescription)")
            finish(box, error: error)
        }
    }

    private func readData(atOffset offset: Int64, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [inputSource] in
                do {
                    continuation.resume(
                        returning: try inputSource.value.readData(atOffset: offset, length: length)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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

    private func clearTask(for key: ObjectIdentifier, matching work: RequestWork) {
        lock.lock()
        if requestTasks[key] === work {
            requestTasks[key] = nil
        }
        lock.unlock()
    }
}

extension SystemAudioStreamingLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let box = RequestBox(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        let work = RequestWork()

        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return false
        }
        requestTasks[key] = work
        lock.unlock()

        let task = Task { [weak self] in
            await self?.serve(box)
            self?.clearTask(for: key, matching: work)
        }
        lock.lock()
        let shouldCancel = invalidated || work.isCancelled || requestTasks[key] !== work
        if shouldCancel {
            work.isCancelled = true
        } else {
            work.task = task
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let work = requestTasks.removeValue(forKey: key)
        work?.isCancelled = true
        let task = work?.task
        lock.unlock()
        task?.cancel()
    }
}
