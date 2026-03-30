import SwiftUI
import PrimuseKit

/// Loads cover art with a unified three-tier strategy:
/// 1. Memory cache (NSCache, keyed by songID)
/// 2. Disk cache (MetadataAssetStore, keyed by songID)
/// 3. Source fetch (URL download / sidecar download / embedded extraction)
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

    private static let artworkDir: URL = MetadataAssetStore.shared.artworkDirectoryURL

    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    /// Deduplicates in-flight source fetches: multiple views requesting the same cover
    /// share a single network request instead of each fetching independently.
    private static let inFlightTracker = InFlightFetchTracker()

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

    private var cacheKey: String {
        if let albumID { return "album_\(albumID)" }
        if let artistID { return "artist_\(artistID)" }
        return songID ?? coverRef ?? ""
    }

    private func loadImage() {
        let key = cacheKey
        guard !key.isEmpty else { image = nil; return }

        let cacheNSKey = key as NSString

        // Tier 1: Memory cache
        if let cached = Self.memoryCache.object(forKey: cacheNSKey) {
            image = cached
            return
        }

        loadTask?.cancel()

        // Album/artist path — uses ArtworkFetchService
        if let albumID, let albumTitle {
            let capturedArtist = artistName
            loadTask = Task {
                // Check disk cache first
                if let data = await MetadataAssetStore.shared.cachedAlbumCover(forAlbumID: albumID),
                   let loaded = UIImage(data: data) {
                    Self.memoryCache.setObject(loaded, forKey: cacheNSKey, cost: data.count)
                    if !Task.isCancelled { image = loaded }
                    return
                }
                // Fetch online
                if let data = await ArtworkFetchService.shared.fetchAlbumCover(
                    albumTitle: albumTitle, artistName: capturedArtist, albumID: albumID
                ), let loaded = UIImage(data: data) {
                    Self.memoryCache.setObject(loaded, forKey: cacheNSKey, cost: data.count)
                    if !Task.isCancelled { image = loaded }
                }
            }
            return
        }

        if let artistID, let artistName {
            loadTask = Task {
                if let data = await MetadataAssetStore.shared.cachedArtistImage(forArtistID: artistID),
                   let loaded = UIImage(data: data) {
                    Self.memoryCache.setObject(loaded, forKey: cacheNSKey, cost: data.count)
                    if !Task.isCancelled { image = loaded }
                    return
                }
                if let data = await ArtworkFetchService.shared.fetchArtistImage(
                    artistName: artistName, artistID: artistID
                ), let loaded = UIImage(data: data) {
                    Self.memoryCache.setObject(loaded, forKey: cacheNSKey, cost: data.count)
                    if !Task.isCancelled { image = loaded }
                }
            }
            return
        }

        // Song-based path (existing logic)
        let capturedRef = coverRef
        let capturedSongID = songID
        let capturedSourceID = sourceID
        let capturedFilePath = filePath
        let capturedSourceManager = sourceManager

        loadTask = Task {
            // Tier 2: Disk cache (songID-based or legacy filename-based)
            if let data = await loadFromDiskCache(songID: capturedSongID, ref: capturedRef),
               let loaded = UIImage(data: data) {
                Self.memoryCache.setObject(loaded, forKey: cacheNSKey, cost: data.count)
                if !Task.isCancelled { image = loaded }
                return
            }

            // Tier 3: Source fetch (deduplicated — multiple views share one request)
            let fetchKey = capturedSongID ?? capturedRef ?? ""
            guard !fetchKey.isEmpty else { return }
            let data = await Self.inFlightTracker.deduplicated(key: fetchKey) {
                await self.loadFromSource(
                    ref: capturedRef,
                    songID: capturedSongID,
                    sourceID: capturedSourceID,
                    filePath: capturedFilePath,
                    sourceManager: capturedSourceManager
                )
            }
            if let data, let loaded = UIImage(data: data) {
                if let sid = capturedSongID {
                    await MetadataAssetStore.shared.cacheCover(data, forSongID: sid)
                }
                Self.memoryCache.setObject(loaded, forKey: cacheNSKey, cost: data.count)
                if !Task.isCancelled { image = loaded }
            }
        }
    }

    // MARK: - Disk Cache

    private func loadFromDiskCache(songID: String?, ref: String?) async -> Data? {
        // New: songID-based cache
        if let songID {
            if let data = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) {
                return data
            }
        }
        // Legacy: old hashed filename in artworkDir
        if let ref, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            let url = Self.artworkDir.appendingPathComponent(ref)
            return try? Data(contentsOf: url)
        }
        return nil
    }

    // MARK: - Source Fetch

    private func loadFromSource(
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

    // MARK: - Static helpers

    static func invalidateCache(for fileName: String) {
        memoryCache.removeObject(forKey: fileName as NSString)
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
