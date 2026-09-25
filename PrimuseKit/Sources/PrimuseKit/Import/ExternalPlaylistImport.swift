import Foundation

// 从其他音乐 App 导入歌单：认链接、拼请求、解响应、解析文本清单。
// 这里只有纯逻辑（Linux 上可测），真正发请求在 App 里的 ExternalPlaylistFetcher。
//
// 用到的都是各家网页端/客户端自己在用的公开接口，没有开放平台授权：
// - 只读公开歌单的文字信息（歌名/歌手/专辑/时长），不取音频、不登录、不预置抓取；
// - 不内置任何从别家 App 里扒出来的签名密钥 —— 需要那种密钥才能拿全的（酷狗新版分享、
//   千千），只取对方分享页公开给出的部分，并标记「可能不完整」；
// - 接口随时可能变，失败时界面要引导用户改用「粘贴文本清单」。
// Apple Music 走系统 MusicKit，不在这里。

public enum ExternalPlaylistPlatform: String, Codable, Sendable, CaseIterable, Identifiable {
    case netease
    case qqMusic = "qqmusic"
    case kuwo
    /// 波点属于酷我，接口在 bd-api.kuwo.cn，要带它桌面客户端的请求头（匿名即可）。
    case bodian
    case kugou
    case migu
    /// 汽水音乐（抖音）。只能从网页版歌单页里取，最多 50 首。
    case soda
    case appleMusic = "applemusic"
    case spotify
    case deezer
    /// B 站：音频区歌单（am…）与公开收藏夹（ml…/favlist?fid=）。收藏夹里是视频标题。
    case bilibili
    /// YouTube 与 YouTube Music 共用一个歌单页；条目是视频标题。
    case youtube

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

    /// 同一条的其他读法。视频标题「A - B」分不清谁是歌手谁是歌名时两种都给，
    /// 匹配时取对得上的那一种；置灰占位只记第一种。
    public var alternateSubjects: [ExternalTrackMatchPolicy.Subject] = []
    /// 播放器导出文件（pls/wpl/xspf）里的文件路径，先按文件名对曲库。
    public var location: String? = nil

    public var artistLine: String { artists.joined(separator: " / ") }

    public var matchSubject: ExternalTrackMatchPolicy.Subject {
        .init(title: title, artists: artists, duration: duration)
    }

    public var matchSubjects: [ExternalTrackMatchPolicy.Subject] {
        [matchSubject] + alternateSubjects
    }
}

public struct ExternalPlaylist: Sendable, Hashable {
    public var name: String
    public var platform: ExternalPlaylistPlatform?
    public var tracks: [ExternalPlaylistTrack]
    /// 对方只公开了歌单的前一部分（酷狗分享页 10 首、汽水网页 50 首、Spotify 嵌入页 100 首），
    /// 拿到的条数正好顶到上限时置真，界面据此提醒用户剩下的要用文本清单补。
    public var isPartial: Bool

    public init(
        name: String,
        platform: ExternalPlaylistPlatform?,
        tracks: [ExternalPlaylistTrack],
        isPartial: Bool = false
    ) {
        self.name = name
        self.platform = platform
        self.tracks = tracks
        self.isPartial = isPartial
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
    /// 平台已经停止服务（虾米音乐 2021 年 2 月关站）。
    case discontinued
}

// MARK: - Links

public struct ExternalPlaylistLink: Hashable, Sendable {
    public let platform: ExternalPlaylistPlatform
    public let playlistID: String
    /// 取数据时还要用到的链接参数：波点的 `source`、酷狗分享页的整段签名查询串 `shareQuery`。
    public let parameters: [String: String]

    public init(platform: ExternalPlaylistPlatform, playlistID: String, parameters: [String: String] = [:]) {
        self.platform = platform
        self.playlistID = playlistID
        self.parameters = parameters
    }

    public enum Detection: Hashable, Sendable {
        case playlist(ExternalPlaylistLink)
        /// 短链接：跟随跳转后用最终地址再认一次。
        case needsRedirect(URL, ExternalPlaylistPlatform)
        /// 认出来了，但平台已经不在了（虾米）。
        case discontinued
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

        if host.hasSuffix("xiami.com") || host == "xiami.cn" || host.hasSuffix(".xiami.cn") {
            return .discontinued
        }

        // 波点：bodian.kuwo.cn 与 h5app.kuwo.cn/m/bodian/… 两种落地页。歌单 id 在
        // playlistId/pid/id 里，`source` 区分「酷我同步来的歌单」(4) 与「波点自建歌单」(5)。
        if host.contains("bodian") || (host.hasSuffix("kuwo.cn") && path.lowercased().contains("bodian")) {
            let source = query("source") ?? query("sourceType")
            let parameters = numeric(source).map { ["source": $0] } ?? [:]
            if let id = numeric(query("playlistId"))
                ?? numeric(query("playListId"))
                ?? numeric(query("pid"))
                ?? number(after: "playlist_detail/", in: path)
                ?? number(after: "playlist/", in: path)
                ?? numeric(query("id")) {
                return .playlist(.init(platform: .bodian, playlistID: id, parameters: parameters))
            }
            return host.contains("bodian") ? .needsRedirect(url, .bodian) : .none
        }

        if host.hasSuffix("kuwo.cn") {
            if let id = number(after: "playlist_detail/", in: path) ?? number(after: "playlist/", in: path) {
                return .playlist(.init(platform: .kuwo, playlistID: id))
            }
            if path.contains("playlist"), let id = numeric(query("pid")) ?? numeric(query("id")) {
                return .playlist(.init(platform: .kuwo, playlistID: id))
            }
            return .none
        }

        if host.hasSuffix("kugou.com") {
            // 手机分享的短链 t1/t4.kugou.com/xxxx 跳到 zlist.html。
            if host.range(of: #"^t\d*\.kugou\.com$"#, options: .regularExpression) != nil {
                return .needsRedirect(url, .kugou)
            }
            // 新版分享页：签名只对这一整串参数有效，原样留着去取数据。
            if path.contains("zlist"), let gcid = query("global_collection_id"), !gcid.isEmpty {
                let shareQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
                return .playlist(.init(platform: .kugou, playlistID: gcid, parameters: ["shareQuery": shareQuery]))
            }
            // 老版歌单：www.kugou.com/yy/special/single/123.html、m.kugou.com/plist/list/123。
            if let id = number(after: "special/single/", in: path) ?? number(after: "plist/list/", in: path) {
                return .playlist(.init(platform: .kugou, playlistID: id))
            }
            if let id = numeric(query("specialid")) {
                return .playlist(.init(platform: .kugou, playlistID: id))
            }
            return .none
        }

        if host.hasSuffix("migu.cn") {
            if host == "c.migu.cn" { return .needsRedirect(url, .migu) }
            let fragmentPlaylistID = fragmentQuery?.queryItems?.first { $0.name == "playlistId" }?.value
            if let id = number(after: "playlist/", in: path)
                ?? numeric(query("playlistId"))
                ?? numeric(fragmentPlaylistID)
                ?? (path.contains("playlist") ? numeric(query("id")) : nil) {
                return .playlist(.init(platform: .migu, playlistID: id))
            }
            return .none
        }

        // 汽水音乐：qishui.douyin.com/s/xxx 短链 → music.douyin.com/qishui/share/playlist?playlist_id=…；
        // 网页版 www.douyin.com/qishui/playlist/<id>。
        if host == "qishui.douyin.com" || host.hasSuffix(".qishui.com") || host == "qishui.com" {
            if let id = numeric(query("playlist_id")) {
                return .playlist(.init(platform: .soda, playlistID: id))
            }
            return .needsRedirect(url, .soda)
        }
        if host.hasSuffix("douyin.com"), path.contains("qishui") {
            if let id = numeric(query("playlist_id")) ?? number(after: "playlist/", in: path) {
                return .playlist(.init(platform: .soda, playlistID: id))
            }
            return .none
        }

        if host == "link.deezer.com" || host == "deezer.page.link" {
            return .needsRedirect(url, .deezer)
        }
        if host.hasSuffix("deezer.com") {
            if let id = number(after: "playlist/", in: path) {
                return .playlist(.init(platform: .deezer, playlistID: id))
            }
            return .none
        }

        if host == "b23.tv" || host.hasSuffix(".b23.tv") {
            return .needsRedirect(url, .bilibili)
        }
        if host.hasSuffix("bilibili.com") {
            // 音频区歌单：/audio/am10624
            if let id = number(after: "/audio/am", in: path) {
                return .playlist(.init(platform: .bilibili, playlistID: id, parameters: ["kind": "menu"]))
            }
            // 收藏夹：space…/favlist?fid=…、/list/ml…、/medialist/detail/ml…
            if let id = numeric(query("fid")) ?? number(after: "/list/ml", in: path) ?? number(after: "/detail/ml", in: path) {
                return .playlist(.init(platform: .bilibili, playlistID: id, parameters: ["kind": "fav"]))
            }
            return .none
        }

        if host.hasSuffix("youtube.com") || host == "youtu.be" {
            if let list = query("list"), !list.isEmpty,
               list.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                return .playlist(.init(platform: .youtube, playlistID: list))
            }
            return .none
        }

        if host.hasSuffix("music.apple.com") || host.hasSuffix("itunes.apple.com") {
            guard path.contains("/playlist/") else { return .none }
            if let last = url.pathComponents.last, last.hasPrefix("pl.") {
                return .playlist(.init(platform: .appleMusic, playlistID: last))
            }
            return .none
        }

        if host == "spotify.link" || host == "spoti.fi" {
            return .needsRedirect(url, .spotify)
        }
        if host.hasSuffix("spotify.com") {
            let components = url.pathComponents
            if let index = components.firstIndex(of: "playlist"), index + 1 < components.count {
                let id = components[index + 1]
                if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    return .playlist(.init(platform: .spotify, playlistID: id))
                }
            }
            return .none
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

    // 波点：桌面客户端的请求头，匿名（uid=-1）即可读公开歌单。不带这些头会回 402。
    public static let bodianPageSize = 100

    public static func bodianPlaylist(id: String, source: String, page: Int, deviceID: String) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(
            url: URL(string: "https://bd-api.kuwo.cn/api/service/playlist/\(id)/musicList?source=\(source)&pn=\(page)&rn=\(bodianPageSize)&uid=-1&token=")!,
            headers: bodianHeaders(deviceID: deviceID)
        )
    }

    public static func bodianPlaylistInfo(id: String, source: String, deviceID: String) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(
            url: URL(string: "https://bd-api.kuwo.cn/api/service/playlist/info/\(id)?source=\(source)&uid=-1&token=")!,
            headers: bodianHeaders(deviceID: deviceID)
        )
    }

    private static func bodianHeaders(deviceID: String) -> [String: String] {
        [
            "User-Agent": "Dart/3.3 (dart:io)", "plat": "win", "channel": "W1", "ver": "1.1.5",
            "svrver": "13", "api-ver": "application/json", "devid": deviceID, "qimei36": deviceID,
        ]
    }

    public static let miguPageSize = 50

    public static func miguPlaylist(id: String, page: Int) -> ExternalPlaylistRequest {
        request(
            "https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0?pageNo=\(page)&pageSize=\(miguPageSize)&playlistId=\(id)",
            referer: "https://music.migu.cn/"
        )
    }

    public static func miguPlaylistInfo(id: String) -> ExternalPlaylistRequest {
        request("https://app.c.nf.migu.cn/resource/playlist/v2.0?playlistId=\(id)", referer: "https://music.migu.cn/")
    }

    public static let kugouPageSize = 300

    /// 酷狗老版歌单（specialid）：不用签名，能分页取全。mobilecdn.kugou.com 的 HTTPS 证书
    /// 不含这个主机名，只能走 http（App 的 ATS 已允许任意加载）。
    public static func kugouSpecial(id: String, page: Int) -> ExternalPlaylistRequest {
        request(
            "http://mobilecdn.kugou.com/api/v3/special/song?specialid=\(id)&page=\(page)&pagesize=\(kugouPageSize)",
            referer: "https://m.kugou.com/"
        )
    }

    public static func kugouSpecialInfo(id: String) -> ExternalPlaylistRequest {
        request("http://mobilecdn.kugou.com/api/v3/special/info?specialid=\(id)", referer: "https://m.kugou.com/")
    }

    /// 酷狗新版分享页：签名来自分享链接本身，只能原样转交；对方只公开前 10 首。
    public static let kugouSharePreviewLimit = 10

    public static func kugouShare(query: String) -> ExternalPlaylistRequest {
        request("https://m3ws.kugou.com/zlist/list?\(query)", referer: "https://m3ws.kugou.com/")
    }

    /// 汽水音乐网页版歌单页，页面数据里带着最多 50 首。
    public static let sodaPageLimit = 50

    public static func sodaPlaylistPage(id: String) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(
            url: URL(string: "https://www.douyin.com/qishui/playlist/\(id)")!,
            headers: ["User-Agent": desktopUserAgent, "Referer": "https://www.douyin.com/qishui/"]
        )
    }

    /// Spotify 公开嵌入页，页面数据里带着最多 100 首。
    public static let spotifyEmbedLimit = 100

    public static func spotifyEmbed(id: String) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(
            url: URL(string: "https://open.spotify.com/embed/playlist/\(id)")!,
            headers: ["User-Agent": desktopUserAgent]
        )
    }

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

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

    public static func bodianPage(_ data: Data) throws -> Page {
        let root = try object(data)
        guard int(root["code"]) == 200, let body = root["data"] as? [String: Any] else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let tracks = ((body["list"] as? [[String: Any]]) ?? []).compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["name"]).map(htmlUnescaped), !title.isEmpty else { return nil }
            var artists = ((raw["artists"] as? [[String: Any]]) ?? []).compactMap { string($0["name"]) }.filter { !$0.isEmpty }
            if artists.isEmpty {
                artists = splitArtists(htmlUnescaped(string(raw["artist"]) ?? ""), separators: ["&"])
            }
            return ExternalPlaylistTrack(
                title: title,
                artists: artists,
                album: string(raw["album"]).flatMap { $0.isEmpty ? nil : htmlUnescaped($0) },
                duration: double(raw["duration"]),
                externalID: idString(raw["id"])
            )
        }
        return Page(name: "", total: int(body["total"]) ?? tracks.count, tracks: tracks)
    }

    public static func bodianPlaylistName(_ data: Data) -> String? {
        guard let root = try? object(data), let body = root["data"] as? [String: Any] else { return nil }
        return string(body["name"]).map(htmlUnescaped)
    }

    public static func miguPage(_ data: Data) throws -> Page {
        let root = try object(data)
        guard string(root["code"]) == "000000", let body = root["data"] as? [String: Any] else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let tracks = ((body["songList"] as? [[String: Any]]) ?? []).compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["songName"]), !title.isEmpty else { return nil }
            var artists = ((raw["singerList"] as? [[String: Any]]) ?? []).compactMap { string($0["name"]) }.filter { !$0.isEmpty }
            if artists.isEmpty { artists = splitArtists(string(raw["singer"]) ?? "", separators: ["|", "、"]) }
            return ExternalPlaylistTrack(
                title: title,
                artists: artists,
                album: string(raw["album"]).flatMap { $0.isEmpty ? nil : $0 },
                duration: double(raw["duration"]),
                externalID: string(raw["contentId"]) ?? idString(raw["songId"])
            )
        }
        return Page(name: "", total: int(body["totalCount"]) ?? tracks.count, tracks: tracks)
    }

    public static func miguPlaylistName(_ data: Data) -> String? {
        guard let root = try? object(data), let body = root["data"] as? [String: Any] else { return nil }
        return string(body["title"])
    }

    public static func kugouSpecialPage(_ data: Data) throws -> Page {
        let root = try object(data)
        guard let body = root["data"] as? [String: Any], let info = body["info"] as? [[String: Any]] else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let tracks = info.compactMap { raw -> ExternalPlaylistTrack? in
            guard let parsed = artistAndTitle(string(raw["filename"]) ?? string(raw["name"]) ?? "") else { return nil }
            return ExternalPlaylistTrack(
                title: parsed.title,
                artists: parsed.artists,
                album: string(raw["remark"]).flatMap { $0.isEmpty ? nil : $0 },
                duration: double(raw["duration"]),
                externalID: string(raw["hash"])
            )
        }
        return Page(name: "", total: int(body["total"]) ?? tracks.count, tracks: tracks)
    }

    public static func kugouSpecialName(_ data: Data) -> String? {
        guard let root = try? object(data), let body = root["data"] as? [String: Any] else { return nil }
        return string(body["specialname"])
    }

    /// 酷狗分享页：`list.info[].name` 是「歌手 - 歌名」，`timelen` 毫秒；歌单名在顶层 `info[0].name`。
    public static func kugouSharePage(_ data: Data) throws -> Page {
        let root = try object(data)
        guard int(root["errcode"]) == 0, let list = root["list"] as? [String: Any],
              let info = list["info"] as? [[String: Any]] else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let tracks = info.compactMap { raw -> ExternalPlaylistTrack? in
            guard let parsed = artistAndTitle(string(raw["name"]) ?? "") else { return nil }
            return ExternalPlaylistTrack(
                title: parsed.title,
                artists: parsed.artists,
                duration: double(raw["timelen"]).map { $0 / 1000 },
                externalID: string(raw["hash"])
            )
        }
        let name = ((root["info"] as? [[String: Any]])?.first).flatMap { string($0["name"]) } ?? ""
        return Page(name: name, total: int(list["count"]) ?? tracks.count, tracks: tracks)
    }

    /// 汽水音乐网页版歌单页里的 `"qishui_playlist": {keyword, music_list: [...]}`。
    public static func sodaPlaylistPage(_ html: String) throws -> Page {
        guard let playlist = embeddedJSONObject(after: "\"qishui_playlist\":", in: html) else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let tracks = ((playlist["music_list"] as? [[String: Any]]) ?? []).compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["name"]), !title.isEmpty else { return nil }
            return ExternalPlaylistTrack(
                title: title,
                artists: ((raw["artist_name_list"] as? [Any]) ?? []).compactMap { string($0) }.filter { !$0.isEmpty },
                album: string(raw["album_name"]).flatMap { $0.isEmpty ? nil : $0 },
                duration: double(raw["duration_ms"]).map { $0 / 1000 },
                externalID: idString(raw["track_id"])
            )
        }
        guard !tracks.isEmpty else { throw ExternalPlaylistError.notFoundOrPrivate }
        return Page(name: string(playlist["keyword"]) ?? "", total: tracks.count, tracks: tracks)
    }

    /// Spotify 嵌入页 `__NEXT_DATA__` 里的 `entity.trackList`：`subtitle` 是逗号连起来的歌手。
    public static func spotifyEmbedPage(_ html: String) throws -> Page {
        guard let startMarker = html.range(of: "id=\"__NEXT_DATA__\""),
              let open = html.range(of: ">", range: startMarker.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let root = try? object(Data(html[open.upperBound..<close.lowerBound].utf8)),
              let entity = dig(root, ["props", "pageProps", "state", "data", "entity"]) as? [String: Any] else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let tracks = ((entity["trackList"] as? [[String: Any]]) ?? []).compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["title"]), !title.isEmpty else { return nil }
            return ExternalPlaylistTrack(
                title: title,
                artists: splitArtists(string(raw["subtitle"]) ?? "", separators: [", "]),
                duration: double(raw["duration"]).map { $0 / 1000 },
                externalID: string(raw["uri"])
            )
        }
        return Page(name: string(entity["name"]) ?? string(entity["title"]) ?? "", total: tracks.count, tracks: tracks)
    }

    // MARK: Helpers

    /// 「歌手 - 歌名」按第一个 " - " 切开；没有分隔符时整串当歌名。
    static func artistAndTitle(_ text: String) -> (artists: [String], title: String)? {
        let trimmed = htmlUnescaped(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let range = trimmed.range(of: " - ") else { return ([], trimmed) }
        let artist = String(trimmed[..<range.lowerBound])
        let title = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return ([], trimmed) }
        return (splitArtists(artist, separators: ["、", "&"]), title)
    }

    static func splitArtists(_ text: String, separators: [String]) -> [String] {
        var parts = [text]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func dig(_ value: Any?, _ path: [String]) -> Any? {
        var current = value
        for key in path { current = (current as? [String: Any])?[key] }
        return current
    }

    /// 网页里嵌着的一段 JSON 对象：从 `marker` 之后的第一个 `{` 起，按括号配对（跳过字符串里的括号）截出来。
    static func embeddedJSONObject(after marker: String, in html: String) -> [String: Any]? {
        guard let markerRange = html.range(of: marker) else { return nil }
        let bytes = Array(html.utf8[markerRange.upperBound...])
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    let slice = Data(bytes[start...index])
                    return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
                }
            default: break
            }
        }
        return nil
    }

    static func object(_ data: Data) throws -> [String: Any] {
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

    static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    static func idString(_ value: Any?) -> String? {
        if let value = value as? NSNumber { return value.stringValue }
        if let value = value as? String, !value.isEmpty { return value }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
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
