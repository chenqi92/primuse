import Foundation
import PrimuseKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Fetches and caches album covers and artist images from online scrapers.
actor ArtworkFetchService {
    static let shared = ArtworkFetchService()
    private let assetStore = MetadataAssetStore.shared

    /// In-flight deduplication: albumID/artistID → Task
    private var inFlightAlbum: [String: Task<Data?, Never>] = [:]
    private var inFlightArtist: [String: Task<Data?, Never>] = [:]

    /// Cached scraper instances keyed by source config id, so per-source rate
    /// limiting (lastRequestTime/minInterval lives on the scraper instance) is
    /// shared across requests instead of being reset on every fetch.
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

    /// Fetch artist image: check cache → search online → store
    func fetchArtistImage(
        artistName: String,
        artistID: String,
        allowBuiltInFallback: Bool = false
    ) async -> Data? {
        // 1. Check disk cache
        if let cached = await assetStore.cachedArtistImage(forArtistID: artistID) {
            return cached
        }

        // 2. Deduplicate in-flight requests
        let requestID = "\(artistID)|\(allowBuiltInFallback)"
        if let existing = inFlightArtist[requestID] {
            return await existing.value
        }

        let task = Task<Data?, Never> {
            let data = await searchArtistImageOnline(artistName: artistName, allowBuiltInFallback: allowBuiltInFallback)
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

    nonisolated static func artistLookupSources(
        settings: ScraperSettings,
        allowBuiltInFallback: Bool
    ) -> [ScraperSourceConfig] {
        let sources = settings.enabledSources.filter { $0.type.supportsCover }
        guard sources.isEmpty, allowBuiltInFallback else { return sources }
        // A manual lookup can opt in for this request without enabling any
        // source for automatic scraping or changing synchronized settings.
        return [.init(id: "manual-artist-itunes", type: .itunes, isEnabled: true, priority: 0)]
    }

    private func searchArtistImageOnline(artistName: String, allowBuiltInFallback: Bool) async -> Data? {
        let sources = Self.artistLookupSources(settings: ScraperSettings.load(), allowBuiltInFallback: allowBuiltInFallback)
        for config in sources {
            guard !isBackedOff(config.id) else { continue }
            do {
                let scraper = scraper(for: config)
                let searchResult = try await scraper.search(query: artistName, artist: artistName, album: nil, limit: 3)
                guard let best = searchResult.items.first(where: {
                    Self.isConfidentArtistMatch($0, artistName: artistName)
                }) else {
                    clearFailure(config.id)
                    continue
                }
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
                if Self.isCancellation(error) { return nil }
                registerFailure(config.id, error: error)
                plog("⚠️ ArtworkFetch: artist image search failed for '\(artistName)' via \(config.type.displayName): \(error.localizedDescription)")
                continue
            }
        }
        return nil
    }


    // MARK: - Helpers

    /// Return a cached scraper for the source, creating it on first use. Caching
    /// keeps each scraper's rate limiter alive across the many album/artist
    /// requests that Phase 2 enrichment issues back-to-back.
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
        var state = sourceFailures[configID] ?? SourceFailureState()
        state.consecutiveFailures += 1

        let delaySeconds: Int
        if case .rateLimited(let retryAfter) = error as? ScraperError {
            delaySeconds = max(5, min(300, retryAfter ?? 60))
        } else {
            let exponent = min(state.consecutiveFailures - 1, 5)
            delaySeconds = min(120, 5 * (1 << exponent))
        }
        state.retryAfter = ContinuousClock.now + .seconds(delaySeconds)
        sourceFailures[configID] = state
    }

    private nonisolated static func isConfidentArtistMatch(
        _ item: ScraperSearchItem,
        artistName: String
    ) -> Bool {
        let requested = normalized(artistName)
        guard !requested.isEmpty else { return false }
        return textMatches(requested, normalized(item.artist))
            || textMatches(requested, normalized(item.title))
    }

    private nonisolated static func textMatches(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }

    private nonisolated static func normalized(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
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
