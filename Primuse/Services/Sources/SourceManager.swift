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
        // Priority 2: Streaming URL (Synology and similar — direct HTTP URL)
        if let streamURL = try await conn.streamingURL(for: song.filePath) {
            return streamURL
        }
        // Priority 3: Cloud-drive sources with a known fileSize go through
        // the streaming SFBInputSource — instant playback, lazy on-disk
        // caching. AudioPlayerService spots the custom scheme and uses
        // CloudPlaybackSource. Falls back to full download for sources
        // without a usable fileSize (rare; only happens before the first
        // metadata refresh on legacy entries).
        if source.supportsRangeStreaming, song.fileSize > 0 {
            var components = URLComponents()
            components.scheme = Self.cloudStreamingScheme
            components.host = song.sourceID
            components.path = song.filePath.hasPrefix("/") ? song.filePath : "/" + song.filePath
            if let url = components.url {
                return url
            }
        }
        // Priority 4: Download to local (legacy path; still required for
        // sources without Range support).
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
                at: basePath, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    func deleteAudioCache(for song: Song) {
        let cacheURL = cacheURL(for: song)
        try? FileManager.default.removeItem(at: cacheURL)
        let relativePath = "\(song.sourceID)/\(song.filePath.replacingOccurrences(of: "/", with: "_"))"
        Task { await AudioCacheManager.shared.removeEntry(path: relativePath) }
    }

    func clearAudioCache() {
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
        try? FileManager.default.removeItem(at: basePath)
        try? FileManager.default.removeItem(at: Self.smbCacheDir)
        Task { await AudioCacheManager.shared.clearAll() }
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
        do {
            let head = try await connector.fetchRange(path: song.filePath, offset: 0, length: Self.prewarmHeadSize)
            seedPrewarmCache(song: song, head: head)
        } catch {
            plog("⚠️ Prewarm failed for '\(song.title)': \(error.localizedDescription)")
        }
    }

    static let prewarmHeadSize: Int64 = 256 * 1024

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

    /// True if `song` lives on a source that supports HTTP Range streaming
    /// (i.e. would go through `CloudPlaybackSource` at play time). Used by
    /// metadata backfill to decide whether to seed the prewarm cache —
    /// local/file sources never hit `CloudPlaybackSource`, so writing a
    /// `.partial` for them would waste disk for nothing.
    func songSupportsRangeStreaming(_ song: Song) async -> Bool {
        guard let sources = try? await sourcesProvider() else { return false }
        return sources.first(where: { $0.id == song.sourceID })?.supportsRangeStreaming ?? false
    }

    /// Already-prewarmed marker check. Used by both `prewarmCloudSong` and
    /// any other caller that has the head bytes in hand and wants to skip
    /// re-writing them.
    func isPrewarmed(song: Song) -> Bool {
        let cache = cacheURL(for: song)
        let partial = URL(fileURLWithPath: cache.path + ".partial")
        let marker = URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix)
        guard FileManager.default.fileExists(atPath: marker.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: partial.path),
              let size = attrs[.size] as? Int64,
              size == Self.prewarmHeadSize else { return false }
        return true
    }

    /// Write `head` to the song's `.partial` cache and place the prewarm
    /// marker. Used when another path (e.g. metadata backfill) already
    /// fetched the head bytes — avoids a second network round-trip just to
    /// pre-populate the disk cache for the next play.
    func seedPrewarmCache(song: Song, head: Data) {
        guard head.count >= Int(Self.prewarmHeadSize) else { return }
        let cache = cacheURL(for: song)
        let partial = URL(fileURLWithPath: cache.path + ".partial")
        let marker = URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix)
        if FileManager.default.fileExists(atPath: marker.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: partial.path),
           let size = attrs[.size] as? Int64,
           size == Self.prewarmHeadSize {
            return  // already seeded
        }
        try? FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            // Atomic write of partial first, then marker — order matters:
            // if power fails between them, no marker means
            // CloudPlaybackSource will discard the partial rather than
            // trusting partial bytes.
            let trimmed = head.prefix(Int(Self.prewarmHeadSize))
            try trimmed.write(to: partial, options: .atomic)
            FileManager.default.createFile(atPath: marker.path, contents: nil)
            plog("⏩ Prewarm: '\(song.title)' head=\(trimmed.count / 1024)KB cached")
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
        return CloudPlaybackSource.makeInputSource(
            song: song,
            totalLength: song.fileSize,
            connector: conn,
            cacheURL: cache,
            persistOnComplete: cacheEnabled
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

    /// Create a **separate** connector instance for auxiliary tasks (lyrics, cover art).
    /// This avoids blocking the shared playback connector's actor queue.
    func auxiliaryConnector(for song: Song) async throws -> any MusicSourceConnector {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        // Create a fresh connector — not cached, independent actor instance
        let conn = connector(for: source, cache: false)
        try await conn.connect()
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
        type.category == .cloudDrive || type == .webdav
    }
}
