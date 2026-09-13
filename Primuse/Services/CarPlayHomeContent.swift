#if os(iOS)
import CarPlay
import Combine
import ImageIO
import struct MusicKit.MusicAuthorization
import struct MusicKit.MusicDataRequest
import UIKit
import PrimuseKit

actor CarPlayAppleMusicArtwork {
    enum Kind: String, Sendable { case songs, playlists }
    private struct Response: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable {
                struct Artwork: Decodable { let url: String? }
                let artwork: Artwork?
            }
            struct Relationships: Decodable {
                struct Catalog: Decodable { let data: [Item] }
                let catalog: Catalog?
            }
            let attributes: Attributes?
            let relationships: Relationships?
        }
        let data: [Item]
    }
    private struct Entry {
        let reference: String?
        let expires: Date
    }
    static let shared = CarPlayAppleMusicArtwork()
    private let fetch: @Sendable (URL) async throws -> Data
    private let isAuthorized: @Sendable () -> Bool
    private var cache: [String: Entry] = [:]
    private var requests: [String: Task<String?, Never>] = [:]
    private var activeRequests = 0

    init(fetch: @escaping @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        return try await MusicDataRequest(urlRequest: request).response().data
    }, isAuthorized: @escaping @Sendable () -> Bool = { MusicAuthorization.currentStatus == .authorized }) {
        self.fetch = fetch
        self.isAuthorized = isAuthorized
    }

    func reference(kind: Kind, id: String, pixelSize: Int) async -> String? {
        guard isAuthorized(), let url = Self.resourceURL(kind: kind, id: id) else { return nil }
        let key = "\(kind.rawValue)/\(id)"
        let reference: String?
        if let cached = cache[key], cached.expires > Date() {
            reference = cached.reference
        } else if let request = requests[key] {
            reference = await request.value
        } else {
            let request = Task { await self.fetchReference(url: url) }
            requests[key] = request
            reference = await request.value
            requests[key] = nil
            if cache.count >= 256, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key {
                cache[oldest] = nil
            }
            cache[key] = Entry(reference: reference, expires: Date().addingTimeInterval(reference == nil ? 30 : 3_600))
        }
        guard !Task.isCancelled, let reference else { return nil }
        let side = String(max(1, min(1_024, pixelSize)))
        let resolved = reference.replacingOccurrences(of: "{w}", with: side).replacingOccurrences(of: "{h}", with: side)
        guard let url = URL(string: resolved), url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return resolved
    }

    nonisolated static func resourceURL(kind: Kind, id: String) -> URL? {
        let prefix = kind == .songs ? "i." : "p."
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard id.hasPrefix(prefix), id.count > prefix.count,
              id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return URL(string: "https://api.music.apple.com/v1/me/library/\(kind.rawValue)/\(id)?include=catalog")
    }

    private func fetchReference(url: URL) async -> String? {
        while activeRequests >= 4 {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
        }
        guard !Task.isCancelled, isAuthorized() else { return nil }
        activeRequests += 1
        defer { activeRequests -= 1 }
        guard let data = try? await fetch(url), let response = try? JSONDecoder().decode(Response.self, from: data),
              let item = response.data.first else { return nil }
        // Library Artwork may use a MusicKit-only scheme. The REST resource exposes its public bitmap URL.
        return item.attributes?.artwork?.url ?? item.relationships?.catalog?.data.first?.attributes?.artwork?.url
    }
}

@MainActor
final class CarPlayArtworkUpdates {
    private final class Bindings {
        var entries: [(Set<String>, @MainActor () -> Void)] = []
    }
    private let owners = NSMapTable<AnyObject, Bindings>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var subscription: AnyCancellable?

    init(center: NotificationCenter = .default) {
        subscription = center.publisher(for: .primuseArtworkDidCache).sink { [weak self] notification in
            guard let songID = notification.object as? String else { return }
            Task { @MainActor [weak self] in self?.refresh(songID: songID) }
        }
    }

    func bind(owner: AnyObject, songIDs: Set<String>, refresh: @escaping @MainActor () -> Void) {
        guard !songIDs.isEmpty else { return }
        let bindings = owners.object(forKey: owner) ?? Bindings()
        bindings.entries.append((songIDs, refresh))
        owners.setObject(bindings, forKey: owner)
    }

    private func refresh(songID: String) {
        guard let bindings = owners.objectEnumerator()?.allObjects as? [Bindings] else { return }
        for group in bindings {
            for (songIDs, refresh) in group.entries where songIDs.contains(songID) { refresh() }
        }
    }

    func removeAll() { owners.removeAllObjects() }
}

@MainActor
enum CarPlayTemplateImages {
    static let listSide = min(CPListItem.maximumImageSize.width, CPListItem.maximumImageSize.height)
    private static let placeholders = NSCache<NSString, UIImage>()

    static func placeholder(_ symbol: String, side: CGFloat = listSide, scale: CGFloat = 2, artwork: Bool = true) -> UIImage {
        let key = "\(symbol):\(side):\(scale):\(artwork)" as NSString
        if let cached = placeholders.object(forKey: key) { return cached }
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = artwork
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
                if artwork {
                    UIColor.secondarySystemBackground.resolvedColor(with: traits).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                }
                let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.44, weight: .medium))?
                    .withTintColor(UIColor.label.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
                if let glyph {
                    let ratio = min(side * 0.52 / glyph.size.width, side * 0.52 / glyph.size.height)
                    let size = CGSize(width: glyph.size.width * ratio, height: glyph.size.height * ratio)
                    glyph.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
                }
            }
            asset.register(image.withRenderingMode(.alwaysOriginal), with: traits)
        }
        let image = asset.image(with: .current)
        placeholders.setObject(image, forKey: key, cost: Int(side * scale * side * scale * 8))
        placeholders.totalCostLimit = 12 * 1_024 * 1_024
        return image
    }

    static func square(_ image: UIImage, side: CGFloat = listSide, scale: CGFloat = 2) -> UIImage {
        guard image.size.width > 0, image.size.height > 0 else { return placeholder("music.note", side: side, scale: scale) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let ratio = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysOriginal)
        return rendered
    }

    static func rowSide(for style: CarPlayBrowseStyle) -> CGFloat {
        let maximum: CGSize
        if #available(iOS 26.0, *) {
            switch style {
            case .cards: maximum = CPListImageRowItemCardElement.maximumImageSize
            case .capsules: maximum = CPListImageRowItemCondensedElement.maximumImageSize
            default: maximum = CPListImageRowItemRowElement.maximumImageSize
            }
        } else { maximum = CPListImageRowItem.maximumImageSize }
        return max(1, min(160, maximum.width, maximum.height))
    }
}

enum CarPlayContentArtwork: Sendable {
    case song(Song), album(Album), playlist(Playlist)
    case songReference(id: String, coverRef: String?)

    /// 同一张封面在多次列表重建之间的稳定标识。歌曲带上 coverRef，换了封面文件
    /// 就是另一张图；专辑与歌单只认 ID，它们的封面变化由覆盖版本号负责作废。
    var cacheIdentity: String {
        switch self {
        case .song(let song): "song:\(song.id):\(song.coverArtFileName ?? "")"
        case .songReference(let id, let coverRef): "song:\(id):\(coverRef ?? "")"
        case .album(let album): "album:\(album.id)"
        case .playlist(let playlist): "playlist:\(playlist.id)"
        }
    }
}

/// 已经取到并渲染好的 CarPlay 行内封面。
///
/// 只在主线程访问，容量按「一屏几十行 × 几个尺寸」取，超出由 NSCache 自行淘汰。
@MainActor
enum CarPlayRenderedArtwork {
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    static func image(forKey key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    static func store(_ image: UIImage, forKey key: String) {
        images.setObject(image, forKey: key as NSString)
    }

    static func removeAll() { images.removeAllObjects() }
}

struct CarPlayHomeItem: Identifiable, Sendable {
    enum Target: Sendable {
        case nowPlaying
        case song(String, queue: [String])
        case playlist(String, directly: Bool)
        case album(String, directly: Bool)
        case folder(LibraryFolderNodeID, directly: Bool)
        case radio(String)
        case unavailable
    }
    let id: String
    let title: String
    var subtitle: String? = nil
    var symbol = "music.note"
    var artwork: CarPlayContentArtwork? = nil
    var enabled = true
    let target: Target
}

struct CarPlayHomeBlock: Identifiable {
    let configuration: CarPlayLayoutBlock
    var items: [CarPlayHomeItem]
    var id: String { configuration.id }
    var title: String {
        configuration.title.isEmpty ? NSLocalizedString(configuration.kind.titleKey, comment: "") : configuration.title
    }
}

/// Both the editor and the CarPlay templates resolve the same identities and
/// apply the same grouping budget; previewing never starts audio playback.
@MainActor
enum CarPlayHomeContent {
    static func resolve(_ configuration: CarPlayLayoutConfiguration) -> [CarPlayHomeBlock] {
        let player = AppServices.shared.playerService
        let nowPlaying: CarPlayHomeItem? = player.currentSong != nil || player.currentRadioStation != nil
            ? CarPlayHomeItem(id: "nowPlaying", title: String(localized: "carplay_now_playing"),
                subtitle: player.currentSong?.title ?? player.currentRadioStation?.name,
                symbol: "play.circle", artwork: player.currentSong.map(CarPlayContentArtwork.song), target: .nowPlaying) : nil
        let resolved = CarPlayEditorCatalog.shared.snapshot.blocks(for: configuration,
            folders: CarPlayFolderLibrary.shared.index, nowPlaying: nowPlaying)
        var remainingRows = max(1, CPListTemplate.maximumItemCount - 4)
        var remainingSections = max(1, CPListTemplate.maximumSectionCount - 1)
        return resolved.filter { $0.configuration.isVisible && $0.configuration.kind != .siri }.map { source in
            var block = source
            let columns = block.configuration.style == .list ? 1 : rowSize(for: block.configuration)
            let available = remainingSections > 0 ? remainingRows * columns : 0
            block.items = Array(block.items.prefix(available))
            if !block.items.isEmpty {
                remainingRows -= (block.items.count + columns - 1) / columns
                remainingSections -= 1
            }
            return block
        }
    }

    static func rowSize(for block: CarPlayLayoutBlock) -> Int {
        max(1, min(Int(CPMaximumNumberOfGridImages), block.normalized.columns))
    }

    static func resolve(_ item: CarPlayLayoutItem, directly: Bool) -> CarPlayHomeItem {
        let library = AppServices.shared.musicLibrary
        var resolved: CarPlayHomeItem?
        switch item.kind {
        case .nowPlaying:
            let player = AppServices.shared.playerService
            resolved = CarPlayHomeItem(id: item.id, title: String(localized: "carplay_now_playing"),
                                       subtitle: player.currentSong?.title ?? player.currentRadioStation?.name,
                                       symbol: "play.circle", artwork: player.currentSong.map(CarPlayContentArtwork.song),
                                       target: .nowPlaying)
        case .playlist:
            resolved = library.playlists.first { $0.id == item.targetID }.map { playlist($0, directly: directly) }
        case .album:
            resolved = library.visibleAlbums.first { $0.id == item.targetID }.map { album($0, directly: directly) }
        case .song:
            resolved = library.unobservedVisibleSong(id: item.targetID).map { song($0, queue: [$0.id]) }
        case .folder:
            resolved = item.folderID.flatMap { CarPlayFolderLibrary.shared.index?.node(withID: $0) }.map { folder($0, directly: directly) }
        case .radio:
            resolved = AppServices.shared.radioStationsStore.station(id: item.targetID).map {
                CarPlayHomeItem(id: item.id, title: $0.name, subtitle: $0.playbackSubtitle, symbol: "radio", target: .radio($0.id))
            }
        }
        guard let resolved else {
            return CarPlayHomeItem(id: item.id, title: item.title, subtitle: String(localized: "carplay_content_unavailable"),
                                   symbol: "exclamationmark.circle", enabled: false, target: .unavailable)
        }
        return CarPlayHomeItem(id: item.id, title: resolved.title, subtitle: resolved.subtitle,
                               symbol: resolved.symbol, artwork: resolved.artwork, enabled: resolved.enabled, target: resolved.target)
    }

    static func songs(for target: CarPlayHomeItem.Target) -> [Song] {
        let library = AppServices.shared.musicLibrary
        switch target {
        case .song(_, let queue): return queue.compactMap { library.unobservedVisibleSong(id: $0) }
        case .playlist(let id, _): return library.songs(forPlaylist: id)
        case .album(let id, _):
            return library.songs(forAlbum: id).sorted {
                ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0)
            }
        case .folder(let id, _): return CarPlayFolderLibrary.shared.songs(in: id)
        case .nowPlaying: return AppServices.shared.playerService.currentSong.map { [$0] } ?? []
        case .radio, .unavailable: return []
        }
    }

    static func artwork(_ artwork: CarPlayContentArtwork, pixelSize: Int) async -> UIImage? {
        let library = AppServices.shared.musicLibrary
        let owner: LibraryArtworkOwner
        switch artwork {
        case .songReference(let id, let coverRef):
            if let song = library.unobservedVisibleSong(id: id) { return await songArtwork(song, pixelSize: pixelSize) }
            return await CarPlayArtworkDecoder.shared.thumbnail(forSongID: id, coverRef: coverRef, maximumPixelSize: pixelSize)
        case .song(let song):
            return await songArtwork(song, pixelSize: pixelSize)
        case .album(let album):
            owner = LibraryArtworkOwner(kind: .album, id: album.id)
        case .playlist(let playlist):
            owner = LibraryArtworkOwner(kind: .playlist, id: playlist.id)
        }
        let presentation = library.artworkPresentation(for: owner)
        switch presentation.resolution {
        case .uploaded(let contentID):
            return await Task.detached(priority: .utility) {
                guard let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID),
                      data.count <= 16 * 1_024 * 1_024,
                      let source = CGImageSourceCreateWithData(data as CFData, [
                        kCGImageSourceShouldCache: false
                      ] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixelSize
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        case .selectedSong:
            guard let song = presentation.selectedSong else { return nil }
            return await songArtwork(song, pixelSize: pixelSize)
        case .automatic:
            if case .playlist(let playlist) = artwork {
                let candidates = library.rawSongIDs(forPlaylist: playlist.id).lazy
                    .compactMap { library.unobservedVisibleSong(id: $0) }.prefix(12)
                let songs = Array(candidates)
                let plan = PlaylistArtworkResolutionPolicy.makePlan(playlist: playlist, songs: songs)
                let sourceID = MirrorPlaylistSuppressionPolicy.key(forPlaylistID: playlist.id)?.sourceID
                let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let result = await PlaylistArtworkResolver.resolve(plan: plan) { candidate -> UIImage? in
                    if candidate.kind == .song {
                        guard let id = candidate.songID, let song = songsByID[id] else { return nil }
                        return await songArtwork(song, pixelSize: pixelSize)
                    }
                    if sourceID == AppleMusicLibraryIdentity.sourceID {
                        let reference = AppServices.shared.appleMusicLibrary.cachedMusicKitPlaylistArtwork(playlistID: playlist.id)?
                            .url(width: pixelSize, height: pixelSize)?.absoluteString
                        if let image = await appleMusicBitmap(references: [reference, candidate.artworkReference], pixelSize: pixelSize) { return image }
                        guard let id = MirrorPlaylistSuppressionPolicy.key(forPlaylistID: playlist.id)?.remotePlaylistID else { return nil }
                        let libraryReference = await CarPlayAppleMusicArtwork.shared.reference(kind: .playlists, id: id, pixelSize: pixelSize)
                        return await appleMusicBitmap(references: [libraryReference], pixelSize: pixelSize)
                    }
                    return await CachedArtworkView.resolveImage(coverRef: candidate.artworkReference, songID: nil,
                        size: CGFloat(pixelSize), sourceID: sourceID, filePath: nil, fileFormat: nil,
                        sourceManager: AppServices.shared.sourceManager,
                        cacheDiscriminator: "carplay:\(playlist.updatedAt.timeIntervalSinceReferenceDate)")
                }
                return result?.value
            }
            guard case .album(let album) = artwork, let song = library.preferredArtworkSong(forAlbumID: album.id) else { return nil }
            return await songArtwork(song, pixelSize: pixelSize)
        }
    }

    static func httpArtworkReference(_ reference: String?) -> String? {
        guard let reference, let url = URL(string: reference), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return reference
    }

    private static func appleMusicBitmap(references: [String?], pixelSize: Int, songID: String? = nil) async -> UIImage? {
        for reference in references {
            guard let reference = httpArtworkReference(reference) else { continue }
            // MusicKit artwork URLs are public images, not requests to an audio source connector.
            if let image = await CachedArtworkView.resolveImage(coverRef: reference, songID: songID,
                size: CGFloat(pixelSize), sourceID: nil, filePath: nil, fileFormat: nil,
                sourceManager: AppServices.shared.sourceManager) { return image }
        }
        return nil
    }

    static func songArtwork(_ song: Song, pixelSize: Int, sourceManager: SourceManager = AppServices.shared.sourceManager) async -> UIImage? {
        if let image = await CarPlayArtworkDecoder.shared.thumbnail(forSongID: song.id,
            coverRef: song.coverArtFileName, maximumPixelSize: pixelSize) { return image }
        if song.sourceID == AppleMusicLibraryIdentity.sourceID {
            let reference = AppServices.shared.appleMusicLibrary.cachedMusicKitSong(amID: song.filePath)?.artwork?
                .url(width: pixelSize, height: pixelSize)?.absoluteString
            if let image = await appleMusicBitmap(references: [reference, song.coverArtFileName], pixelSize: pixelSize, songID: song.id) { return image }
            let libraryReference = await CarPlayAppleMusicArtwork.shared.reference(kind: .songs, id: song.filePath, pixelSize: pixelSize)
            return await appleMusicBitmap(references: [libraryReference], pixelSize: pixelSize, songID: song.id)
        }
        return await CachedArtworkView.resolveImage(coverRef: song.coverArtFileName, songID: song.id,
            size: CGFloat(pixelSize), sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat,
            sourceManager: sourceManager)
    }

    static func artworkSongIDs(_ artwork: CarPlayContentArtwork) -> Set<String> {
        let library = AppServices.shared.musicLibrary
        let owner: LibraryArtworkOwner
        switch artwork {
        case .song(let song): return [song.id]
        case .songReference(let id, _): return [id]
        case .playlist(let playlist): owner = LibraryArtworkOwner(kind: .playlist, id: playlist.id)
        case .album(let album): owner = LibraryArtworkOwner(kind: .album, id: album.id)
        }
        let presentation = library.artworkPresentation(for: owner)
        switch presentation.resolution {
        case .uploaded: return []
        case .selectedSong: return Set(presentation.selectedSong.map { [$0.id] } ?? [])
        case .automatic:
            switch artwork {
            case .playlist(let playlist): return Set(library.rawSongIDs(forPlaylist: playlist.id).lazy
                .compactMap { library.unobservedVisibleSong(id: $0)?.id }.prefix(12))
            case .album(let album): return Set(library.preferredArtworkSong(forAlbumID: album.id).map { [$0.id] } ?? [])
            default: return []
            }
        }
    }

    private static func playlist(_ playlist: Playlist, directly: Bool) -> CarPlayHomeItem {
        let summary = AppServices.shared.musicLibrary.songSummary(forPlaylist: playlist.id)
        return CarPlayHomeItem(id: playlist.id, title: playlist.name, subtitle: count(summary.count),
                               symbol: playlist.id == MusicLibrary.likedSongsPlaylistID ? "heart.fill" : "music.note.list",
                               artwork: .playlist(playlist), enabled: summary.count > 0 || !directly,
                               target: .playlist(playlist.id, directly: directly))
    }

    private static func album(_ album: Album, directly: Bool) -> CarPlayHomeItem {
        CarPlayHomeItem(id: album.id, title: album.title, subtitle: album.artistName, symbol: "square.stack",
                        artwork: .album(album), target: .album(album.id, directly: directly))
    }

    private static func song(_ song: Song, queue: [String]) -> CarPlayHomeItem {
        CarPlayHomeItem(id: song.id, title: song.title, subtitle: AppServices.shared.musicLibrary.artistDisplayName(for: song),
                        artwork: .song(song), target: .song(song.id, queue: queue))
    }

    private static func folder(_ node: LibraryFolderNode, directly: Bool) -> CarPlayHomeItem {
        CarPlayHomeItem(id: HomeFolderPinStorage.encode([node.id]), title: HomeDiscoveryText.folderTitle(node),
                        subtitle: count(node.descendantSongCount), symbol: "folder.fill",
                        enabled: node.descendantSongCount > 0 || !directly, target: .folder(node.id, directly: directly))
    }

    private static func count(_ count: Int) -> String {
        String(format: String(localized: "carplay_playlist_song_count_format"), count)
    }
}
#endif
