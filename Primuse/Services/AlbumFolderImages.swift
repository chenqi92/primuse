import CoreGraphics
import Foundation
import PrimuseKit

/// 一首歌所在专辑文件夹里的图片(歌在分碟子文件夹里时连上一层一起列):全屏黑胶的盘面图和
/// 专辑「编辑封面」里的文件夹图片都从这里取。只有按目录组织的音乐源才有;列过的文件夹记在
/// 内存里(列失败不记,下次再试)。缩好的图在内存和磁盘各缓存一份,和播放页封底共用缓存目录。
@MainActor
enum AlbumFolderImages {
    struct Picture: Sendable, Hashable, Identifiable {
        let path: String
        let name: String
        let size: Int64
        let modified: Date?
        let sourceID: String
        /// 在分碟子文件夹上一层的专辑文件夹里。
        let isInAlbumFolder: Bool

        var id: String { "\(sourceID)|\(path)" }

        var cacheKey: String {
            "\(sourceID)|\(path)|\(size)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        }
    }

    struct Listing: Sendable {
        var songFolder: [Picture]
        /// 歌在分碟子文件夹里时上一层的图片;否则 nil。
        var albumFolder: [Picture]?
        var songFolderName: String?

        static let empty = Listing(songFolder: [], albumFolder: nil, songFolderName: nil)

        var all: [Picture] { songFolder + (albumFolder ?? []) }
    }

    nonisolated static let maximumPictureBytes = 40 * 1024 * 1024
    nonisolated static let discFaceMaxPixel = 1_200

    private static var listings: [String: Listing] = [:]

    /// 这首歌的文件夹里的图片;源列不了目录时为空,列失败为 nil。
    static func listing(for song: Song, sourceManager: SourceManager) async -> Listing? {
        let songDirectory = (song.filePath as NSString).deletingLastPathComponent
        let key = "\(song.sourceID)|\(songDirectory)"
        if let cached = listings[key] { return cached }
        guard let source = await sourceManager.source(withID: song.sourceID),
              source.isEnabled, !source.isDeleted,
              source.type.supportsFolderRescan else { return .empty }
        let connector = sourceManager.connector(for: source)
        do {
            try await connector.connect()
            let directory: String
            var albumDirectory: String?
            if source.type.usesOpaqueDirectoryIdentifiers {
                guard let resolver = connector as? any LyricsSidecarTargetResolving else { return .empty }
                directory = try await resolver.lyricsSidecarTarget(
                    for: song,
                    request: .catalog(for: song)
                ).containerPath
            } else {
                directory = songDirectory
                albumDirectory = DiscFolderPolicy.parentDirectory(ofDiscFolder: songDirectory)
            }
            let own = try await connector.listFiles(at: directory)
            var album: [RemoteFileItem]?
            if let albumDirectory {
                album = try await connector.listFiles(at: albumDirectory)
            }
            let listing = Listing(
                songFolder: pictures(in: own, sourceID: song.sourceID, isInAlbumFolder: false),
                albumFolder: album.map { pictures(in: $0, sourceID: song.sourceID, isInAlbumFolder: true) },
                songFolderName: (songDirectory as NSString).lastPathComponent
            )
            listings[key] = listing
            return listing
        } catch is CancellationError {
            return nil
        } catch {
            plog("🖼 Album folder images lookup failed source=\(source.type.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    /// 这首歌那张碟的盘面图(`DiscArtworkPolicy`);没有或读不出来是 nil。
    static func discFace(for song: Song, sourceManager: SourceManager) async -> CGImage? {
        guard let listing = await listing(for: song, sourceManager: sourceManager),
              !Task.isCancelled else { return nil }
        let discNumber = listing.songFolderName.flatMap(DiscFolderPolicy.discNumber(fromFolderName:))
            ?? song.discNumber
        let picture: Picture?
        switch DiscArtworkPolicy.choose(
            songFolderNames: listing.songFolder.map(\.name),
            albumFolderNames: listing.albumFolder?.map(\.name),
            songFolderName: listing.songFolderName,
            discNumber: discNumber
        ) {
        case .songFolder(let index): picture = listing.songFolder[index]
        case .albumFolder(let index): picture = listing.albumFolder?[index]
        case nil: picture = nil
        }
        guard let picture else { return nil }
        return await image(of: picture, maxPixel: discFaceMaxPixel, sourceManager: sourceManager, preservingAlpha: true)
    }

    /// 缩到 `maxPixel` 的图:先内存、再磁盘缓存,都没有才从音乐源读。
    static func image(of picture: Picture, maxPixel: Int, sourceManager: SourceManager, preservingAlpha: Bool = false) async -> CGImage? {
        let format = preservingAlpha ? "disc-alpha-v1|" : ""
        let memoryKey = "folder-image|\(format)\(picture.cacheKey)|\(maxPixel)"
        if let cached = PlayerBackdropMemoryCache.shared.image(forKey: memoryKey) { return cached }
        let diskKey = "\(format)\(picture.cacheKey)|\(maxPixel)"
        let cachedURL = PlayerBackdropAlbumBackCache.fileURL(forKey: diskKey, preservingAlpha: preservingAlpha)
        var image = await Task.detached(priority: .utility) {
            PlayerBackdropImaging.decodedImage(url: cachedURL, maxPixel: maxPixel)
        }.value
        if image == nil {
            guard let data = await originalData(of: picture, sourceManager: sourceManager),
                  !Task.isCancelled else { return nil }
            image = await Task.detached(priority: .utility) { () -> CGImage? in
                let encoded = preservingAlpha
                    ? PlayerBackdropImaging.downscaledPNG(from: data, maxPixel: maxPixel)
                    : PlayerBackdropImaging.downscaledJPEG(from: data, maxPixel: maxPixel)
                guard let encoded else {
                    return nil
                }
                PlayerBackdropAlbumBackCache.store(encoded, forKey: diskKey, preservingAlpha: preservingAlpha)
                return PlayerBackdropImaging.decodedImage(data: encoded, maxPixel: maxPixel)
            }.value
        }
        guard let image else { return nil }
        PlayerBackdropMemoryCache.shared.insert(image, forKey: memoryKey)
        return image
    }

    /// 原图的字节,给「用作专辑封面」用。
    static func originalData(of picture: Picture, sourceManager: SourceManager) async -> Data? {
        guard picture.size <= Int64(maximumPictureBytes) else { return nil }
        let limit = picture.size > 0 ? Int(picture.size) : maximumPictureBytes
        return await sourceManager.artworkData(
            for: picture.path,
            sourceID: picture.sourceID,
            maximumBytes: limit,
            purpose: .originalAnimation
        )
    }

    private static func pictures(in items: [RemoteFileItem], sourceID: String, isInAlbumFolder: Bool) -> [Picture] {
        items.compactMap { item in
            guard !item.isDirectory,
                  PrimuseConstants.supportedCoverExtensions.contains((item.name as NSString).pathExtension.lowercased())
            else { return nil }
            return Picture(
                path: item.path,
                name: item.name,
                size: item.size,
                modified: item.modifiedDate,
                sourceID: sourceID,
                isInAlbumFolder: isInAlbumFolder
            )
        }
    }
}
