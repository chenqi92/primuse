import Foundation
import PrimuseKit

/// Audiobookshelf(有声书 / 播客服务器)的只读整库 connector。
///
/// 服务器里只有书库和播客库,没有音乐:源类型本身就把全部内容归到有声
/// (`MusicSourceType.declaredListeningContentKind`),不靠流派或目录标签。
/// 书的每个音频文件、播客的每一集各是一首歌,归书规则按「专辑 = 书名、专辑艺术家 = 作者」合回一本。
actor AudiobookshelfSource: RefreshingMetadataSongConnector, ServerLibraryListingConnector {
    let sourceID: String

    private let client: AudiobookshelfServiceClient
    private let session: URLSession
    private let serverBaseURL: URL?
    private let audioCacheDirectory: URL
    private let excludedLibraryIDs: Set<String>
    private var connected = false
    /// Set by `scanSongs` when the catalogue moved while it was being paged.
    private var catalogDriftInLastWalk = false
    private var observedLibraries: [ServerLibraryDescriptor]?
    /// 扫描时记下的条目(文件布局、章节),章节与进度换算要用;没有的播放时再取一次。
    private var itemCache: [String: AudiobookshelfCatalogItem] = [:]

    init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        username: String,
        secret: String,
        authType: SourceAuthType,
        alternateTLSValidationHostname: String? = nil,
        excludedLibraryIDs: Set<String> = []
    ) {
        self.sourceID = sourceID
        self.excludedLibraryIDs = excludedLibraryIDs
        self.serverBaseURL = AudiobookshelfAPIProtocol.serverBaseURL(
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: SmartSSLDelegate(
                redirectPolicy: .sameEndpoint,
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: NetworkEndpointIdentity(
                    scheme: useSSL ? "https" : "http",
                    host: host,
                    port: port
                )
            ),
            delegateQueue: nil
        )
        self.session = session
        self.client = AudiobookshelfServiceClient(
            sourceID: sourceID,
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath,
            username: username,
            secret: secret,
            authType: authType,
            transport: AudiobookshelfRequestTransport(
                data: { try await TrustedHTTPTransport.data(for: $0, session: session) },
                download: { try await TrustedHTTPTransport.download(for: $0, session: session) }
            )
        )
        let root = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        self.audioCacheDirectory = root
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: audioCacheDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit { session.invalidateAndCancel() }

    func connect() async throws {
        if connected { return }
        do {
            _ = try await client.validateConnection()
            connected = true
            await MainActor.run { SourceAuthAlert.clear(sourceID: sourceID) }
        } catch {
            let message: String
            if let serviceError = error as? AudiobookshelfServiceError,
               serviceError == .authenticationFailed || serviceError == .missingCredential {
                message = PMString("error.audiobookshelf.authenticationFailed")
            } else {
                message = error.localizedDescription
            }
            await MainActor.run {
                SourceAuthAlert.report(sourceID: sourceID, message: message)
            }
            throw error
        }
    }

    func disconnect() async {
        connected = false
        await client.invalidateSession()
    }

    // MARK: - Libraries

    private func scannedLibraries() async throws -> [AudiobookshelfLibrary] {
        try await client.libraries().filter {
            $0.mediaType != .other && !excludedLibraryIDs.contains($0.id)
        }
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        guard path == "/" || path.isEmpty else { return [] }
        return try await scannedLibraries().map { library in
            RemoteFileItem(
                name: library.name,
                path: "/libraries/\(library.id)/\(library.name.replacingOccurrences(of: "/", with: " - "))",
                isDirectory: true,
                size: 0,
                modifiedDate: nil
            )
        }
    }

    func fetchServerLibraries() async throws -> [ServerLibraryDescriptor] {
        try await connect()
        return try await client.libraries()
            .filter { $0.mediaType != .other }
            .map(\.descriptor)
    }

    func takeObservedServerLibraries() async -> [ServerLibraryDescriptor]? {
        defer { observedLibraries = nil }
        return observedLibraries
    }

    // MARK: - Catalogue

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        let libraries = try await scannedLibraries()
        observedLibraries = libraries.map(\.descriptor)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for library in libraries {
                        try await self.walkLibrary(library, continuation: continuation)
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

    private func walkLibrary(
        _ library: AudiobookshelfLibrary,
        continuation: AsyncThrowingStream<ConnectorScannedSong, Error>.Continuation
    ) async throws {
        let pageSize = AudiobookshelfServiceClient.pageSize
        var page = 0
        // The server keeps scanning while the walk pages; see `CatalogWalkDriftTracker`.
        var walk = CatalogWalkDriftTracker()
        defer {
            if walk.driftObserved {
                catalogDriftInLastWalk = true
                plog("↻ audiobookshelf library \(library.id): catalogue moved during the walk")
            }
            plog("📚 audiobookshelf library \(library.id): walked \(walk.admittedCount) item(s), server reported \(walk.reportedTotal.map(String.init) ?? "no total")")
        }
        while true {
            try Task.checkCancellation()
            let result = try await client.libraryItemsPage(libraryID: library.id, page: page, limit: pageSize)
            walk.observeTotal(result.total)
            guard result.rawCount <= pageSize else {
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.invalidPageCount"))
            }
            if result.rawCount == 0 {
                _ = walk.isFinished(offset: page * pageSize, rawCount: 0, pageSize: pageSize)
                break
            }
            for item in result.items {
                try Task.checkCancellation()
                guard walk.admit(item.id) else { continue }
                itemCache[item.id] = item
                let location = libraryFolderLocation(for: item, library: library)
                for song in item.makeSongs(sourceID: sourceID) {
                    let suffix = (song.filePath as NSString).pathExtension
                    continuation.yield(
                        ConnectorScannedSong(
                            song: song,
                            displayName: suffix.isEmpty ? song.title : "\(song.title).\(suffix)",
                            titleMetadataInspected: true,
                            folderLocation: location
                        )
                    )
                }
            }
            let offset = (page + 1) * pageSize
            guard SubsonicCatalogPagingPolicy.isWithinSongLimit(offset) else {
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.pageOverflow"))
            }
            if walk.isFinished(offset: offset, rawCount: result.rawCount, pageSize: pageSize) { break }
            page += 1
        }
    }

    private func libraryFolderLocation(
        for item: AudiobookshelfCatalogItem,
        library: AudiobookshelfLibrary
    ) -> ConnectorLibraryFolderLocation {
        var fallback: [ConnectorLibraryFolderComponent] = []
        if item.mediaType == .book, let author = item.authors.first {
            let identity = item.authorIDs.first ?? ConnectorLibraryFolderHierarchy.stableNameIdentity(author)
            fallback.append(
                ConnectorLibraryFolderComponent(
                    stableID: "author:\(identity)",
                    displayName: item.authors.joined(separator: ", ")
                )
            )
        }
        fallback.append(
            ConnectorLibraryFolderComponent(stableID: "item:\(item.id)", displayName: item.title)
        )
        return ConnectorLibraryFolderHierarchy.location(
            rootStableID: "audiobookshelf:library:\(library.id)",
            rootDisplayName: library.name,
            providerFilePath: nil,
            fallbackComponents: fallback
        )
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

    /// 扫描时见过的条目,播放时没有就再取一次(章节与进度换算要文件布局)。
    func catalogItem(id: String) async throws -> AudiobookshelfCatalogItem? {
        if let cached = itemCache[id] { return cached }
        try await connect()
        let item = try await client.item(id: id)
        if let item { itemCache[id] = item }
        return item
    }

    // MARK: - Media

    func streamingURL(for path: String) async throws -> URL? {
        // 原始文件要 Authorization 头,iOS/macOS 走 Range/localURL 通道。
        nil
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await connect()
        return try await client.fetchRange(trackPath: path, offset: offset, length: length)
    }

    func localURL(for path: String) async throws -> URL {
        guard AudiobookshelfAPIProtocol.trackReference(from: path) != nil else {
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
        let temporaryURL = try await client.downloadTrack(trackPath: path)
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

    func imageURL(for path: String) async throws -> URL? { nil }

    func fetchArtworkData(for reference: String, maximumBytes: Int, purpose: ArtworkFetchPurpose) async throws -> Data? {
        try await connect()
        return try await client.coverData(reference: reference, maximumBytes: maximumBytes)
    }
}

extension AudiobookshelfSource: ServerCatalogChangeDetectingConnector {
    /// 各库条目数之和。能看见书增减;改了标签的要等下次扫描。
    func fetchServerCatalogScanStatus(changedSince: Date?) async throws -> ServerCatalogScanStatus {
        try await connect()
        let libraries = try await scannedLibraries()
        let total = try await client.catalogItemCount(libraryIDs: libraries.map(\.id))
        return ServerCatalogScanStatus(
            isScanning: false,
            itemCount: Int64(total),
            lastCompletedScanAt: nil
        )
    }
}

extension AudiobookshelfSource: CatalogDriftReportingConnector {
    func takeCatalogDriftObservation() -> Bool {
        defer { catalogDriftInLastWalk = false }
        return catalogDriftInLastWalk
    }
}
