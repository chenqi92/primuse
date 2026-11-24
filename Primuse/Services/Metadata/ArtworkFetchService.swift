import Foundation
import MusicKit
import PrimuseKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Fetches and caches album covers from online scrapers and artist photos from
/// the Apple Music catalog.
actor ArtworkFetchService {
    static let shared = ArtworkFetchService()
    private let assetStore: MetadataAssetStore
    private let artistPhotoLookup: @Sendable (String) async -> Data?
    private let isArtistLookupAuthorized: @Sendable () -> Bool
    private var artistRetryAfter: [String: ContinuousClock.Instant] = [:]
    /// Apple 目录里的歌手照片只在这次运行里留着，不写进磁盘。
    private var artistPhotos: [String: Data] = [:]
    private var artistPhotoOrder: [String] = []
    private static let artistPhotoLimit = 120

    init(
        assetStore: MetadataAssetStore = .shared,
        isArtistLookupAuthorized: @escaping @Sendable () -> Bool = { MusicAuthorization.currentStatus == .authorized },
        artistPhotoLookup: @escaping @Sendable (String) async -> Data? = { await ArtworkFetchService.searchArtistPhoto(artistName: $0) }
    ) {
        self.assetStore = assetStore
        self.isArtistLookupAuthorized = isArtistLookupAuthorized
        self.artistPhotoLookup = artistPhotoLookup
    }

    /// In-flight deduplication: albumID/artistID → Task
    private var inFlightAlbum: [String: Task<Data?, Never>] = [:]
    private var albumsReadingFromSource: Set<String> = []
    private var inFlightArtist: [String: Task<Data?, Never>] = [:]

    /// Reuse scraper sessions and parsing configuration across artwork lookups.
    /// Service quotas are shared by RequestExecutor, including manual requests.
    private var scraperCache: [String: any MusicScraper] = [:]
    private struct SourceFailureState {
        var consecutiveFailures = 0
        var retryAfter: ContinuousClock.Instant?
    }
    private var sourceFailures: [String: SourceFailureState] = [:]

    // MARK: - Album Cover

    enum LocalCoverRead: Sendable {
        case unavailable
        case inspected(Data?)
    }

    /// 补这张专辑的自动封面。先找本机已有的曲目图片，再读源里已知的图片，
    /// 最后按实际音频文件读内嵌封面。多碟/CUE 的重复引用和同一文件只读一次。
    func rereadAlbumCover(
        albumID: String, songs: [PrimuseKit.Song],
        isCurrent: @MainActor @Sendable (PrimuseKit.Song) -> Bool,
        readLocalFile: @Sendable (PrimuseKit.Song) async throws -> LocalCoverRead,
        readReference: @Sendable (PrimuseKit.Song, String) async throws -> Data?,
        readRemoteFile: @Sendable (PrimuseKit.Song) async throws -> Data?,
        installEmbeddedSongCover: (@Sendable (PrimuseKit.Song, Data) async -> Void)? = nil
    ) async throws -> Bool {
        guard albumsReadingFromSource.insert(albumID).inserted else { throw CancellationError() }
        defer { albumsReadingFromSource.remove(albumID) }
        let candidates = songs.filter { $0.albumID == albumID }
        func install(_ data: Data?, from song: PrimuseKit.Song) async throws -> Bool {
            try Task.checkCancellation()
            guard let data, ArtworkImageCompatibility.isCompleteImage(data),
                  let image = LibraryArtworkImageProcessor.process(data),
                  await isCurrent(song) else { return false }
            try Task.checkCancellation()
            guard await assetStore.storeAlbumCover(image, forAlbumID: albumID) != nil else {
                throw CocoaError(.fileWriteUnknown)
            }
            return true
        }

        let existingAlbumCover = await assetStore.cachedAlbumCover(forAlbumID: albumID)
            .map(ArtworkImageCompatibility.isCompleteImage) == true
        // 旧版本可能只留下专辑图。单曲专辑再次补读时，以歌曲原文件确认它自己的图。
        if existingAlbumCover {
            guard installEmbeddedSongCover != nil, candidates.count == 1, let song = candidates.first,
                  song.sourceID != AppleMusicLibraryIdentity.sourceID,
                  song.coverArtFileName?.isEmpty ?? true else { return true }
        }
        for song in candidates where !existingAlbumCover {
            try Task.checkCancellation()
            guard !SourceArtworkPolicy.shouldIgnoreGenericFolderCover(ref: song.coverArtFileName, filePath: song.filePath)
            else { continue }
            let cached = assetStore.cachedSourceCover(sourceID: song.sourceID, reference: song.coverArtFileName,
                                                       maximumPixels: 1536, allowsStale: true)
                ?? assetStore.displayCoverData(songID: song.id, reference: song.coverArtFileName)
            if try await install(cached, from: song) { return true }
        }

        var blockedSources: Set<String> = []
        var inspectedFiles: [String: Set<String>] = [:]
        var lastError: Error?
        enum CoverLocation { case localFile, reference, remoteFile }
        for location in [CoverLocation.localFile, .reference, .remoteFile] {
            var seen: [String: Set<String>] = [:]
            for song in candidates {
                try Task.checkCancellation()
                guard !blockedSources.contains(song.sourceID),
                      let path = location == .reference ? song.coverArtFileName : song.filePath, !path.isEmpty,
                      await isCurrent(song), seen[song.sourceID, default: []].insert(path).inserted else { continue }
                let data: Data?
                do {
                    switch location {
                    case .localFile:
                        guard case .inspected(let cover) = try await readLocalFile(song) else { continue }
                        inspectedFiles[song.sourceID, default: []].insert(path)
                        data = cover
                    case .reference: data = try await readReference(song, path)
                    case .remoteFile:
                        guard inspectedFiles[song.sourceID]?.contains(path) != true else { continue }
                        data = try await readRemoteFile(song)
                    }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    lastError = error
                    if location != .localFile, Self.blocksAlbumReads(error) { blockedSources.insert(song.sourceID) }
                    continue
                }
                guard let data else { continue }
                if existingAlbumCover {
                    guard ArtworkImageCompatibility.isCompleteImage(data), await isCurrent(song) else { continue }
                } else {
                    guard try await install(data, from: song) else { continue }
                }
                if location != .reference, song.sourceID != AppleMusicLibraryIdentity.sourceID,
                   song.coverArtFileName?.isEmpty ?? true {
                    await installEmbeddedSongCover?(song, data)
                }
                return true
            }
        }
        if existingAlbumCover { return true }
        if let lastError { throw lastError }
        return false
    }

    private static func blocksAlbumReads(_ error: Error) -> Bool {
        if let http = error as? HTTPResponseFailure {
            return http.isRateLimitFailure || http.statusCode == 401
        }
        switch error {
        case CloudDriveError.apiError(430, _), CloudDriveError.apiError(429, _), CloudDriveError.rateLimited,
             CloudDriveError.permissionDenied(.accountAccess),
             CloudDriveError.notAuthenticated,
             CloudDriveError.downloadQuotaExceeded: return true
        default: return false
        }
    }

    nonisolated static func embeddedAlbumCover(for song: PrimuseKit.Song, at url: URL) async throws -> Data? {
        if song.fileFormat == .flac {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var local = song
            local.fileSize = Int64(clamping: try handle.seekToEnd())
            if let cover = try await embeddedAlbumCover(for: local, fetch: { offset, length in
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: Int(length)) ?? Data()
            }) { return cover }
        }
        try Task.checkCancellation()
        return await FileMetadataReader.read(from: url).coverArtData
    }

    /// 远端手动读取复用格式的标签解析器。FLAC 可越过自动扫描的文件头上限，
    /// 尾置 moov 的 M4A 直接定位 moov；都不需要为找图下载整首音频。
    nonisolated static func embeddedAlbumCover(
        for song: PrimuseKit.Song, fetch: @Sendable (Int64, Int64) async throws -> Data
    ) async throws -> Data? {
        let size = song.fileSize
        let prefixLength = Int64(RemoteMetadataReadPolicy.initialHeadByteCount)
        var head = Data(try await fetch(0, size > 0 ? min(size, prefixLength) : prefixLength))
        guard !head.isEmpty else { return nil }
        let ext = RemoteMetadataInspectionPolicy.parserFileExtension(
            declaredFileExtension: song.fileFormat.rawValue, signature: AudioFileSignaturePolicy.inspect(head)
        )
        if ext == "flac",
           let cover = try await RemoteMetadataReadPolicy.readFLACArtwork(
               head: head, fileSize: size, fetch: fetch, decodePicture: FileMetadataReader.completeFLACPicture
           ) { return cover }
        let strategy = RemoteMetadataInspectionPolicy.tailStrategy(fileExtension: ext, isExplicitReread: true)
        if strategy == .isoBaseMedia, size > 0,
           let tags = try await ISOBaseMediaRangeReader.read(head: head, fileSize: size, fetch: fetch) {
            return await FileMetadataReader.read(from: tags, fileExtension: ext).coverArtData
        }
        let maxTag = 32 * 1024 * 1024
        if let tagLength = EmbeddedTagMetadataParser.id3TagByteCount(in: head),
           tagLength > head.count, tagLength <= maxTag, size <= 0 || tagLength <= size {
            head = try await RemoteMetadataReadPolicy.extendingHead(head, to: tagLength, fetch: fetch)
        }
        while let length = EmbeddedTagMetadataParser.expandedHeadReadSize(
            fileSize: size, currentData: head, fileExtension: ext
        ), length > head.count {
            head = try await RemoteMetadataReadPolicy.extendingHead(head, to: length, fetch: fetch)
        }
        let session = FileMetadataReader.RangeReadSession()
        if let cover = await session.read(from: head, fileExtension: ext).coverArtData { return cover }
        guard size > head.count else { return nil }
        if let tags = try await EmbeddedTagMetadataParser.waveMetadataFile(head: head, fileSize: size, fetch: fetch),
           let cover = await session.read(from: head, fileExtension: ext, id3TailData: tags).coverArtData {
            return cover
        }
        if strategy == .dsfOffset, let offset = EmbeddedTagMetadataParser.dsfMetadataOffset(in: head),
           offset >= 0, offset <= size - 10 {
            let header = try await fetch(offset, 10)
            guard let length = EmbeddedTagMetadataParser.id3TagByteCount(in: header),
                  length <= maxTag, Int64(length) <= size - offset else { return nil }
            let tag = try await fetch(offset, Int64(length))
            return await session.read(from: head, fileExtension: ext, id3TailData: tag).coverArtData
        }
        guard ext != "flac", [.apeV2, .mp3ID3, .containerID3, .genericEOF].contains(strategy) else { return nil }
        let count = min(size, Int64(RemoteMetadataReadPolicy.initialContainerTailByteCount))
        var tail = try await fetch(size - count, count)
        if let length = EmbeddedTagMetadataParser.expandedTailReadSize(
            fileSize: size, currentData: tail, fileExtension: ext
        ), length > tail.count {
            tail = try await fetch(size - Int64(length), Int64(length))
        }
        return await session.read(from: head, fileExtension: ext, id3TailData: tail).coverArtData
    }

    /// Fetch album cover: check cache → search online → store
    func fetchAlbumCover(albumTitle: String, artistName: String?, albumID: String) async -> Data? {
        // 1. Check disk cache
        if let cached = await assetStore.cachedAlbumCover(forAlbumID: albumID) {
            return cached
        }

        // 2. Deduplicate in-flight requests
        if let existing = inFlightAlbum[albumID] {
            return await existing.value
        }

        let task = Task<Data?, Never> {
            let data = await searchAlbumCoverOnline(albumTitle: albumTitle, artistName: artistName)
            guard let data, await installFetchedAlbumCover(data, albumID: albumID) else { return nil }
            return data
        }
        inFlightAlbum[albumID] = task
        let result = await task.value
        inFlightAlbum[albumID] = nil
        return result
    }

    func installFetchedAlbumCover(_ data: Data, albumID: String) async -> Bool {
        guard await assetStore.storeAlbumCover(data, forAlbumID: albumID) != nil else { return false }
        #if os(tvOS)
        await MainActor.run { TVArtworkRefresh.shared.refresh([albumID]) }
        #else
        await MainActor.run { CachedArtworkView.invalidateAlbumCover(albumID) }
        #endif
        return true
    }

    /// 只按已启用的刮削源在线搜一张专辑封面，不读也不写本机的专辑封面缓存。
    /// Apple TV 把它当作按文本搜索的最后一档：结果放进电视自己的模糊搜索缓存，
    /// 不能升格成「准确的专辑封面」而盖过歌曲自己的封面。
    func searchAlbumCover(albumTitle: String, artistName: String?) async -> Data? {
        await searchAlbumCoverOnline(albumTitle: albumTitle, artistName: artistName)
    }

    // MARK: - Artist Image

    /// Apple 目录里的歌手照片。只给曲库里有 Apple Music 歌曲的歌手用（`isAppleMusicArtist`），
    /// 只在内存里留着：不存盘、不写进文件标签，下次启动重新取。
    func fetchArtistImage(
        artistName: String,
        artistID: String,
        isAppleMusicArtist: Bool,
        forceRefresh: Bool = false
    ) async -> Data? {
        guard isAppleMusicArtist else { return nil }
        let cacheID = ArtistArtworkResolutionPolicy.appleMusicCacheID(artistID: artistID)
        if !forceRefresh, let cached = artistPhotos[cacheID] { return cached }
        guard isArtistLookupAuthorized(), !Task.isCancelled,
              !artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let existing = inFlightArtist[cacheID] { return await existing.value }
        if !forceRefresh, let retryAfter = artistRetryAfter[cacheID], retryAfter > .now { return nil }
        let task = Task<Data?, Never> {
            guard let data = await self.artistPhotoLookup(artistName),
                  ArtworkImageCompatibility.isCompleteImage(data) else { return nil }
            return data
        }
        inFlightArtist[cacheID] = task
        let result = await task.value
        inFlightArtist[cacheID] = nil
        if let result {
            rememberArtistPhoto(result, for: cacheID)
            artistRetryAfter[cacheID] = nil
            #if os(iOS) || os(macOS)
            await MainActor.run { CachedArtworkView.invalidateCache(for: artistID) }
            #endif
        } else {
            artistRetryAfter = artistRetryAfter.filter { $0.value > .now }
            artistRetryAfter[cacheID] = .now + .seconds(300)
        }
        return result
    }

    private func rememberArtistPhoto(_ data: Data, for cacheID: String) {
        artistPhotos[cacheID] = data
        artistPhotoOrder.removeAll { $0 == cacheID }
        artistPhotoOrder.append(cacheID)
        while artistPhotoOrder.count > Self.artistPhotoLimit {
            artistPhotos[artistPhotoOrder.removeFirst()] = nil
        }
    }

    func clearMemoryCache() {
        artistPhotos.removeAll(keepingCapacity: false)
        artistPhotoOrder.removeAll(keepingCapacity: false)
    }

    // MARK: - Online Search

    private func searchAlbumCoverOnline(albumTitle: String, artistName: String?) async -> Data? {
        // 专辑名或歌手不明(空的、「未知专辑」这类占位值)就不搜：只凭一个专辑名，
        // 搜出来的多半是别人的同名专辑。
        let placeholders: Set<String> = [String(localized: "unknown_artist")]
        guard let albumTitle = AlbumArtworkMatchPolicy.searchableName(albumTitle, placeholders: placeholders),
              let artistName = AlbumArtworkMatchPolicy.searchableName(artistName, placeholders: placeholders) else {
            return nil
        }
        let settings = ScraperSettings.load()
        let query = "\(artistName) \(albumTitle)"

        for config in settings.enabledSources where config.type.supportsCover {
            guard !isBackedOff(config.id) else { continue }
            do {
                let scraper = scraper(for: config)
                guard await !scraper.isCoolingDown() else { continue }
                let searchResult = try await scraper.search(query: query, artist: artistName, album: albumTitle, limit: 5)
                // 目录按相关度排序，第一条常常是无关的热门专辑：候选必须先对上专辑名
                // (两边都有歌手时还要对上歌手)，再在对得上的里面挑最可信的一条。
                guard let bestIndex = AlbumArtworkMatchPolicy.bestMatchIndex(
                    requestedAlbum: albumTitle,
                    requestedArtist: artistName,
                    candidates: searchResult.items.map { item -> (album: String?, artist: String?) in
                        (item.album ?? item.title, item.artist)
                    }
                ) else {
                    clearFailure(config.id)
                    continue
                }
                let best = searchResult.items[bestIndex]
                if
                   let coverUrl = try await resolveCoverURL(for: best, with: scraper) {
                    guard let data = try await downloadImage(url: coverUrl, sourceConfig: config) else {
                        throw ScraperError.networkError("Artwork download failed")
                    }
                    clearFailure(config.id)
                    return Self.compressJPEG(data)
                }
                clearFailure(config.id)
            } catch {
                // 调用方不要了(封面位滚出屏幕、页面关掉)不是源出了问题，不能让它进退避。
                if Self.isCancellation(error) { return nil }
                registerFailure(config.id, error: error)
                plog("⚠️ ArtworkFetch: album cover search failed for '\(query)' via \(config.type.displayName): \(error.localizedDescription)")
                continue
            }
        }
        return nil
    }

    /// 艺人图只用 Apple Music 目录里的艺人照片。刮削源只能按歌搜, 拿到的是某首歌的
    /// 专辑封面: 当成艺人图就是「按封面配艺人」, 名字互相包含就算对上时还会配到别人。
    /// 没有照片的艺人卡片照旧借自己一首歌的封面, 那至少是他自己的歌。
    private nonisolated static func searchArtistPhoto(artistName: String) async -> Data? {
        guard let url = await AppleMusicCatalogNeighbors.artistArtworkURL(
            matchingName: artistName,
            side: SubsonicArtworkPolicy.fullResolutionPixels
        ) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await TrustedHTTPTransport.data(
                for: request,
                session: artistPhotoSession,
                maxBytes: 8 * 1024 * 1024
            )
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  ArtworkImageCompatibility.isCompleteImage(data) else { return nil }
            return compressJPEG(data)
        } catch {
            if !Self.isCancellation(error) {
                plog("⚠️ ArtworkFetch: artist photo download failed for '\(artistName)': \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// 不带磁盘缓存的会话：系统的网络缓存也不留这些照片。
    private static let artistPhotoSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: - Helpers

    /// Return a cached scraper for the source, creating it on first use.
    private func scraper(for config: ScraperSourceConfig) -> any MusicScraper {
        if let cached = scraperCache[config.id] {
            return cached
        }
        let scraper = MusicScraperFactory.create(for: config)
        scraperCache[config.id] = scraper
        return scraper
    }

    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        // 刮削源把底层错误包成文字的写法,与 ScraperManager 的判断一致。
        if case ScraperError.networkError(let message) = error,
           message.localizedCaseInsensitiveContains("cancel") {
            return true
        }
        return false
    }

    private func isBackedOff(_ configID: String) -> Bool {
        guard let retryAfter = sourceFailures[configID]?.retryAfter else { return false }
        if retryAfter > ContinuousClock.now { return true }
        sourceFailures[configID]?.retryAfter = nil
        return false
    }

    private func clearFailure(_ configID: String) {
        sourceFailures.removeValue(forKey: configID)
    }

    private func registerFailure(_ configID: String, error: Error) {
        // Server cooldown is owned by the shared executor; never cap it here.
        if case .rateLimited = error as? ScraperError { return }
        var state = sourceFailures[configID] ?? SourceFailureState()
        state.consecutiveFailures += 1
        let exponent = min(state.consecutiveFailures - 1, 5)
        let delaySeconds = min(120, 5 * (1 << exponent))
        state.retryAfter = ContinuousClock.now + .seconds(delaySeconds)
        sourceFailures[configID] = state
    }

    private func downloadImage(url: String, sourceConfig: ScraperSourceConfig) async throws -> Data? {
        try await ConfigurableScraper.downloadResource(from: url, sourceConfig: sourceConfig)
    }

    private func resolveCoverURL(for item: ScraperSearchItem, with scraper: any MusicScraper) async throws -> String? {
        if let coverUrl = item.coverUrl, !coverUrl.isEmpty {
            return coverUrl
        }
        if let fallback = try await scraper.getCoverArt(externalId: item.externalId).first?.coverUrl,
           !fallback.isEmpty {
            return fallback
        }
        if let detailCover = try await scraper.getDetail(externalId: item.externalId)?.coverUrl,
           !detailCover.isEmpty {
            return detailCover
        }
        return nil
    }

    private nonisolated static func compressJPEG(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data),
              let compressed = image.jpegData(compressionQuality: 0.85) else {
            return data
        }
        return compressed
        #else
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let compressed = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return data
        }
        return compressed
        #endif
    }
}
