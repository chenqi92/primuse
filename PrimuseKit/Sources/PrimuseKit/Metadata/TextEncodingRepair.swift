import Foundation

/// 音乐标签文本的编码修复。标签乱码分两大类:
///
/// 1. 单字节误读 —— GBK/Big5/Shift_JIS/EUC-KR 的字节被当成 ISO-8859-1 或
///    CP1252 解出, 结果是一串扩展拉丁字符 ("¹ý»ð"、"â€™")。
/// 2. 多字节互串 —— UTF-8 的字节被当成 GBK/Big5 解出, 汉字变成另一组汉字
///    (常混着生僻字与繁体字)。这类一个扩展拉丁字符都没有。
///
/// 修复办法是把当前字符串按"错误编码"编回字节, 再按"真实编码"重新解出,
/// 取合理度评分最高、且显著优于原文的候选。
///
/// 目标编码是 UTF-8 时结构自校验能力很强 —— GBK/Big5 的尾字节常落在
/// 0x40...0x7E, 而 UTF-8 续字节必须是 0x80...0xBF, 所以正常中文标签的字节
/// 几乎不可能碰巧是合法 UTF-8。这类候选只要求较小分差; 没有自校验的组合
/// (GBK↔Big5) 要求大得多的分差, 并且必须真正减少生僻字。
public enum TextEncodingRepair {
    // MARK: - Encodings

    private static func cfEncoding(_ raw: UInt32) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(raw))
        )
    }

    /// kCFStringEncodingGB_18030_2000
    public static let gb18030 = cfEncoding(0x0632)
    /// kCFStringEncodingBig5
    public static let big5 = cfEncoding(0x0A03)
    /// kCFStringEncodingEUC_KR
    public static let eucKR = cfEncoding(0x0940)

    // MARK: - Public API

    /// 返回修复后的文本; 没有可信候选时返回 nil (调用方应保留原文)。
    public static func repaired(_ text: String) -> String? {
        guard looksCorrupted(text) else { return nil }

        let originalScore = plausibility(text)
        let originalRareHan = rareHanCount(in: text)
        var best: (text: String, score: Int)?

        for rewrite in rewrites {
            guard let candidate = rewrite.apply(to: text) else { continue }
            guard candidate != text else { continue }

            let score = plausibility(candidate)
            let margin = rewrite.selfValidating
                ? selfValidatingMargin
                : ambiguousMargin
            guard score >= originalScore + margin else { continue }

            // 没有结构自校验的组合(GBK↔Big5)必须真正减少生僻字, 否则只是把
            // 一组汉字换成另一组同样可疑的汉字。
            if rewrite.requiresRareHanReduction {
                guard rareHanCount(in: candidate) < originalRareHan else { continue }
            }

            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }

        return best?.text
    }

    /// 文本是否值得进入修复流程。这是个便宜的粗筛, 真正的把关在分差上。
    public static func looksCorrupted(_ text: String) -> Bool {
        var artifactRunLatin1Count = 0
        var artifactRunMarkerCount = 0
        var hasArtifactRun = false
        var han = 0
        var rareHan = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isLatin1Artifact = (0x80...0xFF).contains(value)
            let isCP1252Marker = cp1252MarkerScalars.contains(value)
            if isLatin1Artifact || isCP1252Marker {
                artifactRunLatin1Count += isLatin1Artifact ? 1 : 0
                artifactRunMarkerCount += isCP1252Marker ? 1 : 0
                if artifactRunLatin1Count >= 2
                    || (artifactRunLatin1Count >= 1 && artifactRunMarkerCount >= 2) {
                    hasArtifactRun = true
                }
            } else {
                artifactRunLatin1Count = 0
                artifactRunMarkerCount = 0
            }
            if isHan(value) {
                han += 1
                if !isCommonHan(scalar) { rareHan += 1 }
            }
        }

        // 真乱码保留的是连续原始字节, 例如 "Ã©" 或 "â€™"；正常西文标题里的
        // é / ð / ö 通常被 ASCII 分开。按连续簇判断可保留多重音符号人名, 同时
        // 仍覆盖 C1 字节和 CP1252 映射到 € ™ “ ” 等码位的典型乱码。
        if hasArtifactRun { return true }

        // 汉字被当成另一套汉字解出来时, 结果几乎必然夹带生僻字。只看"有汉字"
        // 会让每个正常中文标题都跑满整个候选矩阵 —— 而扫描时每首歌要判 4 个
        // 字段, 这条快速路径因此值得。代价是全为常用字的乱码会被漏掉, 但漏修
        // 远好过误改。
        return han >= 2 && rareHan >= 1
    }

    /// 文本是否含已经不可逆丢失的字符。这类字段没法从原字节恢复, 只能改用
    /// 文件名之类的旁路兜底。
    public static func hasUnrecoverableReplacement(in text: String) -> Bool {
        if text.unicodeScalars.contains(where: { $0.value == 0xFFFD }) {
            return true
        }

        // 一部分媒体服务器把解不出的尾部字节换成 ASCII 问号而不是 U+FFFD。
        // 要求同时存在 CJK 文字, 才不会误伤正常带问号的西文标题。
        return text.contains("??")
            && text.unicodeScalars.contains { isCJKScript($0.value) }
    }

    /// 从若干候选编码中解出最可信的文本。合法 UTF-8 具有结构自校验, 应直接
    /// 采用；ISO-8859-1 则是 ID3 编码字节 0 的标准含义, 只有出现连续乱码字节簇
    /// 且其他候选显著更合理时才覆盖。这样既兼容误声明的 GBK/Shift_JIS 等标签,
    /// 也不会把 Björk / Mylène 之类的合法西文按 CJK 绝对分数误解码。
    public static func bestDecoding(of data: Data, encodings: [String.Encoding]) -> String? {
        guard !data.isEmpty else { return nil }

        var candidates: [(encoding: String.Encoding, text: String, score: Int)] = []
        for encoding in encodings {
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            let cleaned = decoded.replacingOccurrences(of: "\0", with: "")
            guard !cleaned.isEmpty else { continue }
            candidates.append((encoding, cleaned, plausibility(cleaned)))
        }

        if let utf8 = candidates.first(where: { $0.encoding == .utf8 }),
           !utf8.text.unicodeScalars.contains(where: { isDisallowedControl($0.value) }) {
            return utf8.text
        }

        if let latin1 = candidates.first(where: { $0.encoding == .isoLatin1 }) {
            if looksCorrupted(latin1.text) {
                var best: (encoding: String.Encoding, text: String, score: Int)?
                for candidate in candidates where !candidate.text.unicodeScalars.contains(where: {
                    isDisallowedControl($0.value)
                }) {
                    if best == nil || candidate.score > best!.score {
                        best = candidate
                    }
                }
                if let best,
                   best.encoding != .isoLatin1,
                   best.score >= latin1.score + ambiguousMargin {
                    return best.text
                }
            }

            // 实际 CP1252 标签常把弯引号写在 0x80...0x9F。ISO-8859-1 会把
            // 这些字节变成控制字符；没有更强的东亚编码候选时采用无控制字符的
            // Windows-1252 解码。
            if latin1.text.unicodeScalars.contains(where: { (0x80...0x9F).contains($0.value) }),
               let cp1252 = candidates.first(where: { $0.encoding == .windowsCP1252 }),
               !cp1252.text.unicodeScalars.contains(where: { isDisallowedControl($0.value) }) {
                return cp1252.text
            }
            return latin1.text
        }

        var best: (text: String, score: Int)?
        for candidate in candidates {
            if best == nil || candidate.score > best!.score {
                best = (candidate.text, candidate.score)
            }
        }
        return best?.text
    }

    /// 解 ID3 文本帧。`encodingByte` 是帧首那个声明字节, 但大量老工具会在写
    /// GBK/Shift_JIS 字节时把它留成 0 (标准里是 ISO-8859-1), 所以声明只作为
    /// 候选顺序的提示, 最终仍按合理度评分定夺。
    public static func decodeID3Text(_ payload: Data, encodingByte: UInt8) -> String? {
        guard !payload.isEmpty else { return nil }

        let decoded: String?
        switch encodingByte {
        case 0:
            decoded = bestDecoding(of: payload, encodings: legacyTextEncodings)
        case 1:
            decoded = bestDecoding(
                of: payload,
                encodings: [.utf16, .utf16LittleEndian, .utf16BigEndian]
            )
        case 2:
            decoded = String(data: payload, encoding: .utf16BigEndian)
        case 3:
            decoded = String(data: payload, encoding: .utf8)
                ?? bestDecoding(of: payload, encodings: legacyTextEncodings)
        default:
            return nil
        }

        guard let decoded else { return nil }
        let normalized = decoded
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return repaired(normalized) ?? normalized
    }

    /// 声明为单字节/未知编码时的候选集合。
    public static let legacyTextEncodings: [String.Encoding] = [
        .utf8, gb18030, big5, .shiftJIS, eucKR, .isoLatin1, .windowsCP1252,
    ]

    // MARK: - 手动修正

    /// 一套可供用户挑选的重解方案。`fields` 与传入的字段一一对应。
    public struct EncodingFix: Identifiable, Sendable, Equatable {
        public let id: String
        /// 形如 "Latin-1 → GBK", 说明这批字节当初被谁读错、真实编码是谁。
        public let label: String
        public let fields: [String]
        /// 合理度增量, 仅用于排序。
        public let scoreDelta: Int
    }

    /// 列出能把这批字段重新解出不同结果的所有方案, 好的排在前面。
    ///
    /// 自动修复必须保守 —— 猜错了会把好数据改坏。手动模式相反: 用户能看到
    /// 预览再决定, 所以这里不设分差门槛, 只要解得出不含替换字符的结果就列
    /// 出来, 由人来判断。
    ///
    /// 同一首歌的各个标签字段几乎总是同一个编码写的, 所以方案是整批应用的:
    /// 选一次, 标题/艺术家/专辑一起改。某个字段在该方案下解不出来时保留原值。
    public static func availableFixes(for fields: [String]) -> [EncodingFix] {
        let nonEmpty = fields.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return [] }

        let baseline = nonEmpty.reduce(0) { $0 + plausibility($1) }
        var fixes: [EncodingFix] = []
        var seen = Set<[String]>()

        for rewrite in rewrites {
            var rewritten: [String] = []
            var changed = false

            for field in fields {
                if let candidate = rewrite.apply(to: field), candidate != field {
                    rewritten.append(candidate)
                    changed = true
                } else {
                    rewritten.append(field)
                }
            }

            guard changed, seen.insert(rewritten).inserted else { continue }

            let score = rewritten
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .reduce(0) { $0 + plausibility($1) }

            fixes.append(
                EncodingFix(
                    id: "\(rewrite.source.rawValue)-\(rewrite.target.rawValue)",
                    label: "\(displayName(of: rewrite.source)) → \(displayName(of: rewrite.target))",
                    fields: rewritten,
                    scoreDelta: score - baseline
                )
            )
        }

        return fixes.sorted { $0.scoreDelta > $1.scoreDelta }
    }

    private static func displayName(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .isoLatin1: return "Latin-1"
        case .windowsCP1252: return "Windows-1252"
        case gb18030: return "GBK"
        case big5: return "Big5"
        case .shiftJIS: return "Shift_JIS"
        case eucKR: return "EUC-KR"
        default: return "\(encoding.rawValue)"
        }
    }

    // MARK: - Rewrite matrix

    private static let selfValidatingMargin = 4
    private static let ambiguousMargin = 24

    private struct Rewrite {
        /// 当前字符串是被这个编码错误解出来的。
        let source: String.Encoding
        /// 字节的真实编码。
        let target: String.Encoding
        /// 目标编码是否具备结构自校验(仅 UTF-8)。
        let selfValidating: Bool
        /// Only the GBK/Big5 cross-rewrite lacks a structural signal. Other
        /// targets, such as Shift_JIS and EUC-KR, must not be rejected merely
        /// because their correct result contains no Han characters.
        let requiresRareHanReduction: Bool

        func apply(to text: String) -> String? {
            guard let bytes = encodedBytes(of: text) else { return nil }
            guard bytes.count >= 2 else { return nil }
            guard let decoded = String(data: bytes, encoding: target) else { return nil }

            let cleaned = decoded.replacingOccurrences(of: "\0", with: "")
            guard !cleaned.isEmpty else { return nil }
            guard !cleaned.unicodeScalars.contains(where: {
                $0.value == 0xFFFD || TextEncodingRepair.isDisallowedControl($0.value)
            }) else {
                return nil
            }
            return cleaned
        }

        private func encodedBytes(of text: String) -> Data? {
            guard let bytes = text.data(using: source) else { return nil }
            guard source == TextEncodingRepair.gb18030 else { return bytes }

            // GB18030 能编码全部 Unicode(用 4 字节序列), 所以它作为"错误编码"
            // 时永远不会失败。只有当每个字符都落在 1/2 字节的传统 GBK 区间,
            // 这些字节才可能真是当初被误读的那批。
            let expected = text.unicodeScalars.reduce(0) { total, scalar in
                total + (scalar.value < 0x80 ? 1 : 2)
            }
            return bytes.count == expected ? bytes : nil
        }
    }

    private static let rewrites: [Rewrite] = {
        var list: [Rewrite] = []
        let trueEncodings: [String.Encoding] = [.utf8, gb18030, big5, .shiftJIS, eucKR]

        // 单字节误读: 字节被当成 latin1/CP1252 逐字节映射成了字符。
        for source in [String.Encoding.isoLatin1, .windowsCP1252] {
            for target in trueEncodings {
                list.append(
                    Rewrite(
                        source: source,
                        target: target,
                        selfValidating: target == .utf8,
                        requiresRareHanReduction: false
                    )
                )
            }
        }

        // 多字节互串: UTF-8 字节被当成 GBK/Big5 解出(汉字→汉字)。
        list.append(Rewrite(source: gb18030, target: .utf8, selfValidating: true, requiresRareHanReduction: false))
        list.append(Rewrite(source: big5, target: .utf8, selfValidating: true, requiresRareHanReduction: false))

        // GBK 与 Big5 互串。没有自校验, 靠大分差 + 生僻字必须减少来把关。
        list.append(Rewrite(source: gb18030, target: big5, selfValidating: false, requiresRareHanReduction: true))
        list.append(Rewrite(source: big5, target: gb18030, selfValidating: false, requiresRareHanReduction: true))

        return list
    }()

    // MARK: - Plausibility scoring

    /// 文本"像不像人写的标签"。分数只用于比较同一字段的不同解码候选。
    static func plausibility(_ text: String) -> Int {
        var score = 0
        var hangulCount = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value

            if isHangul(value) { hangulCount += 1 }

            if value == 0xFFFD {
                score -= 40
            } else if isDisallowedControl(value) {
                score -= 25
            } else if isHan(value) {
                score += isCommonHan(scalar) ? 6 : -8
            } else if isHalfwidthKana(value) {
                // Halfwidth Katakana is a valid legacy encoding result, but
                // it is a weaker signal than fullwidth kana or Hangul. This
                // keeps accidental Shift_JIS candidates below real Han/Hangul
                // while still repairing a short all-halfwidth title.
                score += 2
            } else if isKanaOrHangul(value) {
                score += 6
            } else if isCJKPunctuationOrFullwidth(value) {
                score += 2
            } else if cp1252MarkerScalars.contains(value) {
                score -= 4
            } else if (0xA1...0xFF).contains(value) {
                score -= 3
            } else if value < 0x80 {
                score += 1
            }
            // 其余脚本(西里尔、希腊、emoji 等)按中性处理, 不加不减。
        }
        // A sufficiently long Hangul result is a useful tie-breaker for
        // EUC-KR, while a one-character accidental Hangul candidate must not
        // outrank a short Chinese result.
        if hangulCount >= 3 && hangulCount * 2 >= text.unicodeScalars.count {
            score += 2
        }
        return score
    }

    private static func rareHanCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + (isHan(scalar.value) && !isCommonHan(scalar) ? 1 : 0)
        }
    }

    /// 汉字是否属于常用字。判据是它落不落进 GB2312 的一/二级字库, 或者
    /// Big5 的常用/次常用区 —— 两边取并集, 简体库和繁体库都不会被误判成
    /// 生僻字。乱码产生的汉字串通常大量落在这两个区间之外。
    private static func isCommonHan(_ scalar: Unicode.Scalar) -> Bool {
        commonHanScalars.contains(scalar.value)
    }

    /// 扫描大库时 `isSuspicious` 会对每个标题跑一遍打分, 所以常用字判定不能
    /// 每个字符都去编码一次。这里一次性把两个字库展开成集合, 之后全是查表。
    private static let commonHanScalars: Set<UInt32> = {
        var scalars = Set<UInt32>()
        scalars.reserveCapacity(20000)

        func insert(_ bytes: [UInt8], encoding: String.Encoding) {
            guard let text = String(data: Data(bytes), encoding: encoding),
                  text.unicodeScalars.count == 1,
                  let scalar = text.unicodeScalars.first,
                  isHan(scalar.value) else {
                return
            }
            scalars.insert(scalar.value)
        }

        // GB2312 一级 B0A1...D7F9 与二级 D8A0...F7FE
        for lead in 0xB0...0xF7 {
            for trail in 0xA1...0xFE {
                insert([UInt8(lead), UInt8(trail)], encoding: gb18030)
            }
        }

        // Big5 常用 A440...C67E 与次常用 C940...F9D5
        let big5Trails = Array(0x40...0x7E) + Array(0xA1...0xFE)
        for lead in Array(0xA4...0xC6) + Array(0xC9...0xF9) {
            for trail in big5Trails {
                insert([UInt8(lead), UInt8(trail)], encoding: big5)
            }
        }

        return scalars
    }()

    // MARK: - Script classification

    static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
    }

    /// 假名与谚文。旧实现只认表意文字, 导致纯假名的日文标题算出来是 0 个
    /// CJK 字符, 正确解码反而会被判为"没有改善"而否决。
    static func isKanaOrHangul(_ value: UInt32) -> Bool {
        (0x3040...0x309F).contains(value)      // 平假名
            || (0x30A0...0x30FF).contains(value)  // 片假名
            || (0x31F0...0x31FF).contains(value)  // 片假名音标扩展
            || isHalfwidthKana(value)
            || (0xAC00...0xD7A3).contains(value)  // 谚文音节
            || (0x1100...0x11FF).contains(value)  // 谚文字母
            || (0x3130...0x318F).contains(value)  // 谚文兼容字母
    }

    static func isCJKScript(_ value: UInt32) -> Bool {
        isHan(value) || isKanaOrHangul(value)
    }

    private static func isHalfwidthKana(_ value: UInt32) -> Bool {
        (0xFF66...0xFF9F).contains(value)
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        (0xAC00...0xD7A3).contains(value)
            || (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
    }

    private static func isCJKPunctuationOrFullwidth(_ value: UInt32) -> Bool {
        (0x3000...0x303F).contains(value) || (0xFF01...0xFF60).contains(value)
    }

    private static func isDisallowedControl(_ value: UInt32) -> Bool {
        // 制表/换行/回车在歌词等字段里合法, 其余控制字符视为解码失败的证据。
        if value == 0x09 || value == 0x0A || value == 0x0D { return false }
        return value < 0x20 || (0x7F...0x9F).contains(value)
    }

    /// CP1252 在 0x80...0x9F 区映射出的字符。旧实现只统计 U+00A1...U+00FF,
    /// 这一整区都漏掉了, 于是最典型的 "â€™" 只有 â 被计入、达不到阈值。
    private static let cp1252MarkerScalars: Set<UInt32> = [
        0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6,
        0x2030, 0x0160, 0x2039, 0x0152, 0x017D, 0x2018, 0x2019, 0x201C,
        0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
        0x0153, 0x017E, 0x0178,
    ]
}
