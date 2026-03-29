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
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let rootDirectory = caches.appendingPathComponent("primuse_metadata", isDirectory: true)
        artworkDirectory = rootDirectory.appendingPathComponent("artwork", isDirectory: true)
        lyricsDirectory = rootDirectory.appendingPathComponent("lyrics", isDirectory: true)
        artworkDirectoryURL = artworkDirectory
        lyricsDirectoryURL = lyricsDirectory

        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
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
