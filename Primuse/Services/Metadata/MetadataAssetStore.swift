import CryptoKit
import Foundation
import PrimuseKit

actor MetadataAssetStore {
    static let shared = MetadataAssetStore()

    private let artworkDirectory: URL
    private let lyricsDirectory: URL
    private let albumArtworkDirectory: URL
    private let artistArtworkDirectory: URL
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
        albumArtworkDirectory = rootDirectory.appendingPathComponent("artwork/album", isDirectory: true)
        artistArtworkDirectory = rootDirectory.appendingPathComponent("artwork/artist", isDirectory: true)
        artworkDirectoryURL = artworkDirectory
        lyricsDirectoryURL = lyricsDirectory

        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: albumArtworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artistArtworkDirectory, withIntermediateDirectories: true)

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
        do {
            return try Data(contentsOf: artworkDirectory.appendingPathComponent(fileName))
        } catch {
            plog("MetadataAssetStore: failed to read cover '\(fileName)': \(error.localizedDescription)")
            return nil
        }
    }

    /// 写歌词到本地缓存。
    ///
    /// - parameter force: 用户动作 (刮削) 传 true, **任何级别都覆盖**;
    ///                    后台自动 (扫描 USLT / Tier3 stale-while-revalidate)
    ///                    传 false, **拒绝把已有的字级降级成行级**, 但允许
    ///                    同级别刷新内容 (字→字 / 行→行)。
    ///
    /// 语义: 用户刮削结果 = 最高权威, 自动路径不能擅自降级用户的字级数据。
    /// 但允许用户手动改 NAS .lrc 后被自动路径同步 (字→字 / 行→行 都允许)。
    func storeLyrics(_ lines: [LyricLine], for key: String, force: Bool = false) -> String? {
        let fileName = hashedFileName(for: key, pathExtension: "json")
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        if !force && wouldDowngrade(at: fileURL, against: lines) {
            plog("📝 storeLyrics skip downgrade key=\(key.prefix(8))")
            return fileName
        }
        guard let data = try? encoder.encode(lines) else { return nil }
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    /// 「会不会让现存的字级缓存被降级成行级」—— true 表示该跳过本次写入。
    /// 同级别写入 (字→字 / 行→行) 永远允许 (能刷新内容)。
    nonisolated private func wouldDowngrade(at url: URL, against incoming: [LyricLine]) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let existing = try? JSONDecoder().decode([LyricLine].self, from: data) else {
            return false
        }
        let existingHasSyllables = existing.contains(where: { $0.isWordLevel })
        let incomingHasSyllables = incoming.contains(where: { $0.isWordLevel })
        return existingHasSyllables && !incomingHasSyllables
    }

    func lyrics(named fileName: String?) -> [LyricLine]? {
        guard let fileName, !fileName.isEmpty else { return nil }
        do {
            let data = try Data(contentsOf: lyricsDirectory.appendingPathComponent(fileName))
            return try decoder.decode([LyricLine].self, from: data)
        } catch {
            plog("MetadataAssetStore: failed to read lyrics '\(fileName)': \(error.localizedDescription)")
            return nil
        }
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
    ///
    /// - parameter force: 用户动作 (刮削 sidecar 镜像回写) 传 true; 自动路径
    ///                    (Tier3 stale-while-revalidate) 传 false 拒绝降级。
    /// - returns: true 表示写入了 / false 跳过 (downgrade 或编码失败)。调用
    ///   方根据返回值决定要不要更新 UI —— skip 了就 UI 保持现状。
    @discardableResult
    func cacheLyrics(_ lines: [LyricLine], forSongID songID: String, force: Bool = false) -> Bool {
        let fileName = hashedFileName(for: songID, pathExtension: "json")
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        if !force && wouldDowngrade(at: fileURL, against: lines) {
            plog("📝 cacheLyrics skip downgrade songID=\(songID.prefix(8))")
            return false
        }
        guard let data = try? encoder.encode(lines) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
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

    /// Remove cached lyrics for a specific song.
    func invalidateLyricsCache(forSongID songID: String) {
        let fileName = hashedFileName(for: songID, pathExtension: "json")
        try? FileManager.default.removeItem(at: lyricsDirectory.appendingPathComponent(fileName))
    }

    /// Check if a reference is an old-style local hashed filename (for migration).
    nonisolated func isLegacyLocalRef(_ ref: String) -> Bool {
        !ref.contains("/") && !ref.contains("://") && ref.hasSuffix(".jpg") || ref.hasSuffix(".json")
    }

    // MARK: - Album artwork

    func storeAlbumCover(_ data: Data, forAlbumID albumID: String) -> String? {
        let fileName = hashedFileName(for: "album_\(albumID)", pathExtension: "jpg")
        let fileURL = albumArtworkDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileName
        } catch { return nil }
    }

    func cachedAlbumCover(forAlbumID albumID: String) -> Data? {
        let fileName = hashedFileName(for: "album_\(albumID)", pathExtension: "jpg")
        return try? Data(contentsOf: albumArtworkDirectory.appendingPathComponent(fileName))
    }

    nonisolated func hasAlbumCover(forAlbumID albumID: String) -> Bool {
        let fileName = hashedFileName(for: "album_\(albumID)", pathExtension: "jpg")
        return FileManager.default.fileExists(atPath: albumArtworkDirectory.appendingPathComponent(fileName).path)
    }

    // MARK: - Artist artwork

    func storeArtistImage(_ data: Data, forArtistID artistID: String) -> String? {
        let fileName = hashedFileName(for: "artist_\(artistID)", pathExtension: "jpg")
        let fileURL = artistArtworkDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileName
        } catch { return nil }
    }

    func cachedArtistImage(forArtistID artistID: String) -> Data? {
        let fileName = hashedFileName(for: "artist_\(artistID)", pathExtension: "jpg")
        return try? Data(contentsOf: artistArtworkDirectory.appendingPathComponent(fileName))
    }

    nonisolated func hasArtistImage(forArtistID artistID: String) -> Bool {
        let fileName = hashedFileName(for: "artist_\(artistID)", pathExtension: "jpg")
        return FileManager.default.fileExists(atPath: artistArtworkDirectory.appendingPathComponent(fileName).path)
    }

    // MARK: - hashedFileName needs to be nonisolated for sync callers

    nonisolated private func hashedFileName(for key: String, pathExtension ext: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let base = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(base).\(ext)"
    }

    func clearAll() {
        clear(directory: artworkDirectory)
        clear(directory: lyricsDirectory)
        clear(directory: albumArtworkDirectory)
        clear(directory: artistArtworkDirectory)
    }

    func cacheSize() -> Int64 {
        directorySize(artworkDirectory) + directorySize(lyricsDirectory)
            + directorySize(albumArtworkDirectory) + directorySize(artistArtworkDirectory)
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

    /// 同步版 storeLyrics, 给 ScrapeOptionsView 等不便 await actor 的同步
    /// UI 路径用。语义跟 async 版一致 (force=false 拒绝降级)。默认 force=true
    /// 因为现有 caller 都是用户的刮削动作。
    nonisolated func storeLyricsSync(_ lines: [LyricLine], for key: String, force: Bool = true) {
        let fileName = expectedLyricsFileName(for: key)
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        let wordLevel = lines.contains(where: { $0.isWordLevel })
        plog("📝 storeLyricsSync key=\(key.prefix(8)) lines=\(lines.count) wordLevel=\(wordLevel) force=\(force)")
        if !force && wouldDowngrade(at: fileURL, against: lines) {
            plog("📝 storeLyricsSync skip downgrade")
            return
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(lines) else {
            plog("⚠️ storeLyricsSync encode failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            plog("📝 storeLyricsSync wrote \(data.count)B → \(fileName)")
        } catch {
            plog("⚠️ storeLyricsSync write failed: \(error.localizedDescription)")
        }
    }
}
