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
actor SubsonicSource: SongScanningConnector, ServerScrobblingConnector, ServerLyricsConnector {
    let sourceID: String

    private let baseURL: URL          // 形如 https://host:4533 (+ basePath), 不含 /rest
    private let username: String
    private let salt: String
    private let token: String         // md5(password + salt)
    private let session: URLSession
    private let cacheDirectory: URL

    private var isConnected = false
    /// 服务端类型与 OpenSubsonic 能力 —— 从 ping 响应读。决定歌词走 OpenSubsonic
    /// `getLyricsBySongId`(Navidrome/Gonic)还是老 `getLyrics`(Airsonic 等非 OpenSubsonic)。
    private var serverType: String?
    private var isOpenSubsonic = false

    /// Subsonic API 协议版本。1.16.1 覆盖我们用到的全部端点;
    /// OpenSubsonic 扩展(getLyricsBySongId)在此基础上额外探测。
    private static let apiVersion = "1.16.1"
    private static let clientName = "Primuse"
    private static let pageSize = 500          // getAlbumList2 单页上限
    private static let transcodeBitRate = 320  // 转码目标码率 kbps

    init(
        sourceID: String,
        host: String,
        port: Int?,
        useSsl: Bool,
        basePath: String?,
        username: String,
        password: String
    ) {
        self.sourceID = sourceID
        self.baseURL = Self.makeBaseURL(host: host, port: port, useSsl: useSsl, basePath: basePath)
        self.username = username
        let salt = Self.randomSalt()
        self.salt = salt
        self.token = Self.md5Hex(password + salt)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
        // 家用 Navidrome 常用自签 HTTPS, 复用全局 SmartSSLDelegate 放行受信任证书。
        self.session = URLSession(configuration: configuration, delegate: SmartSSLDelegate(), delegateQueue: nil)

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_subsonic_cache_\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory
    }

    // MARK: - Connection

    func connect() async throws {
        if isConnected { return }
        guard username.isEmpty == false else { throw SourceError.authenticationFailed }
        // requestJSON 已统一校验 envelope status, status != "ok"(含认证 error 40/41)直接抛错。
        let ping: PingContainer = try await requestJSON("ping")
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
            Task {
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
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var offset = 0
                    // 逐页拉专辑列表, 再对每个专辑取曲目(getAlbum 自带完整 Child 元数据)。
                    while true {
                        let listContainer: AlbumListContainer = try await requestJSON(
                            "getAlbumList2",
                            query: [
                                URLQueryItem(name: "type", value: "alphabeticalByName"),
                                URLQueryItem(name: "size", value: String(Self.pageSize)),
                                URLQueryItem(name: "offset", value: String(offset))
                            ]
                        )
                        let albums = listContainer.albumList2?.album ?? []
                        if albums.isEmpty { break }

                        for album in albums {
                            let albumContainer: AlbumContainer = try await requestJSON(
                                "getAlbum",
                                query: [URLQueryItem(name: "id", value: album.id)]
                            )
                            let songs = albumContainer.album?.song ?? []
                            for child in songs where child.isVideo != true {
                                let song = buildSong(from: child, album: album)
                                continuation.yield(ConnectorScannedSong(song: song, displayName: child.title ?? song.title))
                            }
                        }

                        offset += albums.count
                        if albums.count < Self.pageSize { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
        if offset < 0 {
            request.setValue("bytes=\(offset)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SourceError.connectionFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
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
        _ = try? await session.data(from: url)
    }

    // MARK: - Lyrics (ServerLyricsConnector)

    func fetchServerLyrics(for path: String) async -> String? {
        guard (try? await connect()) != nil, let songID = songID(from: path) else { return nil }
        // OpenSubsonic 服务端(Navidrome/Gonic)优先用 getLyricsBySongId(可同步歌词)。
        if let lrc = await modernLyrics(songID: songID) { return lrc }
        // OpenSubsonic 服务端这就是权威结果(空 = 真没歌词), 不再退回老接口多打一轮请求。
        if isOpenSubsonic { return nil }
        // 非 OpenSubsonic 服务端(如 Airsonic): 退回老 Subsonic getLyrics(artist+title)。
        return await legacyLyrics(songID: songID)
    }

    /// OpenSubsonic getLyricsBySongId —— 结构化(可带时间轴)歌词。
    private func modernLyrics(songID: String) async -> String? {
        // requestJSON 在 status != "ok" 时抛错, try? 吞掉后返回 nil。
        guard let container: LyricsContainer = try? await requestJSON(
            "getLyricsBySongId",
            query: [URLQueryItem(name: "id", value: songID)]
        ),
        let structured = container.lyricsList?.structuredLyrics?.first,
        let lines = structured.line, !lines.isEmpty else {
            return nil
        }
        // 按"行是否带 start 时间戳"判定是否同步, 不依赖 `synced` 标志 ——
        // 实测 Navidrome 0.61 对部分曲目返回带时间轴的 line[] 却不给 synced
        // 字段(已知 bug)。有时间戳的行输出 LRC `[mm:ss.xx]`, 无时间戳的输出
        // 裸文本, 交给 LyricsParser.parseText 统一处理(它兼容 LRC 与纯文本)。
        let text = lines.compactMap { line -> String? in
            guard let value = line.value, !value.isEmpty else { return nil }
            if let start = line.start { return "\(Self.lrcTimestamp(ms: start))\(value)" }
            return value
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
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

    // MARK: - Song construction

    private func buildSong(from child: SubsonicChild, album: AlbumSummary) -> Song {
        let suffix = (child.suffix ?? (child.path.map { ($0 as NSString).pathExtension }) ?? "mp3").lowercased()
        let format = AudioFormat.from(fileExtension: suffix) ?? .mp3
        let relativePath = "/songs/\(child.id).\(suffix.isEmpty ? "mp3" : suffix)"
        let coverArtID = child.coverArt ?? album.coverArt

        // 单曲艺术家常缺标签 → Subsonic 返回 "[Unknown Artist]" 占位; 回退到
        // 专辑艺术家。真正全空的归一成 nil, 让 Primuse 走自己的"未知"处理,
        // 而不是显示字面量 "[Unknown Artist]"。专辑名同理。
        let artist = Self.cleaned(child.artist, unknown: "[Unknown Artist]")
            ?? Self.cleaned(child.displayArtist, unknown: "[Unknown Artist]")
            ?? Self.cleaned(album.artist, unknown: "[Unknown Artist]")
        let albumTitle = Self.cleaned(child.album, unknown: "[Unknown Album]")
            ?? Self.cleaned(album.name, unknown: "[Unknown Album]")

        return Song(
            id: Self.hash("\(sourceID):\(relativePath)"),
            title: child.title ?? "Unknown",
            albumID: child.albumId,
            artistID: child.artistId,
            albumTitle: albumTitle,
            artistName: artist,
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
            coverArtFileName: coverArtID.flatMap { coverArtURLString(for: $0) }
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

    /// 取图层经 SourceManager.imageURL 回调 —— 把封面引用还原成带当前凭据的
    /// 实时 getCoverArt URL。同样兜底处理历史上落盘的完整 URL(老快照里直接
    /// 存了 https://.../getCoverArt 的情况), 直接放行。
    func imageURL(for path: String) async throws -> URL? {
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
        // 老快照里持久化的完整封面 URL: 仍是合法 http(s), 直接用。
        if path.contains("://") { return URL(string: path) }
        return nil
    }

    // MARK: - HTTP / JSON plumbing

    private func requestJSON<C: SubsonicResponseContainer>(_ method: String, query: [URLQueryItem] = []) async throws -> C {
        guard let url = buildRESTURL(method: method, query: query) else {
            throw SourceError.connectionFailed("Invalid URL for \(method)")
        }
        let (data, response) = try await session.data(from: url)
        try validate(response)
        let envelope = try JSONDecoder().decode(Envelope<C>.self, from: data)
        let container = envelope.subsonicResponse
        // Subsonic 应用层错误常以 HTTP 200 + status:"failed" 返回。统一在此校验
        // envelope, status != "ok" 时抛错 —— 否则扫描会把 failed 当作"空结果"
        // 静默结束, 触发 ConnectorScanner 的 prune 把整源曲库清空。
        guard container.status == "ok" else {
            throw Self.error(from: container.error)
        }
        return container
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid server response")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw SourceError.authenticationFailed
            }
            throw SourceError.connectionFailed("HTTP \(http.statusCode)")
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
        [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json")
        ]
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

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func lrcTimestamp(ms: Int) -> String {
        let totalCentis = ms / 10
        let centis = totalCentis % 100
        let totalSeconds = totalCentis / 100
        let seconds = totalSeconds % 60
        let minutes = totalSeconds / 60
        return String(format: "[%02d:%02d.%02d]", minutes, seconds, centis)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func error(from error: SubsonicError?) -> SourceError {
        guard let error else { return .connectionFailed("Subsonic request failed") }
        if error.code == 40 || error.code == 41 { return .authenticationFailed }
        return .connectionFailed(error.message ?? "Subsonic error \(error.code)")
    }
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

private struct AlbumSummary: Decodable {
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

private struct AlbumWithSongs: Decodable {
    let song: [SubsonicChild]?
}

/// Subsonic "Child" 元素(歌曲)。字段名遵循 Subsonic/OpenSubsonic 规范。
private struct SubsonicChild: Decodable {
    let id: String
    let title: String?
    let album: String?
    let artist: String?
    let displayArtist: String?
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
    // OpenSubsonic 扩展
    let samplingRate: Int?
    let bitDepth: Int?
}

private struct LyricsContainer: SubsonicResponseContainer {
    let status: String
    let error: SubsonicError?
    let lyricsList: LyricsList?
}

private struct LyricsList: Decodable {
    let structuredLyrics: [StructuredLyrics]?
}

private struct StructuredLyrics: Decodable {
    let synced: Bool?
    let line: [StructuredLyricLine]?
}

private struct StructuredLyricLine: Decodable {
    let start: Int?     // 毫秒
    let value: String?
}
