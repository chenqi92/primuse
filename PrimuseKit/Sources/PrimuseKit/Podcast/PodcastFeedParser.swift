import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 一份 feed 解析出来的样子,还没有和本机已有的单集合并(合并见 `PodcastFeedMerge`)。
public struct PodcastFeed: Sendable, Hashable {
    public var title: String
    public var author: String?
    public var summary: String?
    public var artworkURL: URL?
    public var websiteURL: URL?
    public var language: String?
    public var categories: [String]
    public var isSerial: Bool
    public var isExplicit: Bool
    /// `itunes:new-feed-url`:节目搬家了,以后去新地址取。
    public var newFeedURL: URL?
    public var items: [PodcastFeedItem]
    /// XML 中途坏掉、只读到一部分时为真。
    public var isPartial: Bool

    public init(
        title: String = "",
        author: String? = nil,
        summary: String? = nil,
        artworkURL: URL? = nil,
        websiteURL: URL? = nil,
        language: String? = nil,
        categories: [String] = [],
        isSerial: Bool = false,
        isExplicit: Bool = false,
        newFeedURL: URL? = nil,
        items: [PodcastFeedItem] = [],
        isPartial: Bool = false
    ) {
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.websiteURL = websiteURL
        self.language = language
        self.categories = categories
        self.isSerial = isSerial
        self.isExplicit = isExplicit
        self.newFeedURL = newFeedURL
        self.items = items
        self.isPartial = isPartial
    }
}

public struct PodcastFeedItem: Sendable, Hashable {
    public var guid: String?
    public var title: String
    public var subtitle: String?
    /// `content:encoded` > `description` > `itunes:summary`,取最完整的那份。
    public var showNotes: String?
    public var publishedAt: Date?
    public var duration: TimeInterval?
    public var enclosureURL: URL?
    public var enclosureType: String?
    public var enclosureLength: Int64?
    public var artworkURL: URL?
    public var season: Int?
    public var number: Int?
    public var kind: PodcastEpisodeKind
    public var link: URL?
    public var chaptersURL: URL?
    public var chapters: [PodcastChapter]
    public var transcriptURL: URL?
    public var transcriptType: String?
    public var isExplicit: Bool

    public init(
        guid: String? = nil,
        title: String = "",
        subtitle: String? = nil,
        showNotes: String? = nil,
        publishedAt: Date? = nil,
        duration: TimeInterval? = nil,
        enclosureURL: URL? = nil,
        enclosureType: String? = nil,
        enclosureLength: Int64? = nil,
        artworkURL: URL? = nil,
        season: Int? = nil,
        number: Int? = nil,
        kind: PodcastEpisodeKind = .full,
        link: URL? = nil,
        chaptersURL: URL? = nil,
        chapters: [PodcastChapter] = [],
        transcriptURL: URL? = nil,
        transcriptType: String? = nil,
        isExplicit: Bool = false
    ) {
        self.guid = guid
        self.title = title
        self.subtitle = subtitle
        self.showNotes = showNotes
        self.publishedAt = publishedAt
        self.duration = duration
        self.enclosureURL = enclosureURL
        self.enclosureType = enclosureType
        self.enclosureLength = enclosureLength
        self.artworkURL = artworkURL
        self.season = season
        self.number = number
        self.kind = kind
        self.link = link
        self.chaptersURL = chaptersURL
        self.chapters = chapters
        self.transcriptURL = transcriptURL
        self.transcriptType = transcriptType
        self.isExplicit = isExplicit
    }

    /// 同一集在不同次刷新之间的身份:有 guid 用 guid,没有就用音频地址。
    public var identity: String? {
        if let guid = PodcastText.nonEmpty(guid) { return guid }
        return enclosureURL?.absoluteString
    }
}

public enum PodcastFeedError: Error, Equatable, Sendable {
    /// 拿到的不是 RSS/Atom(多半是网页或错误页)。
    case notAFeed
    /// XML 坏到一集都读不出来。
    case malformed
}

/// RSS 2.0(含 iTunes、Podcasting 2.0、Podlove 章节扩展)和 Atom 的 feed 解析。
///
/// 真实 feed 不少写得不规范:混进 HTML 实体(`&nbsp;`)、裸 `&`。第一遍失败时把这些
/// 改成合法写法再解析一次;中途坏掉但已经读到节目和若干集的,把读到的部分交出去并标 `isPartial`。
public enum PodcastFeedParser {
    public static func parse(_ data: Data, feedURL: URL? = nil) throws -> PodcastFeed {
        let first = parseOnce(data, baseURL: feedURL)
        if let feed = first.feed, first.error == nil { return feed }
        if first.sawRoot == false, first.feed == nil, !looksLikeXML(data) { throw PodcastFeedError.notAFeed }
        if let repaired = repairedXML(data) {
            let second = parseOnce(repaired, baseURL: feedURL)
            if let feed = second.feed, second.error == nil { return feed }
            if let feed = bestPartial(first.feed, second.feed) { return feed }
            if second.sawRoot == false && first.sawRoot == false { throw PodcastFeedError.notAFeed }
        } else if let feed = bestPartial(first.feed, nil) {
            return feed
        }
        throw first.sawRoot ? PodcastFeedError.malformed : PodcastFeedError.notAFeed
    }

    private static func bestPartial(_ a: PodcastFeed?, _ b: PodcastFeed?) -> PodcastFeed? {
        let candidates = [a, b].compactMap { $0 }.filter { !$0.items.isEmpty }
        guard var best = candidates.max(by: { $0.items.count < $1.items.count }) else { return nil }
        best.isPartial = true
        return best
    }

    private static func parseOnce(_ data: Data, baseURL: URL?) -> (feed: PodcastFeed?, error: Error?, sawRoot: Bool) {
        let delegate = PodcastFeedXMLDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        let feed = delegate.result()
        if ok, let feed { return (feed, nil, delegate.sawFeedRoot) }
        return (feed, parser.parserError ?? PodcastFeedError.malformed, delegate.sawFeedRoot)
    }

    private static func looksLikeXML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<?xml") || head.contains("<channel")
    }

    /// 把 XML 里不认识的 HTML 实体换成数字引用、裸 `&` 换成 `&amp;`。CDATA 段原样保留。
    static func repairedXML(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var output = ""
        output.reserveCapacity(text.utf8.count + 256)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("<![CDATA["),
               let end = text.range(of: "]]>", range: index..<text.endIndex) {
                output += text[index..<end.upperBound]
                index = end.upperBound
                continue
            }
            let character = text[index]
            if character == "&" {
                let rest = text[text.index(after: index)...]
                if let semicolon = rest.prefix(12).firstIndex(of: ";") {
                    let name = String(rest[rest.startIndex..<semicolon])
                    if xmlEntityNames.contains(name) || isNumericEntity(name) {
                        output += "&" + name + ";"
                    } else if let scalar = htmlEntities[name] {
                        output += "&#\(scalar);"
                    } else {
                        output += "&amp;" + name + ";"
                    }
                    index = text.index(after: semicolon)
                    continue
                }
                output += "&amp;"
                index = text.index(after: index)
                continue
            }
            output.append(character)
            index = text.index(after: index)
        }
        return output.data(using: .utf8)
    }

    private static let xmlEntityNames: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    private static func isNumericEntity(_ name: String) -> Bool {
        guard name.hasPrefix("#"), name.count > 1 else { return false }
        let body = name.dropFirst()
        if body.first == "x" || body.first == "X" {
            return body.count > 1 && body.dropFirst().allSatisfy(\.isHexDigit)
        }
        return body.allSatisfy(\.isNumber)
    }

    static let htmlEntities: [String: UInt32] = [
        "nbsp": 160, "copy": 169, "reg": 174, "trade": 8482, "hellip": 8230, "mdash": 8212, "ndash": 8211,
        "lsquo": 8216, "rsquo": 8217, "ldquo": 8220, "rdquo": 8221, "laquo": 171, "raquo": 187,
        "middot": 183, "bull": 8226, "deg": 176, "times": 215, "eacute": 233, "egrave": 232,
        "aacute": 225, "agrave": 224, "ouml": 246, "uuml": 252, "auml": 228, "Ouml": 214, "Uuml": 220,
        "Auml": 196, "szlig": 223, "ccedil": 231, "ntilde": 241, "euro": 8364, "pound": 163, "yen": 165,
        "iexcl": 161, "iquest": 191, "shy": 173, "zwj": 8205, "zwnj": 8204, "thinsp": 8201, "ensp": 8194, "emsp": 8195,
    ]

    // MARK: - Field parsing

    /// `itunes:duration`:`H:MM:SS`、`MM:SS`、纯秒数(可带小数)。0 和读不懂的当没写。
    public static func duration(from raw: String?) -> TimeInterval? {
        guard let raw = PodcastText.nonEmpty(raw) else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(PodcastText.trimmed(String(part))), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total > 0 ? total : nil
    }

    /// psc 章节的 `start`:`HH:MM:SS.mmm`、`MM:SS`、秒数。
    public static func chapterStart(from raw: String?) -> TimeInterval? {
        guard let raw = PodcastText.nonEmpty(raw) else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// RFC 822 日期的各种写法(星期写错、两位年份、没有秒、时区缩写),再退到 ISO 8601。
    public static func date(from raw: String?) -> Date? {
        PodcastDateParser().date(from: raw)
    }

    static func bool(from raw: String?) -> Bool {
        switch raw.map(PodcastText.trimmed)?.lowercased() {
        case "yes", "true", "explicit", "1": return true
        default: return false
        }
    }

    static func positiveInt(from raw: String?) -> Int? {
        guard let raw = PodcastText.nonEmpty(raw), let value = Int(raw), value > 0 else { return nil }
        return value
    }
}

/// 日期格式化器建一次很贵,一份 feed 几百集共用一套,并记住上一次命中的写法先试。
final class PodcastDateParser {
    private static let rfc822Formats = [
        "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm zzz",
        "d MMM yy HH:mm:ss Z", "d MMM yy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss", "d MMM yyyy",
        "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss",
    ]

    private lazy var formatters: [DateFormatter] = Self.rfc822Formats.map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
    private lazy var isoFormatters: [ISO8601DateFormatter] = [
        [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate],
    ].map { (options: ISO8601DateFormatter.Options) in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }
    private var lastHit = 0

    /// 绝大多数 feed 的写法 `30 Sep 2026 05:42:45 GMT` / `+0800`:手算,不经过格式化器。
    /// 认不出的(月份全称、少见时区缩写)返回 nil,交给后面的格式化器。
    static func fastRFC822(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 4 || parts.count == 5,
              let day = Int(parts[0]), (1...31).contains(day),
              let month = monthNumbers[parts[1].prefix(3).lowercased()], parts[1].count <= 4,
              var year = Int(parts[2]) else { return nil }
        if parts[2].count == 2 { year += year < 70 ? 2000 : 1900 }
        guard (1900...2200).contains(year) else { return nil }
        let clock = parts[3].split(separator: ":")
        guard clock.count == 2 || clock.count == 3,
              let hour = Int(clock[0]), let minute = Int(clock[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var second = 0.0
        if clock.count == 3 {
            guard let value = Double(clock[2]), value >= 0, value < 61 else { return nil }
            second = value
        }
        var offset = 0
        if parts.count == 5 {
            let zone = parts[4]
            if let named = zoneOffsets[zone.uppercased()] {
                offset = named
            } else if (zone.first == "+" || zone.first == "-"), zone.count == 5 || zone.count == 6 {
                let digits = zone.dropFirst().filter { $0 != ":" }
                guard digits.count == 4, let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)) else { return nil }
                offset = (hh * 3600 + mm * 60) * (zone.first == "-" ? -1 : 1)
            } else {
                return nil
            }
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60) + second - Double(offset)
        return Date(timeIntervalSince1970: seconds)
    }

    private static let monthNumbers: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    private static let zoneOffsets: [String: Int] = [
        "GMT": 0, "UTC": 0, "UT": 0, "Z": 0,
        "EST": -5 * 3600, "EDT": -4 * 3600, "CST": -6 * 3600, "CDT": -5 * 3600,
        "MST": -7 * 3600, "MDT": -6 * 3600, "PST": -8 * 3600, "PDT": -7 * 3600,
    ]

    /// 公历日期到 1970-01-01 的天数(Howard Hinnant 的 days_from_civil)。
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        var text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        // 星期名写错的 feed 不少,而且解析器会因此整个拒绝,直接去掉。
        if let comma = text.firstIndex(of: ","), text[..<comma].allSatisfy(\.isLetter) {
            text = String(text[text.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        if let date = Self.fastRFC822(text) { return date }
        if let date = formatters[lastHit].date(from: text) { return date }
        for (index, formatter) in formatters.enumerated() where index != lastHit {
            if let date = formatter.date(from: text) {
                lastHit = index
                return date
            }
        }
        for formatter in isoFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

// MARK: - Chapters JSON

/// Podcasting 2.0 章节文件(`podcast:chapters type="application/json+chapters"`)。
/// `toc: false` 的条目是只给配图用的,不进目录。
public enum PodcastChaptersJSON {
    private struct Document: Decodable {
        struct Entry: Decodable {
            let startTime: Double?
            let title: String?
            let img: String?
            let url: String?
            let toc: Bool?
        }
        let chapters: [Entry]?
    }

    public static func decode(_ data: Data, baseURL: URL? = nil) -> [PodcastChapter] {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        let chapters = (document.chapters ?? []).compactMap { entry -> PodcastChapter? in
            guard entry.toc != false, let start = entry.startTime, start >= 0, start.isFinite else { return nil }
            let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PodcastChapter(
                start: start,
                title: title,
                url: entry.url.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL },
                imageURL: entry.img.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            )
        }
        return PodcastChapterNormalization.normalized(chapters)
    }
}

// MARK: - Transcript

/// Podcasting 2.0 文字稿(`podcast:transcript`)交给歌词解析之前的样子。
///
/// - WebVTT / SRT 原样交出,歌词那边按字幕读(`<v 说话人>` 也认);
/// - JSON 文字稿常常一个词一段,按说话人、停顿和句末标点拼成一句一行,再写成 WebVTT;
/// - HTML / 纯文本没有时间轴,不当文字稿用。
public enum PodcastTranscriptDocument {
    /// 两段之间停顿超过这么久就另起一行。
    static let pauseBreak: Double = 1.2
    /// 一行攒到这么长,不等句末标点也换行。
    static let maximumLineLength = 100
    /// 句末标点只在一行已经有这么长时才断,免得「Yes.」「好。」各占一行。
    static let minimumSentenceLength = 16

    public static func subtitleText(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let content = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if content.first == "{" { return webVTT(fromJSON: data) }
        if content.hasPrefix("WEBVTT") || hasSubtitleTiming(content.prefix(4096)) { return String(content) }
        return nil
    }

    /// SRT 的计时行:`00:00:01,000 --> 00:00:04,000`。HTML 注释也带 `-->`,所以要连时间一起认。
    private static func hasSubtitleTiming(_ head: Substring) -> Bool {
        head.split(whereSeparator: \.isNewline).contains { line in
            line.contains("-->") && line.split(separator: " ").first.map(isTimestamp) == true
        }
    }

    private static func isTimestamp(_ token: Substring) -> Bool {
        let parts = token.split(separator: ":")
        guard (2...3).contains(parts.count), let last = parts.last else { return false }
        return parts.dropLast().allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            && last.contains(where: { $0 == "." || $0 == "," })
            && last.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
    }

    // MARK: JSON

    struct Segment: Decodable, Equatable {
        var speaker: String?
        var startTime: Double?
        var endTime: Double?
        var body: String?

        init(speaker: String? = nil, startTime: Double?, endTime: Double?, body: String?) {
            self.speaker = speaker
            self.startTime = startTime
            self.endTime = endTime
            self.body = body
        }

        private enum CodingKeys: String, CodingKey { case speaker, startTime, endTime, body }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            speaker = try? c.decodeIfPresent(String.self, forKey: .speaker)
            body = try? c.decodeIfPresent(String.self, forKey: .body)
            startTime = Self.seconds(c, .startTime)
            endTime = Self.seconds(c, .endTime)
        }

        /// 规范写数字,也见过写成字符串的。
        private static func seconds(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
            if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return value }
            if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Double(text) }
            return nil
        }
    }

    private struct Document: Decodable {
        let segments: [Segment]?
    }

    struct Cue: Equatable {
        var start: Double
        var end: Double
        var speaker: String?
        var text: String
    }

    public static func webVTT(fromJSON data: Data) -> String? {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        let cues = cues(from: document.segments ?? [])
        guard !cues.isEmpty else { return nil }
        var output = "WEBVTT\n"
        for cue in cues {
            output += "\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n"
            if let speaker = cue.speaker { output += "<v \(speaker)>" }
            output += cue.text + "\n"
        }
        return output
    }

    static func cues(from segments: [Segment]) -> [Cue] {
        let ordered = segments.enumerated().sorted {
            ($0.element.startTime ?? 0, $0.offset) < ($1.element.startTime ?? 0, $1.offset)
        }
        var cues: [Cue] = []
        var current: Cue?
        for segment in ordered.map(\.element) {
            guard let start = segment.startTime, start.isFinite, start >= 0 else { continue }
            let body = cleaned(segment.body)
            guard !body.isEmpty else { continue }
            let end = max(start, segment.endTime.flatMap { $0.isFinite ? $0 : nil } ?? start)
            // 逐词稿常常只在换人时写说话人,没写就当还是同一个人。
            let speaker = cleanedSpeaker(segment.speaker)
            if let line = current,
               (speaker != nil && speaker != line.speaker)
                || start - line.end > pauseBreak
                || line.text.count >= maximumLineLength {
                cues.append(line)
                current = nil
            }
            if var line = current {
                line.text = joined(line.text, body)
                line.end = max(line.end, end)
                current = line
            } else {
                current = Cue(start: start, end: end, speaker: speaker, text: body)
            }
            if let line = current, line.text.count >= minimumSentenceLength, endsSentence(line.text) {
                cues.append(line)
                current = nil
            }
        }
        if let current { cues.append(current) }
        return cues
    }

    private static func cleaned(_ body: String?) -> String {
        guard let body else { return "" }
        // 换行、`-->` 和尖括号在 WebVTT 正文里各有含义,换成不会被误读的写法。
        return body
            .replacingOccurrences(of: "-->", with: "→")
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func cleanedSpeaker(_ speaker: String?) -> String? {
        let name = cleaned(speaker)
        return name.isEmpty ? nil : name
    }

    private static let attachedPunctuation: Set<Character> = [
        ",", ".", "!", "?", ";", ":", ")", "]", "'", "’", "”", "…",
        "，", "。", "！", "？", "；", "：", "、", "）", "」", "』", "》",
    ]

    /// 逐词拼句:标点贴着前一个词;中日韩文字之间不加空格。
    static func joined(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        if attachedPunctuation.contains(first) || (isCJK(last) && isCJK(first)) {
            return head + tail
        }
        return head + " " + tail
    }

    private static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "’", "”", "」", "』", ")", "）"]
        guard let last = text.last(where: { !closers.contains($0) }) else { return false }
        return [".", "?", "!", "。", "？", "！", "…"].contains(last)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            // 含全角标点(`，`、`。`):它们后面接汉字也不该有空格。
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
                 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d.%03d",
            millis / 3_600_000,
            millis / 60_000 % 60,
            millis / 1000 % 60,
            millis % 1000
        )
    }
}

public enum PodcastChapterNormalization {
    /// 按开始时间排好、去掉同一时刻的重复,没标题的用「第 n 章」占位由界面决定,这里只留空串。
    public static func normalized(_ chapters: [PodcastChapter]) -> [PodcastChapter] {
        var seen = Set<Int>()
        return chapters
            .sorted { $0.start < $1.start }
            .filter { seen.insert(Int(($0.start * 10).rounded())).inserted }
    }
}

// MARK: - XML delegate

private final class PodcastFeedXMLDelegate: NSObject, XMLParserDelegate {
    private enum Namespace {
        case none, itunes, content, podcast, psc, atom, googleplay, media, unknown
    }

    private let baseURL: URL?
    private var prefixes: [String: Namespace] = [
        "itunes": .itunes, "content": .content, "podcast": .podcast, "psc": .psc,
        "atom": .atom, "googleplay": .googleplay, "media": .media,
    ]
    private var defaultNamespace: Namespace = .none
    private(set) var sawFeedRoot = false
    private var isAtom = false

    private var stack: [(ns: Namespace, name: String)] = []
    private var text = ""
    private let dates = PodcastDateParser()

    private var feed = PodcastFeed()
    private var channelSummaryDescription: String?
    private var channelItunesSummary: String?
    private var channelImageURL: URL?
    private var channelItunesImageURL: URL?

    private var item: PodcastFeedItem?
    private var itemDescription: String?
    private var itemContentEncoded: String?
    private var itemItunesSummary: String?
    private var itemItunesTitle: String?
    private var itemMediaContent: (url: URL, type: String?, length: Int64?)?
    private var inImage = false
    private var inOwner = false
    private var inAuthor = false

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func result() -> PodcastFeed? {
        guard sawFeedRoot else { return nil }
        var result = feed
        result.title = PodcastText.trimmed(result.title)
        result.summary = PodcastText.nonEmpty(channelItunesSummary) ?? PodcastText.nonEmpty(channelSummaryDescription) ?? result.summary
        // 有的平台(荔枝)节目层不写封面,只在每集上写:退回最新一集的。
        result.artworkURL = channelItunesImageURL ?? channelImageURL ?? result.artworkURL
            ?? result.items.first(where: { $0.artworkURL != nil })?.artworkURL
        var categories: [String] = []
        for category in result.categories where !categories.contains(category) { categories.append(category) }
        result.categories = categories
        guard !result.title.isEmpty || !result.items.isEmpty else { return nil }
        return result
    }

    private func resolve(_ raw: String?) -> URL? {
        guard let raw, case let value = PodcastText.trimmed(raw), !value.isEmpty else { return nil }
        // 绝大多数地址本身就合法,先直接解析;解析不了(带空格、中文)才做百分号编码。
        let parsed = URL(string: value, relativeTo: baseURL)
            ?? value.addingPercentEncoding(withAllowedCharacters: Self.urlAllowed).flatMap { URL(string: $0, relativeTo: baseURL) }
        guard let url = parsed?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// 地址里偶尔有空格或中文:能保留的保留,其余百分号编码,已有的 `%xx` 不动。
    private static let urlAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.formUnion(.urlPathAllowed)
        set.insert(charactersIn: "%#?&=:/")
        return set
    }()

    private func split(_ qualifiedName: String) -> (Namespace, String) {
        guard let colon = qualifiedName.firstIndex(of: ":") else { return (defaultNamespace, qualifiedName) }
        let prefix = String(qualifiedName[..<colon])
        let local = String(qualifiedName[qualifiedName.index(after: colon)...])
        return (prefixes[prefix] ?? .unknown, local)
    }

    private static func namespace(forURI uri: String) -> Namespace? {
        let value = uri.lowercased()
        if value.contains("itunes.com/dtds/podcast") { return .itunes }
        if value.contains("purl.org/rss/1.0/modules/content") { return .content }
        if value.contains("podcastindex.org/namespace") { return .podcast }
        if value.contains("podlove.org/simple-chapters") { return .psc }
        if value.contains("w3.org/2005/atom") { return .atom }
        if value.contains("google.com/schemas/play-podcasts") { return .googleplay }
        if value.contains("search.yahoo.com/mrss") { return .media }
        return nil
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if stack.isEmpty {
            for (key, value) in attributes {
                if key == "xmlns" {
                    defaultNamespace = Self.namespace(forURI: value) ?? .none
                } else if key.hasPrefix("xmlns:") {
                    prefixes[String(key.dropFirst(6))] = Self.namespace(forURI: value) ?? .unknown
                }
            }
            let root = elementName.lowercased()
            if root == "rss" || root == "rdf:rdf" {
                sawFeedRoot = true
                defaultNamespace = .none
            } else if root == "feed" || root.hasSuffix(":feed") {
                sawFeedRoot = true
                isAtom = true
                defaultNamespace = .none
            }
        }
        let (ns, name) = split(elementName)
        stack.append((ns, name))
        text = ""

        if isAtom {
            atomStart(ns: ns, name: name, attributes: attributes)
            return
        }

        switch (ns, name) {
        case (.none, "item"):
            item = PodcastFeedItem()
            itemDescription = nil
            itemContentEncoded = nil
            itemItunesSummary = nil
            itemItunesTitle = nil
            itemMediaContent = nil
        case (.none, "image") where item == nil:
            inImage = true
        case (.itunes, "owner"):
            inOwner = true
        case (.none, "enclosure"):
            guard item != nil, let url = resolve(attributes["url"]) else { break }
            // 一集挂多个 enclosure 时取第一个音频的。
            let type = attributes["type"]
            let isAudio = type?.lowercased().hasPrefix("audio/") ?? true
            if item?.enclosureURL == nil || (isAudio && item?.enclosureType?.lowercased().hasPrefix("audio/") != true) {
                item?.enclosureURL = url
                item?.enclosureType = type
                item?.enclosureLength = attributes["length"].flatMap { Int64(PodcastText.trimmed($0)) }.flatMap { $0 > 0 ? $0 : nil }
            }
        case (.media, "content"):
            guard item != nil, itemMediaContent == nil, let url = resolve(attributes["url"]) else { break }
            itemMediaContent = (url, attributes["type"], attributes["fileSize"].flatMap { Int64($0) })
        case (.itunes, "image"):
            let url = resolve(attributes["href"] ?? attributes["url"])
            if item != nil { item?.artworkURL = url ?? item?.artworkURL } else if let url { channelItunesImageURL = url }
        case (.itunes, "category"):
            if item == nil, let text = PodcastText.nonEmpty(attributes["text"]) {
                feed.categories.append(text)
            }
        case (.podcast, "chapters"):
            if item != nil { item?.chaptersURL = resolve(attributes["url"]) }
        case (.podcast, "transcript"):
            guard item != nil, let url = resolve(attributes["url"]) else { break }
            let type = attributes["type"]
            // 多份字幕时优先能直接显示的格式。
            if item?.transcriptURL == nil || Self.transcriptRank(type) > Self.transcriptRank(item?.transcriptType) {
                item?.transcriptURL = url
                item?.transcriptType = type
            }
        case (.psc, "chapter"):
            guard item != nil, let start = PodcastFeedParser.chapterStart(from: attributes["start"]) else { break }
            item?.chapters.append(PodcastChapter(
                start: start,
                title: attributes["title"].map(PodcastText.trimmed) ?? "",
                url: resolve(attributes["href"]),
                imageURL: resolve(attributes["image"])
            ))
        case (.podcast, "season"), (.podcast, "episode"):
            break
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let (ns, name) = stack.popLast() else { return }
        let value = PodcastText.trimmed(text)
        text = ""
        if isAtom {
            atomEnd(ns: ns, name: name, value: value)
            return
        }
        let parent = stack.last

        if var current = item {
            switch (ns, name) {
            case (.none, "item"):
                finishItem(current)
                item = nil
                return
            case (.none, "title") where parent?.name == "item":
                current.title = value
            case (.itunes, "title"):
                itemItunesTitle = value
            case (.none, "guid"):
                current.guid = value
            case (.none, "pubDate"), (.none, "pubdate"):
                current.publishedAt = dates.date(from: value)
            case (.none, "description"):
                itemDescription = value
            case (.content, "encoded"):
                itemContentEncoded = value
            case (.itunes, "summary"):
                itemItunesSummary = value
            case (.itunes, "subtitle"):
                current.subtitle = PodcastText.nonEmpty(value)
            case (.itunes, "duration"):
                current.duration = PodcastFeedParser.duration(from: value)
            case (.itunes, "season"), (.podcast, "season"):
                current.season = PodcastFeedParser.positiveInt(from: value) ?? current.season
            case (.itunes, "episode"), (.podcast, "episode"):
                current.number = PodcastFeedParser.positiveInt(from: value) ?? current.number
            case (.itunes, "episodeType"):
                current.kind = PodcastEpisodeKind(feedValue: value)
            case (.itunes, "explicit"):
                current.isExplicit = PodcastFeedParser.bool(from: value)
            case (.none, "link") where parent?.name == "item":
                current.link = resolve(value)
            default:
                break
            }
            item = current
            return
        }

        switch (ns, name) {
        case (.none, "title") where parent?.name == "channel":
            feed.title = value
        case (.none, "url") where inImage:
            channelImageURL = resolve(value)
        case (.none, "image"):
            inImage = false
        case (.none, "link") where parent?.name == "channel":
            feed.websiteURL = resolve(value) ?? feed.websiteURL
        case (.none, "description") where parent?.name == "channel":
            channelSummaryDescription = value
        case (.itunes, "summary") where parent?.name == "channel":
            channelItunesSummary = value
        case (.itunes, "author") where parent?.name == "channel":
            feed.author = PodcastText.nonEmpty(value) ?? feed.author
        case (.itunes, "name") where inOwner:
            if feed.author == nil { feed.author = PodcastText.nonEmpty(value) }
        case (.itunes, "owner"):
            inOwner = false
        case (.none, "language") where parent?.name == "channel":
            feed.language = PodcastText.nonEmpty(value)
        case (.itunes, "type") where parent?.name == "channel":
            feed.isSerial = value.lowercased() == "serial"
        case (.itunes, "explicit") where parent?.name == "channel":
            feed.isExplicit = PodcastFeedParser.bool(from: value)
        case (.itunes, "new-feed-url"):
            feed.newFeedURL = resolve(value)
        case (.none, "managingEditor") where parent?.name == "channel":
            if feed.author == nil { feed.author = Self.cleanedEditor(value) }
        default:
            break
        }
    }

    private func finishItem(_ raw: PodcastFeedItem) {
        var current = raw
        if current.title.isEmpty, let itunesTitle = PodcastText.nonEmpty(itemItunesTitle) { current.title = itunesTitle }
        if current.enclosureURL == nil, let media = itemMediaContent {
            current.enclosureURL = media.url
            current.enclosureType = media.type
            current.enclosureLength = media.length
        }
        current.showNotes = Self.richest([itemContentEncoded, itemDescription, itemItunesSummary])
        if current.subtitle == nil, current.showNotes == nil, let summary = PodcastText.nonEmpty(itemItunesSummary) {
            current.subtitle = summary
        }
        current.chapters = PodcastChapterNormalization.normalized(current.chapters)
        // 没有音频的条目(文字更新、纯链接)不是单集。
        guard current.enclosureURL != nil else { return }
        if current.title.isEmpty, let date = current.publishedAt {
            current.title = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        }
        feed.items.append(current)
    }

    /// 三份说明里挑最长的;HTML 版和纯文本版内容一样时 HTML 更长,正好保留链接。
    private static func richest(_ candidates: [String?]) -> String? {
        candidates.compactMap { PodcastText.nonEmpty($0) }.max { $0.utf8.count < $1.utf8.count }
    }

    private static func cleanedEditor(_ value: String) -> String? {
        // "mail@example.com (Name)" → "Name"
        if let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
            return PodcastText.nonEmpty(String(value[value.index(after: open)..<close]))
        }
        return value.contains("@") ? nil : PodcastText.nonEmpty(value)
    }

    private static func transcriptRank(_ type: String?) -> Int {
        switch type?.lowercased() {
        case "text/vtt": return 4
        case "application/x-subrip", "application/srt", "text/srt": return 3
        case "application/json": return 2
        case "text/html": return 1
        default: return 0
        }
    }

    // MARK: Atom

    private var atomEntry: PodcastFeedItem?
    private var atomEntrySummary: String?
    private var atomEntryContent: String?

    private func atomStart(ns: Namespace, name: String, attributes: [String: String]) {
        switch (ns, name) {
        case (.none, "entry"), (.atom, "entry"):
            atomEntry = PodcastFeedItem()
            atomEntrySummary = nil
            atomEntryContent = nil
        case (.none, "link"), (.atom, "link"):
            let rel = attributes["rel"]?.lowercased() ?? "alternate"
            let url = resolve(attributes["href"])
            if atomEntry != nil {
                if rel == "enclosure", let url, atomEntry?.enclosureURL == nil {
                    atomEntry?.enclosureURL = url
                    atomEntry?.enclosureType = attributes["type"]
                    atomEntry?.enclosureLength = attributes["length"].flatMap { Int64($0) }
                } else if rel == "alternate" {
                    atomEntry?.link = url ?? atomEntry?.link
                }
            } else if rel == "alternate" {
                feed.websiteURL = url ?? feed.websiteURL
            }
        case (.itunes, "image"):
            let url = resolve(attributes["href"])
            if atomEntry != nil { atomEntry?.artworkURL = url ?? atomEntry?.artworkURL } else if let url { channelItunesImageURL = url }
        case (.itunes, "category"):
            if atomEntry == nil, let text = PodcastText.nonEmpty(attributes["text"]) { feed.categories.append(text) }
        default:
            break
        }
    }

    private func atomEnd(ns: Namespace, name: String, value: String) {
        let parent = stack.last
        if var entry = atomEntry {
            switch (ns, name) {
            case (.none, "entry"), (.atom, "entry"):
                entry.showNotes = Self.richest([atomEntryContent, atomEntrySummary])
                atomEntry = nil
                if entry.enclosureURL != nil {
                    entry.chapters = PodcastChapterNormalization.normalized(entry.chapters)
                    feed.items.append(entry)
                }
                return
            case (.none, "title"), (.atom, "title"):
                if parent?.name == "entry" { entry.title = value }
            case (.none, "id"), (.atom, "id"):
                if parent?.name == "entry" { entry.guid = value }
            case (.none, "published"), (.atom, "published"):
                entry.publishedAt = dates.date(from: value) ?? entry.publishedAt
            case (.none, "updated"), (.atom, "updated"):
                if entry.publishedAt == nil { entry.publishedAt = dates.date(from: value) }
            case (.none, "summary"), (.atom, "summary"):
                atomEntrySummary = value
            case (.none, "content"), (.atom, "content"):
                atomEntryContent = value
            case (.itunes, "duration"):
                entry.duration = PodcastFeedParser.duration(from: value)
            default:
                break
            }
            atomEntry = entry
            return
        }
        switch (ns, name) {
        case (.none, "title"), (.atom, "title"):
            if parent?.name == "feed" { feed.title = value }
        case (.none, "subtitle"), (.atom, "subtitle"):
            if parent?.name == "feed" { channelSummaryDescription = value }
        case (.none, "name"), (.atom, "name"):
            if parent?.name == "author", stack.count == 2, feed.author == nil { feed.author = PodcastText.nonEmpty(value) }
        case (.none, "logo"), (.atom, "logo"), (.none, "icon"), (.atom, "icon"):
            if channelImageURL == nil { channelImageURL = resolve(value) }
        case (.itunes, "author"):
            feed.author = PodcastText.nonEmpty(value) ?? feed.author
        case (.itunes, "summary"):
            channelItunesSummary = value
        default:
            break
        }
    }
}
