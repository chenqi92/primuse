import Foundation
import Observation
import PrimuseKit

extension Notification.Name {
    /// 歌曲或专辑的视频动态封面设了、换了或移除了。
    static let primuseMotionCoverDidChange = Notification.Name("primuseMotionCoverDidChange")
}

/// 用户给歌曲、专辑指定的视频动态封面（#411）。
///
/// 视频按内容哈希存在 App 自己的持久目录里：不写进音乐文件，也不走 iCloud（体积太大）。
/// 索引只记「谁 → 哪段视频」，单曲自己设的优先，没有时跟随所在专辑。删歌、删专辑、删音乐源时
/// 跟着把设置清掉，没人再用的视频随后删除。
@MainActor
@Observable
final class MotionCoverStore {
    static let shared = MotionCoverStore()

    /// 设置一变就加一。只有大封面位和编辑页读它，列表里的封面不订阅。
    private(set) var revision = 0
    @ObservationIgnored private var index: MotionCoverIndex
    @ObservationIgnored private var removalObserver: NSObjectProtocol?

    nonisolated static let directoryURL: URL = FileManager.default
        .primuseDirectoryURL(for: .applicationSupportDirectory)
        .appendingPathComponent("Primuse/MotionCovers", isDirectory: true)
    /// 导入中的临时文件。整个目录在启动时清掉：上次没导完的都是半成品。
    nonisolated static let stagingDirectoryURL: URL = directoryURL
        .appendingPathComponent("staging", isDirectory: true)
    nonisolated private static let indexURL: URL = directoryURL.appendingPathComponent("index.json")
    /// 刚放进目录、还没写进索引的视频不能被清理当成没人用的删掉。
    nonisolated private static let orphanGracePeriod: TimeInterval = 10 * 60

    private init() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: Self.stagingDirectoryURL)
        index = Self.loadIndex()
        removalObserver = NotificationCenter.default.addObserver(
            forName: .primuseSongsRemoved,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let songs = (note.userInfo?["songs"] as? [Song]) ?? []
            let songIDs = (note.userInfo?["songIDs"] as? Set<String>) ?? Set(songs.map(\.id))
            let albumIDs = Set(songs.compactMap(\.albumID))
            MainActor.assumeIsolated {
                self.handleSongsRemoved(songIDs: songIDs, albumIDs: albumIDs)
            }
        }
        scheduleUnreferencedFileCleanup()
    }

    // MARK: - Lookup

    func asset(for owner: MotionCoverOwner) -> MotionCoverAsset? {
        _ = revision
        return index.asset(for: owner)
    }

    /// 实际生效的那一段（单曲自己设的 > 专辑的），文件已经不在时当作没有。
    func effectiveAsset(songID: String?, albumID: String?) -> (asset: MotionCoverAsset, owner: MotionCoverOwner)? {
        _ = revision
        guard let resolved = index.effectiveAsset(songID: songID, albumID: albumID),
              FileManager.default.fileExists(atPath: Self.videoURL(for: resolved.asset).path) else { return nil }
        return resolved
    }

    func videoURL(songID: String?, albumID: String?) -> URL? {
        effectiveAsset(songID: songID, albumID: albumID).map { Self.videoURL(for: $0.asset) }
    }

    var hasAnyMotionCover: Bool {
        _ = revision
        return !index.isEmpty
    }

    nonisolated static func videoURL(for asset: MotionCoverAsset) -> URL {
        directoryURL.appendingPathComponent("\(asset.contentID).mp4")
    }

    /// 导入时从视频第一帧截的图，给锁屏预览和编辑页用。
    nonisolated static func posterURL(for asset: MotionCoverAsset) -> URL {
        directoryURL.appendingPathComponent("\(asset.contentID).jpg")
    }

    // MARK: - Mutation

    func setAsset(_ asset: MotionCoverAsset, for owner: MotionCoverOwner) {
        guard MotionCoverAsset.isValidContentID(asset.contentID) else { return }
        index.set(asset, for: owner)
        commit()
    }

    func removeAsset(for owner: MotionCoverOwner) {
        guard index.asset(for: owner) != nil else { return }
        index.set(nil, for: owner)
        commit()
    }

    /// 存储管理页「全部移除」：用户要的是马上腾出空间，不等宽限期，删完再返回好让页面刷新占用。
    func removeAll() async {
        if !index.isEmpty {
            index = MotionCoverIndex()
            revision &+= 1
            persistIndex()
            NotificationCenter.default.post(name: .primuseMotionCoverDidChange, object: nil)
        }
        await Task.detached(priority: .utility) {
            Self.removeUnreferencedFiles(keeping: [], gracePeriod: 0)
            Self.clearLockScreenCache()
        }.value
    }

    private func handleSongsRemoved(songIDs: Set<String>, albumIDs: Set<String>) {
        let removedSongBindings = Set(songIDs.filter { index.songs[$0] != nil })
        let candidateAlbums = Set(albumIDs.filter { index.albums[$0] != nil })
        if !removedSongBindings.isEmpty {
            index.remove(songIDs: removedSongBindings, albumIDs: [])
            commit()
        }
        guard !candidateAlbums.isEmpty else { return }
        // 删音乐源时资料库可能在这条通知之后才换上新的歌曲表；等下一轮再看专辑还有没有歌。
        Task { @MainActor [weak self] in
            guard let self else { return }
            let songs = AppServices.shared.musicLibrary.songs
            let orphanedAlbums = candidateAlbums.filter { albumID in
                !songs.contains { $0.albumID == albumID }
            }
            guard !orphanedAlbums.isEmpty, self.index.remove(songIDs: [], albumIDs: orphanedAlbums) else { return }
            self.commit()
        }
    }

    private func commit() {
        revision &+= 1
        persistIndex()
        // 先通知（锁屏会立刻换下不再用的视频），再去删没人用的文件。
        NotificationCenter.default.post(name: .primuseMotionCoverDidChange, object: nil)
        scheduleUnreferencedFileCleanup()
    }

    private func persistIndex() {
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            plog("⚠️ MotionCover index save failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func loadIndex() -> MotionCoverIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(MotionCoverIndex.self, from: data) else {
            return MotionCoverIndex()
        }
        return decoded
    }

    private func scheduleUnreferencedFileCleanup() {
        let referenced = index.referencedContentIDs
        Task.detached(priority: .background) {
            Self.removeUnreferencedFiles(keeping: referenced, gracePeriod: Self.orphanGracePeriod)
        }
    }

    nonisolated private static func removeUnreferencedFiles(
        keeping referenced: Set<String>,
        gracePeriod: TimeInterval
    ) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard ext == "mp4" || ext == "jpg" else { continue }
            let contentID = file.deletingPathExtension().lastPathComponent
            guard MotionCoverAsset.isValidContentID(contentID), !referenced.contains(contentID) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) >= gracePeriod else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    /// 存储管理页显示的占用：视频、首帧截图，以及锁屏给动图转出来的视频缓存。
    nonisolated static func diskUsage() async -> Int64 {
        await Task.detached(priority: .utility) {
            Self.directorySize(Self.directoryURL) + Self.directorySize(Self.lockScreenCacheDirectoryURL)
        }.value
    }

    /// 锁屏把动图转成视频后的缓存（可再生）。放在 Caches，系统空间紧张时可以回收。
    nonisolated static let lockScreenCacheDirectoryURL: URL = FileManager.default
        .primuseDirectoryURL(for: .cachesDirectory)
        .appendingPathComponent("Primuse/LockScreenMotionArtwork", isDirectory: true)

    nonisolated static func clearLockScreenCache() {
        try? FileManager.default.removeItem(at: lockScreenCacheDirectoryURL)
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}
