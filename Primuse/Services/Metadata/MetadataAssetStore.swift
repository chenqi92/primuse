import CryptoKit
import Foundation
import PrimuseKit

actor MetadataAssetStore {
    static let shared = MetadataAssetStore()

    private let artworkDirectory: URL
    private let lyricsDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Public directory URLs for external consumers (CachedArtworkView, ThemeService, etc.)
    nonisolated let artworkDirectoryURL: URL
    nonisolated let lyricsDirectoryURL: URL

    private init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let rootDirectory = appSupport.appendingPathComponent("Primuse/MetadataAssets", isDirectory: true)
        artworkDirectory = rootDirectory.appendingPathComponent("artwork", isDirectory: true)
        lyricsDirectory = rootDirectory.appendingPathComponent("lyrics", isDirectory: true)
        artworkDirectoryURL = artworkDirectory
        lyricsDirectoryURL = lyricsDirectory

        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)

        // One-time migration from old Caches location
        let oldRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("primuse_metadata", isDirectory: true)
        migrateIfNeeded(from: oldRoot, fileManager: fileManager)
    }

    /// Migrate files from old Caches path to new Application Support path.
    private nonisolated func migrateIfNeeded(from oldRoot: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: oldRoot.path) else { return }
        let oldArtwork = oldRoot.appendingPathComponent("artwork")
        let oldLyrics = oldRoot.appendingPathComponent("lyrics")

        for (src, dst) in [(oldArtwork, artworkDirectory), (oldLyrics, lyricsDirectory)] {
            guard let files = try? fileManager.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let target = dst.appendingPathComponent(file.lastPathComponent)
                if !fileManager.fileExists(atPath: target.path) {
                    try? fileManager.moveItem(at: file, to: target)
                }
            }
        }
        // Remove old directory after migration
        try? fileManager.removeItem(at: oldRoot)
    }

    func storeCover(_ data: Data, for key: String) -> String? {
        let fileName = hashedFileName(for: key, pathExtension: "jpg")
        let fileURL = artworkDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    func coverData(named fileName: String?) -> Data? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return try? Data(contentsOf: artworkDirectory.appendingPathComponent(fileName))
    }

    func storeLyrics(_ lines: [LyricLine], for key: String) -> String? {
        guard let data = try? encoder.encode(lines) else { return nil }
        let fileName = hashedFileName(for: key, pathExtension: "json")
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    func lyrics(named fileName: String?) -> [LyricLine]? {
        guard let fileName, !fileName.isEmpty,
              let data = try? Data(contentsOf: lyricsDirectory.appendingPathComponent(fileName)) else {
            return nil
        }
        return try? decoder.decode([LyricLine].self, from: data)
    }

    // MARK: - Song ID-based cache (new architecture: source ref + local cache)

    /// Cache cover art data using song ID as the cache key.
    func cacheCover(_ data: Data, forSongID songID: String) {
        let fileName = hashedFileName(for: songID, pathExtension: "jpg")
        let fileURL = artworkDirectory.appendingPathComponent(fileName)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Read cached cover art by song ID.
    func cachedCoverData(forSongID songID: String) -> Data? {
        let fileName = hashedFileName(for: songID, pathExtension: "jpg")
        return try? Data(contentsOf: artworkDirectory.appendingPathComponent(fileName))
    }

    /// Cache lyrics using song ID as the cache key.
    func cacheLyrics(_ lines: [LyricLine], forSongID songID: String) {
        guard let data = try? encoder.encode(lines) else { return }
        let fileName = hashedFileName(for: songID, pathExtension: "json")
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Read cached lyrics by song ID.
    func cachedLyrics(forSongID songID: String) -> [LyricLine]? {
        let fileName = hashedFileName(for: songID, pathExtension: "json")
        guard let data = try? Data(contentsOf: lyricsDirectory.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode([LyricLine].self, from: data)
    }

    /// Remove cached cover art for a specific song (e.g., after scraping updates it).
    func invalidateCoverCache(forSongID songID: String) {
        let fileName = hashedFileName(for: songID, pathExtension: "jpg")
        try? FileManager.default.removeItem(at: artworkDirectory.appendingPathComponent(fileName))
    }

    /// Check if a reference is an old-style local hashed filename (for migration).
    nonisolated func isLegacyLocalRef(_ ref: String) -> Bool {
        !ref.contains("/") && !ref.contains("://") && ref.hasSuffix(".jpg") || ref.hasSuffix(".json")
    }

    func clearAll() {
        clear(directory: artworkDirectory)
        clear(directory: lyricsDirectory)
    }

    func cacheSize() -> Int64 {
        directorySize(artworkDirectory) + directorySize(lyricsDirectory)
    }

    private func clear(directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }

        for fileURL in contents {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func directorySize(_ directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }

        return contents.reduce(0) { total, fileURL in
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    private func hashedFileName(for key: String, pathExtension: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let base = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(base).\(pathExtension)"
    }

    // MARK: - Synchronous helpers (nonisolated, for use from non-async contexts)

    nonisolated func expectedCoverFileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let base = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(base).jpg"
    }

    nonisolated func expectedLyricsFileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let base = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(base).json"
    }

    nonisolated func storeCoverSync(_ data: Data, for key: String) {
        let fileName = expectedCoverFileName(for: key)
        let fileURL = artworkDirectory.appendingPathComponent(fileName)
        try? data.write(to: fileURL, options: .atomic)
    }

    nonisolated func storeLyricsSync(_ lines: [LyricLine], for key: String) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(lines) else { return }
        let fileName = expectedLyricsFileName(for: key)
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        try? data.write(to: fileURL, options: .atomic)
    }
}
