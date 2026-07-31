import Foundation
import PrimuseKit
#if os(iOS)
#if os(iOS)
import UIKit
#endif
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

    // MARK: - Artist Image

    /// Fetch artist image: check cache → search online → store
    func fetchArtistImage(artistName: String, artistID: String) async -> Data? {
        // 1. Check disk cache
        if let cached = await assetStore.cachedArtistImage(forArtistID: artistID) {
            return cached
        }

        // 2. Deduplicate in-flight requests
        if let existing = inFlightArtist[artistID] {
            return await existing.value
        }

        let task = Task<Data?, Never> {
            let data = await searchArtistImageOnline(artistName: artistName)
            if let data {
                _ = await assetStore.storeArtistImage(data, forArtistID: artistID)
            }
            return data
        }
        inFlightArtist[artistID] = task
        let result = await task.value
        inFlightArtist[artistID] = nil
        return result
    }

    // MARK: - Online Search

    private func searchAlbumCoverOnline(albumTitle: String, artistName: String?) async -> Data? {
        let settings = ScraperSettings.load()
        let query = [artistName, albumTitle].compactMap { $0 }.joined(separator: " ")

        for config in settings.enabledSources where config.type.supportsCover {
            guard !isBackedOff(config.id) else { continue }
            do {
                let scraper = scraper(for: config)
                let searchResult = try await scraper.search(query: query, artist: artistName, album: albumTitle, limit: 5)
                guard let best = searchResult.items.first(where: {
                    Self.isConfidentAlbumMatch($0, albumTitle: albumTitle, artistName: artistName)
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
                registerFailure(config.id, error: error)
                plog("⚠️ ArtworkFetch: album cover search failed for '\(query)' via \(config.type.displayName): \(error.localizedDescription)")
                continue
            }
        }
        return nil
    }

    private func searchArtistImageOnline(artistName: String) async -> Data? {
        // Search via enabled scrapers, use cover from best match as artist image
        let settings = ScraperSettings.load()
        for config in settings.enabledSources where config.type.supportsCover {
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

    private nonisolated static func isConfidentAlbumMatch(
        _ item: ScraperSearchItem,
        albumTitle: String,
        artistName: String?
    ) -> Bool {
        let requestedAlbum = normalized(albumTitle)
        let candidateAlbum = normalized(item.album ?? item.title)
        guard textMatches(requestedAlbum, candidateAlbum) else { return false }

        let requestedArtist = normalized(artistName)
        guard !requestedArtist.isEmpty else { return true }
        return textMatches(requestedArtist, normalized(item.artist))
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
        #if os(iOS)
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
