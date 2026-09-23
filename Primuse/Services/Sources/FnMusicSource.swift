import Foundation
import PrimuseKit

/// Connector for the Feiniu Music catalogue and user library.
/// The legacy `.fnos` NAS placeholder remains separate so old source records
/// are never reinterpreted as a server-side music library.
actor FnMusicSource: RefreshingMetadataSongConnector, ServerLyricsConnector, ServerScrobblingConnector,
    ServerPlaylistConnector, ServerFavoriteConnector, MediaServerWritebackConnector {
    let sourceID: String

    private let api: FnMusicAPI
    private let username: String
    private let password: String
    private let audioCacheDirectory: URL
    private let artworkCacheDirectory: URL
    private struct LoginOperation {
        let id: UUID
        let task: Task<Void, Error>
        var waiters: Set<UUID>
    }
    private var loginOperation: LoginOperation?
    private let loginTimeout: TimeInterval
    /// Route generation on which the session was last proven.
    private var verifiedRouteGeneration: UInt64?

    static let connectionTimeout: TimeInterval = 60

    struct LoginTimeoutError: LocalizedError {
        var errorDescription: String? { SourceError.timeout.localizedDescription }
    }

    private static let pageSize = 50
    /// 飞牛的曲目接口不返回专辑艺术家, 只有 `album/detail` 的 `artists` 有。
    /// 少了它同一张专辑会按每首歌各自的艺术家散成多张同名专辑, 所以扫描时
    /// 按专辑补一次。一张专辑只问一次, 整次扫描共用这两张表。
    private var albumArtistByGUID: [String: String] = [:]
    private var albumsWithoutArtist: Set<String> = []
    private static let albumDetailConcurrency = 6
    private static let albumPageSize = 100
    /// 整个源的专辑最多翻这么多页, 防住 total 不实时时的空转。
    private static let albumPageLimit = 500
    private var albumListPrimed = false
    /// 老版本飞牛没有专辑详情这个接口。一次成功都没有就别再撞了, 否则每页都要
    /// 白发一轮请求。取消不算失败, 每次扫描开始时重新给它一次机会。
    private static let albumDetailFailureLimit = 8
    private var albumDetailFailures = 0
    private var albumDetailSucceeded = false
    private var albumDetailUnavailable = false

    /// `.resolved` 的 name 为 nil 表示这张专辑问过了、服务端就是没有专辑艺术家。
    private enum AlbumArtistLookup: Sendable {
        case resolved(guid: String, name: String?)
        case failed
        case cancelled
    }

    init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        connectionMode: FnMusicConnectionMode,
        accessCode: String?,
        username: String,
        password: String,
        alternateTLSValidationHostname: String? = nil,
        session: URLSession? = nil,
        loginTimeout: TimeInterval = FnMusicSource.connectionTimeout
    ) {
        self.sourceID = sourceID
        self.username = username
        self.password = password
        self.loginTimeout = loginTimeout
        self.api = FnMusicAPI(
            sourceID: sourceID,
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath,
            connectionMode: connectionMode,
            accessCode: accessCode,
            alternateTLSValidationHostname: alternateTLSValidationHostname,
            session: session
        )

        let root = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        self.audioCacheDirectory = root
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        self.artworkCacheDirectory = root
            .appendingPathComponent("fnmusic_artwork", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
            .appendingPathComponent(
                MusicSourceSecurityRevision.cacheNamespace(for: sourceID),
                isDirectory: true
            )
        try? FileManager.default.createDirectory(at: audioCacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkCacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Connection

    func prepareDiagnosticConnection() async throws {
        try await api.prepareConnection()
    }

    func connect() async throws {
        try Task.checkCancellation()
        let routeGeneration = await SourceConnectionRuntime.shared.routeGeneration()
        if await api.isLoggedIn {
            guard SourceSessionRouteValidation.needsRevalidation(
                verifiedGeneration: verifiedRouteGeneration,
                currentGeneration: routeGeneration
            ) else { return }
            // The network changed under a live session: prove this route with
            // the smallest catalogue request before the router trusts it again.
            do {
                _ = try await api.trackPage(page: 1, size: 1)
                verifiedRouteGeneration = routeGeneration
                return
            } catch SourceError.authenticationFailed {
                // The session expired as well; sign in again below.
                await api.invalidateSession()
            }
        }
        guard !username.isEmpty, !password.isEmpty else {
            await reportAuthenticationProblem(PMString("error.fnMusic.missingCredential"))
            throw SourceError.authenticationFailed
        }
        let waiterID = UUID()
        let operation: LoginOperation
        if var existing = loginOperation {
            existing.waiters.insert(waiterID)
            loginOperation = existing
            operation = existing
        } else {
            let task = Task { [api, username, password, loginTimeout] in
                try await AsyncOperationTimeout.run(seconds: loginTimeout) {
                    try await api.login(username: username, password: password)
                }
            }
            operation = LoginOperation(id: UUID(), task: task, waiters: [waiterID])
            loginOperation = operation
        }
        do {
            try await Self.waitForLogin(operation.task)
            try Task.checkCancellation()
            verifiedRouteGeneration = routeGeneration
            await finishLoginWaiter(waiterID, operationID: operation.id, failed: false)
            await MainActor.run { SourceAuthAlert.clear(sourceID: sourceID) }
        } catch {
            await finishLoginWaiter(waiterID, operationID: operation.id, failed: true)
            if (error as? URLError)?.code == .timedOut { throw LoginTimeoutError() }
            if case SourceError.authenticationFailed = error {
                await reportAuthenticationProblem(PMString("error.fnMusic.authenticationFailed"))
            }
            throw error
        }
    }

    func disconnect() async {
        let operationID = loginOperation?.id
        loginOperation?.task.cancel()
        await api.logout()
        if loginOperation?.id == operationID { loginOperation = nil }
    }

    private func finishLoginWaiter(_ waiterID: UUID, operationID: UUID, failed: Bool) async {
        guard var operation = loginOperation, operation.id == operationID else { return }
        operation.waiters.remove(waiterID)
        loginOperation = operation
        guard operation.waiters.isEmpty else { return }
        if failed {
            operation.task.cancel()
            await api.cancelPendingLogin()
        }
        if loginOperation?.id == operationID { loginOperation = nil }
    }

    private static func waitForLogin(_ task: Task<Void, Error>) async throws {
        let race = CancellableResultRace<Void>()
        let observer = Task { race.resolve(await task.result) }
        defer { observer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.install($0) }
        } onCancel: {
            race.cancel()
        }
    }

    private func reportAuthenticationProblem(_ message: String) async {
        await MainActor.run {
            SourceAuthAlert.report(sourceID: sourceID, message: message)
        }
    }

    // MARK: - Catalogue scanning

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        // This is a server catalogue, not a filesystem. The synthetic root is
        // used only by connection diagnostics; scans use scanSongs("/").
        _ = try await trackPage(page: 1, size: 1)
        return [
            RemoteFileItem(
                name: MusicSourceType.fnMusic.displayName,
                path: "/",
                isDirectory: true,
                size: 0,
                modifiedDate: nil
            ),
        ]
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        albumDetailFailures = 0
        albumDetailUnavailable = false
        albumListPrimed = false
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var page = 1
                    var received = 0
                    var expectedTotal: Int?
                    var seenTrackGUIDs: Set<String> = []
                    while true {
                        try Task.checkCancellation()
                        let result = try await self.trackPage(page: page, size: Self.pageSize)

                        guard let pageTotal = result.total else {
                            throw SourceError.connectionFailed(PMString("error.catalog.missingTotal"))
                        }
                        if let expectedTotal, expectedTotal != pageTotal {
                            throw SourceError.connectionFailed(PMString("error.catalog.totalChanged"))
                        }
                        expectedTotal = pageTotal

                        guard result.rawCount <= Self.pageSize else {
                            throw SourceError.connectionFailed(PMString("error.catalog.invalidPageCount"))
                        }
                        if pageTotal == 0 {
                            guard page == 1, result.rawCount == 0 else {
                                throw SourceError.connectionFailed(PMString("error.catalog.pageTotalMismatch"))
                            }
                            break
                        }
                        guard result.rawCount > 0 else {
                            throw SourceError.connectionFailed(PMString("error.catalog.pageEndedEarly"))
                        }

                        received += result.rawCount
                        await self.primeAlbumArtists()
                        let albumArtists = await self.albumArtistNames(for: result.tracks)
                        for track in result.tracks {
                            try Task.checkCancellation()
                            guard seenTrackGUIDs.insert(track.guid).inserted else {
                                throw SourceError.connectionFailed(PMString("error.catalog.duplicateItem"))
                            }
                            let scanned = try self.scannedSong(
                                from: track,
                                albumArtistName: track.albumGUID.flatMap { albumArtists[$0] }
                            )
                            continuation.yield(scanned)
                        }

                        guard received <= pageTotal else {
                            throw SourceError.connectionFailed(PMString("error.catalog.pageExceedsTotal"))
                        }
                        if received == pageTotal {
                            break
                        }
                        guard result.rawCount == Self.pageSize else {
                            throw SourceError.connectionFailed(PMString("error.catalog.incompletePage"))
                        }
                        page += 1
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let songs = try await scanSongs(from: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await scanned in songs {
                        continuation.yield(
                            RemoteFileItem(
                                name: scanned.displayName,
                                path: scanned.song.filePath,
                                isDirectory: false,
                                size: scanned.song.fileSize,
                                modifiedDate: scanned.song.lastModified,
                                revision: scanned.song.revision
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func scannedSong(
        from track: FnMusicTrack,
        albumArtistName: String?
    ) throws -> ConnectorScannedSong {
        let suffix = track.fileExtension ?? ""
        guard let song = track.makeSong(
            sourceID: sourceID,
            albumArtistName: albumArtistName
        ) else {
            throw SourceError.connectionFailed(PMString("error.catalog.trackMissingFormat", track.title))
        }
        return ConnectorScannedSong(
            song: song,
            displayName: "\(track.title).\(suffix)",
            titleMetadataInspected: track.hasUsableCatalogTitle,
            folderLocation: libraryFolderLocation(for: track, albumArtistName: albumArtistName)
        )
    }

    /// 整个源的专辑艺术家一次翻完。`album/list` 每页就带回一批 `artists`,
    /// 比一张张问详情省得多; 这条路走不通(老版本没有这个端点、或者列表项不带
    /// artists)也不报错, 缺的专辑由下面按需问详情补上。每次扫描只做一次。
    private func primeAlbumArtists() async {
        guard !albumListPrimed else { return }
        albumListPrimed = true
        var page = 1
        var received = 0
        var expectedTotal: Int?
        while page <= Self.albumPageLimit, !Task.isCancelled {
            let result: FnMusicAlbumPage
            do {
                result = try await api.albumPage(page: page, size: Self.albumPageSize)
            } catch {
                return
            }
            guard result.rawCount > 0, result.rawCount <= Self.albumPageSize else { return }
            if let expectedTotal, expectedTotal != result.total { return }
            expectedTotal = result.total
            // 只记有名字的。列表项万一根本不带 artists(端点变了、或者这一版
            // 的列表是精简结构), 把空的记成「服务端就是没有」会连详情那条路
            // 一起堵死 —— 那时这里什么都不填, 退化成逐张问详情而已。
            for album in result.albums {
                guard let name = album.artistName, albumArtistByGUID[album.guid] == nil else { continue }
                albumArtistByGUID[album.guid] = name
            }
            received += result.rawCount
            if let total = result.total, received >= total { return }
            guard result.rawCount == Self.albumPageSize else { return }
            page += 1
        }
    }

    /// 专辑 GUID → 专辑艺术家, 只含这一页真的查到的。曲目自己带了专辑艺术家
    /// (飞牛哪天开始给了)就不问, 问过没有的也不再问。一个专辑详情取不到不该
    /// 让整次扫描失败, 那一张这轮就按曲目艺术家走。
    private func albumArtistNames(for tracks: [FnMusicTrack]) async -> [String: String] {
        var pending: [String] = []
        if !albumDetailUnavailable {
            for track in tracks {
                guard track.albumArtistName == nil, let guid = track.albumGUID,
                      albumArtistByGUID[guid] == nil, !albumsWithoutArtist.contains(guid),
                      !pending.contains(guid) else { continue }
                pending.append(guid)
            }
        }
        var offset = 0
        while offset < pending.count, !Task.isCancelled, !albumDetailUnavailable {
            let slice = Array(pending[offset..<min(offset + Self.albumDetailConcurrency, pending.count)])
            offset += slice.count
            await withTaskGroup(of: AlbumArtistLookup.self) { group in
                for guid in slice {
                    group.addTask { [api] in
                        do {
                            return .resolved(
                                guid: guid,
                                name: try await api.albumArtistName(albumGUID: guid)
                            )
                        } catch {
                            return OperationCancellationPolicy.isCancellation(error)
                                ? .cancelled
                                : .failed
                        }
                    }
                }
                for await lookup in group {
                    switch lookup {
                    case .resolved(let guid, let name):
                        albumDetailSucceeded = true
                        albumDetailFailures = 0
                        if let name {
                            albumArtistByGUID[guid] = name
                        } else {
                            albumsWithoutArtist.insert(guid)
                        }
                    case .failed:
                        albumDetailFailures += 1
                    case .cancelled:
                        break
                    }
                }
            }
            if !albumDetailSucceeded, albumDetailFailures >= Self.albumDetailFailureLimit {
                albumDetailUnavailable = true
                plog("FN Music album detail unavailable source=\(sourceID.prefix(8)) failures=\(albumDetailFailures)")
            }
        }
        var names: [String: String] = [:]
        for track in tracks {
            guard let guid = track.albumGUID, let name = albumArtistByGUID[guid] else { continue }
            names[guid] = name
        }
        return names
    }

    private func libraryFolderLocation(
        for track: FnMusicTrack,
        albumArtistName: String?
    ) -> ConnectorLibraryFolderLocation {
        let albumArtistName = albumArtistName ?? track.albumArtistName
        let trackArtistName = track.artistNames.isEmpty
            ? nil
            : track.artistNames.joined(separator: ", ")
        let artistName = albumArtistName ?? trackArtistName
        var fallback: [ConnectorLibraryFolderComponent] = []
        if let artistName {
            let artistIdentity: String
            if albumArtistName != nil {
                artistIdentity = "album-artist-name:\(ConnectorLibraryFolderHierarchy.stableNameIdentity(artistName))"
            } else {
                let identity = track.artistNames.count == 1
                    ? track.artistGUID
                    : nil
                let resolvedIdentity = identity
                    ?? ConnectorLibraryFolderHierarchy.stableNameIdentity(artistName)
                artistIdentity = "track-artist:\(resolvedIdentity)"
            }
            fallback.append(
                ConnectorLibraryFolderComponent(
                    stableID: artistIdentity,
                    displayName: artistName
                )
            )
        }
        if let albumName = track.albumName {
            fallback.append(
                ConnectorLibraryFolderComponent(
                    stableID: "album:\(track.albumGUID ?? albumName)",
                    displayName: albumName
                )
            )
        }
        return ConnectorLibraryFolderHierarchy.location(
            rootStableID: "fnmusic:catalog",
            rootDisplayName: MusicSourceType.fnMusic.displayName,
            providerFilePath: nil,
            fallbackComponents: fallback
        )
    }

    private func trackPage(page: Int, size: Int) async throws -> FnMusicTrackPage {
        do {
            return try await api.trackPage(page: page, size: size)
        } catch SourceError.authenticationFailed {
            try await connect()
            return try await api.trackPage(page: page, size: size)
        }
    }

    private var libraryClient: FnMusicLibraryClient {
        FnMusicLibraryClient { [self] request in
            try await connect()
            do {
                return try await api.libraryPayload(request)
            } catch SourceError.authenticationFailed {
                try await connect()
                return try await api.libraryPayload(request)
            }
        }
    }

    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        let snapshot = try await libraryClient.playlists()
        return ServerPlaylistSnapshot(
            playlists: snapshot.playlists.map {
                ServerPlaylist(id: $0.id, name: $0.name, coverArtReference: $0.coverReference,
                               trackIDs: $0.trackIDs, reportedTrackCount: $0.trackIDs.count)
            },
            failedPlaylistIDs: snapshot.failedPlaylistIDs
        )
    }

    func fetchServerFavorites() async throws -> ServerFavoriteSnapshot {
        ServerFavoriteSnapshot(itemIDs: try await libraryClient.favorites())
    }

    func setServerFavorite(itemID: String, isFavorite: Bool) async throws -> ServerFavoriteSnapshot {
        ServerFavoriteSnapshot(itemIDs: try await libraryClient.setFavorite(trackID: itemID, isFavorite: isFavorite))
    }

    // MARK: - Audio

    func streamingURL(for path: String) async throws -> URL? {
        // The media route needs a Cookie header. Returning a bare URL would
        // work only inside an already-authenticated WebView and fails in the
        // native decoder, so playback deliberately uses fetchRange/localURL.
        nil
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0,
              let trackGUID = FnMusicAPIProtocol.trackGUID(from: path) else {
            return Data()
        }
        try await connect()
        let response: FnMusicRangeResponse
        do {
            response = try await api.fetchRange(trackGUID: trackGUID, offset: offset, length: length)
        } catch SourceError.authenticationFailed {
            try await connect()
            response = try await api.fetchRange(trackGUID: trackGUID, offset: offset, length: length)
        }
        return response.data
    }

    func localURL(for path: String) async throws -> URL {
        guard let trackGUID = FnMusicAPIProtocol.trackGUID(from: path) else {
            throw SourceError.fileNotFound(path)
        }
        let suffix = (path as NSString).pathExtension
        let target = audioCacheDirectory.appendingPathComponent(
            CacheFileNamePolicy.make(
                path: path,
                preferredExtension: suffix.isEmpty ? "bin" : suffix
            )
        )
        if FileManager.default.fileExists(atPath: target.path) { return target }

        try await connect()
        let temporaryURL: URL
        do {
            temporaryURL = try await api.downloadTrack(trackGUID: trackGUID)
        } catch SourceError.authenticationFailed {
            try await connect()
            temporaryURL = try await api.downloadTrack(trackGUID: trackGUID)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
            return target
        }
        try FileManager.default.moveItem(at: temporaryURL, to: target)
        return target
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let local = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: local)
                    defer { try? handle.close() }
                    while true {
                        try Task.checkCancellation()
                        let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    // MARK: - Artwork / lyrics / playback history

    func imageURL(for path: String) async throws -> URL? {
        guard let coverID = FnMusicAPIProtocol.coverID(from: path) else {
            return path.contains("://") ? URL(string: path) : nil
        }
        let target = artworkCacheDirectory.appendingPathComponent(
            CacheFileNamePolicy.make(path: path, preferredExtension: "image")
        )
        if FileManager.default.fileExists(atPath: target.path) { return target }

        try await connect()
        let revision = FnMusicAPIProtocol.coverRevision(from: path)
        let data: Data
        do {
            data = try await api.coverData(coverID: coverID, revision: revision)
        } catch SourceError.authenticationFailed {
            try await connect()
            data = try await api.coverData(coverID: coverID, revision: revision)
        }
        try data.write(to: target, options: .atomic)
        return target
    }

    func fetchServerLyrics(for path: String) async -> String? {
        guard case .content(let content) = await readServerLyrics(for: path) else {
            return nil
        }
        return content
    }

    func readServerLyrics(for path: String) async -> ServerLyricsReadResult {
        guard let trackGUID = FnMusicAPIProtocol.trackGUID(from: path) else {
            return .unavailable
        }
        do {
            try await connect()
            return try await api.preferredLyrics(trackGUID: trackGUID)
                .map(ServerLyricsReadResult.content) ?? .absent
        } catch SourceError.authenticationFailed {
            do {
                try await connect()
                return try await api.preferredLyrics(trackGUID: trackGUID)
                    .map(ServerLyricsReadResult.content) ?? .absent
            } catch {
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    func scrobble(songPath: String, submission: Bool) async {
        guard submission,
              let trackGUID = FnMusicAPIProtocol.trackGUID(from: songPath),
              (try? await connect()) != nil else { return }
        do {
            try await api.reportPlayback(trackGUID: trackGUID)
        } catch SourceError.authenticationFailed {
            guard (try? await connect()) != nil else { return }
            _ = try? await api.reportPlayback(trackGUID: trackGUID)
        } catch {
            return
        }
    }

}

extension FnMusicSource {
    func writeScrapedMetadata(original: Song, updated: Song, coverData: Data?, lyricsLines: [LyricLine]?, lyricsContent: String?) async -> MediaServerWritebackResult {
        let changed = TagMetadataWritebackField.changedFields(from: original, to: updated, includesCover: coverData?.isEmpty == false)
        let writable = changed.intersection(TagMetadataWritebackField.metadataFields)
        let unsupported = changed.subtracting(writable)
        var result = MediaServerWritebackResult()
        if !writable.isEmpty {
            do {
                try await connect()
                let suffix = (original.filePath as NSString).pathExtension
                let cache = audioCacheDirectory.appendingPathComponent(CacheFileNamePolicy.make(
                    path: original.filePath, preferredExtension: suffix.isEmpty ? "bin" : suffix))
                defer { try? FileManager.default.removeItem(at: cache) }
                result = try await api.updateTrackMetadata(original: original, updated: updated, fields: writable)
                albumArtistByGUID.removeAll()
                albumsWithoutArtist.removeAll()
            } catch {
                result.errors.append(error.localizedDescription)
                result.fieldResults = writable.map { TagMetadataFieldWritebackResult(field: $0, disposition: .failed(error.localizedDescription)) }
            }
        }
        let detail = String(localized: "metadata_writeback_error_unsupported")
        result.fieldResults.append(contentsOf: unsupported.map { TagMetadataFieldWritebackResult(field: $0, disposition: .unsupported(detail)) })
        if !unsupported.isEmpty || lyricsLines != nil || lyricsContent != nil { result.unsupported.append(detail) }
        return result
    }

    func removeLyrics(for song: Song) async -> MediaServerWritebackResult {
        MediaServerWritebackResult(unsupported: [String(localized: "metadata_writeback_error_unsupported")])
    }
}
