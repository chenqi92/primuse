import CryptoKit
import Foundation

public enum TingReaderServiceError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential
    case invalidURL
    case authenticationFailed
    /// Range 请求被回了整份文件(200)。RSS 源站不给总长时服务端会这样回。
    case rangeNotSupported
    case badServerResponse(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return PMString("error.tingReader.missingCredential")
        case .invalidURL:
            return PMString("error.tingReader.invalidURL")
        case .authenticationFailed:
            return PMString("error.tingReader.authenticationFailed")
        case .rangeNotSupported:
            return PMString("error.catalog.invalidRangeResponse")
        case .badServerResponse(let status):
            return PMString("error.tingReader.http", String(status))
        case .invalidResponse(let detail):
            return PMString("error.tingReader.invalidResponse", detail)
        }
    }
}

// MARK: - Models

/// 服务端的一个存储库:本地目录、WebDAV 或 RSS 订阅。里面都是有声内容。
public struct TingReaderLibrary: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// `local` / `webdav` / `rss`。
    public let libraryType: String

    public init(id: String, name: String, libraryType: String) {
        self.id = id
        self.name = name
        self.libraryType = libraryType
    }

    public init?(json: [String: Any]) {
        guard let id = trString(json["id"]) else { return nil }
        self.id = id
        self.name = trString(json["name"]) ?? id
        self.libraryType = trString(json["library_type"])?.lowercased() ?? "local"
    }

    public var descriptor: ServerLibraryDescriptor {
        ServerLibraryDescriptor(id: id, name: name, kind: libraryType == "rss" ? .podcasts : .audiobooks)
    }
}

/// 一本书(RSS 存储库里是一个节目)。
public struct TingReaderBook: Sendable, Equatable {
    public let id: String
    public let libraryID: String
    public let title: String
    public let author: String?
    public let narrator: String?
    /// 存储库里的封面文件路径,或刮削来的外链;取的时候都交给服务器代取。
    public let coverPath: String?
    public let genre: String?
    public let year: Int?
    public let createdAt: Date?

    public init(id: String, libraryID: String, title: String, author: String? = nil, narrator: String? = nil,
                coverPath: String? = nil, genre: String? = nil, year: Int? = nil, createdAt: Date? = nil) {
        self.id = id
        self.libraryID = libraryID
        self.title = title
        self.author = author
        self.narrator = narrator
        self.coverPath = coverPath
        self.genre = genre
        self.year = year
        self.createdAt = createdAt
    }

    public init?(json: [String: Any]) {
        guard let id = trString(json["id"]) else { return nil }
        self.id = id
        self.libraryID = trString(json["library_id"]) ?? ""
        // 还没刮削、书名为空的书,用它所在的文件夹名,不露出 id。
        let folder = trString(json["path"]).map {
            (($0.replacingOccurrences(of: "\\", with: "/")) as NSString).lastPathComponent
        }
        self.title = trString(json["title"]) ?? folder.flatMap { trString($0) } ?? id
        self.author = trString(json["author"])
        self.narrator = trString(json["narrator"])
        self.coverPath = trString(json["cover_url"])
        self.genre = trString(json["genre"])
        self.year = trInt(json["year"]).flatMap { $0 > 0 ? $0 : nil }
        self.createdAt = trDate(json["created_at"])
    }
}

/// 一章 = 服务器上的一个音频文件。
public struct TingReaderChapter: Sendable, Equatable {
    public let id: String
    public let bookID: String
    public let title: String?
    /// 服务器上的路径(本地路径、WebDAV 路径或 RSS 里的音频地址),只拿来认后缀和兜底章名。
    public let path: String
    public let duration: TimeInterval
    public let index: Int?
    /// 服务端标成「番外」的章节,排在正文之后。
    public let isExtra: Bool
    /// 当前账号在这一章的位置(秒);没听过是 nil。
    public let progressPosition: TimeInterval?
    public let progressUpdatedAt: Date?

    public init(id: String, bookID: String, title: String? = nil, path: String, duration: TimeInterval,
                index: Int? = nil, isExtra: Bool = false, progressPosition: TimeInterval? = nil,
                progressUpdatedAt: Date? = nil) {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.path = path
        self.duration = duration
        self.index = index
        self.isExtra = isExtra
        self.progressPosition = progressPosition
        self.progressUpdatedAt = progressUpdatedAt
    }

    public init?(json: [String: Any]) {
        guard let id = trString(json["id"]), let bookID = trString(json["book_id"]) else { return nil }
        self.id = id
        self.bookID = bookID
        self.title = trString(json["title"])
        self.path = trString(json["path"]) ?? ""
        self.duration = max(0, trDouble(json["duration"]) ?? 0)
        self.index = trInt(json["chapter_index"])
        self.isExtra = (trInt(json["is_extra"]) ?? 0) != 0 || (json["is_extra"] as? Bool) == true
        self.progressPosition = trDouble(json["progress_position"])
        self.progressUpdatedAt = trDate(json["progress_updated_at"])
    }

    public var fileExtension: String {
        TingReaderAPIProtocol.audioFileExtension(forServerPath: path)
    }

    /// 文件名(去掉后缀),章节没有标题时用。
    var fileStem: String? {
        var candidate = path
        if let components = URLComponents(string: path), components.scheme != nil {
            candidate = components.path
        }
        let leaf = (candidate.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let stem = (leaf as NSString).deletingPathExtension
        return trString(stem.removingPercentEncoding ?? stem)
    }
}

/// 服务端一章的进度落到本机的样子。
public struct TingReaderChapterProgress: Sendable, Equatable {
    public let position: TimeInterval
    public let duration: TimeInterval
    public let isFinished: Bool
    public let updatedAt: Date

    public init(position: TimeInterval, duration: TimeInterval, isFinished: Bool, updatedAt: Date) {
        self.position = position
        self.duration = duration
        self.isFinished = isFinished
        self.updatedAt = updatedAt
    }
}

/// 服务端按「账号 + 书 + 章」各记一条位置,没有「听完」标记(它算书的进度时按位置占时长的比例)。
public enum TingReaderProgressPolicy {
    /// 离结尾不到本机认定听完的那段、又过了一半,就算听完 —— 和本机播放时的判断一致;
    /// 过半的条件挡住很短的章节,免得刚开头的位置被当成听完。
    public static func isFinished(position: TimeInterval, duration: TimeInterval) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0, position > 0 else { return false }
        return position >= duration - SpokenWordProgressPolicy.completionTailThreshold
            && position >= duration / 2
    }

    public static func progress(for chapter: TingReaderChapter) -> TingReaderChapterProgress? {
        guard let position = chapter.progressPosition, position.isFinite, position >= 0,
              let updatedAt = chapter.progressUpdatedAt else { return nil }
        let finished = isFinished(position: position, duration: chapter.duration)
        return TingReaderChapterProgress(
            position: finished ? chapter.duration : min(position, chapter.duration > 0 ? chapter.duration : position),
            duration: chapter.duration,
            isFinished: finished,
            updatedAt: updatedAt
        )
    }

    /// 报给服务端的位置。听完就报整章时长,这样它的书进度会算满,读回来也还是听完。
    public static func reportedPosition(position: TimeInterval, duration: TimeInterval, isFinished: Bool) -> TimeInterval {
        let safe = position.isFinite ? max(0, position) : 0
        guard duration.isFinite, duration > 0 else { return safe }
        return isFinished ? duration : min(safe, duration)
    }
}

/// 一本书和它的章节,扫描与进度换算都用它。
public struct TingReaderCatalogBook: Sendable, Equatable {
    public let book: TingReaderBook
    /// 服务端给的顺序:正文按章节序号,番外在后。
    public let chapters: [TingReaderChapter]

    public init(book: TingReaderBook, chapters: [TingReaderChapter]) {
        self.book = book
        self.chapters = chapters
    }

    public func chapter(id: String) -> TingReaderChapter? {
        chapters.first { $0.id == id }
    }

    public func trackPath(for chapter: TingReaderChapter) -> String {
        TingReaderAPIProtocol.trackPath(bookID: book.id, chapterID: chapter.id, fileExtension: chapter.fileExtension)
    }

    /// 歌曲 id 只跟章节走:书合并、章节挪到别的书时,播放记录和进度跟着它。
    public static func songID(sourceID: String, chapterID: String) -> String {
        hash("\(sourceID):tingreader:\(chapterID)")
    }

    public func makeSongs(sourceID: String) -> [Song] {
        let coverReference = book.coverPath.map {
            TingReaderAPIProtocol.coverReference(bookID: book.id, libraryID: book.libraryID, coverPath: $0)
        }
        // 演播者当艺术家、作者当专辑艺术家:有声书架按「书名 + 作者」把各章合回一本。
        let artist = book.narrator ?? book.author
        return chapters.enumerated().map { position, chapter in
            let title: String
            if chapters.count == 1 {
                title = book.title
            } else {
                title = chapter.title ?? chapter.fileStem ?? "\(book.title) \(position + 1)"
            }
            let fileExtension = chapter.fileExtension
            return Song(
                id: Self.songID(sourceID: sourceID, chapterID: chapter.id),
                title: title,
                albumID: book.id,
                albumTitle: book.title,
                artistName: artist,
                albumArtistName: book.author,
                trackNumber: position + 1,
                duration: chapter.duration,
                fileFormat: AudioFormat.from(fileExtension: fileExtension) ?? .mp3,
                filePath: TingReaderAPIProtocol.trackPath(bookID: book.id, chapterID: chapter.id, fileExtension: fileExtension),
                sourceID: sourceID,
                genre: book.genre,
                year: book.year,
                dateAdded: book.createdAt ?? Date(),
                coverArtFileName: coverReference,
                revision: "tingreader:\(Self.hash(chapter.path).prefix(16)):\(Int(chapter.duration.rounded()))",
                serverLibraryID: book.libraryID.isEmpty ? nil : book.libraryID
            )
        }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 公开的 `/api/stats`:全服务器的书数、章节数、总时长与最近一次扫描时间。
/// 不分账号,只拿来判断服务器上的内容有没有变。
public struct TingReaderCatalogStats: Sendable, Equatable {
    public let totalBooks: Int
    public let totalChapters: Int
    public let totalDuration: Int64
    public let lastScanAt: Date?

    public init(totalBooks: Int, totalChapters: Int, totalDuration: Int64, lastScanAt: Date?) {
        self.totalBooks = totalBooks
        self.totalChapters = totalChapters
        self.totalDuration = totalDuration
        self.lastScanAt = lastScanAt
    }

    public init?(json: [String: Any]) {
        guard let books = trInt(json["total_books"]), let chapters = trInt(json["total_chapters"]) else { return nil }
        self.totalBooks = books
        self.totalChapters = chapters
        self.totalDuration = trInt64(json["total_duration"]) ?? 0
        self.lastScanAt = trDate(json["last_scan_time"])
    }

    public var contentRevision: String {
        "\(totalBooks):\(totalChapters):\(totalDuration)"
    }
}

// MARK: - Transport

/// 可注入的请求通道,让 App 端套自己的证书与跳转策略。
public struct TingReaderRequestTransport: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias DownloadLoader = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    private let dataLoader: DataLoader
    private let downloadLoader: DownloadLoader

    public init(data: @escaping DataLoader, download: @escaping DownloadLoader) {
        self.dataLoader = data
        self.downloadLoader = download
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await dataLoader(request)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await downloadLoader(request)
    }

    static func urlSession(_ session: URLSession) -> Self {
        Self(
            data: { try await StreamResolverHTTPTransport.data(for: $0, session: session) },
            download: { try await StreamResolverHTTPTransport.download(for: $0, session: session) }
        )
    }
}

// MARK: - Client

/// Ting Reader 的书目、封面、音频与收听进度共用的客户端。
///
/// 只有账号密码一种登录:`POST /api/auth/login` 换回 7 天有效的 JWT,没有刷新接口。
/// token 只留在内存里,被拒(401)一次就重新登录。403 是这个账号没有那本书的权限,不是会话问题。
public actor TingReaderServiceClient {
    private let sourceID: String
    public let baseURL: URL?
    private let username: String
    private let password: String?
    private let transport: TingReaderRequestTransport
    private let ownedSession: URLSession?
    private var token: String?
    private var authTask: Task<String, Error>?

    public init(
        source: MusicSource,
        credential: SourceCredential?,
        transport: TingReaderRequestTransport? = nil
    ) {
        let credential = credential ?? SourceCredential()
        self.init(
            sourceID: source.id,
            host: source.host ?? "",
            port: source.port,
            useSSL: source.useSsl,
            basePath: source.basePath,
            username: credential.username ?? source.username ?? "",
            password: credential.password ?? credential.token ?? "",
            transport: transport
        )
    }

    public init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        username: String,
        password: String,
        transport: TingReaderRequestTransport? = nil
    ) {
        self.sourceID = sourceID
        self.baseURL = TingReaderAPIProtocol.serverBaseURL(
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath
        )
        self.username = username
        self.password = password
        if let transport {
            self.transport = transport
            self.ownedSession = nil
        } else {
            let session = Self.makeSession()
            self.transport = .urlSession(session)
            self.ownedSession = session
        }
    }

    deinit { ownedSession?.invalidateAndCancel() }

    public func invalidateSession() {
        token = nil
        authTask?.cancel()
        authTask = nil
    }

    // MARK: Catalogue

    /// 登录并列出存储库;空列表也算连上了(账号可能还没分到存储库)。
    public func validateConnection() async throws -> [TingReaderLibrary] {
        try await libraries()
    }

    /// 管理员看到全部,普通账号只看到分给它的。
    public func libraries() async throws -> [TingReaderLibrary] {
        try Self.list(try await authorizedJSON(path: "/api/libraries"), key: "libraries")
            .compactMap(TingReaderLibrary.init(json:))
    }

    /// 账号看得到的全部书。服务端不分页,一次给全。
    public func books() async throws -> [TingReaderBook] {
        try Self.list(try await authorizedJSON(path: "/api/books"), key: "books")
            .compactMap(TingReaderBook.init(json:))
    }

    public func book(id: String) async throws -> TingReaderBook? {
        do {
            let payload = try await authorizedJSON(path: "/api/books/\(TingReaderAPIProtocol.encodedPathComponent(id))")
            guard let dictionary = payload as? [String: Any] else { return nil }
            return TingReaderBook(json: dictionary)
        } catch TingReaderServiceError.badServerResponse(404) {
            return nil
        }
    }

    /// 一本书的全部章节(不带分页参数时服务端回整个数组),附当前账号每章的位置。
    public func chapters(bookID: String) async throws -> [TingReaderChapter] {
        let payload = try await authorizedJSON(
            path: "/api/books/\(TingReaderAPIProtocol.encodedPathComponent(bookID))/chapters"
        )
        return try Self.list(payload, key: "chapters").compactMap(TingReaderChapter.init(json:))
    }

    /// 书和章节一起取;书已经不在了是 nil。
    public func catalogBook(id: String) async throws -> TingReaderCatalogBook? {
        guard let book = try await book(id: id) else { return nil }
        do {
            return TingReaderCatalogBook(book: book, chapters: try await chapters(bookID: id))
        } catch TingReaderServiceError.badServerResponse(404) {
            return nil
        }
    }

    /// 公开接口,不登录:服务端每次登录都记一条登录日志、发一次登录通知,定期检查不该刷它。
    public func catalogStats() async throws -> TingReaderCatalogStats {
        guard let baseURL,
              let url = TingReaderAPIProtocol.endpointURL(serverBaseURL: baseURL, path: "/api/stats") else {
            throw TingReaderServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Primuse", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TingReaderServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw TingReaderServiceError.badServerResponse(http.statusCode)
        }
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = TingReaderCatalogStats(json: dictionary) else {
            throw TingReaderServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
        }
        return stats
    }

    // MARK: Media

    public func fetchRange(trackPath: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0, length <= Int64(Int.max),
              let reference = TingReaderAPIProtocol.trackReference(from: trackPath) else { return Data() }
        let rangeValue: String
        if offset < 0 {
            rangeValue = "bytes=-\(length)"
        } else {
            guard let exclusiveEnd = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
                return Data()
            }
            rangeValue = "bytes=\(offset)-\(exclusiveEnd - 1)"
        }
        let path = TingReaderAPIProtocol.streamPath(chapterID: reference.chapterID)
        for attempt in 0...1 {
            let request = try await authenticatedRequest(
                path: path,
                headers: ["Range": rangeValue, "Accept-Encoding": "identity", "Accept": "*/*"]
            )
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TingReaderServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if http.statusCode == 401 {
                if attempt == 0, try await recoverSession(after: request) { continue }
                throw TingReaderServiceError.authenticationFailed
            }
            if http.statusCode == 200 { throw TingReaderServiceError.rangeNotSupported }
            guard http.statusCode == 206 else {
                throw TingReaderServiceError.badServerResponse(http.statusCode)
            }
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw TingReaderServiceError.invalidResponse(PMString("error.catalog.invalidRangeResponse"))
            }
            return data
        }
        throw TingReaderServiceError.authenticationFailed
    }

    public func downloadTrack(trackPath: String) async throws -> URL {
        guard let reference = TingReaderAPIProtocol.trackReference(from: trackPath) else {
            throw TingReaderServiceError.invalidResponse(PMString("error.catalog.invalidTrackReference"))
        }
        let path = TingReaderAPIProtocol.streamPath(chapterID: reference.chapterID)
        for attempt in 0...1 {
            let request = try await authenticatedRequest(path: path, headers: ["Accept": "*/*"])
            let (temporaryURL, response) = try await transport.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw TingReaderServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if http.statusCode == 401 {
                try? FileManager.default.removeItem(at: temporaryURL)
                if attempt == 0, try await recoverSession(after: request) { continue }
                throw TingReaderServiceError.authenticationFailed
            }
            guard (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw TingReaderServiceError.badServerResponse(http.statusCode)
            }
            return temporaryURL
        }
        throw TingReaderServiceError.authenticationFailed
    }

    /// 给 Apple TV 的直连地址与播放头,先用两字节 Range 探一下这章真的能取。
    /// 服务端对这章回整份文件时照样能播,只是拖动进度要等它读到那里。
    public func resolvedStream(trackPath: String) async throws -> ResolvedStream {
        do {
            _ = try await fetchRange(trackPath: trackPath, offset: 0, length: 2)
        } catch TingReaderServiceError.rangeNotSupported {}
        guard let baseURL,
              let reference = TingReaderAPIProtocol.trackReference(from: trackPath),
              let url = TingReaderAPIProtocol.streamURL(serverBaseURL: baseURL, chapterID: reference.chapterID),
              let token else {
            throw TingReaderServiceError.invalidURL
        }
        return ResolvedStream(url: url, headers: ["Authorization": "Bearer \(token)"])
    }

    public func coverData(reference: String, maximumBytes: Int) async throws -> Data? {
        guard let cover = TingReaderAPIProtocol.coverReference(from: reference), maximumBytes > 0 else {
            return nil
        }
        for attempt in 0...1 {
            let request = try await authenticatedRequest(
                path: "/api/proxy/cover",
                queryItems: TingReaderAPIProtocol.coverProxyQueryItems(for: cover),
                headers: ["Accept": "image/*"]
            )
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TingReaderServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if http.statusCode == 401 {
                if attempt == 0, try await recoverSession(after: request) { continue }
                throw TingReaderServiceError.authenticationFailed
            }
            // 封面文件没了、外链失效:当没有封面,交给刮削。
            if http.statusCode == 404 || http.statusCode == 502 { return nil }
            guard (200...299).contains(http.statusCode) else {
                throw TingReaderServiceError.badServerResponse(http.statusCode)
            }
            guard !data.isEmpty, data.count <= maximumBytes else { return nil }
            return data
        }
        throw TingReaderServiceError.authenticationFailed
    }

    // MARK: Listening progress

    /// 一章的位置(秒,章内)。服务端按「账号 + 书 + 章」覆盖写。
    public func updateProgress(
        bookID: String,
        chapterID: String,
        position: TimeInterval,
        duration: TimeInterval
    ) async throws {
        var body: [String: Any] = [
            "book_id": bookID,
            "chapter_id": chapterID,
            "position": position.isFinite ? max(0, position) : 0,
        ]
        if duration.isFinite, duration > 0 { body["duration"] = duration }
        _ = try await authorizedJSON(path: "/api/progress", method: "POST", body: body, allowsEmptyBody: true)
    }

    // MARK: Requests

    private func authorizedJSON(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: Any]? = nil,
        allowsEmptyBody: Bool = false
    ) async throws -> Any {
        for attempt in 0...1 {
            var request = try await authenticatedRequest(path: path, queryItems: queryItems)
            request.httpMethod = method
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            }
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TingReaderServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if http.statusCode == 401 {
                if attempt == 0, try await recoverSession(after: request) { continue }
                throw TingReaderServiceError.authenticationFailed
            }
            guard (200...299).contains(http.statusCode) else {
                throw TingReaderServiceError.badServerResponse(http.statusCode)
            }
            if data.isEmpty, allowsEmptyBody { return [String: Any]() }
            do {
                return try JSONSerialization.jsonObject(with: data)
            } catch {
                if allowsEmptyBody { return [String: Any]() }
                throw TingReaderServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
            }
        }
        throw TingReaderServiceError.authenticationFailed
    }

    private func authenticatedRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> URLRequest {
        let token = try await currentToken()
        guard let baseURL,
              let url = TingReaderAPIProtocol.endpointURL(
                serverBaseURL: baseURL,
                path: path,
                queryItems: queryItems
              ) else {
            throw TingReaderServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Primuse", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// 列表接口回的是数组;也认 `{"<key>": [...]}` 的包法。
    private static func list(_ payload: Any, key: String) throws -> [[String: Any]] {
        if let array = payload as? [[String: Any]] { return array }
        if let dictionary = payload as? [String: Any], let array = dictionary[key] as? [[String: Any]] {
            return array
        }
        throw TingReaderServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
    }

    // MARK: Session

    private func currentToken() async throws -> String {
        if let token { return token }
        return try await establishSession()
    }

    /// 服务端拒了这个 token:重新登录一次。只有被拒的还是当前这一个时才动会话,
    /// 免得迟到的 401 作废刚换好的新 token。
    private func recoverSession(after request: URLRequest) async throws -> Bool {
        guard let token else { return true }
        let rejected = request.value(forHTTPHeaderField: "Authorization")
        guard rejected == nil || rejected == "Bearer \(token)" else { return true }
        self.token = nil
        _ = try await establishSession()
        return true
    }

    private func establishSession() async throws -> String {
        if let authTask {
            return try await authTask.value
        }
        let task = Task { try await self.login() }
        authTask = task
        defer { authTask = nil }
        let value = try await task.value
        token = value
        return value
    }

    private func login() async throws -> String {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let password, !password.isEmpty else {
            throw TingReaderServiceError.missingCredential
        }
        guard let baseURL,
              let url = TingReaderAPIProtocol.endpointURL(serverBaseURL: baseURL, path: "/api/auth/login") else {
            throw TingReaderServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Primuse", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["username": username, "password": password],
            options: [.sortedKeys]
        )
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TingReaderServiceError.invalidResponse(PMString("error.catalog.loginMissingHTTPResponse"))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw TingReaderServiceError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw TingReaderServiceError.badServerResponse(http.statusCode)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = Self.token(fromLoginPayload: payload) else {
            throw TingReaderServiceError.invalidResponse(PMString("error.catalog.loginMissingToken"))
        }
        return token
    }

    /// 登录响应 `{"user": {...}, "token": "<JWT>"}` 里的 token。
    public static func token(fromLoginPayload payload: [String: Any]) -> String? {
        trString(payload["token"])
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

// MARK: - Catalogue walk

public enum TingReaderCatalogWalk {
    /// 同时取几本书的章节。服务端是逐本一次请求,书多时串行太慢,开太多又压着 NAS。
    public static let chapterFetchConcurrency = 4

    /// 逐本取章节,每本取到就交给 `body`(按完成先后,不保证书目顺序)。
    /// 走查途中被删掉的书(章节接口 404)跳过。
    public static func forEachBook(
        _ books: [TingReaderBook],
        client: TingReaderServiceClient,
        concurrency: Int = chapterFetchConcurrency,
        isolation: isolated (any Actor)? = #isolation,
        body: (TingReaderCatalogBook) async throws -> Void
    ) async throws {
        guard !books.isEmpty else { return }
        let fetch: @Sendable (TingReaderBook) async throws -> TingReaderCatalogBook? = { book in
            do {
                return TingReaderCatalogBook(book: book, chapters: try await client.chapters(bookID: book.id))
            } catch TingReaderServiceError.badServerResponse(404) {
                return nil
            }
        }
        try await withThrowingTaskGroup(of: TingReaderCatalogBook?.self) { group in
            var pending = books[...]
            for book in pending.prefix(max(1, concurrency)) {
                group.addTask { try await fetch(book) }
            }
            pending = pending.dropFirst(max(1, concurrency))
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let result { try await body(result) }
                if let book = pending.popFirst() {
                    group.addTask { try await fetch(book) }
                }
            }
        }
    }
}

// MARK: - JSON helpers

private func trString(_ value: Any?) -> String? {
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

private func trInt(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
    return nil
}

private func trInt64(_ value: Any?) -> Int64? {
    if let int = value as? Int64 { return int }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string.trimmingCharacters(in: .whitespaces)) }
    return nil
}

private func trDouble(_ value: Any?) -> Double? {
    if let double = value as? Double, double.isFinite { return double }
    if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
    if let string = value as? String, let double = Double(string.trimmingCharacters(in: .whitespaces)), double.isFinite {
        return double
    }
    return nil
}

/// 服务端的时间是 RFC 3339(进度带纳秒,`2026-10-09T12:34:56.123456789+00:00`);
/// 老数据还有 SQLite 的 `2026-10-09 12:34:56`(UTC)。小数秒截到毫秒再交给 ISO 8601 解析。
func tingReaderDate(_ text: String) -> Date? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count >= 19 else { return nil }
    if value.count == 19, value[value.index(value.startIndex, offsetBy: 10)] == " " {
        value.replaceSubrange(value.index(value.startIndex, offsetBy: 10)...value.index(value.startIndex, offsetBy: 10), with: "T")
        value += "Z"
    }
    var hasFraction = false
    if let timeMarker = value.firstIndex(of: "T"),
       let dot = value[timeMarker...].firstIndex(of: ".") {
        let digitsStart = value.index(after: dot)
        let digitsEnd = value[digitsStart...].firstIndex { !$0.isNumber } ?? value.endIndex
        let digits = String(value[digitsStart..<digitsEnd].prefix(3))
        let millis = digits.padding(toLength: 3, withPad: "0", startingAt: 0)
        value.replaceSubrange(dot..<digitsEnd, with: ".\(millis)")
        hasFraction = true
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = hasFraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter.date(from: value)
}

private func trDate(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return tingReaderDate(text)
}
