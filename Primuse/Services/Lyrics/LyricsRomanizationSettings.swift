import Foundation
import Observation
import PrimuseKit

/// 歌词罗马音设置：怎么显示、要不要自动生成、给哪些语言生成、用什么方式生成。
/// 和歌词翻译设置一样只存在本机，不走 iCloud（「生成这些语言」的默认值跟着本机的系统语言走）。
@MainActor
@Observable
final class LyricsRomanizationSettingsStore {
    static let shared = LyricsRomanizationSettingsStore()
    @ObservationIgnored private var suppressPersist = false
    @ObservationIgnored private let defaults: UserDefaults

    static let storageKey = "primuse.lyrics.romanization.settings.v1"

    @ObservationIgnored private var lastVisibleMode: LyricRomanizationDisplayMode = .belowOriginal
    var displayMode: LyricRomanizationDisplayMode {
        didSet {
            guard displayMode != oldValue else { return }
            if displayMode != .hidden { lastVisibleMode = displayMode }
            persistAndNotify(generationChanged: false)
        }
    }

    func toggleVisibility() {
        displayMode = displayMode == .hidden ? lastVisibleMode : .hidden
    }

    var isAutoGenerationEnabled: Bool {
        didSet {
            guard isAutoGenerationEnabled != oldValue else { return }
            persistAndNotify()
        }
    }

    var method: LyricRomanizationMethod {
        didSet {
            guard method != oldValue else { return }
            persistAndNotify()
        }
    }

    /// 用户改过的语言开关；没改过的跟随系统首选语言给出的默认值。只经 `setLanguage` 赋值。
    private(set) var languageOverrides: [String: Bool] {
        didSet {
            guard languageOverrides != oldValue else { return }
            persistAndNotify()
        }
    }

    func isLanguageEnabled(_ language: LyricRomanizationLanguage) -> Bool {
        LyricRomanizationLanguagePolicy.isEnabled(
            language,
            overrides: languageOverrides,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    func setLanguage(_ language: LyricRomanizationLanguage, enabled: Bool) {
        var overrides = languageOverrides
        overrides[language.rawValue] = enabled
        languageOverrides = overrides
    }

    var enabledLanguages: Set<LyricRomanizationLanguage> {
        LyricRomanizationLanguagePolicy.enabledLanguages(
            overrides: languageOverrides,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    /// 设置行右侧的摘要：开着的语言，按「日语、韩语、中文、其他文字」的顺序。
    var enabledLanguagesSummary: String {
        let names = LyricRomanizationLanguage.allCases
            .filter(isLanguageEnabled)
            .map(\.localizedTitle)
        guard !names.isEmpty else { return String(localized: "lyrics_romanization_languages_none") }
        return names.formatted(.list(type: .and, width: .narrow))
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var displayMode = LyricRomanizationDisplayMode.defaultValue
        var isAutoGenerationEnabled = false
        var method = LyricRomanizationMethod.defaultValue
        var languageOverrides: [String: Bool] = [:]
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            displayMode = decoded.displayMode.flatMap(LyricRomanizationDisplayMode.init(rawValue:)) ?? displayMode
            let previous = decoded.lastVisibleMode.flatMap(LyricRomanizationDisplayMode.init(rawValue:))
            if let previous, previous != .hidden { lastVisibleMode = previous }
            isAutoGenerationEnabled = decoded.isAutoGenerationEnabled ?? false
            method = decoded.method.flatMap(LyricRomanizationMethod.init(rawValue:)) ?? method
            languageOverrides = decoded.languageOverrides ?? [:]
        }
        #if DEBUG
        // 编译机无人值守取证：直接打开自动生成并指定显示方式，不写进设置。
        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["PRIMUSE_DEBUG_LYRICS_ROMANIZATION"] {
            isAutoGenerationEnabled = true
            displayMode = LyricRomanizationDisplayMode(rawValue: mode) ?? .belowOriginal
        }
        #endif
        self.displayMode = displayMode
        if displayMode != .hidden { lastVisibleMode = displayMode }
        self.isAutoGenerationEnabled = isAutoGenerationEnabled
        self.method = method
        self.languageOverrides = languageOverrides
    }

    func reloadAfterOfflineImport() {
        let loaded = LyricsRomanizationSettingsStore(defaults: defaults)
        suppressPersist = true
        displayMode = loaded.displayMode
        lastVisibleMode = loaded.lastVisibleMode
        isAutoGenerationEnabled = loaded.isAutoGenerationEnabled
        method = loaded.method
        languageOverrides = loaded.languageOverrides
        suppressPersist = false
        NotificationCenter.default.post(name: .lyricsRomanizationSettingsChanged, object: nil)
    }

    private func persistAndNotify(generationChanged: Bool = true) {
        guard !suppressPersist else { return }
        let persisted = Persisted(
            displayMode: displayMode.rawValue,
            lastVisibleMode: lastVisibleMode.rawValue,
            isAutoGenerationEnabled: isAutoGenerationEnabled,
            method: method.rawValue,
            languageOverrides: languageOverrides
        )
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: Self.storageKey)
        }
        if generationChanged {
            NotificationCenter.default.post(name: .lyricsRomanizationSettingsChanged, object: nil)
        }
    }

    /// 取值都存成字符串：以后加了新的显示方式或生成方式，老版本读到认不出的值退回默认，不会整份丢掉。
    private struct Persisted: Codable {
        let displayMode: String?
        let lastVisibleMode: String?
        let isAutoGenerationEnabled: Bool?
        let method: String?
        let languageOverrides: [String: Bool]?
    }
}

extension Notification.Name {
    static let lyricsRomanizationSettingsChanged = Notification.Name("primuse.lyrics.romanization.settingsChanged")
}

extension LyricRomanizationLanguage {
    var localizedTitle: String {
        switch self {
        case .japanese: String(localized: "lyrics_romanization_language_japanese")
        case .korean: String(localized: "lyrics_romanization_language_korean")
        case .chinese: String(localized: "lyrics_romanization_language_chinese")
        case .other: String(localized: "lyrics_romanization_language_other")
        }
    }

    var localizedDetail: String? {
        switch self {
        case .chinese: String(localized: "lyrics_romanization_language_chinese_detail")
        case .other: String(localized: "lyrics_romanization_language_other_detail")
        case .japanese, .korean: nil
        }
    }
}

extension LyricRomanizationDisplayMode {
    var localizedTitle: String {
        switch self {
        case .belowOriginal: String(localized: "lyrics_romanization_display_below")
        case .romanizationOnly: String(localized: "lyrics_romanization_display_only")
        case .hidden: String(localized: "lyrics_romanization_display_hidden")
        }
    }
}

extension LyricRomanizationMethod {
    var localizedTitle: String {
        switch self {
        case .local: String(localized: "lyrics_romanization_method_local")
        case .intelligent: String(localized: "lyrics_romanization_method_intelligent")
        case .googleCloud: String(localized: "lyrics_romanization_method_google")
        }
    }

    /// 这个地区、这台设备上能选哪些方式：智能功能看地区开不开放，Google Cloud 只在国际区。
    static func offeredMethods(
        region: AICommercialRegion,
        exposesIntelligentServices: Bool
    ) -> [LyricRomanizationMethod] {
        allCases.filter { method in
            LyricRomanizationMethodPolicy.effectiveMethod(
                method,
                region: region,
                exposesIntelligentServices: exposesIntelligentServices
            ) == method
        }
    }
}

extension LyricsAITranslationReadiness {
    /// 罗马音选了智能功能生成、却发不出去时，设置页说明差哪一步（三端同一套；前提与歌词翻译相同）。
    var romanizationExplanation: String {
        switch self {
        case .needsBuiltInConsent:
            String(localized: "lyrics_translation_ai_needs_builtin_consent")
        case .needsRemoteConsent:
            String(localized: "lyrics_translation_ai_needs_remote_consent")
        case .noService:
            String(localized: "lyrics_translation_ai_no_service")
        case .ready, .regionUnavailable:
            ""
        }
    }
}

/// Per-song track selection for multi-track TTML / OpenSubsonic lyrics
/// (primary replacement language, subtitle translation language, and
/// transliteration track). Kept bounded in memory and shared across iOS,
/// macOS, and tvOS player screens.
@MainActor
@Observable
final class LyricsTrackSelectionStore {
    private(set) var selectionRevision: UInt = 0
    @ObservationIgnored private var recentEntries: [Entry] = [] // bounded: 64 recent songs
    @ObservationIgnored private var defaultSelection = LyricTrackSelection.automatic

    init() {}
}

extension LyricsTrackSelectionStore {
    static let shared = LyricsTrackSelectionStore()
    static let maximumEntryCount = 64

    struct Entry: Equatable, Sendable {
        var songID: String
        var selection: LyricTrackSelection
    }

    func selection(forSongID songID: String?) -> LyricTrackSelection {
        _ = selectionRevision
        guard let songID, !songID.isEmpty else { return defaultSelection }
        return recentEntries.first(where: { $0.songID == songID })?.selection ?? .automatic
    }

    func selectReplacement(_ trackID: String?, forSongID songID: String?) {
        mutateSelection(forSongID: songID) { $0.replacementTrackID = trackID }
        // Primary language selection and romanization-only primary mode are mutually exclusive.
        let romanization = LyricsRomanizationSettingsStore.shared
        if romanization.displayMode == .romanizationOnly {
            romanization.displayMode = .hidden
        }
    }

    func selectRomanizationAsPrimary(forSongID songID: String?) {
        LyricsRomanizationSettingsStore.shared.displayMode = .romanizationOnly
        bumpAndNotify(songID: songID)
    }

    func selectSubtitle(_ trackID: String?, forSongID songID: String?) {
        let translation = LyricsTranslationSettingsStore.shared
        guard let trackID else {
            translation.showsBundledTranslations = false
            bumpAndNotify(songID: songID)
            return
        }
        mutateSelection(forSongID: songID) { $0.subtitleTrackID = trackID }
        if !translation.showsBundledTranslations {
            translation.showsBundledTranslations = true
        }
    }

    func selectTransliteration(_ trackID: String?, forSongID songID: String?) {
        mutateSelection(forSongID: songID) { $0.transliterationTrackID = trackID }
        let romanization = LyricsRomanizationSettingsStore.shared
        if romanization.displayMode == .hidden {
            romanization.displayMode = .belowOriginal
        }
    }

    func selectTransliterationMode(_ mode: LyricRomanizationDisplayMode, forSongID songID: String?) {
        LyricsRomanizationSettingsStore.shared.displayMode = mode
        bumpAndNotify(songID: songID)
    }

    func reset(forSongID songID: String? = nil) {
        if let songID, !songID.isEmpty {
            recentEntries.removeAll { $0.songID == songID }
        } else {
            recentEntries.removeAll()
            defaultSelection = .automatic
        }
        bumpAndNotify(songID: songID)
    }

    private func mutateSelection(
        forSongID songID: String?,
        _ update: (inout LyricTrackSelection) -> Void
    ) {
        if let songID, !songID.isEmpty {
            var current: LyricTrackSelection
            if let index = recentEntries.firstIndex(where: { $0.songID == songID }) {
                current = recentEntries.remove(at: index).selection
            } else {
                current = .automatic
            }
            update(&current)
            if !current.isAutomatic {
                recentEntries.append(Entry(songID: songID, selection: current))
                if recentEntries.count > Self.maximumEntryCount {
                    recentEntries.removeFirst(recentEntries.count - Self.maximumEntryCount)
                }
            }
        } else {
            update(&defaultSelection)
        }
        bumpAndNotify(songID: songID)
    }

    private func bumpAndNotify(songID: String?) {
        selectionRevision &+= 1
        NotificationCenter.default.post(name: .lyricsTrackSelectionChanged, object: songID)
    }
}

extension Notification.Name {
    static let lyricsTrackSelectionChanged = Notification.Name("primuse.lyrics.trackSelection.changed")
}
