import Foundation
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
    private let assetStore = MetadataAssetStore.shared

    /// In-flight deduplication: albumID/artistID → Task
    private var inFlightAlbum: [String: Task<Data?, Never>] = [:]
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
            if let data {
                _ = await assetStore.storeAlbumCover(data, forAlbumID: albumID)
            }
            return data
        }
        inFlightAlbum[albumID] = task
        let result = await task.value
        inFlightAlbum[albumID] = nil
        return result
    }

    /// 只按已启用的刮削源在线搜一张专辑封面，不读也不写本机的专辑封面缓存。
    /// Apple TV 把它当作按文本搜索的最后一档：结果放进电视自己的模糊搜索缓存，
    /// 不能升格成「准确的专辑封面」而盖过歌曲自己的封面。
    func searchAlbumCover(albumTitle: String, artistName: String?) async -> Data? {
        await searchAlbumCoverOnline(albumTitle: albumTitle, artistName: artistName)
    }

    // MARK: - Artist Image

    /// Fetch artist image: check cache → Apple Music artist photo → store
    func fetchArtistImage(artistName: String, artistID: String) async -> Data? {
        // 1. Check disk cache
        if let cached = await assetStore.cachedArtistImage(forArtistID: artistID) {
            return cached
        }

        // 2. Deduplicate in-flight requests
        let requestID = artistID
        if let existing = inFlightArtist[requestID] {
            return await existing.value
        }

        let task = Task<Data?, Never> {
            let data = await searchArtistPhoto(artistName: artistName)
            if let data {
                _ = await assetStore.storeArtistImage(data, forArtistID: artistID)
            }
            return data
        }
        inFlightArtist[requestID] = task
        let result = await task.value
        inFlightArtist[requestID] = nil
        return result
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
                    return compressJPEG(data)
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
    private func searchArtistPhoto(artistName: String) async -> Data? {
        guard let url = await AppleMusicCatalogNeighbors.artistArtworkURL(
            matchingName: artistName,
            side: 600
        ) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await TrustedHTTPTransport.data(
                for: request,
                session: .shared,
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

    private func compressJPEG(_ data: Data) -> Data? {
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
