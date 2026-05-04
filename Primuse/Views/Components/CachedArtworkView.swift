import SwiftUI
import ImageIO
import PrimuseKit

/// Loads cover art with a unified three-tier strategy:
/// 1. Memory cache (NSCache, keyed by songID + size bucket)
/// 2. Disk cache (MetadataAssetStore, keyed by songID)
/// 3. Source fetch (URL download / sidecar download / embedded extraction)
///
/// Decoding runs off the main thread via ImageIO so list scrolling never
/// pays for `UIImage(data:)` lazy decode at draw time. Each cover is also
/// downsampled to one of two pixel buckets:
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

    @Environment(SourceManager.self) private var sourceManager
    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?

    nonisolated(unsafe) private static let artworkDir: URL = MetadataAssetStore.shared.artworkDirectoryURL

    /// Memory cache holds *already-decoded* UIImages. Cost is reported as
    /// real pixel byte count so the limit reflects actual memory pressure
    /// rather than the compressed source size.
    nonisolated(unsafe) private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
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
    /// resulting CGImage is fed to UIImage at scale 1, so cost stays small.
    private static let thumbMaxPixel: Int = 288

    /// Cap full-resolution decodes so a pathological 4000×4000 source can't
    /// blow the cache budget by itself. Larger than any device's hero art.
    private static let fullMaxPixel: Int = 1536

    // Backward compatible init — old call sites use coverFileName
    init(coverFileName: String?, size: CGFloat? = nil, cornerRadius: CGFloat = 12,
         sourceID: String? = nil, filePath: String? = nil) {
        self.coverRef = coverFileName
        self.size = size
        self.cornerRadius = cornerRadius
        self.sourceID = sourceID
        self.filePath = filePath
    }

    // New init with explicit songID
    init(coverRef: String?, songID: String, size: CGFloat? = nil, cornerRadius: CGFloat = 12,
         sourceID: String? = nil, filePath: String? = nil) {
        self.coverRef = coverRef
        self.songID = songID
        self.size = size
        self.cornerRadius = cornerRadius
        self.sourceID = sourceID
        self.filePath = filePath
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
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderView
            }
        }
        .if(size != nil) { view in
            view.frame(width: size!, height: size!)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear { loadImage() }
        .onChange(of: coverRef) { _, _ in loadImage() }
        .onChange(of: songID) { _, _ in loadImage() }
        .onChange(of: albumID) { _, _ in loadImage() }
        .onChange(of: artistID) { _, _ in loadImage() }
        .onDisappear { loadTask?.cancel() }
    }

    private var placeholderView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [Color(.systemGray5), Color(.systemGray4)],
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
    /// cache but get separate decoded UIImage entries so the 44pt list cell
    /// never has to display (or hold) the 1500×1500 original.
    private var cacheKey: String {
        let suffix = "@\(bucket.rawValue)"
        if let albumID { return "album_\(albumID)\(suffix)" }
        if let artistID { return "artist_\(artistID)\(suffix)" }
        return (songID ?? coverRef ?? "") + suffix
    }

    private func loadImage() {
        let key = cacheKey
        guard !key.isEmpty else { image = nil; return }

        let cacheNSKey = key as NSString

        // Tier 1: Memory cache — already decoded, hand it to the View directly.
        if let cached = Self.memoryCache.object(forKey: cacheNSKey) {
            image = cached
            return
        }

        loadTask?.cancel()

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

        loadTask = Task {
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
            guard let decoded, !Task.isCancelled else { return }
            image = decoded
        }
    }

    // MARK: - Load + Decode (off-main)

    /// Top-level loader: tries memory cache, disk cache, then falls back to
    /// the source. Decodes via ImageIO, writes both layers of cache, returns
    /// the decoded UIImage. Runs on the cooperative pool.
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
    ) async -> UIImage? {
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
        if let data = await loadFromDiskCache(songID: songID, ref: ref) {
            return finalize(data: data, bucket: bucket, cacheKey: cacheKey)
        }

        let fetchKey = songID ?? ref ?? ""
        guard !fetchKey.isEmpty else { return nil }
        let fetched = await inFlightTracker.deduplicated(key: fetchKey) {
            await loadFromSource(
                ref: ref,
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
    private static func finalize(data: Data, bucket: Bucket, cacheKey: String) -> UIImage? {
        guard let decoded = decode(data, bucket: bucket) else { return nil }
        memoryCache.setObject(decoded, forKey: cacheKey as NSString, cost: imageCost(decoded))
        return decoded
    }

    // MARK: - Disk Cache

    private static func loadFromDiskCache(songID: String?, ref: String?) async -> Data? {
        // 当 ref 是 source 端 sidecar 路径(NAS / https)时,NAS sidecar 才是
        // single source of truth —— 跳过 songID-hash cache。理由:
        // 1. 治本(MetadataService.trustedSource:false)只防"以后"刮削写脏 cache,
        //    历史污染的 cache 文件不会自动消失。
        // 2. cache mirror 和 sidecar 之间存在 stale 风险(用户在 NAS 上手动改过
        //    cover 文件,cache 不会感知)。
        // hash cache 仍用于无 NAS sidecar 引用的本地歌(embedded artwork)。
        let refIsRemote = (ref ?? "").contains("/") || (ref ?? "").contains("://")
        if let songID, !refIsRemote {
            if let data = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) {
                return data
            }
        }
        // Legacy: old hashed filename in artworkDir
        if let ref, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            let url = artworkDir.appendingPathComponent(ref)
            return try? Data(contentsOf: url)
        }
        return nil
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
    private static func decode(_ data: Data, bucket: Bucket) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            // Fallback for formats ImageIO can't open (rare): UIImage(data:)
            // still defers decode to first draw, but this is a graceful path.
            return UIImage(data: data)
        }
        let maxPixel = bucket == .thumb ? thumbMaxPixel : fullMaxPixel
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }

    private static func imageCost(_ image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    // MARK: - Static helpers

    static func invalidateCache(for fileName: String) {
        for bucket in ["thumb", "full"] {
            memoryCache.removeObject(forKey: "\(fileName)@\(bucket)" as NSString)
            memoryCache.removeObject(forKey: "album_\(fileName)@\(bucket)" as NSString)
            memoryCache.removeObject(forKey: "artist_\(fileName)@\(bucket)" as NSString)
        }
    }

    static func clearMemoryCache() {
        memoryCache.removeAllObjects()
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
