import Foundation
import NaturalLanguage
import PrimuseKit
import Translation

enum LyricsTranslationMode: String, Codable, CaseIterable, Sendable {
    case system
    case intelligentWithSystemFallback
}

/// 歌词翻译设置 — 启用开关 + 目标语言。
/// 翻译用 Apple 自带 Translation Framework (iOS 18+ / macOS 15+),
/// 离线 + 免费 + 不需要任何 API key 注册。
@MainActor
@Observable
final class LyricsTranslationSettingsStore {
    static let shared = LyricsTranslationSettingsStore()

    private static let userDefaultsKey = "primuse.lyrics.translation.settings.v1"

    var isEnabled: Bool {
        didSet { persist(); LyricsTranslationSettingsStore.notifyChanged() }
    }

    var mode: LyricsTranslationMode {
        didSet { persist(); LyricsTranslationSettingsStore.notifyChanged() }
    }

    /// BCP-47 语言标识 (例如 "zh-Hans" / "zh-Hant" / "en" / "ja")。
    /// 默认跟随系统首选语言, 第一次启动按 Locale.preferredLanguages 推断。
    var targetLanguageCode: String {
        didSet { persist(); LyricsTranslationSettingsStore.notifyChanged() }
    }

    /// `LanguageAvailability` 尚未返回结果时使用的离线候选。设置界面加载后
    /// 会改用设备当前真正支持的完整语言列表。
    static let availableTargetLanguages: [(code: String, displayKey: String)] = [
        ("zh-Hans", "lang_zh_hans"),
        ("zh-Hant", "lang_zh_hant"),
        ("en", "lang_en"),
        ("ja", "lang_ja"),
        ("ko", "lang_ko"),
        ("es", "lang_es"),
        ("fr", "lang_fr"),
        ("de", "lang_de"),
        ("ru", "lang_ru")
    ]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            self.isEnabled = decoded.isEnabled
            self.targetLanguageCode = decoded.targetLanguageCode
            self.mode = decoded.mode ?? .system
        } else {
            self.isEnabled = false
            // 取 user 系统首选语言, 跟 region 无关用 base code 简化匹配
            let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
            self.targetLanguageCode = Self.normalizedLanguageCode(preferred)
            self.mode = .system
        }
    }

    /// 把带 region 的 BCP-47 标识简化为 Translation 使用的语言身份，同时
    /// 保留会影响转换结果的 script（例如简体/繁体）。
    static func normalizedLanguageCode(_ raw: String) -> String {
        let identity = LyricTranslationGroupingPolicy.languageIdentity(raw)
        return identity.isEmpty ? "zh-Hans" : identity
    }

    static func detectedLanguageCode(
        for text: String,
        minimumConfidence: Double = 0.55
    ) -> String? {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(1_000)))
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
              hypothesis.value >= minimumConfidence else {
            return nil
        }
        return LyricTranslationGroupingPolicy.languageIdentity(hypothesis.key.rawValue)
    }

    /// Returns false when the lyric body is confidently already in the target
    /// language. Apple Translation reports that normal no-op case as an error
    /// (for example Simplified Chinese → Simplified Chinese); treating it as a
    /// failed translation pollutes logs and the negative cache. Script variants
    /// remain distinct so zh-Hant → zh-Hans conversion is still attempted.
    static func lyricsNeedTranslation(_ texts: [String], targetLanguageCode: String) -> Bool {
        let sample = texts
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(80)
            .joined(separator: "\n")
        guard !sample.isEmpty else { return false }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(4_000)))
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
              hypothesis.value >= 0.65 else {
            return true
        }
        return LyricTranslationGroupingPolicy.languageIdentity(hypothesis.key.rawValue)
            != LyricTranslationGroupingPolicy.languageIdentity(targetLanguageCode)
    }

    private func persist() {
        let p = Persisted(
            isEnabled: isEnabled,
            targetLanguageCode: targetLanguageCode,
            mode: mode
        )
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: .lyricsTranslationSettingsChanged, object: nil)
    }

    private struct Persisted: Codable {
        let isEnabled: Bool
        let targetLanguageCode: String
        let mode: LyricsTranslationMode?
    }
}

@MainActor
@Observable
final class LyricsTranslationLanguageCatalog {
    static let shared = LyricsTranslationLanguageCatalog()

    private(set) var languageCodes = LyricsTranslationSettingsStore
        .availableTargetLanguages
        .map { $0.code }
    private(set) var hasLoadedDeviceLanguages = false

    private init() {}

    func refresh() async {
        let supported = await Self.deviceSupportedLanguageIdentifiers()
        guard !Task.isCancelled else { return }

        var seen = Set<String>()
        let codes = supported.compactMap { identifier -> String? in
            let code = LyricsTranslationSettingsStore.normalizedLanguageCode(
                identifier
            )
            guard !code.isEmpty, seen.insert(code).inserted else { return nil }
            return code
        }
        .sorted { lhs, rhs in
            displayName(for: lhs).localizedStandardCompare(displayName(for: rhs)) == .orderedAscending
        }

        if !codes.isEmpty {
            languageCodes = codes
        }
        hasLoadedDeviceLanguages = true
    }

    /// Keep Translation's non-Sendable availability object inside a
    /// nonisolated operation and return only Sendable language identifiers to
    /// the main-actor settings model.
    private nonisolated static func deviceSupportedLanguageIdentifiers() async -> [String] {
        let supported = await LanguageAvailability().supportedLanguages
        return supported.map(\.minimalIdentifier)
    }

    func options(including selectedCode: String) -> [String] {
        guard !languageCodes.contains(selectedCode) else { return languageCodes }
        return [selectedCode] + languageCodes
    }

    func displayName(for code: String) -> String {
        Locale.autoupdatingCurrent.localizedString(forIdentifier: code) ?? code
    }
}

extension Notification.Name {
    static let lyricsTranslationSettingsChanged = Notification.Name("primuse.lyrics.translation.settingsChanged")
}
