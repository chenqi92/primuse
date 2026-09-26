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
    private static let preparationRequestMaximumAge: TimeInterval = 30

    /// Only a direct tap on the in-player translation action issues this
    /// process-local revision. Persisted settings, song changes and view remounts
    /// therefore cannot authorize system language-pack UI by themselves.
    private(set) var systemPreparationRequestRevision: UInt = 0
    private var systemPreparationRequestGate = LyricTranslationPreparationRequestGate()

    var isEnabled: Bool {
        didSet {
            if !isEnabled { systemPreparationRequestGate.invalidate() }
            persist()
            LyricsTranslationSettingsStore.notifyChanged()
        }
    }

    var mode: LyricsTranslationMode {
        didSet {
            if mode != oldValue { systemPreparationRequestGate.invalidate() }
            persist()
            LyricsTranslationSettingsStore.notifyChanged()
        }
    }

    /// BCP-47 语言标识 (例如 "zh-Hans" / "zh-Hant" / "en" / "ja")。
    /// 默认跟随系统首选语言, 第一次启动按 Locale.preferredLanguages 推断。
    var targetLanguageCode: String {
        didSet {
            if targetLanguageCode != oldValue { systemPreparationRequestGate.invalidate() }
            persist()
            LyricsTranslationSettingsStore.notifyChanged()
        }
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
        ("ru", "lang_ru"),
        // Persian stays reachable for the explicitly configured intelligent/
        // custom-provider mode. Its presence here is not a claim that Apple
        // Translation supports this target; system mode reports it unsupported.
        ("fa", "fa")
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
    nonisolated static func normalizedLanguageCode(_ raw: String) -> String {
        let identity = LyricTranslationGroupingPolicy.languageIdentity(raw)
        return identity.isEmpty ? "zh-Hans" : identity
    }

    nonisolated static func detectedLanguageCode(
        for text: String,
        minimumConfidence: Double = 0.55,
        fallbackLanguageCode: String? = nil,
        declaredLanguageCode: String? = nil
    ) -> String? {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(1_000)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let hypothesis = hypotheses.first else {
            return nil
        }
        if let corrected = LyricTranslationGroupingPolicy.correctedPersianLanguageCode(
            text: sample,
            detectedLanguageCode: hypothesis.key.rawValue,
            fallbackSourceLanguageCode: fallbackLanguageCode,
            declaredSourceLanguageCode: declaredLanguageCode
        ) {
            return corrected
        }
        let reconciled = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: sample,
            detectedLanguageCode: hypothesis.key.rawValue,
            confidence: hypothesis.value,
            alternativeConfidence: hypotheses.dropFirst().first?.value ?? 0,
            fallbackSourceLanguageCode: fallbackLanguageCode
        )
        if hypothesis.value >= minimumConfidence {
            return reconciled
        }
        guard let reconciled, let fallbackLanguageCode,
              LyricTranslationGroupingPolicy.languageIdentity(reconciled)
                != LyricTranslationGroupingPolicy.languageIdentity(fallbackLanguageCode) else {
            return nil
        }
        return reconciled
    }

    nonisolated static func detectedLyricsLanguageCode(
        for texts: [String],
        metadataLines: [String] = []
    ) -> String? {
        if let declared = declaredLyricsLanguageCode(from: metadataLines) {
            return declared
        }
        let sample = texts
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(80)
            .joined(separator: "\n")
        guard !sample.isEmpty else { return nil }
        return detectedLanguageCode(
            for: String(sample.prefix(4_000)),
            minimumConfidence: 0.65
        )
    }

    nonisolated static func declaredLyricsLanguageCode(from metadataLines: [String]) -> String? {
        LyricTranslationGroupingPolicy.declaredLanguageCode(in: metadataLines)
    }

    /// Returns false when the lyric body is confidently already in the target
    /// language. Apple Translation reports that normal no-op case as an error
    /// (for example Simplified Chinese → Simplified Chinese); treating it as a
    /// failed translation pollutes logs and the negative cache. Script variants
    /// remain distinct so zh-Hant → zh-Hans conversion is still attempted.
    static func lyricsNeedTranslation(_ texts: [String], targetLanguageCode: String) -> Bool {
        guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return false }
        return lyricsNeedTranslation(
            detectedSourceLanguageCode: detectedLyricsLanguageCode(for: texts),
            targetLanguageCode: targetLanguageCode
        )
    }

    static func lyricsNeedTranslation(
        detectedSourceLanguageCode: String?,
        targetLanguageCode: String
    ) -> Bool {
        return LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: detectedSourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }

    func requestSystemTranslationPreparation() {
        guard isEnabled else { return }
        systemPreparationRequestRevision = systemPreparationRequestGate.issue()
    }

    func consumeSystemTranslationPreparationRequest(revision: UInt) -> Bool {
        systemPreparationRequestGate.consume(
            revision: revision,
            maximumAge: Self.preparationRequestMaximumAge
        )
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
        let codes = (supported + ["fa"]).compactMap { identifier -> String? in
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

/// Pure preparation is shared across player presentations and stays off the UI executor.
actor LyricsTranslationPreparer {
    static let shared = LyricsTranslationPreparer()

    struct Prepared: Equatable, Sendable {
        let manualTranslations: [String: String]
        let groups: [LyricTranslationGroup]
        var requiresPreparation = false
    }

    private struct Key: Hashable {
        let lyrics: [LyricLine]
        let targetLanguageCode: String
        let enabled: Bool
    }

    private var cached: [(Key, Prepared)] = []

    func prepare(lyrics: [LyricLine], targetLanguageCode: String, enabled: Bool) throws -> Prepared {
        try Task.checkCancellation()
        let key = Key(lyrics: lyrics, targetLanguageCode: targetLanguageCode, enabled: enabled)
        if let index = cached.firstIndex(where: { $0.0 == key }) {
            let hit = cached.remove(at: index)
            cached.append(hit)
            return hit.1
        }
        let result = try makePreparation(lyrics: lyrics, targetLanguageCode: targetLanguageCode, enabled: enabled)
        try Task.checkCancellation()
        cached.append((key, result))
        if cached.count > 4 { cached.removeFirst() }
        return result
    }

    private func makePreparation(lyrics: [LyricLine], targetLanguageCode: String, enabled: Bool) throws -> Prepared {
        let translationLines = LyricVoiceTimelinePolicy.flattenedLines(lyrics)
        // 罗马音 / 拼音这类读音行按整篇判一次，逐行选译文时把它们排除掉。
        let readingIDs = LyricRomanizedReadingPolicy.readingIDs(in: translationLines)
        let manualTranslations = translationLines.reduce(into: [String: String]()) { result, line in
            guard let manualTranslation = LyricManualTranslationPolicy.preferredTranslation(
                for: line,
                targetLanguageCode: targetLanguageCode,
                readingIDs: readingIDs
            ) else { return }
            let text = manualTranslation.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            result[line.id] = text
        }

        guard enabled, !lyrics.isEmpty else {
            return Prepared(manualTranslations: manualTranslations, groups: [])
        }
        if LyricManualTranslationPolicy.hasCompleteCoverage(
            in: translationLines,
            targetLanguageCode: targetLanguageCode,
            readingIDs: readingIDs
        ) {
            return Prepared(manualTranslations: manualTranslations, groups: [])
        }

        let lyricTexts = translationLines.map(\.text)
        let metadataLines = lyrics.lazy.compactMap(\.metadataLines).first ?? []
        let declaredSourceLanguageCode = LyricsTranslationSettingsStore
            .declaredLyricsLanguageCode(from: metadataLines)
        let fallbackSourceLanguageCode = LyricsTranslationSettingsStore.detectedLyricsLanguageCode(
            for: lyricTexts,
            metadataLines: metadataLines
        )
        let candidates = try translationLines.compactMap { line -> LyricTranslationCandidate? in
            try Task.checkCancellation()
            guard manualTranslations[line.id] == nil else { return nil }
            let lineDeclaredLanguageCode = line.languageCode ?? declaredSourceLanguageCode
            return LyricTranslationCandidate(
                id: line.id,
                text: line.text,
                sourceLanguageCode: LyricsTranslationSettingsStore.detectedLanguageCode(
                    for: line.text,
                    fallbackLanguageCode: fallbackSourceLanguageCode,
                    declaredLanguageCode: lineDeclaredLanguageCode
                )
            )
        }
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: candidates,
            targetLanguageCode: targetLanguageCode,
            fallbackSourceLanguageCode: fallbackSourceLanguageCode
        )
        return Prepared(manualTranslations: manualTranslations, groups: groups, requiresPreparation: true)
    }
}
