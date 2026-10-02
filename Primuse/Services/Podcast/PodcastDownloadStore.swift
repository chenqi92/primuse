import Foundation
import PrimuseKit

/// 下载到本机的单集。和曲库的离线缓存是两套:那套按音乐源分目录、受源的缓存配额管,
/// 单集不属于任何音乐源,所以单独放 `Application Support/Primuse/Podcasts/Downloads`,
/// 不进 iCloud 备份。播放时有本机文件就直接放本机文件。
@MainActor
@Observable
final class PodcastDownloadStore {
    static let shared = PodcastDownloadStore()

    enum State: Equatable, Sendable {
        case queued
        case downloading(Double)
        case failed(String)
    }

    struct Record: Codable, Equatable, Sendable {
        var episodeID: String
        var showID: String
        var fileName: String
        var bytes: Int64
        var downloadedAt: Date
    }

    /// 下载中/排队/失败的;下载好的在 `records` 里。
    private(set) var states: [String: State] = [:]
    private(set) var records: [String: Record] = [:]

    @ObservationIgnored private var queue: [(episode: PodcastEpisode, showID: String)] = []
    @ObservationIgnored private var tasks: [Int: (task: URLSessionDownloadTask, episodeID: String, showID: String, ext: String)] = [:]
    @ObservationIgnored private var lastProgressPublish: [String: Date] = [:]
    /// 已经开始(含还在解析地址)的下载。并发上限按它算,`tasks` 要等地址解析完才有。
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private let session: URLSession

    private static let maximumConcurrent = 2
    static let wifiOnlyKey = "primuse.podcast.autoDownloadWiFiOnly"
    static let deletePlayedKey = "primuse.podcast.deletePlayedDownloads"

    let directory: URL
    private let indexURL: URL

    private init() {
        #if os(tvOS)
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        directory = base.appendingPathComponent("Primuse/Podcasts/Downloads", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        config.httpAdditionalHeaders = ["User-Agent": PodcastNetwork.userAgent]
        let delegate = PodcastDownloadSessionDelegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.store = self
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            // 文件被系统清掉的记录不算下载过。
            records = decoded.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path) }
        }
    }

    // MARK: - Reading

    func isDownloaded(_ episodeID: String) -> Bool { records[episodeID] != nil }

    func localURL(for episodeID: String) -> URL? {
        guard let record = records[episodeID] else { return nil }
        let url = directory.appendingPathComponent(record.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    func bytes(forShowID showID: String) -> Int64 {
        records.values.filter { $0.showID == showID }.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Writing

    func download(_ episode: PodcastEpisode) {
        guard records[episode.id] == nil else { return }
        if case .downloading = states[episode.id] { return }
        if states[episode.id] == .queued { return }
        states[episode.id] = .queued
        queue.append((episode, episode.showID))
        pump()
    }

    func cancel(_ episodeID: String) {
        queue.removeAll { $0.episode.id == episodeID }
        for (identifier, entry) in tasks where entry.episodeID == episodeID {
            entry.task.cancel()
            tasks.removeValue(forKey: identifier)
        }
        states.removeValue(forKey: episodeID)
        active.remove(episodeID)
        pump()
    }

    func delete(_ episodeID: String) {
        cancel(episodeID)
        guard let record = records.removeValue(forKey: episodeID) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.fileName))
        persist()
    }

    func deleteAll(showID: String? = nil) {
        let targets = records.values.filter { showID == nil || $0.showID == showID }.map(\.episodeID)
        for id in targets { delete(id) }
        if let showID {
            for item in queue where item.showID == showID { cancel(item.episode.id) }
        } else {
            for item in queue { cancel(item.episode.id) }
        }
    }

    /// 听完的单集删掉下载(设置里默认打开)。
    func deletePlayedDownloads(isFinished: (String) -> Bool) {
        guard UserDefaults.standard.object(forKey: Self.deletePlayedKey) as? Bool ?? true else { return }
        let played = records.keys.filter(isFinished)
        guard !played.isEmpty else { return }
        for id in played { delete(id) }
        plog("🎙️ Removed \(played.count) played podcast downloads")
    }

    /// 刷新到新单集时的自动下载。只用 Wi-Fi 的设置开着时,蜂窝网络下先不下。
    /// Apple TV 只在线听:存储随时会被系统清掉,自动下载的设置是从手机同步过来的,这里不照做。
    func autoDownload(_ episodes: [PodcastEpisode]) {
        #if os(tvOS)
        return
        #else
        guard !episodes.isEmpty else { return }
        let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true
        if wifiOnly, NetworkMonitor.shared.isExpensive || NetworkMonitor.shared.isConstrained { return }
        for episode in episodes.prefix(10) { download(episode) }
        #endif
    }

    private func pump() {
        while active.count < Self.maximumConcurrent, !queue.isEmpty {
            let next = queue.removeFirst()
            start(next.episode)
        }
    }

    private func start(_ episode: PodcastEpisode) {
        let episodeID = episode.id
        states[episodeID] = .downloading(0)
        active.insert(episodeID)
        Task { @MainActor in
            do {
                let url = try await PodcastNetwork.reachableURL(for: episode.enclosureURL)
                guard states[episodeID] != nil else { return }
                if TrustedHTTPTransport.requiresPlainSocket(for: url) {
                    // 用户放行过的明文主机走 App 自己的明文通道,没有进度,下完一次落盘。
                    try await downloadOverPlainHTTP(url, episode: episode)
                    return
                }
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.downloadTask(with: request)
                tasks[task.taskIdentifier] = (task, episodeID, episode.showID, episode.audioFileExtension)
                task.resume()
            } catch {
                fail(episodeID, error.localizedDescription)
            }
        }
    }

    private func downloadOverPlainHTTP(_ url: URL, episode: PodcastEpisode) async throws {
        let (temporary, response) = try await TrustedHTTPTransport.download(from: url, session: session, timeout: 600)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw PodcastNetwork.Failure.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        finish(episodeID: episode.id, showID: episode.showID, ext: episode.audioFileExtension, temporaryURL: temporary)
        pump()
    }

    private func fail(_ episodeID: String, _ message: String) {
        active.remove(episodeID)
        states[episodeID] = .failed(message)
        plog("🎙️ Podcast download failed id=\(episodeID.suffix(8)): \(message)")
        pump()
    }

    fileprivate func finish(episodeID: String, showID: String, ext: String, temporaryURL: URL) {
        let fileName = PodcastIdentity.digest(episodeID) + "." + ext
        let destination = directory.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            records[episodeID] = Record(episodeID: episodeID, showID: showID, fileName: fileName, bytes: bytes, downloadedAt: Date())
            states.removeValue(forKey: episodeID)
            active.remove(episodeID)
            persist()
            plog("🎙️ Podcast downloaded id=\(episodeID.suffix(8)) \(bytes / 1024)KB")
        } catch {
            fail(episodeID, error.localizedDescription)
        }
    }

    fileprivate func progress(taskID: Int, fraction: Double) {
        guard let entry = tasks[taskID] else { return }
        // 进度一秒最多发布几次,列表里几十行跟着动就够了。
        let now = Date()
        if let last = lastProgressPublish[entry.episodeID], now.timeIntervalSince(last) < 0.3, fraction < 1 { return }
        lastProgressPublish[entry.episodeID] = now
        states[entry.episodeID] = .downloading(fraction)
    }

    fileprivate func completed(taskID: Int, temporaryURL: URL?, statusCode: Int?, error: Error?) {
        guard let entry = tasks.removeValue(forKey: taskID) else { return }
        lastProgressPublish.removeValue(forKey: entry.episodeID)
        if let error {
            if (error as? URLError)?.code == .cancelled {
                active.remove(entry.episodeID)
                return
            }
            fail(entry.episodeID, error.localizedDescription)
            return
        }
        guard let temporaryURL, let statusCode, (200...299).contains(statusCode) else {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            fail(entry.episodeID, PodcastNetwork.Failure.httpStatus(statusCode ?? 0).localizedDescription)
            return
        }
        finish(episodeID: entry.episodeID, showID: entry.showID, ext: entry.ext, temporaryURL: temporaryURL)
        pump()
    }

    private func persist() {
        let snapshot = records
        let url = indexURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 下载会话的回调转回主线程上的下载账。单独一个对象,下载账本身不用继承 NSObject。
private final class PodcastDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// 只在初始化时写一次。
    weak var store: PodcastDownloadStore?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let taskID = downloadTask.taskIdentifier
        let store = self.store
        Task { @MainActor in store?.progress(taskID: taskID, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 系统在这个回调返回后就删掉临时文件,先挪到自己的临时位置。
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcast-\(UUID().uuidString)")
        let moved = (try? FileManager.default.moveItem(at: location, to: staged)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let taskID = downloadTask.taskIdentifier
        let store = self.store
        Task { @MainActor in
            store?.completed(taskID: taskID, temporaryURL: moved ? staged : nil, statusCode: status, error: moved ? nil : URLError(.cannotMoveFile))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        let store = self.store
        Task { @MainActor in store?.completed(taskID: taskID, temporaryURL: nil, statusCode: nil, error: error) }
    }
}
