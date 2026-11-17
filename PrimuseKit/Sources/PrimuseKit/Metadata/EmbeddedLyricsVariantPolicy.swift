import Foundation

/// 一个音频文件里内嵌了不止一份同一首歌的歌词时（纯文本、逐行、逐字各一份，同一种语言写了两遍，
/// FLAC 的 LYRICS 与 SYNCEDLYRICS 并存……）显示哪一份。设置里可以选，默认时间轴最细的那份。
///
/// 只管「原文」：标明是译文的字段、标了另一种语言的那份照旧当译文候选，不参与这里的挑选。
public enum EmbeddedLyricsVariantPriority: String, CaseIterable, Sendable {
    /// 逐字 > 逐行 > 纯文本；一样细的取文件里排在前面的。
    case finestTiming
    /// 文件里排在前面的那份，不看有没有时间轴。
    case firstInFile

    public static let storageKey = "primuse.lyrics.embeddedVariantPriority.v1"
    public static let defaultValue: Self = .finestTiming

    /// 读标签、换歌词时用的那一档。认不出的存值按默认。
    public static func current(_ defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

/// 文件里的一份歌词原文。`languageCode` 是标签上写的语言（ID3 的 USLT/SYLT 语言、字段名后缀），
/// 没写或写的是 `und` 时为 nil。
public struct EmbeddedLyricsVariant: Codable, Hashable, Sendable {
    public var text: String
    public var languageCode: String?

    public init(text: String, languageCode: String? = nil) {
        self.text = text
        self.languageCode = languageCode
    }
}

public enum EmbeddedLyricsVariantPolicy {
    /// 按在文件里的先后记下一份。内容相同的只记第一次（顺带补上语言）。
    public static func append(
        _ text: String?,
        languageCode: String?,
        to variants: inout [EmbeddedLyricsVariant]
    ) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = variants.firstIndex(where: { $0.text == text }) {
            if variants[index].languageCode == nil {
                variants[index].languageCode = languageCode
            }
            return
        }
        variants.append(EmbeddedLyricsVariant(text: text, languageCode: languageCode))
    }

    /// 几份里显示哪一份。没有候选时为 nil。
    public static func preferredIndex(
        in variants: [EmbeddedLyricsVariant],
        priority: EmbeddedLyricsVariantPriority
    ) -> Int? {
        guard !variants.isEmpty else { return nil }
        switch priority {
        case .firstInFile:
            return variants.startIndex
        case .finestTiming:
            var best = variants.startIndex
            var bestRank = rank(of: variants[best].text)
            for index in variants.indices.dropFirst() {
                let candidate = rank(of: variants[index].text)
                // 严格更细才换：一样细的留排在前面的。
                if candidate > bestRank {
                    best = index
                    bestRank = candidate
                }
            }
            return best
        }
    }

    public static func preferred(
        in variants: [EmbeddedLyricsVariant],
        priority: EmbeddedLyricsVariantPriority
    ) -> EmbeddedLyricsVariant? {
        preferredIndex(in: variants, priority: priority).map { variants[$0] }
    }

    private static func rank(of text: String) -> Int {
        switch LyricsFormat.detect(text) {
        case .plain: return 0
        case .lineLevel: return 1
        case .wordLevel: return 2
        }
    }
}

/// 读标签时记下的内嵌歌词全貌：几份原文和译文字段。只在原文不止一份时才存，
/// 设置改了以后不用重读文件，按新的那一档重新挑一份。
public struct EmbeddedLyricsAlternatives: Codable, Hashable, Sendable {
    public var variants: [EmbeddedLyricsVariant]
    public var lyricsLanguageCode: String?
    public var translatedLyricsText: String?
    public var translatedLyricsLanguageCode: String?
    public var languageTaggedLyrics: [String: String]
    public var languageTaggedTranslations: [String: String]

    public init(
        variants: [EmbeddedLyricsVariant],
        lyricsLanguageCode: String? = nil,
        translatedLyricsText: String? = nil,
        translatedLyricsLanguageCode: String? = nil,
        languageTaggedLyrics: [String: String] = [:],
        languageTaggedTranslations: [String: String] = [:]
    ) {
        self.variants = variants
        self.lyricsLanguageCode = lyricsLanguageCode
        self.translatedLyricsText = translatedLyricsText
        self.translatedLyricsLanguageCode = translatedLyricsLanguageCode
        self.languageTaggedLyrics = languageTaggedLyrics
        self.languageTaggedTranslations = languageTaggedTranslations
    }

    /// 原文只有一份时没什么可挑的，不存。
    public var offersChoice: Bool { variants.count > 1 }
}
