import PrimuseKit
import SwiftUI
import Translation

extension View {
    @ViewBuilder
    func lyricsTranslationTaskIfAvailable(
        songID: String?,
        songContext: LyricTranslationSongContext,
        lyricsRevision: UInt,
        lyrics: [LyricLine],
        settings: LyricsTranslationSettingsStore,
        player: AudioPlayerService,
        translatedTextByLineID: Binding<[String: String]>,
        activity: Binding<LyricsTranslationActivity>
    ) -> some View {
        if #available(iOS 18.0, *) {
            modifier(
                LyricsTranslationTaskModifier(
                    songID: songID,
                    songContext: songContext,
                    lyricsRevision: lyricsRevision,
                    lyrics: lyrics,
                    settings: settings,
                    player: player,
                    translatedTextByLineID: translatedTextByLineID,
                    activity: activity
                )
            )
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
struct LyricsTranslationTaskModifier: ViewModifier {
    @Environment(MusicIntelligenceService.self) private var intelligence
    private var localTranslation: LocalLyricsTranslationService { .shared }
    let songID: String?
    let songContext: LyricTranslationSongContext
    let lyricsRevision: UInt
    let lyrics: [LyricLine]
    let settings: LyricsTranslationSettingsStore
    let player: AudioPlayerService
    @Binding var translatedTextByLineID: [String: String]
    @Binding var activity: LyricsTranslationActivity

    @State private var translationConfig: TranslationSession.Configuration?
    @State private var preparedGroups: [LyricTranslationGroup] = []
    @State private var activeGroupIndex = 0
    @State private var preparedIdentity: TranslationTaskIdentity?
    @State private var completionActivity: LyricsTranslationActivity?
    @State private var deduplication = LyricTranslationDeduplication(groups: [])

    private struct TranslationTaskIdentity: Hashable {
        let songID: String?
        let songContext: LyricTranslationSongContext
        let lyricsRevision: UInt
        let isEnabled: Bool
        let targetLanguageCode: String
        let skippedSourceLanguageCodes: [String]
        let mode: LyricsTranslationMode
        let systemPreparationRequestRevision: UInt
        /// 只认真正影响翻译决策的那个结论，而不是地区服务的原始修订号。
        ///
        /// 地区服务每刷新一次会把修订号加两次（先置未知、再发布结果），而翻译
        /// 准备唯一用到它的地方是这个布尔值 —— 拿原始修订号当重启键，等于每次
        /// 商店信息抖动都白白重启两轮翻译准备，每轮都要再问一遍系统语言可用性。
        let exposesRemoteConfiguration: Bool
        /// The offline model was downloaded or removed.
        let localModelRevision: UInt
        /// 选了智能翻译时它此刻发不发得出去;同意了内置 AI、允许了发送或配好了服务就重来。
        let intelligentReadiness: LyricsAITranslationReadiness?
        /// 选了百度翻译时 APP ID 与密钥的版本:填好、换掉或移除后重来。
        let baiduRevision: UInt?
    }

    private var translationTaskIdentity: TranslationTaskIdentity {
        TranslationTaskIdentity(
            songID: songID,
            songContext: songContext,
            lyricsRevision: lyricsRevision,
            isEnabled: settings.isEnabled,
            targetLanguageCode: LyricsTranslationSettingsStore.normalizedLanguageCode(
                settings.targetLanguageCode
            ),
            skippedSourceLanguageCodes: settings.skippedSourceLanguageCodes,
            mode: settings.mode,
            systemPreparationRequestRevision: settings.systemPreparationRequestRevision,
            exposesRemoteConfiguration: intelligence.shouldExposeRemoteConfiguration,
            localModelRevision: localTranslation.modelRevision,
            intelligentReadiness: settings.mode == .intelligentWithSystemFallback
                ? intelligence.lyricsAITranslationReadiness : nil,
            baiduRevision: settings.mode == .baidu ? BaiduTranslateAccount.shared.revision : nil
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: translationTaskIdentity) {
                let identity = translationTaskIdentity
                await prepareTranslation(for: identity)
            }
            .translationTask(translationConfig) { session in
                await runTranslation(session: session)
            }
    }

    /// 按检测到的源语言拆分歌词。Translation 的一个 batch 只能对应一个
    /// source/target 语言对，混合语言放进同一自动检测 batch 会导致整批失败。
    private func prepareTranslation(for identity: TranslationTaskIdentity) async {
        guard !Task.isCancelled, translationTaskIdentity == identity else { return }

        translationConfig = nil
        preparedGroups = []
        activeGroupIndex = 0
        preparedIdentity = nil
        completionActivity = nil
        deduplication = LyricTranslationDeduplication(groups: [])
        translatedTextByLineID = [:]
        activity = .idle

        let prepared: LyricsTranslationPreparer.Prepared
        do {
            prepared = try await LyricsTranslationPreparer.shared.prepare(
                lyrics: lyrics,
                targetLanguageCode: identity.targetLanguageCode,
                skippedSourceLanguageCodes: identity.skippedSourceLanguageCodes,
                enabled: identity.isEnabled,
                songContext: identity.songContext
            )
        } catch {
            return
        }
        guard !Task.isCancelled, translationTaskIdentity == identity else { return }
        if identity.isEnabled {
            // 每组认出的源语言和行数,诊断报告里看得出整首被认成了什么语言。
            plog("Lyrics translation groups -> \(identity.targetLanguageCode): "
                + LyricTranslationGroupingPolicy.diagnosticSummary(of: prepared.groups)
                + "; script conversions \(prepared.scriptConversions.count)")
        }
        let manualTranslations = prepared.manualTranslations
            .merging(prepared.scriptConversions) { manual, _ in manual }
        // Order before deduplicating, so a repeated chorus is sent as the
        // copy being sung rather than its first appearance.
        let deduplication = LyricTranslationDeduplication(
            groups: LyricTranslationPlaybackOrderPolicy.ordered(
                prepared.groups,
                lyrics: lyrics,
                playbackTime: player.currentSong?.id == identity.songID ? player.currentTime : 0
            )
        )
        self.deduplication = deduplication
        let groups = deduplication.groups
        translatedTextByLineID = manualTranslations
        let explicitlyRequested = prepared.requiresPreparation
            && settings.consumeSystemTranslationPreparationRequest(
                revision: identity.systemPreparationRequestRevision
            )
        guard !groups.isEmpty else {
            activity = .notNeeded
            return
        }

        let cache = LyricsTranslationCache.shared
        let wantsIntelligentProvider = identity.mode == .intelligentWithSystemFallback
            && identity.exposesRemoteConfiguration
        let usesIntelligentProvider = wantsIntelligentProvider && identity.intelligentReadiness == .ready
        // 选了智能翻译却发不出去(没同意内置 AI、没允许发送、没有服务):照常用系统翻译,
        // 但说清楚差哪一步,别让人以为智能翻译坏了或者根本没生效。
        var intelligentNotice: LyricsTranslationActivity? = wantsIntelligentProvider && !usesIntelligentProvider
            ? identity.intelligentReadiness.map(LyricsTranslationActivity.intelligentNotReady)
            : nil
        // 选了百度翻译却没填好、或百度译不成这种语言:同样照常用系统翻译,并说明原因。
        let baiduIssue = identity.mode == .baidu
            ? BaiduTranslateIssue.current(targetLanguageCode: identity.targetLanguageCode) : nil
        let usesBaidu = identity.mode == .baidu && baiduIssue == nil
        if let baiduIssue { intelligentNotice = .baiduNotReady(baiduIssue) }
        let prefetcher = LyricsTranslationPrefetcher.shared
        if usesIntelligentProvider, let songID = identity.songID {
            // The previous song may already be translating this one; its
            // result lands in the cache below instead of a second request.
            await prefetcher.waitIfTranslating(
                songID: songID,
                targetLanguageCode: identity.targetLanguageCode
            )
            guard !Task.isCancelled, translationTaskIdentity == identity else { return }
        } else {
            prefetcher.cancel()
        }
        let preferredCacheProvider: LyricsTranslationCache.ProviderNamespace =
            usesIntelligentProvider ? .intelligent : (usesBaidu ? .baidu : .system)
        var hits = manualTranslations
        var uncachedGroups: [LyricTranslationGroup] = []

        for group in groups {
            let pending = group.candidates.filter { candidate in
                if let translated = cache.translation(
                    for: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode,
                    provider: preferredCacheProvider
                ) {
                    hits[candidate.id] = translated
                    return false
                }
                return true
            }
            if !pending.isEmpty {
                uncachedGroups.append(
                    LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: pending
                    )
                )
            }
        }

        translatedTextByLineID = deduplication.expanding(hits)
        if let intelligentNotice { activity = intelligentNotice }
        guard !uncachedGroups.isEmpty else {
            if preferredCacheProvider == .intelligent, !hits.isEmpty {
                activity = .intelligentCached
            } else if preferredCacheProvider == .baidu, !hits.isEmpty {
                activity = .baiduSuccess
            }
            if usesIntelligentProvider { prefetchUpcomingSong(identity: identity) }
            return
        }

        if usesBaidu {
            guard let outcome = await translateWithBaidu(
                uncachedGroups,
                identity: identity,
                deduplication: deduplication,
                hits: &hits
            ) else { return }
            uncachedGroups = outcome.remaining
            if let issue = outcome.issue { intelligentNotice = .baiduNotReady(issue) }
            guard !uncachedGroups.isEmpty else { return }
        }

        if usesIntelligentProvider {
            activity = .intelligentLoading
            var pendingSources: [String: (text: String, sourceLang: String?)] = [:]
            for group in uncachedGroups {
                for candidate in group.candidates {
                    pendingSources[candidate.id] = (candidate.text, group.sourceLanguageCode)
                }
            }
            let startedAt = ContinuousClock.now
            var loggedFirstLine = false
            var streamedTranslations: [String: String] = [:]
            // 和系统翻译一样整批写回、整批进缓存(见 `runTranslation`)。
            var stream = LyricTranslationStreamBatch(lineCount: lyrics.count)
            var pendingCachePairs: [(source: String, sourceLang: String?, translated: String)] = []
            defer {
                Self.storeTranslations(
                    &pendingCachePairs,
                    targetLanguageCode: identity.targetLanguageCode,
                    provider: .intelligent
                )
            }
            // 服务商一次只收前 80 行。长歌词一轮翻完前 80 行后接着发剩下的,
            // 不再把后半首交给系统翻译(前后两种译文的质量会突然变)。
            var round = 0
            translationRounds: while round < Self.maximumIntelligentTranslationRounds {
                round += 1
                let pendingCandidates = uncachedGroups.flatMap(\.candidates)
                // 「重来」事件只撤销这一轮流式出来的行,前几轮已经落定的不动。
                streamedTranslations = [:]
                let execution = await intelligence.translateLyrics(
                    pendingCandidates,
                    targetLanguageCode: identity.targetLanguageCode,
                    onStreamEvent: { event in
                        guard !Task.isCancelled,
                              translationTaskIdentity == identity else { return }
                        switch event {
                        case .reset:
                            // 还没写上去的直接丢掉;已经写上去的一次换回原样。
                            _ = stream.takeAll()
                            var restored = translatedTextByLineID
                            for id in streamedTranslations.keys {
                                for lineID in deduplication.lineIDs(for: id) {
                                    restored[lineID] = hits[id]
                                }
                            }
                            translatedTextByLineID = restored
                            streamedTranslations = [:]
                        case .translation(let id, let text):
                            if !loggedFirstLine {
                                loggedFirstLine = true
                                plog("🌐 Lyrics AI translation first line after "
                                    + "\(Self.secondsText(since: startedAt)), "
                                    + "\(pendingCandidates.count) unique lines")
                            }
                            // Keep every finished row, so leaving the song midway
                            // does not throw away what was already translated.
                            if let source = pendingSources[id] {
                                pendingCachePairs.append((source.text, source.sourceLang, text))
                            }
                            streamedTranslations[id] = text
                            stream.add(text, forLines: deduplication.lineIDs(for: id))
                            if let due = stream.takeIfDue(now: ProcessInfo.processInfo.systemUptime) {
                                translatedTextByLineID.merge(due) { _, new in new }
                                Self.storeTranslations(
                                    &pendingCachePairs,
                                    targetLanguageCode: identity.targetLanguageCode,
                                    provider: .intelligent
                                )
                            }
                        case .completed:
                            break
                        }
                    }
                )
                Self.storeTranslations(
                    &pendingCachePairs,
                    targetLanguageCode: identity.targetLanguageCode,
                    provider: .intelligent
                )
                guard !Task.isCancelled, translationTaskIdentity == identity else { break translationRounds }
                // 服务商中途失败时,已经流回来的行留在屏幕上(下面退回系统翻译只翻剩下的)。
                let streamedRemainder = stream.takeAll()
                if !streamedRemainder.isEmpty {
                    translatedTextByLineID.merge(streamedRemainder) { _, new in new }
                }
                guard let execution else { break translationRounds }
                var cachePairs: [(source: String, sourceLang: String?, translated: String)] = []
                for group in uncachedGroups {
                    for candidate in group.candidates {
                        guard let translated = execution.translations[candidate.id] else { continue }
                        cachePairs.append((candidate.text, group.sourceLanguageCode, translated))
                    }
                }
                LyricsTranslationCache.shared.bulkSet(
                    cachePairs,
                    targetLang: identity.targetLanguageCode,
                    provider: .intelligent
                )
                translatedTextByLineID.merge(
                    deduplication.expanding(execution.translations)
                ) { _, new in new }
                let translatedIDs = Set(execution.translations.keys)
                uncachedGroups = uncachedGroups.compactMap { group in
                    let remaining = group.candidates.filter {
                        !translatedIDs.contains($0.id)
                    }
                    guard !remaining.isEmpty else { return nil }
                    return LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: remaining
                    )
                }
                plog("🌐 Lyrics AI translation finished after "
                    + "\(Self.secondsText(since: startedAt)), "
                    + "\(execution.translations.count)/\(pendingCandidates.count) lines")
                if uncachedGroups.isEmpty {
                    activity = .intelligentSuccess(
                        provider: execution.providerName,
                        fallbackDepth: execution.fallbackDepth
                    )
                    prefetchUpcomingSong(identity: identity)
                    return
                }
                // 这一轮一行都没翻出来:交给下面的系统翻译,别空转。
                guard !execution.translations.isEmpty else { break translationRounds }
            }
            guard !Task.isCancelled, translationTaskIdentity == identity else { return }
            // Rows the provider streamed before it failed stay on screen (they
            // are cached already); only the rest fall back to the system.
            if !streamedTranslations.isEmpty {
                uncachedGroups = uncachedGroups.compactMap { group in
                    let remaining = group.candidates.filter { streamedTranslations[$0.id] == nil }
                    guard !remaining.isEmpty else { return nil }
                    return LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: remaining
                    )
                }
                guard !uncachedGroups.isEmpty else {
                    activity = .intelligentCached
                    return
                }
            }
            activity = .systemFallback

            var systemPendingGroups: [LyricTranslationGroup] = []
            for group in uncachedGroups {
                let pending = group.candidates.filter { candidate in
                    if let translated = cache.translation(
                        for: candidate.text,
                        sourceLang: group.sourceLanguageCode,
                        targetLang: identity.targetLanguageCode,
                        provider: .system
                    ) {
                        hits[candidate.id] = translated
                        return false
                    }
                    return true
                }
                if !pending.isEmpty {
                    systemPendingGroups.append(LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: pending
                    ))
                }
            }
            translatedTextByLineID.merge(deduplication.expanding(hits)) { _, new in new }
            uncachedGroups = systemPendingGroups
            guard !uncachedGroups.isEmpty else { return }
        }

        // Pairs Apple Translation does not offer (Persian) go to the offline
        // model when it is on this device; they are never sent online from
        // here. Other languages reach it through English only with a system
        // language pack that is already installed.
        var localUnsupportedGroups: [LyricTranslationGroup] = []
        var localNeedsModel = false
        let localGroups = uncachedGroups.filter {
            !LyricTranslationGroupingPolicy.permitsAppleSystemTranslation(
                sourceLanguageCode: $0.sourceLanguageCode,
                targetLanguageCode: identity.targetLanguageCode
            )
        }
        if !localGroups.isEmpty {
            let localGroupIDs = Set(localGroups.map(\.id))
            uncachedGroups.removeAll { localGroupIDs.contains($0.id) }
            let activityBeforeLocal = activity
            if localTranslation.isModelReady { activity = .localTranslating }
            var stream = LyricTranslationStreamBatch(lineCount: lyrics.count)
            let outcome = await localTranslation.translate(
                groups: localGroups,
                targetLanguageCode: identity.targetLanguageCode,
                systemTranslator: LyricsSystemTranslationBridge.installedPacks,
                isCurrent: { translationTaskIdentity == identity },
                onTranslation: { id, text in
                    stream.add(text, forLines: deduplication.lineIDs(for: id))
                    if let due = stream.takeIfDue(now: ProcessInfo.processInfo.systemUptime) {
                        translatedTextByLineID.merge(due) { _, new in new }
                    }
                }
            )
            guard !Task.isCancelled, translationTaskIdentity == identity else { return }
            let localRemainder = stream.takeAll()
            if !localRemainder.isEmpty {
                translatedTextByLineID.merge(localRemainder) { _, new in new }
            }
            if activity == .localTranslating { activity = activityBeforeLocal }
            localUnsupportedGroups = outcome.unsupportedGroups
            // 和「翻译不可用」同一个门槛:一两行缺翻译包时不让整首都提示下载翻译模型。
            localNeedsModel = LyricTranslationNoticePolicy.shouldRequestModel(
                lyrics: lyrics,
                groupsNeedingModel: deduplication.restoringDuplicates(in: outcome.groupsNeedingModel),
                song: identity.songContext
            )
        }

        var systemGroups: [LyricTranslationGroup] = []
        var deferredSystemLineCount = 0
        for group in uncachedGroups {
            if !explicitlyRequested, cache.isPairMarkedFailed(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            ) {
                deferredSystemLineCount += group.candidates.count
                continue
            }

            let pending = explicitlyRequested ? group.candidates : group.candidates.filter { candidate in
                if cache.isMarkedFailed(
                    source: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode
                ) {
                    deferredSystemLineCount += 1
                    return false
                }
                return true
            }
            guard !pending.isEmpty else { continue }
            systemGroups.append(
                LyricTranslationGroup(
                    id: group.id,
                    sourceLanguageCode: group.sourceLanguageCode,
                    candidates: pending
                )
            )
        }
        if deferredSystemLineCount > 0 {
            plog("Lyrics translation cooldown skipped \(deferredSystemLineCount) lines")
        }
        guard !systemGroups.isEmpty else {
            if deferredSystemLineCount > 0 {
                activity = .systemPreparationRequired
            } else if localNeedsModel {
                activity = .localModelRequired
            } else if !localUnsupportedGroups.isEmpty {
                activity = LyricTranslationNoticePolicy.shouldShowUnavailable(
                    lyrics: lyrics,
                    unsupportedGroups: deduplication.restoringDuplicates(in: localUnsupportedGroups),
                    targetLanguageCode: identity.targetLanguageCode,
                    song: identity.songContext
                ) ? .systemUnavailable : .idle
            }
            return
        }

        let target = Locale.Language(identifier: identity.targetLanguageCode)
        var installedGroups: [LyricTranslationGroup] = []
        var preparationRequiredGroups: [LyricTranslationGroup] = []
        var unsupportedSystemGroups: [LyricTranslationGroup] = []
        var shouldOfferPreparation = deferredSystemLineCount > 0
        var encounteredUnknownAvailabilityStatus = false
        var encounteredAvailabilityError = false
        for group in systemGroups {
            guard !Task.isCancelled else { return }
            guard LyricTranslationGroupingPolicy.permitsAppleSystemTranslation(
                sourceLanguageCode: group.sourceLanguageCode,
                targetLanguageCode: identity.targetLanguageCode
            ) else {
                unsupportedSystemGroups.append(group)
                plog(
                    "Lyrics translation pair unsupported by system provider: "
                        + "\(group.sourceLanguageCode ?? "auto") -> "
                        + identity.targetLanguageCode
                )
                continue
            }
            if group.sourceLanguageCode == nil, !explicitlyRequested {
                preparationRequiredGroups.append(group)
                continue
            }
            do {
                guard let text = group.candidates.first?.text else { continue }
                let status = try await Self.translationAvailabilityStatus(
                    sourceLanguageCode: group.sourceLanguageCode,
                    sampleText: text,
                    targetLanguageCode: target.minimalIdentifier
                )

                switch status {
                case .installed:
                    if group.sourceLanguageCode == nil {
                        preparationRequiredGroups.append(group)
                    } else {
                        installedGroups.append(group)
                    }
                case .supported:
                    preparationRequiredGroups.append(group)
                    plog(
                        "Lyrics translation language pair requires explicit download: "
                            + "\(group.sourceLanguageCode ?? "auto") -> "
                            + identity.targetLanguageCode
                    )
                case .unsupported:
                    unsupportedSystemGroups.append(group)
                    plog(
                        "Lyrics translation pair unsupported: "
                            + "\(group.sourceLanguageCode ?? "auto") -> "
                            + identity.targetLanguageCode
                    )
                @unknown default:
                    encounteredUnknownAvailabilityStatus = true
                    shouldOfferPreparation = true
                    plog("Lyrics translation availability returned an unknown status")
                }
            } catch {
                guard !Task.isCancelled, translationTaskIdentity == identity else { return }
                encounteredAvailabilityError = true
                cache.markPairFailed(
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode
                )
                shouldOfferPreparation = true
                plog("Lyrics translation language detection failed: \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled, translationTaskIdentity == identity else { return }
        translatedTextByLineID.merge(deduplication.expanding(hits)) { _, new in new }
        var availableGroups = LyricTranslationGroupingPolicy.automaticSessionGroups(
            installed: installedGroups
        )
        if explicitlyRequested,
           let explicitGroup = LyricTranslationGroupingPolicy.explicitlyRequestedSessionGroup(
               preparationRequired: preparationRequiredGroups
           ) {
            availableGroups.append(explicitGroup)
            preparationRequiredGroups.removeAll { $0.id == explicitGroup.id }
        }
        unsupportedSystemGroups.append(contentsOf: localUnsupportedGroups)
        let unsupportedSystemLineCount = unsupportedSystemGroups.reduce(0) {
            $0 + $1.candidates.count
        }
        let unavailableActivity: LyricsTranslationActivity =
            LyricTranslationNoticePolicy.shouldShowUnavailable(
                lyrics: lyrics,
                unsupportedGroups: deduplication.restoringDuplicates(in: unsupportedSystemGroups),
                targetLanguageCode: identity.targetLanguageCode,
                song: identity.songContext
            ) ? .systemUnavailable : .idle
        let remainingState = LyricTranslationTerminalPolicy.remainingStateAfterAvailableWork(
            preparationRequiredCandidateCount: preparationRequiredGroups.reduce(0) {
                $0 + $1.candidates.count
            },
            unsupportedCandidateCount: unsupportedSystemLineCount,
            encounteredUnknownStatus: encounteredUnknownAvailabilityStatus,
            encounteredError: encounteredAvailabilityError || shouldOfferPreparation
        )
        switch remainingState {
        case .notNeeded:
            completionActivity = localNeedsModel ? .localModelRequired : (intelligentNotice ?? .notNeeded)
        case .preparationRequired:
            completionActivity = .systemPreparationRequired
        case .unavailable:
            completionActivity = unavailableActivity
        case .ready:
            completionActivity = localNeedsModel ? .localModelRequired : intelligentNotice
        }
        let terminalState = LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: systemGroups.reduce(0) { partial, group in
                partial + group.candidates.count
            },
            availableGroupCount: availableGroups.count,
            preparationRequiredGroupCount: preparationRequiredGroups.count,
            unsupportedCandidateCount: unsupportedSystemLineCount,
            encounteredUnknownStatus: encounteredUnknownAvailabilityStatus,
            encounteredError: encounteredAvailabilityError || shouldOfferPreparation
        )
        switch terminalState {
        case .notNeeded:
            activity = localNeedsModel ? .localModelRequired : .notNeeded
            return
        case .unavailable:
            activity = unavailableActivity
            return
        case .preparationRequired:
            activity = .systemPreparationRequired
            return
        case .ready:
            if !preparationRequiredGroups.isEmpty || shouldOfferPreparation {
                activity = .systemPreparationRequired
            } else if localNeedsModel {
                activity = .localModelRequired
            }
        }

        preparedGroups = availableGroups
        activeGroupIndex = 0
        preparedIdentity = identity
        activateGroup(at: 0, identity: identity)
    }

    /// 一轮最多 80 行,十轮够八百行 —— 再长的歌词也翻得完,又不会在服务端出错时无限重试。
    private static let maximumIntelligentTranslationRounds = 10

    /// 把攒下的译文一次写进缓存并清空。
    private static func storeTranslations(
        _ pairs: inout [(source: String, sourceLang: String?, translated: String)],
        targetLanguageCode: String,
        provider: LyricsTranslationCache.ProviderNamespace
    ) {
        guard !pairs.isEmpty else { return }
        LyricsTranslationCache.shared.bulkSet(pairs, targetLang: targetLanguageCode, provider: provider)
        pairs.removeAll(keepingCapacity: true)
    }

    /// 百度翻译(#320):一组(同一源语言)按字节上限分批发出去,翻完一批写回一批、进缓存。出错时停下,
    /// 已经翻好的留着,剩下的(`remaining`)交给后面的系统翻译。身份变了或被取消时返回 nil。
    private func translateWithBaidu(
        _ groups: [LyricTranslationGroup],
        identity: TranslationTaskIdentity,
        deduplication: LyricTranslationDeduplication,
        hits: inout [String: String]
    ) async -> (remaining: [LyricTranslationGroup], issue: BaiduTranslateIssue?)? {
        activity = .baiduLoading
        let startedAt = ContinuousClock.now
        var remaining: [LyricTranslationGroup] = []
        var failure: BaiduTranslateError?
        var translatedCount = 0
        for group in groups {
            let texts = group.candidates.map(\.text)
            var translatedIDs = Set<String>()
            for batch in BaiduTranslateAPI.batches(texts) where failure == nil {
                let results: [String?]
                do {
                    results = try await BaiduTranslateClient.shared.translate(
                        batch.map { texts[$0] },
                        sourceLanguageCode: group.sourceLanguageCode,
                        targetLanguageCode: identity.targetLanguageCode
                    )
                } catch let error as BaiduTranslateError {
                    failure = error
                    break
                } catch {
                    return nil
                }
                guard !Task.isCancelled, translationTaskIdentity == identity else { return nil }
                var updates: [String: String] = [:]
                var cachePairs: [(source: String, sourceLang: String?, translated: String)] = []
                for (offset, translated) in results.enumerated() {
                    guard let translated else { continue }
                    let candidate = group.candidates[batch[offset]]
                    updates[candidate.id] = translated
                    cachePairs.append((candidate.text, group.sourceLanguageCode, translated))
                }
                guard !updates.isEmpty else { continue }
                LyricsTranslationCache.shared.bulkSet(
                    cachePairs,
                    targetLang: identity.targetLanguageCode,
                    provider: .baidu
                )
                hits.merge(updates) { _, new in new }
                translatedTextByLineID.merge(deduplication.expanding(updates)) { _, new in new }
                translatedIDs.formUnion(updates.keys)
                translatedCount += updates.count
            }
            let left = group.candidates.filter { !translatedIDs.contains($0.id) }
            if !left.isEmpty {
                remaining.append(LyricTranslationGroup(
                    id: group.id,
                    sourceLanguageCode: group.sourceLanguageCode,
                    candidates: left
                ))
            }
        }
        plog("🌐 Lyrics Baidu translation finished after \(Self.secondsText(since: startedAt)), "
            + "\(translatedCount) lines, failure=\(failure.map { "\($0)" } ?? "none")")
        let account = BaiduTranslateAccount.shared
        guard let failure else {
            account.recordSuccess()
            activity = translatedCount > 0 ? .baiduSuccess : .idle
            return (remaining, nil)
        }
        account.recordFailure(failure)
        let issue: BaiduTranslateIssue = failure == .notConfigured
            ? .notConfigured
            : .failed(BaiduTranslateAccount.message(for: failure))
        activity = .baiduNotReady(issue)
        return (remaining, issue)
    }

    private static func secondsText(since start: ContinuousClock.Instant) -> String {
        let elapsed = (ContinuousClock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return String(format: "%.1fs", seconds)
    }

    /// Once this song's translation is settled, translate the next queued
    /// song ahead of time so its lyrics open already translated.
    private func prefetchUpcomingSong(identity: TranslationTaskIdentity) {
        guard let upcoming = player.upcomingSongInQueue,
              upcoming.id != identity.songID else { return }
        LyricsTranslationPrefetcher.shared.prefetch(
            song: upcoming,
            targetLanguageCode: identity.targetLanguageCode,
            intelligence: intelligence
        )
    }

    /// Translation's availability reference is not Sendable in the current
    /// SDK. Keep it entirely inside this nonisolated operation and return only
    /// its Sendable status to the view's main-actor state machine.
    private nonisolated static func translationAvailabilityStatus(
        sourceLanguageCode: String?,
        sampleText: String,
        targetLanguageCode: String
    ) async throws -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        let target = Locale.Language(identifier: targetLanguageCode)
        if let sourceLanguageCode {
            return await availability.status(
                from: Locale.Language(identifier: sourceLanguageCode),
                to: target
            )
        }
        return try await availability.status(for: sampleText, to: target)
    }

    /// 为下一组建立 session。同一语言配置再次启用时必须 invalidate 配置版本，
    /// 才能让 SwiftUI 重新运行 translationTask。
    private func activateGroup(at index: Int, identity: TranslationTaskIdentity) {
        guard preparedIdentity == identity, preparedGroups.indices.contains(index) else {
            translationConfig = nil
            return
        }

        activeGroupIndex = index
        let group = preparedGroups[index]
        let source = group.sourceLanguageCode.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: identity.targetLanguageCode)
        var next = TranslationSession.Configuration(source: source, target: target)

        if var current = translationConfig,
           current.source == next.source,
           current.target == next.target {
            current.invalidate()
            next = current
        }
        translationConfig = next
    }

    /// 一次只翻译同一源语言的行。失败进入短时间冷却，避免用户取消下载或系统
    /// 临时错误后，同一首歌立即再次抢占系统展示链。
    private func runTranslation(session: TranslationSession) async {
        guard let identity = preparedIdentity,
              identity == translationTaskIdentity,
              preparedGroups.indices.contains(activeGroupIndex) else {
            return
        }

        let groupIndex = activeGroupIndex
        let group = preparedGroups[groupIndex]
        let requests = group.candidates.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        guard !requests.isEmpty else { return }

        // 译文和缓存都整批写:逐句写回会让整页歌词每一句重算一遍,逐句写缓存每句都要算键、排一次存盘。
        // 攒着的缓存在任何一条退出路径上都要写掉,中途切走时已经翻好的不白翻。
        var stream = LyricTranslationStreamBatch(lineCount: lyrics.count)
        var pendingCachePairs: [(source: String, sourceLang: String?, translated: String)] = []
        defer {
            Self.storeTranslations(&pendingCachePairs, targetLanguageCode: identity.targetLanguageCode, provider: .system)
        }
        // 一批里检测出来的语言就那么几种,规范化一次记下来,不必每句再解析一遍语言码。
        var normalizedDetectedLanguages: [String: String] = [:]
        var newStateUpdates: [String: String] = [:]
        var translationFailed = false
        do {
            for try await response in session.translate(batch: requests) {
                guard !Task.isCancelled else { return }
                let id = response.clientIdentifier ?? ""
                let translated = response.targetText
                if !id.isEmpty { newStateUpdates[id] = translated }
                let rawDetected = response.sourceLanguage.minimalIdentifier
                let detectedSourceLanguageCode: String
                if let known = normalizedDetectedLanguages[rawDetected] {
                    detectedSourceLanguageCode = known
                } else {
                    detectedSourceLanguageCode = LyricsTranslationSettingsStore.normalizedLanguageCode(rawDetected)
                    normalizedDetectedLanguages[rawDetected] = detectedSourceLanguageCode
                }
                pendingCachePairs.append(
                    (
                        source: response.sourceText,
                        sourceLang: group.sourceLanguageCode,
                        translated: translated
                    )
                )
                if group.sourceLanguageCode != detectedSourceLanguageCode {
                    pendingCachePairs.append(
                        (
                            source: response.sourceText,
                            sourceLang: detectedSourceLanguageCode,
                            translated: translated
                        )
                    )
                }
                if !id.isEmpty {
                    stream.add(translated, forLines: deduplication.lineIDs(for: id))
                }
                if let due = stream.takeIfDue(now: ProcessInfo.processInfo.systemUptime) {
                    translatedTextByLineID.merge(due) { _, new in new }
                    Self.storeTranslations(
                        &pendingCachePairs,
                        targetLanguageCode: identity.targetLanguageCode,
                        provider: .system
                    )
                }
            }
        } catch {
            guard !Task.isCancelled,
                  preparedIdentity == identity,
                  translationTaskIdentity == identity,
                  activeGroupIndex == groupIndex else { return }
            translationFailed = true
            LyricsTranslationCache.shared.markFailed(
                sources: group.candidates.compactMap { candidate in
                    newStateUpdates[candidate.id] == nil ? candidate.text : nil
                },
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
            LyricsTranslationCache.shared.markPairFailed(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
            plog("Lyrics translation failed: \(error.localizedDescription)")
        }

        guard !Task.isCancelled,
              preparedIdentity == identity,
              translationTaskIdentity == identity,
              activeGroupIndex == groupIndex else { return }

        Self.storeTranslations(&pendingCachePairs, targetLanguageCode: identity.targetLanguageCode, provider: .system)
        if !translationFailed {
            LyricsTranslationCache.shared.clearPairFailure(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
        }

        if !newStateUpdates.isEmpty {
            translatedTextByLineID.merge(
                deduplication.expanding(newStateUpdates)
            ) { _, new in new }
        }

        guard !translationFailed else {
            activity = .systemPreparationRequired
            translationConfig = nil
            preparedGroups = []
            preparedIdentity = nil
            return
        }

        let nextIndex = groupIndex + 1
        if preparedGroups.indices.contains(nextIndex) {
            activateGroup(at: nextIndex, identity: identity)
        } else {
            translationConfig = nil
            activity = completionActivity ?? .notNeeded
            completionActivity = nil
            preparedGroups = []
            preparedIdentity = nil
        }
    }
}

/// Translates the next queued song's lyrics with the remote provider before
/// it starts. Only lyrics already stored on this device are used, so nothing
/// is fetched from a source, and only one song is prepared at a time.
@MainActor
final class LyricsTranslationPrefetcher {
    static let shared = LyricsTranslationPrefetcher()

    private struct Job {
        let songID: String
        let targetLanguageCode: String
        let task: Task<Void, Never>
    }

    private var job: Job?

    private init() {}

    func prefetch(
        song: Song,
        targetLanguageCode: String,
        intelligence: MusicIntelligenceService
    ) {
        if let job, job.songID == song.id, job.targetLanguageCode == targetLanguageCode {
            return
        }
        job?.task.cancel()
        let songContext = LyricTranslationSongContext(title: song.title, artist: song.artistName)
        let skippedSourceLanguageCodes = LyricsTranslationSettingsStore.shared.skippedSourceLanguageCodes
        let showsBundledTranslations = LyricsTranslationSettingsStore.shared.showsBundledTranslations
        let task = Task { @MainActor in
            guard let lyrics = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id),
                  !lyrics.isEmpty,
                  // 和播放页同一份:自带译文藏起来时,那些行也要预先译好。
                  let prepared = try? await LyricsTranslationPreparer.shared.prepare(
                      lyrics: LyricBundledTranslationPolicy.presentation(
                          of: lyrics,
                          showsBundledTranslations: showsBundledTranslations
                      ).lines,
                      targetLanguageCode: targetLanguageCode,
                      skippedSourceLanguageCodes: skippedSourceLanguageCodes,
                      enabled: true,
                      songContext: songContext
                  ),
                  !Task.isCancelled else { return }
            let cache = LyricsTranslationCache.shared
            let groups = LyricTranslationDeduplication(groups: prepared.groups).groups
            var sourceLanguageByID: [String: String?] = [:]
            let pending = groups.flatMap { group in
                group.candidates.filter { candidate in
                    sourceLanguageByID[candidate.id] = group.sourceLanguageCode
                    return cache.translation(
                        for: candidate.text,
                        sourceLang: group.sourceLanguageCode,
                        targetLang: targetLanguageCode,
                        provider: .intelligent
                    ) == nil
                }
            }
            guard !pending.isEmpty else { return }
            plog("🌐 Prefetching lyrics translation for the next song: \(pending.count) lines")
            guard let execution = await intelligence.translateLyrics(
                pending,
                targetLanguageCode: targetLanguageCode
            ), !Task.isCancelled else { return }
            cache.bulkSet(
                pending.compactMap { candidate in
                    execution.translations[candidate.id].map { translated in
                        (
                            source: candidate.text,
                            sourceLang: sourceLanguageByID[candidate.id] ?? nil,
                            translated: translated
                        )
                    }
                },
                targetLang: targetLanguageCode,
                provider: .intelligent
            )
        }
        job = Job(songID: song.id, targetLanguageCode: targetLanguageCode, task: task)
    }

    /// Lets the song that was being prepared reuse that request instead of
    /// starting a second one.
    func waitIfTranslating(songID: String, targetLanguageCode: String) async {
        guard let job, job.songID == songID,
              job.targetLanguageCode == targetLanguageCode else { return }
        await job.task.value
    }

    func cancel() {
        job?.task.cancel()
        job = nil
    }
}
