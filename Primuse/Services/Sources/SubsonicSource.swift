import CryptoKit
import Foundation
import PrimuseKit

/// Subsonic / OpenSubsonic 服务端曲库源。首个验证对象是 Navidrome, 但只用
/// 通用 Subsonic API, 因此同样适用于 Airsonic / Gonic / Ampache 等。
///
/// 与 NAS / 文件源不同, 它不浏览目录树而是"全库扫描": 服务端直接给出
/// title / artist / album / duration / cover, 绕开本地读文件头回填。
///
/// 播放策略(智能混合):
/// - 本地能解码的格式 → `stream?format=raw` 原文件, 走已知大小的 HTTP Range
///   稀疏缓存(边下边播, 播完整曲落盘, 与离线下载一致)。
/// - 本地解不了的格式(主要 WMA) → 服务端转码 mp3 渐进流, 不做持久缓存。
///
/// 离线下载始终取 `download` 原文件。
actor SubsonicSource: RefreshingMetadataSongConnector, ServerScrobblingConnector, ServerLyricsConnector,
    ServerCatalogChangeDetectingConnector, ServerCatalogScanRequestingConnector,
    ResumablePagedSongCatalogConnector,
    ServerPlaylistConnector, ServerFavoriteConnector, ServerRadioConnector,
    ServerListeningStatsConnector {
    let sourceID: String

    private let sourceType: MusicSourceType
    private let baseURL: URL          // 形如 https://host:4533 (+ basePath), 不含 /rest
    private let username: String
    private let salt: String
    private let token: String         // md5(password + salt)
    private let apiVersion: String
    private let encodedPassword: String
    private var usesEncodedPassword: Bool
    private let session: URLSession
    private let cacheDirectory: URL
    private let mirrorsStarredSongsAsPlaylist: Bool

    private var isConnected = false
    /// 服务端类型与 OpenSubsonic 能力 —— 从 ping 响应读。决定歌词走 OpenSubsonic
    /// `getLyricsBySongId`(Navidrome/Gonic)还是老 `getLyrics`(Airsonic 等非 OpenSubsonic)。
    private var serverType: String?
    private var isOpenSubsonic = false

    /// Airsonic Advanced 目前只接受 1.15.0，对更高版本会返回错误 30。
    /// 其他实现保持 1.16.1；OpenSubsonic 扩展能力仍由 ping 响应单独探测。
    private static let defaultAPIVersion = "1.16.1"
    private static let airsonicAPIVersion = "1.15.0"
    private static let clientName = "Primuse"
    private static let pageSize = SubsonicCatalogPagingPolicy.pageSize
    private static let transcodeBitRate = 320  // 转码目标码率 kbps
    private static let catalogRequestMaximumAttempts = 3
    private static let catalogSnapshotMaximumAttempts = 2

    func fetchServerCatalogScanStatus() async throws -> ServerCatalogScanStatus {
        let container: ScanStatusContainer = try await requestJSON("getScanStatus")
        try Self.rejectFailedServerScan(container.scanStatus)
        return Self.scanStatus(from: container)
    }

    func requestServerCatalogScan() async throws -> ServerCatalogScanRequestResult {
        try await connect()
        do {
            let container: ScanStatusContainer = try await responseJSON(
                "startScan",
                query: [URLQueryItem(name: "fullScan", value: "true")]
            )
            guard container.status == "ok" else {
                if container.error?.code == 50 {
                    return .permissionDenied
                }
                if Self.isServerScanAPIUnavailable(container.error?.message ?? "") {
                    return .unsupported
                }
                throw Self.error(from: container.error)
            }
            return .accepted(Self.scanStatus(from: container))
        } catch let statusError as SubsonicHTTPStatusError {
            switch statusError.statusCode {
            case 403:
                return .permissionDenied
            case 404, 405, 410, 501:
                return .unsupported
            case 401:
                throw SourceError.authenticationFailed
            default:
                throw SourceError.connectionFailed("HTTP \(statusError.statusCode)")
            }
        } catch let sourceError as SourceError {
            if case .connectionFailed(let detail) = sourceError,
               Self.isServerScanAPIUnavailable(detail) {
                return .unsupported
            }
            throw sourceError
        }
    }

    func stableSongCatalogRevision() async throws -> String? {
        try await connect()
        guard SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: isOpenSubsonic,
            serverType: serverType
        ) else {
            throw PagedSongCatalogError.unavailable
        }
        let container: ScanStatusContainer
        do {
            container = try await responseJSON("getScanStatus")
        } catch let statusError as SubsonicHTTPStatusError {
            switch statusError.statusCode {
            case 403, 404, 405, 410, 501:
                throw PagedSongCatalogError.unavailable
            case 401:
                throw SourceError.authenticationFailed
            default:
                throw SourceError.connectionFailed("HTTP \(statusError.statusCode)")
            }
        }
        guard container.status == "ok" else {
            if container.error?.code == 50
                || Self.isDirectCatalogUnavailable(container.error?.message ?? "") {
                throw PagedSongCatalogError.unavailable
            }
            throw Self.error(from: container.error)
        }
        guard container.scanStatus?.scanning != true else {
            throw PagedSongCatalogError.snapshotChangedDuringPagination
        }
        try Self.rejectFailedServerScan(container.scanStatus)
        let lastScan = container.scanStatus?.lastScan ?? ""
        let count = container.scanStatus?.count.map(String.init) ?? ""
        guard !lastScan.isEmpty else {
            throw SourceError.connectionFailed(
                "Navidrome did not provide a stable catalog revision"
            )
        }
        return "\(lastScan)|\(count)"
    }

    func songCatalogPage(from path: String, offset: Int) async throws -> PagedSongCatalogPage {
        try await connect()
        guard SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: isOpenSubsonic,
            serverType: serverType
        ) else {
            throw PagedSongCatalogError.unavailable
        }

        let children: [SubsonicChild]
        do {
            children = try await search3SongPage(offset: offset, path: path)
        } catch SubsonicCompatibilityError.directCatalogUnavailable {
            throw PagedSongCatalogError.unavailable
        }
        let songs = children.compactMap { child -> ConnectorScannedSong? in
            guard child.isVideo != true else { return nil }
            let song = buildSong(from: child)
            return ConnectorScannedSong(
                song: song,
                displayName: child.title ?? song.title,
                titleMetadataInspected: ServerCatalogMetadataInspectionPolicy.hasUsableTitle(child.title),
                folderLocation: libraryFolderLocation(for: child)
            )
        }
        return PagedSongCatalogPage(
            songs: songs,
            itemIDs: children.map(\.id),
            nextOffset: SubsonicCatalogPagingPolicy.nextOffset(
                currentOffset: offset,
                receivedCount: children.count
            )
        )
    }

    init(
        sourceID: String,
        sourceType: MusicSourceType,
        host: String,
        port: Int?,
        useSsl: Bool,
        basePath: String?,
        username: String,
        password: String,
        alternateTLSValidationHostname: String? = nil,
        session: URLSession? = nil
    ) {
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.baseURL = Self.makeBaseURL(host: host, port: port, useSsl: useSsl, basePath: basePath)
        self.username = username
        self.apiVersion = sourceType == .airsonic
            ? Self.airsonicAPIVersion
            : Self.defaultAPIVersion
        // Airsonic Advanced 的新密码存储不支持 Subsonic 的 MD5 token 校验，
        // 但仍支持规范中的 `p=enc:<UTF-8 hex>` 形式。
        self.encodedPassword = Self.hexEncoded(password)
        self.usesEncodedPassword = sourceType == .airsonic
        self.mirrorsStarredSongsAsPlaylist = sourceType == .airsonic || sourceType == .gonic
        let salt = Self.randomSalt()
        self.salt = salt
        self.token = Self.md5Hex(password + salt)

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Matches WebDAV / Synology / S3: a catalogue page is 500 songs of JSON
            // and a full walk is one request per page, which needs more than a
            // LAN-sized budget over the public internet.
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            configuration.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
            // 家用 Navidrome 常用自签 HTTPS, 复用全局 SmartSSLDelegate 放行受信任证书。
            self.session = URLSession(
                configuration: configuration,
                delegate: SmartSSLDelegate(
                    redirectPolicy: .sameEndpoint,
                    alternateServerTrustHostname: alternateTLSValidationHostname,
                    alternateServerTrustEndpoint: NetworkEndpointIdentity(
                        scheme: useSsl ? "https" : "http",
                        host: host,
                        port: port
                    )
                ),
                delegateQueue: nil
            )
        }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_subsonic_cache_\(sourceID)")
            .appendingPathComponent(
                MusicSourceSecurityRevision.cacheNamespace(for: sourceID)
            )
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory
    }

    // MARK: - Connection

    func connect() async throws {
        if isConnected { return }
        guard username.isEmpty == false else { throw SourceError.authenticationFailed }
        // requestJSON 已统一校验 envelope status, status != "ok"(含认证 error 40/41)直接抛错。
        let ping: PingContainer
        do {
            ping = try await requestJSON("ping")
        } catch SubsonicCompatibilityError.tokenAuthenticationUnsupported {
            usesEncodedPassword = true
            ping = try await requestJSON("ping")
        }
        serverType = ping.type
        isOpenSubsonic = ping.openSubsonic ?? false
        isConnected = true
    }

    func disconnect() async {
        isConnected = false
    }

    // MARK: - Library listing / scanning

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        // 全库源不浏览目录树, 扫描走 scanSongs("/")。这里只服务于"连接体检"的
        // 可见性检查: 尽量返回顶层音乐文件夹(getMusicFolders)。getMusicFolders
        // 失败/形状异常时不抛错 —— 否则体检会把它当作阻断性失败而中止扫描;
        // 连接已 ping 通, 退回一个代表整库的合成根即可让体检如实通过。
        try await connect()
        if let container: MusicFoldersContainer = try? await requestJSON("getMusicFolders"),
           let folders = container.musicFolders?.musicFolder, !folders.isEmpty {
            return folders.map { folder in
                RemoteFileItem(
                    name: folder.name ?? "Music",
                    path: "/folders/\(folder.id)",
                    isDirectory: true,
                    size: 0,
                    modifiedDate: nil
                )
            }
        }
        return [RemoteFileItem(name: "Library", path: "/", isDirectory: true, size: 0, modifiedDate: nil)]
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let stream = try await scanSongs(from: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await scanned in stream {
                        continuation.yield(
                            RemoteFileItem(
                                name: scanned.displayName,
                                path: scanned.song.filePath,
                                isDirectory: false,
                                size: scanned.song.fileSize,
                                modifiedDate: scanned.song.lastModified
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled ? continuation.finish() : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    // OpenSubsonic defines an empty search3 query as the direct
                    // full-media enumeration path for offline sync. Navidrome
                    // implements it, reducing an N+1 album walk to one request
                    // per 500 songs. Build a stable snapshot before yielding so
                    // transient WAN failures or a moving offset window cannot
                    // leave the scanner with a partial authoritative catalog.
                    if SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
                        isOpenSubsonic: isOpenSubsonic,
                        serverType: serverType
                    ) {
                        let catalog: [SubsonicChild]?
                        do {
                            catalog = try await fetchStableSearch3Catalog(path: path)
                        } catch SubsonicCompatibilityError.directCatalogUnavailable {
                            try Task.checkCancellation()
                            plog("⚠️ Subsonic direct catalog unavailable; falling back to album walk")
                            catalog = nil
                        } catch {
                            throw error
                        }

                        if let catalog {
                            try yieldSearch3Catalog(catalog, continuation: continuation)
                            continuation.finish()
                            return
                        }
                    }

                    var offset = 0
                    var seenAlbumIDs = Set<String>()
                    var seenSongIDs = Set<String>()
                    // 逐页拉专辑列表, 再对每个专辑取曲目(getAlbum 自带完整 Child 元数据)。
                    while true {
                        try Task.checkCancellation()
                        let listContainer: AlbumListContainer = try await requestJSON(
                            "getAlbumList2",
                            query: [
                                URLQueryItem(name: "type", value: "alphabeticalByName"),
                                URLQueryItem(name: "size", value: String(Self.pageSize)),
                                URLQueryItem(name: "offset", value: String(offset))
                            ]
                        )
                        guard let albumList = listContainer.albumList2 else {
                            throw SourceError.connectionFailed("Subsonic getAlbumList2 response is missing albumList2")
                        }
                        let albums = albumList.album ?? []
                        if albums.isEmpty { break }

                        let newAlbums = albums.filter { seenAlbumIDs.insert($0.id).inserted }
                        if albums.count >= Self.pageSize, newAlbums.isEmpty {
                            throw SourceError.connectionFailed("Subsonic getAlbumList2 pagination repeated a full page")
                        }
                        guard SubsonicCatalogPagingPolicy.isWithinAlbumLimit(seenAlbumIDs.count) else {
                            throw SourceError.connectionFailed("Subsonic album catalog exceeded the safety limit")
                        }

                        let albumResults = try await fetchLegacyAlbums(newAlbums)
                        for result in albumResults {
                            for child in result.songs where child.isVideo != true {
                                try Task.checkCancellation()
                                guard seenSongIDs.insert(child.id).inserted else { continue }
                                guard SubsonicCatalogPagingPolicy.isWithinSongLimit(seenSongIDs.count) else {
                                    throw SourceError.connectionFailed("Subsonic song catalog exceeded the safety limit")
                                }
                                let song = buildSong(from: child, album: result.album)
                                continuation.yield(
                                    ConnectorScannedSong(
                                        song: song,
                                        displayName: child.title ?? song.title,
                                        titleMetadataInspected: ServerCatalogMetadataInspectionPolicy.hasUsableTitle(
                                            child.title
                                        ),
                                        folderLocation: libraryFolderLocation(
                                            for: child,
                                            album: result.album
                                        )
                                    )
                                )
                            }
                        }

                        offset += albums.count
                        if albums.count < Self.pageSize { break }
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled ? continuation.finish() : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func fetchServerListeningStats() async throws -> ServerListeningStatsPayload {
        try await connect()
        let catalog = try await fetchCompleteStatsCatalog()
        let tracks = catalog.map { child in
            ServerListeningTrackAggregate(
                remoteTrackID: child.id,
                title: child.title ?? child.id,
                artist: child.artist ?? child.displayArtist,
                album: child.album,
                playCount: child.playCount ?? 0,
                lastPlayedAt: child.played.flatMap(Self.parseDate)
            )
        }
        let payload = ServerListeningStatsPayload(
            accountFingerprint: ServerListeningStatsFingerprint.account(
                service: sourceType.rawValue,
                endpoint: baseURL.absoluteString,
                accountIdentifier: username
            ),
            temporalDetail: .aggregate,
            tracks: tracks
        )
        guard payload.isStructurallyValid else {
            throw ServerListeningStatsConnectorError.invalidSnapshot
        }
        return payload
    }

    /// Statistics are published only after the complete catalogue has been read.
    /// This deliberately does not consume `scanSongs`, whose legacy path streams rows
    /// before the final page and therefore cannot provide an atomic server snapshot.
    private func fetchCompleteStatsCatalog() async throws -> [SubsonicChild] {
        if SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: isOpenSubsonic,
            serverType: serverType
        ) {
            do {
                if let catalog = try await fetchStableSearch3Catalog(path: "/") {
                    return catalog
                }
            } catch SubsonicCompatibilityError.directCatalogUnavailable {
                try Task.checkCancellation()
            }
        }

        var offset = 0
        var seenAlbumIDs = Set<String>()
        var seenSongIDs = Set<String>()
        var catalog: [SubsonicChild] = []
        while true {
            try Task.checkCancellation()
            let listContainer: AlbumListContainer = try await requestJSON(
                "getAlbumList2",
                query: [
                    URLQueryItem(name: "type", value: "alphabeticalByName"),
                    URLQueryItem(name: "size", value: String(Self.pageSize)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ]
            )
            guard let albumList = listContainer.albumList2 else {
                throw ServerListeningStatsConnectorError.invalidSnapshot
            }
            let albums = albumList.album ?? []
            if albums.isEmpty { break }
            let newAlbums = albums.filter { seenAlbumIDs.insert($0.id).inserted }
            if albums.count >= Self.pageSize, newAlbums.isEmpty {
                throw ServerListeningStatsConnectorError.historyChangedDuringPagination
            }
            guard SubsonicCatalogPagingPolicy.isWithinAlbumLimit(seenAlbumIDs.count) else {
                throw ServerListeningStatsConnectorError.invalidSnapshot
            }

            for result in try await fetchLegacyAlbums(newAlbums) {
                for child in result.songs where child.isVideo != true {
                    try Task.checkCancellation()
                    guard seenSongIDs.insert(child.id).inserted else { continue }
                    guard SubsonicCatalogPagingPolicy.isWithinSongLimit(seenSongIDs.count) else {
                        throw ServerListeningStatsConnectorError.invalidSnapshot
                    }
                    catalog.append(child)
                }
            }
            offset += albums.count
            if albums.count < Self.pageSize { break }
        }
        return catalog
    }

    private func search3SongPage(offset: Int, path: String) async throws -> [SubsonicChild] {
        var finalError: Error?
        for attempt in 0..<Self.catalogRequestMaximumAttempts {
            do {
                let container: Search3Container = try await requestJSON(
                    "search3",
                    query: SubsonicCatalogPagingPolicy.search3QueryItems(
                        songOffset: offset,
                        musicFolderID: musicFolderID(from: path)
                    )
                )
                guard let result = container.searchResult3 else {
                    throw SubsonicCompatibilityError.directCatalogUnavailable
                }
                return result.song ?? []
            } catch let SourceError.connectionFailed(message)
                where Self.isDirectCatalogUnavailable(message) {
                throw SubsonicCompatibilityError.directCatalogUnavailable
            } catch {
                guard attempt + 1 < Self.catalogRequestMaximumAttempts,
                      RemoteDirectoryTransportErrorPolicy.isRetryable(error) else {
                    throw error
                }
                finalError = error
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw finalError ?? SourceError.connectionFailed("Subsonic search3 request failed")
    }

    private func fetchLegacyAlbums(_ albums: [AlbumSummary]) async throws -> [LegacyAlbumResult] {
        guard !albums.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: LegacyAlbumResult.self) { group in
            let initialCount = min(SubsonicCatalogPagingPolicy.legacyAlbumConcurrency, albums.count)
            for index in 0..<initialCount {
                let album = albums[index]
                group.addTask { [self] in
                    try await fetchLegacyAlbum(album, index: index)
                }
            }

            var nextIndex = initialCount
            var results: [LegacyAlbumResult] = []
            results.reserveCapacity(albums.count)
            while let result = try await group.next() {
                results.append(result)
                if nextIndex < albums.count {
                    let index = nextIndex
                    let album = albums[index]
                    nextIndex += 1
                    group.addTask { [self] in
                        try await fetchLegacyAlbum(album, index: index)
                    }
                }
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private func fetchLegacyAlbum(_ album: AlbumSummary, index: Int) async throws -> LegacyAlbumResult {
        let container: AlbumContainer = try await requestJSON(
            "getAlbum",
            query: [URLQueryItem(name: "id", value: album.id)]
        )
        guard let albumWithSongs = container.album else {
            throw SourceError.connectionFailed("Subsonic getAlbum response is missing album")
        }
        return LegacyAlbumResult(index: index, album: album, songs: albumWithSongs.song ?? [])
    }

    private func fetchStableSearch3Catalog(path: String) async throws -> [SubsonicChild]? {
        for attempt in 0..<Self.catalogSnapshotMaximumAttempts {
            do {
                let firstPage = try await search3SongPage(offset: 0, path: path)
                guard !firstPage.isEmpty else { return nil }
                return try await collectSearch3Catalog(firstPage: firstPage, path: path)
            } catch SubsonicCompatibilityError.catalogChangedDuringPagination {
                guard attempt + 1 < Self.catalogSnapshotMaximumAttempts else {
                    throw SourceError.connectionFailed(
                        "Subsonic search3 catalog changed repeatedly during pagination"
                    )
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw SourceError.connectionFailed("Subsonic search3 catalog snapshot failed")
    }

    private func collectSearch3Catalog(
        firstPage: [SubsonicChild],
        path: String
    ) async throws -> [SubsonicChild] {
        var offset = 0
        var page = firstPage
        var seenResultIDs = Set<String>()
        var catalog: [SubsonicChild] = []

        while true {
            try Task.checkCancellation()
            for child in page {
                try Task.checkCancellation()
                guard seenResultIDs.insert(child.id).inserted else {
                    throw SubsonicCompatibilityError.catalogChangedDuringPagination
                }
                guard child.isVideo != true else { continue }
                catalog.append(child)
            }

            guard SubsonicCatalogPagingPolicy.isWithinSongLimit(seenResultIDs.count) else {
                throw SourceError.connectionFailed("Subsonic song catalog exceeded the safety limit")
            }
            guard let nextOffset = SubsonicCatalogPagingPolicy.nextOffset(
                currentOffset: offset,
                receivedCount: page.count
            ) else { return catalog }
            offset = nextOffset
            page = try await search3SongPage(offset: offset, path: path)
        }
    }

    private func yieldSearch3Catalog(
        _ catalog: [SubsonicChild],
        continuation: AsyncThrowingStream<ConnectorScannedSong, Error>.Continuation
    ) throws {
        for child in catalog {
            try Task.checkCancellation()
            let song = buildSong(from: child)
            continuation.yield(
                ConnectorScannedSong(
                    song: song,
                    displayName: child.title ?? song.title,
                    titleMetadataInspected: ServerCatalogMetadataInspectionPolicy.hasUsableTitle(
                        child.title
                    ),
                    folderLocation: libraryFolderLocation(for: child)
                )
            )
        }
    }

    private func musicFolderID(from path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2,
              String(components[0]).caseInsensitiveCompare("folders") == .orderedSame else { return nil }
        return String(components[1])
    }

    // MARK: - Playback URLs

    func streamingURL(for path: String) async throws -> URL? {
        try await connect()
        guard let songID = songID(from: path) else { throw SourceError.fileNotFound(path) }
        let format = AudioFormat.from(fileExtension: (path as NSString).pathExtension)

        if let format, Self.requiresServerTranscode(format) {
            // 本地解不了 → 服务端转码 mp3 渐进流。带 transcoded 标记让播放层
            // 走 AVAssetReader 渐进解码(不按已知大小做 Range, 不持久缓存)。
            return buildRESTURL(
                method: "stream",
                query: [
                    URLQueryItem(name: "id", value: songID),
                    URLQueryItem(name: "format", value: "mp3"),
                    URLQueryItem(name: "maxBitRate", value: String(Self.transcodeBitRate)),
                    URLQueryItem(name: SourceManager.transcodedStreamQueryKey, value: "1")
                ]
            )
        }

        // 原文件流: 字节大小与扫描记录一致, 支持 HTTP Range 稀疏缓存。
        return buildRESTURL(
            method: "stream",
            query: [
                URLQueryItem(name: "id", value: songID),
                URLQueryItem(name: "format", value: "raw")
            ]
        )
    }

    func localURL(for path: String) async throws -> URL {
        try await connect()
        guard let songID = songID(from: path) else { throw SourceError.fileNotFound(path) }

        let ext = (path as NSString).pathExtension.isEmpty ? "bin" : (path as NSString).pathExtension
        let fileURL = cacheDirectory.appendingPathComponent("\(songID).\(ext)")
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }

        // 离线下载始终取原文件(download), 不转码 → 大小与扫描一致, 可被缓存校验。
        guard let remoteURL = buildRESTURL(method: "download", query: [URLQueryItem(name: "id", value: songID)]) else {
            throw SourceError.fileNotFound(path)
        }
        let (temporaryURL, response) = try await TrustedHTTPTransport.download(
            from: remoteURL,
            session: session,
            timeout: 120
        )
        do {
            try validate(response)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return fileURL
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { try? handle.close() }
                    while true {
                        let chunk = handle.readData(ofLength: 64 * 1024)
                        if chunk.isEmpty { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// HTTP Range 读取原文件流 —— 给 prewarm(head+tail) 与 CloudPlaybackSource
    /// 稀疏缓存用。负 offset(从尾部)用 HTTP suffix range 兜底, 但服务端源
    /// 元数据齐全, backfill 跳过它, 正常只会收到正 offset。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await connect()
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        guard let songID = songID(from: path),
              let url = buildRESTURL(
                  method: "stream",
                  query: [
                    URLQueryItem(name: "id", value: songID),
                    URLQueryItem(name: "format", value: "raw")
                  ]
              ) else {
            throw SourceError.fileNotFound(path)
        }

        var request = URLRequest(url: url)
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let requestedBytes = Int(clamping: max(length, 0))
        let responseLimit = requestedBytes > Int.max - 64 * 1024
            ? Int.max
            : requestedBytes + 64 * 1024
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: session,
            maxBytes: max(PlainHTTPClient.defaultMaxBytes, responseLimit)
        )
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid Subsonic range response")
        }
        switch http.statusCode {
        case 206:
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw SourceError.connectionFailed("Invalid Subsonic Content-Range response")
            }
            return data
        case 200:
            guard HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw SourceError.connectionFailed("Subsonic server ignored the byte Range request")
            }
            return data
        default:
            throw SourceError.connectionFailed("Subsonic range request failed: HTTP \(http.statusCode)")
        }
    }

    // MARK: - Scrobble (ServerScrobblingConnector)

    func scrobble(songPath: String, submission: Bool) async {
        guard (try? await connect()) != nil, let songID = songID(from: songPath) else { return }
        guard let url = buildRESTURL(
            method: "scrobble",
            query: [
                URLQueryItem(name: "id", value: songID),
                URLQueryItem(name: "submission", value: submission ? "true" : "false")
            ]
        ) else { return }
        // 尽力而为: 失败不影响播放, 也不重试(回报不是关键路径)。
        _ = try? await TrustedHTTPTransport.data(from: url, session: session)
    }

    // MARK: - Lyrics (ServerLyricsConnector)

    func fetchServerLyrics(for path: String) async -> String? {
        guard (try? await connect()) != nil, let songID = songID(from: path) else { return nil }
        // getLyricsBySongId is an OpenSubsonic extension. Calling it on
        // Airsonic Advanced produces a server-side 404 exception before the
        // legacy fallback, even though playback itself succeeds. Route by the
        // capability advertised by ping so each family receives only the API
        // it implements.
        if isOpenSubsonic {
            return await modernLyrics(songID: songID)
        }
        return await legacyLyrics(songID: songID)
    }

    /// OpenSubsonic getLyricsBySongId —— 结构化(可带时间轴)歌词。
    private func modernLyrics(songID: String) async -> String? {
        // songLyrics v2 gates cue-level karaoke timing behind enhanced=true.
        // Most older servers ignore the optional parameter and keep returning
        // the version 1 line array. If one rejects unknown parameters, retry
        // the original request so enabling karaoke does not regress lyrics.
        let enhanced: LyricsContainer? = try? await requestJSON(
            "getLyricsBySongId",
            query: [
                URLQueryItem(name: "id", value: songID),
                URLQueryItem(name: "enhanced", value: "true"),
            ]
        )
        let container: LyricsContainer
        if let enhanced {
            container = enhanced
        } else {
            guard !Task.isCancelled,
                  let versionOne: LyricsContainer = try? await requestJSON(
                      "getLyricsBySongId",
                      query: [URLQueryItem(name: "id", value: songID)]
                  ) else {
                return nil
            }
            container = versionOne
        }
        guard let tracks = container.lyricsList?.structuredLyrics else { return nil }
        return OpenSubsonicLyricsConverter.text(from: tracks)
    }

    /// 老 Subsonic getLyrics —— 按 artist+title 匹配, 只返回无时间轴纯文本。
    /// 给非 OpenSubsonic 服务端(Airsonic 等)兜底。先 getSong 拿 artist/title。
    private func legacyLyrics(songID: String) async -> String? {
        guard let songContainer: GetSongContainer = try? await requestJSON(
            "getSong",
            query: [URLQueryItem(name: "id", value: songID)]
        ),
        let child = songContainer.song, let title = child.title else {
            return nil
        }
        var query = [URLQueryItem(name: "title", value: title)]
        if let artist = Self.cleaned(child.artist, unknown: "[Unknown Artist]")
            ?? Self.cleaned(child.displayArtist, unknown: "[Unknown Artist]") {
            query.append(URLQueryItem(name: "artist", value: artist))
        }
        guard let container: LegacyLyricsContainer = try? await requestJSON("getLyrics", query: query),
              let text = container.lyrics?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - Server playlists

    /// `getPlaylists` 列出当前用户可播放的歌单(含别人分享的 public 歌单),
    /// 再逐个 `getPlaylist` 取曲目。两个方法自 Subsonic API 1.0.0 就存在,
    /// Navidrome / Airsonic / gonic / Ampache 全家族都实现, 因此不做能力探测。
    ///
    /// 单个歌单取曲目失败只跳过它, 不让整次同步失败 —— 一个坏歌单不该挡住
    /// 其余歌单。`getPlaylist` 规范上没有分页参数, 一次返回全部 `entry`。
    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        try await connect()
        let container: PlaylistsContainer = try await requestJSON("getPlaylists")
        let summaries = container.playlists?.playlist ?? []

        var result: [ServerPlaylist] = []
        var failedPlaylistIDs = Set<String>()
        result.reserveCapacity(summaries.count + 1)
        for summary in summaries {
            try Task.checkCancellation()
            let detail: PlaylistContainer
            do {
                detail = try await requestJSON(
                    "getPlaylist",
                    query: [URLQueryItem(name: "id", value: summary.id.value)]
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                plog("⚠️ Subsonic getPlaylist '\(summary.name ?? summary.id.value)' failed: \(error.localizedDescription)")
                failedPlaylistIDs.insert(summary.id.value)
                continue
            }
            guard let playlist = detail.playlist else {
                failedPlaylistIDs.insert(summary.id.value)
                plog("⚠️ Subsonic getPlaylist '\(summary.name ?? summary.id.value)' returned no playlist detail")
                continue
            }
            let trackIDs = (playlist.entry ?? []).map(\.id)
            // 名字缺失时退回服务端 ID, 保证镜像歌单不会出现空标题。
            let name = Self.cleaned(playlist.name ?? summary.name, unknown: "")
                ?? summary.id.value
            result.append(ServerPlaylist(
                id: summary.id.value,
                name: name,
                coverArtReference: (playlist.coverArt ?? summary.coverArt)
                    .flatMap { coverArtURLString(for: $0) },
                trackIDs: trackIDs,
                reportedTrackCount: playlist.songCount ?? summary.songCount
            ))
        }

        // Airsonic/gonic retain the legacy read-only mirror. Navidrome and the
        // explicit Subsonic source now reconcile getStarred2 into Primuse's
        // system liked playlist, so emitting a second mirror would duplicate it.
        if mirrorsStarredSongsAsPlaylist {
            do {
                let starred: Starred2Container = try await requestJSON("getStarred2")
                let songs = starred.starred2?.song ?? []
                if !songs.isEmpty {
                    result.append(ServerPlaylist(
                        id: Self.starredPlaylistID,
                        name: String(localized: "playlist_liked_name"),
                        coverArtReference: songs.first?.coverArt.flatMap { coverArtURLString(for: $0) },
                        trackIDs: songs.map(\.id),
                        reportedTrackCount: songs.count
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                failedPlaylistIDs.insert(Self.starredPlaylistID)
                plog("⚠️ Subsonic getStarred2 failed: \(error.localizedDescription)")
            }
        }
        return ServerPlaylistSnapshot(
            playlists: result,
            failedPlaylistIDs: failedPlaylistIDs
        )
    }

    private static let starredPlaylistID = "primuse.subsonic.starred-songs"

    // MARK: - Server favorites

    func fetchServerFavorites() async throws -> ServerFavoriteSnapshot {
        try await connect()
        return try await fetchServerFavoriteSnapshot()
    }

    func setServerFavorite(
        itemID: String,
        isFavorite: Bool
    ) async throws -> ServerFavoriteSnapshot {
        try await connect()
        guard !itemID.isEmpty,
              !itemID.contains("/"),
              !itemID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw SourceError.fileNotFound(itemID)
        }

        let _: EmptyContainer = try await requestJSON(
            isFavorite ? "star" : "unstar",
            query: [URLQueryItem(name: "id", value: itemID)]
        )
        let refreshed = try await fetchServerFavoriteSnapshot()
        guard refreshed.itemIDs.contains(itemID) == isFavorite else {
            throw SourceError.connectionFailed(String(localized: "server_favorite_refresh_mismatch"))
        }
        return refreshed
    }

    private func fetchServerFavoriteSnapshot() async throws -> ServerFavoriteSnapshot {
        let starred: Starred2Container = try await requestJSON("getStarred2")
        return ServerFavoriteSnapshot(itemIDs: (starred.starred2?.song ?? []).map(\.id))
    }

    // MARK: - Internet radio

    /// `getInternetRadioStations` is part of Subsonic 1.9.0. Navidrome and
    /// Subsonic expose it directly; Airsonic supports the read endpoint while
    /// older compatible servers may not. Unsupported-method responses return
    /// nil so reconciliation preserves existing mirrors instead of treating
    /// an unavailable capability as an authoritative empty list.
    func fetchServerRadioStations() async throws -> ServerRadioStationSnapshot? {
        try await connect()
        let container: InternetRadioStationsContainer
        do {
            container = try await requestJSON("getInternetRadioStations")
        } catch {
            if Self.isInternetRadioAPIUnavailable(error) { return nil }
            throw error
        }

        let upstreamStations = container.internetRadioStations
            .flatMap(\.internetRadioStation) ?? []
        let stations = upstreamStations.map { station in
            let name = Self.cleaned(station.name, unknown: "") ?? station.id.value
            let format = station.streamURL.flatMap(URL.init(string:))
                .map { RadioStreamFormat.inferred(from: $0) } ?? .automatic
            return ServerRadioStation(
                id: station.id.value,
                name: name,
                streamURL: station.streamURL,
                homepageURL: station.homePageURL,
                coverArtReference: station.coverArt.flatMap { coverArtURLString(for: $0) },
                streamFormat: format
            )
        }
        return ServerRadioStationSnapshot(stations: stations)
    }

    // MARK: - Song construction

    private func buildSong(from child: SubsonicChild, album: AlbumSummary? = nil) -> Song {
        let suffix = (child.suffix ?? (child.path.map { ($0 as NSString).pathExtension }) ?? "mp3").lowercased()
        let format = AudioFormat.from(fileExtension: suffix) ?? .mp3
        let relativePath = "/songs/\(child.id).\(suffix.isEmpty ? "mp3" : suffix)"
        let coverArtID = child.coverArt ?? album?.coverArt

        // 单曲艺术家常缺标签 → Subsonic 返回 "[Unknown Artist]" 占位; 回退到
        // 专辑艺术家。真正全空的归一成 nil, 让 Primuse 走自己的"未知"处理,
        // 而不是显示字面量 "[Unknown Artist]"。专辑名同理。
        let sourceArtistNames = child.artists?.compactMap {
            Self.cleaned($0.name, unknown: "[Unknown Artist]")
        }.reduce(into: [String]()) { result, name in
            guard !result.contains(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) else { return }
            result.append(name)
        } ?? []
        let artist = Self.cleaned(child.displayArtist, unknown: "[Unknown Artist]")
            ?? (sourceArtistNames.count > 1
                ? sourceArtistNames.joined(separator: "; ")
                : sourceArtistNames.first)
            ?? Self.cleaned(child.artist, unknown: "[Unknown Artist]")
            ?? Self.cleaned(album?.artist, unknown: "[Unknown Artist]")
        let albumTitle = Self.cleaned(child.album, unknown: "[Unknown Album]")
            ?? Self.cleaned(album?.name, unknown: "[Unknown Album]")
        let joinedAlbumArtists = child.albumArtists.flatMap { artists -> String? in
            let names = artists.compactMap {
                Self.cleaned($0.name, unknown: "[Unknown Artist]")
            }
            return Self.cleaned(names.joined(separator: ", "), unknown: "[Unknown Artist]")
        }
        let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: Self.cleaned(child.displayAlbumArtist, unknown: "[Unknown Artist]")
                ?? joinedAlbumArtists
                ?? Self.cleaned(album?.artist, unknown: "[Unknown Artist]"),
            trackArtistName: artist
        )

        return Song(
            id: Self.hash("\(sourceID):\(relativePath)"),
            title: child.title ?? "Unknown",
            albumID: child.albumId,
            artistID: child.artistId,
            albumTitle: albumTitle,
            artistName: artist,
            sourceArtistNames: sourceArtistNames.count > 1 ? sourceArtistNames : nil,
            albumArtistName: albumArtist,
            trackNumber: child.track,
            discNumber: child.discNumber,
            duration: TimeInterval(child.duration ?? 0),
            fileFormat: format,
            filePath: relativePath,
            sourceID: sourceID,
            fileSize: child.size ?? 0,
            bitRate: child.bitRate,
            sampleRate: child.samplingRate,
            bitDepth: child.bitDepth,
            genre: child.genre,
            year: child.year,
            lastModified: child.created.flatMap(Self.parseDate),
            coverArtFileName: coverArtID.flatMap { coverArtURLString(for: $0) },
            artistArtworkFileName: (child.artists?.first?.id ?? child.artistId)
                .flatMap { artistArtworkReference(for: $0) }
        )
    }

    private func libraryFolderLocation(
        for child: SubsonicChild,
        album: AlbumSummary? = nil
    ) -> ConnectorLibraryFolderLocation {
        let displayAlbumArtist = Self.cleaned(
            child.displayAlbumArtist,
            unknown: "[Unknown Artist]"
        )
        let albumArtistNames = child.albumArtists?.compactMap {
            Self.cleaned($0.name, unknown: "[Unknown Artist]")
        } ?? []
        let trackArtistName = Self.cleaned(child.displayArtist, unknown: "[Unknown Artist]")
            ?? Self.cleaned(child.artist, unknown: "[Unknown Artist]")
        let albumSummaryArtist = Self.cleaned(album?.artist, unknown: "[Unknown Artist]")
        let artistName = displayAlbumArtist
            ?? (albumArtistNames.isEmpty ? nil : albumArtistNames.joined(separator: ", "))
            ?? albumSummaryArtist
            ?? trackArtistName
        let albumName = Self.cleaned(child.album, unknown: "[Unknown Album]")
            ?? Self.cleaned(album?.name, unknown: "[Unknown Album]")
        var fallback: [ConnectorLibraryFolderComponent] = []
        if let artistName {
            let artistIdentity: String
            if displayAlbumArtist != nil {
                let matchingID = child.albumArtists?.first { candidate in
                    guard let name = Self.cleaned(candidate.name, unknown: "[Unknown Artist]") else {
                        return false
                    }
                    return name.caseInsensitiveCompare(artistName) == .orderedSame
                }?.id
                let identity = matchingID
                    ?? ConnectorLibraryFolderHierarchy.stableNameIdentity(artistName)
                artistIdentity = "album-artist:\(identity)"
            } else if !albumArtistNames.isEmpty {
                let identities = child.albumArtists?.compactMap { candidate -> String? in
                    guard let name = Self.cleaned(candidate.name, unknown: "[Unknown Artist]") else {
                        return nil
                    }
                    return candidate.id.map { "id:\($0)" }
                        ?? "name:\(ConnectorLibraryFolderHierarchy.stableNameIdentity(name))"
                } ?? []
                artistIdentity = "album-artists:\(identities.joined(separator: ":"))"
            } else if albumSummaryArtist != nil {
                artistIdentity = "album-artist-name:\(ConnectorLibraryFolderHierarchy.stableNameIdentity(artistName))"
            } else {
                let identity = child.artistId
                    ?? ConnectorLibraryFolderHierarchy.stableNameIdentity(artistName)
                artistIdentity = "track-artist:\(identity)"
            }
            fallback.append(
                ConnectorLibraryFolderComponent(
                    stableID: artistIdentity,
                    displayName: artistName
                )
            )
        }
        if let albumName {
            fallback.append(
                ConnectorLibraryFolderComponent(
                    stableID: "album:\(child.albumId ?? album?.id ?? albumName)",
                    displayName: albumName
                )
            )
        }
        return ConnectorLibraryFolderHierarchy.location(
            rootStableID: "\(sourceType.rawValue):library",
            rootDisplayName: sourceType.displayName,
            providerFilePath: child.path,
            acceptsProviderRelativePath: true,
            fallbackComponents: fallback
        )
    }

    /// 封面引用只存稳定标识(`subsonic-cover/<coverArtID>`), 不把鉴权凭据
    /// (token=md5(password+salt) 与 salt)写进曲库快照 —— 凭据持久化落盘对
    /// Subsonic 服务端等价于完整账号, 且密码更换后旧 token 失效会让封面永久
    /// 加载失败。实时 URL 由 `imageURL(for:)` 在取图时用当前凭据现拼。
    ///
    /// 标识里带 `/`(避开 CachedArtworkView 把无 `/` 引用当作本地旧哈希文件名),
    /// 又不含 `://`(避开把它当成可直接下载的完整 URL), 因此走 connector 的
    /// `imageURL(for:)` 重新签发。
    private func coverArtURLString(for coverArtID: String) -> String? {
        Self.coverRefPrefix + coverArtID
    }

    private static let coverRefPrefix = "subsonic-cover/"
    private static let artistRefPrefix = "subsonic-artist/"

    private func artistArtworkReference(for artistID: String) -> String? {
        guard !artistID.isEmpty else { return nil }
        return Self.artistRefPrefix + artistID
    }

    /// 取图层经 SourceManager.imageURL 回调 —— 把封面引用还原成带当前凭据的
    /// 实时 getCoverArt URL。同样兜底处理历史上落盘的完整 URL(老快照里直接
    /// 存了 https://.../getCoverArt 的情况), 直接放行。
    func imageURL(for path: String) async throws -> URL? {
        if path.hasPrefix(Self.artistRefPrefix) {
            try await connect()
            let artistID = String(path.dropFirst(Self.artistRefPrefix.count))
            guard !artistID.isEmpty else { return nil }
            let container: ArtistContainer = try await requestJSON(
                "getArtist",
                query: [URLQueryItem(name: "id", value: artistID)]
            )
            if let coverArtID = container.artist?.coverArt, !coverArtID.isEmpty {
                return buildRESTURL(
                    method: "getCoverArt",
                    query: [
                        URLQueryItem(name: "id", value: coverArtID),
                        URLQueryItem(name: "size", value: "480")
                    ]
                )
            }
            if let imageURL = container.artist?.artistImageURL, !imageURL.isEmpty {
                return URL(string: imageURL)
            }
            return nil
        }
        if path.hasPrefix(Self.coverRefPrefix) {
            try await connect()
            let coverArtID = String(path.dropFirst(Self.coverRefPrefix.count))
            guard !coverArtID.isEmpty else { return nil }
            return buildRESTURL(
                method: "getCoverArt",
                query: [
                    URLQueryItem(name: "id", value: coverArtID),
                    URLQueryItem(name: "size", value: "480")
                ]
            )
        }
        // 老快照里持久化的完整 getCoverArt URL 可能带着扫描时的 LAN
        // 主机和旧 token。提取稳定 cover id，再用当前路线与凭据重签。
        if let legacyURL = URL(string: path),
           legacyURL.scheme != nil,
           legacyURL.path.lowercased().contains("/rest/getcoverart"),
           let coverArtID = URLComponents(
            url: legacyURL,
            resolvingAgainstBaseURL: false
           )?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("id") == .orderedSame })?.value,
           coverArtID.isEmpty == false {
            try await connect()
            return buildRESTURL(
                method: "getCoverArt",
                query: [
                    URLQueryItem(name: "id", value: coverArtID),
                    URLQueryItem(name: "size", value: "480")
                ]
            )
        }
        if path.contains("://") { return URL(string: path) }
        return nil
    }

    /// OpenSubsonic's optional `size` query may resize or transcode artwork.
    /// Dynamic hero artwork therefore requests the source object without that
    /// parameter, while ordinary list/grid loads keep using the bounded 480px
    /// thumbnail above.
    func originalArtworkURL(for path: String) async throws -> URL? {
        let coverArtID: String?
        if path.hasPrefix(Self.coverRefPrefix) {
            coverArtID = String(path.dropFirst(Self.coverRefPrefix.count))
        } else if let legacyURL = URL(string: path),
                  legacyURL.scheme != nil,
                  legacyURL.path.lowercased().contains("/rest/getcoverart") {
            coverArtID = URLComponents(
                url: legacyURL,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: {
                $0.name.caseInsensitiveCompare("id") == .orderedSame
            })?.value
        } else {
            coverArtID = nil
        }

        if let coverArtID, !coverArtID.isEmpty {
            try await connect()
            return buildRESTURL(
                method: "getCoverArt",
                query: [URLQueryItem(name: "id", value: coverArtID)]
            )
        }
        if path.contains("://") { return URL(string: path) }
        return nil
    }

    // MARK: - HTTP / JSON plumbing

    private func responseJSON<C: SubsonicResponseContainer>(
        _ method: String,
        query: [URLQueryItem] = []
    ) async throws -> C {
        guard let url = buildRESTURL(method: method, query: query) else {
            throw SourceError.connectionFailed("Invalid URL for \(method)")
        }
        let (data, response) = try await TrustedHTTPTransport.data(from: url, session: session)
        try validateHTTPStatus(response)
        let decoder = JSONDecoder()
        let envelope: Envelope<C>
        do {
            envelope = try decoder.decode(Envelope<C>.self, from: data)
        } catch {
            let normalized = try SubsonicResponseCompatibility.normalizedJSONData(data)
            envelope = try decoder.decode(Envelope<C>.self, from: normalized)
        }
        return envelope.subsonicResponse
    }

    private func requestJSON<C: SubsonicResponseContainer>(_ method: String, query: [URLQueryItem] = []) async throws -> C {
        let container: C
        do {
            container = try await responseJSON(method, query: query)
        } catch let statusError as SubsonicHTTPStatusError {
            if statusError.statusCode == 401 || statusError.statusCode == 403 {
                throw SourceError.authenticationFailed
            }
            throw SourceError.connectionFailed("HTTP \(statusError.statusCode)")
        }
        // Subsonic 应用层错误常以 HTTP 200 + status:"failed" 返回。统一在此校验
        // envelope, status != "ok" 时抛错 —— 否则扫描会把 failed 当作"空结果"
        // 静默结束, 触发 ConnectorScanner 的 prune 把整源曲库清空。
        guard container.status == "ok" else {
            if let errorCode = container.error?.code,
               SubsonicResponseCompatibility.shouldRetryWithEncodedPassword(
                   errorCode: errorCode,
                   alreadyUsingEncodedPassword: usesEncodedPassword
               ) {
                throw SubsonicCompatibilityError.tokenAuthenticationUnsupported
            }
            throw Self.error(from: container.error)
        }
        return container
    }

    private func validateHTTPStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid server response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SubsonicHTTPStatusError(statusCode: http.statusCode)
        }
    }

    private func validate(_ response: URLResponse) throws {
        do {
            try validateHTTPStatus(response)
        } catch let statusError as SubsonicHTTPStatusError {
            if statusError.statusCode == 401 || statusError.statusCode == 403 {
                throw SourceError.authenticationFailed
            }
            throw SourceError.connectionFailed("HTTP \(statusError.statusCode)")
        }
    }

    /// 构造 `{baseURL}/rest/{method}.view?<auth>&<query>`。`.view` 后缀
    /// 在整个 Subsonic 家族通用(Navidrome 会自动剥离)。
    private func buildRESTURL(method: String, query: [URLQueryItem]) -> URL? {
        var url = baseURL
        url.appendPathComponent("rest")
        url.appendPathComponent("\(method).view")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = authQueryItems() + query
        return components.url
    }

    private func authQueryItems() -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "u", value: username),
        ]
        if usesEncodedPassword {
            items.append(URLQueryItem(name: "p", value: "enc:\(encodedPassword)"))
        } else {
            items.append(URLQueryItem(name: "t", value: token))
            items.append(URLQueryItem(name: "s", value: salt))
        }
        items.append(URLQueryItem(name: "v", value: apiVersion))
        items.append(URLQueryItem(name: "c", value: Self.clientName))
        items.append(URLQueryItem(name: "f", value: "json"))
        return items
    }

    private func songID(from path: String) -> String? {
        let last = (path as NSString).lastPathComponent
        guard last.isEmpty == false else { return nil }
        return (last as NSString).deletingPathExtension
    }

    // MARK: - Static helpers

    /// 本地 SFBAudioEngine 解不了, 需要服务端转码的格式。SFB 已支持
    /// FLAC/MP3/AAC/ALAC/WAV/AIFF/APE/DSD/Opus/Vorbis/WavPack 等, 实际只剩 WMA。
    static func requiresServerTranscode(_ format: AudioFormat) -> Bool {
        format == .wma
    }

    private static func makeBaseURL(host: String, port: Int?, useSsl: Bool, basePath: String?) -> URL {
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = useSsl ? "https" : "http"
        var url = NetworkURLBuilder.baseURL(host: rawHost, scheme: scheme, port: port)
            ?? URL(string: "\(scheme)://localhost")!
        let normalizedBasePath = (basePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBasePath.isEmpty == false {
            for component in normalizedBasePath.split(separator: "/") {
                url.appendPathComponent(String(component))
            }
        }
        return url
    }

    /// 去掉空白; 空串或 Navidrome 占位符(如 "[Unknown Artist]")视作"无值"返回 nil。
    private static func cleaned(_ value: String?, unknown: String) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty, v != unknown else { return nil }
        return v
    }

    private static func randomSalt() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hexEncoded(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func scanStatus(from container: ScanStatusContainer) -> ServerCatalogScanStatus {
        ServerCatalogScanStatus(
            isScanning: container.scanStatus?.scanning ?? false,
            itemCount: container.scanStatus?.count,
            lastCompletedScanAt: container.scanStatus?.lastScan.flatMap(parseDate)
        )
    }

    private static func rejectFailedServerScan(
        _ status: SubsonicScanStatus?
    ) throws {
        guard let detail = status?.error?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else { return }
        throw SourceError.connectionFailed("Navidrome server scan failed: \(detail)")
    }

    private static func error(from error: SubsonicError?) -> SourceError {
        guard let error else { return .connectionFailed("Subsonic request failed") }
        if error.code == 40 || error.code == 41 { return .authenticationFailed }
        return .connectionFailed(error.message ?? "Subsonic error \(error.code)")
    }

    private static func isDirectCatalogUnavailable(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized == "http 404"
            || normalized == "http 405"
            || normalized == "http 410"
            || normalized == "http 501"
            || normalized.contains("not found")
            || normalized.contains("not implemented")
            || normalized.contains("unknown api")
            || normalized.contains("unknown method")
    }

    private static func isInternetRadioAPIUnavailable(_ error: Error) -> Bool {
        let message: String
        if let sourceError = error as? SourceError,
           case .connectionFailed(let detail) = sourceError {
            message = detail
        } else {
            message = error.localizedDescription
        }
        let normalized = message.lowercased()
        return normalized == "http 404"
            || normalized == "http 405"
            || normalized == "http 501"
            || normalized.contains("not found")
            || normalized.contains("not implemented")
            || normalized.contains("unknown api")
            || normalized.contains("unknown method")
            || normalized.contains("unsupported method")
    }

    private static func isServerScanAPIUnavailable(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized == "http 404"
            || normalized == "http 405"
            || normalized == "http 410"
            || normalized == "http 501"
            || normalized.contains("not found")
            || normalized.contains("not implemented")
            || normalized.contains("unknown api")
            || normalized.contains("unknown method")
            || normalized.contains("unsupported method")
    }
}

private enum SubsonicCompatibilityError: Error {
    case tokenAuthenticationUnsupported
    case directCatalogUnavailable
    case catalogChangedDuringPagination
}

private struct SubsonicHTTPStatusError: Error {
    let statusCode: Int
}

// MARK: - Subsonic JSON models

/// 所有 `subsonic-response` 容器共有的应用层状态。`requestJSON` 据此统一校验:
/// status != "ok" 即应用层失败(含认证 error 40/41), 抛错而非当作空结果。
private protocol SubsonicResponseContainer: Decodable {
    var status: String { get }
    var error: SubsonicError? { get }
}

private struct Envelope<C: Decodable>: Decodable {
    let subsonicResponse: C
    enum CodingKeys: String, CodingKey { case subsonicResponse = "subsonic-response" }
}

private struct SubsonicError: Decodable {
    let code: Int
    let message: String?
}

private struct PingContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let type: String?            // "navidrome" / "airsonic" / "gonic" / ...
    let openSubsonic: Bool?
}

private struct EmptyContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
}

private struct ScanStatusContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let scanStatus: SubsonicScanStatus?
}

private struct SubsonicScanStatus: Decodable {
    let scanning: Bool
    let count: Int64?
    let lastScan: String?
    let error: String?
}

private struct GetSongContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let song: SubsonicChild?
}

private struct LegacyLyricsContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let lyrics: LegacyLyrics?
}

private struct LegacyLyrics: Decodable {
    let value: String?           // 歌词纯文本(Subsonic 把元素文本放在 "value")
}

private struct MusicFoldersContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let musicFolders: MusicFolders?
}

private struct MusicFolders: Decodable {
    let musicFolder: [MusicFolder]?
}

private struct MusicFolder: Decodable {
    let id: Int
    let name: String?
}

private struct AlbumListContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let albumList2: AlbumList2?
}

private struct AlbumList2: Decodable {
    let album: [AlbumSummary]?
}

private struct AlbumSummary: Decodable, Sendable {
    let id: String
    let name: String?
    let artist: String?
    let coverArt: String?
}

private struct AlbumContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let album: AlbumWithSongs?
}

private struct Search3Container: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let searchResult3: SearchResult3?
}

private struct SearchResult3: Decodable {
    let song: [SubsonicChild]?
}

private struct ArtistContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let artist: SubsonicArtistID3?
}

private struct AlbumWithSongs: Decodable, Sendable {
    let song: [SubsonicChild]?
}

private struct LegacyAlbumResult: Sendable {
    let index: Int
    let album: AlbumSummary
    let songs: [SubsonicChild]
}

/// Subsonic "Child" 元素(歌曲)。字段名遵循 Subsonic/OpenSubsonic 规范。
private struct SubsonicChild: Decodable, Sendable {
    let id: String
    let title: String?
    let album: String?
    let artist: String?
    let displayArtist: String?
    let artists: [SubsonicArtistID3]?
    let displayAlbumArtist: String?
    let albumArtists: [SubsonicArtistID3]?
    let albumId: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let size: Int64?
    let suffix: String?
    let duration: Int?
    let bitRate: Int?
    let path: String?
    let isVideo: Bool?
    let created: String?
    let playCount: Int?
    let played: String?
    // OpenSubsonic 扩展
    let samplingRate: Int?
    let bitDepth: Int?
}

private struct SubsonicArtistID3: Decodable, Sendable {
    let id: String?
    let name: String?
    let coverArt: String?
    let artistImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case coverArt
        case artistImageURL = "artistImageUrl"
    }
}

private struct PlaylistsContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let playlists: PlaylistList?
}

private struct PlaylistList: Decodable {
    let playlist: [PlaylistSummary]?
}

private struct PlaylistSummary: Decodable {
    let id: FlexibleID
    let name: String?
    let songCount: Int?
    let coverArt: String?
}

private struct PlaylistContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let playlist: PlaylistWithEntries?
}

private struct Starred2Container: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let starred2: Starred2?
}

private struct Starred2: Decodable {
    let song: [SubsonicChild]?
}

/// `playlistWithSongs`: 曲目字段是单数 `entry`, 装的是 Child 数组。
private struct PlaylistWithEntries: Decodable {
    let name: String?
    let songCount: Int?
    let coverArt: String?
    let entry: [SubsonicChild]?
}

private struct InternetRadioStationsContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let internetRadioStations: InternetRadioStationList?
}

private struct InternetRadioStationList: Decodable {
    let internetRadioStation: [SubsonicInternetRadioStation]?
}

private struct SubsonicInternetRadioStation: Decodable {
    let id: FlexibleID
    let name: String?
    let streamURL: String?
    let homePageURL: String?
    let coverArt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case coverArt
        case streamURL = "streamUrl"
        case homePageURL = "homePageUrl"
    }
}

/// 歌单 ID 在规范里是字符串(Navidrome 给 UUID), 但部分实现按整数序列化 JSON
/// (musicFolder.id 就是这种情况, 见 `MusicFolder`)。歌单 ID 只用于回传
/// `getPlaylist?id=` 和派生本地镜像 ID, 两种形状都按原文收下即可。
private struct FlexibleID: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Playlist id is neither a string nor an integer"
                )
            )
        }
    }
}

private struct LyricsContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let lyricsList: LyricsList?
}

private struct LyricsList: Decodable {
    let structuredLyrics: [OpenSubsonicLyricsConverter.Track]?
}
