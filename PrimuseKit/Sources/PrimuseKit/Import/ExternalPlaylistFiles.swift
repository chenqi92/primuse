import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// 第三批来源：Deezer、B 站、YouTube 三个平台，以及其他播放器导出的歌单文件
// （CSV、Apple Music 的 txt/xml、pls、xspf、wpl）。约定同 ExternalPlaylistImport.swift。

// MARK: - Requests

extension ExternalPlaylistRequests {
    /// Deezer 官方公开接口，不用登录也不用密钥。
    public static func deezerPlaylist(id: String) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(url: URL(string: "https://api.deezer.com/playlist/\(id)")!, headers: [:])
    }

    public static let deezerPageSize = 100

    public static func deezerTracks(id: String, index: Int) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(
            url: URL(string: "https://api.deezer.com/playlist/\(id)/tracks?index=\(index)&limit=\(deezerPageSize)")!,
            headers: [:]
        )
    }

    public static let bilibiliMenuPageSize = 100

    public static func bilibiliMenu(id: String, page: Int) -> ExternalPlaylistRequest {
        bilibili("https://www.bilibili.com/audio/music-service-c/web/song/of-menu?sid=\(id)&pn=\(page)&ps=\(bilibiliMenuPageSize)")
    }

    public static func bilibiliMenuInfo(id: String) -> ExternalPlaylistRequest {
        bilibili("https://www.bilibili.com/audio/music-service-c/web/menu/info?sid=\(id)")
    }

    /// 收藏夹接口每页最多 20 条。
    public static let bilibiliFavoritesPageSize = 20

    public static func bilibiliFavorites(id: String, page: Int) -> ExternalPlaylistRequest {
        bilibili("https://api.bilibili.com/x/v3/fav/resource/list?media_id=\(id)&pn=\(page)&ps=\(bilibiliFavoritesPageSize)&platform=web")
    }

    private static func bilibili(_ string: String) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(
            url: URL(string: string)!,
            headers: ["User-Agent": desktopUserAgent, "Referer": "https://www.bilibili.com/"]
        )
    }

    public static func youtubePlaylistPage(id: String) -> ExternalPlaylistRequest {
        ExternalPlaylistRequest(
            url: URL(string: "https://www.youtube.com/playlist?list=\(id)&hl=en")!,
            headers: ["User-Agent": desktopUserAgent, "Accept-Language": "en"]
        )
    }

    /// 歌单页只带前 100 条，后面的用页面给出的续页令牌向网页自己用的 browse 接口要。
    public static func youtubeContinuation(token: String, clientVersion: String) -> (request: ExternalPlaylistRequest, body: Data) {
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": clientVersion, "hl": "en"]],
            "continuation": token,
        ]
        return (
            ExternalPlaylistRequest(
                url: URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!,
                headers: ["User-Agent": desktopUserAgent, "Content-Type": "application/json"]
            ),
            (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        )
    }
}

// MARK: - Responses

extension ExternalPlaylistDecoder {
    /// `/playlist/{id}`：歌单名；`/playlist/{id}/tracks`：`data` + `total` + `next`。
    public static func deezerPlaylistName(_ data: Data) throws -> String {
        let root = try object(data)
        if root["error"] != nil { throw ExternalPlaylistError.notFoundOrPrivate }
        return string(root["title"]) ?? ""
    }

    public static func deezerTracksPage(_ data: Data) throws -> Page {
        let root = try object(data)
        if root["error"] != nil { throw ExternalPlaylistError.notFoundOrPrivate }
        let tracks = ((root["data"] as? [[String: Any]]) ?? []).compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["title"]), !title.isEmpty else { return nil }
            let artist = (raw["artist"] as? [String: Any]).flatMap { string($0["name"]) }
            return ExternalPlaylistTrack(
                title: title,
                artists: artist.map { [$0] } ?? [],
                album: (raw["album"] as? [String: Any]).flatMap { string($0["title"]) },
                duration: double(raw["duration"]),
                externalID: idString(raw["id"])
            )
        }
        return Page(name: "", total: int(root["total"]) ?? tracks.count, tracks: tracks)
    }

    /// 音频区歌单：`author` 形如「初音未来, MEIKO · Mitchie M」（歌手 · 制作人）。
    public static func bilibiliMenuPage(_ data: Data) throws -> Page {
        let root = try object(data)
        guard int(root["code"]) == 0, let body = root["data"] as? [String: Any] else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let tracks = ((body["data"] as? [[String: Any]]) ?? []).compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["title"]).map(htmlUnescaped), !title.isEmpty else { return nil }
            var artists = splitArtists(string(raw["author"]) ?? "", separators: ["·", ",", "，", "、"])
            if artists.isEmpty, let uploader = string(raw["uname"]), !uploader.isEmpty { artists = [uploader] }
            return ExternalPlaylistTrack(
                title: title,
                artists: artists,
                duration: double(raw["duration"]),
                externalID: idString(raw["id"])
            )
        }
        return Page(name: "", total: int(body["totalSize"]) ?? tracks.count, tracks: tracks)
    }

    public static func bilibiliMenuName(_ data: Data) -> String? {
        guard let root = try? object(data), let body = root["data"] as? [String: Any] else { return nil }
        return string(body["title"])
    }

    /// 收藏夹：条目是视频，标题交给 `VideoTitleInterpretation` 拆。`hasMore` 决定是否翻页。
    public static func bilibiliFavoritesPage(_ data: Data) throws -> (page: Page, hasMore: Bool) {
        let root = try object(data)
        guard int(root["code"]) == 0, let body = root["data"] as? [String: Any] else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let info = body["info"] as? [String: Any]
        let tracks = ((body["medias"] as? [[String: Any]]) ?? []).compactMap { raw -> ExternalPlaylistTrack? in
            guard let title = string(raw["title"]).map(htmlUnescaped), !title.isEmpty,
                  title != "已失效视频" else { return nil }
            let uploader = (raw["upper"] as? [String: Any]).flatMap { string($0["name"]) }
            return VideoTitleInterpretation.track(
                videoTitle: title,
                channel: uploader,
                duration: double(raw["duration"]),
                externalID: string(raw["bvid"]) ?? idString(raw["id"])
            )
        }
        let page = Page(
            name: info.flatMap { string($0["title"]) } ?? "",
            total: info.flatMap { int($0["media_count"]) } ?? tracks.count,
            tracks: tracks
        )
        let hasMore = (body["has_more"] as? Bool) ?? ((body["has_more"] as? NSNumber)?.boolValue ?? false)
        return (page, hasMore)
    }

    public struct YouTubePage: Sendable, Equatable {
        public var name: String
        public var tracks: [ExternalPlaylistTrack]
        public var continuation: String?
        public var clientVersion: String?
    }

    /// 歌单页里的 `ytInitialData`：条目是 `lockupViewModel`（2026 年起的新结构）。
    public static func youtubePlaylistPage(_ html: String) throws -> YouTubePage {
        guard let root = embeddedJSONObject(after: "var ytInitialData = ", in: html) else {
            throw ExternalPlaylistError.notFoundOrPrivate
        }
        let (tracks, continuation) = youtubeItems(in: root)
        guard !tracks.isEmpty else { throw ExternalPlaylistError.notFoundOrPrivate }
        var name = ""
        if let titleRange = html.range(of: "<title>"),
           let end = html.range(of: "</title>", range: titleRange.upperBound..<html.endIndex) {
            name = htmlUnescaped(String(html[titleRange.upperBound..<end.lowerBound]))
            if name.hasSuffix(" - YouTube") { name = String(name.dropLast(" - YouTube".count)) }
        }
        var clientVersion: String?
        if let marker = html.range(of: "\"INNERTUBE_CLIENT_VERSION\":\"") {
            clientVersion = String(html[marker.upperBound...].prefix { $0 != "\"" })
        }
        return YouTubePage(name: name, tracks: tracks, continuation: continuation, clientVersion: clientVersion)
    }

    /// browse 续页的响应。
    public static func youtubeContinuationPage(_ data: Data) throws -> (tracks: [ExternalPlaylistTrack], continuation: String?) {
        let root = try object(data)
        return youtubeItems(in: root)
    }

    /// 找到第一个装着 `lockupViewModel` 的数组：按顺序取条目，同一个数组里的
    /// `continuationItemViewModel` 就是这个列表的续页令牌。
    static func youtubeItems(in root: Any) -> (tracks: [ExternalPlaylistTrack], continuation: String?) {
        guard let items = firstArray(in: root, containing: "lockupViewModel") else { return ([], nil) }
        var tracks: [ExternalPlaylistTrack] = []
        var continuation: String?
        for item in items {
            guard let item = item as? [String: Any] else { continue }
            if let lockup = item["lockupViewModel"] as? [String: Any] {
                if let track = youtubeTrack(lockup) { tracks.append(track) }
            } else if let next = item["continuationItemViewModel"] {
                continuation = firstString(in: next, forKey: "token")
            }
        }
        return (tracks, continuation)
    }

    private static func youtubeTrack(_ lockup: [String: Any]) -> ExternalPlaylistTrack? {
        let metadata = dig(lockup, ["metadata", "lockupMetadataViewModel"]) as? [String: Any]
        guard let title = (metadata?["title"] as? [String: Any]).flatMap({ string($0["content"]) }),
              !title.isEmpty, title != "[Deleted video]", title != "[Private video]" else { return nil }
        let rows = dig(metadata, ["metadata", "contentMetadataViewModel", "metadataRows"]) as? [[String: Any]]
        let channel = ((rows?.first?["metadataParts"] as? [[String: Any]])?.first)
            .flatMap { dig($0, ["text", "content"]) as? String }
        let durationText = allStrings(in: lockup["contentImage"] as Any).first { text in
            text.contains(":") && text.allSatisfy { $0.isNumber || $0 == ":" }
        }
        return VideoTitleInterpretation.track(
            videoTitle: title,
            channel: channel,
            duration: durationText.flatMap(clockDuration),
            externalID: string(lockup["contentId"])
        )
    }

    /// 「4:01」「1:02:03」→ 秒。
    static func clockDuration(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func firstArray(in value: Any, containing key: String) -> [Any]? {
        if let array = value as? [Any] {
            if array.contains(where: { ($0 as? [String: Any])?[key] != nil }) { return array }
            for element in array { if let found = firstArray(in: element, containing: key) { return found } }
        } else if let dictionary = value as? [String: Any] {
            for child in dictionary.values { if let found = firstArray(in: child, containing: key) { return found } }
        }
        return nil
    }

    private static func firstString(in value: Any, forKey key: String) -> String? {
        if let dictionary = value as? [String: Any] {
            if let found = dictionary[key] as? String { return found }
            for child in dictionary.values { if let found = firstString(in: child, forKey: key) { return found } }
        } else if let array = value as? [Any] {
            for element in array { if let found = firstString(in: element, forKey: key) { return found } }
        }
        return nil
    }

    private static func allStrings(in value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(allStrings) }
        if let array = value as? [Any] { return array.flatMap(allStrings) }
        return []
    }
}

// MARK: - Video titles

/// 视频标题（YouTube、B 站收藏夹）不分歌名和歌手，这里给出几种读法：
/// 「A - B」两种顺序都给；《歌名》按书名号取；「【歌手】歌名」取括号里的当歌手；
/// 频道名是「歌手 - Topic」或「歌手VEVO」时就是歌手本人。
public enum VideoTitleInterpretation {
    public static func track(
        videoTitle: String,
        channel: String?,
        duration: Double?,
        externalID: String?
    ) -> ExternalPlaylistTrack {
        let readings = subjects(videoTitle: videoTitle, channel: channel, duration: duration)
        let primary = readings.first ?? .init(title: videoTitle, artists: [], duration: duration)
        var track = ExternalPlaylistTrack(
            title: primary.title,
            artists: primary.artists,
            duration: duration,
            externalID: externalID
        )
        track.alternateSubjects = Array(readings.dropFirst())
        return track
    }

    public static func subjects(videoTitle: String, channel: String?, duration: Double?) -> [ExternalTrackMatchPolicy.Subject] {
        var title = videoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「Artist - Song | Official Video」：竖线后面是附注。
        if let bar = title.range(of: " | ") ?? title.range(of: "｜") {
            title = String(title[..<bar.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        let artistChannel = channel.flatMap(channelArtist)
        var result: [ExternalTrackMatchPolicy.Subject] = []
        func add(_ songTitle: String, _ artists: [String]) {
            let cleanedTitle = songTitle.trimmingCharacters(in: .whitespaces)
            guard !cleanedTitle.isEmpty else { return }
            let subject = ExternalTrackMatchPolicy.Subject(title: cleanedTitle, artists: artists, duration: duration)
            if !result.contains(subject) { result.append(subject) }
        }

        // 【歌手】歌名 / [歌手] 歌名
        var body = title
        var bracketArtist: String?
        for (open, close) in [("【", "】"), ("[", "]")] where body.hasPrefix(open) {
            if let end = body.range(of: close) {
                bracketArtist = String(body[body.index(after: body.startIndex)..<end.lowerBound])
                body = String(body[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            break
        }

        // 《歌名》
        if let open = body.range(of: "《"), let close = body.range(of: "》", range: open.upperBound..<body.endIndex) {
            let song = String(body[open.upperBound..<close.lowerBound])
            let before = String(body[..<open.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " -–—:：|"))
            let artists = [before].filter { !$0.isEmpty } + [bracketArtist, artistChannel].compactMap { $0 }
            add(song, artists.isEmpty ? [] : [artists[0]])
        }

        for separator in [" - ", " – ", " — ", " － ", "－"] {
            guard let range = body.range(of: separator) else { continue }
            let left = String(body[..<range.lowerBound])
            let right = String(body[range.upperBound...])
            add(right, ExternalPlaylistDecoder.splitArtists(withoutBrackets(left), separators: [",", "，", "、", " & ", " x ", " X ", " feat. ", " ft. "]))
            add(left, ExternalPlaylistDecoder.splitArtists(withoutBrackets(right), separators: [",", "，", "、", " & "]))
            break
        }

        if let bracketArtist { add(body, [bracketArtist]) }
        if let artistChannel { add(body, [artistChannel]) }
        add(body, [])
        return result
    }

    /// 歌手那一侧的「【高音质】」「(Official Video)」之类附注整段去掉。
    static func withoutBrackets(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if "(（[【［《〔".contains(character) { depth += 1; continue }
            if ")）]】］》〕".contains(character) { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 「周杰伦 - Topic」「ShakiraVEVO」是自动生成的歌手频道，频道名就是歌手。
    static func channelArtist(_ channel: String) -> String? {
        let trimmed = channel.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(" - Topic") { return String(trimmed.dropLast(" - Topic".count)) }
        if trimmed.hasSuffix("VEVO"), trimmed.count > 4 { return String(trimmed.dropLast(4)) }
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Exported playlist files

/// 其他播放器导出的歌单文件：CSV（Exportify、TuneMyMusic、Soundiiz 等）、Apple Music/iTunes
/// 导出的 txt（制表符分隔，常见 UTF-16）与 xml（plist）、pls、xspf、wpl。
public enum ExternalPlaylistFileParser {
    public static let supportedExtensions: Set<String> = ["csv", "tsv", "txt", "xml", "pls", "xspf", "wpl"]

    public static func parse(data: Data, fileExtension: String, fileName: String, fallbackText: String? = nil) throws -> ExternalPlaylist {
        let ext = fileExtension.lowercased()
        switch ext {
        case "xml":
            if let playlist = try? iTunesXML(data, fileName: fileName) { return playlist }
            throw ExternalPlaylistError.unexpectedResponse
        case "xspf":
            return try nonEmpty(xspf(data, fileName: fileName))
        case "wpl":
            return try nonEmpty(wpl(data, fileName: fileName))
        default:
            guard let text = decodeText(data) ?? fallbackText else { throw ExternalPlaylistError.unexpectedResponse }
            if ext == "pls" { return try nonEmpty(pls(text, fileName: fileName)) }
            if let table = delimitedTable(text, fileName: fileName, preferComma: ext == "csv") { return try nonEmpty(table) }
            // 没有认得出的表头：当成「歌名 - 歌手」文本清单。
            return try nonEmpty(ExternalPlaylist(name: fileName, platform: nil, tracks: ExternalPlaylistTextParser.parse(text)))
        }
    }

    private static func nonEmpty(_ playlist: ExternalPlaylist) throws -> ExternalPlaylist {
        guard !playlist.tracks.isEmpty else { throw ExternalPlaylistError.empty }
        return playlist
    }

    /// 带 BOM 的 UTF-8/UTF-16，或者无 BOM 的 UTF-8。别的编码（GB18030 等）交给调用方兜底。
    public static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian).map(dropBOM) }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian).map(dropBOM) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        // 无 BOM 的 UTF-16：ASCII 字符间夹着 0 字节。
        if data.count > 4, data.prefix(64).enumerated().filter({ $0.offset % 2 == 1 && $0.element == 0 }).count > 8 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func dropBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    // MARK: CSV / TSV / Apple Music txt

    private static let titleHeaders = ["track name", "title", "song", "song name", "name", "track", "歌名", "歌曲名", "歌曲", "曲名", "名称", "名稱", "标题", "標題"]
    private static let artistHeaders = ["artist name(s)", "artist name", "artist", "artists", "歌手", "艺人", "藝人", "表演者", "演出者", "艺术家", "藝術家"]
    private static let albumHeaders = ["album name", "album", "专辑", "專輯"]
    private static let millisecondHeaders = ["duration (ms)", "duration_ms", "track duration (ms)", "length (ms)"]
    private static let durationHeaders = ["duration", "time", "length", "时长", "時長", "时间", "時間"]

    static func delimitedTable(_ text: String, fileName: String, preferComma: Bool) -> ExternalPlaylist? {
        let firstLine = text.prefix { !$0.isNewline }
        let delimiter: Character = firstLine.contains("\t") && !(preferComma && firstLine.contains(",")) ? "\t" : ","
        let rows = parseDelimited(text, delimiter: delimiter)
        guard let header = rows.first else { return nil }
        let normalized = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? {
            for name in names { if let index = normalized.firstIndex(of: name) { return index } }
            return nil
        }
        guard let titleColumn = column(titleHeaders) else { return nil }
        let artistColumn = column(artistHeaders)
        let albumColumn = column(albumHeaders)
        let millisecondColumn = column(millisecondHeaders)
        let durationColumn = millisecondColumn == nil ? column(durationHeaders) : nil

        var tracks: [ExternalPlaylistTrack] = []
        for row in rows.dropFirst() {
            func field(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            guard let title = field(titleColumn) else { continue }
            var duration: Double?
            if let milliseconds = field(millisecondColumn).flatMap(Double.init) {
                duration = milliseconds / 1000
            } else if let raw = field(durationColumn) {
                duration = raw.contains(":") ? ExternalPlaylistDecoder.clockDuration(raw) : Double(raw)
            }
            tracks.append(ExternalPlaylistTrack(
                title: title,
                artists: field(artistColumn).map { ExternalPlaylistDecoder.splitArtists($0, separators: [";", "；"]) } ?? [],
                album: field(albumColumn),
                duration: duration
            ))
        }
        return ExternalPlaylist(name: fileName, platform: nil, tracks: tracks)
    }

    /// RFC 4180 风格：双引号包裹的字段里可以有分隔符、换行和成对的双引号。
    static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character.isNewline {
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(character)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    // MARK: PLS

    static func pls(_ text: String, fileName: String) -> ExternalPlaylist {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: Double] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].lowercased()
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("file"), let index = Int(key.dropFirst(4)) {
                files[index] = value
            } else if key.hasPrefix("title"), let index = Int(key.dropFirst(5)) {
                titles[index] = value
            } else if key.hasPrefix("length"), let index = Int(key.dropFirst(6)) {
                lengths[index] = Double(value)
            }
        }
        let tracks = files.keys.sorted().compactMap { index -> ExternalPlaylistTrack? in
            track(location: files[index], displayTitle: titles[index], artist: nil, album: nil,
                  duration: lengths[index].flatMap { $0 > 0 ? $0 : nil })
        }
        return ExternalPlaylist(name: fileName, platform: nil, tracks: tracks)
    }

    // MARK: XML formats

    static func xspf(_ data: Data, fileName: String) throws -> ExternalPlaylist {
        let document = try SimpleXMLDocument(data: data)
        let name = document.root.child("title")?.text ?? fileName
        let tracks = (document.root.child("trackList")?.children(named: "track") ?? []).compactMap { node in
            track(
                location: node.child("location")?.text.removingPercentEncoding ?? node.child("location")?.text,
                displayTitle: node.child("title")?.text,
                artist: node.child("creator")?.text,
                album: node.child("album")?.text,
                duration: node.child("duration").flatMap { Double($0.text) }.map { $0 / 1000 }
            )
        }
        return ExternalPlaylist(name: name, platform: nil, tracks: tracks)
    }

    static func wpl(_ data: Data, fileName: String) throws -> ExternalPlaylist {
        let document = try SimpleXMLDocument(data: data)
        let name = document.root.child("head")?.child("title")?.text ?? fileName
        let media = document.root.child("body")?.child("seq")?.children(named: "media") ?? []
        let tracks = media.compactMap { node in
            track(location: node.attributes["src"], displayTitle: nil, artist: nil, album: nil, duration: nil)
        }
        return ExternalPlaylist(name: name, platform: nil, tracks: tracks)
    }

    /// Apple Music / iTunes「导出播放列表」的 xml：`Tracks` 字典 + `Playlists[0].Playlist Items`。
    static func iTunesXML(_ data: Data, fileName: String) throws -> ExternalPlaylist {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tracksByID = root["Tracks"] as? [String: Any] else {
            throw ExternalPlaylistError.unexpectedResponse
        }
        let playlist = (root["Playlists"] as? [[String: Any]])?.first
        var ids: [String] = ((playlist?["Playlist Items"] as? [[String: Any]]) ?? []).compactMap { item in
            ExternalPlaylistDecoder.idString(item["Track ID"])
        }
        if ids.isEmpty { ids = tracksByID.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) } }
        let tracks = ids.compactMap { id -> ExternalPlaylistTrack? in
            guard let raw = tracksByID[id] as? [String: Any],
                  let title = raw["Name"] as? String, !title.isEmpty else { return nil }
            var track = ExternalPlaylistTrack(
                title: title,
                artists: (raw["Artist"] as? String).map { [$0] } ?? [],
                album: raw["Album"] as? String,
                duration: ExternalPlaylistDecoder.double(raw["Total Time"]).map { $0 / 1000 }
            )
            if let location = raw["Location"] as? String {
                track.location = URL(string: location)?.path ?? location
            }
            return track
        }
        let name = (playlist?["Name"] as? String) ?? fileName
        return ExternalPlaylist(name: name, platform: nil, tracks: tracks)
    }

    /// 只有路径没有标题时从文件名推「歌手 - 歌名」；有标题时用标题。
    private static func track(
        location: String?,
        displayTitle: String?,
        artist: String?,
        album: String?,
        duration: Double?
    ) -> ExternalPlaylistTrack? {
        let cleanedLocation = location?.trimmingCharacters(in: .whitespaces)
        var title = displayTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        var artists = artist.map { [$0] } ?? []
        if title.isEmpty, let cleanedLocation, !cleanedLocation.isEmpty {
            let base = ((cleanedLocation.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            title = base
        }
        if artists.isEmpty, let parsed = ExternalPlaylistDecoder.artistAndTitle(title), !parsed.artists.isEmpty {
            artists = parsed.artists
            title = parsed.title
        }
        guard !title.isEmpty else { return nil }
        var track = ExternalPlaylistTrack(title: title, artists: artists, album: album, duration: duration)
        track.location = cleanedLocation
        return track
    }
}

/// 只够读 xspf/wpl 的极简 DOM。
struct SimpleXMLDocument {
    final class Node {
        let name: String
        var attributes: [String: String]
        var childNodes: [Node] = []
        var text = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func child(_ name: String) -> Node? {
            childNodes.first { $0.name.lowercased() == name.lowercased() }
        }

        func children(named name: String) -> [Node] {
            childNodes.filter { $0.name.lowercased() == name.lowercased() }
        }
    }

    let root: Node

    init(data: Data) throws {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { throw ExternalPlaylistError.unexpectedResponse }
        self.root = root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = Node(name: elementName, attributes: attributeDict)
            stack.last?.childNodes.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if let node = stack.popLast() {
                node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
