import Foundation
import PrimuseKit

actor SongloftSource: RefreshingMetadataSongConnector, ServerLyricsConnector,
    ServerPlaylistConnector, ServerPlaylistAppendingConnector, ServerFavoriteConnector, ServerScrobblingConnector,
    ServerRadioConnector, ServerRadioStreamResolvingConnector {
    let sourceID: String
    private let client: SongloftServiceClient
    private let session: URLSession
    private let audioCacheDirectory: URL
    private var connected = false

    init(sourceID: String, host: String, port: Int?, useSSL: Bool, basePath: String?,
         username: String, password: String, alternateTLSValidationHostname: String? = nil,
         transport: SongloftRequestTransport? = nil) {
        self.sourceID = sourceID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: SmartSSLDelegate(
            redirectPolicy: .sameEndpoint,
            alternateServerTrustHostname: alternateTLSValidationHostname,
            alternateServerTrustEndpoint: NetworkEndpointIdentity(scheme: useSSL ? "https" : "http", host: host, port: port)
        ), delegateQueue: nil)
        self.session = session
        client = SongloftServiceClient(
            source: MusicSource(id: sourceID, name: "Songloft", type: .songloft, host: host,
                                port: port, useSsl: useSSL, username: username, basePath: basePath),
            credential: SourceCredential(username: username, password: password),
            transport: transport ?? SongloftRequestTransport(
                data: { try await TrustedHTTPTransport.data(for: $0, session: session) },
                download: { try await TrustedHTTPTransport.download(for: $0, session: session) }
            )
        )
        audioCacheDirectory = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
            .appendingPathComponent(MusicSourceSecurityRevision.cacheNamespace(for: sourceID), isDirectory: true)
    }

    deinit { session.invalidateAndCancel() }

    func connect() async throws {
        guard !connected else { return }
        do {
            _ = try await client.validateConnection()
            connected = true
            #if !os(tvOS)
            await MainActor.run { SourceAuthAlert.clear(sourceID: sourceID) }
            #endif
        } catch {
            #if !os(tvOS)
            if let failure = error as? SongloftServiceError,
               failure == .authenticationFailed || failure == .missingCredential {
                await MainActor.run { SourceAuthAlert.report(sourceID: sourceID, message: failure.localizedDescription) }
            }
            #endif
            throw error
        }
    }

    func disconnect() async {
        connected = false
        await client.invalidateSession()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return [RemoteFileItem(name: "Songloft", path: "/", isDirectory: true, size: 0, modifiedDate: nil)]
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let root = try? await self.client.libraryRoot()
                    for try await track in await self.client.catalog() {
                        try Task.checkCancellation()
                        guard !track.isRadio, track.isVideo != true else { continue }
                        guard let song = track.makeSong(sourceID: self.sourceID) else { throw SongloftServiceError.invalidResponse }
                        continuation.yield(ConnectorScannedSong(
                            song: song, displayName: song.title, titleMetadataInspected: track.hasUsableTitle,
                            folderLocation: Self.folderLocation(track: track, root: root)
                        ))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private static func folderLocation(track: SongloftTrack, root: String?) -> ConnectorLibraryFolderLocation {
        let fallback = [("artist", track.artist), ("album", track.album)].compactMap { kind, name -> ConnectorLibraryFolderComponent? in
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ConnectorLibraryFolderComponent(stableID: "\(kind):\(ConnectorLibraryFolderHierarchy.stableNameIdentity(name))", displayName: name)
        }
        return ConnectorLibraryFolderHierarchy.location(
            rootStableID: "songloft:catalog", rootDisplayName: "Songloft",
            providerFilePath: track.type == "local" ? track.filePath : nil,
            declaredLibraryRoots: root.map { [$0] } ?? [], fallbackComponents: fallback
        )
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let songs = try await scanSongs(from: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await item in songs {
                        try Task.checkCancellation()
                        continuation.yield(RemoteFileItem(name: item.displayName, path: item.song.filePath,
                            isDirectory: false, size: item.song.fileSize, modifiedDate: item.song.lastModified,
                            revision: item.song.revision))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func streamingURL(for path: String) async throws -> URL? { nil }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await client.fetchRange(trackPath: path, offset: offset, length: length)
    }

    func localURL(for path: String) async throws -> URL {
        guard SongloftAPIProtocol.trackID(from: path) != nil else { throw SourceError.fileNotFound(path) }
        let target = audioCacheDirectory.appendingPathComponent(CacheFileNamePolicy.make(
            path: path, preferredExtension: (path as NSString).pathExtension))
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let temporary = try await client.downloadTrack(trackPath: path)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: audioCacheDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        return target
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let file = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    while true {
                        try Task.checkCancellation()
                        let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func imageURL(for path: String) async throws -> URL? { nil }

    func fetchArtworkData(for reference: String, maximumBytes: Int, purpose: ArtworkFetchPurpose) async throws -> Data? {
        try await client.artworkData(reference: reference, maximumBytes: maximumBytes)
    }

    func fetchServerLyrics(for path: String) async -> String? {
        guard case .content(let text) = await readServerLyrics(for: path) else { return nil }
        return text
    }

    func readServerLyrics(for path: String) async -> ServerLyricsReadResult {
        do { return try await client.preferredLyrics(trackPath: path).map(ServerLyricsReadResult.content) ?? .absent }
        catch { return .unavailable }
    }

    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        try await fetchServerPlaylists(progress: { _ in })
    }

    func fetchServerPlaylists(
        progress: @escaping ServerPlaylistProgress
    ) async throws -> ServerPlaylistSnapshot {
        let listed = try await client.playlistIndex()
        var playlists: [ServerPlaylist] = []
        var failed: Set<String> = []
        for playlist in listed.playlists {
            try Task.checkCancellation()
            // Favorites have their own write-through UI and must not also appear as an editable mirror.
            guard !playlist.isFavorite else { continue }
            do {
                let ids = try await client.playlistSongIDs(id: playlist.id)
                let mirrored = ServerPlaylist(id: String(playlist.id),
                    name: playlist.name.isEmpty ? String(playlist.id) : playlist.name,
                    coverArtReference: playlist.coverReference, trackIDs: ids.map(String.init),
                    tracks: try await client.playlistTracks(ids: ids),
                    reportedTrackCount: playlist.songCount)
                playlists.append(mirrored)
                await progress(mirrored)
            } catch is CancellationError { throw CancellationError() }
            catch { failed.insert(String(playlist.id)) }
        }
        return ServerPlaylistSnapshot(
            playlists: playlists,
            failedPlaylistIDs: failed,
            isIndexComplete: listed.unreadableCount == 0
        )
    }

    /// 只往普通歌单里加; 收藏有自己的红心入口, 不当成加歌目标。先读一次明细只追加还不在
    /// 里面的, 加完再读一次, 每首都在才算成功。
    func appendToServerPlaylist(id: String, itemIDs: [String]) async throws -> ServerPlaylist {
        guard let playlistID = Int64(id), playlistID > 0 else { throw ServerPlaylistAppendError.readOnly }
        let playlist = try await client.playlist(id: playlistID)
        guard playlist.type == "normal", !playlist.isFavorite else { throw ServerPlaylistAppendError.readOnly }
        let current = try await client.playlistSongIDs(id: playlistID)
        var seen = Set(current)
        let missing = itemIDs.compactMap { Int64($0) }.filter { $0 > 0 && seen.insert($0).inserted }
        var trackIDs = current
        if !missing.isEmpty {
            var offset = 0
            while offset < missing.count {
                try Task.checkCancellation()
                let chunk = Array(missing[offset..<min(offset + 100, missing.count)])
                do {
                    try await client.addSongs(chunk, toPlaylist: playlistID)
                } catch SongloftServiceError.badServerResponse(403) {
                    throw ServerPlaylistAppendError.readOnly
                }
                offset += chunk.count
            }
            trackIDs = try await client.playlistSongIDs(id: playlistID)
            guard Set(trackIDs).isSuperset(of: missing) else { throw ServerPlaylistAppendError.notConfirmed }
        }
        return ServerPlaylist(id: id,
            name: playlist.name.isEmpty ? id : playlist.name,
            coverArtReference: playlist.coverReference, trackIDs: trackIDs.map(String.init),
            tracks: try await client.playlistTracks(ids: trackIDs),
            reportedTrackCount: trackIDs.count)
    }

    func fetchServerFavorites() async throws -> ServerFavoriteSnapshot {
        let favorites = try await client.favoriteSongIDList()
        return ServerFavoriteSnapshot(itemIDs: favorites.ids.map(String.init), isComplete: favorites.unreadableCount == 0)
    }

    func setServerFavorite(itemID: String, isFavorite: Bool) async throws -> ServerFavoriteSnapshot {
        guard let id = Int64(itemID), id > 0 else { throw SongloftServiceError.invalidResponse }
        let confirmed = try await client.setFavorite(id: id, isFavorite: isFavorite)
        return ServerFavoriteSnapshot(itemIDs: confirmed.ids.map(String.init), isComplete: confirmed.unreadableCount == 0)
    }

    func scrobble(songPath: String, submission: Bool) async {
        try? await client.reportPlayback(trackPath: songPath, submission: submission)
    }

    func fetchServerRadioStations() async throws -> ServerRadioStationSnapshot? {
        var stations: [ServerRadioStation] = []
        for try await track in await client.catalog(type: "radio") {
            stations.append(ServerRadioStation(id: String(track.id), name: track.title ?? "Songloft",
                streamURL: nil, homepageURL: nil,
                coverArtReference: track.coverUrl?.isEmpty == false
                    ? SongloftAPIProtocol.coverReference(id: track.id, revision: track.updatedAt) : nil,
                sourcePlaybackPath: SongloftAPIProtocol.radioPlaybackPath(id: track.id),
                streamFormat: track.usesHLS ? .hls : .automatic,
                bitRate: track.radioBitRateInBitsPerSecond))
        }
        return ServerRadioStationSnapshot(stations: stations)
    }

    func resolveServerRadioStream(stationID: String, forceRefresh: Bool) async throws -> URL {
        guard let id = Int64(stationID), id > 0 else { throw SongloftServiceError.invalidResponse }
        if forceRefresh { await client.invalidateSession() }
        return try await client.radioURL(id: id)
    }
}

extension SongloftSource: ServerCatalogChangeDetectingConnector {
    /// The catalogue total from a one-row page. It sees rows arriving or
    /// leaving; an edited tag waits for the next scan.
    func fetchServerCatalogScanStatus(changedSince: Date?) async throws -> ServerCatalogScanStatus {
        try await connect()
        let total = try await client.trackPage(offset: 0, limit: 1).total
        return ServerCatalogScanStatus(
            isScanning: false,
            itemCount: Int64(total),
            lastCompletedScanAt: nil
        )
    }
}

extension SongloftSource: CatalogDriftReportingConnector {
    func takeCatalogDriftObservation() async -> Bool {
        await client.takeCatalogDriftObservation()
    }
}
