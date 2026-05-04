import Foundation
import PrimuseKit

@MainActor
@Observable
final class SourceManager {
    private var connectors: [String: any MusicSourceConnector] = [:]
    private let sourcesProvider: @Sendable () async throws -> [MusicSource]

    init(database: LibraryDatabase) {
        self.sourcesProvider = {
            try await database.allSources()
        }
    }

    init(sourcesProvider: @escaping @Sendable () async throws -> [MusicSource]) {
        self.sourcesProvider = sourcesProvider
        // When a re-scan detects that the bytes behind a known path
        // changed (user replaced the file on the cloud drive), the old
        // local cache file is now stale. Wipe it so the next play
        // re-streams against the new bytes instead of decoding the
        // previous content.
        NotificationCenter.default.addObserver(
            forName: .primuseSongContentChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let songs = (note.userInfo?["songs"] as? [Song]) ?? []
            MainActor.assumeIsolated {
                for song in songs {
                    self.deleteAudioCache(for: song)
                    let cache = self.cacheURL(for: song)
                    let partial = URL(fileURLWithPath: cache.path + ".partial")
                    try? FileManager.default.removeItem(at: partial)
                    let marker = URL(fileURLWithPath: cache.path + ".partial.prewarmed")
                    try? FileManager.default.removeItem(at: marker)
                }
            }
        }
    }

    func connector(for source: MusicSource) -> any MusicSourceConnector {
        return connector(for: source, cache: true)
    }

    private func connector(for source: MusicSource, cache: Bool) -> any MusicSourceConnector {
        if cache, let existing = connectors[source.id] {
            return existing
        }

        let connector: any MusicSourceConnector
        switch source.type {
        case .synology:
            connector = SynologySource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 5001,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? "",
                rememberDevice: source.rememberDevice,
                deviceId: source.deviceId
            )
        case .local:
            connector = LocalFileSource(
                sourceID: source.id,
                basePath: URL(fileURLWithPath: source.basePath ?? "/")
            )
        case .smb:
            connector = SMBSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 445,
                sharePath: source.shareName ?? "",
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .webdav:
            connector = WebDAVSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                useSsl: source.useSsl,
                basePath: source.basePath,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .ftp:
            connector = FTPSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                basePath: source.basePath,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? "",
                encryption: source.ftpEncryption ?? .none
            )
        case .sftp:
            connector = SFTPSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                basePath: source.basePath,
                username: source.username ?? "",
                secret: KeychainService.getPassword(for: source.id) ?? "",
                authType: source.authType
            )
        case .nfs:
            connector = NFSSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                exportPath: source.exportPath,
                nfsVersion: source.nfsVersion ?? .auto
            )
        case .upnp:
            connector = UPnPSource(sourceID: source.id)
        case .jellyfin, .emby, .plex:
            connector = MediaServerSource(
                sourceID: source.id,
                kind: MediaServerSource.Kind(sourceType: source.type)!,
                host: source.host ?? "",
                port: source.port,
                useSsl: source.useSsl,
                basePath: source.basePath,
                username: source.username ?? "",
                secret: KeychainService.getPassword(for: source.id) ?? "",
                authType: source.authType
            )
        case .qnap:
            connector = QnapSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 8080,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .ugreen:
            connector = UgreenSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 9999,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .fnos:
            connector = FnOSSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 5666,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .baiduPan:
            connector = BaiduPanSource(sourceID: source.id)
        case .aliyunDrive:
            connector = AliyunDriveSource(sourceID: source.id)
        case .googleDrive:
            connector = GoogleDriveSource(sourceID: source.id)
        case .oneDrive:
            connector = OneDriveSource(sourceID: source.id)
        case .dropbox:
            connector = DropboxSource(sourceID: source.id)
        case .s3:
            // S3 uses host=endpoint, basePath=bucket, extraConfig=JSON{region}
            let extraJson = (try? JSONSerialization.jsonObject(with: Data((source.extraConfig ?? "{}").utf8))) as? [String: String] ?? [:]
            connector = S3Source(
                sourceID: source.id,
                endpoint: source.host ?? "s3.amazonaws.com",
                region: extraJson["region"] ?? "us-east-1",
                bucket: source.basePath ?? "",
                accessKey: source.username ?? "",
                secretKey: KeychainService.getPassword(for: source.id) ?? "",
                useSsl: source.useSsl
            )
        }

        if cache {
            connectors[source.id] = connector
        }
        return connector
    }

    /// Custom URL scheme that signals "play this song via streaming
    /// SFBInputSource" — AudioPlayerService intercepts it and routes to
    /// CloudPlaybackSource instead of doing a full download.
    static let cloudStreamingScheme = "primuse-stream"

    func resolveURL(for song: Song) async throws -> URL {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }

        let conn = connector(for: source)
        try await conn.connect()

        // Priority 1: Cached local file (instant playback)
        if let cached = cachedURL(for: song) {
            return cached
        }
        // Priority 2: Range streaming via CloudPlaybackSource — 边下边播,
        // ~500ms 出首个 PCM buffer。AudioPlayerService 看到 cloud-stream://
        // scheme 后会调 makeStreamingInputSource 走 sparse cache。
        // 比 Priority 3 的 plain streamingURL 优先,因为后者会触发
        // StreamingDownloadDecoder 整文件下载(40MB flac 等 6.1s)。
        if source.supportsRangeStreaming, song.fileSize > 0 {
            var components = URLComponents()
            components.scheme = Self.cloudStreamingScheme
            components.host = song.sourceID
            components.path = song.filePath.hasPrefix("/") ? song.filePath : "/" + song.filePath
            if let url = components.url {
                return url
            }
        }
        // Priority 3: Streaming URL (sources without Range support, 或
        // fileSize 未知的 legacy 条目)。走 StreamingDownloadDecoder 整下。
        if let streamURL = try await conn.streamingURL(for: song.filePath) {
            return streamURL
        }
        // Priority 4: Download to local (sources without streaming URL).
        return try await conn.localURL(for: song.filePath)
    }

    // MARK: - Audio Cache

    private static let audioCacheDirName = "primuse_audio_cache"

    private func audioCacheDirectory(for sourceID: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cachedURL(for song: Song) -> URL? {
        let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
        let fileURL = audioCacheDirectory(for: song.sourceID).appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let relativePath = "\(song.sourceID)/\(sanitized)"
        Task { await AudioCacheManager.shared.recordAccess(path: relativePath) }
        return fileURL
    }

    func cacheURL(for song: Song) -> URL {
        let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
        return audioCacheDirectory(for: song.sourceID).appendingPathComponent(sanitized)
    }

    private static var smbCacheDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("primuse_smb_cache")
    }

    func audioCacheSize() -> Int64 {
        var total: Int64 = 0
        let dirs = [
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent(Self.audioCacheDirName),
            Self.smbCacheDir,
        ]
        for basePath in dirs {
            guard let enumerator = FileManager.default.enumerator(
                at: basePath, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    /// 给「存储管理」页用的统计 —— 把 audio cache 拆成三类:
    /// - completed: 完整下完的歌曲 (rename 成 final 名), 受 2GB LRU 控制
    /// - partial: `.partial` / `.partial.prewarmed` 半成品 (用户跳过 /
    ///   prewarm 完没听), 启动时 7 天清一次, 也可以这里手动一键清
    /// - orphaned: 子目录里的文件, 但 sourceID 已经不在 sources 表里
    ///   (用户删过源 / source ID 变更), 没人会再访问, 全是垃圾
    struct AudioCacheBreakdown {
        var completedBytes: Int64 = 0
        /// 「真半成品」—— 用户播到一半切走的, 或下载失败的。下次还有用
        /// (sparse cache 复用) 但用户视角是「中断了」。
        var partialBytes: Int64 = 0
        /// 「预热种子」—— prewarmCloudSong 写的 head + tail (合计 ~1.25MB / 首),
        /// 让下次播首次解码秒出。看着是 .partial 但属于设计内的小种子,
        /// 不应该让用户误以为出问题了。判定方法: `.partial` 旁边有
        /// `.partial.prewarmed` marker 文件且自身大小 < 2MB。
        var prewarmSeedBytes: Int64 = 0
        var orphanedBytes: Int64 = 0
        var orphanedSourceIDs: Set<String> = []
    }

    func audioCacheBreakdown() async -> AudioCacheBreakdown {
        var result = AudioCacheBreakdown()
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
        let aliveSourceIDs: Set<String>
        if let sources = try? await sourcesProvider() {
            aliveSourceIDs = Set(sources.map { $0.id })
        } else {
            aliveSourceIDs = []
        }

        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: basePath, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return result }

        // 先收集所有 .partial.prewarmed marker 路径, 后面判断 .partial 是否
        // 是「预热种子」时用。
        let fm = FileManager.default
        var prewarmMarkers: Set<String> = []
        for sourceDir in subdirs {
            guard (try? sourceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let e = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let fileURL = e.nextObject() as? URL {
                    if fileURL.lastPathComponent.hasSuffix(".partial.prewarmed") {
                        prewarmMarkers.insert(fileURL.path)
                    }
                }
            }
        }

        for sourceDir in subdirs {
            guard (try? sourceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let sid = sourceDir.lastPathComponent
            let isOrphan = !aliveSourceIDs.contains(sid)
            if isOrphan { result.orphanedSourceIDs.insert(sid) }

            let enumerator = fm.enumerator(
                at: sourceDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                let size = Int64((try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                let name = fileURL.lastPathComponent
                if isOrphan {
                    result.orphanedBytes += size
                    continue
                }
                if name.hasSuffix(".partial.prewarmed") {
                    // marker 本身, 算到 prewarm 类
                    result.prewarmSeedBytes += size
                } else if name.hasSuffix(".partial") {
                    // 旁边有 marker 且本身较小 = prewarm 种子, 否则真半成品
                    let markerPath = fileURL.path + CloudPlaybackSource.prewarmMarkerSuffix
                    let isSeed = prewarmMarkers.contains(markerPath) && size < 2 * 1024 * 1024
                    if isSeed {
                        result.prewarmSeedBytes += size
                    } else {
                        result.partialBytes += size
                    }
                } else {
                    result.completedBytes += size
                }
            }
        }
        return result
    }

    /// 一键清掉所有孤立 sourceID 的整个 cache 子目录。
    func purgeOrphanedAudioCache() async {
        let breakdown = await audioCacheBreakdown()
        for sid in breakdown.orphanedSourceIDs {
            purgeAudioCache(forSourceID: sid)
        }
    }

    /// 一键清掉所有 `.partial` 半成品 (无视 mtime, 等价于用户主动决定
    /// 「不要任何半下载文件了」)。正在 streaming 的歌会立即变成 cache miss
    /// 重新下, 但不会丢功能。
    @discardableResult
    func purgeAllPartialFiles() -> (freedBytes: Int64, failedCount: Int) {
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
        var freed: Int64 = 0
        var failed = 0
        guard let enumerator = FileManager.default.enumerator(
            at: basePath, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var partials: [(URL, Int64)] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasSuffix(".partial") || name.hasSuffix(".partial.prewarmed") else { continue }
            let size = Int64((try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            partials.append((fileURL, size))
        }
        for (url, size) in partials {
            do {
                try FileManager.default.removeItem(at: url)
                freed += size
            } catch {
                failed += 1
            }
        }
        plog("🧹 purgeAllPartialFiles: freed \(freed / 1024 / 1024)MB, failed=\(failed)")
        return (freed, failed)
    }

    func deleteAudioCache(for song: Song) {
        let cacheURL = cacheURL(for: song)
        try? FileManager.default.removeItem(at: cacheURL)
        let relativePath = "\(song.sourceID)/\(song.filePath.replacingOccurrences(of: "/", with: "_"))"
        Task { await AudioCacheManager.shared.removeEntry(path: relativePath) }
    }

    /// 清空所有音频缓存。返回 (成功删除字节数, 失败文件数)。
    ///
    /// 之前的版本对整个目录调一次 removeItem(at:), 任何一个文件 handle
    /// 没释放 (audio engine 正在读, NSURLSession 还在写) 就整个失败,
    /// `try?` 又吞错误 — 用户以为清了实际没动。现在先递归枚举每个文件
    /// 单独删, 把 in-flight 文件之外的都干掉, 只对 cache 目录的整个
    /// removeItem 是 best-effort 的最后一步。
    @discardableResult
    func clearAudioCache() -> (freedBytes: Int64, failedCount: Int) {
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
        var freed: Int64 = 0
        var failed = 0

        for dir in [basePath, Self.smbCacheDir] {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            // 先收集再删, 避免 enumerator 边删边遍历崩。
            var files: [(URL, Int64)] = []
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                files.append((fileURL, Int64(values.totalFileAllocatedSize ?? 0)))
            }
            for (url, size) in files {
                do {
                    try FileManager.default.removeItem(at: url)
                    freed += size
                } catch {
                    failed += 1
                    plog("⚠️ clearAudioCache: cannot remove \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // 文件都删完了, 子目录就空了, 一把删掉; 失败也不要紧 (可能仍有
            // in-flight 文件, 下次 clear 再清)。
            try? FileManager.default.removeItem(at: dir)
        }

        Task { await AudioCacheManager.shared.clearAll() }
        plog("🧹 clearAudioCache: freed \(freed / 1024 / 1024)MB, failed=\(failed)")
        return (freed, failed)
    }

    /// 启动时清掉超过 `olderThanDays` 没动的 `.partial` 半成品 + 对应的
    /// `.partial.prewarmed` marker。这些文件平时无人管 —— Range streaming
    /// 路径只在歌完整下完后 rename, 用户跳过 / prewarm 完没接着播的歌
    /// 会留下一堆 `.partial` 永久占盘。LRU 也只盯 final 文件, 看不到
    /// `.partial`。
    ///
    /// 只清 mtime 超过阈值的, 现在正在 streaming 的 `.partial` (mtime
    /// 是新的) 不会被误删。
    func pruneStalePartialFiles(olderThanDays days: Int = 7) {
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
        guard let enumerator = FileManager.default.enumerator(
            at: basePath,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var removedBytes: Int64 = 0
        var removedCount = 0
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasSuffix(".partial") || name.hasSuffix(".partial.prewarmed") else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey]),
                  let mtime = values.contentModificationDate,
                  mtime < cutoff else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            if (try? FileManager.default.removeItem(at: fileURL)) != nil {
                removedBytes += size
                removedCount += 1
            }
        }
        if removedCount > 0 {
            let mb = Double(removedBytes) / 1_048_576
            plog("🧹 pruned \(removedCount) stale .partial files (\(String(format: "%.1f", mb)) MB)")
        }
    }

    /// 删除指定 source 的整个 audio cache 子目录 + LRU 里属于这个源的记录。
    /// 只在 LibraryService.removeSource() 流程里用 —— 用户主动删源时一并
    /// 回收磁盘, 不然 caches/primuse_audio_cache/<sourceID>/ 里的整本歌
    /// + `.partial` 半成品永远没人动。
    func purgeAudioCache(forSourceID sourceID: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
            .appendingPathComponent(sourceID)
        try? FileManager.default.removeItem(at: dir)
        Task { await AudioCacheManager.shared.removeAllEntries(forSourcePrefix: "\(sourceID)/") }
    }

    /// Background-cache a song file (generalized for all sources).
    /// Cloud sources take a different path: instead of pre-downloading the
    /// whole file (wasteful — they stream on demand anyway), we just warm
    /// the connector's dlink cache and pull the first chunk into the
    /// `.partial` cache file. Result: when the user hits "next", the
    /// dlink is already resolved and the first 256KB is local — playback
    /// starts in <100ms instead of 500ms-1s of dlink+head latency.
    /// Pass `cacheEnabled: false` (when the user has Audio Cache off) to
    /// skip the prewarm/cache write entirely — we'll still play the song
    /// fine, just without the latency win.
    func cacheInBackground(song: Song, cacheEnabled: Bool = true) {
        guard cachedURL(for: song) == nil else { return }
        Task {
            do {
                let sources = try await sourcesProvider()
                guard let source = sources.first(where: { $0.id == song.sourceID }) else {
                    plog("⚠️ Cache: source not found for '\(song.title)'")
                    return
                }
                let conn = connector(for: source)
                try await conn.connect()

                if source.supportsRangeStreaming, song.fileSize > 0 {
                    if cacheEnabled {
                        await prewarmCloudSong(song: song, connector: conn)
                    }
                    return
                }
                guard cacheEnabled else { return }

                guard let streamURL = try await conn.streamingURL(for: song.filePath) else {
                    plog("⚠️ Cache: no streaming URL for '\(song.title)'")
                    return
                }
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 300
                let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                let (tempURL, response) = try await session.download(from: streamURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    plog("⚠️ Cache: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for '\(song.title)'")
                    return
                }
                let target = cacheURL(for: song)
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                await AudioCacheManager.shared.evictIfNeeded(reserveBytes: song.fileSize)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tempURL, to: target)
                let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
                await AudioCacheManager.shared.recordAccess(path: "\(song.sourceID)/\(sanitized)")
                plog("✅ Cache: '\(song.title)' cached successfully")
            } catch {
                plog("⚠️ Cache failed for '\(song.title)': \(error.localizedDescription)")
            }
        }
    }

    /// Prewarm a cloud song so the next "play" is instant:
    /// - Resolve and cache the dlink (saves the 200-500ms multi-API round trip)
    /// - Pull the first 256KB into the `.partial` cache file
    ///
    /// `CloudPlaybackSource` recognises a `.partial` file at exactly the
    /// prewarm head size as a trustworthy seed and re-uses the bytes when
    /// the actual play session starts — so the very first SFB read hits
    /// disk, not the network. Idempotent on repeat calls.
    private func prewarmCloudSong(song: Song, connector: any MusicSourceConnector) async {
        if isPrewarmed(song: song) { return }
        let fileSize = song.fileSize
        guard fileSize > 0 else { return }
        do {
            // 并发拉 head + tail —— SFB.open() 必读 mp3 ID3v1 (tail 128B),
            // 不预热 tail 就会触发 1-2s 的 user-facing fetch 卡顿。
            // 短文件 (head + tail overlap) 时 tail 直接为空。
            let tailSize = min(Self.prewarmTailSize, max(0, fileSize - Self.prewarmHeadSize))
            async let headData = connector.fetchRange(path: song.filePath, offset: 0, length: Self.prewarmHeadSize)
            async let tailData: Data = tailSize > 0
                ? connector.fetchRange(path: song.filePath, offset: fileSize - tailSize, length: tailSize)
                : Data()
            let (head, tail) = try await (headData, tailData)
            seedPrewarmCache(song: song, head: head, tail: tail, fileSize: fileSize)
        } catch {
            plog("⚠️ Prewarm failed for '\(song.title)': \(error.localizedDescription)")
        }
    }

    static let prewarmHeadSize: Int64 = CloudPlaybackSource.prewarmHeadBytes
    static let prewarmTailSize: Int64 = CloudPlaybackSource.prewarmTailBytes

    /// Same as `prewarmCloudSong` but accepts a Song directly and resolves
    /// the connector itself. Exposed so `ScanService` can run a serialized
    /// prewarm sweep over every cloud song in a fresh scan (avoiding the
    /// fire-and-forget `cacheInBackground` which spawns one Task per song
    /// and would stampede the connector).
    func prewarmCloudSongPublic(song: Song) async {
        guard let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == song.sourceID }),
              source.supportsRangeStreaming else { return }
        let conn = connector(for: source)
        do { try await conn.connect() } catch { return }
        await prewarmCloudSong(song: song, connector: conn)
    }

    /// 主动结束 `song` 对应的 streaming session: 把 .partial 推向 final
    /// (如果缺口在自动补齐阈值内) 或者保持原状。AudioPlayerService 在
    /// 切歌 / stop / 播完时调, 让 .partial 不依赖 SFB 是否还会读字节就能
    /// 走完应有的 rename 路径。
    func finalizeStreamingSession(for song: Song) {
        let cache = cacheURL(for: song)
        let partialPath = cache.path + ".partial"
        CloudPlaybackSource.finalizeSession(partialPath: partialPath)
    }

    /// True if `song` lives on a source that supports HTTP Range streaming
    /// (i.e. would go through `CloudPlaybackSource` at play time). Used by
    /// metadata backfill to decide whether to seed the prewarm cache —
    /// local/file sources never hit `CloudPlaybackSource`, so writing a
    /// `.partial` for them would waste disk for nothing.
    func songSupportsRangeStreaming(_ song: Song) async -> Bool {
        guard let sources = try? await sourcesProvider() else { return false }
        return sources.first(where: { $0.id == song.sourceID })?.supportsRangeStreaming ?? false
    }

    /// Already-prewarmed marker check. Marker JSON 存在 + partial 文件
    /// 大小覆盖所有 listed ranges + head range 长度 >= 当前 prewarmHeadSize
    /// 才算 prewarm。head 长度检查让 prewarm head 调大后旧 partial 自然
    /// 重新 prewarm (不会被旧 256KB head 短路)。
    func isPrewarmed(song: Song) -> Bool {
        let cache = cacheURL(for: song)
        let partial = URL(fileURLWithPath: cache.path + ".partial")
        let marker = URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix)
        guard let m = CloudPlaybackSource.PrewarmMarker.read(from: marker),
              FileManager.default.fileExists(atPath: partial.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: partial.path),
              let size = attrs[.size] as? Int64,
              let maxEnd = m.swiftRanges.map(\.upperBound).max(),
              size >= maxEnd,
              let firstRange = m.swiftRanges.first,
              firstRange.lowerBound == 0,
              (firstRange.upperBound - firstRange.lowerBound) >= Self.prewarmHeadSize
        else { return false }
        return true
    }

    /// 兼容旧调用方 (MetadataBackfillService 拿到 head bytes 时只 seed head)。
    /// 新代码应使用 `seedPrewarmCache(song:head:tail:fileSize:)`。
    func seedPrewarmCache(song: Song, head: Data) {
        seedPrewarmCache(song: song, head: head, tail: Data(), fileSize: 0)
    }

    /// Write `head` (+ optional `tail`) to the song's sparse `.partial` cache
    /// and place the prewarm marker JSON. Used by `prewarmCloudSong` and
    /// MetadataBackfillService (head-only, via the compatibility overload).
    /// fileSize=0 means "tail unknown, only seed head".
    func seedPrewarmCache(song: Song, head: Data, tail: Data, fileSize: Int64) {
        guard !head.isEmpty else { return }
        let cache = cacheURL(for: song)
        let partial = URL(fileURLWithPath: cache.path + ".partial")
        let marker = URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix)

        // Already seeded with at least equivalent ranges? Skip.
        if isPrewarmed(song: song) {
            return
        }

        try? FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: marker)

        do {
            // 写 sparse partial: head 在 offset 0, tail 在 fileSize-tail.count
            // (中间 byte hole, file system 自动 sparse, 不占实际空间)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)
            try handle.write(contentsOf: head)
            var ranges: [[Int64]] = [[0, Int64(head.count)]]
            if !tail.isEmpty, fileSize > Int64(head.count) {
                let tailOffset = fileSize - Int64(tail.count)
                if tailOffset >= Int64(head.count) {  // 不覆盖 head
                    try handle.seek(toOffset: UInt64(tailOffset))
                    try handle.write(contentsOf: tail)
                    ranges.append([tailOffset, fileSize])
                }
            }
            try handle.close()
            // marker JSON 必须最后写 —— 如果中间崩溃, 没 marker 就不信任 partial。
            let m = CloudPlaybackSource.PrewarmMarker(v: CloudPlaybackSource.PrewarmMarker.currentVersion, ranges: ranges)
            try m.write(to: marker)
            plog("⏩ Prewarm: '\(song.title)' head=\(head.count / 1024)KB tail=\(tail.count / 1024)KB cached")
        } catch {
            plog("⚠️ Prewarm seed failed for '\(song.title)': \(error.localizedDescription)")
        }
    }

    /// Build a streaming `SFBInputSource` for `song`. Used by
    /// AudioPlayerService when `resolveURL` returns a `primuse-stream://`
    /// URL. The returned source reads via HTTP Range and writes fetched
    /// chunks to the same cache file used by `localURL` — once enough
    /// ranges accumulate (or the user replays after a full listen) the
    /// next play hits Priority 1 above and bypasses streaming entirely.
    /// When `cacheEnabled` is false (the user disabled Audio Cache), the
    /// streaming partial is routed to `NSTemporaryDirectory` and is never
    /// promoted to the canonical cache path — the file is still needed
    /// during the session for SFB to read from, but iOS reaps the temp
    /// directory on its own schedule afterward.
    func makeStreamingInputSource(for song: Song, cacheEnabled: Bool = true) async throws -> InputSource? {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let conn = connector(for: source)
        try await conn.connect()
        guard song.fileSize > 0 else { return nil }
        let cache = cacheEnabled
            ? cacheURL(for: song)
            : URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("primuse-stream-\(song.id)")

        // 启动 streaming 之前先按预计大小腾位置 —— Range streaming 路径以前
        // 完全没接 LRU, 缓存可以无限胀。这里做最低限度的 evict (只在持久化
        // 模式下), 让 2GB 上限对 NAS 也生效。注意是异步, 不阻塞首播 ——
        // 真正写满前不一定能 evict 完, 但能保证 LRU 不再被绕过。
        let cacheRelativePath: String?
        if cacheEnabled {
            let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
            cacheRelativePath = "\(song.sourceID)/\(sanitized)"
            await AudioCacheManager.shared.evictIfNeeded(reserveBytes: song.fileSize)
        } else {
            cacheRelativePath = nil
        }

        return CloudPlaybackSource.makeInputSource(
            song: song,
            totalLength: song.fileSize,
            connector: conn,
            cacheURL: cache,
            persistOnComplete: cacheEnabled,
            cacheRelativePath: cacheRelativePath
        )
    }

    /// Get the shared connector for a song's source (for playback and file writing).
    func connectorForSong(_ song: Song) async throws -> any MusicSourceConnector {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let conn = connector(for: source)
        try await conn.connect()
        return conn
    }

    /// Lyrics / cover / scrape 都直接复用 playback connector(cached pool)。
    /// 之前用独立 instance"避免 actor blocking",但实测 connector 内 fetchRange
    /// 全是 await 点(让出 actor), 多个调用交错执行不会真 serial block。
    /// 复用 main connector 的最大好处: prewarm 阶段已经 connect 过, lyrics
    /// Tier3 第一首歌的 connect() 直接走 isLoggedIn 短路,免去 SSL+login 2-3s。
    func auxiliaryConnector(for song: Song) async throws -> any MusicSourceConnector {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let conn = connector(for: source)  // cache: true, 复用
        try await conn.connect()  // idempotent on isLoggedIn
        return conn
    }


    /// Get a direct HTTP URL for an image file on the source (for cover art display).
    /// Uses the shared connector — lightweight, just builds a URL without downloading.
    func imageURL(for path: String, sourceID: String) async -> URL? {
        guard let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        let conn = connector(for: source)
        return try? await conn.imageURL(for: path)
    }

    func refreshConnector(for sourceID: String) async {
        guard let connector = connectors.removeValue(forKey: sourceID) else { return }
        await connector.disconnect()
    }

    func removeConnector(for sourceID: String) async {
        await refreshConnector(for: sourceID)
    }

    func disconnectAll() async {
        for (_, connector) in connectors {
            await connector.disconnect()
        }
        connectors.removeAll()
    }
}

private extension MusicSource {
    var supportsRangeStreaming: Bool {
        type.category == .cloudDrive
            || type == .webdav
            || type == .synology
            || type == .qnap
            || type == .ugreen
            || type == .fnos
            || type == .s3
            || type == .smb
            || type == .sftp
            || type == .ftp
            || type == .nfs
    }
}
