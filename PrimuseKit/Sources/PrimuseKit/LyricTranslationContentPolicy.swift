import Foundation

public struct LyricTranslationSongContext: Hashable, Sendable {
    public let title: String?
    public let artist: String?

    public init(title: String? = nil, artist: String? = nil) {
        self.title = title
        self.artist = artist
    }
}

/// Selects sung text for language detection and machine translation without
/// changing the displayed document, its timing, or authored translations.
public enum LyricTranslationContentPolicy {
    private enum Kind: Hashable {
        case title, artist, credit, pair, blank
    }

    private static let titleLabels: Set<String> = ["ti", "title", "song", "song title", "歌名", "歌曲", "曲名"]
    private static let artistLabels: Set<String> = ["ar", "artist", "singer", "演唱", "歌手", "艺人", "藝人", "原唱", "翻唱"]
    private static let creditLabels: Set<String> = [
        "al", "album", "by", "au", "author", "re", "ve", "offset", "length", "la", "language",
        "专辑", "專輯", "词", "詞", "曲", "唱", "作词", "作詞", "作曲", "填词", "填詞", "编曲", "編曲",
        "词曲", "詞曲", "作词作曲", "作詞作曲", "制作", "製作", "制作人", "製作人", "制作统筹", "製作統籌",
        "监制", "監製", "音乐总监", "音樂總監", "制作公司", "製作公司", "混音", "混音师", "混音師", "母带", "母帶", "母带工程师",
        "录音", "錄音", "录音师", "錄音師", "录音室", "錄音室", "录音棚", "錄音棚", "人声录音", "人聲錄音",
        "和声", "和聲", "和声编写", "和聲編寫", "吉他", "贝斯", "貝斯", "鼓", "键盘", "鍵盤", "钢琴", "鋼琴",
        "弦乐", "弦樂", "弦乐编写", "弦樂編寫", "出品", "发行", "發行", "策划", "策劃", "统筹", "統籌",
        "版权", "版權", "版权提供", "版權提供", "op", "sp", "isrc", "lrc", "歌词制作", "歌詞製作",
        "lyrics", "lyrics by", "lyricist", "music", "music by", "composed by", "composer", "composition",
        "arranged by", "arranger", "arrangement", "produced by", "producer", "executive producer",
        "mix", "mixed by", "mixing", "mastering", "mastered by", "written by", "songwriter",
        "vocals", "vocal", "vocalist", "backing vocals", "background vocals", "guitar", "guitar solo",
        "bass", "drums", "keyboards", "piano", "strings", "recorded by", "recording", "engineer", "copyright",
        "作詩", "編詞", "編曲", "歌", "작사", "작곡", "편곡", "노래", "paroles", "musique",
        "企划营销", "企劃營銷",
    ]
    private static let byPrefixes = [
        "lyrics by", "music by", "composed by", "arranged by", "produced by",
        "written by", "mixed by", "mastered by", "recorded by",
    ]
    private static let productionRoles: Set<String> = [
        "制作", "製作", "录音", "錄音", "混音", "母带", "母帶", "编辑", "編輯",
        "编写", "編寫", "编配", "編配", "配唱", "和声", "和聲", "演奏", "统筹", "統籌", "监制", "監製",
    ]
    private static let productionPrefixes = [
        "", "配唱", "人声", "人聲", "弦乐", "弦樂", "和声", "和聲", "音频", "音頻",
        "数字", "數字", "联合", "聯合", "执行", "執行", "音乐", "音樂", "总", "總",
    ]
    private static let productionSuffixes = [
        "", "人", "师", "師", "室", "棚", "工作室", "团队", "團隊", "工程师", "工程師",
        "助理", "指导", "指導", "总监", "總監",
    ]
    private static let englishProductionRoles: Set<String> = [
        "recording", "mixing", "mastering", "production", "producer", "arrangement", "engineering", "editing",
    ]
    private static let englishProductionPrefixes = [
        "", "vocal ", "backing vocal ", "string ", "digital ", "audio ", "co-", "co ", "executive ", "additional ",
    ]
    private static let englishProductionSuffixes = ["", " engineer", " studio", " team", " assistant", " director"]

    /// Input may be flattened voice lines; metadata remains attached to its
    /// original row. Explicit credits can occur at either end or mid-song.
    public static func contentLines(
        in lines: [LyricLine],
        song: LyricTranslationSongContext = .init()
    ) -> [LyricLine] {
        var titles = variants(song.title, includeAliases: false)
        var artists = variants(song.artist, includeAliases: true)
        for text in lines.flatMap({ ($0.metadataLines ?? []) + [$0.text] }) {
            guard let field = field(in: text) else { continue }
            if field.kind == .title { titles.formUnion(variants(field.value, includeAliases: false)) }
            if field.kind == .artist { artists.formUnion(variants(field.value, includeAliases: true)) }
        }

        var excluded = Set<Int>()
        let kinds: [Kind?] = lines.enumerated().map { index, line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return .blank }
            if field(in: text) != nil || isCopyright(text) {
                excluded.insert(index)
                return .credit
            }
            // Word timing or a vocal part is positive evidence of sung text.
            guard !line.isWordLevel, line.voice == .primary else { return nil }
            if isTitleArtistPair(text, titles: titles, artists: artists) { return .pair }
            // Bare song names are often the chorus itself. Only consider early
            // header rows, with corroborating credits or a separate artist row.
            guard line.timestamp <= 5 else { return nil }
            let identities = variants(text, includeAliases: false)
            if !identities.isDisjoint(with: titles) { return .title }
            if !identities.isDisjoint(with: artists) { return .artist }
            return nil
        }

        func excludeHeaderBlock(_ indices: [Int], allowsStandaloneNames: Bool) {
            var block: [Int] = []
            var seen = Set<Kind>()
            for index in indices {
                guard let kind = kinds[index] else { break }
                if !allowsStandaloneNames, kind == .title || kind == .artist { break }
                // A repeated title belongs to the lyrics after the header.
                if (kind == .title || kind == .artist), seen.contains(kind) { break }
                block.append(index)
                seen.insert(kind)
                if kind == .pair { seen.formUnion([.title, .artist]) }
            }
            guard seen.contains(.credit) || seen.contains(.pair)
                || (seen.contains(.title) && seen.contains(.artist)) else { return }
            excluded.formUnion(block)
        }
        excludeHeaderBlock(Array(lines.indices), allowsStandaloneNames: true)
        excludeHeaderBlock(Array(lines.indices.reversed()), allowsStandaloneNames: false)

        return lines.enumerated().compactMap { index, line in
            guard !excluded.contains(index),
                  line.text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
            return line
        }
    }

    private static func field(in raw: String) -> (kind: Kind, value: String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        if let separator = text.firstIndex(where: { ":=".contains($0) }) {
            let label = String(text[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if titleLabels.contains(label) { return (.title, value) }
            if artistLabels.contains(label) { return (.artist, value) }
            let parts = label.replacingOccurrences(of: " and ", with: "/")
                .components(separatedBy: CharacterSet(charactersIn: "/&、"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if !parts.isEmpty, parts.allSatisfy(isCreditLabel) { return (.credit, value) }
        }
        let lower = text.lowercased()
        for prefix in byPrefixes where lower.hasPrefix(prefix + " ") {
            return (.credit, String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        // Chinese/Japanese/Korean credits also commonly use whitespace in
        // place of a colon. English nouns alone could be ordinary lyric text.
        if let space = text.firstIndex(where: \.isWhitespace) {
            let label = String(text[..<space])
            if label.unicodeScalars.contains(where: { $0.value > 0x7F }),
               isCreditLabel(label) || artistLabels.contains(label) {
                return (.credit, String(text[text.index(after: space)...]))
            }
        }
        return nil
    }

    private static func isCreditLabel(_ label: String) -> Bool {
        if isSingleCreditLabel(label) { return true }
        let components = label.replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(whereSeparator: \.isWhitespace)
        guard let first = components.first,
              first.unicodeScalars.contains(where: { $0.value > 0x7F }),
              isSingleCreditLabel(String(first)) else { return false }
        return isSingleCreditLabel(components.dropFirst().joined(separator: " "))
    }

    private static func isSingleCreditLabel(_ label: String) -> Bool {
        if creditLabels.contains(label) { return true }
        // Match complete role names, including personnel and studio variants.
        // A role word embedded in an ordinary sentence is not a credit label.
        func matches(roles: Set<String>, prefixes: [String], suffixes: [String]) -> Bool {
            for prefix in prefixes where label.hasPrefix(prefix) {
                let remainder = label.dropFirst(prefix.count)
                for suffix in suffixes where remainder.hasSuffix(suffix) {
                    if roles.contains(String(remainder.dropLast(suffix.count))) { return true }
                }
            }
            return false
        }
        return matches(roles: productionRoles, prefixes: productionPrefixes, suffixes: productionSuffixes)
            || matches(roles: englishProductionRoles, prefixes: englishProductionPrefixes, suffixes: englishProductionSuffixes)
    }

    private static func isCopyright(_ text: String) -> Bool {
        text.hasPrefix("©") || text.hasPrefix("℗")
            || text.lowercased().hasPrefix("copyright ©")
    }

    private static func identity(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    private static func variants(_ value: String?, includeAliases: Bool) -> Set<String> {
        guard let value else { return [] }
        let text = value.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let pattern = #"\([^()]*\)|\[[^\[\]]*\]"#
        var values = [text, text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)]
        if includeAliases, let expression = try? NSRegularExpression(pattern: pattern) {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) { values.append(String(text[range].dropFirst().dropLast())) }
            }
        }
        return Set(values.map(identity).filter { !$0.isEmpty })
    }

    private static func isTitleArtistPair(_ text: String, titles: Set<String>, artists: Set<String>) -> Bool {
        guard !titles.isEmpty, !artists.isEmpty else { return false }
        for split in text.indices where "-–—|/／:：".contains(text[split]) {
            let left = variants(String(text[..<split]), includeAliases: false)
            let right = variants(String(text[text.index(after: split)...]), includeAliases: false)
            if (!left.isDisjoint(with: titles) && !right.isDisjoint(with: artists))
                || (!left.isDisjoint(with: artists) && !right.isDisjoint(with: titles)) { return true }
        }
        return false
    }
}
