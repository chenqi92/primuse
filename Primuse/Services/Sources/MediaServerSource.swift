import CryptoKit
import Foundation
import PrimuseKit

actor MediaServerSource: RefreshingMetadataSongConnector, MediaServerWritebackConnector,
    ServerLyricsConnector, ServerPlaylistConnector, ServerFavoriteConnector, ServerRadioConnector,
    ServerRadioStreamResolvingConnector {
    typealias RequestDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let maximumCatalogTracks = 10_000_000
    private static let maximumPlaylistCount = 100_000
    private static let playlistPageSize = 200
    private static let maximumLyricsResponseBytes = 2 * 1024 * 1024

    enum Kind: Sendable {
        case jellyfin
        case emby
        case plex
    }

    let sourceID: String
    nonisolated let serverLyricsCapabilities: ServerLyricsCapabilities

    private let kind: Kind
    private let baseURL: URL
    private let username: String
    private let secret: String
    private let authType: SourceAuthType
    private let session: URLSession
    private let requestDataLoader: RequestDataLoader?
    private let deviceID: String
    private let cacheDirectory: URL

    private var accessToken: String?
    private var userID: String?
    private var loginTask: Task<Void, Error>?
    private var plexItems: [String: PlexAudioItem] = [:]
    private var plexAPIVersion: String?
    private var plexSigninState: String?
    private var embyLyricsStreams: [String: EmbyLyricsStreamDescriptor] = [:]
    private var embyLyricsProbedItemIDs: Set<String> = []

    init(
        sourceID: String,
        kind: Kind,
        host: String,
        port: Int?,
        useSsl: Bool,
        basePath: String?,
        username: String,
        secret: String,
        authType: SourceAuthType,
        alternateTLSValidationHostname: String? = nil,
        requestDataLoader: RequestDataLoader? = nil
    ) {
        self.sourceID = sourceID
        self.kind = kind
        switch kind {
        case .jellyfin:
            self.serverLyricsCapabilities = ServerLyricsCapabilities(
                canRead: true,
                canWrite: true,
                canDelete: true,
                supportsSiblingSidecarLookup: false
            )
        case .emby:
            self.serverLyricsCapabilities = .readOnlyDocument
        case .plex:
            self.serverLyricsCapabilities = .unavailable
        }
        self.baseURL = Self.makeBaseURL(
            host: host,
            port: port,
            useSsl: useSsl,
            basePath: basePath
        )
        self.username = username
        self.secret = secret
        self.authType = authType
        self.requestDataLoader = requestDataLoader
        self.deviceID = "primuse-\(sourceID)"

        let configuration = URLSessionConfiguration.default
        // Matches WebDAV / Subsonic / Synology: a catalogue request over the
        // public internet needs more than a LAN-sized budget.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
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

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_media_server_cache_\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory
    }

    func connect() async throws {
        if accessToken != nil, userID != nil {
            return
        }
        if let loginTask {
            try await loginTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.establishConnection()
        }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    private func establishConnection() async throws {

        if kind == .plex {
            guard secret.isEmpty == false else {
                throw SourceError.authenticationFailed
            }

            accessToken = secret
            let serverInfo = try await fetchPlexServerInfo()
            plexAPIVersion = serverInfo.apiVersion
            plexSigninState = serverInfo.myPlexSigninState
            userID = "plex"
            return
        }

        switch authType {
        case .apiKey:
            guard secret.isEmpty == false else {
                throw SourceError.authenticationFailed
            }
            accessToken = secret
            userID = try await fetchCurrentUserID()
        default:
            // Jellyfin/Emby allow a named account with no password. The empty
            // string must still be sent as `Pw` to AuthenticateByName.
            guard username.isEmpty == false else {
                throw SourceError.authenticationFailed
            }

            let payload = [
                "Username": username,
                "Pw": secret
            ]
            let data = try SafeJSONSerialization.data(withJSONObject: payload)
            let response = try await performRequest(
                path: "/Users/AuthenticateByName",
                method: "POST",
                body: data,
                requiresAuth: false
            )
            let auth = try decoder.decode(LoginResponse.self, from: response)
            accessToken = auth.accessToken
            userID = auth.user.id
        }
    }

    func disconnect() async {
        loginTask?.cancel()
        loginTask = nil
        accessToken = nil
        userID = nil
        plexItems.removeAll()
        plexAPIVersion = nil
        plexSigninState = nil
        embyLyricsStreams.removeAll()
        embyLyricsProbedItemIDs.removeAll()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()

        guard normalize(path) == "/" else {
            return []
        }

        let libraries = try await fetchLibraries()
        let filteredLibraries = preferredLibraries(from: libraries)

        return filteredLibraries.map { library in
            RemoteFileItem(
                name: library.name,
                path: libraryPath(for: library.id, name: library.name),
                isDirectory: true,
                size: Int64(library.childCount ?? 0),
                modifiedDate: nil
            )
        }
    }

    func localURL(for path: String) async throws -> URL {
        try await connect()

        guard let itemID = itemID(from: path) else {
            throw SourceError.fileNotFound(path)
        }

        let fileExtension = (path as NSString).pathExtension.isEmpty ? "mp3" : (path as NSString).pathExtension
        let fileURL = cacheDirectory.appendingPathComponent("\(itemID).\(fileExtension)")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let remoteURL = try await playbackURL(for: itemID)

        let (temporaryURL, response) = try await TrustedHTTPTransport.download(
            from: remoteURL,
            session: session,
            timeout: 60
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

    func streamingURL(for path: String) async throws -> URL? {
        try await connect()

        guard let itemID = itemID(from: path) else {
            throw SourceError.fileNotFound(path)
        }

        let url = try await playbackURL(for: itemID)
        return requiresConnectorBackedTransport(for: url) ? nil : url
    }

    /// Catalogue rows persist an absolute artwork URL produced by whichever
    /// route performed the scan. Rebuild that service-owned path on this
    /// connector's current endpoint so a LAN scan remains usable on the
    /// Internet (and vice versa), while refreshing the route's auth token.
    func imageURL(for reference: String) async throws -> URL? {
        guard let original = URL(string: reference), original.scheme != nil else {
            return nil
        }
        try await connect()
        guard let accessToken else { throw SourceError.authenticationFailed }

        switch kind {
        case .jellyfin, .emby:
            return SourceConnectionURLRewriter.rebasedURL(
                for: original,
                onto: baseURL,
                pathMarkers: ["/Items/"],
                removingQueryItemsNamed: ["api_key", "X-Emby-Token"],
                addingQueryItems: [URLQueryItem(name: "api_key", value: accessToken)]
            )
        case .plex:
            return SourceConnectionURLRewriter.rebasedURL(
                for: original,
                onto: baseURL,
                pathMarkers: ["/library/", "/playlists/", "/photo/"],
                removingQueryItemsNamed: ["X-Plex-Token"],
                addingQueryItems: [URLQueryItem(name: "X-Plex-Token", value: accessToken)]
            )
        }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await fetchRange(path: path, offset: offset, length: length, allowReauthentication: true)
    }

    private func fetchRange(
        path: String,
        offset: Int64,
        length: Int64,
        allowReauthentication: Bool
    ) async throws -> Data {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        try await connect()
        guard let itemID = itemID(from: path) else {
            throw SourceError.fileNotFound(path)
        }
        var request = URLRequest(url: try await playbackURL(for: itemID))
        request.httpMethod = "GET"
        request.timeoutInterval = 60
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
            throw SourceError.connectionFailed("Invalid media-server range response")
        }
        if (http.statusCode == 401 || http.statusCode == 403),
           allowReauthentication,
           kind != .plex,
           authType != .apiKey {
            accessToken = nil
            userID = nil
            return try await fetchRange(
                path: path,
                offset: offset,
                length: length,
                allowReauthentication: false
            )
        }
        if httpMediaResponseLooksLikeErrorBody(http, data: data) {
            throw SourceError.connectionFailed("Media server returned a non-audio response")
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
                throw SourceError.connectionFailed("Invalid media-server Content-Range response")
            }
            return data
        case 200:
            guard HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw SourceError.connectionFailed("Media server ignored the byte Range request")
            }
            return data
        default:
            throw SourceError.connectionFailed("Media-server range request failed: HTTP \(http.statusCode)")
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { handle.closeFile() }
                    let chunkSize = 64 * 1024
                    while true {
                        let data = handle.readData(ofLength: chunkSize)
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Delete through the media server instead of only removing Primuse's
    /// local row. Jellyfin/Emby expose Items/{id}; Plex uses the ratingKey
    /// metadata endpoint and deletes the underlying media as well.
    func deleteFile(at path: String) async throws {
        try await connect()
        guard let itemID = itemID(from: path) else {
            throw SourceError.fileNotFound(path)
        }
        switch kind {
        case .jellyfin, .emby:
            _ = try await performRequest(path: "/Items/\(itemID)", method: "DELETE")
        case .plex:
            _ = try await performRequest(path: "/library/metadata/\(itemID)", method: "DELETE")
            plexItems.removeValue(forKey: itemID)
        }
        let ext = (path as NSString).pathExtension.isEmpty ? "mp3" : (path as NSString).pathExtension
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("\(itemID).\(ext)"))
        plog("🗑️ Media server item deleted: \(itemID)")
    }

    private func playbackURL(for itemID: String) async throws -> URL {
        switch kind {
        case .plex:
            return try await plexPlaybackURL(for: itemID)
        case .jellyfin, .emby:
            guard let accessToken else {
                throw SourceError.authenticationFailed
            }
            return buildURL(
                path: "/Audio/\(itemID)/stream",
                queryItems: [
                    URLQueryItem(name: "Static", value: "true"),
                    URLQueryItem(name: "api_key", value: accessToken)
                ]
            )
        }
    }

    private func radioPlaybackURL(for itemID: String) throws -> URL {
        guard kind != .plex, let accessToken else {
            throw SourceError.authenticationFailed
        }
        return buildURL(
            path: "/Audio/\(itemID)/stream.mp3",
            queryItems: [
                URLQueryItem(name: "Static", value: "false"),
                URLQueryItem(name: "AudioCodec", value: "mp3"),
                URLQueryItem(name: "Container", value: "mp3"),
                URLQueryItem(name: "api_key", value: accessToken)
            ]
        )
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let stream = try await scanSongs(from: path)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await scannedSong in stream {
                        continuation.yield(
                            RemoteFileItem(
                                name: scannedSong.displayName,
                                path: scannedSong.song.filePath,
                                isDirectory: false,
                                size: scannedSong.song.fileSize,
                                modifiedDate: scannedSong.song.lastModified
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()

        let normalizedPath = normalize(path)
        let libraryIDs: [String]
        if normalizedPath == "/" {
            // Media-server sources are whole-library sources. ScanService uses
            // "/" as the shared sentinel for that contract, so resolve it to
            // every visible music library before enumerating tracks.
            libraryIDs = preferredLibraries(from: try await fetchLibraries()).map(\.id)
        } else if let libraryID = libraryID(from: normalizedPath) {
            libraryIDs = [libraryID]
        } else {
            throw SourceError.pathNotFound(path)
        }

        let scanStartedAt = Date()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let pageSize = 200
                    var seenTrackIDs: Set<String> = []

                    for libraryID in libraryIDs {
                        var startIndex = 0
                        var expectedTotal: Int?
                        var seenPages: Set<String> = []

                        switch kind {
                        case .plex:
                            while true {
                                try Task.checkCancellation()
                                let result = try await fetchPlexTracks(
                                    sectionID: libraryID,
                                    startIndex: startIndex,
                                    limit: pageSize
                                )

                                if let total = result.totalCount {
                                    guard total >= 0, total <= Self.maximumCatalogTracks else {
                                        throw SourceError.connectionFailed(PMString("error.catalog.invalidTotal"))
                                    }
                                    if let expectedTotal, expectedTotal != total {
                                        throw SourceError.connectionFailed(PMString("error.catalog.totalChanged"))
                                    }
                                    expectedTotal = total
                                }
                                if result.items.isEmpty {
                                    if let expectedTotal, startIndex < expectedTotal {
                                        throw SourceError.connectionFailed(PMString("error.catalog.pageEndedEarly"))
                                    }
                                    break
                                }
                                guard result.items.count <= pageSize else {
                                    throw SourceError.connectionFailed(PMString("error.catalog.invalidPageCount"))
                                }
                                let pageIDs = result.items.map(\.ratingKey)
                                guard seenPages.insert(Self.catalogPageSignature(pageIDs)).inserted else {
                                    throw SourceError.connectionFailed(PMString("error.catalog.duplicateItem"))
                                }

                                for item in result.items {
                                    guard seenTrackIDs.insert(item.ratingKey).inserted else { continue }
                                    guard seenTrackIDs.count <= Self.maximumCatalogTracks else {
                                        throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
                                    }
                                    plexItems[item.ratingKey] = item
                                    let song = buildSong(from: item)
                                    continuation.yield(
                                        ConnectorScannedSong(
                                            song: song,
                                            displayName: item.title,
                                            titleMetadataInspected: ServerCatalogMetadataInspectionPolicy.hasUsableTitle(
                                                item.title
                                            )
                                        )
                                    )
                                }

                                startIndex += result.items.count
                                if let expectedTotal {
                                    guard startIndex <= expectedTotal else {
                                        throw SourceError.connectionFailed(PMString("error.catalog.pageExceedsTotal"))
                                    }
                                    if startIndex == expectedTotal { break }
                                }
                            }
                        case .jellyfin, .emby:
                            while true {
                                try Task.checkCancellation()
                                let result = try await fetchAudioItems(
                                    parentID: libraryID,
                                    startIndex: startIndex,
                                    limit: pageSize
                                )

                                if let total = result.totalRecordCount {
                                    guard total >= 0, total <= Self.maximumCatalogTracks else {
                                        throw SourceError.connectionFailed(PMString("error.catalog.invalidTotal"))
                                    }
                                    if let expectedTotal, expectedTotal != total {
                                        throw SourceError.connectionFailed(PMString("error.catalog.totalChanged"))
                                    }
                                    expectedTotal = total
                                }
                                if result.items.isEmpty {
                                    if let expectedTotal, startIndex < expectedTotal {
                                        throw SourceError.connectionFailed(PMString("error.catalog.pageEndedEarly"))
                                    }
                                    break
                                }
                                guard result.items.count <= pageSize else {
                                    throw SourceError.connectionFailed(PMString("error.catalog.invalidPageCount"))
                                }
                                let pageIDs = result.items.map(\.id)
                                guard seenPages.insert(Self.catalogPageSignature(pageIDs)).inserted else {
                                    throw SourceError.connectionFailed(PMString("error.catalog.duplicateItem"))
                                }

                                for item in result.items {
                                    guard seenTrackIDs.insert(item.id).inserted else { continue }
                                    guard seenTrackIDs.count <= Self.maximumCatalogTracks else {
                                        throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
                                    }
                                    if kind == .emby {
                                        embyLyricsProbedItemIDs.insert(item.id)
                                        embyLyricsStreams[item.id] = item.embyLyricsStream
                                    }
                                    let song = buildSong(
                                        from: item,
                                        dateAddedFallback: scanStartedAt
                                    )
                                    continuation.yield(
                                        ConnectorScannedSong(
                                            song: song,
                                            displayName: item.name,
                                            titleMetadataInspected: ServerCatalogMetadataInspectionPolicy.hasUsableTitle(
                                                item.name
                                            )
                                        )
                                    )
                                }

                                startIndex += result.items.count
                                if let expectedTotal {
                                    guard startIndex <= expectedTotal else {
                                        throw SourceError.connectionFailed(PMString("error.catalog.pageExceedsTotal"))
                                    }
                                    if startIndex == expectedTotal { break }
                                }
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func writeScrapedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        lyricsContent: String?
    ) async -> MediaServerWritebackResult {
        var result = MediaServerWritebackResult()
        let requestedFields = TagMetadataWritebackField.changedFields(
            from: original,
            to: updated,
            includesCover: coverData?.isEmpty == false
        )
        let requestedMetadataFields = requestedFields.intersection(
            TagMetadataWritebackField.metadataFields
        )

        do {
            try await connect()
        } catch {
            result.errors.append("Connection: \(error.localizedDescription)")
            result.fieldResults = requestedFields.map {
                TagMetadataFieldWritebackResult(
                    field: $0,
                    disposition: .failed(error.localizedDescription)
                )
            }
            return result
        }

        guard let itemID = itemID(from: updated.filePath) else {
            let detail = String(localized: "metadata_writeback_media_invalid_item")
            result.errors.append(detail)
            result.fieldResults = requestedFields.map {
                TagMetadataFieldWritebackResult(field: $0, disposition: .failed(detail))
            }
            return result
        }

        if !requestedMetadataFields.isEmpty {
            switch kind {
            case .jellyfin, .emby:
                do {
                    try await updateJellyfinOrEmbyItem(itemID: itemID, song: updated)
                    let mismatched = try await jellyfinOrEmbyReadbackMismatches(
                        itemID: itemID,
                        expected: updated,
                        fields: requestedMetadataFields
                    )
                    result.fieldResults.append(contentsOf: requestedMetadataFields.map { field in
                        TagMetadataFieldWritebackResult(
                            field: field,
                            disposition: mismatched.contains(field)
                                ? .failed(String(localized: "metadata_writeback_media_readback_mismatch"))
                                : .written
                        )
                    })
                    result.metadataWritten = mismatched.count < requestedMetadataFields.count
                    if !mismatched.isEmpty {
                        result.errors.append(
                            String(localized: "metadata_writeback_media_readback_mismatch")
                        )
                    }
                } catch {
                    result.errors.append("Metadata: \(error.localizedDescription)")
                    result.fieldResults.append(contentsOf: requestedMetadataFields.map {
                        TagMetadataFieldWritebackResult(
                            field: $0,
                            disposition: .failed(error.localizedDescription)
                        )
                    })
                }
            case .plex:
                let plexResults = await updatePlexMetadata(
                    ratingKey: itemID,
                    original: original,
                    updated: updated
                )
                let verifiedPlexResults = await verifyPlexMetadataReadback(
                    ratingKey: itemID,
                    expected: updated,
                    results: plexResults
                )
                result.fieldResults.append(contentsOf: verifiedPlexResults)
                result.metadataWritten = verifiedPlexResults.contains {
                    if case .written = $0.disposition { return true }
                    return false
                }
                for fieldResult in verifiedPlexResults {
                    switch fieldResult.disposition {
                    case .failed(let detail):
                        result.errors.append(
                            "\(fieldResult.field.localizedName): \(detail)"
                        )
                    case .unsupported(let detail):
                        result.unsupported.append(
                            "\(fieldResult.field.localizedName): \(detail)"
                        )
                    case .unchanged, .written, .localOnly:
                        break
                    }
                }
            }
        }

        if let coverData, !coverData.isEmpty {
            do {
                try await uploadCover(itemID: itemID, data: coverData)
                result.coverWritten = true
                result.fieldResults.append(
                    TagMetadataFieldWritebackResult(field: .cover, disposition: .written)
                )
            } catch {
                result.errors.append("Cover: \(error.localizedDescription)")
                result.fieldResults.append(
                    TagMetadataFieldWritebackResult(
                        field: .cover,
                        disposition: .failed(error.localizedDescription)
                    )
                )
            }
        }

        if let lyricsLines, !lyricsLines.isEmpty {
            switch kind {
            case .jellyfin:
                do {
                    try await uploadJellyfinLyrics(
                        itemID: itemID,
                        title: updated.title,
                        lines: lyricsLines,
                        content: lyricsContent
                    )
                    result.lyricsWritten = true
                } catch {
                    result.errors.append("Lyrics: \(error.localizedDescription)")
                }
            case .emby:
                result.unsupported.append("Emby does not expose a lyrics upload API")
            case .plex:
                result.unsupported.append("Plex requires a same-name .lrc file in the media directory")
            }
        }

        return result
    }

    func removeLyrics(for song: Song) async -> MediaServerWritebackResult {
        var result = MediaServerWritebackResult()
        do {
            try await connect()
            guard let itemID = itemID(from: song.filePath) else {
                result.errors.append("Invalid media-server item path: \(song.filePath)")
                return result
            }
            switch kind {
            case .jellyfin:
                _ = try await performRequest(
                    path: "/Audio/\(itemID)/Lyrics",
                    method: "DELETE"
                )
                result.lyricsRemoved = true
            case .emby:
                result.unsupported.append("Emby does not expose a lyrics deletion API")
            case .plex:
                result.unsupported.append("Plex requires deleting the same-name .lrc file in the media directory")
            }
        } catch {
            result.errors.append("Lyrics: \(error.localizedDescription)")
        }
        return result
    }

    func fetchServerLyrics(for path: String) async -> String? {
        guard let itemID = itemID(from: path) else { return nil }
        do {
            try await connect()
            switch kind {
            case .jellyfin:
                let data = try await performRequest(
                    path: "/Audio/\(itemID)/Lyrics",
                    maximumResponseBytes: Self.maximumLyricsResponseBytes
                )
                let response = try decoder.decode(JellyfinLyricResponse.self, from: data)
                return response.editableContent
            case .emby:
                guard let stream = try await embyLyricsStream(for: itemID) else { return nil }
                let data = try await performRequest(
                    path: "/Items/\(itemID)/\(stream.mediaSourceID)/Subtitles/\(stream.streamIndex)/Stream.js",
                    maximumResponseBytes: Self.maximumLyricsResponseBytes
                )
                return try EmbyLyricsTrackEventParser.editableText(from: data)
            case .plex:
                return nil
            }
        } catch {
            return nil
        }
    }

    private func embyLyricsStream(for itemID: String) async throws -> EmbyLyricsStreamDescriptor? {
        if let cached = embyLyricsStreams[itemID] {
            return cached
        }
        if embyLyricsProbedItemIDs.contains(itemID) {
            return nil
        }
        guard let userID else { throw SourceError.authenticationFailed }
        let data = try await performRequest(
            path: "/Users/\(userID)/Items/\(itemID)",
            queryItems: [URLQueryItem(name: "Fields", value: "MediaSources,MediaStreams")],
            maximumResponseBytes: Self.maximumLyricsResponseBytes
        )
        let item = try decoder.decode(AudioItem.self, from: data)
        let descriptor = item.embyLyricsStream
        embyLyricsProbedItemIDs.insert(itemID)
        embyLyricsStreams[itemID] = descriptor
        return descriptor
    }

    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        try await connect()

        if kind == .plex {
            return try await fetchPlexPlaylists()
        } else {
            return try await fetchJellyfinOrEmbyPlaylists()
        }
    }

    func fetchServerFavorites() async throws -> ServerFavoriteSnapshot {
        guard kind == .emby else {
            throw SourceError.connectionFailed(String(localized: "server_favorite_unsupported"))
        }
        try await connect()
        return try await fetchEmbyFavoriteSnapshot()
    }

    func setServerFavorite(
        itemID: String,
        isFavorite: Bool
    ) async throws -> ServerFavoriteSnapshot {
        guard kind == .emby else {
            throw SourceError.connectionFailed(String(localized: "server_favorite_unsupported"))
        }
        try await connect()
        guard let userID else { throw SourceError.authenticationFailed }

        _ = try await performRequest(
            path: "/Users/\(userID)/FavoriteItems/\(itemID)",
            method: isFavorite ? "POST" : "DELETE",
            retriesIdempotentMutationAfterAuthentication: true
        )

        let refreshed = try await fetchEmbyFavoriteSnapshot()
        guard refreshed.itemIDs.contains(itemID) == isFavorite else {
            throw SourceError.connectionFailed(String(localized: "server_favorite_refresh_mismatch"))
        }
        return refreshed
    }

    func fetchServerRadioStations() async throws -> ServerRadioStationSnapshot? {
        guard kind != .plex else { return nil }
        try await connect()
        guard let userID else { throw SourceError.authenticationFailed }

        let response = try await fetchAllJellyfinOrEmbyItems(
            path: "/LiveTv/Channels",
            baseQueryItems: [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "Type", value: "Radio"),
                URLQueryItem(name: "EnableImages", value: "true")
            ],
            maximumCount: Self.maximumPlaylistCount,
            deduplicatesItems: true
        )
        let stations = response.items.compactMap { item -> ServerRadioStation? in
            if let channelType = item.channelType,
               channelType.caseInsensitiveCompare("Radio") != .orderedSame {
                return nil
            }
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return ServerRadioStation(
                id: item.id,
                name: name.isEmpty ? item.id : name,
                coverArtReference: playlistCoverArtReference(for: item),
                sourcePlaybackPath: ServerRadioStationIdentity.mediaServerPlaybackPath(
                    serverStationID: item.id
                ),
                streamFormat: .mp3
            )
        }
        return ServerRadioStationSnapshot(stations: stations)
    }

    func resolveServerRadioStream(stationID: String, forceRefresh: Bool) async throws -> URL {
        guard kind != .plex else {
            throw SourceError.connectionFailed("Plex server radio is unavailable")
        }
        if forceRefresh {
            loginTask?.cancel()
            loginTask = nil
            accessToken = nil
            userID = nil
        }
        try await connect()
        return try radioPlaybackURL(for: stationID)
    }

    private func fetchJellyfinOrEmbyPlaylists() async throws -> ServerPlaylistSnapshot {
        guard let userID else { throw SourceError.authenticationFailed }

        let summaryResponse = try await fetchAllJellyfinOrEmbyItems(
            path: "/Users/\(userID)/Items",
            baseQueryItems: [
                URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "Fields", value: "ChildCount,ImageTags")
            ],
            maximumCount: Self.maximumPlaylistCount,
            deduplicatesItems: true
        )
        guard summaryResponse.items.isEmpty == false else {
            return ServerPlaylistSnapshot(playlists: [])
        }

        var result: [ServerPlaylist] = []
        var failedPlaylistIDs = Set<String>()
        result.reserveCapacity(summaryResponse.items.count)

        for summary in summaryResponse.items {
            try Task.checkCancellation()
            do {
                let itemsResponse = try await fetchAllJellyfinOrEmbyItems(
                    path: "/Playlists/\(summary.id)/Items",
                    baseQueryItems: [URLQueryItem(name: "UserId", value: userID)],
                    maximumCount: Self.maximumCatalogTracks,
                    deduplicatesItems: false
                )
                result.append(ServerPlaylist(
                    id: summary.id,
                    name: summary.name.isEmpty ? summary.id : summary.name,
                    coverArtReference: playlistCoverArtReference(for: summary),
                    trackIDs: itemsResponse.items.map(\.id),
                    reportedTrackCount: itemsResponse.totalCount
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                plog("⚠️ \(kind == .jellyfin ? "Jellyfin" : "Emby") playlist '\(summary.name)' items fetch failed: \(error.localizedDescription)")
                failedPlaylistIDs.insert(summary.id)
            }
        }
        return ServerPlaylistSnapshot(
            playlists: result,
            failedPlaylistIDs: failedPlaylistIDs
        )
    }

    private func fetchEmbyFavoriteSnapshot() async throws -> ServerFavoriteSnapshot {
        guard let userID else { throw SourceError.authenticationFailed }
        let response = try await fetchAllJellyfinOrEmbyItems(
            path: "/Users/\(userID)/Items",
            baseQueryItems: [
                URLQueryItem(name: "Filters", value: "IsFavorite"),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending")
            ],
            maximumCount: Self.maximumCatalogTracks,
            deduplicatesItems: true
        )
        return ServerFavoriteSnapshot(itemIDs: response.items.map(\.id))
    }

    private func fetchPlexPlaylists() async throws -> ServerPlaylistSnapshot {
        let summaries = try await fetchAllPlexPlaylistSummaries()
        let audioPlaylists = summaries.filter { $0.playlistType == "audio" }
        guard audioPlaylists.isEmpty == false else {
            return ServerPlaylistSnapshot(playlists: [])
        }

        var result: [ServerPlaylist] = []
        var failedPlaylistIDs = Set<String>()
        result.reserveCapacity(audioPlaylists.count)

        for summary in audioPlaylists {
            try Task.checkCancellation()
            do {
                let itemsResponse = try await fetchAllPlexPlaylistItems(
                    playlistID: summary.ratingKey
                )
                result.append(ServerPlaylist(
                    id: summary.ratingKey,
                    name: summary.title.isEmpty ? summary.ratingKey : summary.title,
                    coverArtReference: playlistCoverArtReference(for: summary),
                    trackIDs: itemsResponse.items.map(\.ratingKey),
                    reportedTrackCount: itemsResponse.totalCount ?? summary.leafCount
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                plog("⚠️ Plex playlist '\(summary.title)' items fetch failed: \(error.localizedDescription)")
                failedPlaylistIDs.insert(summary.ratingKey)
            }
        }
        return ServerPlaylistSnapshot(
            playlists: result,
            failedPlaylistIDs: failedPlaylistIDs
        )
    }

    /// Jellyfin / Emby 的 Items API 会按服务器默认上限截断；歌单列表和每份歌单
    /// 明细都必须显式翻页。列表级失败向上抛出，明细级失败由调用方记录失败 ID。
    private func fetchAllJellyfinOrEmbyItems(
        path: String,
        baseQueryItems: [URLQueryItem],
        maximumCount: Int,
        deduplicatesItems: Bool
    ) async throws -> (items: [AudioItem], totalCount: Int?) {
        var startIndex = 0
        var expectedTotal: Int?
        var seenPages = Set<String>()
        var seenItemIDs = Set<String>()
        var result: [AudioItem] = []

        while true {
            try Task.checkCancellation()
            let data = try await performRequest(
                path: path,
                queryItems: baseQueryItems + [
                    URLQueryItem(name: "StartIndex", value: String(startIndex)),
                    URLQueryItem(name: "Limit", value: String(Self.playlistPageSize))
                ]
            )
            let page = try decoder.decode(ItemResponse.self, from: data)
            if let total = page.totalRecordCount {
                guard total >= 0, total <= maximumCount else {
                    throw SourceError.connectionFailed(PMString("error.catalog.invalidTotal"))
                }
                if let expectedTotal, expectedTotal != total {
                    throw SourceError.connectionFailed(PMString("error.catalog.totalChanged"))
                }
                expectedTotal = total
            }
            if page.items.isEmpty {
                if let expectedTotal, startIndex < expectedTotal {
                    throw SourceError.connectionFailed(PMString("error.catalog.pageEndedEarly"))
                }
                break
            }
            guard page.items.count <= Self.playlistPageSize else {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidPageCount"))
            }
            let pageIDs = page.items.map(\.id)
            guard seenPages.insert(Self.catalogPageSignature(pageIDs)).inserted else {
                throw SourceError.connectionFailed(PMString("error.catalog.duplicateItem"))
            }
            if deduplicatesItems {
                for item in page.items where seenItemIDs.insert(item.id).inserted {
                    guard seenItemIDs.count <= maximumCount else {
                        throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
                    }
                    result.append(item)
                }
            } else {
                guard result.count + page.items.count <= maximumCount else {
                    throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
                }
                result.append(contentsOf: page.items)
            }

            startIndex += page.items.count
            guard startIndex <= maximumCount else {
                throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
            }
            if let expectedTotal {
                guard startIndex <= expectedTotal else {
                    throw SourceError.connectionFailed(PMString("error.catalog.pageExceedsTotal"))
                }
                if startIndex == expectedTotal { break }
            }
        }

        return (result, expectedTotal)
    }

    private func fetchAllPlexPlaylistSummaries() async throws -> [PlexPlaylistSummary] {
        var startIndex = 0
        var expectedTotal: Int?
        var seenPages = Set<String>()
        var seenItemIDs = Set<String>()
        var result: [PlexPlaylistSummary] = []

        while true {
            try Task.checkCancellation()
            let data = try await performRequest(
                path: "/playlists",
                queryItems: [
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(startIndex)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(Self.playlistPageSize))
                ]
            )
            let page = try decoder.decode(PlexPlaylistResponse.self, from: data).mediaContainer
            try Self.validatePlaylistPageTotal(
                page.totalSize,
                expectedTotal: &expectedTotal,
                maximumCount: Self.maximumPlaylistCount
            )
            if let size = page.size, size != page.playlists.count {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidPageCount"))
            }
            if page.playlists.isEmpty {
                if let expectedTotal, startIndex < expectedTotal {
                    throw SourceError.connectionFailed(PMString("error.catalog.pageEndedEarly"))
                }
                break
            }
            guard page.playlists.count <= Self.playlistPageSize else {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidPageCount"))
            }
            let pageIDs = page.playlists.map(\.ratingKey)
            guard seenPages.insert(Self.catalogPageSignature(pageIDs)).inserted else {
                throw SourceError.connectionFailed(PMString("error.catalog.duplicateItem"))
            }
            for item in page.playlists where seenItemIDs.insert(item.ratingKey).inserted {
                guard seenItemIDs.count <= Self.maximumPlaylistCount else {
                    throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
                }
                result.append(item)
            }

            startIndex += page.playlists.count
            guard startIndex <= Self.maximumPlaylistCount else {
                throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
            }
            if let expectedTotal {
                guard startIndex <= expectedTotal else {
                    throw SourceError.connectionFailed(PMString("error.catalog.pageExceedsTotal"))
                }
                if startIndex == expectedTotal { break }
            }
        }
        return result
    }

    private func fetchAllPlexPlaylistItems(
        playlistID: String
    ) async throws -> (items: [PlexPlaylistTrack], totalCount: Int?) {
        var startIndex = 0
        var expectedTotal: Int?
        var seenPages = Set<String>()
        var result: [PlexPlaylistTrack] = []

        while true {
            try Task.checkCancellation()
            let data = try await performRequest(
                path: "/playlists/\(playlistID)/items",
                queryItems: [
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(startIndex)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(Self.playlistPageSize))
                ]
            )
            let page = try decoder.decode(PlexPlaylistItemsResponse.self, from: data).mediaContainer
            try Self.validatePlaylistPageTotal(
                page.totalSize,
                expectedTotal: &expectedTotal,
                maximumCount: Self.maximumCatalogTracks
            )
            if let size = page.size, size != page.tracks.count {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidPageCount"))
            }
            if page.tracks.isEmpty {
                if let expectedTotal, startIndex < expectedTotal {
                    throw SourceError.connectionFailed(PMString("error.catalog.pageEndedEarly"))
                }
                break
            }
            guard page.tracks.count <= Self.playlistPageSize else {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidPageCount"))
            }
            let pageIDs = page.tracks.map(\.ratingKey)
            guard seenPages.insert(Self.catalogPageSignature(pageIDs)).inserted else {
                throw SourceError.connectionFailed(PMString("error.catalog.duplicateItem"))
            }
            guard result.count + page.tracks.count <= Self.maximumCatalogTracks else {
                throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
            }
            result.append(contentsOf: page.tracks)

            startIndex += page.tracks.count
            guard startIndex <= Self.maximumCatalogTracks else {
                throw SourceError.connectionFailed(PMString("error.catalog.pageOverflow"))
            }
            if let expectedTotal {
                guard startIndex <= expectedTotal else {
                    throw SourceError.connectionFailed(PMString("error.catalog.pageExceedsTotal"))
                }
                if startIndex == expectedTotal { break }
            }
        }
        return (result, expectedTotal)
    }

    private static func validatePlaylistPageTotal(
        _ total: Int?,
        expectedTotal: inout Int?,
        maximumCount: Int
    ) throws {
        guard let total else { return }
        guard total >= 0, total <= maximumCount else {
            throw SourceError.connectionFailed(PMString("error.catalog.invalidTotal"))
        }
        if let expectedTotal, expectedTotal != total {
            throw SourceError.connectionFailed(PMString("error.catalog.totalChanged"))
        }
        expectedTotal = total
    }

    private func fetchLibraries() async throws -> [Library] {
        if kind == .plex {
            let data = try await performRequest(path: "/library/sections")
            let response = try decoder.decode(PlexLibraryResponse.self, from: data)
            return response.mediaContainer.directories.map {
                Library(
                    id: $0.key,
                    name: $0.title,
                    collectionType: $0.type,
                    childCount: nil
                )
            }
        }

        guard let userID else { throw SourceError.authenticationFailed }
        let data = try await performRequest(path: "/Users/\(userID)/Views")
        let response = try decoder.decode(LibraryResponse.self, from: data)
        return response.items
    }

    private func fetchAudioItems(
        parentID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> ItemResponse {
        guard let userID else { throw SourceError.authenticationFailed }

        let fields = [
            "Album",
            "AlbumArtist",
            "AlbumArtists",
            "AlbumId",
            "AlbumPrimaryImageTag",
            "ArtistItems",
            "Artists",
            "DateCreated",
            "Genres",
            "IndexNumber",
            "MediaSources",
            "MediaStreams",
            "ParentIndexNumber",
            "Path",
            "ProductionYear"
        ].joined(separator: ",")

        let data = try await performRequest(
            path: "/Users/\(userID)/Items",
            queryItems: [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "Fields", value: fields),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(limit))
            ]
        )

        return try decoder.decode(ItemResponse.self, from: data)
    }

    private func fetchCurrentUserID() async throws -> String {
        if let userID {
            return userID
        }

        do {
            let data = try await performRequest(path: "/Users/Me")
            let user = try decoder.decode(User.self, from: data)
            userID = user.id
            return user.id
        } catch {
            let data = try await performRequest(path: "/Users")
            let users = try decoder.decode([User].self, from: data)
            guard let firstUser = users.first else {
                throw SourceError.authenticationFailed
            }
            userID = firstUser.id
            return firstUser.id
        }
    }

    private func performRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json",
        accept: String = "application/json",
        requiresAuth: Bool = true,
        allowPasswordReauthentication: Bool = true,
        retriesIdempotentMutationAfterAuthentication: Bool = false,
        maximumResponseBytes: Int = PlainHTTPClient.defaultMaxBytes
    ) async throws -> Data {
        var request = URLRequest(url: buildURL(path: path, queryItems: queryItems))
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        for (header, value) in headers(requiresAuth: requiresAuth) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (data, response): (Data, URLResponse)
        if let requestDataLoader {
            (data, response) = try await requestDataLoader(request)
        } else {
            (data, response) = try await TrustedHTTPTransport.data(
                for: request,
                session: session,
                maxBytes: maximumResponseBytes
            )
        }
        if requiresAuth,
           (method == "GET" || retriesIdempotentMutationAfterAuthentication),
           allowPasswordReauthentication,
           kind != .plex,
           authType != .apiKey,
           let http = response as? HTTPURLResponse,
           http.statusCode == 401 || http.statusCode == 403 {
            accessToken = nil
            userID = nil
            try await connect()
            return try await performRequest(
                path: path,
                method: method,
                queryItems: queryItems,
                body: body,
                contentType: contentType,
                accept: accept,
                requiresAuth: requiresAuth,
                allowPasswordReauthentication: false,
                retriesIdempotentMutationAfterAuthentication: false,
                maximumResponseBytes: maximumResponseBytes
            )
        }
        try validate(response)
        guard data.count <= maximumResponseBytes else {
            throw SourceError.connectionFailed("Response exceeds \(maximumResponseBytes) bytes")
        }
        return data
    }

    private func requiresConnectorBackedTransport(for url: URL) -> Bool {
        if TrustedHTTPTransport.requiresPlainSocket(for: url) {
            return true
        }
        guard url.scheme?.lowercased() == "https",
              let endpoint = NetworkEndpointIdentity(url: url) else {
            return false
        }
        return SSLTrustStore.isTrustedSync(domain: endpoint.key)
    }

    private func updateJellyfinOrEmbyItem(itemID: String, song: Song) async throws {
        let itemPath: String
        switch kind {
        case .jellyfin:
            itemPath = "/Items/\(itemID)"
        case .emby:
            guard let userID else { throw SourceError.authenticationFailed }
            itemPath = "/Users/\(userID)/Items/\(itemID)"
        case .plex:
            throw SourceError.connectionFailed("Invalid media-server update route")
        }
        let existingData = try await performRequest(path: itemPath)
        guard var item = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            throw SourceError.connectionFailed("Invalid item metadata response")
        }

        let artist = normalizedMetadataText(song.artistName)
        let albumArtist = normalizedMetadataText(song.albumArtistName) ?? artist
        item["Name"] = song.title
        item["AlbumArtist"] = albumArtist ?? ""
        item["Artists"] = artist.map { [$0] } ?? []
        item["Album"] = normalizedMetadataText(song.albumTitle) ?? ""
        item["IndexNumber"] = song.trackNumber.map { $0 as Any } ?? NSNull()
        item["ParentIndexNumber"] = song.discNumber.map { $0 as Any } ?? NSNull()
        item["ProductionYear"] = song.year.map { $0 as Any } ?? NSNull()
        item["Genres"] = normalizedMetadataText(song.genre).map {
            $0.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } ?? []

        let body = try SafeJSONSerialization.data(withJSONObject: item)
        _ = try await performRequest(path: "/Items/\(itemID)", method: "POST", body: body)
    }

    private func jellyfinOrEmbyReadbackMismatches(
        itemID: String,
        expected: Song,
        fields: Set<TagMetadataWritebackField>
    ) async throws -> Set<TagMetadataWritebackField> {
        var lastMismatch = fields
        for attempt in 0..<2 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(300)) }
            let path: String
            switch kind {
            case .jellyfin:
                path = "/Items/\(itemID)"
            case .emby:
                guard let userID else { throw SourceError.authenticationFailed }
                path = "/Users/\(userID)/Items/\(itemID)"
            case .plex:
                throw SourceError.connectionFailed("Invalid media-server readback route")
            }
            let data = try await performRequest(path: path)
            let item = try decoder.decode(AudioItem.self, from: data)
            lastMismatch = Set(fields.filter {
                !jellyfinOrEmbyItem(item, matches: $0, expected: expected)
            })
            if lastMismatch.isEmpty { return [] }
        }
        return lastMismatch
    }

    private func jellyfinOrEmbyItem(
        _ item: AudioItem,
        matches field: TagMetadataWritebackField,
        expected: Song
    ) -> Bool {
        switch field {
        case .title:
            return normalizedMetadataText(item.name) == normalizedMetadataText(expected.title)
        case .artist:
            let actual = item.artists?.first ?? item.albumArtist
            return normalizedMetadataText(actual) == normalizedMetadataText(expected.artistName)
        case .album:
            return normalizedMetadataText(item.album) == normalizedMetadataText(expected.albumTitle)
        case .genre:
            return normalizedGenreSet(item.genres?.joined(separator: ","))
                == normalizedGenreSet(expected.genre)
        case .year:
            return item.productionYear == expected.year
        case .trackNumber:
            return item.indexNumber == expected.trackNumber
        case .discNumber:
            return item.parentIndexNumber == expected.discNumber
        case .cover:
            return true
        }
    }

    private func updatePlexMetadata(
        ratingKey: String,
        original: Song,
        updated: Song
    ) async -> [TagMetadataFieldWritebackResult] {
        let changed = TagMetadataWritebackField.changedFields(
            from: original,
            to: updated,
            includesCover: false
        )
        var results: [TagMetadataFieldWritebackResult] = []
        let item: PlexAudioItem
        do {
            if let cached = plexItems[ratingKey] {
                item = cached
            } else {
                item = try await fetchPlexTrack(ratingKey: ratingKey)
            }
        } catch {
            return changed.map {
                TagMetadataFieldWritebackResult(
                    field: $0,
                    disposition: .failed(error.localizedDescription)
                )
            }
        }

        var trackFields: [URLQueryItem] = []
        var trackResultFields: Set<TagMetadataWritebackField> = []
        if original.title != updated.title {
            trackFields += [
                URLQueryItem(name: "title", value: updated.title),
                URLQueryItem(name: "title.locked", value: "1")
            ]
            trackResultFields.insert(.title)
        }
        if original.trackNumber != updated.trackNumber {
            trackFields += [
                URLQueryItem(name: "index", value: updated.trackNumber.map(String.init) ?? ""),
                URLQueryItem(name: "index.locked", value: "1")
            ]
            trackResultFields.insert(.trackNumber)
        }
        if original.discNumber != updated.discNumber {
            trackFields += [
                URLQueryItem(name: "parentIndex", value: updated.discNumber.map(String.init) ?? ""),
                URLQueryItem(name: "parentIndex.locked", value: "1")
            ]
            trackResultFields.insert(.discNumber)
        }
        if !trackFields.isEmpty {
            do {
                _ = try await performRequest(
                    path: "/library/metadata/\(ratingKey)",
                    method: "PUT",
                    queryItems: trackFields,
                    contentType: "application/octet-stream",
                    accept: "*/*"
                )
                results.append(contentsOf: trackResultFields.map {
                    TagMetadataFieldWritebackResult(field: $0, disposition: .written)
                })
            } catch {
                results.append(contentsOf: trackResultFields.map {
                    TagMetadataFieldWritebackResult(
                        field: $0,
                        disposition: .failed(error.localizedDescription)
                    )
                })
            }
        }

        var albumFields: [URLQueryItem] = []
        var albumResultFields: Set<TagMetadataWritebackField> = []
        if original.albumTitle != updated.albumTitle {
            albumFields += [
                URLQueryItem(name: "title", value: normalizedMetadataText(updated.albumTitle) ?? ""),
                URLQueryItem(name: "title.locked", value: "1")
            ]
            albumResultFields.insert(.album)
        }
        if original.year != updated.year {
            albumFields += [
                URLQueryItem(name: "year", value: updated.year.map(String.init) ?? ""),
                URLQueryItem(name: "year.locked", value: "1")
            ]
            albumResultFields.insert(.year)
        }
        if !albumFields.isEmpty {
            if let albumID = item.parentRatingKey {
                do {
                    _ = try await performRequest(
                        path: "/library/metadata/\(albumID)",
                        method: "PUT",
                        queryItems: albumFields,
                        contentType: "application/octet-stream",
                        accept: "*/*"
                    )
                    results.append(contentsOf: albumResultFields.map {
                        TagMetadataFieldWritebackResult(field: $0, disposition: .written)
                    })
                } catch {
                    results.append(contentsOf: albumResultFields.map {
                        TagMetadataFieldWritebackResult(
                            field: $0,
                            disposition: .failed(error.localizedDescription)
                        )
                    })
                }
            } else {
                let reason = String(localized: "metadata_writeback_plex_missing_album")
                results.append(contentsOf: albumResultFields.map {
                    TagMetadataFieldWritebackResult(field: $0, disposition: .unsupported(reason))
                })
            }
        }

        if original.artistName != updated.artistName {
            if let artistID = item.grandparentRatingKey {
                do {
                    _ = try await performRequest(
                        path: "/library/metadata/\(artistID)",
                        method: "PUT",
                        queryItems: [
                            URLQueryItem(
                                name: "title",
                                value: normalizedMetadataText(updated.artistName) ?? ""
                            ),
                            URLQueryItem(name: "title.locked", value: "1")
                        ],
                        contentType: "application/octet-stream",
                        accept: "*/*"
                    )
                    results.append(
                        TagMetadataFieldWritebackResult(field: .artist, disposition: .written)
                    )
                } catch {
                    results.append(
                        TagMetadataFieldWritebackResult(
                            field: .artist,
                            disposition: .failed(error.localizedDescription)
                        )
                    )
                }
            } else {
                results.append(
                    TagMetadataFieldWritebackResult(
                        field: .artist,
                        disposition: .unsupported(
                            String(localized: "metadata_writeback_plex_missing_artist")
                        )
                    )
                )
            }
        }

        if original.genre != updated.genre {
            results.append(
                TagMetadataFieldWritebackResult(
                    field: .genre,
                    disposition: .unsupported(
                        String(localized: "metadata_writeback_plex_genre_unsupported")
                    )
                )
            )
        }

        return results
    }

    private func normalizedMetadataText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedGenreSet(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(
            value.split(separator: ",")
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                .filter { !$0.isEmpty }
        )
    }

    private func verifyPlexMetadataReadback(
        ratingKey: String,
        expected: Song,
        results: [TagMetadataFieldWritebackResult]
    ) async -> [TagMetadataFieldWritebackResult] {
        let writtenFields = Set(results.compactMap { result -> TagMetadataWritebackField? in
            if case .written = result.disposition { return result.field }
            return nil
        })
        guard !writtenFields.isEmpty else { return results }

        var readback: PlexAudioItem?
        var readbackError: Error?
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            do {
                let item = try await fetchPlexTrack(ratingKey: ratingKey)
                readbackError = nil
                readback = item
                if writtenFields.allSatisfy({ plexItem(item, matches: $0, expected: expected) }) {
                    break
                }
            } catch {
                readbackError = error
            }
        }

        return results.map { result in
            guard case .written = result.disposition else { return result }
            let detail: String?
            if let readbackError {
                detail = readbackError.localizedDescription
            } else if let readback,
                      !plexItem(readback, matches: result.field, expected: expected) {
                detail = String(localized: "metadata_writeback_media_readback_mismatch")
            } else if readback == nil {
                detail = String(localized: "metadata_writeback_media_readback_mismatch")
            } else {
                detail = nil
            }
            guard let detail else { return result }
            return TagMetadataFieldWritebackResult(
                field: result.field,
                disposition: .failed(detail)
            )
        }
    }

    private func plexItem(
        _ item: PlexAudioItem,
        matches field: TagMetadataWritebackField,
        expected: Song
    ) -> Bool {
        switch field {
        case .title:
            return normalizedMetadataText(item.title) == normalizedMetadataText(expected.title)
        case .artist:
            return normalizedMetadataText(item.grandparentTitle)
                == normalizedMetadataText(expected.artistName)
        case .album:
            return normalizedMetadataText(item.parentTitle)
                == normalizedMetadataText(expected.albumTitle)
        case .year:
            return item.year == expected.year
        case .trackNumber:
            return item.index == expected.trackNumber
        case .discNumber:
            return item.parentIndex == expected.discNumber
        case .genre:
            return normalizedGenreSet(item.genres?.joined(separator: ","))
                == normalizedGenreSet(expected.genre)
        case .cover:
            return true
        }
    }

    private func uploadCover(itemID: String, data: Data) async throws {
        let contentType = Self.imageContentType(for: data)
        let encodedData = Data(data.base64EncodedString().utf8)
        switch kind {
        case .jellyfin:
            _ = try await performRequest(
                path: "/Items/\(itemID)/Images/Primary",
                method: "POST",
                body: encodedData,
                contentType: contentType
            )
        case .emby:
            _ = try await performRequest(
                path: "/Items/\(itemID)/Images/Primary",
                method: "POST",
                body: encodedData,
                contentType: contentType
            )
        case .plex:
            if plexSigninState?.lowercased() == "invalid" {
                throw SourceError.connectionFailed(
                    "Plex artwork upload requires a claimed server and an owner/admin token"
                )
            }
            let item: PlexAudioItem
            if let cached = plexItems[itemID] {
                item = cached
            } else {
                item = try await fetchPlexTrack(ratingKey: itemID)
            }
            let artworkID = item.parentRatingKey ?? itemID
            _ = try await performRequest(
                path: "/library/metadata/\(artworkID)/thumb",
                method: "POST",
                body: data,
                contentType: contentType,
                accept: "*/*"
            )
        }
    }

    private static func imageContentType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 8,
           bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if bytes.count >= 12,
           String(bytes: bytes[0...3], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8...11], encoding: .ascii) == "WEBP" {
            return "image/webp"
        }
        return "image/jpeg"
    }

    private func uploadJellyfinLyrics(
        itemID: String,
        title: String,
        lines: [LyricLine],
        content: String?
    ) async throws {
        let safeTitle = title
            .replacingOccurrences(of: "/", with: " - ")
            .replacingOccurrences(of: ":", with: " - ")
        let uploadContent = content?.trimmingCharacters(in: .newlines)
            ?? LyricsContentParser.serialize(lines)
        guard let data = uploadContent.data(using: .utf8) else {
            throw SourceError.connectionFailed("Unable to encode lyrics")
        }
        _ = try await performRequest(
            path: "/Audio/\(itemID)/Lyrics",
            method: "POST",
            queryItems: [URLQueryItem(name: "fileName", value: "\(safeTitle).lrc")],
            body: data,
            contentType: "text/plain; charset=utf-8"
        )
    }

    private func headers(requiresAuth: Bool) -> [String: String] {
        switch kind {
        case .jellyfin:
            var headers: [String: String] = [
                "Authorization": jellyfinAuthorizationHeader(includeToken: requiresAuth)
            ]
            if requiresAuth, let accessToken {
                headers["X-Emby-Token"] = accessToken
            }
            return headers
        case .emby:
            var headers: [String: String] = [
                "X-Emby-Authorization": embyAuthorizationHeader(includeToken: requiresAuth)
            ]
            if requiresAuth, let accessToken {
                headers["X-Emby-Token"] = accessToken
            }
            return headers
        case .plex:
            var headers: [String: String] = [
                "X-Plex-Client-Identifier": deviceID,
                "X-Plex-Product": "Primuse",
                "X-Plex-Version": "1.0.0",
                "X-Plex-Platform": "iOS",
                "X-Plex-Device": "iPhone",
                "X-Plex-Pms-Api-Version": plexAPIVersion ?? "1.0.0"
            ]
            if requiresAuth, let accessToken {
                headers["X-Plex-Token"] = accessToken
            }
            return headers
        }
    }

    private func jellyfinAuthorizationHeader(includeToken: Bool) -> String {
        var parts = [
            "Client=\"Primuse\"",
            "Device=\"iOS\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"1.0.0\""
        ]
        if includeToken, let accessToken {
            parts.append("Token=\"\(accessToken)\"")
        }
        return "MediaBrowser \(parts.joined(separator: ", "))"
    }

    private func embyAuthorizationHeader(includeToken: Bool) -> String {
        var parts = [
            "MediaBrowser Client=\"Primuse\"",
            "Device=\"iOS\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"1.0.0\""
        ]
        if includeToken, let accessToken {
            parts.append("Token=\"\(accessToken)\"")
        }
        return parts.joined(separator: ", ")
    }

    private func buildURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        guard queryItems.isEmpty == false,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        components.queryItems = queryItems
        return components.url ?? url
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid server response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw SourceError.authenticationFailed
            }
            throw SourceError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
    }

    private func preferredLibraries(from libraries: [Library]) -> [Library] {
        let musicLibraries = libraries.filter {
            guard let kind = $0.collectionType?.lowercased() else { return false }
            return kind == "music" || kind == "artist"
        }
        return musicLibraries.isEmpty ? libraries : musicLibraries
    }

    private func libraryPath(for libraryID: String, name: String) -> String {
        let safeName = name.replacingOccurrences(of: "/", with: " - ")
        return "/libraries/\(libraryID)/\(safeName)"
    }

    private func libraryID(from path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count >= 2, components.first == "libraries" else {
            return nil
        }
        return String(components[1])
    }

    private func itemID(from path: String) -> String? {
        let lastComponent = (path as NSString).lastPathComponent
        guard lastComponent.isEmpty == false else { return nil }
        return (lastComponent as NSString).deletingPathExtension
    }

    private func normalize(_ path: String) -> String {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") == false {
            normalized = "/" + normalized
        }
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func buildSong(
        from item: AudioItem,
        dateAddedFallback: Date
    ) -> Song {
        let fileExtension = audioFileExtension(for: item)
        let format = AudioFormat.from(fileExtension: fileExtension) ?? .mp3
        let repairedServerTitle = MediaMetadataTextRepair.repaired(item.name)
        let title = repairedServerTitle
            ?? MediaMetadataTextRepair.fileNameTitle(from: item.path)
            ?? item.name.replacingOccurrences(of: "\u{FFFD}", with: "")
        let artistCandidates = [
            item.artists?.first,
            item.albumArtist,
            item.albumArtists?.first?.name
        ]
        let artist = artistCandidates.lazy.compactMap(MediaMetadataTextRepair.repaired).first
            ?? MediaMetadataTextRepair.fileNameArtist(from: item.path)
        let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: [item.albumArtist, item.albumArtists?.first?.name]
                .lazy
                .compactMap(MediaMetadataTextRepair.repaired)
                .first,
            trackArtistName: artist
        )
        let album = MediaMetadataTextRepair.repaired(item.album)
        let genres = item.genres?
            .compactMap(MediaMetadataTextRepair.repaired)
            .filter { !$0.isEmpty }
        let year = item.productionYear ?? item.dateCreated.map { Calendar.current.component(.year, from: $0) }
        let audioStream = item.mediaStreams?.first(where: { ($0.type ?? "").caseInsensitiveCompare("Audio") == .orderedSame })
            ?? item.mediaStreams?.first
        let duration = Double(item.runTimeTicks ?? 0) / 10_000_000
        let relativePath = "/items/\(item.id).\(fileExtension)"
        let songID = hash("\(sourceID):\(relativePath)")
        let albumID = album == nil ? nil : item.albumId
        let artistID = artist == nil ? nil : item.albumArtists?.first?.id
        let fileSize = item.mediaSources?.first?.size ?? 0
        let bitRate = audioStream?.bitRate.map { Int($0 / 1000) }
        let genre = genres?.isEmpty == false ? genres?.joined(separator: ", ") : nil
        let dateAdded = item.dateCreated ?? dateAddedFallback
        let coverArtFileName = coverArtURL(for: item)?.absoluteString
        let artistArtworkFileName = artistArtworkReference(for: item, artistName: artist)

        return Song(
            id: songID,
            title: title.isEmpty ? item.id : title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: album,
            artistName: artist,
            albumArtistName: albumArtist,
            trackNumber: item.indexNumber,
            discNumber: item.parentIndexNumber,
            duration: duration,
            fileFormat: format,
            filePath: relativePath,
            sourceID: sourceID,
            fileSize: fileSize,
            bitRate: bitRate,
            sampleRate: audioStream?.sampleRate,
            bitDepth: audioStream?.bitDepth,
            genre: genre,
            year: year,
            lastModified: item.dateCreated,
            dateAdded: dateAdded,
            coverArtFileName: coverArtFileName,
            artistArtworkFileName: artistArtworkFileName
        )
    }

    private func buildSong(from item: PlexAudioItem) -> Song {
        let part = item.media?.first?.parts?.first
        let audioStream = part?.streams?.first(where: { $0.streamType == 2 }) ?? part?.streams?.first
        let fileExtension = plexAudioFileExtension(for: item)
        let format = AudioFormat.from(fileExtension: fileExtension) ?? .mp3
        let relativePath = "/items/\(item.ratingKey).\(fileExtension)"
        let title = MediaMetadataTextRepair.repaired(item.title)
            ?? MediaMetadataTextRepair.fileNameTitle(from: part?.file)
            ?? item.title
        let artist = [item.originalTitle]
            .lazy
            .compactMap(MediaMetadataTextRepair.repaired)
            .first
            ?? MediaMetadataTextRepair.fileNameArtist(from: part?.file)
            ?? MediaMetadataTextRepair.repaired(item.grandparentTitle)
        let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: MediaMetadataTextRepair.repaired(item.grandparentTitle),
            trackArtistName: artist
        )
        let album = MediaMetadataTextRepair.repaired(item.parentTitle)
        let genres = item.genres?
            .compactMap(MediaMetadataTextRepair.repaired)
            .filter { !$0.isEmpty }

        return Song(
            id: hash("\(sourceID):\(relativePath)"),
            title: title,
            albumTitle: album,
            artistName: artist,
            albumArtistName: albumArtist,
            trackNumber: item.index,
            discNumber: item.parentIndex,
            duration: Double(item.duration ?? 0) / 1000,
            fileFormat: format,
            filePath: relativePath,
            sourceID: sourceID,
            fileSize: Int64(part?.size ?? 0),
            bitRate: item.media?.first?.bitrate,
            sampleRate: audioStream?.samplingRate,
            genre: genres?.isEmpty == false ? genres?.joined(separator: ", ") : nil,
            year: item.year,
            coverArtFileName: coverArtURL(for: item)?.absoluteString,
            artistArtworkFileName: artistArtworkReference(for: item, artistName: artist)
        )
    }

    /// Jellyfin/Emby expose stable artist item IDs alongside every audio row.
    /// Persist a credential-free image URL; `imageURL(for:)` later rebases it
    /// onto the active LAN/public route and adds the current token.
    private func artistArtworkReference(for item: AudioItem, artistName: String?) -> String? {
        let candidates = (item.artistItems ?? []) + (item.albumArtists ?? [])
        let match = candidates.first { candidate in
            guard let artistName else { return false }
            return candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(artistName.trimmingCharacters(in: .whitespacesAndNewlines))
                == .orderedSame
        } ?? candidates.first
        guard let artistID = match?.id, !artistID.isEmpty else { return nil }
        return buildURL(
            path: "/Items/\(artistID)/Images/Primary",
            queryItems: [
                URLQueryItem(name: "maxWidth", value: "480"),
                URLQueryItem(name: "format", value: "png"),
            ]
        ).absoluteString
    }

    /// Plex track rows carry the artist's own `grandparentThumb`. Only attach
    /// it when the visible track artist is that grandparent, avoiding an album
    /// artist portrait on compilation tracks credited to somebody else.
    private func artistArtworkReference(for item: PlexAudioItem, artistName: String?) -> String? {
        guard let artistName,
              let grandparentTitle = item.grandparentTitle,
              artistName.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(grandparentTitle.trimmingCharacters(in: .whitespacesAndNewlines))
                == .orderedSame,
              let thumb = item.grandparentThumb,
              !thumb.isEmpty else { return nil }
        return buildURL(path: thumb).absoluteString
    }

    private func coverArtURL(for item: AudioItem) -> URL? {
        guard let accessToken else { return nil }

        if let albumID = item.albumId, let albumPrimaryImageTag = item.albumPrimaryImageTag {
            return buildURL(
                path: "/Items/\(albumID)/Images/Primary",
                queryItems: [
                    URLQueryItem(name: "maxWidth", value: "480"),
                    URLQueryItem(name: "format", value: "png"),
                    URLQueryItem(name: "tag", value: albumPrimaryImageTag),
                    URLQueryItem(name: "api_key", value: accessToken)
                ]
            )
        }

        if item.imageTags?["Primary"] != nil {
            return buildURL(
                path: "/Items/\(item.id)/Images/Primary",
                queryItems: [
                    URLQueryItem(name: "maxWidth", value: "480"),
                    URLQueryItem(name: "format", value: "png"),
                    URLQueryItem(name: "api_key", value: accessToken)
                ]
            )
        }

        return nil
    }

    /// Persist only a route-rewritable, credential-free URL. `imageURL(for:)`
    /// adds the current token after choosing the active LAN/public endpoint.
    private func playlistCoverArtReference(for item: AudioItem) -> String? {
        guard let tag = item.imageTags?["Primary"] else { return nil }
        return buildURL(
            path: "/Items/\(item.id)/Images/Primary",
            queryItems: [
                URLQueryItem(name: "maxWidth", value: "480"),
                URLQueryItem(name: "format", value: "png"),
                URLQueryItem(name: "tag", value: tag),
            ]
        ).absoluteString
    }

    private func playlistCoverArtReference(for item: PlexPlaylistSummary) -> String? {
        guard let thumb = item.thumb, !thumb.isEmpty else { return nil }
        return buildURL(path: thumb).absoluteString
    }

    private func coverArtURL(for item: PlexAudioItem) -> URL? {
        guard let thumb = item.thumb, let accessToken else { return nil }
        return buildURL(
            path: thumb,
            queryItems: [URLQueryItem(name: "X-Plex-Token", value: accessToken)]
        )
    }

    private func audioFileExtension(for item: AudioItem) -> String {
        if let path = item.mediaSources?.first?.path ?? item.path {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            if ext.isEmpty == false {
                return ext
            }
        }

        if let container = item.mediaSources?.first?.container,
           let firstContainer = container.split(separator: ",").first {
            let ext = String(firstContainer).lowercased()
            if ext.isEmpty == false {
                return ext
            }
        }

        return "mp3"
    }

    private func plexAudioFileExtension(for item: PlexAudioItem) -> String {
        if let file = item.media?.first?.parts?.first?.file {
            let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
            if ext.isEmpty == false {
                return ext
            }
        }

        if let container = item.media?.first?.container?.lowercased(), container.isEmpty == false {
            return container
        }

        return "mp3"
    }

    private func fetchPlexServerInfo() async throws -> PlexServerInfoPayload {
        let data = try await performRequest(path: "/")
        let response = try decoder.decode(PlexServerInfoResponse.self, from: data)
        return response.mediaContainer
    }

    private func fetchPlexTracks(
        sectionID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> PlexTrackResponse {
        let data = try await performRequest(
            path: "/library/sections/\(sectionID)/all",
            queryItems: [
                URLQueryItem(name: "type", value: "10"),
                URLQueryItem(name: "sort", value: "titleSort:asc"),
                URLQueryItem(name: "X-Plex-Container-Start", value: String(startIndex)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(limit))
            ]
        )
        return try decoder.decode(PlexTrackResponse.self, from: data)
    }

    private func fetchPlexTrack(ratingKey: String) async throws -> PlexAudioItem {
        let data = try await performRequest(path: "/library/metadata/\(ratingKey)")
        let response = try decoder.decode(PlexTrackResponse.self, from: data)
        guard let item = response.mediaContainer.metadata.first else {
            throw SourceError.fileNotFound(ratingKey)
        }
        plexItems[ratingKey] = item
        return item
    }

    private func plexPlaybackURL(for ratingKey: String) async throws -> URL {
        guard let accessToken else {
            throw SourceError.authenticationFailed
        }

        let item: PlexAudioItem
        if let cachedItem = plexItems[ratingKey] {
            item = cachedItem
        } else {
            item = try await fetchPlexTrack(ratingKey: ratingKey)
        }
        guard let partKey = item.media?.first?.parts?.first?.key else {
            throw SourceError.fileNotFound(ratingKey)
        }

        return buildURL(
            path: partKey,
            queryItems: [URLQueryItem(name: "X-Plex-Token", value: accessToken)]
        )
    }

    private func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.parseDate(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
        return decoder
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func catalogPageSignature(_ ids: [String]) -> String {
        SHA256.hash(data: Data(ids.joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func makeBaseURL(
        host: String,
        port: Int?,
        useSsl: Bool,
        basePath: String?
    ) -> URL {
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = useSsl ? "https" : "http"
        var url = NetworkURLBuilder.baseURL(host: rawHost, scheme: scheme, port: port)
            ?? URL(string: "\(scheme)://localhost")!

        let normalizedBasePath = (basePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBasePath.isEmpty == false {
            for pathComponent in normalizedBasePath.split(separator: "/") {
                url.appendPathComponent(String(pathComponent))
            }
        }

        return url
    }
}

extension MediaServerSource.Kind {
    init?(sourceType: MusicSourceType) {
        switch sourceType {
        case .jellyfin:
            self = .jellyfin
        case .emby:
            self = .emby
        case .plex:
            self = .plex
        default:
            return nil
        }
    }
}

private struct LoginResponse: Decodable {
    let accessToken: String
    let user: User

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

private struct User: Decodable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

private struct LibraryResponse: Decodable {
    let items: [Library]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

private struct Library: Decodable {
    let id: String
    let name: String
    let collectionType: String?
    let childCount: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case childCount = "ChildCount"
    }
}

private struct ItemResponse: Decodable {
    let items: [AudioItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

}

private struct AudioItem: Decodable {
    let id: String
    let name: String
    let album: String?
    let albumArtist: String?
    let albumArtists: [NameIDPair]?
    let artistItems: [NameIDPair]?
    let artists: [String]?
    let albumId: String?
    let albumPrimaryImageTag: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let productionYear: Int?
    let dateCreated: Date?
    let runTimeTicks: Int?
    let genres: [String]?
    let mediaStreams: [AudioStream]?
    let mediaSources: [AudioMediaSource]?
    let imageTags: [String: String]?
    let path: String?
    let channelType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case album = "Album"
        case albumArtist = "AlbumArtist"
        case albumArtists = "AlbumArtists"
        case artistItems = "ArtistItems"
        case artists = "Artists"
        case albumId = "AlbumId"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case productionYear = "ProductionYear"
        case dateCreated = "DateCreated"
        case runTimeTicks = "RunTimeTicks"
        case genres = "Genres"
        case mediaStreams = "MediaStreams"
        case mediaSources = "MediaSources"
        case imageTags = "ImageTags"
        case path = "Path"
        case channelType = "ChannelType"
    }

    var embyLyricsStream: EmbyLyricsStreamDescriptor? {
        for source in mediaSources ?? [] {
            guard let mediaSourceID = source.id, !mediaSourceID.isEmpty else { continue }
            let streams = source.mediaStreams ?? mediaStreams ?? []
            if let stream = Self.lyricsStream(
                in: streams,
                preferredIndex: source.defaultSubtitleStreamIndex
            ), let streamIndex = stream.index {
                return EmbyLyricsStreamDescriptor(
                    mediaSourceID: mediaSourceID,
                    streamIndex: streamIndex
                )
            }
        }
        return nil
    }

    private static func lyricsStream(
        in streams: [AudioStream],
        preferredIndex: Int?
    ) -> AudioStream? {
        let candidates = streams.filter { stream in
            guard stream.type?.caseInsensitiveCompare("Subtitle") == .orderedSame,
                  stream.index != nil,
                  stream.isTextSubtitleStream != false else {
                return false
            }
            guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { return true }
            return codec == "text" || codec == "lrc" || codec == "srt" || codec == "subrip"
        }
        if let preferredIndex,
           let preferred = candidates.first(where: { $0.index == preferredIndex }) {
            return preferred
        }
        return candidates.first
    }
}

private struct EmbyLyricsStreamDescriptor: Sendable {
    let mediaSourceID: String
    let streamIndex: Int
}

/// Jellyfin serializes AlbumArtists as NameGuidPair objects, not strings.
/// Decoding it as `[String]` caused the entire paged Items response to fail as
/// soon as a track contained normal album-artist metadata.
private struct NameIDPair: Decodable {
    let name: String
    let id: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            name = value
            id = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        id = try container.decodeIfPresent(String.self, forKey: .id)
    }
}

private struct AudioStream: Decodable {
    let type: String?
    let index: Int?
    let codec: String?
    let isTextSubtitleStream: Bool?
    let bitRate: Int?
    let sampleRate: Int?
    let bitDepth: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case index = "Index"
        case codec = "Codec"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case bitRate = "BitRate"
        case sampleRate = "SampleRate"
        case bitDepth = "BitDepth"
    }
}

private struct AudioMediaSource: Decodable {
    let id: String?
    let size: Int64?
    let container: String?
    let path: String?
    let defaultSubtitleStreamIndex: Int?
    let mediaStreams: [AudioStream]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case size = "Size"
        case container = "Container"
        case path = "Path"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
        case mediaStreams = "MediaStreams"
    }
}

private struct JellyfinLyricResponse: Decodable {
    let metadata: JellyfinLyricMetadata?
    let lyrics: [JellyfinLyricLine]?

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
        case lyrics = "Lyrics"
    }

    var editableContent: String? {
        let lyricLines = (lyrics ?? []).compactMap(\.editableLine)
        guard !lyricLines.isEmpty else { return nil }
        var output = metadata?.lrcHeaders ?? []
        if !output.isEmpty { output.append("") }
        output.append(contentsOf: lyricLines)
        return output.joined(separator: "\n")
    }
}

private struct JellyfinLyricMetadata: Decodable {
    let artist: String?
    let album: String?
    let title: String?
    let author: String?
    let by: String?
    let creator: String?
    let length: Int64?
    let offset: Int64?

    enum CodingKeys: String, CodingKey {
        case artist = "Artist"
        case album = "Album"
        case title = "Title"
        case author = "Author"
        case by = "By"
        case creator = "Creator"
        case length = "Length"
        case offset = "Offset"
    }

    var lrcHeaders: [String] {
        var values: [String] = []
        if let artist, !artist.isEmpty { values.append("[ar:\(artist)]") }
        if let album, !album.isEmpty { values.append("[al:\(album)]") }
        if let title, !title.isEmpty { values.append("[ti:\(title)]") }
        if let author, !author.isEmpty { values.append("[author:\(author)]") }
        if let by, !by.isEmpty { values.append("[by:\(by)]") }
        if let creator, !creator.isEmpty { values.append("[re:\(creator)]") }
        if let length, length > 0 {
            values.append("[length:\(Self.formatTimestamp(Double(length) / 10_000_000))]")
        }
        if let offset, offset != 0 {
            values.append("[offset:\(offset / 10_000)]")
        }
        return values
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = max(0, (seconds * 1_000).rounded()).finiteInt()
        return String(
            format: "%02d:%02d.%03d",
            milliseconds / 60_000,
            (milliseconds % 60_000) / 1_000,
            milliseconds % 1_000
        )
    }
}

private struct JellyfinLyricLine: Decodable {
    let text: String?
    let start: Int64?
    let cues: [JellyfinLyricCue]?

    enum CodingKeys: String, CodingKey {
        case text = "Text"
        case start = "Start"
        case cues = "Cues"
    }

    var editableLine: String? {
        guard let text, !text.isEmpty else { return nil }
        let orderedCues = (cues ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        if !orderedCues.isEmpty {
            let characters = Array(text)
            var body = ""
            for (index, cue) in orderedCues.enumerated() {
                guard let cueStart = cue.start else { continue }
                let startIndex = min(max(0, cue.position ?? 0), characters.count)
                let fallbackEnd = index + 1 < orderedCues.count
                    ? orderedCues[index + 1].position ?? characters.count
                    : characters.count
                let endIndex = min(max(startIndex, cue.endPosition ?? fallbackEnd), characters.count)
                guard startIndex < endIndex else { continue }
                body += "<\(Self.formatTicks(cueStart))>"
                body += String(characters[startIndex..<endIndex])
            }
            if let end = orderedCues.last?.end {
                body += "<\(Self.formatTicks(end))>"
            }
            guard !body.isEmpty else { return nil }
            let lineStart = start ?? orderedCues.first?.start ?? 0
            return "[\(Self.formatTicks(lineStart))]" + body
        }
        guard let start else { return text }
        return "[\(Self.formatTicks(start))]" + text
    }

    private static func formatTicks(_ ticks: Int64) -> String {
        let milliseconds = max(0, (Double(ticks) / 10_000).rounded()).finiteInt()
        return String(
            format: "%02d:%02d.%03d",
            milliseconds / 60_000,
            (milliseconds % 60_000) / 1_000,
            milliseconds % 1_000
        )
    }
}

private struct JellyfinLyricCue: Decodable {
    let position: Int?
    let endPosition: Int?
    let start: Int64?
    let end: Int64?

    enum CodingKeys: String, CodingKey {
        case position = "Position"
        case endPosition = "EndPosition"
        case start = "Start"
        case end = "End"
    }
}

private struct PlexServerInfoResponse: Decodable {
    let mediaContainer: PlexServerInfoPayload

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

private struct PlexServerInfoPayload: Decodable {
    let friendlyName: String?
    let machineIdentifier: String?
    let version: String?
    let apiVersion: String?
    let myPlexSigninState: String?
}

private struct PlexLibraryResponse: Decodable {
    let mediaContainer: PlexLibraryContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

private struct PlexLibraryContainer: Decodable {
    let directories: [PlexLibraryDirectory]

    enum CodingKeys: String, CodingKey {
        case directories = "Directory"
    }
}

private struct PlexLibraryDirectory: Decodable {
    let key: String
    let title: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case key
        case title
        case type
    }
}

private struct PlexTrackResponse: Decodable {
    let mediaContainer: PlexTrackContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }

    var items: [PlexAudioItem] { mediaContainer.metadata }
    var totalCount: Int? { mediaContainer.totalSize }
}

private struct PlexTrackContainer: Decodable {
    let metadata: [PlexAudioItem]
    let totalSize: Int?

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
        case totalSize
    }
}

private struct PlexAudioItem: Decodable {
    let ratingKey: String
    let title: String
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let originalTitle: String?
    let index: Int?
    let parentIndex: Int?
    let year: Int?
    let duration: Int?
    let thumb: String?
    let grandparentThumb: String?
    let genres: [String]?
    let media: [PlexMedia]?

    enum CodingKeys: String, CodingKey {
        case ratingKey
        case title
        case parentRatingKey
        case grandparentRatingKey
        case parentTitle
        case grandparentTitle
        case originalTitle
        case index
        case parentIndex
        case year
        case duration
        case thumb
        case grandparentThumb
        case media = "Media"
        case genre = "Genre"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        title = try container.decode(String.self, forKey: .title)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        grandparentThumb = try container.decodeIfPresent(String.self, forKey: .grandparentThumb)
        media = try container.decodeIfPresent([PlexMedia].self, forKey: .media)
        genres = try container.decodeIfPresent([PlexGenre].self, forKey: .genre)?.map(\.tag)
    }
}

private struct PlexGenre: Decodable {
    let tag: String
}

private struct PlexMedia: Decodable {
    let bitrate: Int?
    let container: String?
    let parts: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case bitrate
        case container
        case parts = "Part"
    }
}

private struct PlexPart: Decodable {
    let key: String?
    let file: String?
    let size: Int?
    let streams: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case key
        case file
        case size
        case streams = "Stream"
    }
}

private struct PlexStream: Decodable {
    // 可选: 个别 Stream(歌词/封面流)或老版 Plex 可能缺该字段, 非可选会让
    // 整页 PlexTrackResponse 解码失败 → 该源永远扫不出歌。streamType == 2 是音频。
    let streamType: Int?
    let samplingRate: Int?

    enum CodingKeys: String, CodingKey {
        case streamType
        case samplingRate
    }
}

private struct PlexPlaylistResponse: Decodable {
    let mediaContainer: PlexPlaylistContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

private struct PlexPlaylistContainer: Decodable {
    let playlists: [PlexPlaylistSummary]
    let totalSize: Int?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case playlists = "Metadata"
        case totalSize
        case size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSize = try container.decodeIfPresent(Int.self, forKey: .totalSize)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        if let decoded = try container.decodeIfPresent([PlexPlaylistSummary].self, forKey: .playlists) {
            playlists = decoded
        } else if size == 0 || totalSize == 0 {
            playlists = []
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.playlists,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing Plex playlist Metadata")
            )
        }
    }
}

private struct PlexPlaylistSummary: Decodable {
    let ratingKey: String
    let title: String
    let playlistType: String
    let leafCount: Int?
    let thumb: String?

    enum CodingKeys: String, CodingKey {
        case ratingKey
        case title
        case playlistType
        case leafCount
        case thumb
    }
}

private struct PlexPlaylistItemsResponse: Decodable {
    let mediaContainer: PlexPlaylistItemsContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

private struct PlexPlaylistItemsContainer: Decodable {
    let tracks: [PlexPlaylistTrack]
    let totalSize: Int?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case tracks = "Metadata"
        case totalSize
        case size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSize = try container.decodeIfPresent(Int.self, forKey: .totalSize)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        if let decoded = try container.decodeIfPresent([PlexPlaylistTrack].self, forKey: .tracks) {
            tracks = decoded
        } else if size == 0 || totalSize == 0 {
            tracks = []
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.tracks,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing Plex playlist item Metadata")
            )
        }
    }
}

private struct PlexPlaylistTrack: Decodable {
    let ratingKey: String

    enum CodingKeys: String, CodingKey {
        case ratingKey
    }
}
