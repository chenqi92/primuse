import Foundation
import PrimuseKit

/// 歌词翻译设置 — 启用开关 + 目标语言。
/// 翻译用 Apple 自带 Translation Framework (iOS 17.4+ / macOS 14.4+),
/// 离线 + 免费 + 不需要任何 API key 注册。
@MainActor
@Observable
final class LyricsTranslationSettingsStore {
    static let shared = LyricsTranslationSettingsStore()

    private static let userDefaultsKey = "primuse.lyrics.translation.settings.v1"

    var isEnabled: Bool {
        didSet { persist(); LyricsTranslationSettingsStore.notifyChanged() }
    }

    /// BCP-47 语言标识 (例如 "zh-Hans" / "zh-Hant" / "en" / "ja")。
    /// 默认跟随系统首选语言, 第一次启动按 Locale.preferredLanguages 推断。
    var targetLanguageCode: String {
        didSet { persist(); LyricsTranslationSettingsStore.notifyChanged() }
    }

    /// 候选目标语言 — 不全列, 只保留主流, 用户选其他可以拓展。
    /// Apple Translation 实际支持的语言对见 LanguageAvailability, 这里只
    /// 作 picker UI 候选, 实际翻不出来时由 view 端 fallback (隐藏翻译行)。
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
        } else {
            self.isEnabled = false
            // 取 user 系统首选语言, 跟 region 无关用 base code 简化匹配
            let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
            self.targetLanguageCode = Self.normalizedLanguageCode(preferred)
        }
    }

    /// 把 "zh-Hans-CN" / "en-US" 等带 region 的 BCP-47 标识简化为
    /// 我们 picker 里的候选 ("zh-Hans" / "en")。
    static func normalizedLanguageCode(_ raw: String) -> String {
        // 优先精确匹配
        if availableTargetLanguages.contains(where: { $0.code == raw }) {
            return raw
        }
        // 处理 zh-Hans-CN → zh-Hans
        let parts = raw.split(separator: "-")
        if parts.count >= 2 {
            let head = "\(parts[0])-\(parts[1])"
            if availableTargetLanguages.contains(where: { $0.code == head }) {
                return head
            }
        }
        // 退到主语言 ("en-US" → "en")
        if let first = parts.first {
            let primary = String(first)
            if availableTargetLanguages.contains(where: { $0.code == primary }) {
                return primary
            }
        }
        return "zh-Hans"
    }

    private func persist() {
        let p = Persisted(isEnabled: isEnabled, targetLanguageCode: targetLanguageCode)
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
    }
}

extension Notification.Name {
    static let lyricsTranslationSettingsChanged = Notification.Name("primuse.lyrics.translation.settingsChanged")
}
