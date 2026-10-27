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
        /// 模糊封面找图用的歌曲与专辑信息，没有在播的歌时是 nil。
        var cover: TVPlayerCoverArtwork.Input?
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
            guard let cover = request.cover else {
                clear()
                return
            }
            show(key: cover.blurKey, source: .coverBlur) { [weak store] in
                guard let store,
                      let data = await TVPlayerCoverArtwork.data(for: cover, store: store),
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

    /// 这首歌的封面刚存进来（电视自己读到标签、扫码直传带来封面）：模糊封面还没铺上就再找一次，
    /// 不等一分钟的失败冷却。播放页大封面收到同一条通知也会重新取图。
    func artworkDidCache(_ note: Notification, request: Request, store: TVStore) {
        guard request.source == .coverBlur, frame == nil, loadingKey == nil,
              let cover = request.cover, cover.concerns(note) else { return }
        failedKeys[cover.blurKey] = nil
        update(request, store: store)
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

/// 播放页「模糊封面」虚化哪张图：和播放页大封面（`TVArtworkView`）同一个先后——专辑换过的封面、
/// 歌曲自己的封面、专辑封面缓存，最后按艺人和专辑名在线找。只认歌曲自己的封面时，封面只存在
/// 专辑一级的歌（手机扫的曲库、在线补到的封面）播放页有封面，背景却什么也不铺。
@MainActor
enum TVPlayerCoverArtwork {
    struct Input: Equatable, Sendable {
        var songID: String
        var coverRef: String?
        var albumID: String
        var artist: String
        var album: String
        var albumArtwork: LibraryArtworkOverrideResolution

        /// 背景图的身份：换了封面引用或专辑换了封面都算另一张。
        var blurKey: String {
            let override: String
            switch albumArtwork {
            case .automatic: override = ""
            case .selectedSong(let id): override = "song:\(id)"
            case .uploaded(let id): override = "upload:\(id)"
            }
            return "blur|\(songID)|\(coverRef ?? "")|\(albumID)|\(override)"
        }

        /// 封面缓存通知是不是这首歌、这张专辑的（判法同 `TVArtworkView`）。
        func concerns(_ note: Notification) -> Bool {
            if note.userInfo?["all"] as? Bool == true { return true }
            var songIDs: Set<String> = [songID]
            if case .selectedSong(let id) = albumArtwork { songIDs.insert(id) }
            if let id = note.object as? String, songIDs.contains(id) { return true }
            if let id = note.userInfo?["songID"] as? String, songIDs.contains(id) { return true }
            if let ids = note.userInfo?["songIDs"] as? [String], !songIDs.isDisjoint(with: ids) { return true }
            let tokens = note.userInfo?["tokens"] as? [String] ?? []
            if !albumID.isEmpty, tokens.contains(albumID) { return true }
            if let coverRef, !coverRef.isEmpty, tokens.contains(coverRef) { return true }
            if case .uploaded(let id) = albumArtwork, tokens.contains(id) { return true }
            return false
        }
    }

    static func input(songID: String?, store: TVStore) -> Input? {
        guard let songID, !songID.isEmpty else { return nil }
        let nowPlaying = store.nowPlaying
        let matchesNowPlaying = nowPlaying.songID == songID
        let albumID = matchesNowPlaying ? nowPlaying.albumID : ""
        return Input(
            songID: songID,
            coverRef: matchesNowPlaying
                ? nowPlaying.coverRef
                : store.library.song(id: songID)?.coverArtFileName,
            albumID: albumID,
            artist: matchesNowPlaying ? nowPlaying.artist : "",
            album: matchesNowPlaying ? nowPlaying.album : "",
            albumArtwork: albumID.isEmpty
                ? .automatic
                : store.library.artworkPresentation(
                    for: LibraryArtworkOwner(kind: .album, id: albumID)
                ).resolution
        )
    }

    static func data(for input: Input, store: TVStore) async -> Data? {
        switch input.albumArtwork {
        case .uploaded(let contentID):
            if let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID) { return data }
        case .selectedSong(let selectedSongID):
            if let song = store.library.song(id: selectedSongID),
               let data = await store.songArtworkData(songID: song.id, coverRef: song.coverArtFileName) {
                return data
            }
        case .automatic:
            break
        }
        if let data = await store.songArtworkData(songID: input.songID, coverRef: input.coverRef) {
            return data
        }
        // 飞牛的封面引用只认源里那张，不拿专辑缓存或在线搜到的顶上（同 `TVArtworkView`）。
        guard !Task.isCancelled, !input.albumID.isEmpty,
              FnMusicAPIProtocol.coverID(from: input.coverRef ?? "") == nil else { return nil }
        if let cached = await MetadataAssetStore.shared.cachedAlbumCover(forAlbumID: input.albumID),
           let data = await TVArtworkLoader.shared.preparedAlbumArtwork(
            cached, albumID: input.albumID, animationCacheKey: nil
           ) {
            return data
        }
        guard !Task.isCancelled else { return nil }
        return await TVArtworkLoader.shared.cover(key: input.albumID, artist: input.artist, album: input.album)
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
/// 专辑文件夹里的盘面图(`DiscArtworkPolicy`):专辑页、开盒动画里那张盘和全屏黑胶的盘面。
/// 列过的文件夹记在内存里(没有盘面图也记,列失败不记);读图、缩图和磁盘缓存与封底共用。
@MainActor
enum TVAlbumDiscArtwork {
    private static var choices: [String: TVAlbumBackArtwork.File?] = [:]
    /// 专辑 → 读好的盘面在内存缓存里的键。开盒动画等不及列目录,只用现成的。
    private static var albumFaceKeys: [String: String] = [:]

    static func cachedFace(forAlbumID albumID: String) -> CGImage? {
        albumFaceKeys[albumID].flatMap { PlayerBackdropMemoryCache.shared.image(forKey: $0) }
    }

    /// 这首歌那张碟的盘面图;没有、源列不了目录或读失败都是 nil。
    static func face(for song: Song, store: TVStore) async -> (id: String, image: CGImage)? {
        guard let file = await file(for: song, store: store), !Task.isCancelled else { return nil }
        let key = "disc|" + TVAlbumBackArtwork.memoryKey(sourceID: song.sourceID, file: file)
        var image = PlayerBackdropMemoryCache.shared.image(forKey: key)
        if image == nil {
            let load = TVAlbumBackArtwork.loader(file: file, sourceID: song.sourceID, store: store)
            image = await Task.detached(priority: .userInitiated) { await load() }.value
            guard let image, !Task.isCancelled else { return nil }
            PlayerBackdropMemoryCache.shared.insert(image, forKey: key)
        }
        guard let image else { return nil }
        if let albumID = song.albumID, !albumID.isEmpty { albumFaceKeys[albumID] = key }
        return (key, image)
    }

    private static func file(for song: Song, store: TVStore) async -> TVAlbumBackArtwork.File? {
        let directory = TVFolderRescanPolicy.directory(containingFilePath: song.filePath, levelsAbove: 0)
        let folderName = directory.map { ($0 as NSString).lastPathComponent }
        let discNumber = folderName.flatMap(DiscFolderPolicy.discNumber(fromFolderName:)) ?? song.discNumber
        let key = "\(TVAlbumBackArtwork.directoryKey(for: song))|\(discNumber ?? 1)"
        if let cached = choices[key] { return cached }
        guard let source = store.sourcesStore.source(id: song.sourceID),
              source.isEnabled, !source.isDeleted,
              TVFolderRescanPolicy.supports(source.type),
              TVMetadataReaderPool.canRead(source),
              let lister = store.makeLister(for: source),
              let directory
        else { return nil }
        do {
            let own = try await lister.list(directory).filter { !$0.isDir }
            var album: [TVDirEntry]?
            if let parent = DiscFolderPolicy.parentDirectory(ofDiscFolder: directory) {
                album = try await lister.list(parent).filter { !$0.isDir }
            }
            let entry: TVDirEntry?
            switch DiscArtworkPolicy.choose(
                songFolderNames: own.map(\.name),
                albumFolderNames: album?.map(\.name),
                songFolderName: folderName,
                discNumber: discNumber
            ) {
            case .songFolder(let index): entry = own[index]
            case .albumFolder(let index): entry = album?[index]
            case nil: entry = nil
            }
            let file = entry.map {
                TVAlbumBackArtwork.File(path: $0.path, size: $0.size, modified: $0.modifiedDate)
            }
            choices[key] = .some(file)
            return file
        } catch {
            if !(error is CancellationError) {
                plog("🖼 TV disc face lookup failed source=\(source.type.rawValue): \(error.localizedDescription)")
            }
            return nil
        }
    }
}
#endif
