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
            Image(systemName: "music.note")
                .font(.system(size: (size ?? 200) * 0.25))
                .foregroundStyle(.secondary)
        }
    }

    private var cacheKey: String {
        songID ?? coverRef ?? ""
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

            // Tier 3: Source fetch
            if let data = await loadFromSource(
                ref: capturedRef,
                songID: capturedSongID,
                sourceID: capturedSourceID,
                filePath: capturedFilePath,
                sourceManager: capturedSourceManager
            ), let loaded = UIImage(data: data) {
                // Cache to disk for future
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
        // Case 1: URL reference (media server API)
        if let ref, ref.contains("://"), let url = URL(string: ref) {
            return try? await URLSession.shared.data(from: url).0
        }

        // Case 2: Sidecar path reference (NAS/protocol source)
        if let ref, ref.contains("/"), let sourceID {
            return await downloadSidecar(path: ref, sourceID: sourceID, sourceManager: sourceManager)
        }

        // Case 3: No explicit ref — only try embedded extraction from cached audio file
        // (Don't probe multiple sidecar patterns over network — that interferes with playback)
        if let sourceID, let filePath {
            // Only use already-cached audio file to extract embedded cover (no network)
            let dummySong = Song(id: "", title: "", fileFormat: .mp3, filePath: filePath,
                                 sourceID: sourceID, fileSize: 0, dateAdded: Date())
            if let cachedURL = sourceManager.cachedURL(for: dummySong) {
                let metadata = await FileMetadataReader.read(from: cachedURL)
                return metadata.coverArtData
            }
        }

        return nil
    }

    private func downloadSidecar(path: String, sourceID: String, sourceManager: SourceManager) async -> Data? {
        do {
            // Use auxiliary connector — independent from playback connection
            let dummySong = Song(id: "", title: "", fileFormat: .mp3, filePath: path,
                                 sourceID: sourceID, fileSize: 0, dateAdded: Date())
            let connector = try await sourceManager.auxiliaryConnector(for: dummySong)
            let localURL = try await connector.localURL(for: path)
            return try Data(contentsOf: localURL)
        } catch {
            plog("CachedArtworkView sidecar download failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func extractEmbeddedCover(sourceID: String, filePath: String, sourceManager: SourceManager) async -> Data? {
        do {
            let song = Song(id: "", title: "", fileFormat: .mp3, filePath: filePath,
                            sourceID: sourceID, fileSize: 0, dateAdded: Date())
            let resolvedURL: URL
            if let cached = sourceManager.cachedURL(for: song) {
                resolvedURL = cached
            } else {
                resolvedURL = try await sourceManager.resolveURL(for: song)
            }
            guard !Task.isCancelled else { return nil }
            let metadata = await FileMetadataReader.read(from: resolvedURL)
            return metadata.coverArtData
        } catch {
            plog("CachedArtworkView embedded extract failed: \(error.localizedDescription)")
            return nil
        }
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
