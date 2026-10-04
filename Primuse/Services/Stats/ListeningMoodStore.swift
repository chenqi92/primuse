import Foundation
import PrimuseKit

/// 听歌统计里「最近的状态」的 AI 解读。
///
/// 状态是慢慢变的，所以按 `ListeningMoodRefreshPolicy` 很少才问一次：自动最多一周
/// 一次、且中间又听了一些歌；手动「重新解读」一天一次。平时读本机缓存（不同步）。
/// 问不了或没问到时，页面用本机按听歌习惯给出的状态（`ListeningMoodArchetype`）。
@MainActor
@Observable
final class ListeningMoodStore {
    static let shared = ListeningMoodStore()

    private static let readingKey = "primuse.listeningMood.reading.v1"
    private static let lastAttemptKey = "primuse.listeningMood.lastAttempt.v1"

    private(set) var reading: ListeningMoodReading?
    private(set) var lastAttemptAt: Date?
    private(set) var isGenerating = false
    /// 上一次没问到的原因，只留在这次运行里，给状态卡写一行说明。
    private(set) var lastFailure: AILibraryContentFailure?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var generation = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.readingKey) {
            reading = try? JSONDecoder().decode(ListeningMoodReading.self, from: data)
        }
        lastAttemptAt = defaults.object(forKey: Self.lastAttemptKey) as? Date
    }

    /// 解读用的语言，跟界面语言走。
    static var languageCode: String {
        ListeningMoodAIExchange.normalizedLanguageCode(Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// 能显示的那份解读：清空听歌记录之前生成的、换了界面语言的都不算。
    func visibleReading(clearedAt: Date?) -> ListeningMoodReading? {
        guard let reading, reading.languageCode == Self.languageCode else { return nil }
        if let clearedAt, reading.generatedAt < clearedAt { return nil }
        return reading
    }

    /// 手动重新解读最早什么时候可以；nil 表示现在就可以。
    func nextManualRefresh(now: Date = Date()) -> Date? {
        ListeningMoodRefreshPolicy.nextManualRefresh(reading: reading, lastAttemptAt: lastAttemptAt, now: now)
    }

    /// 页面出现、数据变了时调；`force` 是用户点了「重新解读」。
    func refreshIfNeeded(
        signals: ListeningMoodSignals,
        newPlaysSinceReading: Int,
        clearedAt: Date?,
        intelligence: MusicIntelligenceService,
        force: Bool = false,
        now: Date = Date()
    ) {
        guard !isGenerating, intelligence.isListeningMoodAvailable else { return }
        let language = Self.languageCode
        if force {
            guard signals.plays >= ListeningMoodRefreshPolicy.minimumPlays,
                  nextManualRefresh(now: now) == nil else { return }
        } else {
            guard ListeningMoodRefreshPolicy.shouldRefreshAutomatically(
                reading: visibleReading(clearedAt: clearedAt),
                lastAttemptAt: lastAttemptAt,
                windowPlays: signals.plays,
                newPlaysSinceReading: newPlaysSinceReading,
                languageCode: language,
                now: now
            ) else { return }
        }
        guard let request = ListeningMoodAIExchange.request(for: signals, languageCode: language) else { return }

        // 先记下这次尝试再发：失败了也要等冷却过去才再问。
        lastAttemptAt = now
        defaults.set(now, forKey: Self.lastAttemptKey)
        isGenerating = true
        lastFailure = nil
        generation &+= 1
        let token = generation
        Task { [weak self] in
            let outcome = await intelligence.listeningMood(request)
            guard let self, self.generation == token else { return }
            self.isGenerating = false
            switch outcome {
            case .success(let answer, let providerName):
                self.store(ListeningMoodReading(
                    title: answer.title,
                    summary: answer.summary,
                    keywords: answer.keywords,
                    providerName: providerName,
                    generatedAt: Date(),
                    languageCode: language
                ))
                plog("🎧 Listening mood: updated provider=\(providerName)")
            case .failed(let failure, _):
                self.lastFailure = failure
                plog("🎧 Listening mood: kept the on-device reading failure=\(failure)")
            }
        }
    }

    /// 清空听歌记录时一起清掉。
    func clear() {
        generation &+= 1
        isGenerating = false
        lastFailure = nil
        reading = nil
        lastAttemptAt = nil
        defaults.removeObject(forKey: Self.readingKey)
        defaults.removeObject(forKey: Self.lastAttemptKey)
    }

    private func store(_ reading: ListeningMoodReading) {
        self.reading = reading
        if let data = try? JSONEncoder().encode(reading) {
            defaults.set(data, forKey: Self.readingKey)
        }
    }
}
