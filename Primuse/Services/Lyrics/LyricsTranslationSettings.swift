import Foundation
import NaturalLanguage
import PrimuseKit
#if !os(tvOS)
import Translation
#endif

enum LyricsTranslationMode: String, Codable, CaseIterable, Sendable {
    case system
    case intelligentWithSystemFallback
    /// 百度翻译开放平台，用自己的 APP ID 与密钥(#320)；没填好或出错时同样改用系统翻译。
    case baidu
}

/// 歌词翻译设置 — 启用开关 + 目标语言。
/// 翻译用 Apple 自带 Translation Framework (iOS 18+ / macOS 15+),
/// 离线 + 免费 + 不需要任何 API key 注册。
@MainActor
@Observable
final class LyricsTranslationSettingsStore {
    static let shared = LyricsTranslationSettingsStore()

    private static let userDefaultsKey = "primuse.lyrics.translation.settings.v1"
    /// 选了「点了再翻译」后点过翻译的有声内容条目,只存本机。
    private static let approvedSpokenWordItemsKey = "primuse.lyrics.translation.spokenWordApproved.v1"
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

    /// 歌词文件里本来就有的译文要不要显示。和机翻开关分开：关掉机翻的人照样看自带译文，
    /// 这里关掉后只剩原文和读音行；开着机翻时整首改由机翻（见 `LyricBundledTranslationPolicy`）。
    var showsBundledTranslations: Bool {
        didSet {
            guard showsBundledTranslations != oldValue else { return }
            persist()
            LyricsTranslationSettingsStore.notifyChanged()
        }
    }

    /// 播客、有声书的文字稿是换到这一条就翻,还是在文字稿上点了才翻(#336)。
    var spokenWordTranslationTiming: SpokenWordTranslationTiming {
        didSet {
            guard spokenWordTranslationTiming != oldValue else { return }
            persist()
            LyricsTranslationSettingsStore.notifyChanged()
        }
    }

    /// 点过「翻译这份文字稿」的条目,最近点的在最后。
    private(set) var approvedSpokenWordItemIDs: [String]

    /// 这一条有声内容的文稿要不要等用户点了再翻。
    func spokenWordTranslationAwaitsRequest(itemID: String?, isSpokenWord: Bool) -> Bool {
        SpokenWordTranslationRequestPolicy.awaitsRequest(
            timing: spokenWordTranslationTiming,
            isSpokenWord: isSpokenWord,
            itemID: itemID,
            approvedItemIDs: approvedSpokenWordItemIDs
        )
    }

    /// 文字稿上点了「翻译这份文字稿」:这一条现在就翻,以后也照常翻。
    func requestSpokenWordTranslation(itemID: String) {
        approvedSpokenWordItemIDs = SpokenWordTranslationRequestPolicy.approving(
            itemID,
            in: approvedSpokenWordItemIDs
        )
        UserDefaults.standard.set(approvedSpokenWordItemIDs, forKey: Self.approvedSpokenWordItemsKey)
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

    /// 不翻译的语言:这些语言的歌词保持原文(和目标语言相同的本来就不翻译)。存的是
    /// 归一化后的语言身份,简繁中文各是一项。
    private(set) var skippedSourceLanguageCodes: [String] {
        didSet {
            guard skippedSourceLanguageCodes != oldValue else { return }
            systemPreparationRequestGate.invalidate()
            persist()
            LyricsTranslationSettingsStore.notifyChanged()
        }
    }

    func isSourceLanguageSkipped(_ code: String) -> Bool {
        skippedSourceLanguageCodes.contains(Self.normalizedLanguageCode(code))
    }

    func setSourceLanguage(_ code: String, skipped: Bool) {
        let normalized = Self.normalizedLanguageCode(code)
        var codes = skippedSourceLanguageCodes.filter { $0 != normalized }
        if skipped { codes.append(normalized) }
        skippedSourceLanguageCodes = Self.normalizedSkippedLanguageCodes(codes)
    }

    /// 设置行右侧的摘要:没有就写「无」,和目标语言相同的那项不算(它本来就不翻译)。
    static func skippedLanguagesSummary(
        _ skipped: [String],
        targetLanguageCode: String,
        displayName: (String) -> String
    ) -> String {
        let names = skipped
            .filter {
                !LyricTranslationGroupingPolicy.representsSameTranslationLanguage($0, targetLanguageCode)
            }
            .map(displayName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else {
            return String(localized: "lyrics_translation_skipped_languages_none")
        }
        return names.formatted(.list(type: .and, width: .narrow))
    }

    /// 去重并排序,设置变化与任务身份只认内容不认点选顺序。
    nonisolated static func normalizedSkippedLanguageCodes(_ codes: [String]) -> [String] {
        Array(Set(codes.map(normalizedLanguageCode))).sorted()
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

    /// Apple TV 没有系统翻译,离线翻译包能译成的语言:英语 ↔ 波斯语、英语 ↔ 简繁中文 /
    /// 日语 / 韩语,这几种之间经英语中转。
    static let offlinePackTargetLanguages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fa"]

    /// 电视上「翻译为」可选的语言:智能翻译能译成常用语言,离线翻译包只有它覆盖的几种。
    static func tvTargetLanguages(intelligent: Bool) -> [String] {
        intelligent ? availableTargetLanguages.map(\.code) : offlinePackTargetLanguages
    }

    /// `codes` 里没有 `current` 时换一个:先看系统首选语言,再退到英语。
    static func target(_ current: String, within codes: [String]) -> String {
        func match(_ code: String) -> String? {
            codes.first {
                LyricTranslationGroupingPolicy.representsSameTranslationLanguage(
                    $0, normalizedLanguageCode(code)
                )
            }
        }
        return match(current)
            ?? Locale.preferredLanguages.lazy.compactMap(match).first
            ?? codes.first { $0 == LocalLyricTranslationPolicy.englishIdentity }
            ?? codes.first
            ?? current
    }

    private init() {
        var isEnabled = false
        var targetLanguageCode: String
        var mode = LyricsTranslationMode.system
        var skippedSourceLanguageCodes: [String] = []
        var showsBundledTranslations = true
        var spokenWordTranslationTiming = SpokenWordTranslationTiming.automatic
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            isEnabled = decoded.isEnabled
            targetLanguageCode = decoded.targetLanguageCode
            mode = decoded.mode.flatMap(LyricsTranslationMode.init(rawValue:)) ?? .system
            skippedSourceLanguageCodes = Self.normalizedSkippedLanguageCodes(
                decoded.skippedSourceLanguageCodes ?? []
            )
            showsBundledTranslations = decoded.showsBundledTranslations ?? true
            spokenWordTranslationTiming = decoded.spokenWordTranslationTiming
                .flatMap(SpokenWordTranslationTiming.init(rawValue:)) ?? .automatic
        } else {
            // 取 user 系统首选语言, 跟 region 无关用 base code 简化匹配
            let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
            targetLanguageCode = Self.normalizedLanguageCode(preferred)
        }
        #if DEBUG
        // Build-host runs turn translation on with a target language. Applied
        // before the properties are initialized, so nothing is persisted and
        // no change notification fires while `shared` is still being created.
        if let target = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_LYRICS_TRANSLATION_TARGET"] {
            isEnabled = true
            targetLanguageCode = Self.normalizedLanguageCode(target)
        }
        #endif
        self.isEnabled = isEnabled
        self.targetLanguageCode = targetLanguageCode
        self.mode = mode
        self.skippedSourceLanguageCodes = skippedSourceLanguageCodes
        self.showsBundledTranslations = showsBundledTranslations
        self.spokenWordTranslationTiming = spokenWordTranslationTiming
        self.approvedSpokenWordItemIDs = UserDefaults.standard
            .stringArray(forKey: Self.approvedSpokenWordItemsKey) ?? []
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
        let sample = texts
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(80)
            .joined(separator: "\n")
        // 文件标签写的语言(`[la:]`、ID3 语言码、TTML xml:lang)也要和歌词文字对得上:
        // 日文歌词标着波斯语时不采用,改按文字检测。
        if let declared = declaredLyricsLanguageCode(from: metadataLines),
           LyricTranslationGroupingPolicy.textCanBeWritten(in: declared, text: sample) {
            return declared
        }
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
            mode: mode.rawValue,
            skippedSourceLanguageCodes: skippedSourceLanguageCodes,
            showsBundledTranslations: showsBundledTranslations,
            spokenWordTranslationTiming: spokenWordTranslationTiming.rawValue
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
        /// 存成字符串：以后再加翻译方式，老版本读到认不出的值只退回系统翻译，不会整份设置丢掉。
        let mode: String?
        let skippedSourceLanguageCodes: [String]?
        let showsBundledTranslations: Bool?
        /// 和 `mode` 一样存字符串,认不出的值退回自动翻译。
        let spokenWordTranslationTiming: String?
    }
}

#if !os(tvOS)
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

    /// 「不翻译的语言」可勾的语言:和目标语言同一张表,去掉目标语言本身;已经勾了但表里
    /// 没有的(设备语言列表变了)也留着,好取消。
    func skippableLanguageCodes(excludingTarget target: String, including skipped: [String]) -> [String] {
        let extra = skipped.filter { !languageCodes.contains($0) }
        return (extra + languageCodes).filter {
            !LyricTranslationGroupingPolicy.representsSameTranslationLanguage($0, target)
        }
    }

    func skippedLanguagesSummary(_ skipped: [String], targetLanguageCode: String) -> String {
        LyricsTranslationSettingsStore.skippedLanguagesSummary(
            skipped,
            targetLanguageCode: targetLanguageCode,
            displayName: { displayName(for: $0) }
        )
    }
}
#endif

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
        /// 繁简字形互转在本机直接得出的「译文」，不走任何翻译服务。
        var scriptConversions: [String: String] = [:]
        /// 有声内容文稿里并进一句的后面几行(句首那一行 → 后面几行),它们不另写译文。
        var mergedLineIDs: [String: [String]] = [:]
    }

    private struct Key: Hashable {
        let lyrics: [LyricLine]
        let targetLanguageCode: String
        let skippedSourceLanguageCodes: [String]
        let enabled: Bool
        let songContext: LyricTranslationSongContext
    }

    private var cached: [(Key, Prepared)] = []

    func prepare(
        lyrics: [LyricLine], targetLanguageCode: String,
        skippedSourceLanguageCodes: [String] = [], enabled: Bool,
        songContext: LyricTranslationSongContext = .init()
    ) throws -> Prepared {
        try Task.checkCancellation()
        let key = Key(
            lyrics: lyrics, targetLanguageCode: targetLanguageCode,
            skippedSourceLanguageCodes: skippedSourceLanguageCodes,
            enabled: enabled, songContext: songContext
        )
        if let index = cached.firstIndex(where: { $0.0 == key }) {
            let hit = cached.remove(at: index)
            cached.append(hit)
            return hit.1
        }
        let result = try makePreparation(
            lyrics: lyrics, targetLanguageCode: targetLanguageCode,
            skippedSourceLanguageCodes: skippedSourceLanguageCodes,
            enabled: enabled, songContext: songContext
        )
        try Task.checkCancellation()
        cached.append((key, result))
        if cached.count > 4 { cached.removeFirst() }
        return result
    }

    private func makePreparation(
        lyrics: [LyricLine], targetLanguageCode: String,
        skippedSourceLanguageCodes: [String], enabled: Bool,
        songContext: LyricTranslationSongContext
    ) throws -> Prepared {
        let translationLines = LyricVoiceTimelinePolicy.flattenedLines(lyrics)
        let contentLines = LyricTranslationContentPolicy.contentLines(in: translationLines, song: songContext)
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

        guard enabled, !contentLines.isEmpty else {
            return Prepared(manualTranslations: manualTranslations, groups: [])
        }
        if LyricManualTranslationPolicy.hasCompleteCoverage(
            in: contentLines,
            targetLanguageCode: targetLanguageCode,
            readingIDs: readingIDs
        ) {
            return Prepared(manualTranslations: manualTranslations, groups: [])
        }

        let lyricTexts = contentLines.map(\.text)
        let metadataLines = lyrics.lazy.compactMap(\.metadataLines).first ?? []
        let declaredSourceLanguageCode = LyricsTranslationSettingsStore
            .declaredLyricsLanguageCode(from: metadataLines)
        let fallbackSourceLanguageCode = LyricsTranslationSettingsStore.detectedLyricsLanguageCode(
            for: lyricTexts,
            metadataLines: metadataLines
        )
        let candidates = try contentLines.compactMap { line -> LyricTranslationCandidate? in
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
        // 有声内容的文稿按停顿切行,半句半句地送去翻译译文对不上:没到句末的相邻几行并成一句再译(#336)。
        let sentences = songContext.isSpokenWord
            ? LyricTranslationSentenceMergePolicy.merged(candidates, targetLanguageCode: targetLanguageCode)
            : LyricTranslationSentenceMergePolicy.Merged(candidates: candidates)
        let converted = LyricChineseScriptConversionPolicy.apply(
            to: LyricTranslationGroupingPolicy.groups(
                candidates: sentences.candidates,
                targetLanguageCode: targetLanguageCode,
                fallbackSourceLanguageCode: fallbackSourceLanguageCode,
                skippedSourceLanguageCodes: skippedSourceLanguageCodes
            ),
            targetLanguageCode: targetLanguageCode
        )
        let groups = converted.remainingGroups
        return Prepared(
            manualTranslations: manualTranslations,
            groups: groups,
            requiresPreparation: !groups.isEmpty,
            scriptConversions: converted.conversions,
            mergedLineIDs: sentences.mergedLineIDs
        )
    }
}
