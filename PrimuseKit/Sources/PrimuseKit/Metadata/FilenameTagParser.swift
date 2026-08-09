import Foundation

/// 从文件名里拆出 艺术家 / 歌名 / 轨号。
///
/// 扫描器只在文件没有可用 tag 时才会退回文件名，那条路径要保守；这里相反 ──
/// 用户在标签编辑器里主动点了「一键拆分」，所以可以放开猜，猜错他当场就能看到并改。
public enum FilenameTagParser {
    /// 拆分规则。UI 把它做成可点的 chip，让用户在猜错时一键换一种解释。
    public enum Pattern: String, CaseIterable, Sendable, Hashable {
        /// `孙露 _ 一定要爱你.mp3` → 艺术家在前
        case artistFirst
        /// `一定要爱你 - 孙露.mp3` → 歌名在前
        case titleFirst
        /// `01. 一定要爱你.mp3` → 只有轨号和歌名，没有艺术家
        case trackAndTitle
        /// 整个文件名都当歌名，不拆
        case titleOnly
    }

    public struct ParsedTags: Equatable, Sendable {
        public var title: String
        public var artist: String?
        public var trackNumber: Int?

        public init(title: String, artist: String? = nil, trackNumber: Int? = nil) {
            self.title = title
            self.artist = artist
            self.trackNumber = trackNumber
        }
    }

    /// 支持的分隔符，按优先级排。全角连字符和破折号也算 —— 中文曲库里很常见。
    private static let separators = [" - ", " – ", " — ", "_", " · ", " -", "- ", "-", "–", "—"]

    /// 分隔符两侧要清掉的装饰字符，也用来判断裸数字后缀是否真的被隔开。
    private static let trimmables = " _-–—·、"
    /// 轨号后面允许的分隔符。空格单独处理 —— `01 Title` 也算命中。
    private static let trackSeparators = ".-_、"

    /// 按指定规则拆。`filename` 传完整文件名或路径最后一段都行，扩展名会被去掉。
    public static func parse(_ filename: String, pattern: Pattern) -> ParsedTags {
        let stem = normalizedStem(filename)
        guard !stem.isEmpty else { return ParsedTags(title: filename) }

        // 清理后可能为空(整个名字都是装饰字符)，那种情况退回未清理的原文 ──
        // 宁可留个怪名字，也不能把歌名清成空的。
        func title(_ value: String) -> String {
            let result = cleaned(value)
            return result.isEmpty ? stem : result
        }

        switch pattern {
        case .titleOnly:
            // 不拆字段，但重复标记仍要去掉 ── `(2)` / `_ 2` 是下载器留下的，
            // 从来不是歌名的一部分。
            return ParsedTags(title: title(stem))

        case .trackAndTitle:
            let (track, rest) = strippingLeadingTrack(stem)
            return ParsedTags(title: title(rest.isEmpty ? stem : rest), trackNumber: track)

        case .artistFirst, .titleFirst:
            let (track, body) = strippingLeadingTrack(stem)
            guard let (head, tail) = splitOnSeparator(body.isEmpty ? stem : body) else {
                return ParsedTags(title: title(stem), trackNumber: track)
            }
            let cleanedArtist = cleaned(pattern == .artistFirst ? head : tail)
            let cleanedTitle = cleaned(pattern == .artistFirst ? tail : head)
            // 拆出来有一边是空的，说明分隔符在首尾，整段当歌名更安全。
            guard !cleanedTitle.isEmpty, !cleanedArtist.isEmpty else {
                return ParsedTags(title: title(stem), trackNumber: track)
            }
            return ParsedTags(title: cleanedTitle, artist: cleanedArtist, trackNumber: track)
        }
    }

    /// 给一批文件名挑一个最可能的规则。批量整理时用它定默认值，省得用户挨个试。
    ///
    /// 判据：能拆成两段的比例够高才认为有艺术家；再看哪一侧在整批里更"收敛"
    /// ── 同一个艺术家的多首歌里，艺术家那一侧的取值数量会明显少于歌名侧。
    public static func suggestedPattern(for filenames: [String]) -> Pattern {
        let stems = filenames.map(normalizedStem).filter { !$0.isEmpty }
        guard !stems.isEmpty else { return .titleOnly }

        var heads: [String] = []
        var tails: [String] = []
        var trackOnlyCount = 0

        for stem in stems {
            let (track, body) = strippingLeadingTrack(stem)
            guard let (head, tail) = splitOnSeparator(body.isEmpty ? stem : body) else {
                if track != nil { trackOnlyCount += 1 }
                continue
            }
            heads.append(cleaned(head).lowercased())
            tails.append(cleaned(tail).lowercased())
        }

        let splittable = Double(heads.count) / Double(stems.count)
        guard splittable >= 0.6 else {
            return trackOnlyCount >= stems.count / 2 ? .trackAndTitle : .titleOnly
        }

        // 单个文件时没有统计意义，用最常见的书写习惯兜底。
        guard heads.count > 1 else { return .artistFirst }

        let headVariety = Double(Set(heads).count) / Double(heads.count)
        let tailVariety = Double(Set(tails).count) / Double(tails.count)
        // 差距太小说明两边都在变(整库多艺术家)，仍按最常见的 `艺术家 - 歌名` 猜。
        guard abs(headVariety - tailVariety) > 0.15 else { return .artistFirst }
        return headVariety < tailVariety ? .artistFirst : .titleFirst
    }

    /// 一个文件名能拆出的全部解释，UI 直接铺成候选 chip。已去重且保持规则顺序。
    public static func candidates(for filename: String) -> [(pattern: Pattern, tags: ParsedTags)] {
        var seen = Set<String>()
        return Pattern.allCases.compactMap { pattern in
            let tags = parse(filename, pattern: pattern)
            guard !tags.title.isEmpty else { return nil }
            let key = "\(tags.artist ?? "")\u{1}\(tags.title)"
            guard seen.insert(key).inserted else { return nil }
            return (pattern, tags)
        }
    }

    /// 从同目录的邻居文件名里收集可能的艺术家。同一张专辑/同一个歌手的文件夹里，
    /// 这一列的重复项就是答案。按出现次数降序，UI 取前几个当候选。
    public static func neighbouringArtists(
        from filenames: [String],
        pattern: Pattern? = nil,
        limit: Int = 4
    ) -> [String] {
        let resolved = pattern ?? suggestedPattern(for: filenames)
        guard resolved == .artistFirst || resolved == .titleFirst else { return [] }

        var counts: [String: Int] = [:]
        var displayByKey: [String: String] = [:]
        for filename in filenames {
            guard let artist = parse(filename, pattern: resolved).artist else { continue }
            let key = artist.lowercased()
            counts[key, default: 0] += 1
            if displayByKey[key] == nil { displayByKey[key] = artist }
        }

        return counts
            .sorted {
                $0.value != $1.value
                    ? $0.value > $1.value
                    : (displayByKey[$0.key] ?? "").localizedStandardCompare(displayByKey[$1.key] ?? "")
                        == .orderedAscending
            }
            .prefix(limit)
            .compactMap { displayByKey[$0.key] }
    }

    // MARK: - 内部

    /// 去掉路径、扩展名和重复标记后的主体。
    public static func normalizedStem(_ filename: String) -> String {
        let lastComponent = (filename as NSString).lastPathComponent
        let stem = (lastComponent as NSString).deletingPathExtension
        return stem.trimmingCharacters(in: .whitespaces)
    }

    private static func strippingLeadingTrack(_ value: String) -> (Int?, String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // 两位以内，避免把年份 `2003` 当轨号。
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let track = Int(digits) else {
            return (nil, value)
        }

        var rest = trimmed[trimmed.index(trimmed.startIndex, offsetBy: digits.count)...]
        let hadSpace = rest.first == " "
        rest = rest.drop { $0 == " " }
        let hadSeparator = rest.first.map { trackSeparators.contains($0) } ?? false
        if hadSeparator { rest = rest.dropFirst() }
        // 数字后面必须有分隔符或空格，否则 `1994 恋曲` 里的 `19` 会被当轨号切走。
        guard hadSeparator || hadSpace else { return (nil, value) }

        let body = rest.trimmingCharacters(in: .whitespaces)
        // 只有轨号没有正文时不算命中，否则 `01.mp3` 会变成空歌名。
        return body.isEmpty ? (nil, value) : (track, body)
    }

    /// 找第一个出现的分隔符。`_` 与 `-` 混用时(`孙露_一定要爱你 - 现场版`)，
    /// 取更靠左的那个，右边的当作歌名的一部分。
    private static func splitOnSeparator(_ value: String) -> (String, String)? {
        var best: (range: Range<String.Index>, separator: String)?
        for separator in separators {
            guard let range = value.range(of: separator) else { continue }
            if let current = best, current.range.lowerBound <= range.lowerBound { continue }
            best = (range, separator)
        }
        guard let best else { return nil }
        let head = String(value[value.startIndex..<best.range.lowerBound])
        let tail = String(value[best.range.upperBound...])
        return (head, tail)
    }

    private static func cleaned(_ value: String) -> String {
        let stripped = strippingDuplicateSuffix(value.trimmingCharacters(in: .whitespaces))
        return stripped
            .trimmingCharacters(in: CharacterSet(charactersIn: trimmables))
            .trimmingCharacters(in: .whitespaces)
    }

    /// 去掉结尾的重复标记：`_ 2` / `(1)` / `[2]` / `【2】`。它们来自下载器和网盘去重，
    /// 不属于歌名的一部分。整段都是数字时保持原样 —— 有些歌名本来就叫 `1994`。
    private static func strippingDuplicateSuffix(_ value: String) -> String {
        var body = Substring(value).trimmingSuffixWhitespace()

        // 括号形态：`歌名 (2)`。
        let closers: [Character: Character] = [")": "(", "）": "（", "]": "[", "】": "【"]
        if let last = body.last, let opener = closers[last] {
            let inner = body.dropLast()
            if let openIndex = inner.lastIndex(of: opener) {
                let digits = inner[inner.index(after: openIndex)...]
                    .trimmingCharacters(in: .whitespaces)
                if !digits.isEmpty, digits.count <= 2, digits.allSatisfy(\.isNumber) {
                    let head = inner[inner.startIndex..<openIndex].trimmingSuffixWhitespace()
                    if !head.isEmpty { return String(head) }
                }
            }
            return String(body)
        }

        // 裸数字形态：`歌名 _ 2` / `歌名 - 2`。数字前必须有分隔符，
        // 否则 `Track 2` 这种本来就带编号的歌名会被削掉。
        var digitCount = 0
        for character in body.reversed() {
            guard character.isNumber else { break }
            digitCount += 1
        }
        guard digitCount > 0, digitCount <= 2 else { return String(body) }
        body = body.dropLast(digitCount)
        let head = body.trimmingSuffixWhitespace()
        guard let boundary = head.last, trimmables.contains(boundary) else { return value }
        let cleanedHead = head.trimmingSuffixCharacters(in: trimmables)
        return cleanedHead.isEmpty ? value : String(cleanedHead)
    }
}

private extension Substring {
    func trimmingSuffixWhitespace() -> Substring {
        var result = self
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return result
    }

    func trimmingSuffixCharacters(in characters: String) -> Substring {
        var result = trimmingSuffixWhitespace()
        while let last = result.last, characters.contains(last) || last.isWhitespace {
            result = result.dropLast()
        }
        return result
    }
}
