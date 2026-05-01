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
        if source.type.category == .cloudDrive, song.fileSize > 0 {
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

                if source.type.category == .cloudDrive, song.fileSize > 0 {
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
        let cache = cacheURL(for: song)
        let partial = URL(fileURLWithPath: cache.path + ".partial")

        // Already prewarmed (file exists at expected head size) — skip.
        let headSize: Int64 = 256 * 1024
        if let attrs = try? FileManager.default.attributesOfItem(atPath: partial.path),
           let size = attrs[.size] as? Int64,
           size == headSize {
            return
        }

        do {
            let head = try await connector.fetchRange(path: song.filePath, offset: 0, length: headSize)
            guard !head.isEmpty else { return }
            try? FileManager.default.createDirectory(
                at: partial.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic write: this either replaces an old/garbage partial or
            // creates a fresh one. Either way, file size after = head.count,
            // which the State init uses as the "trustable seed" signal.
            try head.write(to: partial, options: .atomic)
            plog("⏩ Prewarm: '\(song.title)' head=\(head.count / 1024)KB cached")
        } catch {
            plog("⚠️ Prewarm failed for '\(song.title)': \(error.localizedDescription)")
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
