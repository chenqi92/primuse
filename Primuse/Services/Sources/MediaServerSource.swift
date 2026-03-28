import CryptoKit
import Foundation
import PrimuseKit

actor MediaServerSource: SongScanningConnector {
    enum Kind: Sendable {
        case jellyfin
        case emby
    }

    let sourceID: String

    private let kind: Kind
    private let baseURL: URL
    private let username: String
    private let secret: String
    private let authType: SourceAuthType
    private let session: URLSession
    private let deviceID: String
    private let cacheDirectory: URL

    private var accessToken: String?
    private var userID: String?

    init(
        sourceID: String,
        kind: Kind,
        host: String,
        port: Int?,
        useSsl: Bool,
        basePath: String?,
        username: String,
        secret: String,
        authType: SourceAuthType
    ) {
        self.sourceID = sourceID
        self.kind = kind
        self.baseURL = Self.makeBaseURL(
            host: host,
            port: port,
            useSsl: useSsl,
            basePath: basePath
        )
        self.username = username
        self.secret = secret
        self.authType = authType
        self.deviceID = "primuse-\(sourceID)"

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
        self.session = URLSession(configuration: configuration)

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_media_server_cache_\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory
    }

    func connect() async throws {
        if accessToken != nil, userID != nil {
            return
        }

        switch authType {
        case .apiKey:
            accessToken = secret
            userID = try await fetchCurrentUserID()
        default:
            guard username.isEmpty == false, secret.isEmpty == false else {
                throw SourceError.authenticationFailed
            }

            let payload = [
                "Username": username,
                "Pw": secret
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
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
        accessToken = nil
        userID = nil
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

        guard let itemID = itemID(from: path),
              let accessToken else {
            throw SourceError.fileNotFound(path)
        }

        let fileExtension = (path as NSString).pathExtension.isEmpty ? "mp3" : (path as NSString).pathExtension
        let fileURL = cacheDirectory.appendingPathComponent("\(itemID).\(fileExtension)")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let remoteURL = buildURL(
            path: "/Videos/\(itemID)/stream",
            queryItems: [
                URLQueryItem(name: "Static", value: "true"),
                URLQueryItem(name: "api_key", value: accessToken)
            ]
        )

        let (data, response) = try await session.data(from: remoteURL)
        try validate(response)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
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
        guard let libraryID = libraryID(from: normalizedPath) else {
            throw SourceError.pathNotFound(path)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var startIndex = 0
                    let pageSize = 200

                    while true {
                        let result = try await fetchAudioItems(
                            parentID: libraryID,
                            startIndex: startIndex,
                            limit: pageSize
                        )

                        if result.items.isEmpty {
                            break
                        }

                        for item in result.items {
                            let song = buildSong(from: item)
                            continuation.yield(
                                ConnectorScannedSong(
                                    song: song,
                                    displayName: item.name
                                )
                            )
                        }

                        startIndex += result.items.count

                        if result.items.count < pageSize {
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func fetchLibraries() async throws -> [Library] {
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
        requiresAuth: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: buildURL(path: path, queryItems: queryItems))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (header, value) in headers(requiresAuth: requiresAuth) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
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
        let musicLibraries = libraries.filter { $0.collectionType?.lowercased() == "music" }
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

    private func buildSong(from item: AudioItem) -> Song {
        let fileExtension = audioFileExtension(for: item)
        let format = AudioFormat.from(fileExtension: fileExtension) ?? .mp3
        let artist = item.albumArtist ?? item.albumArtists?.first ?? item.artists?.first
        let year = item.productionYear ?? item.dateCreated.map { Calendar.current.component(.year, from: $0) }
        let audioStream = item.mediaStreams?.first(where: { ($0.type ?? "").caseInsensitiveCompare("Audio") == .orderedSame })
            ?? item.mediaStreams?.first
        let duration = Double(item.runTimeTicks ?? 0) / 10_000_000
        let relativePath = "/items/\(item.id).\(fileExtension)"

        return Song(
            id: hash("\(sourceID):\(relativePath)"),
            title: item.name,
            albumTitle: item.album,
            artistName: artist,
            trackNumber: item.indexNumber,
            discNumber: item.parentIndexNumber,
            duration: duration,
            fileFormat: format,
            filePath: relativePath,
            sourceID: sourceID,
            fileSize: item.mediaSources?.first?.size ?? 0,
            bitRate: audioStream?.bitRate.map { Int($0 / 1000) },
            sampleRate: audioStream?.sampleRate,
            bitDepth: audioStream?.bitDepth,
            genre: item.genres?.joined(separator: ", "),
            year: year,
            lastModified: item.dateCreated,
            coverArtFileName: coverArtURL(for: item)?.absoluteString
        )
    }

    private func coverArtURL(for item: AudioItem) -> URL? {
        guard let accessToken else { return nil }

        if let albumID = item.albumId, let albumPrimaryImageTag = item.albumPrimaryImageTag {
            return buildURL(
                path: "/Items/\(albumID)/Images/Primary",
                queryItems: [
                    URLQueryItem(name: "maxWidth", value: "480"),
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
                    URLQueryItem(name: "api_key", value: accessToken)
                ]
            )
        }

        return nil
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

    private static func makeBaseURL(
        host: String,
        port: Int?,
        useSsl: Bool,
        basePath: String?
    ) -> URL {
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseString = rawHost.contains("://") ? rawHost : "\(useSsl ? "https" : "http")://\(rawHost)"
        var url = URL(string: baseString) ?? URL(string: "\(useSsl ? "https" : "http")://\(rawHost)")!

        if let port, port > 0, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.port = port
            url = components.url ?? url
        }

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

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

private struct AudioItem: Decodable {
    let id: String
    let name: String
    let album: String?
    let albumArtist: String?
    let albumArtists: [String]?
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

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case album = "Album"
        case albumArtist = "AlbumArtist"
        case albumArtists = "AlbumArtists"
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
    }
}

private struct AudioStream: Decodable {
    let type: String?
    let bitRate: Int?
    let sampleRate: Int?
    let bitDepth: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case bitRate = "BitRate"
        case sampleRate = "SampleRate"
        case bitDepth = "BitDepth"
    }
}

private struct AudioMediaSource: Decodable {
    let size: Int64?
    let container: String?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case size = "Size"
        case container = "Container"
        case path = "Path"
    }
}
