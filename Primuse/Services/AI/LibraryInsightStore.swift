import Foundation
import Observation
import PrimuseKit

/// 专辑与艺人的 AI 简介:本机缓存、生成中的状态和最近一次失败。
/// 简介随时能重新生成,所以存在 Caches 里,不跨设备同步;
/// 用户自己的看法写在专辑「点评」里,那份会同步。
@MainActor
@Observable
final class LibraryInsightStore {
    static let shared = LibraryInsightStore()

    private(set) var cache = LibraryInsightCache()
    private(set) var generatingKeys: Set<String> = []
    private(set) var failures: [String: AILibraryContentFailure] = [:]
    private(set) var retryDates: [String: Date] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("library-insights.json")
        loadIfNeeded()
    }

    /// 简介用界面语言写。
    static var languageCode: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    func key(for subject: LibraryInsightSubject) -> String {
        subject.cacheKey(
            languageCode: Self.languageCode,
            unknownArtistName: String(localized: "unknown_artist")
        )
    }

    func insight(for subject: LibraryInsightSubject) -> LibraryInsight? {
        cache.entries[key(for: subject)]
    }

    func isGenerating(_ subject: LibraryInsightSubject) -> Bool {
        generatingKeys.contains(key(for: subject))
    }

    func failure(for subject: LibraryInsightSubject) -> AILibraryContentFailure? {
        failures[key(for: subject)]
    }

    func retryDate(for subject: LibraryInsightSubject) -> Date? {
        guard let date = retryDates[key(for: subject)], date > Date() else { return nil }
        return date
    }

    /// 问 AI 要一份简介;同一张专辑/同一位艺人已经在问就不再重复发。
    func generate(_ subject: LibraryInsightSubject, intelligence: MusicIntelligenceService) async {
        let key = key(for: subject)
        guard !generatingKeys.contains(key) else { return }
        let languageCode = Self.languageCode
        guard let request = LibraryInsightAIExchange.request(for: subject, languageCode: languageCode) else {
            failures[key] = .noTasteProfile
            return
        }
        generatingKeys.insert(key)
        failures[key] = nil
        retryDates[key] = nil
        defer { generatingKeys.remove(key) }

        switch await intelligence.libraryInsight(request) {
        case .success(let answer, let providerName):
            plog("✨ Library insight kind=\(subject.kind.rawValue) known=\(answer.known) tags=\(answer.tags.count)")
            cache.store(
                LibraryInsight(
                    kind: subject.kind,
                    known: answer.known,
                    summary: answer.summary,
                    tags: answer.tags,
                    providerName: providerName,
                    languageCode: languageCode,
                    generatedAt: Date()
                ),
                for: key
            )
            scheduleSave()
        case .failed(let failure, let retryAt):
            failures[key] = failure
            retryDates[key] = retryAt
        }
    }

    func remove(_ subject: LibraryInsightSubject) {
        let key = key(for: subject)
        guard cache.entries.removeValue(forKey: key) != nil else { return }
        failures[key] = nil
        scheduleSave()
    }

    func clearFailure(for subject: LibraryInsightSubject) {
        let key = key(for: subject)
        failures[key] = nil
        retryDates[key] = nil
    }

    /// 「未知专辑」「未知艺术家」这类占位名字没什么可介绍的。
    nonisolated static func isIntroducible(_ subject: LibraryInsightSubject) -> Bool {
        let unknownArtist = String(localized: "unknown_artist")
        func isPlaceholder(_ name: String) -> Bool {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == unknownArtist || TagCleanupPolicy.isPlaceholder(trimmed)
        }
        switch subject.kind {
        case .album: return !isPlaceholder(subject.albumTitle)
        case .artist: return !isPlaceholder(subject.artistName)
        }
    }

    nonisolated static func message(for failure: AILibraryContentFailure) -> String {
        switch failure {
        case .notConfigured:
            return String(localized: "library_insight_not_configured")
        case .needsConsent:
            return String(localized: "library_insight_needs_consent")
        case .builtInNotOffered:
            return String(localized: "library_insight_builtin_not_offered")
        case .noTasteProfile:
            return String(localized: "ai_song_discovery_failed_generic")
        case .failed(let reason):
            switch reason {
            case .busy: return String(localized: "ai_song_discovery_failed_busy")
            case .minuteLimit: return String(localized: "ai_song_discovery_failed_minute_limit")
            case .dailyLimit: return String(localized: "library_insight_failed_daily_limit")
            case .regionRestricted: return String(localized: "ai_song_discovery_failed_region")
            case .network: return String(localized: "ai_song_discovery_failed_network")
            case .empty, .unavailable, .deviceRegistration, .authentication, .upstream:
                return String(localized: "ai_song_discovery_failed_generic")
            }
        }
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        let url = fileURL
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                LibraryInsightCache.decode(try? Data(contentsOf: url))
            }.value
            guard let self else { return }
            // 读盘期间已经生成了新的,以内存里的为准。
            var merged = loaded
            for (key, insight) in self.cache.entries {
                merged.store(insight, for: key)
            }
            self.cache = merged
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let url = fileURL
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = self?.cache.encoded() else { return }
            await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: url, options: .atomic)
                } catch {
                    plog("⚠️ Library insight cache write failed: \(error.localizedDescription)")
                }
            }.value
        }
    }
}
