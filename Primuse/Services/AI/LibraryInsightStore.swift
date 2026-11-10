import Foundation
import Observation
import PrimuseKit

/// AI 这次给的内容,以及用的服务和语言;编辑页保存时据此判断内容是不是 AI 原样给的。
typealias LibraryInsightDraft = (answer: LibraryInsightAIExchange.Answer, providerName: String, languageCode: String)

/// 专辑与艺人简介的读写入口,以及 AI 正在填写、最近一次失败这些界面状态。
/// 简介本身存在曲库快照里(`MusicLibrary.saveLibraryInsightRecord`),随曲库同步到别的设备。
@MainActor
@Observable
final class LibraryInsightStore {
    static let shared = LibraryInsightStore()

    private(set) var generatingIDs: Set<String> = []
    private(set) var failures: [String: AILibraryContentFailure] = [:]
    private(set) var retryDates: [String: Date] = [:]
    private(set) var fetchingLastFmIDs: Set<String> = []
    private(set) var lastFmFailures: [String: String] = [:]
    private(set) var fetchingAppleMusicIDs: Set<String> = []
    private(set) var fetchingWikipediaIDs: Set<String> = []
    private(set) var wikipediaFailures: [String: String] = [:]
    private(set) var appleMusicFailures: [String: String] = [:]
    private let lastFm: LastFmSimilarAPI
    private let appleMusicLookup: @Sendable (String) async throws -> LibraryInsightImportedDraft?
    private let appleMusicAlbumLookup: @Sendable (String, String) async throws -> LibraryInsightImportedDraft?
    private let wikipediaLookup: @Sendable (LibraryInsightSubject, String) async throws -> LibraryInsightImportedDraft?
    private let isAppleMusicContent: @MainActor (LibraryInsightSubject, MusicLibrary) -> Bool
    /// 最近一次写回音乐源的结果(写进了哪些、哪些没写成),只给界面看。
    private(set) var writebackNotes: [String: String] = [:]

    init(
        lastFm: LastFmSimilarAPI = LastFmSimilarAPI(),
        isAppleMusicContent: @escaping @MainActor (LibraryInsightSubject, MusicLibrary) -> Bool = {
            $1.hasAppleMusicSongs(for: $0)
        },
        appleMusicLookup: @escaping @Sendable (String) async throws -> LibraryInsightImportedDraft? = {
            try await AppleMusicCatalogNeighbors.artistInsight(matchingName: $0)
        },
        appleMusicAlbumLookup: @escaping @Sendable (String, String) async throws -> LibraryInsightImportedDraft? = {
            try await AppleMusicCatalogNeighbors.albumInsight(matchingTitle: $0, artist: $1)
        },
        wikipediaLookup: @escaping @Sendable (LibraryInsightSubject, String) async throws -> LibraryInsightImportedDraft? = {
            try await WikipediaInsightClient.shared.draft(for: $0, languageCode: $1)
        }
    ) {
        self.lastFm = lastFm
        self.appleMusicLookup = appleMusicLookup
        self.appleMusicAlbumLookup = appleMusicAlbumLookup
        self.wikipediaLookup = wikipediaLookup
        self.isAppleMusicContent = isAppleMusicContent
        // 上一版只在本机 Caches 里缓存过一份,现在改存曲库,旧文件清掉。
        let legacy = FileManager.default
            .primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("library-insights.json")
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    /// AI 用界面语言写。
    static var languageCode: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    func recordID(for subject: LibraryInsightSubject) -> String {
        subject.recordID(unknownArtistName: String(localized: "unknown_artist"))
    }

    func record(for subject: LibraryInsightSubject, in library: MusicLibrary) -> LibraryInsightRecord? {
        library.libraryInsightRecord(id: recordID(for: subject))
    }

    func isGenerating(_ subject: LibraryInsightSubject) -> Bool {
        generatingIDs.contains(recordID(for: subject))
    }

    func isFetchingLastFm(_ subject: LibraryInsightSubject) -> Bool {
        fetchingLastFmIDs.contains(recordID(for: subject))
    }

    func lastFmFailure(for subject: LibraryInsightSubject) -> String? {
        lastFmFailures[recordID(for: subject)]
    }

    func isFetchingImport(_ subject: LibraryInsightSubject) -> Bool {
        isFetchingLastFm(subject) || fetchingAppleMusicIDs.contains(recordID(for: subject))
            || fetchingWikipediaIDs.contains(recordID(for: subject))
    }

    func importFailure(for subject: LibraryInsightSubject) -> String? {
        appleMusicFailures[recordID(for: subject)] ?? wikipediaFailures[recordID(for: subject)]
            ?? lastFmFailure(for: subject)
    }

    func progressMessage(for subject: LibraryInsightSubject) -> String {
        if fetchingAppleMusicIDs.contains(recordID(for: subject)) {
            return String(localized: "library_insight_apple_music_fetching")
        }
        if fetchingWikipediaIDs.contains(recordID(for: subject)) {
            return String(localized: "library_insight_wikipedia_fetching")
        }
        return isFetchingLastFm(subject)
            ? String(localized: "library_insight_lastfm_fetching")
            : String(localized: "library_insight_generating")
    }

    func failure(for subject: LibraryInsightSubject) -> AILibraryContentFailure? {
        failures[recordID(for: subject)]
    }

    func retryDate(for subject: LibraryInsightSubject) -> Date? {
        guard let date = retryDates[recordID(for: subject)], date > Date() else { return nil }
        return date
    }

    func writebackNote(for subject: LibraryInsightSubject) -> String? {
        writebackNotes[recordID(for: subject)]
    }

    func setWritebackNote(written: [String], failed: [String], for subject: LibraryInsightSubject) {
        let separator = String(localized: "library_insight_list_separator")
        var parts: [String] = []
        if !written.isEmpty {
            parts.append(String(
                format: String(localized: "library_insight_writeback_written_format"),
                written.joined(separator: separator)
            ))
        }
        if !failed.isEmpty {
            parts.append(String(
                format: String(localized: "library_insight_writeback_failed_format"),
                failed.joined(separator: separator)
            ))
        }
        writebackNotes[recordID(for: subject)] = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 批量补简介开问前占上「正在生成」:详情页照样转圈,卡片上也不会对同一个再发一次。
    /// 已经有人在问就返回 false。
    func beginBatchGeneration(_ subject: LibraryInsightSubject) -> Bool {
        let id = recordID(for: subject)
        guard generatingIDs.insert(id).inserted else { return false }
        failures[id] = nil
        retryDates[id] = nil
        lastFmFailures[id] = nil
        appleMusicFailures[id] = nil
        wikipediaFailures[id] = nil
        return true
    }

    func endBatchGeneration(_ subject: LibraryInsightSubject) {
        generatingIDs.remove(recordID(for: subject))
    }

    func clearFailure(for subject: LibraryInsightSubject) {
        let id = recordID(for: subject)
        failures[id] = nil
        retryDates[id] = nil
        lastFmFailures[id] = nil
        appleMusicFailures[id] = nil
        wikipediaFailures[id] = nil
    }

    @discardableResult
    func fetchAppleMusic(_ subject: LibraryInsightSubject, library: MusicLibrary) async -> Bool {
        let id = recordID(for: subject)
        let previous = library.storedLibraryInsightRecord(id: id)
        guard let draft = await appleMusicDraft(for: subject, library: library),
              library.storedLibraryInsightRecord(id: id) == previous,
              let record = LibraryInsightEditing.recordFromImport(
                summary: draft.summary, tags: draft.tags, subject: subject, id: id,
                sourceLabel: draft.sourceLabel, sourceURL: draft.sourceURL,
                previous: previous, now: Date()
              ) else { return false }
        library.saveLibraryInsightRecord(record)
        return true
    }

    /// 只给曲库里有 Apple Music 歌曲的专辑、歌手取；别的来源点了就说明原因。
    func appleMusicDraft(for subject: LibraryInsightSubject, library: MusicLibrary) async -> LibraryInsightImportedDraft? {
        guard isAppleMusicContent(subject, library) else {
            appleMusicFailures[recordID(for: subject)] = String(localized: "library_insight_apple_music_only")
            return nil
        }
        guard Self.isIntroducible(subject),
              Self.isIntroducible(.artist(name: subject.artistName, genres: [], albums: [], tracks: [])),
              beginBatchGeneration(subject) else { return nil }
        let id = recordID(for: subject)
        fetchingAppleMusicIDs.insert(id)
        defer {
            fetchingAppleMusicIDs.remove(id)
            endBatchGeneration(subject)
        }
        do {
            let draft: LibraryInsightImportedDraft?
            if subject.kind == .album {
                draft = try await appleMusicAlbumLookup(subject.albumTitle, subject.artistName)
            } else {
                draft = try await appleMusicLookup(subject.artistName)
            }
            try Task.checkCancellation()
            if draft == nil { appleMusicFailures[id] = String(localized: "library_insight_apple_music_empty") }
            return draft
        } catch is CancellationError {
            return nil
        } catch AppleMusicCatalogNeighbors.ArtistInsightError.authorizationRequired {
            appleMusicFailures[id] = String(localized: "apple_music_notice_denied")
        } catch {
            if !Task.isCancelled { appleMusicFailures[id] = String(localized: "library_insight_apple_music_failed") }
        }
        return nil
    }

    /// 从维基百科取一份存下。来源记成维基百科和条目链接,界面上一直带着;不写回音乐源。
    @discardableResult
    func fetchWikipedia(_ subject: LibraryInsightSubject, library: MusicLibrary) async -> Bool {
        let id = recordID(for: subject)
        let previous = library.storedLibraryInsightRecord(id: id)
        guard let draft = await wikipediaDraft(for: subject),
              library.storedLibraryInsightRecord(id: id) == previous,
              let record = LibraryInsightEditing.recordFromImport(
                summary: draft.summary, tags: draft.tags, subject: subject, id: id,
                sourceLabel: draft.sourceLabel, sourceURL: draft.sourceURL,
                previous: previous, now: Date()
              ) else { return false }
        library.saveLibraryInsightRecord(record)
        return true
    }

    func wikipediaDraft(for subject: LibraryInsightSubject) async -> LibraryInsightImportedDraft? {
        guard Self.isIntroducible(subject), beginBatchGeneration(subject) else { return nil }
        let id = recordID(for: subject)
        fetchingWikipediaIDs.insert(id)
        defer {
            fetchingWikipediaIDs.remove(id)
            endBatchGeneration(subject)
        }
        do {
            let draft = try await wikipediaLookup(subject, Self.languageCode)
            try Task.checkCancellation()
            if draft == nil { wikipediaFailures[id] = String(localized: "library_insight_wikipedia_empty") }
            return draft
        } catch is CancellationError {
            return nil
        } catch WikipediaInsightClient.LookupError.unreachable {
            // 有些地区的网络到不了维基百科,和「稍后重试」不是一回事,单独说明。
            if !Task.isCancelled { wikipediaFailures[id] = String(localized: "library_insight_wikipedia_unreachable") }
        } catch {
            if !Task.isCancelled { wikipediaFailures[id] = String(localized: "library_insight_wikipedia_failed") }
        }
        return nil
    }

    @discardableResult
    func fetchLastFm(_ subject: LibraryInsightSubject, library: MusicLibrary) async -> Bool {
        let id = recordID(for: subject)
        let previous = library.storedLibraryInsightRecord(id: id)
        guard let draft = await lastFmDraft(for: subject),
              library.storedLibraryInsightRecord(id: id) == previous,
              let record = LibraryInsightEditing.recordFromImport(
                summary: draft.summary, tags: draft.tags, subject: subject, id: id,
                sourceLabel: draft.sourceLabel, sourceURL: draft.sourceURL,
                previous: previous, now: Date()
              ) else { return false }
        library.saveLibraryInsightRecord(record)
        return true
    }

    func lastFmDraft(for subject: LibraryInsightSubject) async -> LibraryInsightImportedDraft? {
        let id = recordID(for: subject)
        guard beginBatchGeneration(subject) else { return nil }
        fetchingLastFmIDs.insert(id)
        defer {
            fetchingLastFmIDs.remove(id)
            endBatchGeneration(subject)
        }
        do {
            let draft = try await lastFm.libraryInsight(for: subject, languageCode: Self.languageCode)
            try Task.checkCancellation()
            if draft == nil { lastFmFailures[id] = String(localized: "library_insight_lastfm_empty") }
            return draft
        } catch is CancellationError {
            return nil
        } catch LastFmSimilarAPI.SimilarError.missingAPIKey {
            lastFmFailures[id] = String(localized: "error_lastfm_api_key_missing")
        } catch {
            lastFmFailures[id] = String(localized: "library_insight_lastfm_failed")
        }
        return nil
    }

    /// 让 AI 写一份并直接存下(卡片上的「生成简介」「重新生成」)。用户改过的内容会被换掉,
    /// 由调用方先确认。
    func generate(
        _ subject: LibraryInsightSubject,
        library: MusicLibrary,
        intelligence: MusicIntelligenceService
    ) async {
        let id = recordID(for: subject)
        guard let draft = await aiDraft(for: subject, intelligence: intelligence) else { return }
        plog("✨ Library insight kind=\(subject.kind.rawValue) known=\(draft.answer.known) tags=\(draft.answer.tags.count)"
             + " provider=\(draft.providerName) tracks=\(subject.tracks.count) albums=\(subject.albums.count)")
        library.saveLibraryInsightRecord(LibraryInsightEditing.recordAfterAIFill(
            draft.answer,
            subject: subject,
            id: id,
            providerName: draft.providerName,
            languageCode: draft.languageCode,
            previous: library.storedLibraryInsightRecord(id: id),
            now: Date()
        ))
    }

    /// 只问 AI 不保存(编辑页的「用 AI 填写」)。失败时记下原因并返回 nil;
    /// 同一张专辑/同一位艺人已经在问就不再重复发。
    func aiDraft(
        for subject: LibraryInsightSubject,
        intelligence: MusicIntelligenceService
    ) async -> LibraryInsightDraft? {
        let id = recordID(for: subject)
        guard !generatingIDs.contains(id) else { return nil }
        let languageCode = Self.languageCode
        guard let request = LibraryInsightAIExchange.request(for: subject, languageCode: languageCode) else {
            failures[id] = .noTasteProfile
            return nil
        }
        generatingIDs.insert(id)
        clearFailure(for: subject)
        defer { generatingIDs.remove(id) }
        switch await intelligence.libraryInsight(request) {
        case .success(let answer, let providerName):
            return (answer, providerName, languageCode)
        case .failed(let failure, let retryAt):
            failures[id] = failure
            retryDates[id] = retryAt
            return nil
        }
    }

    /// 编辑页保存。两项都清空就删除;和这次 AI 草稿一字不差时仍记作 AI 写的。
    func saveEdit(
        _ subject: LibraryInsightSubject,
        summary: String,
        tags: [String],
        aiDraft: LibraryInsightDraft?,
        importedDraft: LibraryInsightImportedDraft? = nil,
        library: MusicLibrary
    ) {
        let id = recordID(for: subject)
        guard let record = LibraryInsightEditing.recordAfterUserEdit(
            summary: summary,
            tags: tags,
            subject: subject,
            id: id,
            previous: library.storedLibraryInsightRecord(id: id),
            aiDraft: aiDraft,
            importedDraft: importedDraft,
            now: Date()
        ) else { return }
        library.saveLibraryInsightRecord(record)
        clearFailure(for: subject)
    }

    func remove(_ subject: LibraryInsightSubject, library: MusicLibrary) {
        guard let record = record(for: subject, in: library) else { return }
        library.saveLibraryInsightRecord(LibraryInsightEditing.tombstone(of: record, now: Date()))
        clearFailure(for: subject)
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

    /// 卡片底部的出处:自己写/改过的标「已编辑」,AI 原样给的标服务名和「可能有误」。
    nonisolated static func footer(for record: LibraryInsightRecord) -> String {
        if record.isUserEdited, let source = record.importedFrom, ["Last.fm", "Apple Music", WikipediaInsightPolicy.sourceLabel].contains(source) {
            return String(localized: "library_insight_footer_edited") + " · "
                + String(format: String(localized: "library_insight_footer_imported_format"), source)
        }
        if !record.isUserEdited, let source = record.importedFrom {
            return String(format: String(localized: "library_insight_footer_imported_format"), source)
        }
        guard !record.isUserEdited, let provider = record.aiProviderName else {
            return String(localized: "library_insight_footer_edited")
        }
        return String(format: String(localized: "library_insight_footer_format"), provider)
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
            case .monthlyLimit: return String(localized: "library_insight_failed_monthly_limit")
            case .regionRestricted: return String(localized: "ai_song_discovery_failed_region")
            case .network: return String(localized: "ai_song_discovery_failed_network")
            case .empty, .unavailable, .deviceRegistration, .authentication, .upstream:
                return String(localized: "ai_song_discovery_failed_generic")
            }
        }
    }
}

/// 维基百科简介的三段请求:MusicBrainz 对上条目并取它的 Wikidata 链接,Wikidata 给出各语言的
/// 条目名,维基百科给摘要。请求地址、匹配和解析都在 `WikipediaInsightPolicy`。
actor WikipediaInsightClient {
    static let shared = WikipediaInsightClient()

    enum LookupError: Error {
        case badResponse
        /// 连不上维基百科或 Wikidata(超时、连接被断开、域名解析不了)。
        case unreachable
    }

    private let session: URLSession
    private var lastMusicBrainzRequest: ContinuousClock.Instant?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": WikipediaInsightPolicy.userAgent]
        session = URLSession(configuration: configuration)
    }

    func draft(for subject: LibraryInsightSubject, languageCode: String) async throws -> LibraryInsightImportedDraft? {
        typealias Policy = WikipediaInsightPolicy
        let entity: String
        let matchedID: String?
        if subject.kind == .album {
            entity = "release-group"
            guard !subject.albumTitle.isEmpty, !subject.artistName.isEmpty,
                  let url = Policy.releaseGroupSearchURL(title: subject.albumTitle, artist: subject.artistName)
            else { return nil }
            let candidates = Policy.releaseGroupCandidates(fromSearch: try await musicBrainz(url))
            matchedID = Policy.uniqueReleaseGroupID(
                title: subject.albumTitle, artist: subject.artistName, in: candidates)
        } else {
            entity = "artist"
            guard !subject.artistName.isEmpty,
                  let url = Policy.artistSearchURL(name: subject.artistName) else { return nil }
            let candidates = Policy.artistCandidates(fromSearch: try await musicBrainz(url))
            matchedID = Policy.uniqueArtistID(name: subject.artistName, in: candidates)
        }
        guard let matchedID, let relationsURL = Policy.relationsURL(entity: entity, id: matchedID),
              let wikidataID = Policy.wikidataID(fromRelations: try await musicBrainz(relationsURL)),
              let sitelinksURL = Policy.sitelinksURL(wikidataID: wikidataID),
              let article = Policy.article(
                fromSitelinks: try await get(sitelinksURL),
                wikidataID: wikidataID, languageCode: languageCode),
              let summaryURL = Policy.summaryURL(for: article) else { return nil }
        var request = URLRequest(url: summaryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let variant = article.variant { request.setValue(variant, forHTTPHeaderField: "Accept-Language") }
        guard let summary = Policy.summary(fromResponse: try await data(for: request, missingIsEmpty: true)) else {
            return nil
        }
        return LibraryInsightImportedDraft(
            summary: summary.text, tags: [], sourceLabel: Policy.sourceLabel, sourceURL: summary.pageURL)
    }

    private static let unreachableCodes: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .networkConnectionLost, .secureConnectionFailed,
    ]

    private static func isWikimediaHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.hasSuffix(".wikipedia.org") || host.hasSuffix(".wikidata.org")
    }

    /// MusicBrainz 的请求排着队走,前后隔开规定的间隔。
    private func musicBrainz(_ url: URL) async throws -> Data {
        if let last = lastMusicBrainzRequest {
            let wait = last + .seconds(WikipediaInsightPolicy.musicBrainzSpacing) - ContinuousClock.now
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        lastMusicBrainzRequest = .now
        return try await get(url)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await data(for: request, missingIsEmpty: false)
    }

    private func data(for request: URLRequest, missingIsEmpty: Bool) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.isWikimediaHost(request.url) && Self.unreachableCodes.contains(error.code) {
            throw LookupError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw LookupError.badResponse }
        if missingIsEmpty, http.statusCode == 404 { return Data() }
        guard (200...299).contains(http.statusCode) else { throw LookupError.badResponse }
        return data
    }
}
