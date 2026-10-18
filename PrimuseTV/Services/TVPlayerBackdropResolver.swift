#if os(tvOS)
import CoreGraphics
import Foundation
import Observation
import PrimuseKit

/// Apple TV 播放页背景图：模糊封面、专辑封底（电视能直接读文件的音乐源）、扫码直传带来的
/// 「我的图片」。和 iPhone 同一套设置与轮播规则；读盘、取图、缩放、模糊都在后台，新图
/// 准备好才换上。
@MainActor
@Observable
final class TVPlayerBackdropResolver {
    static let shared = TVPlayerBackdropResolver()

    struct Frame {
        let id: String
        let source: PlayerBackdropSource
        let image: CGImage
    }

    struct Request: Equatable {
        var source: PlayerBackdropSource
        var rotation: PlayerBackdropRotation
        var step: Int
        var songID: String?
        var coverRef: String?
        var customImageIDs: [String]
    }

    private(set) var frame: Frame?
    private(set) var rotation = PlayerBackdropRotationState()

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadingKey: String?
    @ObservationIgnored private var failedKeys: [String: Date] = [:]

    private nonisolated static let maxPixel = PlayerBackdropPixelPolicy.televisionPixel

    func observeSong(_ songID: String?, rotation mode: PlayerBackdropRotation) {
        // 同一首歌再报一次时原地改也会通知观察者；变了才写回（同 iOS 的 PlayerBackdropResolver）。
        var next = rotation
        _ = next.observeSong(songID, rotation: mode)
        if next != rotation { rotation = next }
    }

    func advanceTimer(rotation mode: PlayerBackdropRotation) {
        _ = rotation.timerFired(rotation: mode)
    }

    func update(_ request: Request, store: TVStore) {
        if let frame, frame.source != request.source { self.frame = nil }
        switch request.source {
        // 电视没有「流动色彩」「声音律动」的画法,和封面取色一样只留色场。
        case .coverAmbient, .liquid, .visualizer:
            cancelLoading()
            frame = nil
        case .customImages:
            guard let index = rotation.index(count: request.customImageIDs.count, rotation: request.rotation) else {
                clear()
                return
            }
            let id = request.customImageIDs[index]
            let maxPixel = Self.maxPixel
            show(key: "custom|\(id)", source: .customImages) {
                guard let url = PlayerBackdropImageStore.fileURL(id: id) else { return nil }
                return PlayerBackdropImaging.decodedImage(url: url, maxPixel: maxPixel)
            }
        case .coverBlur:
            guard let songID = request.songID else {
                clear()
                return
            }
            let coverRef = request.coverRef
            show(key: "blur|\(songID)|\(coverRef ?? "")", source: .coverBlur) { [weak store] in
                guard let data = await store?.songArtworkData(songID: songID, coverRef: coverRef),
                      !Task.isCancelled,
                      let image = PlayerBackdropImaging.decodedImage(
                        data: data, maxPixel: PlayerBackdropPixelPolicy.blurSourcePixel
                      ) else { return nil }
                return PlayerBackdropImaging.blurredBackdrop(from: image)
            }
        case .albumBack:
            guard let songID = request.songID, let song = store.library.song(id: songID) else {
                clear()
                return
            }
            if let files = TVAlbumBackArtwork.cachedFiles(for: song) {
                showAlbumBack(files: files, song: song, request: request, store: store)
                return
            }
            let listingKey = "back-list|\(TVAlbumBackArtwork.directoryKey(for: song))"
            guard loadingKey != listingKey else { return }
            cancelLoading()
            loadingKey = listingKey
            loadTask = Task { [weak self] in
                let files = await TVAlbumBackArtwork.files(for: song, store: store)
                guard let self, !Task.isCancelled, self.loadingKey == listingKey else { return }
                self.loadingKey = nil
                self.showAlbumBack(files: files ?? [], song: song, request: request, store: store)
            }
        }
    }

    private func clear() {
        cancelLoading()
        frame = nil
    }

    private func showAlbumBack(files: [TVAlbumBackArtwork.File], song: Song, request: Request, store: TVStore) {
        guard let index = rotation.index(count: files.count, rotation: request.rotation) else {
            clear()
            return
        }
        let file = files[index]
        show(
            key: TVAlbumBackArtwork.memoryKey(sourceID: song.sourceID, file: file),
            source: .albumBack,
            load: TVAlbumBackArtwork.loader(file: file, sourceID: song.sourceID, store: store)
        )
    }

    private func show(
        key: String,
        source: PlayerBackdropSource,
        load: @escaping @Sendable () async -> CGImage?
    ) {
        if frame?.id == key {
            if loadingKey != nil, loadingKey != key { cancelLoading() }
            return
        }
        if let cached = PlayerBackdropMemoryCache.shared.image(forKey: key) {
            cancelLoading()
            frame = Frame(id: key, source: source, image: cached)
            return
        }
        if let failedAt = failedKeys[key] {
            guard Date().timeIntervalSince(failedAt) > 60 else {
                clear()
                return
            }
            failedKeys[key] = nil
        }
        guard loadingKey != key else { return }
        cancelLoading()
        loadingKey = key
        loadTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { await load() }.value
            guard let self, !Task.isCancelled, self.loadingKey == key else { return }
            self.loadingKey = nil
            if let image {
                PlayerBackdropMemoryCache.shared.insert(image, forKey: key)
                self.frame = Frame(id: key, source: source, image: image)
            } else {
                self.failedKeys[key] = Date()
                self.frame = nil
            }
        }
    }

    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadingKey = nil
    }
}

/// 专辑文件夹里的封底图(back / rear / inside 开头,见 `AlbumBackArtworkPolicy`):播放页「专辑封底」
/// 背景和专辑页背景共用一套查找、读取与缓存。列过的文件夹记在内存里(真没有封底也记,列失败不记),
/// 缩好的图在磁盘缓存(`PlayerBackdropAlbumBackCache`)和内存缓存里各一份。
@MainActor
enum TVAlbumBackArtwork {
    struct File: Sendable {
        let path: String
        let size: Int64
        let modified: Date?

        var cacheKey: String {
            "\(path)|\(size)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        }
    }

    private nonisolated static let maximumBytes: Int64 = 40 * 1024 * 1024
    private nonisolated static let maxPixel = PlayerBackdropPixelPolicy.televisionPixel
    private static var listings: [String: [File]] = [:]

    static func directoryKey(for song: Song) -> String {
        "\(song.sourceID)|\((song.filePath as NSString).deletingLastPathComponent)"
    }

    /// 这首歌的文件夹列过了:封底文件(可能是空的);还没列过是 nil。
    static func cachedFiles(for song: Song) -> [File]? {
        listings[directoryKey(for: song)]
    }

    /// 内存缓存里这张图的键,也是播放页背景换图时认图的身份。
    static func memoryKey(sourceID: String, file: File) -> String {
        "back|\(sourceID)|\(file.cacheKey)"
    }

    /// 列歌所在文件夹（分碟子文件夹再看上一层）找封底。只做电视能按路径列目录、又能直接
    /// 读文件的源；列失败返回 nil（下次再试），真没有返回空。
    static func files(for song: Song, store: TVStore) async -> [File]? {
        if let cached = cachedFiles(for: song) { return cached }
        guard let source = store.sourcesStore.source(id: song.sourceID),
              source.isEnabled, !source.isDeleted,
              TVFolderRescanPolicy.supports(source.type),
              TVMetadataReaderPool.canRead(source),
              let lister = store.makeLister(for: source),
              let directory = TVFolderRescanPolicy.directory(containingFilePath: song.filePath, levelsAbove: 0)
        else { return [] }
        let key = directoryKey(for: song)
        do {
            for candidate in AlbumBackArtworkPolicy.searchDirectories(forSongDirectory: directory) {
                try Task.checkCancellation()
                let entries = try await lister.list(candidate).filter { !$0.isDir }
                let order = AlbumBackArtworkPolicy.orderedCandidateIndices(names: entries.map(\.name))
                guard !order.isEmpty else { continue }
                let files = order.map {
                    File(path: entries[$0].path, size: entries[$0].size, modified: entries[$0].modifiedDate)
                }
                listings[key] = files
                return files
            }
            listings[key] = []
            return []
        } catch {
            if !(error is CancellationError) {
                plog("🖼 TV album back lookup failed source=\(source.type.rawValue): \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// 读这张封底:先看磁盘缓存,没有再从音乐源读原图、缩好存盘。在后台跑。
    static func loader(file: File, sourceID: String, store: TVStore) -> @Sendable () async -> CGImage? {
        let maxPixel = Self.maxPixel
        let source = store.sourcesStore.source(id: sourceID)
        let bundle = store.credentialBundle
        return {
            let diskKey = "\(sourceID)|\(file.cacheKey)|\(maxPixel)"
            let cachedURL = PlayerBackdropAlbumBackCache.fileURL(forKey: diskKey)
            if let cached = PlayerBackdropImaging.decodedImage(url: cachedURL, maxPixel: maxPixel) {
                return cached
            }
            guard let source, file.size <= Self.maximumBytes else { return nil }
            // 凭据要查几次钥匙串(同步跨进程调用):缓存没命中、真要读文件时才在这里(后台)读。
            let credential = TVCredentialStore.credential(for: source, bundle: bundle)
            let pool = TVMetadataReaderPool(source: source, credential: credential)
            defer { Task { await pool.closeAll() } }
            do {
                var length = file.size
                if length <= 0 { length = try await pool.contentLength(path: file.path, size: 0) }
                guard length > 0, length <= Self.maximumBytes else { return nil }
                let data = try await pool.read(path: file.path, size: length, offset: 0, length: length)
                guard !Task.isCancelled,
                      let jpeg = PlayerBackdropImaging.downscaledJPEG(from: data, maxPixel: maxPixel) else {
                    return nil
                }
                PlayerBackdropAlbumBackCache.store(jpeg, forKey: diskKey)
                return PlayerBackdropImaging.decodedImage(data: jpeg, maxPixel: maxPixel)
            } catch {
                plog("🖼 TV album back read failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// 专辑页背景:这张专辑第一首歌所在文件夹的第一张封底,轻轻模糊过(见
    /// `PlayerBackdropImaging.softenedBackdrop`)。没有封底、源列不了目录或读失败都是 nil。
    static func softenedFirstImage(forAlbumSongID songID: String, store: TVStore) async -> (id: String, image: CGImage)? {
        guard let song = store.library.song(id: songID),
              let file = await files(for: song, store: store)?.first,
              !Task.isCancelled else { return nil }
        let key = memoryKey(sourceID: song.sourceID, file: file)
        let softKey = "soft|" + key
        if let cached = PlayerBackdropMemoryCache.shared.image(forKey: softKey) { return (softKey, cached) }
        let original = PlayerBackdropMemoryCache.shared.image(forKey: key)
        let load = loader(file: file, sourceID: song.sourceID, store: store)
        let softened = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            // `??` 的右边不能是 async,分开写。
            var image = original
            if image == nil { image = await load() }
            guard let image else { return nil }
            return PlayerBackdropImaging.softenedBackdrop(from: image)
        }.value
        guard let softened, !Task.isCancelled else { return nil }
        PlayerBackdropMemoryCache.shared.insert(softened, forKey: softKey)
        return (softKey, softened)
    }
}
#endif
