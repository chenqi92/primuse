import Foundation
import Observation
import PrimuseKit

extension Notification.Name {
    /// 歌曲或专辑的视频动态封面设了、换了或移除了。
    static let primuseMotionCoverDidChange = Notification.Name("primuseMotionCoverDidChange")
    /// 用户在这台设备上设、换、移除了动态封面，要传到 iCloud（#428）。userInfo：
    /// `bindings`（设置记录 ID）、`uploads`（要传的视频哈希）、`deletedVideos`（没有设置再用、云端可删的视频哈希）。
    /// 别的设备传来的变化不发这条。
    static let primuseMotionCoverSyncChanges = Notification.Name("primuseMotionCoverSyncChanges")
}

/// 用户给歌曲、专辑指定的视频动态封面（#411）。
///
/// 视频按内容哈希存在 App 自己的持久目录里，不写进音乐文件。默认只在这台设备上；
/// 打开「iCloud 同步动态封面」后视频和「谁 → 哪段视频」经 iCloud 同步（#428，见 `CloudKitSyncService`）。
/// 索引只记「谁 → 哪段视频」，单曲自己设的优先，没有时跟随所在专辑。删歌、删专辑、删音乐源时
/// 跟着把设置清掉（只清本机，不当成用户移除传出去），没人再用的视频随后删除。
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
        let previous = index.asset(for: owner)?.contentID
        index.set(asset, for: owner)
        commit()
        postSyncChanges(owners: [owner], uploads: [asset.contentID], replaced: previous.map { [$0] } ?? [])
    }

    func removeAsset(for owner: MotionCoverOwner) {
        guard let previous = index.asset(for: owner)?.contentID else { return }
        index.set(nil, for: owner)
        commit()
        postSyncChanges(owners: [owner], uploads: [], replaced: [previous])
    }

    /// 存储管理页「全部移除」：用户要的是马上腾出空间，不等宽限期，删完再返回好让页面刷新占用。
    /// 开着 iCloud 同步时也是用户移除：每个设置留墓碑传出去，别的设备跟着移除，云端视频删掉。
    func removeAll() async {
        if !index.isEmpty {
            let owners = index.syncOwners.filter { index.asset(for: $0) != nil }
            let previous = index.removeAll()
            revision &+= 1
            persistIndex()
            NotificationCenter.default.post(name: .primuseMotionCoverDidChange, object: nil)
            postSyncChanges(owners: owners, uploads: [], replaced: Array(previous))
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
            self?.removeBindings(ofOrphanedAlbumsAmong: candidateAlbums)
        }
    }

    private func removeBindings(ofOrphanedAlbumsAmong candidateAlbums: Set<String>) {
        // 曲库没装好时整库数组是空的,每张专辑看起来都没歌了:这时不判,等装好再看。
        guard AppServices.shared.musicLibrary.isReady else {
            AppServices.shared.musicLibrary.onReady { [weak self] in
                self?.removeBindings(ofOrphanedAlbumsAmong: candidateAlbums)
            }
            return
        }
        let songs = AppServices.shared.musicLibrary.songs
        let orphanedAlbums = candidateAlbums.filter { albumID in
            !songs.contains { $0.albumID == albumID }
        }
        guard !orphanedAlbums.isEmpty, index.remove(songIDs: [], albumIDs: orphanedAlbums) else { return }
        commit()
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

    // MARK: - iCloud 同步（#428）

    /// 总开关和「iCloud 同步动态封面」都开着。
    nonisolated static var isCloudSyncEnabled: Bool {
        CloudSyncChannel.isMasterEnabled() && MotionCoverSyncPreferences.isEnabled()
    }

    /// 视频记录已经在云端的（自己传成功的、从云端收到的）。打开同步时补传只补不在这里的，
    /// 免得每次都把视频整段重传。
    nonisolated private static let cloudVideoIDsKey = "primuse.motionCover.cloudVideoIDs"

    private func postSyncChanges(owners: [MotionCoverOwner], uploads: [String], replaced: [String]) {
        let referenced = index.referencedContentIDs
        let deleted = Set(replaced).subtracting(referenced).subtracting(uploads)
        NotificationCenter.default.post(name: .primuseMotionCoverSyncChanges, object: nil, userInfo: [
            "bindings": owners.map(MotionCoverCloudRecordID.binding(for:)),
            "uploads": uploads.filter { !isVideoInCloud($0) },
            "deletedVideos": Array(deleted),
        ])
    }

    /// 所有要同步的设置（含墓碑）。歌曲那几条由调用方再按音乐源筛。
    var syncOwners: [MotionCoverOwner] { index.syncOwners }

    func syncEntry(for owner: MotionCoverOwner) -> MotionCoverSyncEntry? {
        index.syncEntry(for: owner)
    }

    /// 由记录 ID 找回归属。ID 里的歌曲/专辑 id 可能是哈希，只能对着本机的设置逐个算。
    func owner(forBindingID id: String) -> MotionCoverOwner? {
        index.syncOwners.first { MotionCoverCloudRecordID.binding(for: $0) == id }
    }

    /// 还要补传到云端的视频：有设置在用、本机文件在、大小在上限内、云端还没有。
    func videosNeedingUpload(usedBy owners: [MotionCoverOwner]) -> [String] {
        let used = Set(owners.compactMap { index.asset(for: $0)?.contentID })
        return used.filter { !isVideoInCloud($0) && uploadableVideoURL(contentID: $0) != nil }.sorted()
    }

    /// 上传用的本机文件。按内容哈希命名，上传期间不会被改写；没有设置在用的不传。
    func uploadableVideoURL(contentID: String) -> URL? {
        guard MotionCoverAsset.isValidContentID(contentID),
              index.referencedContentIDs.contains(contentID) else { return nil }
        let url = Self.videoURL(contentID: contentID)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return MotionCoverSyncVideoPolicy.isUploadable(fileSize: size) ? url : nil
    }

    func asset(forContentID contentID: String) -> MotionCoverAsset? {
        index.songs.values.first { $0.contentID == contentID }
            ?? index.albums.values.first { $0.contentID == contentID }
    }

    func isVideoInCloud(_ contentID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.cloudVideoIDsKey) ?? []).contains(contentID)
    }

    func markVideoInCloud(_ contentID: String, _ present: Bool) {
        guard MotionCoverAsset.isValidContentID(contentID) else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.cloudVideoIDsKey) ?? [])
        let changed = present ? ids.insert(contentID).inserted : ids.remove(contentID) != nil
        guard changed else { return }
        UserDefaults.standard.set(ids.sorted(), forKey: Self.cloudVideoIDsKey)
    }

    func forgetCloudVideos() {
        UserDefaults.standard.removeObject(forKey: Self.cloudVideoIDsKey)
    }

    /// 并入别的设备传来的设置。返回 `.localNewer` 时调用方把本机这条传回去。
    func applyRemoteSyncEntry(_ entry: MotionCoverSyncEntry) -> MotionCoverRemoteApplyResult {
        let result = index.applyRemote(entry)
        if case .applied = result {
            // 不发 `primuseMotionCoverSyncChanges`：这是别处的改动，不用再传回去；
            // 被换下的视频云端由改动的那台设备删。
            commit()
        }
        return result
    }

    /// 有设置在用、本机却还没有文件的视频（别的设备设的，视频还没下载下来）。
    func videosMissingLocally() -> [String] {
        let fileManager = FileManager.default
        return index.referencedContentIDs.filter { contentID in
            MotionCoverAsset.isValidContentID(contentID)
                && !fileManager.fileExists(atPath: Self.videoURL(contentID: contentID).path)
        }.sorted()
    }

    /// 收到别的设备传来的视频。CloudKit 给的临时文件在这次回调之后就会被收走，所以先在
    /// 主线程上硬链接（同一个卷上不复制数据）到暂存目录，校验哈希、截首帧都在后台做。
    func installRemoteVideo(contentID: String, from fileURL: URL) {
        guard MotionCoverAsset.isValidContentID(contentID) else { return }
        markVideoInCloud(contentID, true)
        let destination = Self.videoURL(contentID: contentID)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { return }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard MotionCoverSyncVideoPolicy.isUploadable(fileSize: size) else {
            plog("⚠️ MotionCover sync: skipped remote video \(contentID.prefix(8)) size=\(size)")
            return
        }
        let staged: URL
        do {
            try fileManager.createDirectory(at: Self.stagingDirectoryURL, withIntermediateDirectories: true)
            staged = Self.stagingDirectoryURL.appendingPathComponent("remote-\(UUID().uuidString).mp4")
            do {
                try fileManager.linkItem(at: fileURL, to: staged)
            } catch {
                try fileManager.copyItem(at: fileURL, to: staged)
            }
        } catch {
            plog("⚠️ MotionCover sync: staging remote video failed: \(error.localizedDescription)")
            return
        }
        Task.detached(priority: .utility) {
            let installed = await Self.finishRemoteVideoInstall(staged: staged, contentID: contentID)
            guard installed else { return }
            await MainActor.run {
                // 视频比设置先到时，设置随后到；已经有设置在等这段视频的，现在就能显示了。
                MotionCoverStore.shared.revision &+= 1
                NotificationCenter.default.post(name: .primuseMotionCoverDidChange, object: nil)
            }
        }
    }

    nonisolated private static func finishRemoteVideoInstall(staged: URL, contentID: String) async -> Bool {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: staged) }
        guard let hash = try? MotionCoverImporter.sha256Hex(ofFileAt: staged), hash == contentID else {
            plog("⚠️ MotionCover sync: remote video \(contentID.prefix(8)) failed the content check")
            return false
        }
        let destination = videoURL(contentID: contentID)
        if !fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.moveItem(at: staged, to: destination)
            } catch {
                plog("⚠️ MotionCover sync: installing remote video failed: \(error.localizedDescription)")
                return false
            }
        }
        // 硬链接带着 CloudKit 临时文件的修改时间；改成现在，清理才会给它宽限期等设置到来。
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        let poster = posterURL(contentID: contentID)
        if !fileManager.fileExists(atPath: poster.path),
           let data = await MotionCoverImporter.posterJPEG(forVideoAt: destination) {
            try? data.write(to: poster, options: .atomic)
        }
        return true
    }

    nonisolated private static func videoURL(contentID: String) -> URL {
        directoryURL.appendingPathComponent("\(contentID).mp4")
    }

    nonisolated private static func posterURL(contentID: String) -> URL {
        directoryURL.appendingPathComponent("\(contentID).jpg")
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
