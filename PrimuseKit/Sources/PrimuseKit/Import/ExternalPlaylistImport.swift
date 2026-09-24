import Foundation

// 从其他音乐 App 导入歌单：认链接、拼请求、解响应、解析文本清单。
// 这里只有纯逻辑（Linux 上可测），真正发请求在 App 里的 ExternalPlaylistFetcher。
//
// 用到的都是各家网页端自己在用的公开接口，没有开放平台授权：
// - 只读公开歌单的文字信息（歌名/歌手/专辑/时长），不取音频、不登录、不预置抓取；
// - 接口随时可能变，失败时界面要引导用户改用「粘贴文本清单」。

public enum ExternalPlaylistPlatform: String, Codable, Sendable, CaseIterable, Identifiable {
    case netease
    case qqMusic = "qqmusic"
    case kuwo
    /// 波点属于酷我，分享链接跳转后若带出酷我歌单 id 就按酷我取。未拿到真实分享链接验证过。
    case bodian

    public var id: String { rawValue }
}

public struct ExternalPlaylistTrack: Codable, Hashable, Sendable {
    public var title: String
    public var artists: [String]
    public var album: String?
    /// 秒。
    public var duration: Double?
    public var externalID: String?

    public init(title: String, artists: [String], album: String? = nil, duration: Double? = nil, externalID: String? = nil) {
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.externalID = externalID
    }

    public var artistLine: String { artists.joined(separator: " / ") }

    public var matchSubject: ExternalTrackMatchPolicy.Subject {
        .init(title: title, artists: artists, duration: duration)
    }
}

public struct ExternalPlaylist: Sendable, Hashable {
    public var name: String
    public var platform: ExternalPlaylistPlatform?
    public var tracks: [ExternalPlaylistTrack]

    public init(name: String, platform: ExternalPlaylistPlatform?, tracks: [ExternalPlaylistTrack]) {
        self.name = name
        self.platform = platform
        self.tracks = tracks
    }
}

public enum ExternalPlaylistError: Error, Equatable, Sendable {
    /// 文本里没有认得出的歌单链接。
    case unrecognizedLink
    /// 歌单不存在、已删除，或者是私密歌单（没登录读不到）。
    case notFoundOrPrivate
    /// 平台返回的内容和预期结构对不上 —— 多半是接口改了。
    case unexpectedResponse
    case empty
}

// MARK: - Links

public struct ExternalPlaylistLink: Hashable, Sendable {
    public let platform: ExternalPlaylistPlatform
    public let playlistID: String

    public init(platform: ExternalPlaylistPlatform, playlistID: String) {
        self.platform = platform
        self.playlistID = playlistID
    }

    public enum Detection: Hashable, Sendable {
        case playlist(ExternalPlaylistLink)
        /// 短链接：跟随跳转后用最终地址再认一次。
        case needsRedirect(URL, ExternalPlaylistPlatform)
        case none
    }

    /// 从分享文案或链接里认出歌单。分享文案通常是「分享xx创建的歌单「名字」: https://…」。
    public static func detect(in text: String) -> Detection {
        for url in urls(in: text) {
            let detection = detect(url: url)
            if detection != .none { return detection }
        }
        return .none
    }

    public static func detect(url: URL) -> Detection {
        guard let host = url.host?.lowercased() else { return .none }
        let path = url.path
        // 网易云用 hash 路由：music.163.com/#/playlist?id=123
        let fragmentQuery = url.fragment.flatMap { URLComponents(string: "https://x" + ($0.hasPrefix("/") ? $0 : "/" + $0)) }
        func query(_ name: String) -> String? {
            let items = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                + (fragmentQuery?.queryItems ?? [])
            return items.first { $0.name == name }?.value
        }
        func numeric(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.allSatisfy(\.isASCIIDigit) else { return nil }
            return value
        }
        func number(after marker: String, in text: String) -> String? {
            guard let range = text.range(of: marker) else { return nil }
            let digits = text[range.upperBound...].prefix(while: \.isASCIIDigit)
            return digits.isEmpty ? nil : String(digits)
        }

        if host == "163cn.tv" || host == "163cn.link" || host.hasSuffix(".163cn.tv") {
            return .needsRedirect(url, .netease)
        }
        if host.hasSuffix("music.163.com") {
            let fragmentPath = fragmentQuery?.path ?? ""
            guard path.contains("playlist") || fragmentPath.contains("playlist") else { return .none }
            if let id = numeric(query("id")) { return .playlist(.init(platform: .netease, playlistID: id)) }
            if let id = number(after: "playlist/", in: path) { return .playlist(.init(platform: .netease, playlistID: id)) }
            return .none
        }

        if host.hasSuffix("y.qq.com") || host == "url.cn" {
            if path.contains("fcgi-bin/u") || host == "url.cn" {
                return .needsRedirect(url, .qqMusic)
            }
            if let id = number(after: "playlist/", in: path) {
                return .playlist(.init(platform: .qqMusic, playlistID: id))
            }
            if path.contains("taoge") || path.contains("details") || path.contains("playlist") {
                if let id = numeric(query("id")) ?? numeric(query("disstid")) {
                    return .playlist(.init(platform: .qqMusic, playlistID: id))
                }
            }
            return .none
        }

        if host.hasSuffix("kuwo.cn") && !host.hasPrefix("bodian") {
            if let id = number(after: "playlist_detail/", in: path) ?? number(after: "playlist/", in: path) {
                return .playlist(.init(platform: .kuwo, playlistID: id))
            }
            if path.contains("playlist"), let id = numeric(query("pid")) ?? numeric(query("id")) {
                return .playlist(.init(platform: .kuwo, playlistID: id))
            }
            return .none
        }

        if host.contains("bodian") {
            if let id = number(after: "playlist_detail/", in: path)
                ?? number(after: "playlist/", in: path)
                ?? numeric(query("pid"))
                ?? numeric(query("playlistId"))
                ?? numeric(query("playlistid"))
                ?? (path.contains("playlist") ? numeric(query("id")) : nil) {
                return .playlist(.init(platform: .bodian, playlistID: id))
            }
            return .needsRedirect(url, .bodian)
        }
        return .none
    }

    static func urls(in text: String) -> [URL] {
        var result: [URL] = []
        var searchStart = text.startIndex
        while let range = text.range(of: "http", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let tail = text[range.lowerBound...]
            let candidate = tail.prefix { character in
                !character.isWhitespace && !"\"'<>（）()「」【】，,。".contains(character)
            }
            if let url = URL(string: String(candidate)), url.host != nil {
                result.append(url)
            }
            searchStart = candidate.endIndex
            if searchStart == range.lowerBound { searchStart = range.upperBound }
        }
        return result
    }
}

// MARK: - Requests

public struct ExternalPlaylistRequest: Hashable, Sendable {
    public let url: URL
    public let headers: [String: String]
}

public enum ExternalPlaylistRequests {
    public static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// 网易云歌单详情：`trackIds` 是全量的，`tracks` 只带前一部分，缺的用 `netEaseSongDetails` 补。
    public static func netEasePlaylist(id: String) -> ExternalPlaylistRequest {
        request("https://music.163.com/api/v6/playlist/detail?id=\(id)&n=100000&s=0", referer: "https://music.163.com/")
    }

    public static let netEaseSongDetailBatchSize = 200

    public static func netEaseSongDetails(ids: [String]) -> ExternalPlaylistRequest {
        let list = "[" + ids.joined(separator: ",") + "]"
        let encoded = list.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? list
        return request("https://music.163.com/api/song/detail/?ids=\(encoded)", referer: "https://music.163.com/")
    }

    public static let qqPageSize = 500

    public static func qqPlaylist(id: String, begin: Int) -> ExternalPlaylistRequest {
        request(
            "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlymusic=0&format=json"
                + "&disstid=\(id)&song_begin=\(begin)&song_num=\(qqPageSize)",
            referer: "https://y.qq.com/"
        )
    }

    public static let kuwoPageSize = 100

    /// 酷我（波点同源）歌单分页，`page` 从 0 开始。
    public static func kuwoPlaylist(id: String, page: Int) -> ExternalPlaylistRequest {
        request(
            "https://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(id)&pn=\(page)&rn=\(kuwoPageSize)"
                + "&encode=utf8&keyset=pl2012&identity=kuwo&vipver=MUSIC_9.0.5.0_W1&newver=1",
            referer: "https://www.kuwo.cn/"
        )
    }

    private static func request(_ string: String, referer: String) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(
            url: URL(string: string)!,
            headers: ["User-Agent": browserUserAgent, "Referer": referer]
        )
    }
}

// MARK: - Responses

public enum ExternalPlaylistDecoder {
    public struct NetEasePlaylist: Sendable, Equatable {
        public var name: String
        /// 全量曲目 id，按歌单顺序。
        public var trackIDs: [String]
        /// 详情里已经带了的曲目。
        public var tracksByID: [String: ExternalPlaylistTrack]
    }

    public static func netEasePlaylist(_ data: Data) throws -> NetEasePlaylist {
        let root = try object(data)
        if let code = int(root["code"]), code != 200 { throw ExternalPlaylistError.notFoundOrPrivate }
        guard let playlist = root["playlist"] as? [String: Any] else { throw ExternalPlaylistError.notFoundOrPrivate }
        let name = string(playlist["name"]) ?? ""
        var tracksByID: [String: ExternalPlaylistTrack] = [:]
        var orderFromTracks: [String] = []
        for raw in (playlist["tracks"] as? [[String: Any]]) ?? [] {
            guard let track = netEaseTrack(raw, artistsKey: "ar", albumKey: "al", durationKey: "dt"),
                  let id = track.externalID else { continue }
            tracksByID[id] = track
            orderFromTracks.append(id)
        }
        var trackIDs = ((playlist["trackIds"] as? [[String: Any]]) ?? []).compactMap { idString($0["id"]) }
        if trackIDs.isEmpty { trackIDs = orderFromTracks }
        return NetEasePlaylist(name: name, trackIDs: trackIDs, tracksByID: tracksByID)
    }

    /// `/api/song/detail/?ids=[...]` 的响应。
    public static func netEaseSongDetails(_ data: Data) throws -> [String: ExternalPlaylistTrack] {
        let root = try object(data)
        guard let songs = root["songs"] as? [[String: Any]] else { throw ExternalPlaylistError.unexpectedResponse }
        var result: [String: ExternalPlaylistTrack] = [:]
        for raw in songs {
            // 新旧两种字段名都认：v3 用 ar/al/dt，老接口用 artists/album/duration。
            let track = netEaseTrack(raw, artistsKey: "ar", albumKey: "al", durationKey: "dt")
                ?? netEaseTrack(raw, artistsKey: "artists", albumKey: "album", durationKey: "duration")
            if let track, let id = track.externalID { result[id] = track }
        }
        return result
    }

    private static func netEaseTrack(
        _ raw: [String: Any],
        artistsKey: String,
        albumKey: String,
        durationKey: String
    ) -> ExternalPlaylistTrack? {
        guard let title = string(raw["name"]), !title.isEmpty,
              let artistsRaw = raw[artistsKey] as? [[String: Any]] else { return nil }
        let artists = artistsRaw.compactMap { string($0["name"]) }.filter { !$0.isEmpty }
        let album = (raw[albumKey] as? [String: Any]).flatMap { string($0["name"]) }
        let milliseconds = double(raw[durationKey])
        return ExternalPlaylistTrack(
            title: title,
            artists: artists,
            album: album?.isEmpty == false ? album : nil,
            duration: milliseconds.map { $0 / 1000 },
            externalID: idString(raw["id"])
        )
    }

    public struct Page: Sendable, Equatable {
        public var name: String
        public var total: Int
        public var tracks: [ExternalPlaylistTrack]
    }

    public static func qqPlaylistPage(_ data: Data) throws -> Page {
        let root = try object(data)
        guard let list = (root["cdlist"] as? [[String: Any]])?.first else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let songs = (list["songlist"] as? [[String: Any]]) ?? []
        let tracks = songs.compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["songname"]) ?? string(raw["name"]) ?? string(raw["title"]),
                  !title.isEmpty else { return nil }
            let artists = ((raw["singer"] as? [[String: Any]]) ?? []).compactMap { string($0["name"]) }
            let album = string(raw["albumname"]) ?? (raw["album"] as? [String: Any]).flatMap { string($0["name"]) }
            return ExternalPlaylistTrack(
                title: htmlUnescaped(title),
                artists: artists.map(htmlUnescaped),
                album: album.flatMap { $0.isEmpty ? nil : htmlUnescaped($0) },
                duration: double(raw["interval"]),
                externalID: string(raw["songmid"]) ?? idString(raw["songid"])
            )
        }
        let total = int(list["total_song_num"]) ?? int(list["songnum"]) ?? tracks.count
        return Page(name: htmlUnescaped(string(list["dissname"]) ?? ""), total: total, tracks: tracks)
    }

    public static func kuwoPlaylistPage(_ data: Data) throws -> Page {
        let root = try object(data)
        if let result = string(root["result"]), result != "ok" { throw ExternalPlaylistError.notFoundOrPrivate }
        guard let songs = root["musiclist"] as? [[String: Any]] else { throw ExternalPlaylistError.notFoundOrPrivate }
        let tracks = songs.compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["name"]).map(htmlUnescaped), !title.isEmpty else { return nil }
            let artistField = htmlUnescaped(string(raw["artist"]) ?? "")
            let artists = artistField.components(separatedBy: "&")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let album = string(raw["album"]).map(htmlUnescaped)
            return ExternalPlaylistTrack(
                title: title,
                artists: artists,
                album: album?.isEmpty == false ? album : nil,
                duration: double(raw["duration"]),
                externalID: idString(raw["id"])
            )
        }
        let total = int(root["total"]) ?? tracks.count
        return Page(name: htmlUnescaped(string(root["title"]) ?? ""), total: total, tracks: tracks)
    }

    // MARK: Helpers

    private static func object(_ data: Data) throws -> [String: Any] {
        // QQ 音乐对不存在/私密的歌单直接回空响应体。
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            throw ExternalPlaylistError.unexpectedResponse
        }
        return object
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func idString(_ value: Any?) -> String? {
        if let value = value as? NSNumber { return value.stringValue }
        if let value = value as? String, !value.isEmpty { return value }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }

    static func htmlUnescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, replacement) in [
            ("&amp;", "&"), ("&apos;", "'"), ("&#39;", "'"), ("&quot;", "\""),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}

// MARK: - Text list

/// 粘贴进来的文本清单，一行一首。默认「歌名 - 歌手」（GoMusic 等歌单转换工具的输出格式），
/// 也可以切成「歌手 - 歌名」。没有分隔符的一行整行当歌名。
public enum ExternalPlaylistTextParser {
    public enum Order: String, Sendable, CaseIterable {
        case titleFirst
        case artistFirst
    }

    public static let maximumLines = 5000

    public static func parse(_ text: String, order: Order = .titleFirst) -> [ExternalPlaylistTrack] {
        var tracks: [ExternalPlaylistTrack] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard tracks.count < maximumLines else { break }
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            line = strippedNumbering(line)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // 表格粘贴：制表符分列时前两列就是两个字段。
            if line.contains("\t") {
                let columns = line.components(separatedBy: "\t")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if columns.count >= 2 {
                    tracks.append(track(first: columns[0], second: columns[1], order: order))
                    continue
                }
            }
            if let (first, second) = split(line, order: order) {
                tracks.append(track(first: first, second: second, order: order))
            } else {
                tracks.append(ExternalPlaylistTrack(title: line, artists: []))
            }
        }
        return tracks.filter { !$0.title.isEmpty }
    }

    private static let separators = [" - ", " – ", " — ", " － ", "－", " -", "- "]

    /// 歌名在前时按最后一个分隔符切（歌名里可能带 " - "），歌手在前时按第一个切。
    private static func split(_ line: String, order: Order) -> (String, String)? {
        for separator in separators {
            let range = order == .titleFirst
                ? line.range(of: separator, options: .backwards)
                : line.range(of: separator)
            guard let range else { continue }
            let first = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let second = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !first.isEmpty, !second.isEmpty else { continue }
            return (first, second)
        }
        return nil
    }

    private static func track(first: String, second: String, order: Order) -> ExternalPlaylistTrack {
        let (title, artist) = order == .titleFirst ? (first, second) : (second, first)
        let artists = artist.components(separatedBy: CharacterSet(charactersIn: "/／、;；&＆"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ExternalPlaylistTrack(title: title, artists: artists)
    }

    /// 去掉行首的「12. 」「12、」「(12) 」「12 」序号。纯数字的歌名（"1989"）不动。
    private static func strippedNumbering(_ line: String) -> String {
        var index = line.startIndex
        var sawParen = false
        if index < line.endIndex, line[index] == "(" || line[index] == "（" {
            sawParen = true
            index = line.index(after: index)
        }
        let digitsStart = index
        while index < line.endIndex, line[index].isASCIIDigit { index = line.index(after: index) }
        guard index > digitsStart, line.distance(from: digitsStart, to: index) <= 4,
              index < line.endIndex else { return line }
        let marker = line[index]
        let terminators: Set<Character> = sawParen ? [")", "）"] : [".", "、", ")", "）", ":", "："]
        if terminators.contains(marker) {
            return line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
