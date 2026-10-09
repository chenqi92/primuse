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
    @ObservationIgnored private var albumBackListings: [String: [AlbumBackFile]] = [:]

    private struct AlbumBackFile: Sendable {
        let path: String
        let size: Int64
        let modified: Date?

        var cacheKey: String {
            "\(path)|\(size)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        }
    }

    private nonisolated static let maximumAlbumBackBytes: Int64 = 40 * 1024 * 1024
    private nonisolated static let maxPixel = PlayerBackdropPixelPolicy.televisionPixel

    func observeSong(_ songID: String?, rotation mode: PlayerBackdropRotation) {
        _ = rotation.observeSong(songID, rotation: mode)
    }

    func advanceTimer(rotation mode: PlayerBackdropRotation) {
        _ = rotation.timerFired(rotation: mode)
    }

    func update(_ request: Request, store: TVStore) {
        if let frame, frame.source != request.source { self.frame = nil }
        switch request.source {
        // 电视没有「流动色彩」的画法,和封面取色一样只留色场。
        case .coverAmbient, .liquid:
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
            let directoryKey = "\(song.sourceID)|\((song.filePath as NSString).deletingLastPathComponent)"
            if let files = albumBackListings[directoryKey] {
                showAlbumBack(files: files, song: song, request: request, store: store)
                return
            }
            let listingKey = "back-list|\(directoryKey)"
            guard loadingKey != listingKey else { return }
            cancelLoading()
            loadingKey = listingKey
            loadTask = Task { [weak self] in
                let files = await self?.albumBackFiles(for: song, store: store)
                guard let self, !Task.isCancelled, self.loadingKey == listingKey else { return }
                self.loadingKey = nil
                if let files { self.albumBackListings[directoryKey] = files }
                self.showAlbumBack(files: files ?? [], song: song, request: request, store: store)
            }
        }
    }

    private func clear() {
        cancelLoading()
        frame = nil
    }

    private func showAlbumBack(files: [AlbumBackFile], song: Song, request: Request, store: TVStore) {
        guard let index = rotation.index(count: files.count, rotation: request.rotation) else {
            clear()
            return
        }
        let file = files[index]
        let sourceID = song.sourceID
        let maxPixel = Self.maxPixel
        let key = "back|\(sourceID)|\(file.cacheKey)"
        let source = store.sourcesStore.source(id: sourceID)
        let credential = source.flatMap { TVCredentialStore.credential(for: $0, bundle: store.credentialBundle) }
        show(key: key, source: .albumBack) {
            let diskKey = "\(sourceID)|\(file.cacheKey)|\(maxPixel)"
            let cachedURL = PlayerBackdropAlbumBackCache.fileURL(forKey: diskKey)
            if let cached = PlayerBackdropImaging.decodedImage(url: cachedURL, maxPixel: maxPixel) {
                return cached
            }
            guard let source, file.size <= Self.maximumAlbumBackBytes else { return nil }
            let pool = TVMetadataReaderPool(source: source, credential: credential)
            defer { Task { await pool.closeAll() } }
            do {
                var length = file.size
                if length <= 0 { length = try await pool.contentLength(path: file.path, size: 0) }
                guard length > 0, length <= Self.maximumAlbumBackBytes else { return nil }
                let data = try await pool.read(path: file.path, size: length, offset: 0, length: length)
                guard !Task.isCancelled,
                      let jpeg = PlayerBackdropImaging.downscaledJPEG(from: data, maxPixel: maxPixel) else {
                    return nil
                }
                PlayerBackdropAlbumBackCache.store(jpeg, forKey: diskKey)
                return PlayerBackdropImaging.decodedImage(data: jpeg, maxPixel: maxPixel)
            } catch {
                plog("🖼 TV player backdrop album back read failed: \(error.localizedDescription)")
                return nil
            }
        }
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

    /// 列歌所在文件夹（分碟子文件夹再看上一层）找封底。只做电视能按路径列目录、又能直接
    /// 读文件的源；列失败返回 nil（下次再试），真没有返回空。
    private func albumBackFiles(for song: Song, store: TVStore) async -> [AlbumBackFile]? {
        guard let source = store.sourcesStore.source(id: song.sourceID),
              source.isEnabled, !source.isDeleted,
              TVFolderRescanPolicy.supports(source.type),
              TVMetadataReaderPool.canRead(source),
              let lister = store.makeLister(for: source),
              let directory = TVFolderRescanPolicy.directory(containingFilePath: song.filePath, levelsAbove: 0)
        else { return [] }
        do {
            for candidate in AlbumBackArtworkPolicy.searchDirectories(forSongDirectory: directory) {
                try Task.checkCancellation()
                let entries = try await lister.list(candidate).filter { !$0.isDir }
                let order = AlbumBackArtworkPolicy.orderedCandidateIndices(names: entries.map(\.name))
                guard !order.isEmpty else { continue }
                return order.map {
                    AlbumBackFile(path: entries[$0].path, size: entries[$0].size, modified: entries[$0].modifiedDate)
                }
            }
            return []
        } catch {
            if !(error is CancellationError) {
                plog("🖼 TV player backdrop album back lookup failed source=\(source.type.rawValue): \(error.localizedDescription)")
            }
            return nil
        }
    }
}
#endif
