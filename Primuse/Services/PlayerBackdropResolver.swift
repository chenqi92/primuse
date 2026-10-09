import CoreGraphics
import Foundation
import Observation
import PrimuseKit

/// 播放页背景图从哪来、现在该显示哪一张。iPhone / iPad 与 Mac 的原生播放页共用一份：
/// 轮播计数、内存里解好的位图、各专辑文件夹的封底清单都留在这里，关掉播放页再打开
/// 不用重来。
///
/// 所有读盘、取图、缩放、模糊都在后台做；新图准备好才换上，在那之前保留上一张
/// （或露出底下的封面取色）。
@MainActor
@Observable
final class PlayerBackdropResolver {
    static let shared = PlayerBackdropResolver()

    struct Frame: Identifiable {
        let id: String
        let source: PlayerBackdropSource
        let image: CGImage
    }

    struct Request: Equatable {
        var source: PlayerBackdropSource
        var rotation: PlayerBackdropRotation
        /// 轮播计数（`rotation.step`），变了就换下一张。
        var step: Int
        var song: Song?
        var customImageIDs: [String]
        var maxPixel: Int
        /// 播放页入场动画结束前不开始读盘解码；内存里已经有的照样立刻换上。
        var allowsLoading: Bool

        static func == (lhs: Request, rhs: Request) -> Bool {
            lhs.source == rhs.source && lhs.rotation == rhs.rotation && lhs.step == rhs.step
                && lhs.song?.id == rhs.song?.id
                && lhs.song?.coverArtFileName == rhs.song?.coverArtFileName
                && lhs.song?.filePath == rhs.song?.filePath
                && lhs.customImageIDs == rhs.customImageIDs
                && lhs.maxPixel == rhs.maxPixel && lhs.allowsLoading == rhs.allowsLoading
        }
    }

    private(set) var frame: Frame?
    /// 新图淡入时垫在下面的上一张，换图时不会先闪出底色。
    private(set) var previousFrame: Frame?
    private(set) var rotation = PlayerBackdropRotationState()

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadingKey: String?
    /// 准备失败的图（取不到、解不开）一分钟内不再重试。
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

    /// 封底图原图上限：扫描件常常十几 MB，再大就不取了。
    private nonisolated static let maximumAlbumBackBytes: Int64 = 40 * 1024 * 1024

    var isShowingImage: Bool { frame != nil }

    // MARK: - Rotation

    func observeSong(_ songID: String?, rotation mode: PlayerBackdropRotation) {
        _ = rotation.observeSong(songID, rotation: mode)
    }

    func advanceTimer(rotation mode: PlayerBackdropRotation) {
        _ = rotation.timerFired(rotation: mode)
    }

    // MARK: - Resolution

    func update(_ request: Request, sourceManager: SourceManager, sourcesStore: SourcesStore) {
        // 换了来源就不再拿上一种来源的图垫着。
        if let frame, frame.source != request.source {
            previousFrame = nil
            self.frame = nil
        }
        guard request.source.showsImage else {
            cancelLoading()
            setFrame(nil)
            return
        }
        switch request.source {
        case .coverAmbient, .liquid:
            break
        case .customImages:
            guard let index = rotation.index(count: request.customImageIDs.count, rotation: request.rotation) else {
                cancelLoading()
                setFrame(nil)
                return
            }
            let id = request.customImageIDs[index]
            let maxPixel = request.maxPixel
            let key = "custom|\(id)|\(maxPixel)"
            show(key: key, source: .customImages, allowsLoading: request.allowsLoading) {
                guard let url = PlayerBackdropImageStore.fileURL(id: id) else { return nil }
                return PlayerBackdropImaging.decodedImage(url: url, maxPixel: maxPixel)
            }
        case .coverBlur:
            guard let song = request.song else {
                cancelLoading()
                setFrame(nil)
                return
            }
            let key = "blur|\(song.id)|\(song.coverArtFileName ?? "")"
            show(key: key, source: .coverBlur, allowsLoading: request.allowsLoading) {
                let cover = await CachedArtworkView.resolveImage(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: CGFloat(PlayerBackdropPixelPolicy.blurSourcePixel),
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    sourceManager: sourceManager
                )
                guard !Task.isCancelled, let image = cover?.platformCGImage else { return nil }
                return PlayerBackdropImaging.blurredBackdrop(from: image)
            }
        case .albumBack:
            guard let song = request.song else {
                cancelLoading()
                setFrame(nil)
                return
            }
            let listingKey = "back-list|\(song.sourceID)|\(song.id)"
            if let files = albumBackListings[Self.directoryKey(for: song)] {
                showAlbumBack(files: files, song: song, request: request, sourceManager: sourceManager)
                return
            }
            guard request.allowsLoading else { return }
            guard loadingKey != listingKey else { return }
            cancelLoading()
            loadingKey = listingKey
            loadTask = Task { [weak self] in
                let files = await self?.albumBackFiles(
                    for: song,
                    sourceManager: sourceManager,
                    sourcesStore: sourcesStore
                )
                guard let self, !Task.isCancelled, self.loadingKey == listingKey else { return }
                self.loadingKey = nil
                // 列目录失败（离线、源连不上）不记下，下一首再试；真的没有封底才记成空。
                if let files { self.albumBackListings[Self.directoryKey(for: song)] = files }
                self.showAlbumBack(files: files ?? [], song: song, request: request, sourceManager: sourceManager)
            }
        }
    }

    private func showAlbumBack(
        files: [AlbumBackFile],
        song: Song,
        request: Request,
        sourceManager: SourceManager
    ) {
        guard let index = rotation.index(count: files.count, rotation: request.rotation) else {
            cancelLoading()
            setFrame(nil)
            return
        }
        let file = files[index]
        let sourceID = song.sourceID
        let maxPixel = request.maxPixel
        let key = "back|\(sourceID)|\(file.cacheKey)|\(maxPixel)"
        show(key: key, source: .albumBack, allowsLoading: request.allowsLoading) {
            let diskKey = "\(sourceID)|\(file.cacheKey)|\(maxPixel)"
            let cachedURL = PlayerBackdropAlbumBackCache.fileURL(forKey: diskKey)
            if let cached = PlayerBackdropImaging.decodedImage(url: cachedURL, maxPixel: maxPixel) {
                return cached
            }
            let limit = file.size > 0 ? min(file.size, Self.maximumAlbumBackBytes) : Self.maximumAlbumBackBytes
            guard file.size <= Self.maximumAlbumBackBytes,
                  let data = await sourceManager.artworkData(
                    for: file.path,
                    sourceID: sourceID,
                    maximumBytes: Int(limit),
                    purpose: .originalAnimation
                  ),
                  !Task.isCancelled else { return nil }
            return await Task.detached(priority: .utility) { () -> CGImage? in
                guard let jpeg = PlayerBackdropImaging.downscaledJPEG(from: data, maxPixel: maxPixel) else {
                    return nil
                }
                PlayerBackdropAlbumBackCache.store(jpeg, forKey: diskKey)
                return PlayerBackdropImaging.decodedImage(data: jpeg, maxPixel: maxPixel)
            }.value
        }
    }

    /// 内存命中立刻换上；否则（允许的话）后台准备，好了再换。准备失败就退回底色。
    private func show(
        key: String,
        source: PlayerBackdropSource,
        allowsLoading: Bool,
        load: @escaping @Sendable () async -> CGImage?
    ) {
        if frame?.id == key {
            if loadingKey != nil, loadingKey != key { cancelLoading() }
            return
        }
        if let cached = PlayerBackdropMemoryCache.shared.image(forKey: key) {
            cancelLoading()
            setFrame(Frame(id: key, source: source, image: cached))
            return
        }
        if let failedAt = failedKeys[key] {
            guard Date().timeIntervalSince(failedAt) > 60 else {
                cancelLoading()
                setFrame(nil)
                return
            }
            failedKeys[key] = nil
        }
        guard allowsLoading, loadingKey != key else { return }
        cancelLoading()
        loadingKey = key
        loadTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { await load() }.value
            guard let self, !Task.isCancelled, self.loadingKey == key else { return }
            self.loadingKey = nil
            if let image {
                PlayerBackdropMemoryCache.shared.insert(image, forKey: key)
                self.setFrame(Frame(id: key, source: source, image: image))
            } else {
                self.failedKeys[key] = Date()
                self.setFrame(nil)
            }
        }
    }

    private func setFrame(_ next: Frame?) {
        guard next?.id != frame?.id else { return }
        previousFrame = next == nil ? nil : frame
        frame = next
    }

    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadingKey = nil
    }

    // MARK: - Album back lookup

    private static func directoryKey(for song: Song) -> String {
        "\(song.sourceID)|\((song.filePath as NSString).deletingLastPathComponent)"
    }

    /// 列歌所在文件夹（分碟子文件夹再看上一层）找封底。只有按目录组织的音乐源才有；
    /// 曲库型服务器、Apple Music 等没有文件夹，直接返回空。
    private func albumBackFiles(
        for song: Song,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) async -> [AlbumBackFile]? {
        guard let source = sourcesStore.source(id: song.sourceID),
              source.isEnabled, !source.isDeleted,
              source.type.supportsFolderRescan else { return [] }
        let connector = sourceManager.connector(for: source)
        do {
            try await connector.connect()
            let directories: [String]
            if source.type.usesOpaqueDirectoryIdentifiers {
                guard let resolver = connector as? any LyricsSidecarTargetResolving else { return [] }
                // Only the folder is needed here; a listing request never fails
                // on a song that has both an `.lrc` and a `.ttml`.
                directories = [try await resolver.lyricsSidecarTarget(
                    for: song,
                    request: .catalog(for: song)
                ).containerPath]
            } else {
                directories = AlbumBackArtworkPolicy.searchDirectories(
                    forSongDirectory: (song.filePath as NSString).deletingLastPathComponent
                )
            }
            for directory in directories {
                try Task.checkCancellation()
                let items = try await connector.listFiles(at: directory).filter { !$0.isDirectory }
                let order = AlbumBackArtworkPolicy.orderedCandidateIndices(names: items.map(\.name))
                guard !order.isEmpty else { continue }
                return order.map {
                    AlbumBackFile(path: items[$0].path, size: items[$0].size, modified: items[$0].modifiedDate)
                }
            }
        } catch is CancellationError {
            return nil
        } catch {
            plog("🖼 Player backdrop album back lookup failed source=\(source.type.rawValue): \(error.localizedDescription)")
            return nil
        }
        return []
    }
}
