import Foundation
import PrimuseKit

/// Ting Reader(自托管有声书服务器)的只读整库 connector。
///
/// 服务器里只有有声内容:源类型本身就把全部内容归到有声(`MusicSourceType.declaredListeningContentKind`)。
/// 一章是服务器上的一个音频文件,在这里是一首歌;归书规则按「专辑 = 书名、专辑艺术家 = 作者」合回一本。
/// 进度服务端按章记,和本机按条目记一一对应,不用换算时间轴。
actor TingReaderSource: RefreshingMetadataSongConnector, ServerLibraryListingConnector {
    let sourceID: String

    private let client: TingReaderServiceClient
    private let apiSession: URLSession
    private let mediaSession: URLSession
    private let audioCacheDirectory: URL
    private let excludedLibraryIDs: Set<String>
    private var connected = false
    private var observedLibraries: [ServerLibraryDescriptor]?
    /// 扫描时顺带拿到的每章位置。扫描收尾马上要整源对一遍进度,这段时间内直接用,
    /// 不再逐本重取;过期的按需重取。
    private var chapterSnapshots: [String: (fetchedAt: Date, chapters: [TingReaderChapter])] = [:]
    private static let chapterSnapshotLifetime: TimeInterval = 120

    init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        username: String,
        password: String,
        alternateTLSValidationHostname: String? = nil,
        excludedLibraryIDs: Set<String> = []
    ) {
        self.sourceID = sourceID
        self.excludedLibraryIDs = excludedLibraryIDs
        let endpoint = NetworkEndpointIdentity(
            scheme: useSSL ? "https" : "http",
            host: host,
            port: port
        )
        let apiSession = Self.makeSession(
            delegate: SmartSSLDelegate(
                redirectPolicy: .sameEndpoint,
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: endpoint
            )
        )
        // `.strm` 章节的音频接口会 302 到外部地址;跟过去时去掉本源的 token。
        let mediaSession = Self.makeSession(
            delegate: SmartSSLDelegate(
                redirectPolicy: .media,
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: endpoint
            )
        )
        self.apiSession = apiSession
        self.mediaSession = mediaSession
        let pick: @Sendable (URLRequest) -> URLSession = { request in
            (request.url?.path.contains("/api/stream/") ?? false) ? mediaSession : apiSession
        }
        self.client = TingReaderServiceClient(
            sourceID: sourceID,
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath,
            username: username,
            password: password,
            transport: TingReaderRequestTransport(
                data: { try await TrustedHTTPTransport.data(for: $0, session: pick($0)) },
                download: { try await TrustedHTTPTransport.download(for: $0, session: pick($0)) }
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

    deinit {
        apiSession.invalidateAndCancel()
        mediaSession.invalidateAndCancel()
    }

    private static func makeSession(delegate: SmartSSLDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func connect() async throws {
        if connected { return }
        do {
            _ = try await client.validateConnection()
            connected = true
            await MainActor.run { SourceAuthAlert.clear(sourceID: sourceID) }
        } catch {
            let message: String
            if let serviceError = error as? TingReaderServiceError,
               serviceError == .authenticationFailed || serviceError == .missingCredential {
                message = PMString("error.tingReader.authenticationFailed")
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
        chapterSnapshots.removeAll()
        await client.invalidateSession()
    }

    // MARK: - Libraries

    private func scannedLibraries() async throws -> [TingReaderLibrary] {
        try await client.libraries().filter { !excludedLibraryIDs.contains($0.id) }
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
        return try await client.libraries().map(\.descriptor)
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
        let librariesByID = Dictionary(libraries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 服务端只按账号过滤,不分存储库给;书目一次取全再按存储库筛。
        let books = try await client.books().filter { librariesByID[$0.libraryID] != nil }
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await self.walkBooks(books, libraries: librariesByID, continuation: continuation)
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

    private func walkBooks(
        _ books: [TingReaderBook],
        libraries: [String: TingReaderLibrary],
        continuation: AsyncThrowingStream<ConnectorScannedSong, Error>.Continuation
    ) async throws {
        var walked = 0
        defer { plog("📚 tingreader: walked \(walked) of \(books.count) book(s)") }
        try await TingReaderCatalogWalk.forEachBook(books, client: client) { catalogBook in
            try Task.checkCancellation()
            walked += 1
            chapterSnapshots[catalogBook.book.id] = (Date(), catalogBook.chapters)
            guard let library = libraries[catalogBook.book.libraryID] else { return }
            let location = libraryFolderLocation(for: catalogBook.book, library: library)
            for song in catalogBook.makeSongs(sourceID: sourceID) {
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
    }

    private func libraryFolderLocation(
        for book: TingReaderBook,
        library: TingReaderLibrary
    ) -> ConnectorLibraryFolderLocation {
        var fallback: [ConnectorLibraryFolderComponent] = []
        if let author = book.author {
            fallback.append(
                ConnectorLibraryFolderComponent(
                    stableID: "author:\(ConnectorLibraryFolderHierarchy.stableNameIdentity(author))",
                    displayName: author
                )
            )
        }
        fallback.append(ConnectorLibraryFolderComponent(stableID: "book:\(book.id)", displayName: book.title))
        return ConnectorLibraryFolderHierarchy.location(
            rootStableID: "tingreader:library:\(library.id)",
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

    // MARK: - Media

    func streamingURL(for path: String) async throws -> URL? {
        // 音频接口要 Authorization 头,iOS/macOS 走 Range/localURL 通道。
        nil
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await connect()
        do {
            return try await client.fetchRange(trackPath: path, offset: offset, length: length)
        } catch TingReaderServiceError.rangeNotSupported {
            // RSS 源站不给总长时服务端只能回整份;先整章下载到缓存,再从文件里切。
            let local = try await localURL(for: path)
            return try Self.read(from: local, offset: offset, length: length)
        }
    }

    private static func read(from url: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        let start = offset < 0 ? max(0, size - length) : offset
        guard start < size, length > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(start))
        return try handle.read(upToCount: Int(min(length, size - start))) ?? Data()
    }

    func localURL(for path: String) async throws -> URL {
        guard TingReaderAPIProtocol.trackReference(from: path) != nil else {
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
        guard TingReaderAPIProtocol.coverReference(from: reference) != nil else { return nil }
        try await connect()
        return try await client.coverData(reference: reference, maximumBytes: maximumBytes)
    }
}

extension TingReaderSource: ServerCatalogChangeDetectingConnector {
    /// 服务器的书数、章节数与总时长拼成的指纹。能看见增删章节和换了文件;改了书名的要等下次扫描。
    /// 不报扫描时间:服务端定时重扫会推进它,内容没变也会触发重扫。也不报条目数:统计不分账号,
    /// 和这个账号能看到的歌曲数对不上。
    func fetchServerCatalogScanStatus(changedSince: Date?) async throws -> ServerCatalogScanStatus {
        let stats = try await client.catalogStats()
        return ServerCatalogScanStatus(
            isScanning: false,
            itemCount: nil,
            lastCompletedScanAt: nil,
            contentRevision: stats.contentRevision
        )
    }
}

extension TingReaderSource: ServerListeningProgressConnector {
    func fetchServerListeningProgress(for songPaths: [String]) async throws -> [ServerListeningProgress] {
        var wantedByBook: [String: Set<String>] = [:]
        for path in songPaths {
            guard let reference = TingReaderAPIProtocol.trackReference(from: path) else { continue }
            wantedByBook[reference.bookID, default: []].insert(path)
        }
        guard !wantedByBook.isEmpty else { return [] }
        try await connect()
        let now = Date()
        chapterSnapshots = chapterSnapshots.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.chapterSnapshotLifetime }
        var result: [ServerListeningProgress] = []
        for (bookID, wanted) in wantedByBook {
            try Task.checkCancellation()
            let chapters: [TingReaderChapter]
            if let snapshot = chapterSnapshots[bookID] {
                chapters = snapshot.chapters
            } else {
                do {
                    chapters = try await client.chapters(bookID: bookID)
                } catch TingReaderServiceError.badServerResponse(404) {
                    continue
                }
            }
            for chapter in chapters {
                guard let progress = TingReaderProgressPolicy.progress(for: chapter) else { continue }
                let path = TingReaderAPIProtocol.trackPath(
                    bookID: bookID,
                    chapterID: chapter.id,
                    fileExtension: chapter.fileExtension
                )
                guard wanted.contains(path) else { continue }
                result.append(ServerListeningProgress(
                    songPath: path,
                    position: progress.position,
                    duration: progress.duration,
                    isFinished: progress.isFinished,
                    updatedAt: progress.updatedAt
                ))
            }
        }
        return result
    }

    func reportListeningProgress(songPath: String, position: TimeInterval, duration: TimeInterval, isFinished: Bool) async throws {
        guard let reference = TingReaderAPIProtocol.trackReference(from: songPath) else { return }
        try await connect()
        // 刚报过的位置比扫描时的快照新;作废这本的快照,下次读进度时重取。
        chapterSnapshots.removeValue(forKey: reference.bookID)
        try await client.updateProgress(
            bookID: reference.bookID,
            chapterID: reference.chapterID,
            position: TingReaderProgressPolicy.reportedPosition(
                position: position,
                duration: duration,
                isFinished: isFinished
            ),
            duration: duration
        )
    }
}
