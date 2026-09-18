import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PrimuseKit
import UniformTypeIdentifiers

actor MetadataAssetStore {
    static let shared = MetadataAssetStore()

    private let artworkDirectory: URL
    private let lyricsDirectory: URL
    private let albumArtworkDirectory: URL
    private let artistArtworkDirectory: URL
    private let customArtworkDirectory: URL
    /// 内容寻址的封面物理存储位置 — 同一图片只存一份, 用 SHA256 内容哈希命名,
    /// 上层(per-song / per-album / per-artist 目录)只存指向这里的 redirect
    /// 引导文件。50 首同专辑歌从前各存一份 200KB JPEG 共 10MB,现在共用一份。
    private let artworkContentDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lyricsMutationReservations: [String: UUID] = [:]

    /// Public directory URLs for external consumers (CachedArtworkView, ThemeService, etc.)
    nonisolated let artworkDirectoryURL: URL
    nonisolated let lyricsDirectoryURL: URL
    nonisolated let artworkContentDirectoryURL: URL
    nonisolated let customArtworkDirectoryURL: URL
    nonisolated let portableArtworkDirectoryURL: URL

    /// Redirect 文件前缀:`REDIRECT:` + 64 位 hex SHA。共 73 字节。
    /// JPEG magic 是 `0xFF 0xD8 0xFF`,绝不会以 ASCII `R` 开头,
    /// 所以读取时一字节就能区分新旧两种格式。
    private static let redirectPrefixData = Data("REDIRECT:".utf8)

    init(storageDirectory: URL? = nil, fileManager: FileManager = .default) {
        // tvOS 只允许写 Caches / tmp;Application Support 不可写(歌词/封面落不了盘)。
        #if os(tvOS)
        let appSupport = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let appSupport = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let rootDirectory = storageDirectory ?? appSupport.appendingPathComponent("Primuse/MetadataAssets", isDirectory: true)
        artworkDirectory = rootDirectory.appendingPathComponent("artwork", isDirectory: true)
        lyricsDirectory = rootDirectory.appendingPathComponent("lyrics", isDirectory: true)
        albumArtworkDirectory = rootDirectory.appendingPathComponent("artwork/album", isDirectory: true)
        artistArtworkDirectory = rootDirectory.appendingPathComponent("artwork/artist", isDirectory: true)
        // User uploads are durable data, not a disposable cache. Keep them in
        // their own content-addressed directory so cache eviction/clear and
        // redirect GC can never remove an active custom cover.
        customArtworkDirectory = rootDirectory.appendingPathComponent("custom", isDirectory: true)
        // content/ 放在 root 下,与 artwork/ 平级 —— 不要嵌在 artwork/ 里,
        // 否则 contentsOfDirectory(artwork) 会把它当成普通子目录处理。
        artworkContentDirectory = rootDirectory.appendingPathComponent("content", isDirectory: true)
        artworkDirectoryURL = artworkDirectory
        lyricsDirectoryURL = lyricsDirectory
        artworkContentDirectoryURL = artworkContentDirectory
        customArtworkDirectoryURL = customArtworkDirectory
        portableArtworkDirectoryURL = rootDirectory.appendingPathComponent("portable-artwork-v1", isDirectory: true)

        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: albumArtworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artistArtworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: customArtworkDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artworkContentDirectory, withIntermediateDirectories: true)

        // One-time migration from old Caches location
        let oldRoot = fileManager.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_metadata", isDirectory: true)
        if storageDirectory == nil { migrateIfNeeded(from: oldRoot, fileManager: fileManager) }

        // Dedup/GC can traverse every artwork reference. It is deliberately
        // started by the scene's scheduled file-maintenance window instead of
        // actor initialization, so merely opening the app never launches an
        // unbounded directory walk.
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

    // MARK: - User-selected library artwork

    /// Stores the canonical JPEG once in the content-addressed pool. Album and
    /// playlist override records retain only the returned identifier.
    func storeCustomArtwork(_ data: Data) -> String? {
        storeCustomArtworkSync(data)
    }

    /// Synchronous counterpart used while restoring a CloudKit or portable
    /// library snapshot. The expected ID prevents corrupted or mismatched
    /// remote bytes from being installed under a trusted reference.
    @discardableResult
    nonisolated func storeCustomArtworkSync(
        _ data: Data,
        expectedContentID: String? = nil
    ) -> String? {
        guard !data.isEmpty,
              data.count <= LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else {
            return nil
        }
        let contentID = Self.sha256Hex(data)
        if let expectedContentID, expectedContentID != contentID { return nil }
        let contentURL = customArtworkDirectoryURL.appendingPathComponent("\(contentID).jpg")
        do {
            try FileManager.default.createDirectory(
                at: customArtworkDirectoryURL,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: contentURL.path) {
                try data.write(to: contentURL, options: .atomic)
            }
            Self.postCustomArtworkCached(contentID: contentID)
            return contentID
        } catch {
            return nil
        }
    }

    nonisolated func customArtworkData(contentID: String) -> Data? {
        guard LibraryArtworkContentIDPolicy.isValid(contentID) else { return nil }
        let contentURL = customArtworkDirectoryURL.appendingPathComponent("\(contentID).jpg")
        guard let data = try? Data(contentsOf: contentURL),
              !data.isEmpty,
              data.count <= LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else {
            return nil
        }
        return data
    }

    nonisolated func hasCustomArtwork(contentID: String) -> Bool {
        customArtworkData(contentID: contentID) != nil
    }

    private nonisolated static func postCustomArtworkCached(contentID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .primuseArtworkDidCache,
                object: contentID,
                userInfo: ["tokens": [contentID]]
            )
        }
    }

    /// 公共封面读取入口 — 透明处理 content-addressed redirect 与历史遗留的
    /// raw JPEG 两种格式。`ThemeService` / `AudioPlayerService` 等不便走
    /// actor 的同步路径用这个,而不是直接
    /// `Data(contentsOf:)` —— 直读会拿到 41 字节 "REDIRECT:..." 字符串,
    /// `UIImage(data:)` 当然会返回 nil。
    nonisolated func readCoverData(named filename: String) -> Data? {
        readContentAddressed(refURL: artworkDirectoryURL.appendingPathComponent(filename))
    }

    /// Returns a cheap, stable identity for a cover without decoding or loading
    /// the image into memory. Content-addressed redirects expose their SHA
    /// directly; legacy raw files fall back to size + modification time so an
    /// in-place artwork replacement still invalidates derived thumbnails.
    nonisolated func coverContentIdentifier(named filename: String) -> String? {
        guard !filename.isEmpty else { return nil }
        let refURL = artworkDirectoryURL.appendingPathComponent(filename)
        guard let handle = try? FileHandle(forReadingFrom: refURL) else { return nil }
        defer { try? handle.close() }

        let header: Data
        do {
            header = try handle.read(upToCount: Self.redirectPrefixData.count + 64) ?? Data()
        } catch {
            return nil
        }
        if header.starts(with: Self.redirectPrefixData) {
            let hashData = header.dropFirst(Self.redirectPrefixData.count)
            if let hash = String(data: hashData, encoding: .utf8), !hash.isEmpty {
                return "sha256:\(hash)"
            }
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: refURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return "legacy:\(size):\(modified.timeIntervalSinceReferenceDate.bitPattern)"
    }

    struct PortableCover: Sendable {
        let data: Data
        let requiredProcessing: Bool
    }

    /// Snapshot retries reuse the same transport image across launches. The
    /// source identity changes when either a redirect or a legacy file changes.
    nonisolated func preparePortableCover(named filename: String, contentIdentifier: String) -> PortableCover? {
        let key = Self.sha256Hex(Data(contentIdentifier.utf8))
        let url = portableArtworkDirectoryURL.appendingPathComponent("\(key).jpg")
        if let cached = try? Data(contentsOf: url),
           LibraryArtworkImageProcessor.isReusablePortableJPEG(cached) {
            return PortableCover(data: cached, requiredProcessing: false)
        }
        guard !Self.currentTaskIsCancelled(),
              let original = readCoverData(named: filename) else { return nil }
        if LibraryArtworkImageProcessor.isReusablePortableJPEG(original) {
            return PortableCover(data: original, requiredProcessing: false)
        }
        let processed = autoreleasepool {
            LibraryArtworkImageProcessor.process(original)
        }
        guard !Self.currentTaskIsCancelled(), let processed else { return nil }
        try? FileManager.default.createDirectory(at: portableArtworkDirectoryURL, withIntermediateDirectories: true)
        try? processed.write(to: url, options: .atomic)
        return PortableCover(data: processed, requiredProcessing: true)
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
        guard lyricsMutationReservations[key] == nil else { return nil }
        let fileName = hashedFileName(for: key, pathExtension: "json")
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        if cacheLyrics(lines, forSongID: key, force: force) { return fileName }
        // Automatic scans deliberately retain an existing local override,
        // authored translation, or stronger word-level cache. Keep its stable
        // reference instead of making the caller clear a document we preserved.
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileName : nil
    }

    /// 「会不会让现存的字级缓存被降级成行级」—— true 表示该跳过本次写入。
    /// 同级别写入 (字→字 / 行→行) 永远允许 (能刷新内容)。
    nonisolated private func wouldDowngrade(at url: URL, against incoming: [LyricLine]) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let existing = try? JSONDecoder().decode([LyricLine].self, from: data) else {
            return false
        }
        let existingHasSyllables = existing.contains(where: \.containsWordLevelContent)
        let incomingHasSyllables = incoming.contains(where: \.containsWordLevelContent)
        return existingHasSyllables && !incomingHasSyllables
    }

    func lyrics(named fileName: String?) -> [LyricLine]? {
        // Legacy local references are JSON basenames. Remote sidecar paths
        // belong to the source connector, not this cache directory.
        guard let fileName, !fileName.isEmpty,
              !fileName.contains("/"), !fileName.contains("\\"),
              (fileName as NSString).pathExtension.lowercased() == "json" else { return nil }
        do {
            let data = try Data(contentsOf: lyricsDirectory.appendingPathComponent(fileName))
            let lines = try decoder.decode([LyricLine].self, from: data)
            return LyricVoiceTimelinePolicy.groupingOverlappingSecondaryLines(in: lines)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError { return nil }
            plog("MetadataAssetStore: failed to read lyrics '\(fileName)': \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Song ID-based cache (new architecture: source ref + local cache)

    /// Cache cover art data using song ID as the cache key.
    func cacheCover(_ data: Data, forSongID songID: String) {
        guard ArtworkImageCompatibility.isCompleteImage(data),
              !ArtworkImageCompatibility.hasRedundantJPEGSampling(data) else {
            plog("MetadataAssetStore: rejected incomplete cover for song '\(songID.prefix(8))'")
            return
        }
        let fileName = hashedFileName(for: songID, pathExtension: "jpg")
        let fileURL = artworkDirectory.appendingPathComponent(fileName)
        do {
            try writeContentAddressed(data, refURL: fileURL)
            Self.postCoverCached(songID: songID)
        } catch {
            plog("MetadataAssetStore: failed to cache cover for song '\(songID.prefix(8))': \(error.localizedDescription)")
        }
    }

    private nonisolated static func postCoverCached(songID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .primuseArtworkDidCache, object: songID)
        }
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
        guard lyricsMutationReservations[songID] == nil else { return false }
        let fileName = hashedFileName(for: songID, pathExtension: "json")
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        if !force,
           let stored = cachedLyrics(forSongID: songID),
           !stored.isEmpty {
            if stored.first?.documentIsLocalOverride == true {
                plog("📝 cacheLyrics keep local override songID=\(songID.prefix(8))")
                return false
            }
            guard let reconciled = LyricManualTranslationPolicy
                .preservingStoredTranslations(from: stored, in: lines) else {
                plog("📝 cacheLyrics preserve authored translation songID=\(songID.prefix(8))")
                return false
            }
            if LyricsDocumentFingerprint(lines: reconciled)
                != LyricsDocumentFingerprint(lines: lines) {
                // Automatic callers only receive a Bool and would otherwise
                // put the unmerged source document straight into the UI. Keep
                // the complete cached document until a coordinator capable of
                // returning the reconciled lines performs an explicit update.
                plog("📝 cacheLyrics keep structured cache songID=\(songID.prefix(8))")
                return false
            }
        }
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

    /// Atomically replaces the editable cache only if it is still the document
    /// the editor opened. `nil` means the editor opened with no cache; it is not
    /// a wildcard.
    func replaceLyricsIfUnchanged(
        _ lines: [LyricLine],
        forSongID songID: String,
        expectedFingerprint: LyricsDocumentFingerprint?,
        force: Bool = true
    ) -> Bool {
        guard lyricsMutationReservations[songID] == nil else { return false }
        let currentFingerprint = cachedLyrics(forSongID: songID)
            .map(LyricsDocumentFingerprint.init(lines:))
        guard currentFingerprint == expectedFingerprint else { return false }
        return cacheLyrics(lines, forSongID: songID, force: force)
    }

    /// Reserves a song's cache mutation across an external compare/write/read
    /// transaction. Every ordinary cache writer is rejected until the holder
    /// commits or cancels, so a stale editor cannot discover a cache race only
    /// after it has already changed the source document.
    func beginLyricsMutation(
        forSongID songID: String,
        expectedFingerprint: LyricsDocumentFingerprint?
    ) -> UUID? {
        guard lyricsMutationReservations[songID] == nil else { return nil }
        let currentFingerprint = cachedLyrics(forSongID: songID)
            .map(LyricsDocumentFingerprint.init(lines:))
        guard currentFingerprint == expectedFingerprint else { return nil }
        let token = UUID()
        lyricsMutationReservations[songID] = token
        return token
    }

    func commitLyricsMutation(
        _ lines: [LyricLine],
        forSongID songID: String,
        token: UUID
    ) -> Bool {
        guard lyricsMutationReservations[songID] == token else { return false }
        lyricsMutationReservations[songID] = nil
        return cacheLyrics(lines, forSongID: songID, force: true)
    }

    func commitLyricsRemoval(forSongID songID: String, token: UUID) -> Bool {
        guard lyricsMutationReservations[songID] == token else { return false }
        lyricsMutationReservations[songID] = nil
        return invalidateLyricsCache(forSongID: songID)
    }

    func cancelLyricsMutation(forSongID songID: String, token: UUID) {
        guard lyricsMutationReservations[songID] == token else { return }
        lyricsMutationReservations[songID] = nil
    }

    /// 通知 MusicLibrary 把这首歌的 lyricsText 同步到库里, 让 FTS5 全文
    /// 歌词搜索覆盖新写入的歌。LyricsTextBackfillService 是一次性的, 之后
    /// 的歌只能靠这条路。lines flatten 成纯文本 + 拼接, 单首歌词大小 1-2KB
    /// 量级, post 一次 notification 成本可忽略。
    nonisolated static func postLyricsCached(songID: String, lines: [LyricLine]) {
        let text = LyricVoiceTimelinePolicy.flattenedLines(lines)
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
        guard let lines = try? decoder.decode([LyricLine].self, from: data) else { return nil }
        return LyricVoiceTimelinePolicy.groupingOverlappingSecondaryLines(in: lines)
    }

    /// Preserve lyrics written while MusicKit exposed a catalog-derived song
    /// ID under the canonical Apple Music user-library ID. The alias is kept
    /// for backwards compatibility; the canonical copy becomes the source of
    /// truth after the next launch.
    @discardableResult
    func preserveLyricsAlias(fromSongID aliasSongID: String, toSongID canonicalSongID: String) -> Bool {
        guard aliasSongID != canonicalSongID else { return false }
        guard lyricsMutationReservations[aliasSongID] == nil,
              lyricsMutationReservations[canonicalSongID] == nil else { return false }
        let aliasURL = lyricsDirectory.appendingPathComponent(
            hashedFileName(for: aliasSongID, pathExtension: "json")
        )
        guard let aliasData = try? Data(contentsOf: aliasURL),
              let aliasLines = try? decoder.decode([LyricLine].self, from: aliasData),
              !aliasLines.isEmpty else { return false }

        let canonicalURL = lyricsDirectory.appendingPathComponent(
            hashedFileName(for: canonicalSongID, pathExtension: "json")
        )
        var linesToWrite = aliasLines
        if let canonicalData = try? Data(contentsOf: canonicalURL),
           let canonicalLines = try? decoder.decode([LyricLine].self, from: canonicalData),
           !canonicalLines.isEmpty {
            guard canonicalLines.first?.documentIsLocalOverride != true else { return false }
            let aliasIsWordLevel = aliasLines.contains(where: \.containsWordLevelContent)
            let canonicalIsWordLevel = canonicalLines.contains(where: \.containsWordLevelContent)
            guard aliasIsWordLevel && !canonicalIsWordLevel else { return false }
            guard let reconciled = LyricManualTranslationPolicy.preservingStoredTranslations(
                from: canonicalLines,
                in: aliasLines
            ) else { return false }
            linesToWrite = reconciled
        }

        do {
            let data = try encoder.encode(linesToWrite)
            try data.write(to: canonicalURL, options: .atomic)
            Self.postLyricsCached(songID: canonicalSongID, lines: linesToWrite)
            plog("📝 preserved Apple Music lyrics alias \(aliasSongID.prefix(8)) → \(canonicalSongID.prefix(8))")
            return true
        } catch {
            plog("⚠️failed to preserve Apple Music lyrics alias: \(error.localizedDescription)")
            return false
        }
    }

    /// Synchronous lyrics lookup for local search. Only reads Primuse's local
    /// JSON lyric cache; it deliberately avoids network/source reads while the
    /// user is typing.
    nonisolated func cachedLyricsForSearch(songID: String, lyricsFileName: String?) -> [LyricLine]? {
        for url in lyricsSearchCandidateURLs(songID: songID, lyricsFileName: lyricsFileName) {
            guard let data = try? Data(contentsOf: url),
                  let lines = try? JSONDecoder().decode([LyricLine].self, from: data) else { continue }
            return LyricVoiceTimelinePolicy.groupingOverlappingSecondaryLines(in: lines)
        }
        return nil
    }

    /// A cheap, persistent signature for the local lyrics file. The search
    /// index compares this before decoding/transliterating a lyric, so normal
    /// launches only stat cached files and never rebuild unchanged pinyin.
    nonisolated func cachedLyricsSearchSignature(songID: String, lyricsFileName: String?) -> String? {
        for url in lyricsSearchCandidateURLs(songID: songID, lyricsFileName: lyricsFileName) {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return "\(url.lastPathComponent)|\(size)|\(modified)"
        }
        return nil
    }

    nonisolated private func lyricsSearchCandidateURLs(songID: String, lyricsFileName: String?) -> [URL] {
        var candidates: [URL] = []
        if let lyricsFileName,
           !lyricsFileName.isEmpty,
           isLegacyLocalRef(lyricsFileName),
           lyricsFileName.hasSuffix(".json") {
            candidates.append(lyricsDirectoryURL.appendingPathComponent(lyricsFileName))
        }
        let expected = lyricsDirectoryURL.appendingPathComponent(expectedLyricsFileName(for: songID))
        if candidates.last != expected { candidates.append(expected) }
        return candidates
    }

    /// Remove cached cover art for a specific song (e.g., after scraping updates it).
    /// 只删 ref 文件;content/ 里的物理 jpeg 留给 GC 处理(可能还被其他歌
    /// 引用)。
    func invalidateCoverCache(forSongID songID: String) {
        let fileName = hashedFileName(for: songID, pathExtension: "jpg")
        try? FileManager.default.removeItem(at: artworkDirectory.appendingPathComponent(fileName))
    }

    /// Remove cached lyrics for a specific song.
    @discardableResult
    func invalidateLyricsCache(forSongID songID: String) -> Bool {
        guard lyricsMutationReservations[songID] == nil else { return false }
        let fileName = hashedFileName(for: songID, pathExtension: "json")
        let fileURL = lyricsDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    /// Compare-and-delete counterpart used by the editor. This prevents a
    /// stale window from removing lyrics saved by a newer window.
    func invalidateLyricsCacheIfUnchanged(
        forSongID songID: String,
        expectedFingerprint: LyricsDocumentFingerprint?
    ) -> Bool {
        let currentFingerprint = cachedLyrics(forSongID: songID)
            .map(LyricsDocumentFingerprint.init(lines:))
        guard currentFingerprint == expectedFingerprint else { return false }
        return invalidateLyricsCache(forSongID: songID)
    }

    /// Batch invalidation stays on this actor's executor and avoids creating
    /// two Tasks/actor hops per song when a large source is removed.
    func invalidateCaches(forSongIDs songIDs: [String]) {
        for songID in songIDs {
            let cover = hashedFileName(for: songID, pathExtension: "jpg")
            try? FileManager.default.removeItem(at: artworkDirectory.appendingPathComponent(cover))
            if lyricsMutationReservations[songID] == nil {
                let lyrics = hashedFileName(for: songID, pathExtension: "json")
                try? FileManager.default.removeItem(at: lyricsDirectory.appendingPathComponent(lyrics))
            }
        }
    }

    /// A content-change scan may already have written fresh embedded/sidecar
    /// assets under the deterministic song ID before it publishes the change
    /// notification. Preserve those fresh files and invalidate only asset
    /// kinds that the new authoritative Song explicitly does not reference.
    func invalidateMissingCaches(for songs: [Song]) {
        for song in songs {
            if song.coverArtFileName == nil {
                let cover = hashedFileName(for: song.id, pathExtension: "jpg")
                try? FileManager.default.removeItem(at: artworkDirectory.appendingPathComponent(cover))
            }
            if song.lyricsFileName == nil,
               lyricsMutationReservations[song.id] == nil {
                if cachedLyrics(forSongID: song.id)?.first?.documentIsLocalOverride == true {
                    continue
                }
                let lyrics = hashedFileName(for: song.id, pathExtension: "json")
                try? FileManager.default.removeItem(at: lyricsDirectory.appendingPathComponent(lyrics))
            }
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
        let removedArtworkEntries = clear(directory: artworkDirectory)
        if lyricsMutationReservations.isEmpty {
            clear(directory: lyricsDirectory)
        }
        clear(directory: albumArtworkDirectory)
        clear(directory: artistArtworkDirectory)
        clear(directory: artworkContentDirectory)
        clear(directory: portableArtworkDirectoryURL)
        // 重建被父目录 clear 抹掉的子目录, 让后续 write 不需要再 mkdir。
        let fm = FileManager.default
        try? fm.createDirectory(at: albumArtworkDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: artistArtworkDirectory, withIntermediateDirectories: true)

        // 手动清空和容量驱逐留下的是同一种残局, 所以走同一条善后链路:
        // ref 和 content 都没了, 而 `Song.coverArtFileName` 还留着 —— 回填
        // 队列的判据就是它, 非空就认定"这首歌已经有封面", 于是谁也不会再去
        // 读一次, 界面上就是封面凭空消失且再也回不来 (远端源尤其: 内嵌封面
        // 没有别的地方可以回源)。整批一次性播出去, 观察者那边是一次
        // `replaceSongs` 发布; 拆成小批反而会把 O(整库) 的发布成本乘上批数。
        let clearedCoverRefs = Self.songCoverReferenceNames(in: removedArtworkEntries)
        if !clearedCoverRefs.isEmpty {
            Self.postArtworkContentEvicted(refs: clearedCoverRefs)
        }
    }

    /// `artwork/` 顶层的 `<hash>.jpg` 才是挂在 `Song.coverArtFileName` 上的
    /// 引用; album/ 与 artist/ 两个子目录是另一套键、也不进歌曲记录, 按扩展名
    /// 就能把它们排除掉 (目录 entry 没有 `jpg` 扩展名)。
    nonisolated private static func songCoverReferenceNames(in removed: [URL]) -> Set<String> {
        var names: Set<String> = []
        names.reserveCapacity(removed.count)
        for url in removed where url.pathExtension == "jpg" {
            names.insert(url.lastPathComponent)
        }
        return names
    }

    func cacheSize() -> Int64 {
        // directorySize 现在用 enumerator 递归, artwork/ 已经包含 album/ 和
        // artist/ 子目录, 不能再单独加, 否则双倍计数。
        directorySize(artworkDirectory)
            + directorySize(lyricsDirectory)
            + directorySize(artworkContentDirectory)
            + directorySize(portableArtworkDirectoryURL)
    }

    /// 返回**确实删掉了**的那些 entry。删失败的不能报出去: 调用方会据此让
    /// 资料库把对应的 `coverArtFileName` 摘掉, 而那个文件其实还在。
    @discardableResult
    private func clear(directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        var removed: [URL] = []
        removed.reserveCapacity(contents.count)
        for fileURL in contents {
            guard (try? fileManager.removeItem(at: fileURL)) != nil else { continue }
            removed.append(fileURL)
        }
        return removed
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

    /// The song-ID mirror is read before the song's reference, so a server
    /// that replaced its artwork must lose the mirror before the library
    /// publishes the new reference and mounted covers reload.
    nonisolated func invalidateCoverCacheSync(forSongID songID: String) {
        let fileURL = artworkDirectoryURL.appendingPathComponent(expectedCoverFileName(for: songID))
        try? FileManager.default.removeItem(at: fileURL)
    }

    nonisolated func storeCoverSync(_ data: Data, for key: String) {
        let fileName = expectedCoverFileName(for: key)
        let fileURL = artworkDirectoryURL.appendingPathComponent(fileName)
        try? writeContentAddressed(data, refURL: fileURL)
    }

    /// Transport references are restricted to deterministic cache filenames;
    /// imported images never become user-selected artwork overrides.
    @discardableResult
    nonisolated func installPortableCachedArtwork(
        _ data: Data,
        contentID: String,
        referenceFileNames: [String]
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes,
              Self.sha256Hex(data) == contentID,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else { return false }
        var installed = false
        for reference in referenceFileNames {
            let prefix = ["album/", "artist/"].first(where: reference.hasPrefix)
            let name = prefix.map { String(reference.dropFirst($0.count)) } ?? reference
            let stem = String(name.dropLast(4))
            guard name.hasSuffix(".jpg"), stem.utf8.count == 32,
                  stem.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            let url = artworkDirectoryURL.appendingPathComponent(reference)
            if let existing = readCoverData(named: reference) {
                if existing == data { continue }
                #if !os(tvOS)
                // A TV-sized transport image must not replace the sender's original.
                if CGImageSourceCreateWithData(existing as CFData, nil) != nil { continue }
                #endif
            }
            do {
                try writeContentAddressed(data, refURL: url)
                installed = true
            } catch { continue }
        }
        return installed
    }

    // MARK: - One-time dedup migration

    /// 把 `targetDirs` 下的 raw JPEG 文件全部转成 redirect, 物理内容按
    /// SHA 收拢到 `contentDir`。靠 marker 文件保证只跑一次, 但单文件检查
    /// (`starts(with: prefix)`) 让中途被杀也能下次接着跑。
    @discardableResult
    nonisolated private static func runDedupMigrationIfNeeded(
        targetDirs: [URL],
        contentDir: URL
    ) -> Bool {
        let fm = FileManager.default
        let marker = contentDir.appendingPathComponent(".dedup_v1_done")
        if fm.fileExists(atPath: marker.path) { return true }

        let prefix = MetadataAssetStore.redirectPrefixData
        var migrated = 0
        var skipped = 0

        for dir in targetDirs {
            guard !currentTaskIsCancelled() else { return false }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for file in files {
                guard !currentTaskIsCancelled() else { return false }
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
        return true
    }

    /// `writeContentAddressed` 先写 content 字节、后写 redirect ref, 两步之间
    /// 有窗口。比这个年龄新的 content 文件一律不碰 —— 它的 ref 可能正在路上,
    /// 删掉就会留下一个指向已删内容的引用。孤儿 GC 与容量驱逐共用。
    nonisolated private static let inFlightWriteGrace: TimeInterval = 5 * 60

    /// 扫一遍所有 redirect ref, 建立 sha → 引用它的 ref 文件。孤儿 GC 只用
    /// 它的 key 集合; 容量驱逐还要用它在删 content 的同时清掉悬空 ref。
    /// nil = 中途被取消。
    nonisolated private static func contentReferenceMap(
        targetDirs: [URL]
    ) -> [String: [URL]]? {
        let fm = FileManager.default
        let prefix = MetadataAssetStore.redirectPrefixData
        var map: [String: [URL]] = [:]
        for dir in targetDirs {
            guard !currentTaskIsCancelled() else { return nil }
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let fileURL as URL in enumerator {
                guard !currentTaskIsCancelled() else { return nil }
                guard fileURL.pathExtension == "jpg" else { continue }
                guard let raw = try? Data(contentsOf: fileURL), raw.starts(with: prefix) else { continue }
                let shaBytes = raw.dropFirst(prefix.count)
                if let sha = String(data: Data(shaBytes), encoding: .utf8), !sha.isEmpty {
                    map[sha, default: []].append(fileURL)
                }
            }
        }
        return map
    }

    /// 删掉 content/ 下没人引用的 jpeg。在 dedup 跑完后调一次, 用户清缓存
    /// 也会调到。开销 O(redirects + content), 都是 32 字节读, 很轻。
    ///
    /// 竞态保护: 建引用表与扫 content/ 之间存在窗口, 期间并发的
    /// writeContentAddressed 可能先写 content/<sha>.jpg、后写 redirect ref ——
    /// 若新 content 文件在建表之后才落盘, 它不会出现在引用表里, 会被误判成
    /// 孤儿删掉, 随后写下的 redirect 就指向已删内容。所以只删 mtime 早于
    /// `inFlightWriteGrace` 的孤儿, 给"内容已写、ref 待写"的在途写入留足
    /// 缓冲, 永不碰新近写入的 content 文件。
    @discardableResult
    nonisolated private static func collectOrphanedContent(
        references: [String: [URL]],
        contentDir: URL
    ) -> Bool {
        let fm = FileManager.default
        // 早于这个时刻写入的 content 文件才允许被当孤儿删除。
        let cutoff = Date().addingTimeInterval(-inFlightWriteGrace)

        // 扫 content/, 没在 referenced 集合里、且写入时间早于 cutoff 的才是孤儿
        guard let contents = try? fm.contentsOfDirectory(
            at: contentDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return true }
        var removed = 0
        for file in contents where file.pathExtension == "jpg" {
            guard !currentTaskIsCancelled() else { return false }
            let sha = file.deletingPathExtension().lastPathComponent
            guard references[sha] == nil else { continue }
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard mtime < cutoff else { continue }  // 新近写入的, 可能 ref 还在途, 留着
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 {
            plog("🧹 MetadataAssetStore content GC: removed \(removed) orphan(s)")
        }
        return true
    }

    // MARK: - Size cap / eviction

    /// content/ 总大小超 `maxBytes` 时, 按 mtime 倒序(最老优先)删掉 content
    /// 文件直到回到上限以下。
    ///
    /// 删 content 的同时必须把指向它的 ref 一并删掉并播出去。只删 content
    /// 会留下「有封面引用、字节却没了」的悬空状态: 读出来是 nil, 而
    /// `needsEmbeddedArtworkBackfill` 看到非空的 coverArtFileName 就认定这首
    /// 歌已经有封面, 永远不会重读 —— 内嵌封面又没有任何远端可以回源, 于是
    /// 用户只剩手动「重新读取文件标签」一条路。旧注释说的"下次读会落到
    /// nil → CachedArtworkView 网络重新拉"只对刮削来的网络封面成立。
    ///
    /// `protectedRefs` 引用到的 content 直接跳过: 本地源的内嵌封面要重新解析
    /// 音频文件才能重建, 代价远高于它占的那点空间。
    @discardableResult
    private func evictArtworkContentIfNeeded(
        maxBytes: Int64 = 500 * 1024 * 1024,
        references: [String: [URL]],
        protectedRefs: Set<String>
    ) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: artworkContentDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return true }

        struct Entry {
            let url: URL
            let sha: String
            let size: Int64
            let mtime: Date
            let isProtected: Bool
        }
        var entries: [Entry] = []
        var total: Int64 = 0
        var protectedBytes: Int64 = 0
        // 和孤儿 GC 同一条理由: 刚落盘的 content 可能还有一个 ref 在路上。
        let cutoff = Date().addingTimeInterval(-Self.inFlightWriteGrace)
        for url in contents where url.pathExtension == "jpg" {
            guard !Self.currentTaskIsCancelled() else { return false }
            let sha = url.deletingPathExtension().lastPathComponent
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            let mtime = v?.contentModificationDate ?? .distantPast
            let isProtected = mtime >= cutoff || (references[sha]?.contains {
                protectedRefs.contains($0.lastPathComponent)
            } ?? false)
            entries.append(Entry(url: url, sha: sha, size: size, mtime: mtime, isProtected: isProtected))
            total += size
            if isProtected { protectedBytes += size }
        }
        guard total > maxBytes else { return true }

        entries.sort { $0.mtime < $1.mtime }  // 老的在前
        var freed: Int64 = 0
        var evictedContent = 0
        var skippedProtected = 0
        var evictedRefs: Set<String> = []
        for e in entries {
            guard !Self.currentTaskIsCancelled() else { return false }
            if total - freed <= maxBytes { break }
            if e.isProtected {
                skippedProtected += 1
                continue
            }
            guard (try? fm.removeItem(at: e.url)) != nil else { continue }
            freed += e.size
            evictedContent += 1
            for refURL in references[e.sha] ?? [] {
                guard (try? fm.removeItem(at: refURL)) != nil else { continue }
                evictedRefs.insert(refURL.lastPathComponent)
            }
        }
        plog(
            "🧹 artwork content evict: freed=\(freed / 1024 / 1024)MB "
                + "total=\(total / 1024 / 1024)MB cap=\(maxBytes / 1024 / 1024)MB "
                + "content=\(evictedContent) refs=\(evictedRefs.count) "
                + "protectedSkipped=\(skippedProtected) protected=\(protectedBytes / 1024 / 1024)MB"
        )
        if total - freed > maxBytes {
            plog(
                "⚠️ artwork content evict: still \((total - freed) / 1024 / 1024)MB over cap "
                    + "after skipping \(skippedProtected) protected item(s)"
            )
        }
        if !evictedRefs.isEmpty {
            Self.postArtworkContentEvicted(refs: evictedRefs)
        }
        return true
    }

    /// 让资料库把这些 ref 从 `Song.coverArtFileName` 上摘掉, 回填队列才会重新
    /// 认得出「这首歌缺封面」。
    nonisolated private static func postArtworkContentEvicted(refs: Set<String>) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .primuseArtworkContentEvicted,
                object: nil,
                userInfo: ["refs": refs]
            )
        }
    }

    /// 派生缓存的纯容量驱逐 —— 目录里放的是可以随时重算的副本, 没有别处
    /// 指向它们, 所以不需要连带清理引用。
    private func evictArtworkDirectoryIfNeeded(_ directory: URL, maxBytes: Int64) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return true }

        struct Entry { let url: URL; let size: Int64; let mtime: Date }
        var entries: [Entry] = []
        var total: Int64 = 0
        for url in contents where url.pathExtension == "jpg" {
            guard !Self.currentTaskIsCancelled() else { return false }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            let mtime = v?.contentModificationDate ?? .distantPast
            entries.append(Entry(url: url, size: size, mtime: mtime))
            total += size
        }
        guard total > maxBytes else { return true }

        entries.sort { $0.mtime < $1.mtime }  // 老的在前
        var freed: Int64 = 0
        for e in entries {
            guard !Self.currentTaskIsCancelled() else { return false }
            if total - freed <= maxBytes { break }
            if (try? fm.removeItem(at: e.url)) != nil { freed += e.size }
        }
        plog("🧹 artwork cache evict: directory=\(directory.lastPathComponent) freed=\(freed / 1024 / 1024)MB total=\(total / 1024 / 1024)MB cap=\(maxBytes / 1024 / 1024)MB")
        return true
    }

    /// Runs all artwork migrations and cleanup in one cancellable maintenance
    /// pass. The caller records cadence only when this returns true.
    ///
    /// `protectedCoverRefs` 是调用方交来的「不要为了腾空间删掉」的封面引用,
    /// 目前是本地源的内嵌封面 —— 它们没有远端可以回源。
    func performScheduledContentMaintenance(
        protectedCoverRefs: Set<String> = []
    ) -> Bool {
        let targetDirs = [artworkDirectory, albumArtworkDirectory, artistArtworkDirectory]
        guard Self.runDedupMigrationIfNeeded(
            targetDirs: targetDirs,
            contentDir: artworkContentDirectory
        ) else { return false }
        // dedup 会重写 ref, 所以引用表要在它之后建, 孤儿 GC 与容量驱逐共用。
        guard let references = Self.contentReferenceMap(targetDirs: targetDirs) else {
            return false
        }
        guard Self.collectOrphanedContent(
            references: references,
            contentDir: artworkContentDirectory
        ) else { return false }
        return evictArtworkContentIfNeeded(
            references: references,
            protectedRefs: protectedCoverRefs
        ) && evictArtworkDirectoryIfNeeded(portableArtworkDirectoryURL, maxBytes: 48 * 1024 * 1024)
    }

    nonisolated private static func currentTaskIsCancelled() -> Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }
}

enum LibraryArtworkImageProcessor {
    private static let maximumInputBytes = 32 * 1024 * 1024
    private static let targetLongSides = [1200, 1024, 896, 768, 640]
    private static let qualities: [Double] = [0.86, 0.78, 0.70, 0.62, 0.54, 0.46]

    /// Inspect the encoded header only. Library caches commonly already hold
    /// a bounded JPEG, so decoding and recompressing it adds no transport value.
    nonisolated static func isReusablePortableJPEG(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes,
              ArtworkImageCompatibility.isCompleteImage(data),
              !ArtworkImageCompatibility.hasRedundantJPEGSampling(data),
              let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              max(width, height) <= targetLongSides[0] else { return false }
        return (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    }

    /// Decodes arbitrary picker input, applies orientation, bounds dimensions,
    /// and emits a JPEG small enough to fit inside the existing CloudKit Data
    /// envelope after JSON/base64 overhead.
    nonisolated static func process(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              !withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }),
              let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }

        for longSide in targetLongSides {
            guard !withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) else { return nil }
            guard let image = encodableImage(from: source, longSide: longSide) else { continue }
            for quality in qualities {
                guard !withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) else { return nil }
                guard let encoded = encodeJPEG(image, quality: quality) else { continue }
                if encoded.count <= LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes {
                    return encoded
                }
            }
        }
        return nil
    }

    /// 取一张长边不超过 `longSide`、且 JPEG 编码器一定收得下的位图。
    private nonisolated static func encodableImage(
        from source: CGImageSource,
        longSide: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) {
            // 缩略图路径带 `WithTransform`，出来就是摆正的。
            return jpegReadyImage(thumbnail, exifOrientation: 1)
        }
        return fullyDecodedImage(from: source, longSide: longSide)
    }

    /// ImageIO 生成不出缩略图时的兜底：整张解出来自己缩。
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` 并不是对每张能解码的图都成功，
    /// 而它返回 nil 时上层只会得到「这张图无效」——用户看到的就是选了照片
    /// 却没有任何变化。`CGImageSourceCreateImageAtIndex` 走的是完整解码器，
    /// 这类图基本都能解出来，代价是要自己按 EXIF 摆正并缩放。
    private nonisolated static func fullyDecodedImage(
        from source: CGImageSource,
        longSide: Int
    ) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapsDimensions = ArtworkImageNormalizationPolicy.swapsDimensions(forExif: orientation)
        guard let bounded = ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: swapsDimensions ? image.height : image.width,
            height: swapsDimensions ? image.width : image.height,
            longSide: longSide
        ) else { return nil }

        return redrawOpaque(
            image,
            width: bounded.width,
            height: bounded.height,
            exifOrientation: orientation
        )
    }

    /// 本来就是 8 bit 不透明 RGB/灰度的位图原样返回，其余的重画一遍。
    private nonisolated static func jpegReadyImage(
        _ image: CGImage,
        exifOrientation: Int
    ) -> CGImage? {
        let alpha = image.alphaInfo
        let opaqueLayouts: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        let hasAlpha = !opaqueLayouts.contains(alpha)
        let model = image.colorSpace?.model
        guard ArtworkImageNormalizationPolicy.requiresOpaqueRedraw(
            hasAlpha: hasAlpha,
            bitsPerComponent: image.bitsPerComponent,
            usesFloatComponents: image.bitmapInfo.contains(.floatComponents),
            isJPEGCompatibleColorModel: model == .rgb || model == .monochrome
        ) else { return image }
        return redrawOpaque(
            image,
            width: image.width,
            height: image.height,
            exifOrientation: exifOrientation
        )
    }

    /// 重画成不透明的 8 bit sRGB 位图，顺带按 EXIF 摆正。
    ///
    /// 透明区域铺白而不是留黑：这一类图多半是深色线条配透明底，压到黑底上
    /// 整张就糊成一片，而那正是 ImageIO 自己写 JPEG 时的默认行为。
    private nonisolated static func redrawOpaque(
        _ image: CGImage,
        width: Int,
        height: Int,
        exifOrientation: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let steps = ArtworkImageNormalizationPolicy.orientationSteps(forExif: exifOrientation)
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // CGContext 的正角度是逆时针，steps 说的是顺时针。
        context.rotate(by: -CGFloat(steps.quarterTurnsClockwise) * .pi / 2)
        // 后写的变换先作用到图上，所以镜像写在旋转之后，语义仍是「先镜像再旋转」。
        if steps.mirroredHorizontally {
            context.scaleBy(x: -1, y: 1)
        }

        let drawsRotated = steps.quarterTurnsClockwise % 2 == 1
        let drawWidth = drawsRotated ? height : width
        let drawHeight = drawsRotated ? width : height
        context.draw(image, in: CGRect(
            x: -CGFloat(drawWidth) / 2,
            y: -CGFloat(drawHeight) / 2,
            width: CGFloat(drawWidth),
            height: CGFloat(drawHeight)
        ))
        return context.makeImage()
    }

    private nonisolated static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }
}
