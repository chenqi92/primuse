import SwiftUI
import ImageIO
import MusicKit
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Loads cover art with a unified three-tier strategy:
/// 1. Memory cache (NSCache, keyed by songID + size bucket)
/// 2. Disk cache (MetadataAssetStore, keyed by songID)
/// 3. Source fetch (URL download / sidecar download / embedded extraction)
///
/// Decoding runs off the main thread via ImageIO so list scrolling never
/// pays for `PlatformImage(data:)` lazy decode at draw time. Each cover is
/// also downsampled to one of three pixel buckets:
/// - `thumb` (max 288px) for list-cell sized requests (size <= 96pt)
/// - `card`  (max 768px) for album / artist grids
/// - `full`  (max 1536px) for hero / large views
/// so a 1500×1500 source image never sits decoded inside a 44pt row cell.
///
/// `coverRef` stores the source-side reference:
/// - Media servers: full API URL (https://...)
/// - NAS/protocol: sidecar relative path (/Music/Album/cover.jpg) or nil (embedded)
/// - Legacy: old hashed filename (abc123.jpg) — read from local cache directly
struct CachedArtworkView: View {
    let coverRef: String?
    var songID: String? = nil
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 12
    var sourceID: String? = nil
    var filePath: String? = nil
    var fileFormat: AudioFormat? = nil
    /// For album/artist artwork fetched by ArtworkFetchService
    var albumID: String? = nil
    var albumTitle: String? = nil
    var albumYear: Int? = nil
    var albumTrackCount: Int? = nil
    var artistID: String? = nil
    var artistName: String? = nil
    var placeholderIcon: String = "music.note"
    var showsPlaceholder: Bool = true
    var presentationRole: ArtworkPresentationRole = .staticFirstFrame
    var animationRequiresPlayback = false
    var isPlaying = true
    var isAnimationVisible = true
    /// Large presentation surfaces can mount before their entrance animation.
    /// While disabled, reuse an already-decoded cache entry without starting
    /// disk/source IO; the requested bucket is upgraded once the transition
    /// has settled.
    var loadsHighResolution = true
    /// 当外部数据源 (e.g. AudioPlayerService.coverRevision) 想强制 view 重新加载,
    /// 但 coverRef / songID 这些 key 字段没变, onChange 不会触发时使用。
    /// 调用方传 player.coverRevision, 任意 bump 都会让本 view 重 loadImage。
    var revisionToken: Int = 0
    var onResolutionChange: (Bool) -> Void = { _ in }

    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PlayerAppearancePreferences.animatedArtworkEnabledKey)
    private var animatedArtworkEnabled = PlayerAppearancePreferences.animatedArtworkEnabledByDefault
    @AppStorage(PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyKey)
    private var animatedArtworkUnmeteredOnly = PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyByDefault
    @AppStorage(PlayerAppearancePreferences.motionArtworkServiceEnabledKey)
    private var motionArtworkServiceEnabled = PlayerAppearancePreferences.motionArtworkServiceEnabledByDefault
    @AppStorage(PlayerAppearancePreferences.motionArtworkServiceEndpointKey)
    private var motionArtworkServiceEndpoint = PlayerAppearancePreferences.motionArtworkServiceEndpointByDefault
    @State private var image: PlatformImage?
    @State private var animatedArtworkData: Data?
    @State private var animatedArtworkDescriptor: ArtworkDescriptor?
    @State private var animatedArtworkIdentity: String?
    @State private var animatedArtworkContentKey: String?
    @State private var animatedArtworkExpiresAt: Date?
    @State private var animatedArtworkGeneration: String?
    @State private var resolvedAppleMusicArtwork: MusicKit.Artwork?
    @State private var resolvedAppleMusicArtworkID: String?
    #if os(macOS)
    @State private var imageLoadingRequest: UUID?
    @State private var musicKitLoadingRequest: UUID?
    #endif
    @State private var loadedIdentity: String?
    @State private var displayedArtworkIdentity: String?
    @State private var cacheInvalidationRevision = 0
    @State private var animationPolicyRevision = 0
    @State private var animationCacheMaintenanceGeneration = 0
    @State private var animationCacheMaintenancePending = false


    /// Memory cache holds *already-decoded* PlatformImages. Cost is reported
    /// as real pixel byte count so the limit reflects actual memory pressure
    /// rather than the compressed source size.
    nonisolated(unsafe) private static let memoryCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Remember recent failed loads so scrolling away and back does not keep
    /// re-checking the same missing sidecar / source artwork.
    nonisolated(unsafe) private static let failedLoadCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 1_000
        return cache
    }()

    private static let failedLoadCacheTTL: TimeInterval = 5 * 60

    private final class ArtworkDescriptorBox: NSObject {
        let descriptor: ArtworkDescriptor
        init(_ descriptor: ArtworkDescriptor) { self.descriptor = descriptor }
    }

    private struct AnimatedArtworkInspection: Sendable {
        let descriptor: ArtworkDescriptor
        let contentKey: String
    }

    nonisolated(unsafe) private static let animationDescriptorCache: NSCache<NSString, ArtworkDescriptorBox> = {
        let cache = NSCache<NSString, ArtworkDescriptorBox>()
        cache.countLimit = 200
        return cache
    }()

    private static let animationDiskCache: ArtworkAnimationDiskCache = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("AnimatedArtwork", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        return ArtworkAnimationDiskCache(directory: directory)
    }()

    private nonisolated static let staticAnimationNegativeTTL: TimeInterval = 24 * 60 * 60
    private nonisolated static let transientAnimationFailureTTL: TimeInterval = 5 * 60
    private nonisolated static let configuredMotionArtworkMaximumPositiveTTL: TimeInterval = 24 * 60 * 60

    /// Deduplicates in-flight source fetches: multiple views requesting the same cover
    /// share a single network request instead of each fetching independently.
    private static let inFlightTracker = InFlightFetchTracker()

    private enum Bucket: String, Sendable {
        case thumb, card, full
    }

    /// Anything visibly small (list rows, mini player, album cards under
    /// ~88pt) lands in the thumb bucket. 96 keeps a small headroom for
    /// occasional 80pt artist circles without bumping them to a full decode.
    private var bucket: Bucket {
        Self.bucket(for: size)
    }

    private nonisolated static func bucket(for size: CGFloat?) -> Bucket {
        guard let size else { return .full }
        if size <= 96 { return .thumb }
        if size <= 320 { return .card }
        return .full
    }

    /// 96pt × 3x display scale. ImageIO downsamples in the GPU and the
    /// resulting CGImage is fed to PlatformImage at scale 1, so cost stays small.
    private nonisolated static let thumbMaxPixel: Int = 288

    /// Grid cards need enough pixels for a 3x display without paying the
    /// roughly 9 MiB decoded cost of a 1536px square for every visible album.
    private nonisolated static let cardMaxPixel: Int = 768

    /// Cap full-resolution decodes so a pathological 4000×4000 source can't
    /// blow the cache budget by itself. Larger than any device's hero art.
    private nonisolated static let fullMaxPixel: Int = 1536

    /// Shared session for source-side cover fetches. A delegate-backed
    /// URLSession strongly retains its delegate and never deallocates until
    /// explicitly invalidated, so creating one per fetch leaks both the
    /// session and the SmartSSLDelegate while scrolling long lists. Reuse a
    /// single long-lived session instead (SmartSSLDelegate is Sendable).
    private static let sharedArtworkSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    // Backward compatible init — old call sites use coverFileName
    init(coverFileName: String?, size: CGFloat? = nil, cornerRadius: CGFloat = 12,
         sourceID: String? = nil, filePath: String? = nil,
         fileFormat: AudioFormat? = nil,
         showsPlaceholder: Bool = true,
         presentationRole: ArtworkPresentationRole = .staticFirstFrame,
         animationRequiresPlayback: Bool = false,
         isPlaying: Bool = true,
         isAnimationVisible: Bool = true,
         loadsHighResolution: Bool = true,
         revisionToken: Int = 0,
         onResolutionChange: @escaping (Bool) -> Void = { _ in }) {
        self.coverRef = coverFileName
        self.size = size
        self.cornerRadius = cornerRadius
        self.sourceID = sourceID
        self.filePath = filePath
        self.fileFormat = fileFormat
        self.showsPlaceholder = showsPlaceholder
        self.presentationRole = presentationRole
        self.animationRequiresPlayback = animationRequiresPlayback
        self.isPlaying = isPlaying
        self.isAnimationVisible = isAnimationVisible
        self.loadsHighResolution = loadsHighResolution
        self.revisionToken = revisionToken
        self.onResolutionChange = onResolutionChange
    }

    // New init with explicit songID
    init(coverRef: String?, songID: String?, size: CGFloat? = nil, cornerRadius: CGFloat = 12,
         sourceID: String? = nil, filePath: String? = nil,
         fileFormat: AudioFormat? = nil,
         placeholderIcon: String = "music.note",
         showsPlaceholder: Bool = true,
         presentationRole: ArtworkPresentationRole = .staticFirstFrame,
         animationRequiresPlayback: Bool = false,
         isPlaying: Bool = true,
         isAnimationVisible: Bool = true,
         loadsHighResolution: Bool = true,
         revisionToken: Int = 0,
         onResolutionChange: @escaping (Bool) -> Void = { _ in }) {
        self.coverRef = coverRef
        self.songID = songID
        self.size = size
        self.cornerRadius = cornerRadius
        self.sourceID = sourceID
        self.filePath = filePath
        self.fileFormat = fileFormat
        self.placeholderIcon = placeholderIcon
        self.showsPlaceholder = showsPlaceholder
        self.presentationRole = presentationRole
        self.animationRequiresPlayback = animationRequiresPlayback
        self.isPlaying = isPlaying
        self.isAnimationVisible = isAnimationVisible
        self.loadsHighResolution = loadsHighResolution
        self.revisionToken = revisionToken
        self.onResolutionChange = onResolutionChange
    }

    // Album cover init. Rendering reads cache only; multi-provider online
    // scraping is maintenance work and must never be started by a view mount.
    init(albumID: String, albumTitle: String, artistName: String?,
         year: Int? = nil, trackCount: Int? = nil,
         size: CGFloat? = nil, cornerRadius: CGFloat = 12,
         showsPlaceholder: Bool = true,
         presentationRole: ArtworkPresentationRole = .staticFirstFrame,
         animationRequiresPlayback: Bool = false,
         isPlaying: Bool = true,
         isAnimationVisible: Bool = true,
         onResolutionChange: @escaping (Bool) -> Void = { _ in }) {
        self.coverRef = nil
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.albumYear = year
        self.albumTrackCount = trackCount
        self.artistName = artistName
        self.size = size
        self.cornerRadius = cornerRadius
        self.placeholderIcon = "square.stack"
        self.showsPlaceholder = showsPlaceholder
        self.presentationRole = presentationRole
        self.animationRequiresPlayback = animationRequiresPlayback
        self.isPlaying = isPlaying
        self.isAnimationVisible = isAnimationVisible
        self.onResolutionChange = onResolutionChange
    }

    // Artist image init. Source-owned references may be fetched directly, but
    // a missing image does not fan out into an online scraper chain here.
    init(artistID: String, artistName: String, artworkReference: String? = nil,
         size: CGFloat? = nil, cornerRadius: CGFloat = 12,
         showsPlaceholder: Bool = true,
         onResolutionChange: @escaping (Bool) -> Void = { _ in }) {
        self.coverRef = artworkReference
        self.artistID = artistID
        self.artistName = artistName
        self.size = size
        self.cornerRadius = cornerRadius
        self.placeholderIcon = "music.mic"
        self.showsPlaceholder = showsPlaceholder
        self.onResolutionChange = onResolutionChange
    }

    var body: some View {
        coverContent
        .if(size != nil) { view in
            view.frame(width: size!, height: size!)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: loadTaskIdentity) {
            await loadImage(
                for: loadIdentity,
                taskIdentity: loadTaskIdentity
            )
        }
        .task(id: animationLoadIdentity) {
            await loadAnimatedArtwork(for: animationLoadIdentity)
        }
        .task(id: animatedArtworkExpiryIdentity) {
            await expireAnimatedArtwork(for: animatedArtworkExpiryIdentity)
        }
        .task(id: appleMusicArtworkLoadIdentity) {
            guard loadsHighResolution else { return }
            await resolveAppleMusicArtwork(for: appleMusicArtworkIdentity)
        }
        .onChange(of: hasResolvedArtwork) { _, isResolved in
            if isResolved { onResolutionChange(true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            guard shouldReload(after: note) else { return }
            let diskKey = sourceAnimationDiskKey
            Self.memoryCache.removeObject(forKey: cacheKey as NSString)
            clearAnimatedArtworkCache()
            performAnimationCacheMaintenance(
                keys: diskKey.isEmpty ? [] : [diskKey],
                removesOnlyNegativeEntries: false
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard ArtworkCacheReloadPolicy.shouldReload(
                cachedSongID: note.object as? String,
                displayedSongID: songID,
                hasResolvedImage: image != nil
            ) else { return }
            Self.failedLoadCache.removeObject(forKey: loadIdentity as NSString)
            clearAnimatedArtworkCache()
            cacheInvalidationRevision &+= 1
        }
        .onChange(of: NetworkMonitor.shared.pathGeneration) { _, _ in
            // A failed LAN URL belongs to the previous network context. Let
            // visible covers retry immediately through the newly selected route
            // instead of honoring the normal five-minute failure suppression.
            Self.failedLoadCache.removeObject(forKey: loadIdentity as NSString)
            let diskKeys = [sourceAnimationDiskKey, motionArtworkDiskKey].filter { !$0.isEmpty }
            performAnimationCacheMaintenance(
                keys: diskKeys,
                removesOnlyNegativeEntries: true
            )
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        )) { _ in
            animationPolicyRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )) { _ in
            animationPolicyRevision &+= 1
        }
        .onDisappear {
            clearAnimatedArtworkCache()
        }
    }

    /// body 拆出来 ── 直接写 if/else 链 SwiftUI ResultBuilder 类型推断超时,
    /// 抽成独立 ViewBuilder 编译能过。
    @ViewBuilder
    private var coverContent: some View {
        if let artwork = appleMusicArtwork {
            // Apple Music user library 的 song.artwork.url 返回 musicKit://
            // 自定义 scheme, URLSession 拉不到, 必须走 MusicKit 自家的
            // ArtworkImage SwiftUI view 让 framework 内部解码。
            //
            // ArtworkImage 必须给定具体 width/height, 它不像普通 Image 那样
            // .resizable() 会跟着容器伸缩 —— 给个固定大尺寸 (size==nil 时是
            // 200pt) 在弹性网格 cell 里就会撑成一张巨图, 把整个网格挤裂。
            // 用 GeometryReader 拿到容器真实边长再喂给它, 让 Apple Music 封面
            // 跟其它来源的封面一样填满 cell。ArtworkImage 自身按 display scale
            // 解码, 所以传点数即可, 不用再乘 scale。
            if let animatedArtworkData, let animatedArtworkDescriptor {
                AnimatedArtworkDataView(
                    data: animatedArtworkData,
                    descriptor: animatedArtworkDescriptor,
                    cacheKey: animatedArtworkContentKey ?? motionArtworkDiskKey,
                    presentationRole: presentationRole,
                    isVisible: isAnimationVisible,
                    requiresPlayback: animationRequiresPlayback,
                    isPlaying: isPlaying,
                    maximumPixelSize: animationMaximumPixelSize
                ) {
                    appleMusicArtworkView(artwork)
                }
            } else {
                appleMusicArtworkView(artwork)
            }
        } else if let image {
            if let animatedArtworkData, let animatedArtworkDescriptor {
                AnimatedArtworkDataView(
                    data: animatedArtworkData,
                    descriptor: animatedArtworkDescriptor,
                    cacheKey: animatedArtworkContentKey ?? animationCacheKey,
                    presentationRole: presentationRole,
                    isVisible: isAnimationVisible,
                    requiresPlayback: animationRequiresPlayback,
                    isPlaying: isPlaying,
                    maximumPixelSize: animationMaximumPixelSize
                ) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            } else {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        } else if showsPlaceholder {
            placeholderView
        } else {
            Color.clear
        }
    }

    private func appleMusicArtworkView(_ artwork: MusicKit.Artwork) -> some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height, 1)
            let requestSide = loadsHighResolution ? side : min(side, 96)
            ArtworkImage(artwork, width: requestSide, height: requestSide)
                .frame(width: requestSide, height: requestSide)
                .scaleEffect(side / requestSide)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// 当前歌如果是 Apple Music 来源, 从 songCache 拿 MusicKit.Artwork。
    /// cache miss 时返回 nil, 走 placeholder (用户再播这首会被 catalog/library
    /// lookup 填上 cache, 下次就有了)。
    private var appleMusicArtwork: MusicKit.Artwork? {
        guard sourceID == AppleMusicLibraryService.systemSourceID,
              let amID = filePath else { return nil }
        if resolvedAppleMusicArtworkID == amID, let resolvedAppleMusicArtwork {
            return resolvedAppleMusicArtwork
        }
        return AppServices.shared.appleMusicLibrary.cachedMusicKitSong(amID: amID)?.artwork
    }

    private var hasResolvedArtwork: Bool {
        appleMusicArtwork != nil || image != nil
    }

    private var appleMusicArtworkIdentity: String {
        guard sourceID == AppleMusicLibraryService.systemSourceID,
              let filePath, !filePath.isEmpty else { return "" }
        return filePath
    }

    private var appleMusicArtworkLoadIdentity: String {
        "\(appleMusicArtworkIdentity)|highResolution:\(loadsHighResolution)"
    }

    private func resolveAppleMusicArtwork(for identity: String) async {
        #if os(macOS)
        musicKitLoadingRequest = nil
        #endif
        guard !identity.isEmpty else {
            resolvedAppleMusicArtwork = nil
            resolvedAppleMusicArtworkID = nil
            if sourceID == AppleMusicLibraryService.systemSourceID {
                onResolutionChange(false)
            }
            return
        }
        if let cached = AppServices.shared.appleMusicLibrary.cachedMusicKitSong(amID: identity)?.artwork {
            resolvedAppleMusicArtwork = cached
            resolvedAppleMusicArtworkID = identity
            onResolutionChange(true)
            return
        }
        if resolvedAppleMusicArtworkID != identity {
            resolvedAppleMusicArtwork = nil
            resolvedAppleMusicArtworkID = nil
        }
        #if os(macOS)
        let request = UUID()
        musicKitLoadingRequest = request
        defer {
            if musicKitLoadingRequest == request { musicKitLoadingRequest = nil }
        }
        #endif
        let resolved = await AppServices.shared.appleMusicLibrary.musicKitSong(amID: identity)?.artwork
        guard !Task.isCancelled, appleMusicArtworkIdentity == identity else { return }
        resolvedAppleMusicArtwork = resolved
        resolvedAppleMusicArtworkID = resolved == nil ? nil : identity
        onResolutionChange(resolved != nil)
    }

    @ViewBuilder
    private var placeholderView: some View {
        #if os(macOS)
        if placeholderIcon == "music.note" || placeholderIcon == "square.stack" {
            MacDefaultArtwork(isLoading: loadsHighResolution
                && (imageLoadingRequest != nil || musicKitLoadingRequest != nil))
        } else {
            symbolicPlaceholder
        }
        #else
        symbolicPlaceholder
        #endif
    }

    private var symbolicPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [Color.gray.opacity(0.2), Color.gray.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: placeholderIcon)
                .font(.system(size: (size ?? 200) * 0.25))
                .foregroundStyle(.secondary)
        }
    }

    /// Composite cache key — different sized views share the underlying disk
    /// cache but get separate decoded PlatformImage entries so the 44pt list
    /// cell never has to display (or hold) the 1500×1500 original.
    private var cacheKey: String {
        cacheKey(for: bucket)
    }

    private func cacheKey(for bucket: Bucket) -> String {
        let suffix = "@\(bucket.rawValue)"
        if let albumID { return "album_\(albumID)\(suffix)" }
        if let artistID {
            return "artist_\(artistID)#\(coverRef ?? "")\(suffix)"
        }
        let songIdentity = ArtworkSourceRequestIdentity.key(
            songID: songID,
            artworkReference: coverRef,
            sourceID: sourceID,
            filePath: filePath,
            fileFormat: fileFormat?.rawValue,
            revision: String(revisionToken)
        ) ?? ""
        return songIdentity + suffix
    }

    private var loadIdentity: String {
        let refIdentity = coverRef ?? ""
        let sourceIdentity = "\(sourceID ?? "")|\(filePath ?? "")|\(fileFormat?.rawValue ?? "")"
        return "\(cacheKey)#ref\(refIdentity)#src\(sourceIdentity)#rev\(revisionToken)#inv\(cacheInvalidationRevision)"
    }

    private var artworkContentIdentity: String {
        "\(cacheKey(for: .full))#inv\(cacheInvalidationRevision)"
    }

    private var loadTaskIdentity: String {
        "\(loadIdentity)#highResolution\(loadsHighResolution)"
    }

    private var animationCacheKey: String {
        let components = [
            songID ?? "",
            sourceID ?? "",
            coverRef ?? "",
            filePath ?? "",
            albumID ?? "",
            albumTitle ?? "",
            artistName ?? "",
        ]
        return components.allSatisfy(\.isEmpty)
            ? ""
            : components.joined(separator: "\u{1F}")
    }

    private var sourceAnimationDiskKey: String {
        guard !animationCacheKey.isEmpty else { return "" }
        let sourceRevision = songID.flatMap { library.song(id: $0)?.revision } ?? ""
        return [
            "source-v1",
            animationCacheKey,
            sourceRevision,
            String(revisionToken),
        ].joined(separator: "\u{1F}")
    }

    private var motionArtworkLookupInput: MotionArtworkLookupInput? {
        guard presentationRole == .animatedHero,
              loadsHighResolution,
              isAnimationVisible,
              motionArtworkServiceEnabled,
              !normalizedMotionArtworkServiceEndpoint.isEmpty else { return nil }
        let song = songID.flatMap { library.song(id: $0) }
        let musicKitSong: MusicKit.Song? = {
            guard sourceID == AppleMusicLibraryService.systemSourceID,
                  let filePath, !filePath.isEmpty else { return nil }
            return AppServices.shared.appleMusicLibrary.cachedMusicKitSong(amID: filePath)
        }()
        let musicKitAlbum = musicKitSong?.albums?.first
        let appleAlbumIDs = MotionArtworkAppleAlbumIdentifiers(
            rawAlbumID: musicKitAlbum?.id.rawValue
        )
        let resolvedAlbumID = albumID ?? song?.albumID
        let resolvedTitle = albumTitle ?? musicKitAlbum?.title ?? song?.albumTitle
        let resolvedArtist = musicKitAlbum?.artistName
            ?? song?.albumArtistName
            ?? artistName
            ?? song?.artistName
        let localAlbumTrackCount = resolvedAlbumID.flatMap { albumID -> Int? in
            let album = library.visibleAlbums.first(where: { $0.id == albumID })
            let count = album?.songCount ?? 0
            return count > 0 ? count : nil
        }
        let resolvedTrackCount = albumTrackCount.flatMap { $0 > 0 ? $0 : nil }
            ?? musicKitAlbum?.trackCount
            ?? localAlbumTrackCount
        let resolvedYear = albumYear
            ?? musicKitAlbum?.releaseDate.map {
                Calendar(identifier: .gregorian).component(.year, from: $0)
            }
            ?? song?.year
        guard resolvedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              resolvedArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return MotionArtworkLookupInput(
            appleCatalogAlbumID: appleAlbumIDs.catalogID,
            upc: musicKitAlbum?.upc,
            albumArtist: resolvedArtist,
            albumTitle: resolvedTitle,
            releaseYear: resolvedYear,
            trackCount: resolvedTrackCount
        )
    }

    private var normalizedMotionArtworkServiceEndpoint: String {
        motionArtworkServiceEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var motionArtworkDiskKey: String {
        guard !normalizedMotionArtworkServiceEndpoint.isEmpty,
              let input = motionArtworkLookupInput else { return "" }
        return [
            "configured-service-v1",
            normalizedMotionArtworkServiceEndpoint,
            input.appleCatalogAlbumID ?? "",
            input.appleLibraryAlbumID ?? "",
            input.upc ?? "",
            input.isrcs.sorted().joined(separator: ","),
            input.musicBrainzReleaseID ?? "",
            input.albumArtist ?? "",
            input.albumTitle ?? "",
            input.releaseYear.map { String($0) } ?? "",
            input.trackCount.map { String($0) } ?? "",
            input.storefront ?? "",
        ].joined(separator: "\u{1F}")
    }

    private var animationLoadIdentity: String {
        guard presentationRole == .animatedHero else { return "" }
        return [
            loadIdentity,
            loadedIdentity ?? "",
            resolvedAppleMusicArtworkID ?? "",
            String(animatedArtworkEnabled),
            String(animatedArtworkUnmeteredOnly),
            String(motionArtworkServiceEnabled),
            normalizedMotionArtworkServiceEndpoint,
            sourceAnimationDiskKey,
            motionArtworkDiskKey,
            String(loadsHighResolution),
            String(isAnimationVisible),
            String(animationRequiresPlayback),
            String(isPlaying),
            String(reduceMotion),
            String(playAnimatedImages),
            String(scenePhase == .active),
            String(ProcessInfo.processInfo.isLowPowerModeEnabled),
            Self.thermalCondition(ProcessInfo.processInfo.thermalState).rawValue,
            String(NetworkMonitor.shared.pathGeneration),
            String(animationPolicyRevision),
            String(animationCacheMaintenanceGeneration),
        ].joined(separator: "|")
    }

    private var animatedArtworkExpiryIdentity: String {
        guard let animatedArtworkIdentity,
              let animatedArtworkExpiresAt else { return "" }
        return [
            animatedArtworkIdentity,
            String(animatedArtworkExpiresAt.timeIntervalSinceReferenceDate),
            animatedArtworkGeneration ?? "uncached",
        ].joined(separator: "|")
    }

    private var animationPlaybackPolicy: ArtworkAnimationPolicy {
        ArtworkAnimationPolicy(
            isEnabled: animatedArtworkEnabled,
            presentationRole: presentationRole,
            isVisible: loadsHighResolution && isAnimationVisible,
            isSceneActive: scenePhase == .active,
            requiresPlayback: animationRequiresPlayback,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            playAnimatedImages: playAnimatedImages,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalCondition: Self.thermalCondition(ProcessInfo.processInfo.thermalState)
        )
    }

    private var animationMaximumPixelSize: Int {
        switch bucket {
        case .thumb: Self.thumbMaxPixel
        case .card: Self.cardMaxPixel
        case .full: Self.fullMaxPixel
        }
    }

    @MainActor
    private func loadAnimatedArtwork(for identity: String) async {
        guard !identity.isEmpty,
              !animationCacheMaintenancePending,
              loadedIdentity == loadIdentity,
              animationPlaybackPolicy.shouldAnimate else {
            animatedArtworkData = nil
            animatedArtworkDescriptor = nil
            animatedArtworkIdentity = nil
            animatedArtworkContentKey = nil
            animatedArtworkExpiresAt = nil
            animatedArtworkGeneration = nil
            return
        }

        let key = animationCacheKey
        let diskKey = sourceAnimationDiskKey
        guard !key.isEmpty, !diskKey.isEmpty else { return }
        if animatedArtworkIdentity == diskKey,
           animatedArtworkData != nil,
           animatedArtworkDescriptor != nil {
            return
        }
        animatedArtworkData = nil
        animatedArtworkDescriptor = nil
        animatedArtworkIdentity = nil
        animatedArtworkContentKey = nil
        animatedArtworkExpiresAt = nil
        animatedArtworkGeneration = nil

        var sourceLookupSuppressed = false
        if let cached = try? await Self.animationDiskCache.lookup(forKey: diskKey) {
            guard !Task.isCancelled, animationLoadIdentity == identity else { return }
            switch cached {
            case .asset(let data):
                if let inspection = await Self.animatedInspection(
                    for: data,
                    cacheKey: diskKey
                ) {
                    guard await prepareStaticFallbackIfNeeded(
                        from: data,
                        for: identity
                    ) else { return }
                    guard !Task.isCancelled, animationLoadIdentity == identity else { return }
                    animatedArtworkData = data
                    animatedArtworkDescriptor = inspection.descriptor
                    animatedArtworkIdentity = diskKey
                    animatedArtworkContentKey = inspection.contentKey
                    return
                }
                try? await Self.animationDiskCache.removeValue(forKey: diskKey)
            case .negative:
                sourceLookupSuppressed = true
            }
        }

        if !sourceLookupSuppressed {
            // Lazily migrate an animation persisted by an older build in the
            // ordinary static mirror, then replace that mirror with frame 0.
            let legacyData = await Self.loadFromDiskCache(songID: songID, ref: coverRef)
            if let legacyData,
               let inspection = await Self.animatedInspection(
                for: legacyData,
                cacheKey: diskKey
               ) {
                guard !Task.isCancelled, animationLoadIdentity == identity else { return }
                _ = try? await Self.animationDiskCache.storeAsset(
                    legacyData,
                    forKey: diskKey
                )
                guard await prepareStaticFallbackIfNeeded(
                    from: legacyData,
                    for: identity
                ) else { return }
                guard !Task.isCancelled, animationLoadIdentity == identity else { return }
                animatedArtworkData = legacyData
                animatedArtworkDescriptor = inspection.descriptor
                animatedArtworkIdentity = diskKey
                animatedArtworkContentKey = inspection.contentKey
                return
            }
        }

        let network = NetworkMonitor.shared
        let fetchPolicy = ArtworkAnimationFetchPolicy(
            isEnabled: animatedArtworkEnabled,
            presentationRole: presentationRole,
            isVisible: loadsHighResolution && isAnimationVisible,
            isReachable: network.isReachable,
            isExpensive: network.isExpensive,
            isConstrained: network.isConstrained,
            isOnUnmeteredNetwork: network.isOnUnmeteredNetwork,
            unmeteredOnly: animatedArtworkUnmeteredOnly,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalCondition: Self.thermalCondition(ProcessInfo.processInfo.thermalState)
        )
        let ignoredGenericFolderCover = Self.shouldIgnoreGenericFolderCover(
            ref: coverRef,
            filePath: filePath
        )
        let effectiveAnimationRef = ignoredGenericFolderCover ? nil : coverRef
        let canFetchRemoteSource = fetchPolicy.shouldFetchRemoteAnimation
            && effectiveAnimationRef?.isEmpty == false
        let canReadEmbeddedSource = sourceID?.isEmpty == false
            && filePath?.isEmpty == false
        if !sourceLookupSuppressed,
           sourceID != AppleMusicLibraryService.systemSourceID,
           canFetchRemoteSource || canReadEmbeddedSource {
            let capturedManager = sourceManager
            let fetched = await Self.inFlightTracker.deduplicated(key: "animation:\(diskKey)") {
                await Self.loadOriginalAnimationFromSource(
                    ref: effectiveAnimationRef,
                    songID: songID,
                    sourceID: sourceID,
                    filePath: filePath,
                    fileFormat: fileFormat,
                    sourceManager: capturedManager,
                    allowsRemoteFetch: canFetchRemoteSource
                )
            }
            guard !Task.isCancelled, animationLoadIdentity == identity else { return }
            if let fetched,
               let inspection = await Self.animatedInspection(
                for: fetched,
                cacheKey: diskKey
               ) {
                guard !Task.isCancelled, animationLoadIdentity == identity else { return }
                _ = try? await Self.animationDiskCache.storeAsset(
                    fetched,
                    forKey: diskKey
                )
                guard await prepareStaticFallbackIfNeeded(
                    from: fetched,
                    for: identity
                ) else { return }
                guard !Task.isCancelled, animationLoadIdentity == identity else { return }
                animatedArtworkData = fetched
                animatedArtworkDescriptor = inspection.descriptor
                animatedArtworkIdentity = diskKey
                animatedArtworkContentKey = inspection.contentKey
                return
            }
            try? await Self.animationDiskCache.storeNegative(
                forKey: diskKey,
                expiresAt: Date().addingTimeInterval(
                    fetched == nil
                        ? Self.transientAnimationFailureTTL
                        : Self.staticAnimationNegativeTTL
                )
            )
        }

        guard hasResolvedArtwork else { return }
        await loadConfiguredMotionArtwork(
            for: identity,
            fetchPolicy: fetchPolicy
        )
    }

    @MainActor
    private func prepareStaticFallbackIfNeeded(
        from data: Data,
        for identity: String
    ) async -> Bool {
        if hasResolvedArtwork { return true }

        let capturedBucket = bucket
        let capturedCacheKey = cacheKey
        let fallbackTask = Task.detached(priority: .utility) {
            guard let mirror = ArtworkImageCompatibility.staticFirstFrameJPEG(
                from: data,
                maximumPixelSize: Self.fullMaxPixel
            ), let decoded = Self.decode(mirror, bucket: capturedBucket) else {
                return Optional<(Data, PlatformImage)>.none
            }
            return (mirror, decoded)
        }
        let fallback = await withTaskCancellationHandler {
            await fallbackTask.value
        } onCancel: {
            fallbackTask.cancel()
        }
        guard !Task.isCancelled,
              animationLoadIdentity == identity,
              let (mirror, decoded) = fallback else { return false }

        Self.memoryCache.setObject(
            decoded,
            forKey: capturedCacheKey as NSString,
            cost: Self.imageCost(decoded)
        )
        image = decoded
        Self.failedLoadCache.removeObject(forKey: loadIdentity as NSString)
        onResolutionChange(true)
        if let songID {
            await MetadataAssetStore.shared.cacheCover(mirror, forSongID: songID)
        }
        return !Task.isCancelled && animationLoadIdentity == identity
    }

    @MainActor
    private func loadConfiguredMotionArtwork(
        for identity: String,
        fetchPolicy: ArtworkAnimationFetchPolicy
    ) async {
        guard motionArtworkServiceEnabled,
              hasResolvedArtwork,
              let input = motionArtworkLookupInput,
              !motionArtworkDiskKey.isEmpty,
              let endpoint = URL(string: normalizedMotionArtworkServiceEndpoint),
              MotionArtworkEndpointClient.isValidEndpoint(endpoint) else {
            return
        }
        let diskKey = motionArtworkDiskKey

        let cacheLookupNow = Date()
        if let cached = try? await Self.animationDiskCache.detailedLookup(
            forKey: diskKey,
            now: cacheLookupNow
        ) {
            guard !Task.isCancelled, animationLoadIdentity == identity else { return }
            switch cached {
            case .asset(let record):
                let data = record.data
                if let inspection = await Self.animatedInspection(
                    for: data,
                    cacheKey: diskKey
                ) {
                    let expiration = record.expiresAt
                        ?? cacheLookupNow.addingTimeInterval(
                            Self.configuredMotionArtworkMaximumPositiveTTL
                        )
                    var generation = record.generation
                    if record.expiresAt == nil,
                       let refreshedGeneration = try? await Self.animationDiskCache.storeAsset(
                            data,
                            forKey: diskKey,
                            expiresAt: expiration
                       ) {
                        generation = refreshedGeneration
                    }
                    guard expiration > Date() else {
                        try? await Self.animationDiskCache.removeValue(forKey: diskKey)
                        break
                    }
                    guard !Task.isCancelled, animationLoadIdentity == identity else { return }
                    animatedArtworkData = data
                    animatedArtworkDescriptor = inspection.descriptor
                    animatedArtworkIdentity = diskKey
                    animatedArtworkContentKey = inspection.contentKey
                    animatedArtworkExpiresAt = expiration
                    animatedArtworkGeneration = generation
                    return
                }
                try? await Self.animationDiskCache.removeValue(forKey: diskKey)
            case .negative:
                return
            }
        }

        guard fetchPolicy.shouldFetchRemoteAnimation else { return }
        let now = Date()
        let allowExpensiveNetwork = !animatedArtworkUnmeteredOnly

        do {
            let resolution = try await MotionArtworkEndpointClient.shared.resolve(
                endpoint: endpoint,
                input: input,
                requestKey: diskKey,
                allowExpensiveNetwork: allowExpensiveNetwork
            )
            guard !Task.isCancelled, animationLoadIdentity == identity else { return }
            switch resolution {
            case .downloaded(let payload):
                let expiration = Self.configuredMotionArtworkExpiration(
                    providerExpiration: payload.asset.expiresAt,
                    now: Date()
                )
                guard expiration > Date() else {
                    try? await storeMotionArtworkNegative(
                        forKey: diskKey,
                        expiresAt: Date().addingTimeInterval(
                            Self.transientAnimationFailureTTL
                        )
                    )
                    return
                }
                let generation = try? await Self.animationDiskCache.storeAsset(
                    payload.data,
                    forKey: diskKey,
                    expiresAt: expiration
                )
                guard let contentKey = await Self.animationContentKey(
                    for: payload.data,
                    cacheKey: diskKey
                ) else { return }
                guard !Task.isCancelled, animationLoadIdentity == identity else { return }
                animatedArtworkData = payload.data
                animatedArtworkDescriptor = payload.descriptor
                animatedArtworkIdentity = diskKey
                animatedArtworkContentKey = contentKey
                animatedArtworkExpiresAt = expiration
                animatedArtworkGeneration = generation
            case .notFound, .ambiguous(_), .unsupported:
                try? await storeMotionArtworkNegative(
                    forKey: diskKey,
                    expiresAt: now.addingTimeInterval(Self.staticAnimationNegativeTTL)
                )
            case .temporarilyUnavailable(let retryAfter):
                try? await storeMotionArtworkNegative(
                    forKey: diskKey,
                    expiresAt: Self.transientNegativeExpiry(
                        retryAfter: retryAfter,
                        now: now
                    )
                )
            }
        } catch is CancellationError {
            return
        } catch let error as MotionArtworkEndpointClientError where error == .notAnimatedImage {
            try? await storeMotionArtworkNegative(
                forKey: diskKey,
                expiresAt: now.addingTimeInterval(Self.staticAnimationNegativeTTL)
            )
        } catch {
            try? await storeMotionArtworkNegative(
                forKey: diskKey,
                expiresAt: now.addingTimeInterval(Self.transientAnimationFailureTTL)
            )
        }
    }

    private func storeMotionArtworkNegative(
        forKey key: String,
        expiresAt: Date
    ) async throws {
        try await Self.animationDiskCache.storeNegative(
            forKey: key,
            expiresAt: expiresAt
        )
    }

    private nonisolated static func transientNegativeExpiry(
        retryAfter: Date?,
        now: Date
    ) -> Date {
        let fallback = now.addingTimeInterval(transientAnimationFailureTTL)
        guard let retryAfter, retryAfter > now else { return fallback }
        return min(retryAfter, now.addingTimeInterval(staticAnimationNegativeTTL))
    }

    private nonisolated static func configuredMotionArtworkExpiration(
        providerExpiration: Date?,
        now: Date
    ) -> Date {
        let localLimit = now.addingTimeInterval(configuredMotionArtworkMaximumPositiveTTL)
        guard let providerExpiration else { return localLimit }
        return min(providerExpiration, localLimit)
    }

    @MainActor
    private func expireAnimatedArtwork(for identity: String) async {
        guard !identity.isEmpty,
              animatedArtworkExpiryIdentity == identity,
              let cacheKey = animatedArtworkIdentity,
              let expiration = animatedArtworkExpiresAt else { return }

        let delay = max(0, expiration.timeIntervalSinceNow)
        do {
            try await Task.sleep(for: .seconds(delay))
        } catch {
            return
        }
        guard !Task.isCancelled,
              animatedArtworkExpiryIdentity == identity else { return }

        if let generation = animatedArtworkGeneration {
            _ = try? await Self.animationDiskCache.removeAsset(
                forKey: cacheKey,
                matchingGeneration: generation
            )
        }
        guard !Task.isCancelled,
              animatedArtworkExpiryIdentity == identity else { return }
        clearAnimatedArtworkCache()
        animationPolicyRevision &+= 1
    }

    private func clearAnimatedArtworkCache() {
        if let animatedArtworkContentKey {
            Self.animationDescriptorCache.removeObject(
                forKey: animatedArtworkContentKey as NSString
            )
        }
        animatedArtworkData = nil
        animatedArtworkDescriptor = nil
        animatedArtworkIdentity = nil
        animatedArtworkContentKey = nil
        animatedArtworkExpiresAt = nil
        animatedArtworkGeneration = nil
    }

    @MainActor
    private func performAnimationCacheMaintenance(
        keys: [String],
        removesOnlyNegativeEntries: Bool
    ) {
        animationCacheMaintenanceGeneration &+= 1
        let generation = animationCacheMaintenanceGeneration
        animationCacheMaintenancePending = true
        cacheInvalidationRevision &+= 1

        Task {
            for key in Set(keys) where !key.isEmpty {
                if removesOnlyNegativeEntries {
                    try? await Self.animationDiskCache.removeNegative(forKey: key)
                } else {
                    try? await Self.animationDiskCache.removeValue(forKey: key)
                }
            }
            guard !Task.isCancelled,
                  animationCacheMaintenanceGeneration == generation else { return }
            animationCacheMaintenancePending = false
            cacheInvalidationRevision &+= 1
        }
    }

    private nonisolated static func animatedInspection(
        for data: Data,
        cacheKey: String
    ) async -> AnimatedArtworkInspection? {
        guard let contentKey = await animationContentKey(
            for: data,
            cacheKey: cacheKey
        ) else { return nil }
        let key = contentKey as NSString
        if let cached = animationDescriptorCache.object(forKey: key) {
            return AnimatedArtworkInspection(
                descriptor: cached.descriptor,
                contentKey: contentKey
            )
        }
        let inspection = Task.detached(priority: .utility) {
            ArtworkImageCompatibility.inspect(data)
        }
        let descriptor = await withTaskCancellationHandler {
            await inspection.value
        } onCancel: {
            inspection.cancel()
        }
        guard let descriptor, descriptor.isAnimated else { return nil }
        animationDescriptorCache.setObject(ArtworkDescriptorBox(descriptor), forKey: key)
        return AnimatedArtworkInspection(
            descriptor: descriptor,
            contentKey: contentKey
        )
    }

    private nonisolated static func animationContentKey(
        for data: Data,
        cacheKey: String
    ) async -> String? {
        let hashing = Task.detached(priority: .utility) { () -> String? in
            guard !Task.isCancelled else { return nil }
            let key = "\(cacheKey)|\(data.count)|\(data.hashValue)"
            return Task.isCancelled ? nil : key
        }
        return await withTaskCancellationHandler {
            await hashing.value
        } onCancel: {
            hashing.cancel()
        }
    }

    private nonisolated static func thermalCondition(
        _ state: ProcessInfo.ThermalState
    ) -> ArtworkThermalCondition {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }

    private func shouldReload(after note: Notification) -> Bool {
        if note.userInfo?["all"] as? Bool == true { return true }

        let localTokens = Set([songID, coverRef, albumID, artistID].compactMap { $0 }.filter { !$0.isEmpty })
        guard !localTokens.isEmpty else { return false }

        var invalidatedTokens: [String] = []
        if let token = note.object as? String, !token.isEmpty {
            invalidatedTokens.append(token)
        }
        for key in ["songID", "oldRef", "newRef", "albumID", "artistID"] {
            if let token = note.userInfo?[key] as? String, !token.isEmpty {
                invalidatedTokens.append(token)
            }
        }
        if let tokens = note.userInfo?["tokens"] as? [String] {
            invalidatedTokens.append(contentsOf: tokens)
        }
        if let songIDs = note.userInfo?["songIDs"] as? [String] {
            invalidatedTokens.append(contentsOf: songIDs)
        }
        return invalidatedTokens.contains { localTokens.contains($0) }
    }

    private func loadImage(for identity: String, taskIdentity: String) async {
        #if os(macOS)
        imageLoadingRequest = nil
        #endif
        let key = cacheKey
        let contentIdentity = artworkContentIdentity
        if displayedArtworkIdentity != contentIdentity {
            displayedArtworkIdentity = contentIdentity
            loadedIdentity = nil
            if image != nil { image = nil }
        }

        guard !key.isEmpty else {
            if image != nil { image = nil }
            loadedIdentity = identity
            onResolutionChange(hasResolvedArtwork)
            return
        }

        guard loadedIdentity != identity || image == nil else { return }

        let cacheNSKey = key as NSString
        let failureNSKey = identity as NSString

        // Tier 1: Memory cache — already decoded, hand it to the View directly.
        if let cached = Self.memoryCache.object(forKey: cacheNSKey) {
            loadedIdentity = identity
            image = cached
            onResolutionChange(true)
            return
        }

        // During a container transition, never start a larger decode. Reuse
        // the best smaller memory entry (normally the mini player's thumb)
        // and keep it displayed while the requested bucket loads afterward.
        guard loadsHighResolution else {
            if image == nil, let cached = cachedLowerResolutionImage() {
                image = cached
                onResolutionChange(true)
            }
            return
        }

        if Self.hasRecentFailure(for: failureNSKey) {
            loadedIdentity = identity
            onResolutionChange(hasResolvedArtwork)
            return
        }

        // Capture everything the off-main path needs. SwiftUI Views are
        // @MainActor; the awaited helper is `nonisolated`, so the IO and
        // decode run on the cooperative pool, not the main thread.
        let capturedBucket = bucket
        let capturedRef = coverRef
        let capturedSongID = songID
        let capturedAlbumID = albumID
        let capturedAlbumTitle = albumTitle
        let capturedArtistID = artistID
        let capturedArtistName = artistName
        let capturedSourceID = sourceID
        let capturedFilePath = filePath
        let capturedFileFormat = fileFormat
        let capturedSourceManager = sourceManager

        #if os(macOS)
        let request = UUID()
        imageLoadingRequest = request
        defer {
            if imageLoadingRequest == request { imageLoadingRequest = nil }
        }
        #endif
        let decoded = await Self.loadAndDecode(
            cacheKey: key,
            bucket: capturedBucket,
            ref: capturedRef,
            songID: capturedSongID,
            albumID: capturedAlbumID,
            albumTitle: capturedAlbumTitle,
            artistID: capturedArtistID,
            artistName: capturedArtistName,
            sourceID: capturedSourceID,
            filePath: capturedFilePath,
            fileFormat: capturedFileFormat,
            sourceManager: capturedSourceManager,
            fetchDiscriminator: String(revisionToken),
            animationDiskKey: sourceAnimationDiskKey
        )
        guard !Task.isCancelled,
              loadIdentity == identity,
              loadTaskIdentity == taskIdentity else { return }
        loadedIdentity = identity
        if let decoded {
            image = decoded
        }
        if sourceID != AppleMusicLibraryService.systemSourceID || appleMusicArtworkIdentity.isEmpty {
            onResolutionChange(hasResolvedArtwork)
        }
        if decoded == nil {
            Self.failedLoadCache.setObject(NSDate(), forKey: failureNSKey)
        }
    }

    private func cachedLowerResolutionImage() -> PlatformImage? {
        let candidates: [Bucket]
        switch bucket {
        case .thumb:
            candidates = []
        case .card:
            candidates = [.thumb]
        case .full:
            candidates = [.card, .thumb]
        }
        for candidate in candidates {
            if let cached = Self.memoryCache.object(
                forKey: cacheKey(for: candidate) as NSString
            ) {
                return cached
            }
        }
        return nil
    }

    private static func hasRecentFailure(for key: NSString) -> Bool {
        guard let failedAt = failedLoadCache.object(forKey: key) else { return false }
        if abs(failedAt.timeIntervalSinceNow) < failedLoadCacheTTL {
            return true
        }
        failedLoadCache.removeObject(forKey: key)
        return false
    }

    // MARK: - Load + Decode (off-main)

    /// Shared app-layer image resolver used by playlist artwork. It intentionally
    /// goes through the same memory cache, MetadataAssetStore mirror, connector
    /// routing, bounded remote fetch, embedded extraction, and decode validation
    /// as an ordinary `CachedArtworkView`.
    nonisolated static func resolveImage(
        coverRef: String?,
        songID: String?,
        size: CGFloat,
        sourceID: String?,
        filePath: String?,
        fileFormat: AudioFormat?,
        sourceManager: SourceManager,
        cacheDiscriminator: String = ""
    ) async -> PlatformImage? {
        let bucket = bucket(for: size)
        let identityComponents = [
            songID ?? "",
            coverRef ?? "",
            sourceID ?? "",
            filePath ?? "",
            fileFormat?.rawValue ?? "",
        ]
        guard identityComponents.contains(where: { !$0.isEmpty }) else { return nil }
        let identity = identityComponents.joined(separator: "\u{1F}")
        let key = identity + "@playlist-\(bucket.rawValue)#\(cacheDiscriminator)"
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        return await loadAndDecode(
            cacheKey: key,
            bucket: bucket,
            ref: coverRef,
            songID: songID,
            albumID: nil,
            albumTitle: nil,
            artistID: nil,
            artistName: nil,
            sourceID: sourceID,
            filePath: filePath,
            fileFormat: fileFormat,
            sourceManager: sourceManager,
            fetchDiscriminator: cacheDiscriminator
        )
    }

    /// Top-level loader: tries memory cache, disk cache, then falls back to
    /// the source. Decodes via ImageIO, writes both layers of cache, returns
    /// the decoded PlatformImage. Runs on the cooperative pool.
    private nonisolated static func loadAndDecode(
        cacheKey: String,
        bucket: Bucket,
        ref: String?,
        songID: String?,
        albumID: String?,
        albumTitle: String?,
        artistID: String?,
        artistName: String?,
        sourceID: String?,
        filePath: String?,
        fileFormat: AudioFormat?,
        sourceManager: SourceManager,
        fetchDiscriminator: String = "",
        animationDiskKey: String? = nil
    ) async -> PlatformImage? {
        let ignoredGenericFolderCover = shouldIgnoreGenericFolderCover(ref: ref, filePath: filePath)
        let effectiveRef = ignoredGenericFolderCover ? nil : ref

        // Album path. A SwiftUI card must not implicitly launch JavaScript
        // searches against every enabled provider. Background/manual scraping
        // fills this cache; the deterministic song layer remains the fallback.
        if let albumID, albumTitle != nil {
            let data = await MetadataAssetStore.shared.cachedAlbumCover(forAlbumID: albumID)
            guard let data else { return nil }
            return finalize(data: data, bucket: bucket, cacheKey: cacheKey)
        }

        // Artist path — prefer the originating server, then fall back to the
        // existing name-based artwork provider. Source artwork gets its own
        // disk namespace so an older scraped image cannot mask a server image.
        if let artistID, artistName != nil {
            let data: Data?
            let owned = SourceOwnedArtworkReference.resolve(effectiveRef)
            let sourceCacheID = owned.map { _ in
                "\(artistID)\u{1F}\(effectiveRef ?? "")"
            }
            if let sourceCacheID,
               let cached = await MetadataAssetStore.shared.cachedArtistImage(forArtistID: sourceCacheID) {
                data = cached
            } else if let owned,
                      let sourceData = await sourceManager.artworkData(
                        for: owned.reference,
                        sourceID: owned.sourceID,
                        maximumBytes: 8 * 1024 * 1024
                      ) {
                if let sourceCacheID {
                    _ = await MetadataAssetStore.shared.storeArtistImage(
                        sourceData,
                        forArtistID: sourceCacheID
                    )
                }
                data = sourceData
            } else if let cached = await MetadataAssetStore.shared.cachedArtistImage(forArtistID: artistID) {
                data = cached
            } else {
                data = nil
            }
            guard let data else { return nil }
            return finalize(data: data, bucket: bucket, cacheKey: cacheKey)
        }

        // Song path. Apple Music artwork is always owned by MusicKit. Do not
        // reuse a legacy scraped cover cached under this Primuse song ID; the
        // official artwork resolver above will fill cold MusicKit caches.
        let isAppleMusic = sourceID == AppleMusicLibraryIdentity.sourceID
        if !isAppleMusic,
           let data = await loadFromDiskCache(
            songID: ignoredGenericFolderCover ? nil : songID,
            ref: effectiveRef
           ) {
            if let decoded = finalize(data: data, bucket: bucket, cacheKey: cacheKey) {
                // Older builds could persist an entire GIF/APNG/WebP in the
                // ordinary song-cover mirror. Migrate that entry lazily so
                // list and grid mounts only read a bounded first frame.
                if let songID,
                   isMultiFrameImage(data),
                   let animationDiskKey,
                   !animationDiskKey.isEmpty {
                    let preserved: Bool
                    do {
                        _ = try await animationDiskCache.storeAsset(
                            data,
                            forKey: animationDiskKey
                        )
                        preserved = true
                    } catch {
                        preserved = false
                    }
                    if preserved,
                       let staticMirror = staticCoverCacheData(from: data) {
                        await MetadataAssetStore.shared.cacheCover(
                            staticMirror,
                            forSongID: songID
                        )
                    }
                }
                return decoded
            }
            // Earlier builds accepted ImageIO's `.statusIncomplete`, so a
            // prematurely ended Jellyfin/Emby response could persist as a
            // half-black cover. Remove the bad song mirror and continue to the
            // source in this same load instead of returning the corrupted file
            // forever.
            if let songID {
                await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
            }
        }

        guard let fetchKey = ArtworkSourceRequestIdentity.key(
            songID: songID,
            artworkReference: effectiveRef,
            sourceID: sourceID,
            filePath: filePath,
            fileFormat: fileFormat?.rawValue,
            revision: fetchDiscriminator
        ) else { return nil }
        let fetched = await inFlightTracker.deduplicated(key: fetchKey) {
            await loadFromSource(
                ref: effectiveRef,
                songID: songID,
                sourceID: sourceID,
                filePath: filePath,
                fileFormat: fileFormat,
                sourceManager: sourceManager
            )
        }
        guard let fetched,
              let decoded = finalize(data: fetched, bucket: bucket, cacheKey: cacheKey) else {
            return nil
        }
        if isMultiFrameImage(fetched),
           let animationDiskKey,
           !animationDiskKey.isEmpty {
            _ = try? await animationDiskCache.storeAsset(
                fetched,
                forKey: animationDiskKey
            )
        }
        if let songID, let staticMirror = staticCoverCacheData(from: fetched) {
            await MetadataAssetStore.shared.cacheCover(staticMirror, forSongID: songID)
        }
        return decoded
    }

    /// Static artwork mirrors must never retain a multi-frame container. The
    /// animation original has its own bounded cache and is only read by a
    /// visible hero surface.
    private nonisolated static func staticCoverCacheData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        guard CGImageSourceGetCount(source) > 1 else { return data }
        return ArtworkImageCompatibility.staticFirstFrameJPEG(
            from: data,
            maximumPixelSize: fullMaxPixel
        )
    }

    private nonisolated static func isMultiFrameImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Decode + write to memory cache. NSCache is thread-safe so this can
    /// happen on the cooperative pool.
    private nonisolated static func finalize(
        data: Data,
        bucket: Bucket,
        cacheKey: String
    ) -> PlatformImage? {
        guard let decoded = decode(data, bucket: bucket) else { return nil }
        memoryCache.setObject(decoded, forKey: cacheKey as NSString, cost: imageCost(decoded))
        return decoded
    }

    // MARK: - Disk Cache

    private nonisolated static func loadFromDiskCache(songID: String?, ref: String?) async -> Data? {
        // 始终先尝试 songID-hash disk cache。它由刮削写回路径 (cacheCover) 维护,
        // 是 NAS sidecar 的可信 mirror。只要存在就用 —— 即使 ref 是 NAS path。
        //
        // 历史顾虑(已在写入侧解决):
        // 1. 旧的 trustedSource:false 污染 cache → 现在刮削写回会主动覆写 mirror,
        //    污染会被新数据顶掉。
        // 2. 用户在 NAS 上手动改 cover → 显式调用 invalidateCoverCache 触发重拉
        //    (e.g. 下次扫描检测到 sidecar mtime 变化)。
        //
        // 旧策略 "ref 含 / 就跳过 disk cache 强制走 NAS" 引发的问题:
        // - 每次 view 重 mount / NSCache 被清都触发 NAS round-trip
        // - NAS / CDN HTTP cache 命中旧封面就显示旧的, 用户切到后台再回来封面就
        //   "退回去了"
        // 信任本地 mirror 把这些都解决掉。
        if let songID {
            if let data = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) {
                return data
            }
        }
        // Legacy: old hashed filename in artworkDir。走 redirect-aware 读取。
        if let ref, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            return MetadataAssetStore.shared.readCoverData(named: ref)
        }
        return nil
    }

    private nonisolated static func shouldIgnoreGenericFolderCover(
        ref: String?,
        filePath: String?
    ) -> Bool {
        guard let ref, let filePath, ref.contains("/") else { return false }
        let refName = (ref as NSString).lastPathComponent
        let refBase = (refName as NSString).deletingPathExtension.lowercased()
        guard PrimuseConstants.folderCoverNames.contains(refBase) else { return false }

        let refDir = (ref as NSString).deletingLastPathComponent
        let songDir = (filePath as NSString).deletingLastPathComponent
        guard refDir.caseInsensitiveCompare(songDir) == .orderedSame else { return false }

        let dirName = (songDir as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["music", "音乐", "songs", "audio", "media", "downloads"].contains(dirName)
    }

    // MARK: - Source Fetch

    private nonisolated static func loadOriginalAnimationFromSource(
        ref: String?,
        songID: String?,
        sourceID: String?,
        filePath: String?,
        fileFormat: AudioFormat?,
        sourceManager: SourceManager,
        allowsRemoteFetch: Bool
    ) async -> Data? {
        let maximumBytes = ArtworkAnimationLimits.default.maximumCompressedBytes

        if allowsRemoteFetch, let ref, !ref.isEmpty {
            if let sourceID, !sourceID.isEmpty {
                if let data = await sourceManager.artworkData(
                    for: ref,
                    sourceID: sourceID,
                    maximumBytes: maximumBytes,
                    purpose: .originalAnimation
                ) {
                    return data
                }
            } else if ref.contains("://"), let url = URL(string: ref) {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                if let (data, response) = try? await TrustedHTTPTransport.data(
                    for: request,
                    session: sharedArtworkSession,
                    maxBytes: maximumBytes
                ), let http = response as? HTTPURLResponse,
                   (200...299).contains(http.statusCode),
                   !data.isEmpty {
                    return data
                }
            }
        }

        // Embedded artwork is read only from an already cached local audio
        // object, so it remains available without relaxing network policy.
        if let sourceID, !sourceID.isEmpty,
           let filePath, !filePath.isEmpty {
            let inferredFormat = fileFormat
                ?? AudioFormat.from(fileExtension: (filePath as NSString).pathExtension)
                ?? .mp3
            let localSong = Song(
                id: songID ?? "",
                title: "",
                fileFormat: inferredFormat,
                filePath: filePath,
                sourceID: sourceID,
                fileSize: 0,
                dateAdded: Date()
            )
            if let cachedURL = await sourceManager.cachedURLForBackgroundRead(for: localSong) {
                let metadata = await FileMetadataReader.read(from: cachedURL)
                if let data = metadata.coverArtData,
                   !data.isEmpty,
                   data.count <= maximumBytes {
                    return data
                }
            }
        }

        return nil
    }

    private nonisolated static func loadFromSource(
        ref: String?, songID: String?,
        sourceID: String?, filePath: String?,
        fileFormat: AudioFormat?,
        sourceManager: SourceManager
    ) async -> Data? {
        let maximumArtworkBytes = 8 * 1024 * 1024

        // Case 1: Any source-owned reference, including a historical absolute
        // LAN URL, stays inside the connector operation until its bytes arrive.
        // This lets adaptive routing observe the actual image failure and retry
        // the complete request through the alternate endpoint.
        if let ref, !ref.isEmpty, let sourceID {
            if let data = await sourceManager.artworkData(
                for: ref,
                sourceID: sourceID,
                maximumBytes: maximumArtworkBytes
            ) {
                return data
            }
        }

        // Case 2: A URL without source ownership (for example a scraper CDN)
        // cannot be rebased, but it is still bounded and response-validated.
        if sourceID == nil,
           let ref,
           ref.contains("://"),
           let url = URL(string: ref) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            if let (data, response) = try? await TrustedHTTPTransport.data(
                for: request,
                session: sharedArtworkSession,
                maxBytes: maximumArtworkBytes
            ),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               data.isEmpty == false {
                return data
            }
        }

        // Case 3: No ref — try embedded extraction from locally cached audio file only
        if let sourceID, let filePath {
            let inferredFormat = fileFormat
                ?? AudioFormat.from(fileExtension: (filePath as NSString).pathExtension)
                ?? .mp3
            let dummySong = Song(id: "", title: "", fileFormat: inferredFormat, filePath: filePath,
                                 sourceID: sourceID, fileSize: 0, dateAdded: Date())
            if let cachedURL = await sourceManager.cachedURLForBackgroundRead(for: dummySong) {
                let metadata = await FileMetadataReader.read(from: cachedURL)
                return metadata.coverArtData
            }
        }

        return nil
    }

    // MARK: - Decode

    /// Synchronous decode. Called from `loadAndDecode` on the cooperative
    /// pool, not the main thread. Uses ImageIO's thumbnail API which both
    /// downsamples and force-decodes the bitmap so SwiftUI never re-decodes
    /// at draw time.
    private nonisolated static func decode(_ data: Data, bucket: Bucket) -> PlatformImage? {
        guard ArtworkImageCompatibility.isCompleteImage(data),
              !ArtworkImageCompatibility.hasRedundantJPEGSampling(data) else {
            return nil
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let maxPixel: Int
        switch bucket {
        case .thumb:
            maxPixel = thumbMaxPixel
        case .card:
            maxPixel = cardMaxPixel
        case .full:
            maxPixel = fullMaxPixel
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return PlatformImage.fromCGImage(cg)
        }
        return nil
    }

    private nonisolated static func imageCost(_ image: PlatformImage) -> Int {
        if let cg = image.platformCGImage {
            return cg.bytesPerRow * cg.height
        }
        #if os(iOS)
        return (image.size.width * image.size.height * image.scale * image.scale * 4).finiteInt()
        #else
        return (image.size.width * image.size.height * 4).finiteInt()
        #endif
    }

    // MARK: - Static helpers

    static func invalidateCache(for fileName: String) {
        for bucket in ["thumb", "card", "full"] {
            memoryCache.removeObject(forKey: "\(fileName)@\(bucket)" as NSString)
            memoryCache.removeObject(forKey: "album_\(fileName)@\(bucket)" as NSString)
            memoryCache.removeObject(forKey: "artist_\(fileName)@\(bucket)" as NSString)
        }
        failedLoadCache.removeAllObjects()
        postArtworkInvalidation(token: fileName)
    }

    static func clearMemoryCache() {
        memoryCache.removeAllObjects()
        failedLoadCache.removeAllObjects()
        postArtworkInvalidation(token: nil, userInfo: ["all": true])
    }

    private static func postArtworkInvalidation(token: String?, userInfo: [AnyHashable: Any] = [:]) {
        if Thread.isMainThread {
            NotificationCenter.default.post(
                name: .primuseArtworkDidInvalidate,
                object: token,
                userInfo: userInfo
            )
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .primuseArtworkDidInvalidate,
                    object: token,
                    userInfo: userInfo
                )
            }
        }
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// Keeps rapid list scrolling from turning every briefly-visible row into a
/// simultaneous NAS/cloud request. Four source fetches leave room for the
/// foreground audio Range lane and make cancellation effective before hundreds
/// of off-screen covers have started network work.
private actor ArtworkFetchLimiter {
    private let maximumConcurrentFetches = 4
    private var activeFetches = 0

    func run(_ operation: @Sendable @escaping () async -> Data?) async -> Data? {
        guard await acquire() else { return nil }
        defer { activeFetches -= 1 }
        guard !Task.isCancelled else { return nil }
        return await operation()
    }

    private func acquire() async -> Bool {
        while activeFetches >= maximumConcurrentFetches {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        activeFetches += 1
        return true
    }
}

/// Deduplicates concurrent requests for the same cover and tracks each visible
/// view as a waiter. SwiftUI cancels `.task` when a row leaves the hierarchy;
/// when the last waiter disappears, cancel the shared source request instead
/// of letting a fast scroll download artwork for hundreds of off-screen rows.
private actor InFlightFetchTracker {
    private struct Entry {
        let task: Task<Data?, Never>
        var waiterIDs: Set<UUID>
    }

    private let limiter = ArtworkFetchLimiter()
    private var inFlight: [String: Entry] = [:]

    func deduplicated(key: String, fetch: @Sendable @escaping () async -> Data?) async -> Data? {
        let waiterID = UUID()
        let task: Task<Data?, Never>
        if var existing = inFlight[key] {
            existing.waiterIDs.insert(waiterID)
            inFlight[key] = existing
            task = existing.task
        } else {
            let limiter = limiter
            task = Task<Data?, Never> {
                await limiter.run(fetch)
            }
            inFlight[key] = Entry(task: task, waiterIDs: [waiterID])
        }

        return await withTaskCancellationHandler {
            let result = await task.value
            finishWaiter(waiterID, for: key, cancelIfUnused: false)
            return Task.isCancelled ? nil : result
        } onCancel: {
            Task { await self.finishWaiter(waiterID, for: key, cancelIfUnused: true) }
        }
    }

    private func finishWaiter(_ waiterID: UUID, for key: String, cancelIfUnused: Bool) {
        guard var entry = inFlight[key], entry.waiterIDs.remove(waiterID) != nil else {
            return
        }
        guard entry.waiterIDs.isEmpty else {
            inFlight[key] = entry
            return
        }
        inFlight[key] = nil
        if cancelIfUnused {
            entry.task.cancel()
        }
    }
}
