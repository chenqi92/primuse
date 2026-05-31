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
/// also downsampled to one of two pixel buckets:
/// - `thumb` (max 288px) for list-cell sized requests (size <= 96pt)
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
    /// For album/artist artwork fetched by ArtworkFetchService
    var albumID: String? = nil
    var albumTitle: String? = nil
    var artistID: String? = nil
    var artistName: String? = nil
    var placeholderIcon: String = "music.note"
    /// 当外部数据源 (e.g. AudioPlayerService.coverRevision) 想强制 view 重新加载,
    /// 但 coverRef / songID 这些 key 字段没变, onChange 不会触发时使用。
    /// 调用方传 player.coverRevision, 任意 bump 都会让本 view 重 loadImage。
    var revisionToken: Int = 0

    @Environment(SourceManager.self) private var sourceManager
    @State private var image: PlatformImage?
    @State private var loadedIdentity: String?
    @State private var cacheInvalidationRevision = 0


    /// Memory cache holds *already-decoded* PlatformImages. Cost is reported
    /// as real pixel byte count so the limit reflects actual memory pressure
    /// rather than the compressed source size.
    nonisolated(unsafe) private static let memoryCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Deduplicates in-flight source fetches: multiple views requesting the same cover
    /// share a single network request instead of each fetching independently.
    private static let inFlightTracker = InFlightFetchTracker()

    private enum Bucket: String, Sendable {
        case thumb, full
    }

    /// Anything visibly small (list rows, mini player, album cards under
    /// ~88pt) lands in the thumb bucket. 96 keeps a small headroom for
    /// occasional 80pt artist circles without bumping them to a full decode.
    private var bucket: Bucket {
        if let s = size, s <= 96 { return .thumb } else { return .full }
    }

    /// 96pt × 3x display scale. ImageIO downsamples in the GPU and the
    /// resulting CGImage is fed to PlatformImage at scale 1, so cost stays small.
    private static let thumbMaxPixel: Int = 288

    /// Cap full-resolution decodes so a pathological 4000×4000 source can't
    /// blow the cache budget by itself. Larger than any device's hero art.
    private static let fullMaxPixel: Int = 1536

    // Backward compatible init — old call sites use coverFileName
    init(coverFileName: String?, size: CGFloat? = nil, cornerRadius: CGFloat = 12,
         sourceID: String? = nil, filePath: String? = nil,
         revisionToken: Int = 0) {
        self.coverRef = coverFileName
        self.size = size
        self.cornerRadius = cornerRadius
        self.sourceID = sourceID
        self.filePath = filePath
        self.revisionToken = revisionToken
    }

    // New init with explicit songID
    init(coverRef: String?, songID: String, size: CGFloat? = nil, cornerRadius: CGFloat = 12,
         sourceID: String? = nil, filePath: String? = nil,
         revisionToken: Int = 0) {
        self.coverRef = coverRef
        self.songID = songID
        self.size = size
        self.cornerRadius = cornerRadius
        self.sourceID = sourceID
        self.filePath = filePath
        self.revisionToken = revisionToken
    }

    // Album cover init — fetches via ArtworkFetchService if not cached
    init(albumID: String, albumTitle: String, artistName: String?,
         size: CGFloat? = nil, cornerRadius: CGFloat = 12) {
        self.coverRef = nil
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.size = size
        self.cornerRadius = cornerRadius
        self.placeholderIcon = "square.stack"
    }

    // Artist image init — fetches via ArtworkFetchService if not cached
    init(artistID: String, artistName: String,
         size: CGFloat? = nil, cornerRadius: CGFloat = 12) {
        self.coverRef = nil
        self.artistID = artistID
        self.artistName = artistName
        self.size = size
        self.cornerRadius = cornerRadius
        self.placeholderIcon = "music.mic"
    }

    var body: some View {
        coverContent
        .if(size != nil) { view in
            view.frame(width: size!, height: size!)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: loadIdentity) {
            await loadImage(for: loadIdentity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            guard shouldReload(after: note) else { return }
            Self.memoryCache.removeObject(forKey: cacheKey as NSString)
            cacheInvalidationRevision += 1
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
            GeometryReader { geo in
                let side = max(geo.size.width, geo.size.height, 1)
                ArtworkImage(artwork, width: side, height: side)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .aspectRatio(1, contentMode: .fit)
        } else if let image {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholderView
        }
    }

    /// 当前歌如果是 Apple Music 来源, 从 songCache 拿 MusicKit.Artwork。
    /// cache miss 时返回 nil, 走 placeholder (用户再播这首会被 catalog/library
    /// lookup 填上 cache, 下次就有了)。
    private var appleMusicArtwork: MusicKit.Artwork? {
        guard sourceID == AppleMusicLibraryService.systemSourceID,
              let amID = filePath else { return nil }
        return AppServices.shared.appleMusicLibrary.cachedMusicKitSong(amID: amID)?.artwork
    }

    private var placeholderView: some View {
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
        let suffix = "@\(bucket.rawValue)"
        if let albumID { return "album_\(albumID)\(suffix)" }
        if let artistID { return "artist_\(artistID)\(suffix)" }
        return (songID ?? coverRef ?? "") + suffix
    }

    private var loadIdentity: String {
        let refIdentity = coverRef ?? ""
        let sourceIdentity = "\(sourceID ?? "")|\(filePath ?? "")"
        return "\(cacheKey)#ref\(refIdentity)#src\(sourceIdentity)#rev\(revisionToken)#inv\(cacheInvalidationRevision)"
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
        return invalidatedTokens.contains { localTokens.contains($0) }
    }

    private func loadImage(for identity: String) async {
        let key = cacheKey
        guard !key.isEmpty else {
            if image != nil { image = nil }
            loadedIdentity = identity
            return
        }

        guard loadedIdentity != identity || image == nil else { return }
        if loadedIdentity != identity, image != nil {
            image = nil
        }

        let cacheNSKey = key as NSString

        // Tier 1: Memory cache — already decoded, hand it to the View directly.
        if let cached = Self.memoryCache.object(forKey: cacheNSKey) {
            loadedIdentity = identity
            image = cached
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
        let capturedSourceManager = sourceManager

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
            sourceManager: capturedSourceManager
        )
        guard !Task.isCancelled, loadIdentity == identity else { return }
        loadedIdentity = identity
        if let decoded {
            image = decoded
        } else if image != nil {
            image = nil
        }
    }

    // MARK: - Load + Decode (off-main)

    /// Top-level loader: tries memory cache, disk cache, then falls back to
    /// the source. Decodes via ImageIO, writes both layers of cache, returns
    /// the decoded PlatformImage. Runs on the cooperative pool.
    private static func loadAndDecode(
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
        sourceManager: SourceManager
    ) async -> PlatformImage? {
        let ignoredGenericFolderCover = shouldIgnoreGenericFolderCover(ref: ref, filePath: filePath)
        let effectiveRef = ignoredGenericFolderCover ? nil : ref

        // Album path — ArtworkFetchService
        if let albumID, let albumTitle {
            let data: Data?
            if let cached = await MetadataAssetStore.shared.cachedAlbumCover(forAlbumID: albumID) {
                data = cached
            } else {
                data = await ArtworkFetchService.shared.fetchAlbumCover(
                    albumTitle: albumTitle, artistName: artistName, albumID: albumID
                )
            }
            guard let data else { return nil }
            return finalize(data: data, bucket: bucket, cacheKey: cacheKey)
        }

        // Artist path — ArtworkFetchService
        if let artistID, let artistName {
            let data: Data?
            if let cached = await MetadataAssetStore.shared.cachedArtistImage(forArtistID: artistID) {
                data = cached
            } else {
                data = await ArtworkFetchService.shared.fetchArtistImage(
                    artistName: artistName, artistID: artistID
                )
            }
            guard let data else { return nil }
            return finalize(data: data, bucket: bucket, cacheKey: cacheKey)
        }

        // Song path
        if let data = await loadFromDiskCache(songID: ignoredGenericFolderCover ? nil : songID, ref: effectiveRef) {
            return finalize(data: data, bucket: bucket, cacheKey: cacheKey)
        }

        let fetchKey = songID ?? effectiveRef ?? ""
        guard !fetchKey.isEmpty else { return nil }
        let fetched = await inFlightTracker.deduplicated(key: fetchKey) {
            await loadFromSource(
                ref: effectiveRef,
                songID: songID,
                sourceID: sourceID,
                filePath: filePath,
                sourceManager: sourceManager
            )
        }
        guard let fetched else { return nil }
        if let songID {
            await MetadataAssetStore.shared.cacheCover(fetched, forSongID: songID)
        }
        return finalize(data: fetched, bucket: bucket, cacheKey: cacheKey)
    }

    /// Decode + write to memory cache. NSCache is thread-safe so this can
    /// happen on the cooperative pool.
    private static func finalize(data: Data, bucket: Bucket, cacheKey: String) -> PlatformImage? {
        guard let decoded = decode(data, bucket: bucket) else { return nil }
        memoryCache.setObject(decoded, forKey: cacheKey as NSString, cost: imageCost(decoded))
        return decoded
    }

    // MARK: - Disk Cache

    private static func loadFromDiskCache(songID: String?, ref: String?) async -> Data? {
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

    private static func shouldIgnoreGenericFolderCover(ref: String?, filePath: String?) -> Bool {
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

    private static func loadFromSource(
        ref: String?, songID: String?,
        sourceID: String?, filePath: String?,
        sourceManager: SourceManager
    ) async -> Data? {
        // Case 1: URL reference (media server API — already a full URL)
        if let ref, ref.contains("://"), let url = URL(string: ref) {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
            return try? await session.data(from: url).0
        }

        // Case 2: Sidecar path on source — get a streaming URL (no file download needed)
        if let ref, ref.contains("/"), let sourceID {
            if let imageURL = await sourceManager.imageURL(for: ref, sourceID: sourceID) {
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 10
                let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                return try? await session.data(from: imageURL).0
            }
        }

        // Case 3: No ref — try embedded extraction from locally cached audio file only
        if let sourceID, let filePath {
            let dummySong = Song(id: "", title: "", fileFormat: .mp3, filePath: filePath,
                                 sourceID: sourceID, fileSize: 0, dateAdded: Date())
            if let cachedURL = sourceManager.cachedURL(for: dummySong) {
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
    private static func decode(_ data: Data, bucket: Bucket) -> PlatformImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            // Fallback for formats ImageIO can't open (rare): PlatformImage(data:)
            // still defers decode to first draw, but this is a graceful path.
            return PlatformImage(data: data)
        }
        let maxPixel = bucket == .thumb ? thumbMaxPixel : fullMaxPixel
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return PlatformImage.fromCGImage(cg)
        }
        return PlatformImage(data: data)
    }

    private static func imageCost(_ image: PlatformImage) -> Int {
        if let cg = image.platformCGImage {
            return cg.bytesPerRow * cg.height
        }
        #if os(iOS)
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        #else
        return Int(image.size.width * image.size.height * 4)
        #endif
    }

    // MARK: - Static helpers

    static func invalidateCache(for fileName: String) {
        for bucket in ["thumb", "full"] {
            memoryCache.removeObject(forKey: "\(fileName)@\(bucket)" as NSString)
            memoryCache.removeObject(forKey: "album_\(fileName)@\(bucket)" as NSString)
            memoryCache.removeObject(forKey: "artist_\(fileName)@\(bucket)" as NSString)
        }
        postArtworkInvalidation(token: fileName)
    }

    static func clearMemoryCache() {
        memoryCache.removeAllObjects()
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

/// Deduplicates concurrent fetch requests for the same key.
/// If two views request the same cover art simultaneously, only one network
/// request is made; the second waits for the first to complete and shares the result.
private actor InFlightFetchTracker {
    private var inFlight: [String: Task<Data?, Never>] = [:]

    func deduplicated(key: String, fetch: @Sendable @escaping () async -> Data?) async -> Data? {
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task<Data?, Never> { await fetch() }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }
}
