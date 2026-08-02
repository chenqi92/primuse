import Foundation
import PrimuseKit

actor ScraperManager {
    private var scraperCache: [String: any MusicScraper] = [:]

    /// 命中 429/503 的源在此记录退避截止时刻(按 `config.id`)。批量刮削会反复调用
    /// `scrapeMetadata`,这张表让被限流的源在退避窗口内的后续调用里被直接跳过,
    /// 不再继续撞限流。无 Retry-After 时用 `defaultBackoff` 兜底。
    private var rateLimitBackoff: [String: ContinuousClock.Instant] = [:]
    private struct FailureState {
        var consecutiveFailures: Int
        var circuitOpenUntil: ContinuousClock.Instant?
    }
    private var failureStates: [String: FailureState] = [:]
    private static let defaultBackoff: Duration = .seconds(30)
    private static let maxBackoff: Duration = .seconds(300)
    private static let circuitFailureThreshold = 3
    private static let circuitCooldown: Duration = .seconds(120)

    struct ScrapeNeeds: Sendable {
        var metadata: Bool = true
        var cover: Bool = true
        var lyrics: Bool = true
    }

    private struct RankedMetadataDetail {
        let detail: ScraperDetail
        let rank: ScrapeCandidateRank
        let sourceOrder: Int
        let searchOrder: Int
    }

    private struct PendingMetadataCandidate {
        let config: ScraperSourceConfig
        let item: ScraperSearchItem
        let rank: ScrapeCandidateRank
        let sourceOrder: Int
        let searchOrder: Int
    }

    /// 该源当前是否处于限流退避窗口内(过期条目顺手清掉)。
    private func isBackingOff(_ config: ScraperSourceConfig) -> Bool {
        guard let until = rateLimitBackoff[config.id] else { return false }
        if ContinuousClock.now >= until {
            rateLimitBackoff[config.id] = nil
            return false
        }
        return true
    }

    private func isCircuitOpen(_ config: ScraperSourceConfig) -> Bool {
        guard let until = failureStates[config.id]?.circuitOpenUntil else { return false }
        if ContinuousClock.now >= until {
            failureStates[config.id] = nil
            return false
        }
        return true
    }

    private func registerSuccess(_ config: ScraperSourceConfig) {
        failureStates[config.id] = nil
    }

    private func registerFailure(_ error: Error, config: ScraperSourceConfig) {
        if isCancellation(error) { return }
        if let scraperError = error as? ScraperError {
            switch scraperError {
            case .notFound, .rateLimited:
                return
            case .networkError, .parseError:
                break
            }
        }
        var state = failureStates[config.id] ?? FailureState(consecutiveFailures: 0, circuitOpenUntil: nil)
        state.consecutiveFailures += 1
        if state.consecutiveFailures >= Self.circuitFailureThreshold {
            state.circuitOpenUntil = ContinuousClock.now + Self.circuitCooldown
            plog("Scrape source unavailable [\(config.type.displayName)], circuit open for \(Self.circuitCooldown)")
        }
        failureStates[config.id] = state
    }

    private func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        if case ScraperError.networkError(let message) = error,
           message.localizedCaseInsensitiveContains("cancel") {
            return true
        }
        return false
    }

    private func handleFailure(_ error: Error, config: ScraperSourceConfig) {
        if !handleRateLimit(error, config: config) {
            registerFailure(error, config: config)
        }
    }

    /// 命中 `ScraperError.rateLimited` 时登记退避截止时刻。
    /// retryAfter(秒)优先,缺失则用 `defaultBackoff`,并夹到 `maxBackoff` 上限。
    private func registerBackoff(_ config: ScraperSourceConfig, retryAfter: Int?) {
        var delay: Duration = retryAfter.map { .seconds(max($0, 1)) } ?? Self.defaultBackoff
        if delay > Self.maxBackoff { delay = Self.maxBackoff }
        rateLimitBackoff[config.id] = ContinuousClock.now + delay
        plog("⛔️ Scrape rate limited [\(config.type.displayName)], backing off \(delay)")
    }

    /// 判断 catch 到的 error 是否为限流;是则登记退避并返回 true(调用方据此跳到下一源)。
    private func handleRateLimit(_ error: Error, config: ScraperSourceConfig) -> Bool {
        guard case ScraperError.rateLimited(let retryAfter) = error else { return false }
        registerBackoff(config, retryAfter: retryAfter)
        return true
    }

    func scrapeMetadata(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        needs: ScrapeNeeds,
        settings: ScraperSettings
    ) async -> ScrapeResult {
        var result = ScrapeResult(errors: [])
        let enabledSources = settings.enabledSources

        // Clean title for search; also split "歌手 - 标题" 文件名(云盘无标签歌曲常见)
        // 推出 effectiveArtist,避免用整串脏标题去搜导致错配。
        let (cleanedTitle, effectiveArtist) = Self.searchTitleArtist(title, artist: artist)
        guard !cleanedTitle.isEmpty else {
            // Some remote items have an empty title (or a filename made only
            // of bracketed noise that cleanTitle removes). Sending an empty
            // query makes every provider return a different validation error,
            // burns quota, and records a misleading multi-source failure.
            plog("🔍 Scrape skipped: empty cleaned title")
            return result
        }

        // Rank the returned rows inside each provider, then continue to the next
        // provider only while the best trusted detail is still sparse. This
        // fixes provider-first selection without multiplying every bulk scrape
        // into an unconditional all-source request fan-out.
        if needs.metadata {
            var selectedDetail: RankedMetadataDetail?
            var additionalCandidates: [PendingMetadataCandidate] = []
            let metadataSources = enabledSources.enumerated().filter { $0.element.type.supportsMetadata }

            metadataSourceLoop: for (sourceOrder, config) in metadataSources {
                if isBackingOff(config) || isCircuitOpen(config) {
                    plog("🔍 Skipping \(config.type.displayName) metadata — temporarily unavailable")
                    continue
                }
                do {
                    plog("🔍 Scraping metadata from \(config.type.displayName) for '\(cleanedTitle)'")
                    let scraper = getScraper(for: config)
                    let searchResult = try await scraper.search(
                        query: cleanedTitle, artist: effectiveArtist, album: nil, limit: Self.autoScrapeLimit
                    )
                    plog("🔍 \(config.type.displayName) returned \(searchResult.items.count) results")
                    // Reject unsafe automatic identities before truncating the
                    // ranked set. Duration-first presentation must not let a
                    // same-length wrong artist consume the limited detail slots.
                    let safeItems = searchResult.items.filter {
                        Self.isConfidentAutoMatch(
                            $0,
                            title: cleanedTitle,
                            artist: effectiveArtist,
                            durationMs: durationMs(duration)
                        )
                    }
                    let rankedItems = Self.topMatches(
                        in: safeItems,
                        title: cleanedTitle,
                        artist: effectiveArtist,
                        durationMs: durationMs(duration),
                        maxCount: Self.autoMetadataCandidatesPerSource
                    )
                    let confidentCandidates = rankedItems.enumerated().map { searchOrder, item in
                        PendingMetadataCandidate(
                            config: config,
                            item: item,
                            rank: Self.candidateRank(
                                item,
                                title: cleanedTitle,
                                artist: effectiveArtist,
                                durationMs: durationMs(duration)
                            ),
                            sourceOrder: sourceOrder,
                            searchOrder: searchOrder
                        )
                    }
                    guard let primaryCandidate = confidentCandidates.first else {
                        registerSuccess(config)
                        continue
                    }
                    additionalCandidates.append(contentsOf: confidentCandidates.dropFirst())

                    do {
                        if let rankedDetail = try await fetchMetadataDetail(
                            primaryCandidate,
                            title: cleanedTitle,
                            artist: effectiveArtist,
                            durationMs: durationMs(duration)
                        ) {
                            selectedDetail = Self.preferredDetail(rankedDetail, current: selectedDetail)
                            if Self.isSufficientMetadata(selectedDetail?.rank) {
                                break metadataSourceLoop
                            }
                        }
                    } catch {
                        if isCancellation(error) { return result }
                        plog("🔍 \(config.type.displayName) detail FAILED: \(error.localizedDescription)")
                        await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                        handleFailure(error, config: config)
                        result.errors.append("[\(config.type.displayName)] metadata detail: \(error.localizedDescription)")
                    }
                } catch {
                    if isCancellation(error) { return result }
                    plog("🔍 \(config.type.displayName) FAILED: \(error.localizedDescription)")
                    await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    handleFailure(error, config: config)
                    result.errors.append("[\(config.type.displayName)] metadata: \(error.localizedDescription)")
                }
            }

            // Search rows from configurable providers often expose only identity
            // fields; their second or third detail can be much richer than the
            // server's first row. Try a small globally ranked fallback set only
            // when every provider's primary detail is still insufficient.
            if !Self.isSufficientMetadata(selectedDetail?.rank) {
                let fallbackCandidates = additionalCandidates.sorted(by: Self.isPreferred)
                for candidate in fallbackCandidates.prefix(Self.autoMetadataExtraDetailFetchLimit) {
                    if isBackingOff(candidate.config) || isCircuitOpen(candidate.config) { continue }
                    do {
                        if let rankedDetail = try await fetchMetadataDetail(
                            candidate,
                            title: cleanedTitle,
                            artist: effectiveArtist,
                            durationMs: durationMs(duration)
                        ) {
                            selectedDetail = Self.preferredDetail(rankedDetail, current: selectedDetail)
                            if Self.isSufficientMetadata(selectedDetail?.rank) { break }
                        }
                    } catch {
                        if isCancellation(error) { return result }
                        plog("🔍 \(candidate.config.type.displayName) fallback detail FAILED: \(error.localizedDescription)")
                        await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                        handleFailure(error, config: candidate.config)
                        result.errors.append("[\(candidate.config.type.displayName)] metadata detail: \(error.localizedDescription)")
                    }
                }
            }
            result.detail = selectedDetail?.detail
        }

        // Scrape cover from first successful source
        if needs.cover {
            for config in enabledSources where config.type.supportsCover {
                if isBackingOff(config) || isCircuitOpen(config) { continue }
                do {
                    let scraper = getScraper(for: config)

                    // If we already have a detail with cover URL from the same source, use it
                    if let detail = result.detail, detail.source == config.type, let coverUrl = detail.coverUrl {
                        if let data = try await downloadImage(url: coverUrl, sourceConfig: config) {
                            registerSuccess(config)
                            result.coverData = data
                            break
                        }
                    }

                    // Otherwise search and get cover
                    let searchResult = try await scraper.search(
                        query: cleanedTitle, artist: effectiveArtist, album: nil, limit: Self.autoScrapeLimit
                    )
                    registerSuccess(config)
                    if let best = Self.bestMatch(in: searchResult.items, title: cleanedTitle, artist: effectiveArtist, durationMs: durationMs(duration)) {
                        let covers = try await scraper.getCoverArt(externalId: best.externalId)
                        registerSuccess(config)
                        if let coverUrl = covers.first?.coverUrl,
                           let data = try await downloadImage(url: coverUrl, sourceConfig: config) {
                            result.coverData = data
                            break
                        }
                    }
                } catch {
                    if isCancellation(error) { return result }
                    await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    handleFailure(error, config: config)
                    result.errors.append("[\(config.type.displayName)] cover: \(error.localizedDescription)")
                }
            }
        }

        // Scrape lyrics from first successful source
        if needs.lyrics {
            plog("🎤 Lyrics tier: needs.lyrics=true, enabled sources w/ supportsLyrics: \(enabledSources.filter { $0.type.supportsLyrics }.map { $0.type.displayName })")
            for config in enabledSources where config.type.supportsLyrics {
                if isBackingOff(config) || isCircuitOpen(config) {
                    plog("🎤 Skipping \(config.type.displayName) lyrics — temporarily unavailable")
                    continue
                }
                do {
                    let scraper = getScraper(for: config)

                    if config.type == .lrclib, let artist {
                        // LRCLIB uses direct lookup, not search
                        guard let lrclibScraper = scraper as? LRCLIBScraper else {
                            throw ScraperError.parseError("LRCLIB scraper cache type mismatch")
                        }
                        let fetchedLyrics = try await lrclibScraper.fetchLyrics(
                            title: cleanedTitle, artist: artist, album: album, duration: duration
                        )
                        registerSuccess(config)
                        if let lyricsResult = fetchedLyrics, lyricsResult.hasLyrics {
                            result.lyrics = parseLyrics(lyricsResult)
                            if result.lyrics != nil { break }
                        }
                    } else {
                        // Standard search → getLyrics flow
                        // 选 top-3 候选依次 try, 优先返字级歌词的; 都没字级才
                        // 用第一个行级 fallback。这样同源内 score 相同的几个
                        // 候选(常见: title+duration 都接近)能挑到带逐字的版本。
                        let searchResult = try await scraper.search(
                            query: cleanedTitle, artist: effectiveArtist, album: nil, limit: Self.autoScrapeLimit
                        )
                        registerSuccess(config)
                        // Lyrics must match the requested title. Duration alone is not a
                        // sufficient identity signal: short clips with no artist metadata
                        // can otherwise accept an unrelated same-length song returned by a
                        // noisy search provider. Metadata/cover retain their legacy ranked
                        // fallback, while lyrics choose false-negative over false-positive.
                        let titleCompatibleItems = searchResult.items.filter {
                            Self.isLyricsTitleCompatible(candidate: $0.title, requested: cleanedTitle)
                        }
                        let candidates = Self.topMatches(
                            in: titleCompatibleItems, title: cleanedTitle, artist: effectiveArtist,
                            durationMs: durationMs(duration), maxCount: 3
                        )
                        plog("🎤 [\(config.type.displayName)] lyrics search: \(searchResult.items.count) items, \(titleCompatibleItems.count) title-compatible → top \(candidates.count) candidates: \(candidates.map { "\($0.title)/\($0.artist ?? "?")" })")
                        var lineLevelFallback: [LyricLine]?
                        var triedCount = 0
                        var hasLyricsCount = 0
                        for candidate in candidates {
                            triedCount += 1
                            do {
                                let fetchedLyrics = try await scraper.getLyrics(externalId: candidate.externalId)
                                registerSuccess(config)
                                guard let lyricsResult = fetchedLyrics,
                                      lyricsResult.hasLyrics else { continue }
                                hasLyricsCount += 1
                                guard let parsed = parseLyrics(lyricsResult), !parsed.isEmpty else { continue }
                                if parsed.contains(where: { $0.isWordLevel }) {
                                    plog("🎤 [\(config.type.displayName)] picked WORD-level lyrics from '\(candidate.title)' (\(parsed.count) lines)")
                                    result.lyrics = parsed
                                    break
                                } else if lineLevelFallback == nil {
                                    lineLevelFallback = parsed
                                }
                            } catch {
                                if isCancellation(error) { return result }
                                plog("🎤 [\(config.type.displayName)] getLyrics failed for '\(candidate.title)': \(error.localizedDescription)")
                                handleFailure(error, config: config)
                                if isBackingOff(config) || isCircuitOpen(config) { break }
                            }
                        }
                        if result.lyrics == nil, let fb = lineLevelFallback {
                            plog("🎤 [\(config.type.displayName)] picked LINE-level fallback (\(fb.count) lines)")
                            result.lyrics = fb
                        }
                        if result.lyrics == nil {
                            plog("🎤 [\(config.type.displayName)] NO lyrics found: tried=\(triedCount) hasLyrics=\(hasLyricsCount) — moving to next source")
                        }
                        if result.lyrics != nil { break }
                    }
                } catch {
                    if isCancellation(error) { return result }
                    plog("🎤 [\(config.type.displayName)] lyrics tier ERROR: \(error.localizedDescription)")
                    await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    handleFailure(error, config: config)
                    result.errors.append("[\(config.type.displayName)] lyrics: \(error.localizedDescription)")
                }
            }
            if result.lyrics == nil {
                plog("🎤 Lyrics tier: NO source returned lyrics, result.lyrics=nil")
            }
        } else {
            plog("🎤 Lyrics tier: needs.lyrics=false, skipped")
        }

        return result
    }

    /// Fetch enough search rows to let local identity and completeness ranking
    /// recover richer matches that providers place below promoted first rows.
    private static let autoScrapeLimit = 15
    private static let autoMetadataCandidatesPerSource = 3
    private static let autoMetadataExtraDetailFetchLimit = 4
    private static let sufficientMetadataCompleteness = 7

    private nonisolated func durationMs(_ d: TimeInterval?) -> Int? {
        guard let d, d > 0 else { return nil }
        return Int(d * 1000)
    }

    /// 多维度评分挑最佳候选:
    /// - duration 接近度（最强信号,误差 < 2s 满分,2-5s 中等,5-10s 弱）
    /// - title 完全相等 / 互相包含
    /// - artist 命中
    ///
    /// 评分只决定候选顺序；最终候选还必须通过下方置信门槛，
    /// 不再把服务端首个结果当作无条件 fallback。
    static func bestMatch(
        in items: [ScraperSearchItem],
        title: String,
        artist: String?,
        durationMs targetMs: Int?
    ) -> ScraperSearchItem? {
        let safeItems = items.filter {
            isConfidentAutoMatch(
                $0,
                title: title,
                artist: artist,
                durationMs: targetMs
            )
        }
        return topMatches(
            in: safeItems,
            title: title,
            artist: artist,
            durationMs: targetMs,
            maxCount: 1
        ).first
    }

    static func isConfidentAutoMatch(
        _ item: ScraperSearchItem,
        title: String,
        artist: String?,
        durationMs targetMs: Int?
    ) -> Bool {
        let requestedTitle = normalizeComparableText(title)
        let candidateTitle = normalizeComparableText(item.title)
        guard !requestedTitle.isEmpty,
              !candidateTitle.isEmpty,
              candidateTitle == requestedTitle
                || candidateTitle.contains(requestedTitle)
                || requestedTitle.contains(candidateTitle) else {
            return false
        }

        let requestedArtist = normalizeComparableText(artist)
        let candidateArtist = normalizeComparableText(item.artist)
        let artistMatches = !candidateArtist.isEmpty
            && (candidateArtist == requestedArtist
            || candidateArtist.contains(requestedArtist)
            || requestedArtist.contains(candidateArtist))
        let durationMatches: Bool = if let targetMs,
                                       targetMs > 0,
                                       let candidateMs = item.durationMs {
            abs(candidateMs - targetMs) < 2_000
        } else {
            false
        }
        let durationClearlyConflicts: Bool
        if let targetMs,
           targetMs > 0,
           let candidateMs = item.durationMs,
           candidateMs > 0 {
            let plausibleToleranceMs = max(10_000, min(30_000, targetMs / 10))
            durationClearlyConflicts = abs(candidateMs - targetMs) > plausibleToleranceMs
        } else {
            durationClearlyConflicts = false
        }

        if !requestedArtist.isEmpty {
            if !candidateArtist.isEmpty {
                // A concrete conflicting artist is an identity failure. A near
                // duration must not turn a same-title cover into an automatic
                // metadata write.
                return artistMatches && !durationClearlyConflicts
            }
            // Some sources omit artist in search rows. In that case a near-
            // exact duration may act as the missing second identity signal.
            return durationMatches
        }

        // Without an artist, an exact title alone is weak evidence: popular
        // songs often have many covers with the same name. When both sides
        // expose a duration, require it to agree as the second identity
        // signal. Only fall back to an exact title when duration genuinely is
        // unavailable, preferring a false negative over persisting a cover's
        // artist/album into the user's track.
        if let targetMs, targetMs > 0 {
            return candidateTitle == requestedTitle && durationMatches
        }
        return candidateTitle == requestedTitle
    }

    /// Rank candidates with the same policy used by manual scraping. Provider
    /// order is only the final deterministic tie-breaker.
    static func topMatches(
        in items: [ScraperSearchItem],
        title: String,
        artist: String?,
        durationMs targetMs: Int?,
        maxCount: Int
    ) -> [ScraperSearchItem] {
        guard !items.isEmpty, maxCount > 0 else { return [] }
        let ranked = items.enumerated().map { index, item in
            (
                item: item,
                rank: candidateRank(item, title: title, artist: artist, durationMs: targetMs),
                index: index
            )
        }
        return ranked.sorted { lhs, rhs in
            if ScrapeCandidateRankingPolicy.isPreferred(lhs.rank, over: rhs.rank) {
                return true
            }
            if ScrapeCandidateRankingPolicy.isPreferred(rhs.rank, over: lhs.rank) {
                return false
            }
            return lhs.index < rhs.index
        }.prefix(maxCount).map(\.item)
    }

    private static func candidateRank(
        _ item: ScraperSearchItem,
        title: String,
        artist: String?,
        durationMs: Int?
    ) -> ScrapeCandidateRank {
        ScrapeCandidateRankingPolicy.rank(
            requestedTitle: title,
            requestedArtist: artist,
            targetDurationMs: durationMs,
            candidateTitle: item.title,
            candidateArtist: item.artist,
            candidateDurationMs: item.durationMs,
            candidateAlbum: item.album,
            candidateYear: item.year,
            candidateHasArtwork: preferredText(item.coverUrl, fallback: nil) != nil,
            candidateTrackNumber: item.trackNumber,
            candidateGenreCount: meaningfulGenres(item.genres)?.count ?? 0
        )
    }

    private func fetchMetadataDetail(
        _ candidate: PendingMetadataCandidate,
        title: String,
        artist: String?,
        durationMs: Int?
    ) async throws -> RankedMetadataDetail? {
        guard !isBackingOff(candidate.config), !isCircuitOpen(candidate.config) else {
            return nil
        }
        let scraper = getScraper(for: candidate.config)
        let fetchedDetail = try await scraper.getDetail(externalId: candidate.item.externalId)
        registerSuccess(candidate.config)
        let detail = Self.mergedDetail(fetchedDetail, searchItem: candidate.item)
        let detailItem = Self.searchItem(from: detail)
        guard Self.isConfidentAutoMatch(
            detailItem,
            title: title,
            artist: artist,
            durationMs: durationMs
        ) else { return nil }

        return RankedMetadataDetail(
            detail: detail,
            rank: Self.candidateRank(
                detailItem,
                title: title,
                artist: artist,
                durationMs: durationMs
            ),
            sourceOrder: candidate.sourceOrder,
            searchOrder: candidate.searchOrder
        )
    }

    private static func preferredDetail(
        _ candidate: RankedMetadataDetail,
        current: RankedMetadataDetail?
    ) -> RankedMetadataDetail {
        guard let current else { return candidate }
        return isPreferred(candidate, over: current) ? candidate : current
    }

    private static func isSufficientMetadata(_ rank: ScrapeCandidateRank?) -> Bool {
        guard let rank,
              rank.titleMatchLevel == 2,
              rank.metadataCompleteness >= sufficientMetadataCompleteness else {
            return false
        }
        switch rank.durationTier {
        case .close:
            return (rank.durationDeltaMs ?? Int.max) < 5_000
        case .unavailable:
            return true
        case .plausible, .unknown, .mismatch:
            return false
        }
    }

    private static func isPreferred(
        _ lhs: PendingMetadataCandidate,
        _ rhs: PendingMetadataCandidate
    ) -> Bool {
        // Give every provider's second result a chance before spending the
        // fallback budget on third rows from an earlier provider.
        if lhs.searchOrder != rhs.searchOrder {
            return lhs.searchOrder < rhs.searchOrder
        }
        if ScrapeCandidateRankingPolicy.isPreferred(lhs.rank, over: rhs.rank) {
            return true
        }
        if ScrapeCandidateRankingPolicy.isPreferred(rhs.rank, over: lhs.rank) {
            return false
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    private static func isPreferred(
        _ lhs: RankedMetadataDetail,
        over rhs: RankedMetadataDetail
    ) -> Bool {
        if ScrapeCandidateRankingPolicy.isPreferred(lhs.rank, over: rhs.rank) {
            return true
        }
        if ScrapeCandidateRankingPolicy.isPreferred(rhs.rank, over: lhs.rank) {
            return false
        }
        if lhs.sourceOrder != rhs.sourceOrder {
            return lhs.sourceOrder < rhs.sourceOrder
        }
        return lhs.searchOrder < rhs.searchOrder
    }

    private static func mergedDetail(
        _ detail: ScraperDetail?,
        searchItem: ScraperSearchItem
    ) -> ScraperDetail {
        ScraperDetail(
            externalId: preferredText(detail?.externalId, fallback: searchItem.externalId) ?? searchItem.externalId,
            source: detail?.source ?? searchItem.source,
            title: preferredText(detail?.title, fallback: searchItem.title) ?? searchItem.title,
            artist: preferredText(detail?.artist, fallback: searchItem.artist),
            albumArtist: preferredText(detail?.albumArtist, fallback: nil),
            album: preferredText(detail?.album, fallback: searchItem.album),
            year: preferredPositiveInt(detail?.year, fallback: searchItem.year),
            trackNumber: preferredPositiveInt(detail?.trackNumber, fallback: searchItem.trackNumber),
            discNumber: preferredPositiveInt(detail?.discNumber, fallback: nil),
            durationMs: preferredPositiveInt(detail?.durationMs, fallback: searchItem.durationMs),
            genres: meaningfulGenres(detail?.genres) ?? meaningfulGenres(searchItem.genres),
            coverUrl: preferredText(detail?.coverUrl, fallback: searchItem.coverUrl)
        )
    }

    private static func searchItem(from detail: ScraperDetail) -> ScraperSearchItem {
        ScraperSearchItem(
            externalId: detail.externalId,
            source: detail.source,
            title: detail.title,
            artist: detail.artist,
            album: detail.album,
            year: detail.year,
            durationMs: detail.durationMs,
            coverUrl: detail.coverUrl,
            trackNumber: detail.trackNumber,
            genres: detail.genres
        )
    }

    private static func preferredText(_ value: String?, fallback: String?) -> String? {
        if let value {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let fallback {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func preferredPositiveInt(_ value: Int?, fallback: Int?) -> Int? {
        if let value, value > 0 { return value }
        if let fallback, fallback > 0 { return fallback }
        return nil
    }

    private static func meaningfulGenres(_ genres: [String]?) -> [String]? {
        let cleaned = genres?.compactMap { genre -> String? in
            let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let cleaned, !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// Lyrics are destructive-looking when wrong, so require a normalized title
    /// identity before fetching them. Equality covers the normal case; containment
    /// keeps editions such as "Song Title (Live)" / "Song Title - Remastered"
    /// working after `cleanTitle` has removed bracket noise.
    private static func isLyricsTitleCompatible(candidate: String, requested: String) -> Bool {
        let candidateTitle = normalizeComparableText(candidate)
        let requestedTitle = normalizeComparableText(requested)
        guard !candidateTitle.isEmpty, !requestedTitle.isEmpty else { return false }
        return candidateTitle == requestedTitle
            || candidateTitle.contains(requestedTitle)
            || requestedTitle.contains(candidateTitle)
    }

    // MARK: - Helpers

    private func getScraper(for config: ScraperSourceConfig) -> any MusicScraper {
        let key = cacheKey(for: config)
        if let cached = scraperCache[key] {
            return cached
        }
        let scraper = MusicScraperFactory.create(for: config)
        scraperCache[key] = scraper
        return scraper
    }

    /// Cache key for a scraper instance. `config.id` is stable across edits, but
    /// `ConfigurableScraper` bakes Cookie/headers in at init — updating a failed
    /// Cookie or editing a custom config leaves the id unchanged, so keying on id
    /// alone would keep serving the stale instance until restart. Fold in every
    /// input that影响 scraper 构造(cookie / extraConfig / 自定义配置的 modifiedAt)
    /// so changing any of them yields a fresh instance automatically.
    private func cacheKey(for config: ScraperSourceConfig) -> String {
        var parts: [String] = [config.id, config.cookie ?? ""]
        if let extra = config.extraConfig, !extra.isEmpty {
            parts.append(extra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))
        }
        if case .custom(let configId) = config.type,
           let modifiedAt = ScraperConfigStore.shared.config(for: configId)?.modifiedAt {
            parts.append(String(modifiedAt.timeIntervalSince1970))
        }
        return parts.joined(separator: "|")
    }

    /// Invalidate cached scrapers (e.g., when settings change)
    func invalidateCache() {
        scraperCache.removeAll()
    }

    private func downloadImage(url: String, sourceConfig: ScraperSourceConfig) async throws -> Data? {
        try await ConfigurableScraper.downloadResource(from: url, sourceConfig: sourceConfig)
    }

    private func parseLyrics(_ result: ScraperLyricsResult) -> [LyricLine]? {
        if let lrc = result.lrcContent, !lrc.isEmpty {
            let parsed = LyricsParser.parse(lrc)
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }

    static func searchTitle(_ title: String, artist: String?) -> String {
        let cleanedTitle = cleanTitle(title)
        let cleanedArtist = normalizeComparableText(artist)

        guard !cleanedArtist.isEmpty,
              let split = splitTitleAroundDash(cleanedTitle) else {
            return cleanedTitle
        }

        if normalizeComparableText(split.left) == cleanedArtist, !split.right.isEmpty {
            return split.right
        }
        if normalizeComparableText(split.right) == cleanedArtist, !split.left.isEmpty {
            return split.left
        }

        return cleanedTitle
    }

    /// 像 `searchTitle`,但当 artist 为空且标题是「歌手 - 标题」(云盘无标签歌曲的
    /// 文件名常见)时,把歌手也拆出来,返回 (干净标题, 歌手)。已有可信 artist 时沿用。
    static func searchTitleArtist(_ title: String, artist: String?) -> (title: String, artist: String?) {
        let cleanedArtist = normalizeComparableText(artist)
        if !cleanedArtist.isEmpty {
            return (searchTitle(title, artist: artist), artist)
        }
        let cleaned = cleanTitle(title)
        if let split = splitTitleAroundDash(cleaned) {
            let left = split.left.trimmingCharacters(in: .whitespaces)
            let right = split.right.trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty {
                // 约定「歌手 - 标题」:左歌手、右标题。
                return (cleanTitle(right), left)
            }
        }
        return (cleaned, nil)
    }

    static func shouldAppendArtist(to query: String, artist: String?) -> Bool {
        let cleanedArtist = normalizeComparableText(artist)
        guard !cleanedArtist.isEmpty else { return false }
        return !normalizeComparableText(query).contains(cleanedArtist)
    }

    /// Remove bracket content and noisy prefixes that interfere with search.
    static func cleanTitle(_ title: String) -> String {
        var result = title
        result = result.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "【[^】]*】", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "^\\d+[.\\s]+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitTitleAroundDash(_ title: String) -> (left: String, right: String)? {
        guard let dashRange = title.range(of: "\\s*[–—-]\\s+", options: .regularExpression) else {
            return nil
        }
        let left = String(title[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(title[dashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    private static func normalizeComparableText(_ text: String?) -> String {
        guard let text else { return "" }
        return cleanTitle(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[\\s·•・_\\-–—]+", with: "", options: .regularExpression)
    }
}
