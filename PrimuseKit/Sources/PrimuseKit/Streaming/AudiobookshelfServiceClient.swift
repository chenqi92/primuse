import CryptoKit
import Foundation

public enum AudiobookshelfServiceError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential
    case invalidURL
    case authenticationFailed
    case badServerResponse(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return PMString("error.audiobookshelf.missingCredential")
        case .invalidURL:
            return PMString("error.audiobookshelf.invalidURL")
        case .authenticationFailed:
            return PMString("error.audiobookshelf.authenticationFailed")
        case .badServerResponse(let status):
            return PMString("error.audiobookshelf.http", String(status))
        case .invalidResponse(let detail):
            return PMString("error.audiobookshelf.invalidResponse", detail)
        }
    }
}

// MARK: - Models

/// 服务端的一个资料库。Audiobookshelf 只有书库和播客库,没有音乐库。
public struct AudiobookshelfLibrary: Sendable, Equatable, Identifiable {
    public enum MediaType: String, Sendable, Equatable {
        case book
        case podcast
        case other
    }

    public let id: String
    public let name: String
    public let mediaType: MediaType
    public let displayOrder: Int

    public init(id: String, name: String, mediaType: MediaType, displayOrder: Int = 0) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.displayOrder = displayOrder
    }

    public init?(json: [String: Any]) {
        guard let id = absNonemptyString(json["id"]) else { return nil }
        self.id = id
        self.name = absNonemptyString(json["name"]) ?? id
        self.mediaType = MediaType(rawValue: absNonemptyString(json["mediaType"])?.lowercased() ?? "") ?? .other
        self.displayOrder = absInt(json["displayOrder"]) ?? 0
    }

    public var descriptor: ServerLibraryDescriptor {
        let kind: ServerLibraryContentKind
        switch mediaType {
        case .book: kind = .audiobooks
        case .podcast: kind = .podcasts
        case .other: kind = .other
        }
        return ServerLibraryDescriptor(id: id, name: name, kind: kind)
    }
}

/// 书里的一个音频文件。
public struct AudiobookshelfAudioFile: Sendable, Equatable {
    public let ino: String
    public let index: Int
    public let duration: TimeInterval
    public let size: Int64
    public let fileExtension: String
    public let fileName: String?
    public let tagTitle: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let bitRate: Int?
    public let excluded: Bool

    public init?(json: [String: Any]) {
        guard let ino = absIDString(json["ino"]) else { return nil }
        self.ino = ino
        self.index = absInt(json["index"]) ?? 0
        self.duration = absDouble(json["duration"]) ?? 0
        self.size = absInt64((json["metadata"] as? [String: Any])?["size"]) ?? 0
        let metadata = json["metadata"] as? [String: Any]
        let filename = absNonemptyString(metadata?["filename"])
        self.fileName = filename
        let ext = absNonemptyString(metadata?["ext"])
            ?? filename.map { "." + ($0 as NSString).pathExtension }
            ?? ""
        self.fileExtension = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let tags = json["metaTags"] as? [String: Any]
        self.tagTitle = absNonemptyString(tags?["tagTitle"])
        self.trackNumber = absInt(json["trackNumFromMeta"]) ?? absInt(json["trackNumFromFilename"])
        self.discNumber = absInt(json["discNumFromMeta"]) ?? absInt(json["discNumFromFilename"])
        let bits = absInt(json["bitRate"])
        self.bitRate = bits.map { $0 > 10_000 ? $0 / 1_000 : $0 }
        self.excluded = (json["exclude"] as? Bool) ?? false
    }

    public init(ino: String, index: Int, duration: TimeInterval, size: Int64 = 0, fileExtension: String,
                fileName: String? = nil, tagTitle: String? = nil, trackNumber: Int? = nil,
                discNumber: Int? = nil, bitRate: Int? = nil, excluded: Bool = false) {
        self.ino = ino
        self.index = index
        self.duration = duration
        self.size = size
        self.fileExtension = fileExtension
        self.fileName = fileName
        self.tagTitle = tagTitle
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.bitRate = bitRate
        self.excluded = excluded
    }
}

/// 整本书时间轴上的一个章节(服务端的章节跨文件连续计时)。
public struct AudiobookshelfChapter: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let title: String

    public init(start: TimeInterval, end: TimeInterval, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }

    public init?(json: [String: Any]) {
        guard let start = absDouble(json["start"]) else { return nil }
        self.start = start
        self.end = absDouble(json["end"]) ?? start
        self.title = absNonemptyString(json["title"]) ?? ""
    }
}

/// 播客的一集。
public struct AudiobookshelfEpisode: Sendable, Equatable {
    public let id: String
    public let index: Int
    public let title: String
    public let season: Int?
    public let episodeNumber: Int?
    public let publishedAt: Date?
    public let audioFile: AudiobookshelfAudioFile

    public init?(json: [String: Any]) {
        guard let id = absNonemptyString(json["id"]),
              let fileJSON = json["audioFile"] as? [String: Any],
              let audioFile = AudiobookshelfAudioFile(json: fileJSON) else { return nil }
        self.id = id
        self.index = absInt(json["index"]) ?? 0
        self.title = absNonemptyString(json["title"]) ?? audioFile.tagTitle ?? audioFile.fileName ?? id
        self.season = absInt(json["season"])
        self.episodeNumber = absInt(json["episode"])
        self.publishedAt = absDate(json["publishedAt"]) ?? absDate(json["pubDate"])
        self.audioFile = audioFile
    }
}

/// 一个文件在整本书时间轴上的位置。
public struct AudiobookshelfTrack: Sendable, Equatable {
    public let ino: String
    public let startOffset: TimeInterval
    public let duration: TimeInterval

    public init(ino: String, startOffset: TimeInterval, duration: TimeInterval) {
        self.ino = ino
        self.startOffset = startOffset
        self.duration = duration
    }
}

/// 一本书或一个播客(服务端的 library item)。
public struct AudiobookshelfCatalogItem: Sendable, Equatable {
    public enum MediaType: String, Sendable, Equatable {
        case book
        case podcast
    }

    public let id: String
    public let libraryID: String
    public let mediaType: MediaType
    public let title: String
    public let subtitle: String?
    public let authors: [String]
    public let authorIDs: [String]
    public let narrators: [String]
    public let seriesNames: [String]
    public let genres: [String]
    public let publishedYear: Int?
    public let addedAt: Date?
    public let updatedAt: Date?
    public let hasCover: Bool
    /// 服务端算好的全书时长;文件列表齐全时与各文件之和一致。
    public let duration: TimeInterval
    public let audioFiles: [AudiobookshelfAudioFile]
    public let chapters: [AudiobookshelfChapter]
    public let episodes: [AudiobookshelfEpisode]
    /// 列表接口可能只给了精简的 media,没有文件;这时要单独取一次条目。
    public let mediaIsComplete: Bool
    /// 精简形态里报的音频文件数,用来判断是不是真的没有文件。
    public let reportedAudioFileCount: Int?

    public init?(json: [String: Any]) {
        guard let id = absNonemptyString(json["id"]) else { return nil }
        let media = json["media"] as? [String: Any] ?? [:]
        let metadata = media["metadata"] as? [String: Any] ?? [:]
        self.id = id
        self.libraryID = absNonemptyString(json["libraryId"]) ?? ""
        self.mediaType = absNonemptyString(json["mediaType"])?.lowercased() == "podcast" ? .podcast : .book
        self.title = absNonemptyString(metadata["title"]) ?? id
        self.subtitle = absNonemptyString(metadata["subtitle"])
        if let names = metadata["authors"] as? [[String: Any]] {
            self.authors = names.compactMap { absNonemptyString($0["name"]) }
            self.authorIDs = names.compactMap { absNonemptyString($0["id"]) }
        } else {
            let joined = absNonemptyString(metadata["authorName"]) ?? absNonemptyString(metadata["author"])
            self.authors = joined.map { [$0] } ?? []
            self.authorIDs = []
        }
        if let narrators = metadata["narrators"] as? [String] {
            self.narrators = narrators.compactMap(absNonemptyString)
        } else {
            self.narrators = absNonemptyString(metadata["narratorName"]).map { [$0] } ?? []
        }
        if let series = metadata["series"] as? [[String: Any]] {
            self.seriesNames = series.compactMap { absNonemptyString($0["name"]) }
        } else {
            self.seriesNames = absNonemptyString(metadata["seriesName"]).map { [$0] } ?? []
        }
        self.genres = (metadata["genres"] as? [String])?.compactMap(absNonemptyString) ?? []
        self.publishedYear = absInt(metadata["publishedYear"])
            ?? absNonemptyString(metadata["publishedYear"]).flatMap { Int($0.prefix(4)) }
            ?? absNonemptyString(metadata["releaseDate"]).flatMap { Int($0.prefix(4)) }
        self.addedAt = absDate(json["addedAt"])
        self.updatedAt = absDate(json["updatedAt"]) ?? absDate(media["updatedAt"])
        self.hasCover = absNonemptyString(media["coverPath"]) != nil
        self.duration = absDouble(media["duration"]) ?? 0
        let files = (media["audioFiles"] as? [[String: Any]])?.compactMap(AudiobookshelfAudioFile.init(json:)) ?? []
        self.audioFiles = files.filter { !$0.excluded }.sorted { $0.index < $1.index }
        self.chapters = (media["chapters"] as? [[String: Any]])?
            .compactMap(AudiobookshelfChapter.init(json:))
            .sorted { $0.start < $1.start } ?? []
        self.episodes = (media["episodes"] as? [[String: Any]])?
            .compactMap(AudiobookshelfEpisode.init(json:))
            .sorted { lhs, rhs in
                if let l = lhs.publishedAt, let r = rhs.publishedAt, l != r { return l < r }
                return lhs.index < rhs.index
            } ?? []
        self.reportedAudioFileCount = absInt(media["numAudioFiles"]) ?? absInt(media["numTracks"])
        switch self.mediaType {
        case .book:
            self.mediaIsComplete = media["audioFiles"] != nil
        case .podcast:
            self.mediaIsComplete = media["episodes"] != nil
        }
    }

    /// 是不是精简形态里报了文件、展开形态却还没拿到。
    public var needsExpandedFetch: Bool {
        guard !mediaIsComplete else { return false }
        return (reportedAudioFileCount ?? 1) > 0
    }

    /// 书里各文件在整本书时间轴上的起点,按服务端的文件顺序累加。
    public var tracks: [AudiobookshelfTrack] {
        var offset: TimeInterval = 0
        return audioFiles.map { file in
            defer { offset += max(0, file.duration) }
            return AudiobookshelfTrack(ino: file.ino, startOffset: offset, duration: max(0, file.duration))
        }
    }

    public func track(forIno ino: String) -> AudiobookshelfTrack? {
        tracks.first { $0.ino == ino }
    }

    /// 服务端的章节是整本书的时间轴;Primuse 按文件记章节,所以切到文件自己的时间轴上。
    public func chapters(forIno ino: String) -> [MediaChapter] {
        guard let track = track(forIno: ino) else { return [] }
        return Self.fileChapters(chapters, track: track)
    }

    public static func fileChapters(_ chapters: [AudiobookshelfChapter], track: AudiobookshelfTrack) -> [MediaChapter] {
        guard track.duration > 0 else { return [] }
        let tolerance: TimeInterval = 0.5
        let start = track.startOffset
        let end = track.startOffset + track.duration
        var result: [MediaChapter] = []
        for chapter in chapters where chapter.start >= start - tolerance && chapter.start < end - tolerance {
            let local = max(0, chapter.start - start)
            result.append(MediaChapter(startTime: local, title: chapter.title))
        }
        // 文件开头之前就开始、一直延续进来的那一章,从 0 算起。
        if let spanning = chapters.last(where: { $0.start < start - tolerance && $0.end > start + tolerance }),
           result.first.map({ $0.startTime > tolerance }) ?? true {
            result.insert(MediaChapter(startTime: 0, title: spanning.title), at: 0)
        }
        return result
    }

    /// 文件内的位置换成整本书的位置(服务端的进度按整本书计)。
    public func bookPosition(ino: String, localPosition: TimeInterval) -> TimeInterval? {
        guard let track = track(forIno: ino) else { return nil }
        return track.startOffset + max(0, min(localPosition, track.duration))
    }

    /// 整本书的位置换成文件与文件内的位置。
    public func filePosition(bookPosition: TimeInterval) -> (ino: String, localPosition: TimeInterval)? {
        let all = tracks
        guard !all.isEmpty else { return nil }
        for track in all where bookPosition < track.startOffset + track.duration {
            return (track.ino, max(0, bookPosition - track.startOffset))
        }
        let last = all[all.count - 1]
        return (last.ino, last.duration)
    }

    public func makeSongs(sourceID: String) -> [Song] {
        switch mediaType {
        case .book: return bookSongs(sourceID: sourceID)
        case .podcast: return episodeSongs(sourceID: sourceID)
        }
    }

    private var authorName: String? { authors.isEmpty ? nil : authors.joined(separator: ", ") }
    private var narratorName: String? { narrators.isEmpty ? nil : narrators.joined(separator: ", ") }
    private var genreValue: String? { genres.isEmpty ? nil : genres.joined(separator: ", ") }

    private func bookSongs(sourceID: String) -> [Song] {
        let files = audioFiles
        let coverReference = hasCover
            ? AudiobookshelfAPIProtocol.coverReference(itemID: id, updatedAt: updatedAt)
            : nil
        return files.enumerated().map { position, file in
            let title: String
            if files.count == 1 {
                title = self.title
            } else {
                title = file.tagTitle
                    ?? file.fileName.map { ($0 as NSString).deletingPathExtension }
                    ?? "\(self.title) \(position + 1)"
            }
            return Song(
                id: Self.hash("\(sourceID):audiobookshelf:\(id):\(file.ino)"),
                title: title,
                albumID: id,
                artistID: authorIDs.first,
                albumTitle: self.title,
                artistName: narratorName ?? authorName,
                albumArtistName: authorName,
                trackNumber: file.trackNumber ?? position + 1,
                discNumber: file.discNumber,
                duration: file.duration,
                fileFormat: AudioFormat.from(fileExtension: file.fileExtension) ?? .mp3,
                filePath: AudiobookshelfAPIProtocol.trackPath(itemID: id, kind: .file(ino: file.ino), fileExtension: file.fileExtension),
                sourceID: sourceID,
                fileSize: file.size,
                bitRate: file.bitRate,
                genre: genreValue,
                year: publishedYear,
                lastModified: updatedAt,
                dateAdded: addedAt ?? Date(),
                coverArtFileName: coverReference,
                revision: "audiobookshelf:\(Self.revisionValue(updatedAt)):\(file.size)",
                serverLibraryID: libraryID.isEmpty ? nil : libraryID
            )
        }
    }

    private func episodeSongs(sourceID: String) -> [Song] {
        let coverReference = hasCover
            ? AudiobookshelfAPIProtocol.coverReference(itemID: id, updatedAt: updatedAt)
            : nil
        return episodes.enumerated().map { position, episode in
            let file = episode.audioFile
            let year = episode.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
            return Song(
                id: Self.hash("\(sourceID):audiobookshelf:\(id):episode:\(episode.id)"),
                title: episode.title,
                albumID: id,
                albumTitle: self.title,
                artistName: authorName,
                albumArtistName: authorName,
                trackNumber: episode.episodeNumber ?? position + 1,
                discNumber: episode.season,
                duration: file.duration,
                fileFormat: AudioFormat.from(fileExtension: file.fileExtension) ?? .mp3,
                filePath: AudiobookshelfAPIProtocol.trackPath(itemID: id, kind: .episode(id: episode.id), fileExtension: file.fileExtension),
                sourceID: sourceID,
                fileSize: file.size,
                bitRate: file.bitRate,
                genre: genreValue,
                year: year ?? publishedYear,
                lastModified: updatedAt,
                dateAdded: episode.publishedAt ?? addedAt ?? Date(),
                coverArtFileName: coverReference,
                revision: "audiobookshelf:\(Self.revisionValue(updatedAt)):\(file.size)",
                serverLibraryID: libraryID.isEmpty ? nil : libraryID
            )
        }
    }

    private static func revisionValue(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 服务端记的收听进度(按书 / 按集,整本书时间轴)。
public struct AudiobookshelfMediaProgress: Sendable, Equatable {
    public let libraryItemID: String
    public let episodeID: String?
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let isFinished: Bool
    public let lastUpdate: Date?

    public init(libraryItemID: String, episodeID: String?, currentTime: TimeInterval, duration: TimeInterval,
                isFinished: Bool, lastUpdate: Date?) {
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID
        self.currentTime = currentTime
        self.duration = duration
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
    }

    public init?(json: [String: Any]) {
        guard let itemID = absNonemptyString(json["libraryItemId"]) else { return nil }
        self.libraryItemID = itemID
        self.episodeID = absNonemptyString(json["episodeId"])
        self.currentTime = absDouble(json["currentTime"]) ?? 0
        self.duration = absDouble(json["duration"]) ?? 0
        self.isFinished = (json["isFinished"] as? Bool) ?? false
        self.lastUpdate = absDate(json["lastUpdate"])
    }
}

public struct AudiobookshelfCatalogPage: Sendable {
    public let items: [AudiobookshelfCatalogItem]
    public let total: Int
    public let page: Int
    public let rawCount: Int

    public init(items: [AudiobookshelfCatalogItem], total: Int, page: Int, rawCount: Int) {
        self.items = items
        self.total = total
        self.page = page
        self.rawCount = rawCount
    }
}

// MARK: - Transport

/// 可注入的请求通道,让 App 端套自己的证书与明文策略。
public struct AudiobookshelfRequestTransport: Sendable {
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

/// Audiobookshelf 的曲库、封面、媒体流与收听进度共用的客户端。
///
/// 鉴权两种:API 密钥(服务端「设置 › API Keys」里建,长期有效,直接当 Bearer);
/// 账号密码(2.26 起换回短期 accessToken + refreshToken,旧版本给不过期的 `user.token`,
/// 两种都认)。token 只留在内存里,被拒一次就刷新或重新登录。
public actor AudiobookshelfServiceClient {
    private enum Session {
        case apiKey(String)
        case legacy(token: String)
        case jwt(accessToken: String, refreshToken: String?)

        var bearer: String {
            switch self {
            case .apiKey(let key): return key
            case .legacy(let token): return token
            case .jwt(let accessToken, _): return accessToken
            }
        }
    }

    public static let pageSize = 50

    private let sourceID: String
    public let baseURL: URL?
    private let username: String
    private let secret: String?
    private let usesAPIKey: Bool
    private let transport: AudiobookshelfRequestTransport
    private let ownedSession: URLSession?
    private var session: Session?
    private var authTask: Task<Session, Error>?

    public init(
        source: MusicSource,
        credential: SourceCredential?,
        transport: AudiobookshelfRequestTransport? = nil
    ) {
        let credential = credential ?? SourceCredential()
        self.sourceID = source.id
        self.baseURL = AudiobookshelfAPIProtocol.serverBaseURL(
            host: source.host ?? "",
            port: source.port,
            useSSL: source.useSsl,
            basePath: source.basePath
        )
        self.usesAPIKey = source.authType == .apiKey
        self.username = credential.username ?? source.username ?? ""
        self.secret = credential.token ?? credential.password
        if let transport {
            self.transport = transport
            self.ownedSession = nil
        } else {
            let session = Self.makeSession()
            self.transport = .urlSession(session)
            self.ownedSession = session
        }
    }

    public init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        username: String,
        secret: String,
        authType: SourceAuthType,
        transport: AudiobookshelfRequestTransport? = nil
    ) {
        self.sourceID = sourceID
        self.baseURL = AudiobookshelfAPIProtocol.serverBaseURL(
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath
        )
        self.usesAPIKey = authType == .apiKey
        self.username = username
        self.secret = secret
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
        session = nil
        authTask?.cancel()
        authTask = nil
    }

    // MARK: Catalogue

    /// 登录并列出资料库;空列表也算连上了(账号可能还没分到库)。
    public func validateConnection() async throws -> [AudiobookshelfLibrary] {
        try await libraries()
    }

    public func libraries() async throws -> [AudiobookshelfLibrary] {
        let payload = try await authorizedJSON(path: "/api/libraries")
        guard let dictionary = payload as? [String: Any],
              let list = dictionary["libraries"] as? [[String: Any]] else {
            throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
        }
        return list.compactMap(AudiobookshelfLibrary.init(json:))
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    /// 一页条目。列表给的是完整条目时直接用;只给了精简 media 的,逐条取展开形态。
    public func libraryItemsPage(libraryID: String, page: Int, limit: Int = pageSize) async throws -> AudiobookshelfCatalogPage {
        guard page >= 0, limit > 0, limit <= 500 else {
            throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.invalidPagination"))
        }
        let payload = try await authorizedJSON(
            path: "/api/libraries/\(AudiobookshelfAPIProtocol.encodedPathComponent(libraryID))/items",
            queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "sort", value: "addedAt"),
                URLQueryItem(name: "minified", value: "0"),
            ]
        )
        guard let dictionary = payload as? [String: Any],
              let results = dictionary["results"] as? [[String: Any]] else {
            throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
        }
        var items: [AudiobookshelfCatalogItem] = []
        items.reserveCapacity(results.count)
        for json in results {
            guard var item = AudiobookshelfCatalogItem(json: json) else { continue }
            if item.needsExpandedFetch, let expanded = try await self.item(id: item.id) {
                item = expanded
            }
            items.append(item)
        }
        return AudiobookshelfCatalogPage(
            items: items,
            total: absInt(dictionary["total"]) ?? items.count,
            page: absInt(dictionary["page"]) ?? page,
            rawCount: results.count
        )
    }

    public func item(id: String) async throws -> AudiobookshelfCatalogItem? {
        let payload = try await authorizedJSON(
            path: "/api/items/\(AudiobookshelfAPIProtocol.encodedPathComponent(id))",
            queryItems: [URLQueryItem(name: "expanded", value: "1")]
        )
        guard let dictionary = payload as? [String: Any] else { return nil }
        return AudiobookshelfCatalogItem(json: dictionary)
    }

    /// 各库条目总数之和,给「服务端有没有变」的探针用。
    public func catalogItemCount(libraryIDs: [String]) async throws -> Int {
        var total = 0
        for libraryID in libraryIDs {
            let payload = try await authorizedJSON(
                path: "/api/libraries/\(AudiobookshelfAPIProtocol.encodedPathComponent(libraryID))/items",
                queryItems: [
                    URLQueryItem(name: "limit", value: "1"),
                    URLQueryItem(name: "page", value: "0"),
                    URLQueryItem(name: "minified", value: "1"),
                ]
            )
            guard let dictionary = payload as? [String: Any], let count = absInt(dictionary["total"]) else {
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
            }
            total += count
        }
        return total
    }

    // MARK: Media

    public func fetchRange(trackPath: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0, length <= Int64(Int.max),
              let reference = AudiobookshelfAPIProtocol.trackReference(from: trackPath) else { return Data() }
        let ino = try await fileIno(for: reference)
        let rangeValue: String
        if offset < 0 {
            rangeValue = "bytes=-\(length)"
        } else {
            guard let exclusiveEnd = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
                return Data()
            }
            rangeValue = "bytes=\(offset)-\(exclusiveEnd - 1)"
        }
        let path = "/api/items/\(AudiobookshelfAPIProtocol.encodedPathComponent(reference.itemID))/file/\(AudiobookshelfAPIProtocol.encodedPathComponent(ino))"
        for attempt in 0...1 {
            let request = try await authenticatedRequest(
                path: path,
                headers: ["Range": rangeValue, "Accept-Encoding": "identity"]
            )
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if Self.isAuthenticationFailure(http.statusCode) {
                if attempt == 0, try await recoverSession(after: request) { continue }
                throw AudiobookshelfServiceError.authenticationFailed
            }
            guard http.statusCode == 206 else {
                throw AudiobookshelfServiceError.badServerResponse(http.statusCode)
            }
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.invalidRangeResponse"))
            }
            return data
        }
        throw AudiobookshelfServiceError.authenticationFailed
    }

    public func downloadTrack(trackPath: String) async throws -> URL {
        guard let reference = AudiobookshelfAPIProtocol.trackReference(from: trackPath) else {
            throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.invalidTrackReference"))
        }
        let ino = try await fileIno(for: reference)
        let path = "/api/items/\(AudiobookshelfAPIProtocol.encodedPathComponent(reference.itemID))/file/\(AudiobookshelfAPIProtocol.encodedPathComponent(ino))"
        for attempt in 0...1 {
            let request = try await authenticatedRequest(path: path)
            let (temporaryURL, response) = try await transport.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if Self.isAuthenticationFailure(http.statusCode) {
                try? FileManager.default.removeItem(at: temporaryURL)
                if attempt == 0, try await recoverSession(after: request) { continue }
                throw AudiobookshelfServiceError.authenticationFailed
            }
            guard (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw AudiobookshelfServiceError.badServerResponse(http.statusCode)
            }
            return temporaryURL
        }
        throw AudiobookshelfServiceError.authenticationFailed
    }

    /// 给 Apple TV 的直连地址与播放头,先用两字节 Range 探一下文件真的能取。
    public func resolvedStream(trackPath: String) async throws -> ResolvedStream {
        _ = try await fetchRange(trackPath: trackPath, offset: 0, length: 2)
        guard let baseURL,
              let reference = AudiobookshelfAPIProtocol.trackReference(from: trackPath) else {
            throw AudiobookshelfServiceError.invalidURL
        }
        let ino = try await fileIno(for: reference)
        guard let url = AudiobookshelfAPIProtocol.fileURL(serverBaseURL: baseURL, itemID: reference.itemID, ino: ino),
              let session else {
            throw AudiobookshelfServiceError.invalidURL
        }
        return ResolvedStream(url: url, headers: ["Authorization": "Bearer \(session.bearer)"])
    }

    public func coverData(reference: String, maximumBytes: Int) async throws -> Data? {
        guard let itemID = AudiobookshelfAPIProtocol.coverItemID(fromReference: reference), maximumBytes > 0 else {
            return nil
        }
        let path = "/api/items/\(AudiobookshelfAPIProtocol.encodedPathComponent(itemID))/cover"
        for attempt in 0...1 {
            let request = try await authenticatedRequest(
                path: path,
                queryItems: [URLQueryItem(name: "format", value: "jpeg"), URLQueryItem(name: "width", value: "800")]
            )
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if Self.isAuthenticationFailure(http.statusCode) {
                if attempt == 0, try await recoverSession(after: request) { continue }
                throw AudiobookshelfServiceError.authenticationFailed
            }
            if http.statusCode == 404 { return nil }
            guard (200...299).contains(http.statusCode) else {
                throw AudiobookshelfServiceError.badServerResponse(http.statusCode)
            }
            guard data.count <= maximumBytes else { return nil }
            return data
        }
        throw AudiobookshelfServiceError.authenticationFailed
    }

    /// 播客一集的文件 ino 不在路径里(路径记的是集 id,进度接口认它),播放前查一次条目。
    private var episodeInos: [String: String] = [:]

    private func fileIno(for reference: AudiobookshelfAPIProtocol.TrackReference) async throws -> String {
        switch reference.kind {
        case .file(let ino):
            return ino
        case .episode(let episodeID):
            if let cached = episodeInos[episodeID] { return cached }
            guard let item = try await item(id: reference.itemID),
                  let episode = item.episodes.first(where: { $0.id == episodeID }) else {
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.invalidTrackReference"))
            }
            for episode in item.episodes { episodeInos[episode.id] = episode.audioFile.ino }
            return episode.audioFile.ino
        }
    }

    // MARK: Listening progress

    public func mediaProgress() async throws -> [AudiobookshelfMediaProgress] {
        let payload = try await authorizedJSON(path: "/api/me")
        guard let dictionary = payload as? [String: Any] else {
            throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
        }
        let list = dictionary["mediaProgress"] as? [[String: Any]] ?? []
        return list.compactMap(AudiobookshelfMediaProgress.init(json:))
    }

    /// 整本书 / 一集的进度;`currentTime` 是整本书时间轴上的位置。
    public func updateMediaProgress(
        itemID: String,
        episodeID: String?,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool
    ) async throws {
        var path = "/api/me/progress/\(AudiobookshelfAPIProtocol.encodedPathComponent(itemID))"
        if let episodeID {
            path += "/\(AudiobookshelfAPIProtocol.encodedPathComponent(episodeID))"
        }
        var body: [String: Any] = [
            "currentTime": currentTime,
            "isFinished": isFinished,
        ]
        if duration > 0 {
            body["duration"] = duration
            body["progress"] = isFinished ? 1 : min(1, max(0, currentTime / duration))
        }
        _ = try await authorizedJSON(path: path, method: "PATCH", body: body, allowsEmptyBody: true)
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
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if Self.isAuthenticationFailure(http.statusCode) {
                if attempt == 0, try await recoverSession(after: request) { continue }
                throw AudiobookshelfServiceError.authenticationFailed
            }
            guard (200...299).contains(http.statusCode) else {
                throw AudiobookshelfServiceError.badServerResponse(http.statusCode)
            }
            if data.isEmpty, allowsEmptyBody { return [String: Any]() }
            do {
                return try JSONSerialization.jsonObject(with: data)
            } catch {
                if allowsEmptyBody { return [String: Any]() }
                throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
            }
        }
        throw AudiobookshelfServiceError.authenticationFailed
    }

    private func authenticatedRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> URLRequest {
        let session = try await currentSession()
        guard let baseURL,
              let url = AudiobookshelfAPIProtocol.endpointURL(
                serverBaseURL: baseURL,
                path: path,
                queryItems: queryItems
              ) else {
            throw AudiobookshelfServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("Primuse", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    // MARK: Session

    private func currentSession() async throws -> Session {
        if let session { return session }
        return try await establishSession(refreshToken: nil)
    }

    /// 服务端拒了这个 token:刷新或重新登录一次;API 密钥没得刷新,直接报鉴权失败。
    /// 只有被拒的 token 还是当前这一个时才动会话,免得迟到的 401 作废刚换好的新会话。
    private func recoverSession(after request: URLRequest) async throws -> Bool {
        guard let session else { return true }
        let rejected = request.value(forHTTPHeaderField: "Authorization")
        guard rejected == nil || rejected == "Bearer \(session.bearer)" else { return true }
        switch session {
        case .apiKey:
            self.session = nil
            return false
        case .legacy:
            self.session = nil
            _ = try await establishSession(refreshToken: nil)
            return true
        case .jwt(_, let refreshToken):
            self.session = nil
            _ = try await establishSession(refreshToken: refreshToken)
            return true
        }
    }

    private func establishSession(refreshToken: String?) async throws -> Session {
        if let authTask {
            let value = try await authTask.value
            return value
        }
        let task = Task { try await self.authenticate(refreshToken: refreshToken) }
        authTask = task
        defer { authTask = nil }
        let value = try await task.value
        session = value
        return value
    }

    private func authenticate(refreshToken: String?) async throws -> Session {
        if usesAPIKey {
            guard let secret, !secret.isEmpty else { throw AudiobookshelfServiceError.missingCredential }
            return .apiKey(secret)
        }
        if let refreshToken, !refreshToken.isEmpty {
            do {
                return try await exchangeTokens(path: "/auth/refresh", body: nil, headers: ["x-refresh-token": refreshToken])
            } catch AudiobookshelfServiceError.authenticationFailed {
                // 刷新令牌过期或被吊销:用账号密码重新登录。
            }
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let secret, !secret.isEmpty else {
            throw AudiobookshelfServiceError.missingCredential
        }
        return try await exchangeTokens(path: "/login", body: ["username": username, "password": secret], headers: [:])
    }

    private func exchangeTokens(path: String, body: [String: Any]?, headers: [String: String]) async throws -> Session {
        guard let baseURL,
              let url = AudiobookshelfAPIProtocol.endpointURL(serverBaseURL: baseURL, path: path) else {
            throw AudiobookshelfServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 没有 cookie jar 的客户端要刷新令牌写进响应体,否则它只在 cookie 里。
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.setValue("Primuse", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } else {
            request.httpBody = Data("{}".utf8)
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.loginMissingHTTPResponse"))
        }
        if Self.isAuthenticationFailure(http.statusCode) {
            throw AudiobookshelfServiceError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw AudiobookshelfServiceError.badServerResponse(http.statusCode)
        }
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.loginMissingToken"))
        }
        return try Self.session(fromLoginPayload: dictionary)
    }

    /// 登录 / 刷新响应里的 token。2.26 起是 `user.accessToken`(+ `user.refreshToken`),
    /// 旧版本只有 `user.token`;两种都在时用新式的。
    private static func session(fromLoginPayload payload: [String: Any]) throws -> Session {
        let user = payload["user"] as? [String: Any] ?? payload
        if let access = absNonemptyString(user["accessToken"]) {
            return .jwt(accessToken: access, refreshToken: absNonemptyString(user["refreshToken"]))
        }
        if let token = absNonemptyString(user["token"]) {
            return .legacy(token: token)
        }
        throw AudiobookshelfServiceError.invalidResponse(PMString("error.catalog.loginMissingToken"))
    }

    /// 测试用:登录响应能不能解出 token,以及解出的是哪一类。
    public static func bearerToken(fromLoginPayload payload: [String: Any]) -> (token: String, refreshToken: String?, isLegacy: Bool)? {
        guard let session = try? session(fromLoginPayload: payload) else { return nil }
        switch session {
        case .apiKey(let key): return (key, nil, false)
        case .legacy(let token): return (token, nil, true)
        case .jwt(let access, let refresh): return (access, refresh, false)
        }
    }

    private static func isAuthenticationFailure(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
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

// MARK: - JSON helpers

func absNonemptyString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// ino 在不同版本里是字符串或数字。
func absIDString(_ value: Any?) -> String? {
    if let string = absNonemptyString(value) { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func absInt(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
    return nil
}

func absInt64(_ value: Any?) -> Int64? {
    if let int = value as? Int64 { return int }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string.trimmingCharacters(in: .whitespaces)) }
    return nil
}

func absDouble(_ value: Any?) -> Double? {
    if let double = value as? Double, double.isFinite { return double }
    if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
    if let string = value as? String, let double = Double(string.trimmingCharacters(in: .whitespaces)), double.isFinite {
        return double
    }
    return nil
}

/// 服务端的时间全是毫秒时间戳;顺便认 ISO 字符串。
func absDate(_ value: Any?) -> Date? {
    if let milliseconds = absDouble(value), milliseconds > 0 {
        return Date(timeIntervalSince1970: milliseconds > 10_000_000_000 ? milliseconds / 1_000 : milliseconds)
    }
    guard let string = absNonemptyString(value) else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}
