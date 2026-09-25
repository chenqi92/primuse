import Foundation

/// 把「别处来的一首歌」（其他音乐 App 的歌单、粘贴的文本清单、歌单里还没对上的占位条目）
/// 跟曲库里的歌对上。导入预览和之后的自动点亮用的是同一套规则，所以预览里说「能对上」的，
/// 以后自动点亮时也一定对得上，反之亦然。
///
/// 判定只有三档：
/// - `confident`：歌名一致、歌手有交集、时长（两边都有时）相差不超过 3 秒。可以自动写进歌单。
/// - `probable`：歌名一致，但歌手缺一边或时长差 3～10 秒。只能作为「可能是」给用户确认，
///   绝不自动点亮 —— 点错一首比少点亮一首更糟。
/// - 其余都不算匹配。时长差超过 10 秒、或者版本标记（现场/伴奏/混音…）不同，直接否决。
public enum ExternalTrackMatchPolicy {
    public static let confidentDurationTolerance: Double = 3
    public static let rejectDurationDifference: Double = 10

    /// 参与匹配的一首歌，只含匹配要用的字段，好在 Linux 上直接测。
    public struct Subject: Codable, Sendable, Hashable {
        public var title: String
        public var artists: [String]
        /// 秒；nil 或 ≤0 表示不知道。
        public var duration: Double?

        public init(title: String, artists: [String], duration: Double?) {
            self.title = title
            self.artists = artists
            self.duration = duration
        }
    }

    public enum Verdict: Int, Sendable, Comparable {
        case none = 0
        case probable = 1
        case confident = 2

        public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 预先归一化好的一首歌。建索引时每首歌只算一次（繁简转换不便宜）。
    public struct Key: Sendable, Hashable {
        /// 去掉括号内容、空白和标点后的歌名主体。用作索引桶。
        public let coreTitle: String
        /// 歌名里出现的版本标记（现场、伴奏、混音…），两边必须一致。
        public let versionMarkers: Set<VersionMarker>
        public let artistTokens: Set<String>
        public let duration: Double?

        public init(_ subject: Subject) {
            let (core, markers) = ExternalTrackMatchPolicy.splitTitle(subject.title)
            coreTitle = core
            versionMarkers = markers
            var tokens = Set<String>()
            for artist in subject.artists {
                for token in ExternalTrackMatchPolicy.artistTokens(artist) { tokens.insert(token) }
            }
            artistTokens = tokens
            if let duration = subject.duration, duration.isFinite, duration > 0 {
                self.duration = duration
            } else {
                self.duration = nil
            }
        }

        public var isMatchable: Bool { !coreTitle.isEmpty }
    }

    public enum VersionMarker: String, Sendable, Hashable, CaseIterable {
        case live
        case instrumental
        case remix
        case acoustic
        case demo
        case cover
        case sped
    }

    public static func verdict(_ query: Key, _ candidate: Key) -> Verdict {
        guard query.isMatchable, query.coreTitle == candidate.coreTitle,
              query.versionMarkers == candidate.versionMarkers else { return .none }

        var durationIsClose = true
        if let lhs = query.duration, let rhs = candidate.duration {
            let difference = abs(lhs - rhs)
            if difference > rejectDurationDifference { return .none }
            durationIsClose = difference <= confidentDurationTolerance
        }

        let artistsKnown = !query.artistTokens.isEmpty && !candidate.artistTokens.isEmpty
        if artistsKnown {
            guard !query.artistTokens.isDisjoint(with: candidate.artistTokens) else { return .none }
            return durationIsClose ? .confident : .probable
        }
        // 缺歌手时只剩歌名（加上没被否决的时长），不够资格自动写入。
        return .probable
    }

    // MARK: - Normalization

    /// 全半角、大小写、变音符、繁简统一，并去掉空白和常见标点。
    public static func normalize(_ text: String) -> String {
        var value = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        if value.unicodeScalars.contains(where: isCJKIdeograph),
           let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) {
            value = simplified
        }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where !isIgnorable(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// 把歌名拆成「主体」和「版本标记」。括号（含全角、书名号式的【】）里的内容和
    /// ` - xxx` 形式的后缀都视为附注：附注里认得出的版本关键词进标记，其余（feat.、
    /// Remaster、电视剧插曲…）直接丢掉，不影响匹配。
    public static func splitTitle(_ title: String) -> (core: String, markers: Set<VersionMarker>) {
        var core = ""
        var annotations: [String] = []
        var depth = 0
        var current = ""
        for character in title {
            if openingBrackets.contains(character) {
                if depth == 0 { core.append(" ") } else { current.append(character) }
                depth += 1
                continue
            }
            if closingBrackets.contains(character), depth > 0 {
                depth -= 1
                if depth == 0 {
                    annotations.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
                continue
            }
            if depth > 0 { current.append(character) } else { core.append(character) }
        }
        if !current.isEmpty { annotations.append(current) }

        // 「歌名 - Live」「歌名 - 伴奏」这种写法：只有后缀里认得出版本词时才切，
        // 否则 "A - B" 可能本来就是歌名的一部分。
        for separator in [" - ", " – ", " — ", "－"] {
            guard let range = core.range(of: separator, options: .backwards) else { continue }
            let suffix = String(core[range.upperBound...])
            if !markers(in: suffix).isEmpty || isNeutralAnnotation(suffix) {
                annotations.append(suffix)
                core = String(core[..<range.lowerBound])
            }
            break
        }

        var found = Set<VersionMarker>()
        for annotation in annotations { found.formUnion(markers(in: annotation)) }
        // 主体里直接写着「(Live)」以外的「Live版」之类，也要认出来。
        found.formUnion(markers(in: core, requireWholeAnnotation: true))
        return (normalize(core), found)
    }

    /// 一个歌手字段拆成若干个归一化后的名字。
    public static func artistTokens(_ artist: String) -> [String] {
        var parts = [artist]
        for separator in artistSeparators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var tokens: [String] = []
        for part in parts {
            let normalized = normalize(part)
            if !normalized.isEmpty, !unknownArtistNames.contains(normalized) {
                tokens.append(normalized)
            }
        }
        return tokens
    }

    private static func markers(in annotation: String, requireWholeAnnotation: Bool = false) -> Set<VersionMarker> {
        let lowered = annotation.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        var result = Set<VersionMarker>()
        for (marker, words) in markerKeywords {
            let hit = words.contains { word in
                if requireWholeAnnotation {
                    // 主体里只认紧贴末尾的「xx版」「(live)」式写法，别把歌名里的
                    // 普通英文单词（"Live Forever"）当成现场版。
                    return word.hasSuffix("版") && lowered.hasSuffix(word)
                }
                return lowered.contains(word)
            }
            if hit { result.insert(marker) }
        }
        return result
    }

    private static func isNeutralAnnotation(_ suffix: String) -> Bool {
        let lowered = suffix.lowercased()
        return neutralKeywords.contains { lowered.contains($0) }
    }

    private static let markerKeywords: [VersionMarker: [String]] = [
        .live: ["live", "现场", "現場", "演唱会", "演唱會", "live版"],
        .instrumental: ["instrumental", "伴奏", "纯音乐", "純音樂", "off vocal", "karaoke", "inst.", "消音版"],
        .remix: ["remix", "混音", "dj版", "bootleg"],
        .acoustic: ["acoustic", "不插电", "不插電", "unplugged"],
        .demo: ["demo", "小样", "小樣"],
        .cover: ["cover", "翻唱", "翻自"],
        .sped: ["sped up", "slowed", "加速版", "降速版", "0.8x", "1.2x"],
    ]

    private static let neutralKeywords = [
        "remaster", "feat", "ft.", "mono", "stereo", "version", "ver.", "single", "radio edit",
        "主题曲", "主題曲", "插曲", "片尾曲", "片头曲", "原声", "原聲", "电视剧", "電視劇", "电影", "電影",
        // 视频标题里常见的尾巴
        "official", "mv", "m/v", "lyric", "audio", "visualizer", "官方", "完整版", "高音质", "高音質", "动态歌词", "動態歌詞",
    ]

    private static let openingBrackets: Set<Character> = ["(", "（", "[", "【", "［", "〔", "「", "『", "<", "《"]
    private static let closingBrackets: Set<Character> = [")", "）", "]", "】", "］", "〕", "」", "』", ">", "》"]

    private static let artistSeparators = [
        "/", "／", "、", "&", "＆", ";", "；", ",", "，", "|", "｜",
        " feat. ", " feat ", " ft. ", " Feat. ", " FEAT. ", " Ft. ", " x ", " X ", " × ", " vs. ", " VS ",
    ]

    /// 各家对「没有歌手」的写法；它们不能算作歌手有交集的证据。
    private static let unknownArtistNames: Set<String> = [
        "unknown", "unknownartist", "未知", "未知歌手", "未知艺术家", "群星", "variousartists", "va", "佚名",
    ]

    private static func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    private static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isWhitespace { return true }
        switch properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol,
             .modifierSymbol, .otherSymbol, .control, .format:
            return true
        default:
            return false
        }
    }
}

// MARK: - Index

/// 曲库一侧的匹配索引：按歌名主体分桶。建一次，查任意多次。
public struct ExternalTrackMatchIndex<ID: Hashable & Sendable>: Sendable {
    public struct Entry: Sendable {
        public let id: ID
        public let key: ExternalTrackMatchPolicy.Key
    }

    private var buckets: [String: [Entry]] = [:]

    public init(_ items: [(id: ID, subject: ExternalTrackMatchPolicy.Subject)]) {
        buckets.reserveCapacity(items.count)
        for item in items {
            let key = ExternalTrackMatchPolicy.Key(item.subject)
            guard key.isMatchable else { continue }
            buckets[key.coreTitle, default: []].append(Entry(id: item.id, key: key))
        }
    }

    /// 键已经算好（例如调用方按歌缓存了归一化结果）时直接用。
    public init(keyed items: [(id: ID, key: ExternalTrackMatchPolicy.Key)]) {
        buckets.reserveCapacity(items.count)
        for item in items where item.key.isMatchable {
            buckets[item.key.coreTitle, default: []].append(Entry(id: item.id, key: item.key))
        }
    }

    public var isEmpty: Bool { buckets.isEmpty }

    /// 所有达到 `minimum` 档的候选，按档次从高到低；同档保持建索引时的顺序。
    public func matches(
        for subject: ExternalTrackMatchPolicy.Subject,
        minimum: ExternalTrackMatchPolicy.Verdict = .probable
    ) -> [(id: ID, verdict: ExternalTrackMatchPolicy.Verdict)] {
        matches(for: ExternalTrackMatchPolicy.Key(subject), minimum: minimum)
    }

    public func matches(
        for key: ExternalTrackMatchPolicy.Key,
        minimum: ExternalTrackMatchPolicy.Verdict = .probable
    ) -> [(id: ID, verdict: ExternalTrackMatchPolicy.Verdict)] {
        guard key.isMatchable, let bucket = buckets[key.coreTitle] else { return [] }
        var confident: [(id: ID, verdict: ExternalTrackMatchPolicy.Verdict)] = []
        var probable: [(id: ID, verdict: ExternalTrackMatchPolicy.Verdict)] = []
        for entry in bucket {
            let verdict = ExternalTrackMatchPolicy.verdict(key, entry.key)
            guard verdict >= minimum, verdict != .none else { continue }
            if verdict == .confident {
                confident.append((entry.id, verdict))
            } else {
                probable.append((entry.id, verdict))
            }
        }
        return confident + probable
    }
}

// MARK: - Choosing among copies

/// 同一首歌在多个音乐源里各有一份时选哪一份。顺序：此刻能直接播的 > 本机就有完整音频的 >
/// 音质分高的。音质只在都能播的前提下才比。
public enum PlayableCopyPreferencePolicy {
    public struct Candidate: Sendable, Hashable {
        public let id: String
        public let isAvailable: Bool
        public let hasLocalAudio: Bool
        public let qualityScore: Int

        public init(id: String, isAvailable: Bool, hasLocalAudio: Bool, qualityScore: Int) {
            self.id = id
            self.isAvailable = isAvailable
            self.hasLocalAudio = hasLocalAudio
            self.qualityScore = qualityScore
        }
    }

    /// 最好的一份；没有任何一份可用时返回 nil。
    public static func preferred(_ candidates: [Candidate]) -> Candidate? {
        ordered(candidates).first { $0.isAvailable }
    }

    public static func ordered(_ candidates: [Candidate]) -> [Candidate] {
        candidates.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if l.isAvailable != r.isAvailable { return l.isAvailable }
            if l.hasLocalAudio != r.hasLocalAudio { return l.hasLocalAudio }
            if l.qualityScore != r.qualityScore { return l.qualityScore > r.qualityScore }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
