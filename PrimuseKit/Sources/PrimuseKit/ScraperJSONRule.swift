import Foundation

/// A finite set of data conversions. Rules cannot call functions, evaluate expressions, or perform I/O.
public struct ScraperJSONRule: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
        case json, text, empty, none, motionArtwork
        case albumCatalogSearch, albumCatalogDetail, albumCatalogCover, albumCatalogLyrics
        case envelopeCatalogSearch, envelopeCatalogDetail, envelopeCatalogCover, envelopeCatalogLyrics
        case hashCatalogSearch, hashCatalogDetail, hashCatalogCover, hashCatalogLyrics
        case quotedCatalogSearch, quotedCatalogDetail, quotedCatalogCover, quotedCatalogLyrics
        case groupedCatalogSearch, groupedCatalogDetail, groupedCatalogCover
        case albumCatalogMotionArtwork, hashCatalogMotionArtwork
    }
    public struct Field: Codable, Equatable, Sendable {
        public var path: String?
        public var value: String?
        public var join: String?
        public var scale: Double?
        public init(path: String? = nil, value: String? = nil, join: String? = nil, scale: Double? = nil) {
            self.path = path; self.value = value; self.join = join; self.scale = scale
        }
    }
    public var format: Format
    public var path: String?
    public var fields: [String: Field]?
    public var artworkBaseURL: String?
    public var array: Bool?
    public init(format: Format = .json, path: String? = nil, fields: [String: Field]? = nil, array: Bool? = nil, artworkBaseURL: String? = nil) {
        self.format = format; self.path = path; self.fields = fields; self.array = array; self.artworkBaseURL = artworkBaseURL
    }

    public func validate() throws {
        guard (artworkBaseURL?.utf8.count ?? 0) <= 8192, (fields?.count ?? 0) <= 64, (path?.count ?? 0) <= 512,
              fields?.values.allSatisfy({ ($0.path?.count ?? 0) <= 512 && ($0.value?.utf8.count ?? 0) <= 8192
                  && ($0.join?.count ?? 0) <= 32 && ($0.scale?.isFinite ?? true) }) != false else {
            throw RuleError.invalidRule
        }
    }
    public enum RuleError: Error, LocalizedError {
        case invalidRule, invalidResponse, tooLarge, invalidPlaylist, apiStatus(Int)
        public var errorDescription: String? {
            switch self {
            case .invalidRule: "Invalid data rule"
            case .invalidResponse: "Invalid response data"
            case .tooLarge: "Response too large"
            case .invalidPlaylist: "Unsupported artwork playlist"
            case .apiStatus(let code): "Scraper API error \(code)"
            }
        }
    }
    public static let maximumBytes = 5 * 1024 * 1024
    public static let maximumItems = 1000

    public func parse(_ data: Data, externalID: String? = nil, coverURL: (String) -> String? = { _ in nil }) throws -> Any? {
        try validate()
        guard data.count <= Self.maximumBytes else { throw RuleError.tooLarge }
        if format == .empty { return [Any]() }
        if format == .none { return nil }
        let root: Any = format == .text ? String(decoding: data, as: UTF8.self) : try Self.decode(data, singleQuotedStrings: format == .quotedCatalogSearch)
        if format != .json && format != .text { return try native(root, externalID: externalID, coverURL: coverURL) }
        let selected = Self.lookup(path ?? "", in: root, externalID: externalID)
        guard let fields else { return selected }
        let rows: [Any] = array == true ? ((selected as? [Any]) ?? selected.map { [$0] } ?? []) : selected.map { [$0] } ?? []
        var outputBytes = 0
        let mapped = try rows.prefix(Self.maximumItems).map { row in
            let result = fields.reduce(into: [String: Any]()) { result, entry in
                let field = entry.value
                var value: Any? = field.value ?? Self.lookup(field.path ?? entry.key, in: row, externalID: externalID)
                if let separator = field.join, let values = value as? [Any] {
                    value = values.prefix(Self.maximumItems).map(Self.text).joined(separator: separator)
                }
                if let scale = field.scale, let number = Double(Self.text(value)) {
                    let scaled = number * scale
                    value = scaled.isFinite ? scaled : nil
                }
                if let value, !(value is NSNull) { result[entry.key] = value }
            }
            let size = try JSONSerialization.data(withJSONObject: result).count
            outputBytes += size
            guard outputBytes <= Self.maximumBytes else { throw RuleError.tooLarge }
            return result
        }
        return array == true ? mapped : mapped.first
    }

    /// JSON and JSONP are data; only the enclosed JSON is decoded, never the wrapper.
    public static func decode(_ data: Data, singleQuotedStrings: Bool = false) throws -> Any {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return json }
        if singleQuotedStrings, let normalized = normalizeQuotedData(data),
           let json = try? JSONSerialization.jsonObject(with: normalized) { return json }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")"), start < end,
              text[..<start].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_$ .".contains($0)) }),
              text[text.index(after: end)...].allSatisfy({ $0.isWhitespace || $0 == ";" }) else {
            throw RuleError.invalidResponse
        }
        return try JSONSerialization.jsonObject(with: Data(text[text.index(after: start)..<end].utf8), options: [.fragmentsAllowed])
    }

    // Some endpoints return JSON-shaped data with single-quoted strings. Only quotes are
    // normalized; the JSON decoder still rejects expressions, calls and bare keys.
    private static func normalizeQuotedData(_ data: Data) -> Data? {
        var output = Data(), quote: UInt8?, escaped = false
        for byte in data {
            if let delimiter = quote {
                if escaped {
                    if delimiter == 39 && byte == 39 { output.append(39) }
                    else { output.append(92); output.append(byte) }
                    escaped = false
                } else if byte == 92 { escaped = true }
                else if byte == delimiter { output.append(34); quote = nil }
                else if delimiter == 39 && byte == 34 { output.append(92); output.append(34) }
                else { output.append(byte) }
            } else if byte == 39 || byte == 34 {
                quote = byte; output.append(34)
            } else { output.append(byte) }
        }
        return quote == nil && !escaped ? output : nil
    }

    private static func lookup(_ path: String, in root: Any, externalID: String?) -> Any? {
        if path == "$text" { return root as? String }
        if path == "$id" { return externalID }
        if path.hasPrefix("$id.") {
            let parts = (externalID ?? "").components(separatedBy: "|")
            guard let index = Int(path.dropFirst(4)), parts.indices.contains(index) else { return nil }
            return parts[index]
        }
        if path.isEmpty || path == "$" { return root }
        let components = path.split(separator: ".")
        guard components.count <= 16 else { return nil }
        var values: [Any] = [root]
        var wildcard = false
        for component in components {
            if component == "*" { wildcard = true }
            values = Array(values.prefix(maximumItems).flatMap { value -> [Any] in
                if let dict = value as? [String: Any] { return dict[String(component)].map { [$0] } ?? [] }
                if let list = value as? [Any] {
                    if component == "*" { return Array(list.prefix(maximumItems)) }
                    if let index = Int(component), list.indices.contains(index) { return [list[index]] }
                }
                return []
            }.prefix(maximumItems))
        }
        return wildcard ? values : values.first
    }
    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    private func native(_ root: Any, externalID: String?, coverURL: (String) -> String?) throws -> Any? {
        let object = root as? [String: Any] ?? [:]
        func get(_ value: Any, _ path: String) -> Any? { Self.lookup(path, in: value, externalID: externalID) }
        func string(_ value: Any, _ paths: String...) -> String {
            paths.lazy.map { Self.text(get(value, $0)) }.first { !$0.isEmpty } ?? ""
        }
        func list(_ value: Any, _ path: String) -> [[String: Any]] { Array(((get(value, path) as? [[String: Any]]) ?? []).prefix(Self.maximumItems)) }
        func names(_ value: Any, _ path: String) -> String { list(value, path).map { Self.text($0["name"]) }.joined(separator: " / ") }
        func number(_ value: Any?) -> Double {
            guard let value = Double(Self.text(value)), value.isFinite, abs(value) < 1e15 else { return 0 }
            return value
        }
        func resized(_ cover: String, _ size: Int) -> String {
            let pattern = #"\?param=\d+y\d+$"#
            if cover.range(of: pattern, options: .regularExpression) != nil {
                return cover.replacingOccurrences(of: pattern, with: "?param=\(size)y\(size)", options: .regularExpression)
            }
            return cover.contains("?param=") || cover.isEmpty ? cover : cover + "?param=\(size)y\(size)"
        }
        let parts = (externalID ?? "").components(separatedBy: "|")
        switch format {
        case .albumCatalogMotionArtwork, .hashCatalogMotionArtwork:
            let albumCatalog = format == .albumCatalogMotionArtwork
            if let status = object[albumCatalog ? "code" : "status"], number(status) != (albumCatalog ? 200 : 1) {
                throw RuleError.apiStatus(Int(number(albumCatalog ? status : object["error_code"] ?? status)))
            }
            let path = albumCatalog ? "data.videoPlayUrl" : "data.0.dycover.h264_url"
            let raw = string(object, path, albumCatalog ? path : "data.0.dycover.h265_url")
            guard !raw.isEmpty, var url = URLComponents(string: raw) else { return [] }
            if url.scheme?.lowercased() == "http" { url.scheme = "https" }
            guard let address = url.string else { return [] }
            return [["coverUrl": address, "mimeType": "video/mp4", "kind": "video"]]
        case .motionArtwork:
            guard let url = object["url"] as? String, !url.isEmpty else { return [] }
            var result: [String: Any] = ["coverUrl": url, "kind": "video", "mimeType": "application/vnd.apple.mpegurl"]
            result["artist"] = object["artist"]; result["album"] = object["album"]
            return [result]
        case .albumCatalogSearch, .albumCatalogDetail, .albumCatalogCover:
            let songs = list(object, format == .albumCatalogSearch ? "result.songs" : "songs")
            let converted = songs.compactMap { song -> [String: Any]? in
                let id = string(song, "id")
                if format == .albumCatalogSearch && id.isEmpty { return nil }
                let album = (song["album"] ?? song["al"]) as? [String: Any] ?? [:]
                let pic = string(album, "picUrl", "blurPicUrl")
                let cover = pic.isEmpty ? coverURL(string(album, "picId_str", "picId")) ?? "" : pic
                if format == .albumCatalogCover {
                    return cover.isEmpty ? nil : ["coverUrl": resized(cover, 500), "thumbnailUrl": resized(cover, 150)]
                }
                var result: [String: Any] = ["id": id, "title": string(song, "name"),
                    "artist": names(song, song["artists"] != nil ? "artists" : "ar"), "album": string(album, "name")]
                result["durationMs"] = song["duration"] ?? song["dt"]
                result["artistAliases"] = list(song, song["artists"] != nil ? "artists" : "ar").flatMap {
                    ($0["alias"] as? [String] ?? []) + ($0["alia"] as? [String] ?? [])
                }
                if !cover.isEmpty { result["coverUrl"] = resized(cover, format == .albumCatalogSearch ? 150 : 500) }
                if let time = album["publishTime"], number(time) > 0 {
                    result["year"] = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: number(time) / 1000))
                }
                result["genres"] = song["genres"]
                return result
            }
            return format == .albumCatalogDetail ? converted.first : converted
        case .albumCatalogLyrics:
            var result: [String: Any] = [:]
            let lrc = string(object, "lrc.lyric"), yrc = string(object, "yrc.lyric")
            if !lrc.isEmpty { result["lrcContent"] = lrc }
            if !yrc.isEmpty { result["wordLevelLrc"] = Self.yrcToLRC(yrc) }
            return result.isEmpty ? nil : result
        case .envelopeCatalogSearch, .envelopeCatalogDetail, .envelopeCatalogCover:
            let songs = format == .envelopeCatalogSearch ? list(object, "req_1.data.body.song.list") : [get(object, "req_1.data.track_info") as? [String: Any] ?? [:]]
            let converted = songs.compactMap { song -> [String: Any]? in
                let mid = string(song, "mid"), albumMid = string(song, "album.mid")
                if format == .envelopeCatalogSearch && mid.isEmpty { return nil }
                let cover = albumMid.isEmpty ? "" : artworkBaseURL.map { $0 + albumMid + ".jpg" } ?? ""
                if format == .envelopeCatalogCover {
                    return cover.isEmpty ? nil : ["coverUrl": cover, "thumbnailUrl": cover.replacingOccurrences(of: "300x300", with: "150x150")]
                }
                var result: [String: Any] = ["id": mid, "title": string(song, "name"), "artist": names(song, "singer"),
                    "album": string(song, "album.name"), "durationMs": number(song["interval"]) * 1000]
                if !cover.isEmpty { result["coverUrl"] = cover }
                if let year = Int(string(song, "time_public").prefix(4)), year > 0 { result["year"] = year }
                result["trackNumber"] = song["index_album"]
                if let genre = song["genre"] { result["genres"] = [genre] }
                return result
            }
            return format == .envelopeCatalogDetail ? converted.first : converted
        case .envelopeCatalogLyrics:
            guard let code = object["retcode"] as? NSNumber, code.intValue == 0, let lyric = object["lyric"] as? String, !lyric.isEmpty else { return nil }
            return ["lrcContent": lyric]
        case .hashCatalogSearch:
            return list(object, "data.info").map { song in
                let cover = string(song, "trans_param.union_cover").replacingOccurrences(of: "{size}", with: "150")
                let duration = Self.text(song["duration"] ?? 0)
                var values = [string(song, "hash"), string(song, "album_id").isEmpty ? "0" : string(song, "album_id"), string(song, "songname"), string(song, "singername"), duration, cover]
                let albumName = string(song, "album_name", "albumname")
                if song["album_audio_id"] != nil || !albumName.isEmpty { values.append(string(song, "album_audio_id")) }
                if !albumName.isEmpty { values.append(albumName) }
                return ["id": values.joined(separator: "|"), "title": values[2], "artist": values[3],
                    "album": string(song, "album_name", "albumname"), "durationMs": number(song["duration"]) * 1000, "coverUrl": cover] as [String: Any]
            }
        case .hashCatalogLyrics:
            let candidates = list(object, "candidates").filter { !string($0, "id").isEmpty && !string($0, "accesskey").isEmpty }.prefix(5)
            return candidates.isEmpty ? nil : ["_fetchEncryptedLyrics": true, "vars": candidates.map { ["lyricId": string($0, "id"), "accessKey": string($0, "accesskey")] }]
        case .quotedCatalogSearch:
            return list(object, object["abslist"] != nil ? "abslist" : "ABSLIST").compactMap { song -> [String: Any]? in
                let id = string(song, "MUSICRID", "DC_TARGETID").replacingOccurrences(of: "MUSIC_", with: "")
                guard !id.isEmpty else { return nil }
                var cover = string(song, "web_albumpic_short", "albumpic", "pic")
                if !cover.isEmpty && !cover.hasPrefix("http") {
                    let path = cover.hasPrefix("star/") ? cover : "star/albumcover/" + cover
                    cover = artworkBaseURL.map { $0 + path } ?? ""
                }
                let title = string(song, "NAME", "SONGNAME", "name"), artist = string(song, "ARTIST", "artist"), album = string(song, "ALBUM", "album")
                let duration = number(get(song, "DURATION") ?? get(song, "duration"))
                return ["id": [id, title, artist, album, string(song, "ALBUMID", "albumid"), String(Int(duration)), cover].joined(separator: "|"),
                    "title": title, "artist": artist, "album": album, "durationMs": duration * 1000, "coverUrl": cover]
            }
        case .quotedCatalogLyrics:
            if let status = object["status"], number(status) != 200 { throw RuleError.apiStatus(Int(number(status))) }
            let rows = list(object, "data.lrclist")
            return rows.isEmpty ? nil : ["lrcContent": rows.map { "[\(Self.timestamp(number($0["time"]) * 1000))]\(Self.text($0["lineLyric"]))" }.joined(separator: "\n")]
        case .groupedCatalogSearch:
            guard Self.text(object["code"]) == "000000" else { return [] }
            return list(object, "songResultData.result").compactMap { song -> [String: Any]? in
                let id = string(song, "copyrightId", "id")
                guard !id.isEmpty else { return nil }
                let title = string(song, "name"), artist = names(song, "singers"), album = string(song, "albums.0.name"), cover = string(song, "imgItems.0.img")
                return ["id": [id, title, artist, album, string(song, "albums.0.id"), cover, "0"].joined(separator: "|"),
                    "title": title, "artist": artist, "album": album, "coverUrl": cover]
            }
        case .hashCatalogDetail, .hashCatalogCover, .quotedCatalogDetail, .quotedCatalogCover, .groupedCatalogDetail, .groupedCatalogCover:
            let hashCatalog = format == .hashCatalogDetail || format == .hashCatalogCover
            let quotedCatalog = format == .quotedCatalogDetail || format == .quotedCatalogCover
            let isCover = [.hashCatalogCover, .quotedCatalogCover, .groupedCatalogCover].contains(format)
            guard parts.count >= (hashCatalog || format == .groupedCatalogCover ? 6 : 7) else { return isCover ? [] : nil }
            let thumb = parts[quotedCatalog ? 6 : 5]
            var cover = thumb
            let replacements = hashCatalog ? [("/150/", "/400/")] : quotedCatalog ? [("/120/", "/500/"), ("/300/", "/500/")] : [("_120", "_500"), ("/120/", "/500/"), ("_400", "_800"), ("/400/", "/800/")]
            for (from, to) in replacements { cover = cover.replacingOccurrences(of: from, with: to) }
            if isCover { return cover.isEmpty ? [] : [["coverUrl": cover, "thumbnailUrl": thumb]] }
            var result = ["title": parts[hashCatalog ? 2 : 1], "artist": parts[hashCatalog ? 3 : 2], "coverUrl": cover]
            if !hashCatalog { result["album"] = parts[3] }
            else if parts.count > 7 { result["album"] = parts[7] }
            return result
        default: return nil
        }
    }

    private static func timestamp(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 86_400_000 else { return "00:00.00" }
        let seconds = milliseconds / 1000
        return String(format: "%02d:%05.2f", Int(seconds / 60), seconds.truncatingRemainder(dividingBy: 60))
    }
    private static func yrcToLRC(_ text: String) -> String {
        let header = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
        let word = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^\(]+)"#)
        return text.split(separator: "\n").prefix(20_000).compactMap { line -> String? in
            let line = String(line).trimmingCharacters(in: .newlines) as NSString
            guard let head = header.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
                  let start = Double(line.substring(with: head.range(at: 1))) else { return nil }
            let matches = word.matches(in: line as String, range: NSRange(location: NSMaxRange(head.range), length: line.length - NSMaxRange(head.range)))
            guard let last = matches.last else { return nil }
            var result = "[\(timestamp(start))]"
            for item in matches { result += "<\(timestamp(Double(line.substring(with: item.range(at: 1))) ?? 0))>" + line.substring(with: item.range(at: 3)) }
            let end = (Double(line.substring(with: last.range(at: 1))) ?? 0) + (Double(line.substring(with: last.range(at: 2))) ?? 0)
            return result + "<\(timestamp(end))>"
        }.joined(separator: "\n")
    }
}

/// Selects a bounded, square SDR rendition and a single finite MP4 resource.
public enum ScraperArtworkPlaylist {
    public static func resolve(_ data: Data) throws -> (reference: String, complete: Bool) {
        guard data.count <= ScraperJSONRule.maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw ScraperJSONRule.RuleError.invalidPlaylist
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U", lines.count <= 10_000 else { throw ScraperJSONRule.RuleError.invalidPlaylist }
        func attributes(_ line: String) -> [String: String] {
            let regex = try! NSRegularExpression(pattern: #"([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)"#)
            let ns = line as NSString
            return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).reduce(into: [:]) { result, match in
                result[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            var variants: [(url: String, side: Double, bandwidth: Double, avc: Bool)] = []
            for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") && index + 1 < lines.count {
                let attrs = attributes(lines[index])
                let size = (attrs["RESOLUTION"] ?? "").split(separator: "x").compactMap { Double($0) }
                let codec = attrs["CODECS"] ?? ""
                guard size.count == 2, size.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1080 }),
                      abs(size[0] / size[1] - 1) < 0.1, let bandwidth = Double(attrs["BANDWIDTH"] ?? ""),
                      bandwidth.isFinite, bandwidth > 0, bandwidth <= 8_000_000,
                      attrs["VIDEO-RANGE"] == nil || attrs["VIDEO-RANGE"] == "SDR",
                      codec.hasPrefix("avc1") || codec.hasPrefix("hvc1"), !lines[index + 1].hasPrefix("#") else { continue }
                variants.append((lines[index + 1], max(size[0], size[1]), bandwidth, codec.hasPrefix("avc1")))
            }
            let bounded = variants.filter { $0.side <= 960 }
            let candidates = (bounded.isEmpty ? variants : bounded).sorted {
                if $0.avc != $1.avc { return $0.avc }
                if $0.side != $1.side { return $0.side > $1.side }
                return $0.bandwidth < $1.bandwidth
            }
            guard let chosen = candidates.first else { throw ScraperJSONRule.RuleError.invalidPlaylist }
            return (chosen.url, false)
        }
        guard lines.contains("#EXT-X-ENDLIST") else { throw ScraperJSONRule.RuleError.invalidPlaylist }
        var durations: [Double] = [], media: [String] = [], maps: [String] = []
        for line in lines {
            if line.hasPrefix("#EXT-X-KEY:"), attributes(line)["METHOD"] != "NONE" { throw ScraperJSONRule.RuleError.invalidPlaylist }
            if line.hasPrefix("#EXTINF:") {
                guard let duration = Double(String(line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false).first ?? "")), duration.isFinite, duration > 0 else {
                    throw ScraperJSONRule.RuleError.invalidPlaylist
                }
                durations.append(duration)
            }
            if line.hasPrefix("#EXT-X-MAP:") { maps.append(attributes(line)["URI"] ?? "") }
            if !line.hasPrefix("#") { media.append(line) }
        }
        guard !durations.isEmpty, durations.count <= 120, durations.count == media.count,
              durations.reduce(0, +) <= 60, let reference = media.first,
              media.allSatisfy({ $0 == reference }), maps.allSatisfy({ $0 == reference }),
              URL(string: reference)?.pathExtension.lowercased() == "mp4" else { throw ScraperJSONRule.RuleError.invalidPlaylist }
        return (reference, true)
    }
}
