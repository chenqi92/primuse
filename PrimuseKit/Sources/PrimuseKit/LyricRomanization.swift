import Foundation

// MARK: - 设置取值

/// 歌词罗马音怎么显示。对歌词文件自带的罗马音和自动生成的罗马音同样生效。
public enum LyricRomanizationDisplayMode: String, Codable, CaseIterable, Sendable {
    /// 原文照旧，罗马音排在原文和译文之间（文件自带罗马音一直以来的样子）。
    case belowOriginal
    /// 有罗马音的行只显示罗马音；罗马音没有逐字时间，这些行按整行高亮。
    case romanizationOnly
    /// 一律不显示罗马音，文件自带的也不显示。
    case hidden

    public static let defaultValue: LyricRomanizationDisplayMode = .belowOriginal
}

/// 自动生成罗马音用哪种方式。远程方式失败、没就绪或者不支持这种语言时一律退回本机。
public enum LyricRomanizationMethod: String, Codable, CaseIterable, Sendable {
    /// 本机：离线、即时。
    case local
    /// 智能功能里给「歌词罗马音」分配的服务（内置 AI 或自己的服务）。
    case intelligent
    /// Google Cloud Translation 的 romanizeText（服务账号密钥）。
    case googleCloud

    public static let defaultValue: LyricRomanizationMethod = .local
}

/// 「生成这些语言」里的四组。
public enum LyricRomanizationLanguage: String, Codable, CaseIterable, Sendable {
    case japanese
    case korean
    case chinese
    /// 俄文、乌克兰文、希腊文、泰文、印地文、阿拉伯文、希伯来文等其他非拉丁文字。
    case other
}

public enum LyricRomanizationLanguagePolicy {
    /// 「其他文字」这一组覆盖的语言（只列用非拉丁文字书写的）。
    static let otherScriptLanguageCodes: Set<String> = [
        "ru", "uk", "be", "bg", "mk", "sr", "kk", "ky", "tg", "mn",
        "el", "th", "lo", "km", "my", "hi", "mr", "ne", "sa", "bn", "as",
        "pa", "gu", "or", "ta", "te", "kn", "ml", "si", "ar", "fa", "ur",
        "ps", "ug", "he", "yi", "am", "ti", "ka", "hy", "bo", "dv",
    ]

    /// 没改过时的默认值：用户系统首选语言里已经有的语言不生成（中文用户默认不给中文
    /// 生成拼音），其余默认生成。
    public static func isEnabledByDefault(
        _ language: LyricRomanizationLanguage,
        preferredLanguages: [String]
    ) -> Bool {
        let bases = Set(preferredLanguages.map(baseLanguage))
        switch language {
        case .japanese: return !bases.contains("ja")
        case .korean: return !bases.contains("ko")
        case .chinese: return bases.isDisjoint(with: ["zh", "yue", "wuu", "nan", "hak"])
        case .other: return bases.isDisjoint(with: otherScriptLanguageCodes)
        }
    }

    /// 用户改过就用存下的显式值，没改过跟随默认。
    public static func isEnabled(
        _ language: LyricRomanizationLanguage,
        overrides: [String: Bool],
        preferredLanguages: [String]
    ) -> Bool {
        overrides[language.rawValue]
            ?? isEnabledByDefault(language, preferredLanguages: preferredLanguages)
    }

    public static func enabledLanguages(
        overrides: [String: Bool],
        preferredLanguages: [String]
    ) -> Set<LyricRomanizationLanguage> {
        Set(LyricRomanizationLanguage.allCases.filter {
            isEnabled($0, overrides: overrides, preferredLanguages: preferredLanguages)
        })
    }

    static func baseLanguage(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map { $0.lowercased() } ?? ""
    }
}

public enum LyricRomanizationMethodPolicy {
    /// Google Cloud 只在国际区显示；中国区与地区未知时不显示。
    public static func offersGoogleCloud(region: AICommercialRegion) -> Bool {
        region == .international
    }

    /// 实际用哪种方式：Google Cloud 不显示的地区当作本机，智能功能不开放的地区当作本机。
    public static func effectiveMethod(
        _ method: LyricRomanizationMethod,
        region: AICommercialRegion,
        exposesIntelligentServices: Bool
    ) -> LyricRomanizationMethod {
        switch method {
        case .local: return .local
        case .intelligent: return exposesIntelligentServices ? .intelligent : .local
        case .googleCloud: return offersGoogleCloud(region: region) ? .googleCloud : .local
        }
    }
}

// MARK: - 文字判定

/// 一行歌词里出现的文字。只关心要不要转写、转写成哪种语言。
public enum LyricRomanizationScript: String, Hashable, Sendable {
    case latin
    case kana
    case han
    case hangul
    case cyrillic
    case greek
    case arabic
    case hebrew
    case thai
    case lao
    case khmer
    case myanmar
    case devanagari
    case bengali
    case gurmukhi
    case gujarati
    case oriya
    case tamil
    case telugu
    case kannada
    case malayalam
    case sinhala
    case tibetan
    case thaana
    case ethiopic
    case georgian
    case armenian
}

public enum LyricRomanizationScriptPolicy {
    public struct Counts: Equatable, Sendable {
        public var kana = 0
        public var han = 0
        public var hangul = 0
        public var latin = 0
        /// 其余非拉丁文字各自的字数。
        public var others: [LyricRomanizationScript: Int] = [:]

        public var hasNonLatinLetters: Bool {
            kana > 0 || han > 0 || hangul > 0 || others.values.contains { $0 > 0 }
        }

        /// 字数最多的「其他文字」；并列时按枚举顺序取第一个，结果稳定。
        public var dominantOtherScript: LyricRomanizationScript? {
            others.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
            }?.key
        }
    }

    public static func script(of scalar: Unicode.Scalar) -> LyricRomanizationScript? {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF,
             0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            // 长音符「ー」(30FC) 与片假名中点也落在这一段，算假名。
            return .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
            return .han
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return .hangul
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return .hebrew
        case 0x0E00...0x0E7F: return .thai
        case 0x0E80...0x0EFF: return .lao
        case 0x1780...0x17FF: return .khmer
        case 0x1000...0x109F: return .myanmar
        case 0x0900...0x097F, 0xA8E0...0xA8FF: return .devanagari
        case 0x0980...0x09FF: return .bengali
        case 0x0A00...0x0A7F: return .gurmukhi
        case 0x0A80...0x0AFF: return .gujarati
        case 0x0B00...0x0B7F: return .oriya
        case 0x0B80...0x0BFF: return .tamil
        case 0x0C00...0x0C7F: return .telugu
        case 0x0C80...0x0CFF: return .kannada
        case 0x0D00...0x0D7F: return .malayalam
        case 0x0D80...0x0DFF: return .sinhala
        case 0x0F00...0x0FFF: return .tibetan
        case 0x0780...0x07BF: return .thaana
        case 0x1200...0x139F: return .ethiopic
        case 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F: return .georgian
        case 0x0530...0x058F: return .armenian
        default: return nil
        }
    }

    public static func counts(in text: String) -> Counts {
        var counts = Counts()
        for scalar in text.unicodeScalars {
            // 组合附加符（泰文、天城文的元音符号）不是字母本身，但同属那种文字。
            guard scalar.properties.isAlphabetic
                    || scalar.properties.generalCategory == .nonspacingMark
                    || scalar.properties.generalCategory == .spacingMark
                    || scalar.value == 0x30FC,
                  let script = script(of: scalar) else { continue }
            switch script {
            case .latin: counts.latin += 1
            case .kana: counts.kana += 1
            case .han: counts.han += 1
            case .hangul: counts.hangul += 1
            default: counts.others[script, default: 0] += 1
            }
        }
        return counts
    }

    /// 这一行有没有要转写的文字（只有拉丁字母、数字和符号的行不用转）。
    public static func needsRomanization(_ text: String) -> Bool {
        counts(in: text).hasNonLatinLetters
    }

    /// 「其他文字」这一组的语言代码，给远程方式的 source_language_code 用。
    /// 同一种文字的几种语言靠各自特有的字母分开，分不出时取最常见的那种。
    static func languageCode(for script: LyricRomanizationScript, text: String) -> String {
        func contains(_ characters: String) -> Bool {
            text.unicodeScalars.contains { characters.unicodeScalars.contains($0) }
        }
        switch script {
        case .cyrillic:
            // 白俄罗斯文也用 і，靠 ў 先认出来；剩下出现 і ї є ґ 的是乌克兰文。
            if contains("ўЎ") { return "be" }
            if contains("іїєґІЇЄҐ") { return "uk" }
            if contains("ђћџљњјЂЋЏЉЊЈ") { return "sr" }
            if contains("ѓќѕЃЌЅ") { return "mk" }
            if contains("ъ") && contains("щ") && !contains("ыэёЫЭЁ") { return "bg" }
            return "ru"
        case .greek: return "el"
        case .arabic:
            if contains("ٹڈڑںےۓ") { return "ur" }
            if contains("پچژگکی") { return "fa" }
            return "ar"
        case .hebrew: return "he"
        case .thai: return "th"
        case .lao: return "lo"
        case .khmer: return "km"
        case .myanmar: return "my"
        case .devanagari: return "hi"
        case .bengali: return "bn"
        case .gurmukhi: return "pa"
        case .gujarati: return "gu"
        case .oriya: return "or"
        case .tamil: return "ta"
        case .telugu: return "te"
        case .kannada: return "kn"
        case .malayalam: return "ml"
        case .sinhala: return "si"
        case .tibetan: return "bo"
        case .thaana: return "dv"
        case .ethiopic: return "am"
        case .georgian: return "ka"
        case .armenian: return "hy"
        case .latin, .kana, .han, .hangul: return "und"
        }
    }
}

// MARK: - 要生成哪些行

public struct LyricRomanizationCandidate: Hashable, Sendable {
    public let lineID: String
    public let text: String

    public init(lineID: String, text: String) {
        self.lineID = lineID
        self.text = text
    }
}

/// 一种语言的待转写行。同一首歌可能夹着几种语言（日文歌里的韩文段落），每种各走各的引擎。
public struct LyricRomanizationGroup: Hashable, Sendable {
    public let language: LyricRomanizationLanguage
    /// 给引擎用的语言代码：ja、ko、zh-Hans / zh-Hant / zh（字形没认出来）、ru、el……
    public let languageCode: String
    public let candidates: [LyricRomanizationCandidate]

    public init(language: LyricRomanizationLanguage, languageCode: String, candidates: [LyricRomanizationCandidate]) {
        self.language = language
        self.languageCode = languageCode
        self.candidates = candidates
    }

    /// 去重后的原文，保持第一次出现的顺序。引擎按它请求、缓存按它算指纹。
    public var uniqueTexts: [String] {
        var seen = Set<String>()
        return candidates.compactMap { seen.insert($0.text).inserted ? $0.text : nil }
    }
}

public struct LyricRomanizationPlan: Equatable, Sendable {
    /// 双语 LRC 里被判定为读音的附属行（`LyricManualTranslation.id`）——它们也是文件自带的罗马音。
    public var readingTranslationIDs: Set<String>
    public var groups: [LyricRomanizationGroup]

    public init(readingTranslationIDs: Set<String> = [], groups: [LyricRomanizationGroup] = []) {
        self.readingTranslationIDs = readingTranslationIDs
        self.groups = groups
    }
}

public enum LyricRomanizationPlanner {
    /// 找出要生成罗马音的行：自带罗马音的行（`romanization` 字段或双语 LRC 的读音行）
    /// 不生成；只有拉丁字母的行跳过；作词作曲这类制作信息不算歌词。
    ///
    /// 整首判定语言：任一行有假名就是日文歌，只有汉字的行也按日文读；有谚文的行是韩文；
    /// 其余只有汉字的是中文。
    public static func plan(
        lines: [LyricLine],
        generates: Bool,
        enabledLanguages: Set<LyricRomanizationLanguage>,
        songContext: LyricTranslationSongContext = .init()
    ) -> LyricRomanizationPlan {
        let flattened = LyricVoiceTimelinePolicy.flattenedLines(lines)
        let readingIDs = LyricRomanizedReadingPolicy.readingIDs(in: flattened)
        guard generates, !enabledLanguages.isEmpty else {
            return LyricRomanizationPlan(readingTranslationIDs: readingIDs)
        }

        let content = LyricTranslationContentPolicy.contentLines(in: flattened, song: songContext)
        let counted = content.map { (line: $0, counts: LyricRomanizationScriptPolicy.counts(in: $0.text)) }
        let documentHasKana = counted.contains { $0.counts.kana > 0 }
        // 西里尔文按整首判断：整首出现 і ї є ґ 就是乌克兰文，否则按俄文（ў 先认作白俄罗斯文，塞尔维亚、马其顿特有的字母另认）。
        let cyrillicText = counted
            .filter { $0.counts.others[.cyrillic, default: 0] > 0 }
            .map(\.line.text)
            .joined(separator: "\n")
        let documentCyrillicCode = cyrillicText.isEmpty
            ? "ru"
            : LyricRomanizationScriptPolicy.languageCode(for: .cyrillic, text: cyrillicText)
        let metadataLines = lines.lazy.compactMap(\.metadataLines).first ?? []
        let declaredDocumentLanguage = LyricTranslationGroupingPolicy.declaredLanguageCode(in: metadataLines)

        var order: [String] = []
        var buckets: [String: (language: LyricRomanizationLanguage, code: String, candidates: [LyricRomanizationCandidate])] = [:]
        for (line, counts) in counted {
            guard counts.hasNonLatinLetters, !hasAuthoredRomanization(line, readingIDs: readingIDs) else {
                continue
            }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let classified = classify(
                    text: text,
                    counts: counts,
                    documentHasKana: documentHasKana,
                    documentCyrillicCode: documentCyrillicCode,
                    declaredLanguageCode: line.languageCode ?? declaredDocumentLanguage
                  ),
                  enabledLanguages.contains(classified.language) else { continue }
            let (language, code) = (classified.language, classified.code)
            let key = "\(language.rawValue)|\(code)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = (language, code, [])
            }
            buckets[key]?.candidates.append(LyricRomanizationCandidate(lineID: line.id, text: text))
        }
        let groups = order.compactMap { key -> LyricRomanizationGroup? in
            guard let bucket = buckets[key] else { return nil }
            return LyricRomanizationGroup(language: bucket.language, languageCode: bucket.code, candidates: bucket.candidates)
        }
        return LyricRomanizationPlan(readingTranslationIDs: readingIDs, groups: groups)
    }

    /// 文件自带罗马音：`romanization` 字段，或者双语 LRC 里这一行跟着一条读音行。
    public static func hasAuthoredRomanization(_ line: LyricLine, readingIDs: Set<String>) -> Bool {
        if let romanization = line.romanization,
           !romanization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return line.allManualTranslations.contains { readingIDs.contains($0.id) }
    }

    static func classify(
        text: String,
        counts: LyricRomanizationScriptPolicy.Counts,
        documentHasKana: Bool,
        documentCyrillicCode: String = "ru",
        declaredLanguageCode: String?
    ) -> (language: LyricRomanizationLanguage, code: String)? {
        let declared = declaredLanguageCode.map { LyricTranslationGroupingPolicy.languageIdentity($0) }
        let declaredBase = declared.map(LyricRomanizationLanguagePolicy.baseLanguage)
        if counts.kana > 0 { return (.japanese, "ja") }
        if counts.hangul > 0, counts.hangul >= counts.han { return (.korean, "ko") }
        if counts.han > 0 {
            if documentHasKana || declaredBase == "ja" { return (.japanese, "ja") }
            if declaredBase == "ko" { return (.korean, "ko") }
            return (.chinese, chineseCode(declared: declared))
        }
        if counts.hangul > 0 { return (.korean, "ko") }
        guard let script = counts.dominantOtherScript else { return nil }
        if script == .cyrillic { return (.other, documentCyrillicCode) }
        return (.other, LyricRomanizationScriptPolicy.languageCode(for: script, text: text))
    }

    private static func chineseCode(declared: String?) -> String {
        guard let declared else { return "zh" }
        let lower = declared.lowercased()
        if lower.contains("hant") { return "zh-Hant" }
        if lower.contains("hans") { return "zh-Hans" }
        return "zh"
    }
}

// MARK: - 显示

/// 播放页拿来显示罗马音的那份结果：自动生成的罗马音按行，加上双语 LRC 里哪些附属行其实是读音。
public struct LyricRomanizationOverlay: Equatable, Sendable {
    public var generatedTextByLineID: [String: String]
    public var readingTranslationIDs: Set<String>

    public init(generatedTextByLineID: [String: String] = [:], readingTranslationIDs: Set<String> = []) {
        self.generatedTextByLineID = generatedTextByLineID
        self.readingTranslationIDs = readingTranslationIDs
    }

    public static let empty = LyricRomanizationOverlay()

    public var isEmpty: Bool { generatedTextByLineID.isEmpty && readingTranslationIDs.isEmpty }
}

/// 一行歌词按罗马音设置该怎么显示：正文是什么、下面跟着哪些附属文本。
public struct LyricRomanizationRowPresentation: Equatable, Sendable {
    /// 这一行的正文。「只显示罗马音」且有罗马音时就是罗马音，否则是原文。
    public var text: String
    /// 正文换成了罗马音：罗马音没有逐字时间，这一行按整行高亮，不做逐字扫光。
    public var showsRomanizationAsText: Bool
    /// 显示用的这一行（正文、逐字时间、罗马音字段都已按设置处理）。逐字歌词照它的
    /// `isWordLevel` 决定是否扫光。
    public var line: LyricLine
    /// 正文下面的附属文本，顺序同 `LyricCompanionTextPolicy`：罗马音、文件自带的
    /// 注音与译文、翻译任务的译文。未包 FSI/PDI，上屏前用 `LyricCompanionTextPolicy.displayText`。
    public var companions: [String]
}

/// 罗马音的显示层变换。只改显示用的那份歌词：翻译、点歌词跳转、歌词海报、编辑器仍用原文。
public enum LyricRomanizationDisplayPolicy {
    /// 文件自带罗马音与生成罗马音放在一起之后，这一行罗马音该放哪儿。
    public struct Decision: Equatable, Sendable {
        /// 「只显示罗马音」时替换正文的文字。
        public var replacementText: String?
        /// 排在原文下面的罗马音（原文与译文之间）。
        public var companion: String?

        public init(replacementText: String? = nil, companion: String? = nil) {
            self.replacementText = replacementText
            self.companion = companion
        }
    }

    /// 文件自带的罗马音优先，其次是生成的；`hidden` 时都不显示。
    public static func decision(
        authored: String?,
        generated: String?,
        mode: LyricRomanizationDisplayMode
    ) -> Decision {
        let romanization = normalized(authored) ?? normalized(generated)
        switch mode {
        case .belowOriginal:
            return Decision(replacementText: nil, companion: romanization)
        case .romanizationOnly:
            return Decision(replacementText: romanization, companion: nil)
        case .hidden:
            return Decision(replacementText: nil, companion: nil)
        }
    }

    /// 给歌名下面那一行之类的单行显示用：一行歌词、这一行生成的罗马音、显示方式，
    /// 得出这一行该显示的正文与附属文本。
    public static func row(
        for line: LyricLine,
        generatedRomanization: String?,
        mode: LyricRomanizationDisplayMode,
        translatedText: String? = nil,
        readingTranslationIDs: Set<String> = []
    ) -> LyricRomanizationRowPresentation {
        let display = displayLine(
            line,
            generatedRomanization: generatedRomanization,
            generatedForBackground: [:],
            mode: mode,
            readingTranslationIDs: readingTranslationIDs
        )
        return LyricRomanizationRowPresentation(
            text: display.text,
            showsRomanizationAsText: display.text != line.text,
            line: display,
            companions: LyricCompanionTextPolicy.texts(for: display, translatedText: translatedText)
        )
    }

    /// 整首歌词按设置变换一遍，给歌词列表与全屏舞台显示。行 id、时间戳不变，
    /// 当前行、点歌词跳转照旧对得上。没有要改的时候原样返回（不复制）。
    public static func displayLines(
        _ lines: [LyricLine],
        overlay: LyricRomanizationOverlay,
        mode: LyricRomanizationDisplayMode
    ) -> [LyricLine] {
        switch mode {
        case .belowOriginal:
            guard !overlay.generatedTextByLineID.isEmpty else { return lines }
        case .romanizationOnly:
            guard !overlay.isEmpty || lines.contains(where: hasRomanizationField) else { return lines }
        case .hidden:
            guard !overlay.readingTranslationIDs.isEmpty || lines.contains(where: hasRomanizationField) else {
                return lines
            }
        }
        return lines.map {
            displayLine(
                $0,
                generatedRomanization: overlay.generatedTextByLineID[$0.id],
                generatedForBackground: overlay.generatedTextByLineID,
                mode: mode,
                readingTranslationIDs: overlay.readingTranslationIDs
            )
        }
    }

    static func displayLine(
        _ line: LyricLine,
        generatedRomanization: String?,
        generatedForBackground: [String: String],
        mode: LyricRomanizationDisplayMode,
        readingTranslationIDs: Set<String>
    ) -> LyricLine {
        var display = line
        let readingRow = line.allManualTranslations.first { readingTranslationIDs.contains($0.id) }
        let authored = normalized(line.romanization) ?? normalized(readingRow?.text)
        let resolved = Self.decision(authored: authored, generated: generatedRomanization, mode: mode)

        switch mode {
        case .belowOriginal:
            // 双语 LRC 的读音行本来就排在原文下面，不用再挪。
            if normalized(line.romanization) == nil, readingRow == nil {
                display.romanization = resolved.companion
            }
        case .romanizationOnly:
            if let replacement = resolved.replacementText {
                display.endTimestamp = line.endTime
                display.syllables = nil
                display.text = replacement
            }
            display.romanization = nil
            removeReadings(from: &display, readingTranslationIDs: readingTranslationIDs)
        case .hidden:
            display.romanization = nil
            removeReadings(from: &display, readingTranslationIDs: readingTranslationIDs)
        }

        if let background = line.background {
            display.background = background.map {
                displayLine(
                    $0,
                    generatedRomanization: generatedForBackground[$0.id],
                    generatedForBackground: [:],
                    mode: mode,
                    readingTranslationIDs: readingTranslationIDs
                )
            }
        }
        return display
    }

    private static func removeReadings(from line: inout LyricLine, readingTranslationIDs: Set<String>) {
        guard !readingTranslationIDs.isEmpty else { return }
        let kept = line.allManualTranslations.filter { !readingTranslationIDs.contains($0.id) }
        guard kept.count != line.allManualTranslations.count else { return }
        line.manualTranslation = kept.first
        line.alternateManualTranslations = Array(kept.dropFirst())
    }

    private static func hasRomanizationField(_ line: LyricLine) -> Bool {
        normalized(line.romanization) != nil
            || (line.background?.contains { normalized($0.romanization) != nil } ?? false)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - 结果缓存键

/// 生成结果的缓存键：引擎、引擎版本、语言、这组歌词原文的指纹。歌词改了指纹就变，
/// 旧结果自然用不上；换了引擎或引擎升级也一样。
public struct LyricRomanizationCacheKey: Hashable, Sendable {
    public let engineID: String
    public let engineVersion: String
    public let languageCode: String
    public let contentFingerprint: String

    public init(engineID: String, engineVersion: String, languageCode: String, texts: [String]) {
        self.engineID = engineID
        self.engineVersion = engineVersion
        self.languageCode = languageCode
        self.contentFingerprint = Self.fingerprint(of: texts)
    }

    /// 两路 64 位 FNV-1a（不同前缀）拼成 32 位十六进制。只用来认内容，不涉及安全。
    public static func fingerprint(of texts: [String]) -> String {
        let joined = "\(texts.count)\u{1E}" + texts.joined(separator: "\u{1F}")
        return StableFNV1a64.hexDigest(joined) + StableFNV1a64.hexDigest("romanization\u{1E}" + joined)
    }

    /// 磁盘文件名：所有字段一起取指纹，引擎 id 里有什么字符都不会进路径。
    public var storageName: String {
        let identity = [engineID, engineVersion, languageCode, contentFingerprint].joined(separator: "\u{1F}")
        return StableFNV1a64.hexDigest(identity) + StableFNV1a64.hexDigest("key\u{1E}" + identity)
    }
}
