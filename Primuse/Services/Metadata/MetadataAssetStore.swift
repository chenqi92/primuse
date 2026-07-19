import CryptoKit
import Foundation
import PrimuseKit

actor MetadataAssetStore {
    static let shared = MetadataAssetStore()

    private let artworkDirectory: URL
    private let lyricsDirectory: URL
    private let albumArtworkDirectory: URL
    private let artistArtworkDirectory: URL
    /// 内容寻址的封面物理存储位置 — 同一图片只存一份, 用 SHA256 内容哈希命名,
    /// 上层(per-song / per-album / per-artist 目录)只存指向这里的 redirect
    /// 引导文件。50 首同专辑歌从前各存一份 200KB JPEG 共 10MB,现在共用一份。
    private let artworkContentDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Public directory URLs for external consumers (CachedArtworkView, ThemeService, etc.)
    nonisolated let artworkDirectoryURL: URL
    nonisolated let lyricsDirectoryURL: URL
    nonisolated let artworkContentDirectoryURL: URL

    /// Redirect 文件前缀:`REDIRECT:` + 32 位 hex SHA。共 41 字节。
    /// JPEG magic 是 `0xFF 0xD8 0xFF`,绝不会以 ASCII `R` 开头,
    /// 所以读取时一字节就能区分新旧两种格式。
    private static let redirectPrefixData = Data("REDIRECT:".utf8)

    private init(fileManager: FileManager = .default) {
        // tvOS 只允许写 Caches / tmp;Application Support 不可写(歌词/封面落不了盘)。
        #if os(tvOS)
        let appSupport = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif
        let rootDirectory = appSupport.appendingPathComponent("Primuse/MetadataAssets", isDirectory: true)
        artworkDirectory = rootDirectory.appendingPathComponent("artwork", isDirectory: true)
        lyricsDirectory = rootDirectory.appendingPathComponent("lyrics", isDirectory: true)
        albumArtworkDirectory = rootDirectory.appendingPathComponent("artwork/album", isDirectory: true)
        artistArtworkDirectory = rootDirectory.appendingPathComponent("artwork/artist", isDirectory: true)
        // content/ 放在 root 下,与 artwork/ 平级 —— 不要嵌在 artwork/ 里,
        // 否则 contentsOfDirectory(artwork) 会把它当成普通子目录处理。
        artworkContentDirectory = rootDirectory.appendingPathComponent("content", isDirectory: true)
        artworkDirectoryURL = artworkDirectory
        lyricsDirectoryURL = lyricsDirectory
        artworkContentDirectoryURL = artworkContentDirectory

        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: albumArtworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artistArtworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artworkContentDirectory, withIntermediateDirectories: true)

        // One-time migration from old Caches location
        let oldRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("primuse_metadata", isDirectory: true)
        migrateIfNeeded(from: oldRoot, fileManager: fileManager)

        // 后台跑一次 dedup 迁移 —— 把已经存在的 raw JPEG 文件全部转成 redirect,
        // 物理内容收拢到 content/。Idempotent (靠 .dedup_v1_done marker 文件
        // + 单文件 prefix 检查), 中途被杀也能下次接着跑。低优先级, 不影响
        // 启动速度。
        let dirsToMigrate = [artworkDirectory, albumArtworkDirectory, artistArtworkDirectory]
        let contentDir = artworkContentDirectory
        Task.detached(priority: .background) {
            Self.runDedupMigrationIfNeeded(targetDirs: dirsToMigrate, contentDir: contentDir)
            // 顺手 GC 一下 content/ —— 删掉没人引用的内容文件 (用户清缓存
            // 后偶尔产生孤儿)。
            Self.collectOrphanedContent(targetDirs: dirsToMigrate, contentDir: contentDir)
        }
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

    // MARK: - Content-addressed storage helpers

    /// 写一份封面到 content/ 物理存储, 在 `refURL` 留下 redirect 指针。
    /// 多首歌(或同一专辑下的多首)拿到同一张封面时,content 文件只写一次,
    /// 各自的 ref 文件都指向它。
    nonisolated private func writeContentAddressed(_ data: Data, refURL: URL) throws {
        let sha = Self.sha256Hex(data)
        let contentURL = artworkContentDirectoryURL.appendingPathComponent("\(sha).jpg")
        if !FileManager.default.fileExists(atPath: contentURL.path) {
            try data.write(to: contentURL, options: .atomic)
        }
        let redirect = Self.redirectPrefixData + Data(sha.utf8)
        try redirect.write(to: refURL, options: .atomic)
    }

    /// 读 ref 文件:redirect 就转向 content/<sha>.jpg, 老格式直接返回原 JPEG。
    /// nil = 文件不存在 / 内容损坏 / content 文件缺失。
    nonisolated private func readContentAddressed(refURL: URL) -> Data? {
        guard let raw = try? Data(contentsOf: refURL), !raw.isEmpty else { return nil }
        if raw.starts(with: Self.redirectPrefixData) {
            let shaSlice = raw.dropFirst(Self.redirectPrefixData.count)
            guard let sha = String(data: Data(shaSlice), encoding: .utf8),
                  !sha.isEmpty else { return nil }
            let contentURL = artworkContentDirectoryURL.appendingPathComponent("\(sha).jpg")
            return try? Data(contentsOf: contentURL)
        }
        return raw  // legacy: 还没迁移过的旧 raw JPEG
    }

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(32).map { String(format: "%02x", $0) }.joined()
    }

    /// 公共封面读取入口 — 透明处理 content-addressed redirect 与历史遗留的
    /// raw JPEG 两种格式。`ThemeService` / `LiveActivityManager` /
    /// `AudioPlayerService` 等不便走 actor 的同步路径用这个,而不是直接
    /// `Data(contentsOf:)` —— 直读会拿到 41 字节 "REDIRECT:..." 字符串,
    /// `UIImage(data:)` 当然会返回 nil。
    nonisolated func readCoverData(named filename: String) -> Data? {
        readContentAddressed(refURL: artworkDirectoryURL.appendingPathComponent(filename))
    }

    // MARK: - Cover (per-song key)

    func storeCover(_ data: Data, for key: String) -> String? {
        let fileName = hashedFileName(for: key, pathExtension: "jpg")
        let fileURL = artworkDirectory.appendingPathComponent(fileName)
        do {
            try writeContentAddressed(data, refURL: fileURL)
            return fileName
        } catch {
            return nil
        }
    }

    func coverData(named fileName: String?) -> Data? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let url = artworkDirectory.appendingPathComponent(fileName)
        if let data = readContentAddressed(refURL: url) { return data }
        plog("MetadataAssetStore: cover '\(fileName)' miss")
        return nil
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
            Self.postLyricsCached(songID: key, lines: lines)
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
        try? writeContentAddressed(data, refURL: fileURL)
    }

    /// Read cached cover art by song ID.
    func cachedCoverData(forSongID songID: String) -> Data? {
        let fileName = hashedFileName(for: songID, pathExtension: "jpg")
        return readContentAddressed(refURL: artworkDirectory.appendingPathComponent(fileName))
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
            Self.postLyricsCached(songID: songID, lines: lines)
            return true
        } catch {
            return false
        }
    }

    /// 通知 MusicLibrary 把这首歌的 lyricsText 同步到库里, 让 FTS5 全文
    /// 歌词搜索覆盖新写入的歌。LyricsTextBackfillService 是一次性的, 之后
    /// 的歌只能靠这条路。lines flatten 成纯文本 + 拼接, 单首歌词大小 1-2KB
    /// 量级, post 一次 notification 成本可忽略。
    nonisolated static func postLyricsCached(songID: String, lines: [LyricLine]) {
        let text = lines
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        NotificationCenter.default.post(
            name: .primuseLyricsDidCache,
            object: nil,
            userInfo: ["songID": songID, "lyricsText": text]
        )
    }

    /// Read cached lyrics by song ID.
    func cachedLyrics(forSongID songID: String) -> [LyricLine]? {
        let fileName = hashedFileName(for: songID, pathExtension: "json")
        guard let data = try? Data(contentsOf: lyricsDirectory.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode([LyricLine].self, from: data)
    }

    /// Synchronous lyrics lookup for local search. Only reads Primuse's local
    /// JSON lyric cache; it deliberately avoids network/source reads while the
    /// user is typing.
    nonisolated func cachedLyricsForSearch(songID: String, lyricsFileName: String?) -> [LyricLine]? {
        var candidates: [URL] = []
        if let lyricsFileName,
           !lyricsFileName.isEmpty,
           isLegacyLocalRef(lyricsFileName),
           lyricsFileName.hasSuffix(".json") {
            candidates.append(lyricsDirectoryURL.appendingPathComponent(lyricsFileName))
        }
        candidates.append(lyricsDirectoryURL.appendingPathComponent(expectedLyricsFileName(for: songID)))

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let lines = try? JSONDecoder().decode([LyricLine].self, from: data) else { continue }
            return lines
        }
        return nil
    }

    /// Remove cached cover art for a specific song (e.g., after scraping updates it).
    /// 只删 ref 文件;content/ 里的物理 jpeg 留给 GC 处理(可能还被其他歌
    /// 引用)。
    func invalidateCoverCache(forSongID songID: String) {
        let fileName = hashedFileName(for: songID, pathExtension: "jpg")
        try? FileManager.default.removeItem(at: artworkDirectory.appendingPathComponent(fileName))
    }

    /// Remove cached lyrics for a specific song.
    func invalidateLyricsCache(forSongID songID: String) {
        let fileName = hashedFileName(for: songID, pathExtension: "json")
        try? FileManager.default.removeItem(at: lyricsDirectory.appendingPathComponent(fileName))
    }

    /// Batch invalidation stays on this actor's executor and avoids creating
    /// two Tasks/actor hops per song when a large source is removed.
    func invalidateCaches(forSongIDs songIDs: [String]) {
        for songID in songIDs {
            let cover = hashedFileName(for: songID, pathExtension: "jpg")
            try? FileManager.default.removeItem(at: artworkDirectory.appendingPathComponent(cover))
            let lyrics = hashedFileName(for: songID, pathExtension: "json")
            try? FileManager.default.removeItem(at: lyricsDirectory.appendingPathComponent(lyrics))
        }
    }

    /// Check if a reference is an old-style local hashed filename (for migration).
    nonisolated func isLegacyLocalRef(_ ref: String) -> Bool {
        !ref.contains("/") && !ref.contains("://")
            && (ref.hasSuffix(".jpg") || ref.hasSuffix(".json"))
    }

    // MARK: - Album artwork

    func storeAlbumCover(_ data: Data, forAlbumID albumID: String) -> String? {
        let fileName = hashedFileName(for: "album_\(albumID)", pathExtension: "jpg")
        let fileURL = albumArtworkDirectory.appendingPathComponent(fileName)
        do {
            try writeContentAddressed(data, refURL: fileURL)
            return fileName
        } catch { return nil }
    }

    func cachedAlbumCover(forAlbumID albumID: String) -> Data? {
        let fileName = hashedFileName(for: "album_\(albumID)", pathExtension: "jpg")
        return readContentAddressed(refURL: albumArtworkDirectory.appendingPathComponent(fileName))
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
            try writeContentAddressed(data, refURL: fileURL)
            return fileName
        } catch { return nil }
    }

    func cachedArtistImage(forArtistID artistID: String) -> Data? {
        let fileName = hashedFileName(for: "artist_\(artistID)", pathExtension: "jpg")
        return readContentAddressed(refURL: artistArtworkDirectory.appendingPathComponent(fileName))
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
        // 注意: artwork/ 下还有 album / artist 子目录, 父目录 contentsOf 会
        // 把它们当文件 entry 一并 removeItem (递归删整棵), 子调用 clear()
        // 时再补建即可。content/ 是 root-level 兄弟目录, 必须显式清。
        clear(directory: artworkDirectory)
        clear(directory: lyricsDirectory)
        clear(directory: albumArtworkDirectory)
        clear(directory: artistArtworkDirectory)
        clear(directory: artworkContentDirectory)
        // 重建被父目录 clear 抹掉的子目录, 让后续 write 不需要再 mkdir。
        let fm = FileManager.default
        try? fm.createDirectory(at: albumArtworkDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: artistArtworkDirectory, withIntermediateDirectories: true)
    }

    func cacheSize() -> Int64 {
        // directorySize 现在用 enumerator 递归, artwork/ 已经包含 album/ 和
        // artist/ 子目录, 不能再单独加, 否则双倍计数。
        directorySize(artworkDirectory)
            + directorySize(lyricsDirectory)
            + directorySize(artworkContentDirectory)
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
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
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
        let fileURL = artworkDirectoryURL.appendingPathComponent(fileName)
        try? writeContentAddressed(data, refURL: fileURL)
    }

    /// 同步版 storeLyrics, 给 ScrapeOptionsView 等不便 await actor 的同步
    /// UI 路径用。语义跟 async 版一致 (force=false 拒绝降级)。默认 force=true
    /// 因为现有 caller 都是用户的刮削动作。
    nonisolated func storeLyricsSync(_ lines: [LyricLine], for key: String, force: Bool = true) {
        let fileName = expectedLyricsFileName(for: key)
        let fileURL = lyricsDirectoryURL.appendingPathComponent(fileName)
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
            Self.postLyricsCached(songID: key, lines: lines)
        } catch {
            plog("⚠️ storeLyricsSync write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - One-time dedup migration

    /// 把 `targetDirs` 下的 raw JPEG 文件全部转成 redirect, 物理内容按
    /// SHA 收拢到 `contentDir`。靠 marker 文件保证只跑一次, 但单文件检查
    /// (`starts(with: prefix)`) 让中途被杀也能下次接着跑。
    nonisolated private static func runDedupMigrationIfNeeded(targetDirs: [URL], contentDir: URL) {
        let fm = FileManager.default
        let marker = contentDir.appendingPathComponent(".dedup_v1_done")
        if fm.fileExists(atPath: marker.path) { return }

        let prefix = MetadataAssetStore.redirectPrefixData
        var migrated = 0
        var skipped = 0

        for dir in targetDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for file in files {
                let isRegular = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular, file.pathExtension == "jpg" else { continue }
                guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
                if data.starts(with: prefix) { skipped += 1; continue }

                let sha = sha256Hex(data)
                let contentURL = contentDir.appendingPathComponent("\(sha).jpg")
                if !fm.fileExists(atPath: contentURL.path) {
                    do { try data.write(to: contentURL, options: .atomic) }
                    catch { continue }  // 写不进 content 就别动 ref, 下次重试
                }
                let redirect = prefix + Data(sha.utf8)
                if (try? redirect.write(to: file, options: .atomic)) != nil {
                    migrated += 1
                }
            }
        }

        try? Data().write(to: marker, options: .atomic)
        plog("📦 MetadataAssetStore dedup v1: migrated=\(migrated) alreadyDone=\(skipped)")
    }

    /// 删掉 content/ 下没人引用的 jpeg。在 dedup 跑完后调一次, 用户清缓存
    /// 也会调到。开销 O(redirects + content), 都是 32 字节读, 很轻。
    ///
    /// 竞态保护: 收集 referencedShas 与扫 content/ 之间存在窗口, 期间并发的
    /// writeContentAddressed 可能先写 content/<sha>.jpg、后写 redirect ref ——
    /// 若新 content 文件在收集 referencedShas 之后落盘, 它不会出现在引用集合
    /// 里, 会被误判成孤儿删掉, 随后写下的 redirect 就指向已删内容。所以只删
    /// mtime 早于本次 GC 启动前 5 分钟的孤儿, 给"内容已写、ref 待写"的在途
    /// 写入留足缓冲, 永不碰新近写入的 content 文件。
    nonisolated private static func collectOrphanedContent(targetDirs: [URL], contentDir: URL) {
        let fm = FileManager.default
        let prefix = MetadataAssetStore.redirectPrefixData
        // 早于这个时刻写入的 content 文件才允许被当孤儿删除。
        let cutoff = Date().addingTimeInterval(-5 * 60)

        // 收集所有正在被引用的 SHA
        var referencedShas = Set<String>()
        for dir in targetDirs {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jpg" else { continue }
                guard let raw = try? Data(contentsOf: fileURL), raw.starts(with: prefix) else { continue }
                let shaBytes = raw.dropFirst(prefix.count)
                if let sha = String(data: Data(shaBytes), encoding: .utf8), !sha.isEmpty {
                    referencedShas.insert(sha)
                }
            }
        }

        // 扫 content/, 没在 referenced 集合里、且写入时间早于 cutoff 的才是孤儿
        guard let contents = try? fm.contentsOfDirectory(
            at: contentDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        var removed = 0
        for file in contents where file.pathExtension == "jpg" {
            let sha = file.deletingPathExtension().lastPathComponent
            guard !referencedShas.contains(sha) else { continue }
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard mtime < cutoff else { continue }  // 新近写入的, 可能 ref 还在途, 留着
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 {
            plog("🧹 MetadataAssetStore content GC: removed \(removed) orphan(s)")
        }
    }

    // MARK: - Size cap / eviction

    /// content/ 总大小超 `maxBytes` 时, 按 mtime 倒序(最老优先)删掉 content
    /// 文件直到回到上限以下。被驱逐的 SHA 对应的 ref 文件下次读会落到
    /// readContentAddressed → nil → CachedArtworkView 网络重新拉。
    func evictArtworkContentIfNeeded(maxBytes: Int64 = 500 * 1024 * 1024) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: artworkContentDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        struct Entry { let url: URL; let size: Int64; let mtime: Date }
        var entries: [Entry] = []
        var total: Int64 = 0
        for url in contents where url.pathExtension == "jpg" {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            let mtime = v?.contentModificationDate ?? .distantPast
            entries.append(Entry(url: url, size: size, mtime: mtime))
            total += size
        }
        guard total > maxBytes else { return }

        entries.sort { $0.mtime < $1.mtime }  // 老的在前
        var freed: Int64 = 0
        for e in entries {
            if total - freed <= maxBytes { break }
            if (try? fm.removeItem(at: e.url)) != nil { freed += e.size }
        }
        plog("🧹 artwork content evict: freed=\(freed / 1024 / 1024)MB total=\(total / 1024 / 1024)MB cap=\(maxBytes / 1024 / 1024)MB")
    }
}
