import Foundation
import PrimuseKit

/// 本机文件夹引用里那些放在 iCloud 云盘、还没下到这台设备的歌:起播前读状态、请求下载、
/// 等到能读(#170)。判定规则见 `UbiquitousPlaybackDownloadPolicy`。
enum UbiquitousPlaybackFile {
    struct DownloadError: LocalizedError, Sendable {
        let failure: UbiquitousPlaybackDownloadPolicy.Failure
        let underlyingDescription: String?

        var errorDescription: String? {
            switch failure {
            case .offline:
                String(localized: "playback_icloud_error_offline")
            case .downloadError, .neverStarted, .timedOut:
                String(localized: "playback_icloud_error_download")
            }
        }
    }

    struct Snapshot: Sendable {
        var status: UbiquitousPlaybackDownloadPolicy.Status
        var isDownloading: Bool
        var isDownloadRequested: Bool
        var isLegacyPlaceholder: Bool
        var downloadErrorText: String?
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fraction: Double?

        var latestFraction: Double? { lock.withLock { fraction } }

        func update(_ value: Double?) {
            guard let value else { return }
            lock.withLock { fraction = value }
        }
    }

    /// 旧式 iCloud 占位路径:同目录下的 `.名字.icloud`。
    nonisolated static func evictedPlaceholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// 旧式 iCloud 占位:原文件不在,同目录下有 `.名字.icloud`。
    nonisolated static func isEvictedPlaceholder(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return FileManager.default.fileExists(atPath: evictedPlaceholderURL(for: url).path)
    }

    /// 判断文件或目录是否由 iCloud 云盘 / File Provider 托管(可能被系统驱逐到云端)。
    /// 读文件提供方的属性可能要等,同 `needsDownload` 不在调用方的 actor 上读。
    @concurrent
    nonisolated static func isCloudBacked(_ url: URL) async -> Bool {
        guard url.isFileURL else { return false }
        if LocalCloudStoragePathPolicy.isCloudBackedPath(url.path) || isEvictedPlaceholder(url) {
            return true
        }
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// 这个文件要不要先从 iCloud 下载。普通本地文件、读不到状态时都是 false。
    @concurrent
    nonisolated static func needsDownload(_ url: URL) async -> Bool {
        guard url.isFileURL else { return false }
        return UbiquitousPlaybackDownloadPolicy.needsDownload(snapshot(of: url).status)
    }

    /// 后台按需向系统发起 iCloud 下载请求；已在下载或本机已就位时返回 false。
    @concurrent
    nonisolated static func requestDownloadIfNeeded(_ url: URL) async throws -> Bool {
        guard url.isFileURL else { return false }
        let snap = snapshot(of: url)
        guard UbiquitousPlaybackDownloadPolicy.needsDownload(snap.status), !snap.isDownloading else {
            return false
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        return true
    }

    /// 读这个文件要不要走网络:还没下到本机的 iCloud 云盘文件,或者放在网络卷上(Mac 上
    /// 挂载的 SMB 之类)。后台补资料在不能联网时先问这里。读不到属性时按本机文件算。
    @concurrent
    nonisolated static func readingNeedsNetwork(_ url: URL) async -> Bool {
        guard url.isFileURL else { return false }
        if UbiquitousPlaybackDownloadPolicy.needsDownload(snapshot(of: url).status) { return true }
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal == false
    }

    /// 请求下载并等到文件可读。`isCurrent` 为 false(已经换了别的歌)时以取消结束。
    @concurrent
    nonisolated static func download(
        _ url: URL,
        isOffline: @escaping @Sendable () async -> Bool,
        isCurrent: @escaping @Sendable () async -> Bool,
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        let initial = snapshot(of: url)
        guard UbiquitousPlaybackDownloadPolicy.needsDownload(initial.status) else { return }
        var didRequestStart = initial.isDownloading || initial.isDownloadRequested
        var coordinatedRead: CoordinatedRead?
        if !initial.isDownloading {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                didRequestStart = true
            } catch {
                plog("☁️ iCloud download request failed for '\(url.lastPathComponent)': \(error.localizedDescription)")
                if LocalCloudStoragePathPolicy.isCloudBackedPath(url.path) {
                    coordinatedRead = CoordinatedRead.start(url)
                }
            }
        }
        defer { coordinatedRead?.cancel() }

        let progressBox = ProgressBox()
        let observer = onProgress != nil ? await startProgressObserver(for: url, box: progressBox) : nil
        defer {
            if let observer {
                Task { @MainActor in observer.stop() }
            }
        }

        var monitor = UbiquitousPlaybackDownloadPolicy.Monitor(
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        var lastReportedProgress: Double?
        while true {
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
            let current = snapshot(of: url)
            let fraction = progressBox.latestFraction
            if fraction != lastReportedProgress {
                lastReportedProgress = fraction
                onProgress?(fraction)
            }
            let effectiveRequested = current.isDownloadRequested
                || (current.isLegacyPlaceholder && didRequestStart)
                || coordinatedRead != nil
            let verdict = monitor.observe(
                status: current.status,
                isDownloading: current.isDownloading,
                isDownloadRequested: effectiveRequested,
                hasDownloadError: current.downloadErrorText != nil,
                isOffline: await isOffline(),
                at: ProcessInfo.processInfo.systemUptime
            )
            switch verdict {
            case .ready:
                return
            case .waiting:
                try await Task.sleep(for: UbiquitousPlaybackDownloadPolicy.pollInterval)
            case .failed(let failure):
                throw DownloadError(failure: failure, underlyingDescription: current.downloadErrorText)
            }
        }
    }

    /// 系统不受理下载请求时的退路:协调读一次也会让文件提供方去取。协调读一直阻塞到文件到手,
    /// 所以放在自己的队列上(不占 Swift 并发的线程);`download` 退出(下好、超时、取消)时 `cancel()`,
    /// 阻塞着的那次协调读马上返回,重试不会一次次多占一条线程。
    private final class CoordinatedRead: @unchecked Sendable {
        private static let queue = DispatchQueue(
            label: "primuse.ubiquitous-coordinated-read", qos: .userInitiated, attributes: .concurrent
        )
        private let coordinator = NSFileCoordinator(filePresenter: nil)

        static func start(_ url: URL) -> CoordinatedRead {
            let read = CoordinatedRead()
            queue.async { read.run(url) }
            return read
        }

        private func run(_ url: URL) {
            var error: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in }
        }

        func cancel() { coordinator.cancel() }
    }

    @MainActor
    private final class MetadataProgressObserver {
        private let query: NSMetadataQuery
        private let box: ProgressBox
        private var tokens: [NSObjectProtocol] = []

        init(url: URL, box: ProgressBox) {
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope, url]
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemURLKey, url as NSURL)
            self.query = query
            self.box = box
            let center = NotificationCenter.default
            let handler: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.readProgress() }
            }
            tokens = [
                center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main, using: handler),
                center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main, using: handler),
            ]
            query.start()
        }

        private func readProgress() {
            query.disableUpdates()
            defer { query.enableUpdates() }
            for case let item as NSMetadataItem in query.results {
                if let pct = (item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber)?.doubleValue,
                   let fraction = UbiquitousPlaybackDownloadPolicy.normalizedProgressFraction(percent: pct) {
                    box.update(fraction)
                    break
                }
            }
        }

        func stop() {
            query.stop()
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens.removeAll()
        }
    }

    @MainActor
    private static func startProgressObserver(for url: URL, box: ProgressBox) -> MetadataProgressObserver {
        MetadataProgressObserver(url: url, box: box)
    }

    /// 只在后台用:读的是文件提供方的状态,每次新建 URL,不吃上一次缓存的属性值。
    nonisolated static func snapshot(of url: URL) -> Snapshot {
        let fresh = URL(fileURLWithPath: url.path)
        // 下载进度不从这里读(对应的属性键早已废弃),由 `MetadataProgressObserver` 从 NSMetadataQuery 取。
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadRequestedKey,
            .ubiquitousItemDownloadingErrorKey,
        ]
        if let values = try? fresh.resourceValues(forKeys: keys), values.isUbiquitousItem == true {
            let status: UbiquitousPlaybackDownloadPolicy.Status
            switch values.ubiquitousItemDownloadingStatus {
            case .some(.current): status = .current
            case .some(.downloaded): status = .downloaded
            case .some(.notDownloaded): status = .notDownloaded
            default: status = .notUbiquitous
            }
            return Snapshot(
                status: status,
                isDownloading: values.ubiquitousItemIsDownloading == true,
                isDownloadRequested: values.ubiquitousItemDownloadRequested == true,
                isLegacyPlaceholder: false,
                downloadErrorText: values.ubiquitousItemDownloadingError?.localizedDescription
            )
        }
        // 旧式 `.文件名.icloud` 占位:原文件尚不存在,从占位文件本身读下载与错误状态。
        let placeholder = evictedPlaceholderURL(for: fresh)
        guard !FileManager.default.fileExists(atPath: fresh.path),
              FileManager.default.fileExists(atPath: placeholder.path) else {
            return Snapshot(
                status: .notUbiquitous, isDownloading: false, isDownloadRequested: false,
                isLegacyPlaceholder: false, downloadErrorText: nil
            )
        }
        let values = try? placeholder.resourceValues(forKeys: keys)
        return Snapshot(
            status: .notDownloaded,
            isDownloading: values?.ubiquitousItemIsDownloading == true,
            isDownloadRequested: values?.ubiquitousItemDownloadRequested == true,
            isLegacyPlaceholder: true,
            downloadErrorText: values?.ubiquitousItemDownloadingError?.localizedDescription
        )
    }
}
