import Foundation
import Observation
import PrimuseKit

/// Machine translation of lyrics on Apple TV. tvOS has no Apple Translation:
/// lyrics go to the smart translation service when the person chose it in
/// settings (the built-in AI or their own service), and whatever it does not
/// translate falls to the downloadable offline packs (English ↔ Persian,
/// English ↔ Chinese / Japanese / Korean, other pairs through English).
/// Translations written in the lyrics file keep precedence.
@MainActor
@Observable
final class TVLyricsTranslationController {
    static let shared = TVLyricsTranslationController()

    enum Engine: Equatable {
        /// `provider` is nil when every line came from the cache.
        case intelligent(provider: String?)
        case offline
        /// 百度翻译(#320)。
        case baidu
    }

    /// What the translation of the lyrics on screen is doing; the player shows it.
    enum Activity: Equatable {
        case idle
        /// Already in the target language or one left untranslated, or the file carries translations.
        case notNeeded
        case translating(Engine)
        case done(Engine)
        /// The lines need an offline pack that is not on this Apple TV.
        case needsModel(LocalLyricsTranslationModel.Pack)
        /// No offline pack covers this language, and smart translation is off.
        case unsupported
        case failed
    }

    /// Why smart translation did not run for these lyrics; the offline packs
    /// took over what they could.
    enum IntelligentIssue: Equatable {
        case notReady(LyricsAITranslationReadiness)
        case requestFailed
        /// 选了百度翻译却没用上:没有 APP ID 与密钥、译不成这种语言或请求出错。
        case baidu(BaiduTranslateIssue)
    }

    private(set) var activity: Activity = .idle
    private(set) var intelligentIssue: IntelligentIssue?
    /// The song the activity belongs to.
    private(set) var activitySongID: String?

    /// Set by the app at launch; smart translation needs it.
    @ObservationIgnored weak var intelligence: MusicIntelligenceService?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt = 0
    @ObservationIgnored private var lastLoaded: (songID: String, lines: [LyricLine])?
    @ObservationIgnored private weak var store: TVStore?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// One provider request takes up to 80 lines; ten rounds cover any lyrics
    /// without retrying forever when the service keeps failing.
    private static let maximumIntelligentRounds = 10

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .lyricsTranslationSettingsChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { TVLyricsTranslationController.shared.retranslateCurrentLyrics() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .localLyricsTranslationModelChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { TVLyricsTranslationController.shared.retranslateCurrentLyrics() }
        })
    }

    /// The lyrics as the screen shows them: with "show built-in translations"
    /// off, the translations written in the file are left out (readings stay)
    /// and machine translation then covers every line. `lyricsDidLoad` keeps the
    /// file's own document so the switch can bring them back.
    static func presentedLines(_ lines: [LyricLine]) -> [LyricLine] {
        LyricBundledTranslationPolicy.presentation(
            of: lines,
            showsBundledTranslations: LyricsTranslationSettingsStore.shared.showsBundledTranslations
        ).lines
    }

    /// Called whenever lyrics were put on screen for `songID`.
    func lyricsDidLoad(_ lines: [LyricLine], forSongID songID: String, store: TVStore) {
        self.store = store
        lastLoaded = (songID, lines)
        start()
    }

    /// Re-runs for the lyrics on screen, after a setting changed, the model
    /// was downloaded or removed, or smart translation became usable.
    func retranslateCurrentLyrics() {
        guard let store, let lastLoaded, store.currentSongID == lastLoaded.songID else { return }
        store.applyLyrics(
            TVPlaybackCoordinator.toTVLyrics(Self.presentedLines(lastLoaded.lines), duration: 0),
            forSongID: lastLoaded.songID
        )
        start()
    }

    /// 这首歌的翻译要人动手:缺离线翻译包,或者选了智能翻译却没用上。播放控制里的
    /// 歌词翻译键据此加一个小圆点。
    func needsAttention(forSongID songID: String?) -> Bool {
        guard let songID, activitySongID == songID,
              LyricsTranslationSettingsStore.shared.isEnabled else { return false }
        if case .needsModel = activity { return true }
        return intelligentIssue != nil
    }

    /// Whether the lyrics on screen belong to `songID` and have lines at all.
    func hasLyrics(forSongID songID: String?) -> Bool {
        guard let songID, let lastLoaded else { return false }
        return lastLoaded.songID == songID && !lastLoaded.lines.isEmpty
    }

    private func start() {
        task?.cancel()
        generation &+= 1
        let generation = generation
        activity = .idle
        intelligentIssue = nil
        activitySongID = lastLoaded?.songID
        let settings = LyricsTranslationSettingsStore.shared
        guard settings.isEnabled, let store, let loaded = lastLoaded, !loaded.lines.isEmpty else { return }
        let songID = loaded.songID
        let lines = Self.presentedLines(loaded.lines)
        let song = store.song(songID)
        let songContext = LyricTranslationSongContext(title: song?.title, artist: song?.artist)
        let target = LyricsTranslationSettingsStore.normalizedLanguageCode(settings.targetLanguageCode)
        let skippedSourceLanguageCodes = settings.skippedSourceLanguageCodes
        let intelligence = settings.mode == .intelligentWithSystemFallback ? self.intelligence : nil
        let usesBaidu = settings.mode == .baidu
        task = Task { @MainActor [weak self] in
            let prepared: LyricsTranslationPreparer.Prepared
            do {
                prepared = try await LyricsTranslationPreparer.shared.prepare(
                    lyrics: lines,
                    targetLanguageCode: target,
                    skippedSourceLanguageCodes: skippedSourceLanguageCodes,
                    enabled: true,
                    songContext: songContext
                )
            } catch {
                return
            }
            guard let self, self.isCurrent(generation, songID: songID, store: store) else { return }
            // 每组认出的源语言和行数,诊断报告里看得出整首被认成了什么语言。
            plog("TV lyrics translation groups -> \(target): "
                + LyricTranslationGroupingPolicy.diagnosticSummary(of: prepared.groups)
                + "; script conversions \(prepared.scriptConversions.count)")
            // Lines that already show a translation from the file keep it.
            let shown = Set(store.lyrics.filter { !$0.translation.isEmpty }.map(\.id))
            for (id, text) in prepared.scriptConversions where !shown.contains(id) {
                store.applyLyricTranslation(text, lineID: id, forSongID: songID)
            }
            let groups = prepared.groups.compactMap { group -> LyricTranslationGroup? in
                let pending = group.candidates.filter { !shown.contains($0.id) }
                guard !pending.isEmpty else { return nil }
                return LyricTranslationGroup(id: group.id, sourceLanguageCode: group.sourceLanguageCode, candidates: pending)
            }
            guard !groups.isEmpty else {
                self.activity = .notNeeded
                return
            }
            // Ordered before deduplicating, so a repeated chorus goes out as
            // the copy being sung and the line on screen is translated first.
            let deduplication = LyricTranslationDeduplication(
                groups: LyricTranslationPlaybackOrderPolicy.ordered(
                    groups,
                    lyrics: lines,
                    playbackTime: store.currentSongID == songID ? store.currentTime : 0
                )
            )
            var remaining = deduplication.groups
            var intelligentResult: Engine?

            if let intelligence {
                let readiness = intelligence.lyricsAITranslationReadiness
                if readiness == .ready {
                    let result = await self.translateIntelligently(
                        remaining,
                        target: target,
                        intelligence: intelligence,
                        deduplication: deduplication,
                        songID: songID,
                        store: store,
                        generation: generation
                    )
                    guard self.isCurrent(generation, songID: songID, store: store) else { return }
                    remaining = result.remaining
                    intelligentResult = result.engine
                    if result.engine == nil { self.intelligentIssue = .requestFailed }
                } else if readiness != .regionUnavailable {
                    // 这个地区没有智能服务时设置里也不给选,照离线翻译包算,不当作出了问题。
                    self.intelligentIssue = .notReady(readiness)
                }
            }
            if usesBaidu {
                if let issue = BaiduTranslateIssue.current(targetLanguageCode: target) {
                    self.intelligentIssue = .baidu(issue)
                } else {
                    let result = await self.translateWithBaidu(
                        remaining,
                        target: target,
                        deduplication: deduplication,
                        songID: songID,
                        store: store,
                        generation: generation
                    )
                    guard self.isCurrent(generation, songID: songID, store: store) else { return }
                    remaining = result.remaining
                    if result.translated { intelligentResult = .baidu }
                    if let issue = result.issue { self.intelligentIssue = .baidu(issue) }
                }
            }
            guard !remaining.isEmpty else {
                self.activity = intelligentResult.map(Activity.done) ?? .notNeeded
                return
            }

            let local = LocalLyricsTranslationService.shared
            if Self.anyPackReady(local) { self.activity = .translating(.offline) }
            let outcome = await local.translate(
                groups: remaining,
                targetLanguageCode: target,
                systemTranslator: nil,
                isCurrent: { [weak self] in
                    self?.isCurrent(generation, songID: songID, store: store) ?? false
                },
                onTranslation: { id, text in
                    for lineID in deduplication.lineIDs(for: id) {
                        store.applyLyricTranslation(text, lineID: lineID, forSongID: songID)
                    }
                }
            )
            guard self.isCurrent(generation, songID: songID, store: store) else { return }
            if outcome.translatedCount > 0 {
                plog("🌐 TV lyrics translated \(outcome.translatedCount) lines offline -> \(target)")
            }
            // 和「翻译不可用」同一个门槛:一两行缺翻译包时不让整首都提示下载翻译模型。
            if LyricTranslationNoticePolicy.shouldRequestModel(
                lyrics: lines,
                groupsNeedingModel: deduplication.restoringDuplicates(in: outcome.groupsNeedingModel),
                song: songContext
            ) {
                self.activity = .needsModel(local.requestedPack)
            } else if let intelligentResult {
                self.activity = .done(intelligentResult)
            } else if outcome.translatedCount > 0 {
                self.activity = .done(.offline)
            } else if !outcome.unsupportedGroups.isEmpty,
                      LyricTranslationNoticePolicy.shouldShowUnavailable(
                          lyrics: lines,
                          unsupportedGroups: deduplication.restoringDuplicates(in: outcome.unsupportedGroups),
                          targetLanguageCode: target,
                          song: songContext
                      ) {
                self.activity = .unsupported
            } else if outcome.failed {
                self.activity = .failed
            } else {
                self.activity = .notNeeded
            }
        }
    }

    /// Cached smart translations first, then the service, streaming each line
    /// onto the screen and into the cache as it arrives. Returns the groups it
    /// did not translate, and the engine when it translated anything.
    private func translateIntelligently(
        _ groups: [LyricTranslationGroup],
        target: String,
        intelligence: MusicIntelligenceService,
        deduplication: LyricTranslationDeduplication,
        songID: String,
        store: TVStore,
        generation: UInt
    ) async -> (remaining: [LyricTranslationGroup], engine: Engine?) {
        let cache = LyricsTranslationCache.shared
        func apply(_ id: String, _ text: String) {
            for lineID in deduplication.lineIDs(for: id) {
                store.applyLyricTranslation(text, lineID: lineID, forSongID: songID)
            }
        }
        var sources: [String: (text: String, language: String?)] = [:]
        var pending: [LyricTranslationGroup] = []
        var cachedCount = 0
        for group in groups {
            let rest = group.candidates.filter { candidate in
                if let cached = cache.translation(
                    for: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: target,
                    provider: .intelligent
                ) {
                    apply(candidate.id, cached)
                    cachedCount += 1
                    return false
                }
                sources[candidate.id] = (candidate.text, group.sourceLanguageCode)
                return true
            }
            if !rest.isEmpty {
                pending.append(LyricTranslationGroup(id: group.id, sourceLanguageCode: group.sourceLanguageCode, candidates: rest))
            }
        }
        guard !pending.isEmpty else { return ([], .intelligent(provider: nil)) }

        activity = .translating(.intelligent(provider: nil))
        let startedAt = ContinuousClock.now
        var provider: String?
        // Every line that reached the screen, across rounds; a failed round
        // keeps them (they are cached) and only the rest go offline.
        var landed = Set<String>()
        for _ in 0..<Self.maximumIntelligentRounds {
            let candidates = pending.flatMap(\.candidates)
            var roundLanded = Set<String>()
            let execution = await intelligence.translateLyrics(
                candidates,
                targetLanguageCode: target,
                onStreamEvent: { [weak self] event in
                    guard let self, self.isCurrent(generation, songID: songID, store: store) else { return }
                    switch event {
                    case .reset:
                        for id in roundLanded {
                            for lineID in deduplication.lineIDs(for: id) {
                                store.removeLyricTranslation(lineID: lineID, forSongID: songID)
                            }
                        }
                        landed.subtract(roundLanded)
                        roundLanded = []
                    case .translation(let id, let text):
                        if let source = sources[id] {
                            cache.setTranslation(
                                text,
                                for: source.text,
                                sourceLang: source.language,
                                targetLang: target,
                                provider: .intelligent
                            )
                        }
                        roundLanded.insert(id)
                        landed.insert(id)
                        apply(id, text)
                    case .completed:
                        break
                    }
                }
            )
            guard isCurrent(generation, songID: songID, store: store) else { return (pending, nil) }
            guard let execution else { break }
            var pairs: [(source: String, sourceLang: String?, translated: String)] = []
            for (id, text) in execution.translations {
                apply(id, text)
                landed.insert(id)
                if let source = sources[id] { pairs.append((source.text, source.language, text)) }
            }
            cache.bulkSet(pairs, targetLang: target, provider: .intelligent)
            provider = execution.providerName
            pending = Self.removing(landed, from: pending)
            plog("🌐 TV lyrics AI translation \(execution.translations.count)/\(candidates.count) lines "
                + "after \(Self.secondsText(since: startedAt)) via \(execution.providerName)")
            if pending.isEmpty || execution.translations.isEmpty { break }
        }
        pending = Self.removing(landed, from: pending)
        if provider == nil, !landed.isEmpty {
            provider = String(localized: "ai_provider_default_name")
        }
        let engine = provider != nil || cachedCount > 0 ? Engine.intelligent(provider: provider) : nil
        return (pending, engine)
    }

    /// 百度翻译(#320):先用缓存,再按字节上限分批请求,一批一批写上屏、进缓存。出错时停下,
    /// 已经翻好的留着,剩下的交给离线翻译包。
    private func translateWithBaidu(
        _ groups: [LyricTranslationGroup],
        target: String,
        deduplication: LyricTranslationDeduplication,
        songID: String,
        store: TVStore,
        generation: UInt
    ) async -> (remaining: [LyricTranslationGroup], translated: Bool, issue: BaiduTranslateIssue?) {
        let cache = LyricsTranslationCache.shared
        func apply(_ id: String, _ text: String) {
            for lineID in deduplication.lineIDs(for: id) {
                store.applyLyricTranslation(text, lineID: lineID, forSongID: songID)
            }
        }
        var landed = Set<String>()
        var pending: [LyricTranslationGroup] = []
        for group in groups {
            let rest = group.candidates.filter { candidate in
                guard let cached = cache.translation(
                    for: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: target,
                    provider: .baidu
                ) else { return true }
                apply(candidate.id, cached)
                landed.insert(candidate.id)
                return false
            }
            if !rest.isEmpty {
                pending.append(LyricTranslationGroup(id: group.id, sourceLanguageCode: group.sourceLanguageCode, candidates: rest))
            }
        }
        guard !pending.isEmpty else { return ([], !landed.isEmpty, nil) }

        activity = .translating(.baidu)
        let startedAt = ContinuousClock.now
        var failure: BaiduTranslateError?
        for group in pending where failure == nil {
            let texts = group.candidates.map(\.text)
            for batch in BaiduTranslateAPI.batches(texts) where failure == nil {
                let results: [String?]
                do {
                    results = try await BaiduTranslateClient.shared.translate(
                        batch.map { texts[$0] },
                        sourceLanguageCode: group.sourceLanguageCode,
                        targetLanguageCode: target
                    )
                } catch let error as BaiduTranslateError {
                    failure = error
                    break
                } catch {
                    return (groups, false, nil)
                }
                guard isCurrent(generation, songID: songID, store: store) else { return (groups, false, nil) }
                var pairs: [(source: String, sourceLang: String?, translated: String)] = []
                for (offset, translated) in results.enumerated() {
                    guard let translated else { continue }
                    let candidate = group.candidates[batch[offset]]
                    apply(candidate.id, translated)
                    landed.insert(candidate.id)
                    pairs.append((candidate.text, group.sourceLanguageCode, translated))
                }
                cache.bulkSet(pairs, targetLang: target, provider: .baidu)
            }
        }
        plog("🌐 TV lyrics Baidu translation \(landed.count) lines after \(Self.secondsText(since: startedAt)), "
            + "failure=\(failure.map { "\($0)" } ?? "none")")
        let account = BaiduTranslateAccount.shared
        var issue: BaiduTranslateIssue?
        if let failure {
            account.recordFailure(failure)
            issue = failure == .notConfigured ? .notConfigured : .failed(BaiduTranslateAccount.message(for: failure))
        } else {
            account.recordSuccess()
        }
        return (Self.removing(landed, from: groups), !landed.isEmpty, issue)
    }

    private static func removing(_ ids: Set<String>, from groups: [LyricTranslationGroup]) -> [LyricTranslationGroup] {
        groups.compactMap { group in
            let rest = group.candidates.filter { !ids.contains($0.id) }
            guard !rest.isEmpty else { return nil }
            return LyricTranslationGroup(id: group.id, sourceLanguageCode: group.sourceLanguageCode, candidates: rest)
        }
    }

    private static func anyPackReady(_ service: LocalLyricsTranslationService) -> Bool {
        LocalLyricsTranslationModel.Pack.allCases.contains { service.modelState(for: $0) == .ready }
    }

    private static func secondsText(since start: ContinuousClock.Instant) -> String {
        let elapsed = (ContinuousClock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return String(format: "%.1fs", seconds)
    }

    private func isCurrent(_ generation: UInt, songID: String, store: TVStore) -> Bool {
        !Task.isCancelled && generation == self.generation && store.currentSongID == songID
    }
}
