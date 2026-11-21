import Foundation

/// 一个音频文件里内嵌了不止一份同一首歌的歌词时（纯文本、逐行、逐字各一份，同一种语言写了两遍，
/// FLAC 的 LYRICS 与 SYNCEDLYRICS 并存……）显示哪一份。设置里可以选，默认时间轴最细的那份。
///
/// 只管「原文」：标明是译文的字段、标了另一种语言的那份照旧当译文候选，不参与这里的挑选。
public enum EmbeddedLyricsVariantPriority: String, CaseIterable, Sendable {
    // Keep the original stored value for listeners upgrading from Finest Timing.
    case timingType = "finestTiming"
    case lyricsFormat
    case firstInFile

    public static let storageKey = "primuse.lyrics.embeddedVariantPriority.v1"
    public static let timingOrderKey = "primuse.lyrics.embeddedTimingOrder.v1"
    public static let formatOrderKey = "primuse.lyrics.embeddedFormatOrder.v1"
    public static let defaultValue: Self = .timingType

    private var defaultOrder: [String] {
        switch self {
        case .timingType: [LyricsFormat.wordLevel, .lineLevel, .plain].map(\.rawValue)
        case .lyricsFormat: EmbeddedLyricsContentFormat.allCases.map(\.rawValue)
        case .firstInFile: []
        }
    }

    public func order(from stored: String?) -> [String] {
        let available = defaultOrder
        var remaining = Set(available)
        let known = (stored ?? "").split(separator: ",").map(String.init).filter {
            remaining.remove($0) != nil
        }
        return known + available.filter(remaining.contains)
    }

    fileprivate func storedOrder(in defaults: UserDefaults) -> String? {
        switch self {
        case .timingType: defaults.string(forKey: Self.timingOrderKey)
        case .lyricsFormat: defaults.string(forKey: Self.formatOrderKey)
        case .firstInFile: nil
        }
    }

    /// 读标签、换歌词时用的那一档。认不出的存值按默认。
    public static func current(_ defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

/// Formats distinguishable from the embedded text, which has no filename extension.
public enum EmbeddedLyricsContentFormat: String, CaseIterable, Sendable {
    case ttml, lrc, lys, yrc, qrc, krc, webVTT, subRip, substationAlpha, plainText

    static func detect(_ text: String, timing: LyricsTimingLevel) -> Self {
        if LyricsContentParser.isTTML(text) { return .ttml }
        if let format = WordTimedLyricsParser.detect(text) {
            switch format {
            case .lys: return .lys
            case .yrc: return .yrc
            case .qrc: return .qrc
            case .krc: return .krc
            }
        }
        switch SubtitleLyricsParser.detect(text) {
        case .webVTT: return .webVTT
        case .subRip: return .subRip
        case .substationAlpha: return .substationAlpha
        case nil: return timing == .plain ? .plainText : .lrc
        }
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
        priority: EmbeddedLyricsVariantPriority,
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard variants.count > 1 else { return variants.indices.first }
        let order = priority.order(from: priority.storedOrder(in: defaults))
        var best: Int?
        var bestRank = (Int.max, Int.max)
        for (index, variant) in variants.enumerated() {
            let lines = LyricsContentParser.parseText(variant.text)
            guard !lines.isEmpty else { continue }
            if priority == .firstInFile { return index }
            let timing = LyricsTimingLevel(lines: lines)
            let id: String
            if priority == .timingType {
                let type: LyricsFormat = switch timing {
                case .word: .wordLevel
                case .line: .lineLevel
                case .plain: .plain
                }
                id = type.rawValue
            } else {
                id = EmbeddedLyricsContentFormat.detect(variant.text, timing: timing).rawValue
            }
            // Within one format, keep the finer timing. Equal ranks retain file order.
            let rank = (order.firstIndex(of: id) ?? order.count, -timing.rawValue)
            if rank < bestRank {
                bestRank = rank
                best = index
            }
        }
        return best
    }

    public static func preferred(
        in variants: [EmbeddedLyricsVariant],
        priority: EmbeddedLyricsVariantPriority
    ) -> EmbeddedLyricsVariant? {
        preferredIndex(in: variants, priority: priority).map { variants[$0] }
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
    /// Primuse 上次写进文件、正在用的那一份原文（按字段替换之后记下）。读标签时记下的没有这一项。
    public var inUseText: String?

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
