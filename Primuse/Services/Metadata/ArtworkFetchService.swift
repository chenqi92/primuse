import Foundation
import PrimuseKit
import UIKit

/// Fetches and caches album covers and artist images from online scrapers.
actor ArtworkFetchService {
    static let shared = ArtworkFetchService()
    private let assetStore = MetadataAssetStore.shared

    /// In-flight deduplication: albumID/artistID → Task
    private var inFlightAlbum: [String: Task<Data?, Never>] = [:]
    private var inFlightArtist: [String: Task<Data?, Never>] = [:]

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
            do {
                let scraper = MusicScraperFactory.create(for: config)
                let searchResult = try await scraper.search(query: query, artist: artistName, album: albumTitle, limit: 5)
                if let best = searchResult.items.first, let coverUrl = best.coverUrl {
                    if let data = try? await downloadImage(url: coverUrl, sourceConfig: config) {
                        return compressJPEG(data)
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func searchArtistImageOnline(artistName: String) async -> Data? {
        // Search via enabled scrapers, use cover from best match as artist image
        let settings = ScraperSettings.load()
        for config in settings.enabledSources where config.type.supportsCover {
            do {
                let scraper = MusicScraperFactory.create(for: config)
                let searchResult = try await scraper.search(query: artistName, artist: artistName, album: nil, limit: 3)
                if let best = searchResult.items.first, let coverUrl = best.coverUrl {
                    if let data = try? await downloadImage(url: coverUrl, sourceConfig: config) {
                        return compressJPEG(data)
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }


    // MARK: - Helpers

    private func downloadImage(url: String, sourceConfig: ScraperSourceConfig) async throws -> Data? {
        try await ConfigurableScraper.downloadResource(from: url, sourceConfig: sourceConfig)
    }

    private func compressJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data),
              let compressed = image.jpegData(compressionQuality: 0.85) else {
            return data
        }
        return compressed
    }
}
