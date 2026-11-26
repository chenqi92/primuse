import Foundation
import PrimuseKit

/// 智能歌单规则引擎: 给定一份 SmartPlaylist 定义和当前 library / 播放历史,
/// 算出匹配的 Song 列表 (按 sortField/sortDirection 排序, 按 limit 截断)。
///
/// 设计选择: 纯 in-memory filter, 不走 GRDB SQL。
/// - `MusicLibrary.visibleSongs` 已经在内存里 (snapshot 加载到数组)
/// - 几千首歌 × 几条规则的 filter / sort 在主线程几十 ms 内完成
/// - 跟 SQL 比省了一层 schema / 类型转换 / 后处理 join 的复杂度
/// - 规则数量上限不再是 SQL OR 拖死的问题, 而是用户可读性问题
///
/// PlayHistoryStore 数据 (playCount / lastPlayedAt) 一次性聚合成字典,
/// 所有规则共用 ── 不每条规则重算一遍。
@MainActor
enum SmartPlaylistEngine {
    /// 匹配结果只由这些输入决定。侧栏右键菜单(建行时就整个构造)、歌单列表卡片的
    /// 歌曲数、详情页每次重画都要问一遍, 原来每问一次都把整库按规则过一遍。读这些
    /// 版本号时登记的观察与直接匹配时读到的一致。
    struct MatchInputs: Equatable {
        let smart: SmartPlaylist
        let visibleSongs: MusicLibrary.VisibleSongsVersion
        let librarySongs: UInt64
        /// 只有「在某个歌单里」的规则读歌单成员; 没有这种规则时为 nil, 点个喜欢不必重算。
        let playlists: MusicLibrary.PlaylistContentVersion?
        let artistNameConfiguration: ArtistNameConfiguration
        let history: ObjectIdentifier
        /// 只有按播放次数 / 最后播放时间筛选或排序时才读播放历史, 否则为 nil。
        let historyVersion: UInt64?
        let includesAppleMusicLibrary: Bool
        /// 有「最近 N 天」这类相对日期规则时按分钟前进, 否则为 nil。
        let minute: Int?
    }

    struct CacheEntry {
        fileprivate let inputs: MatchInputs
        /// 随机排序时存的是筛完、还没洗牌的结果: 每次取用照旧重新洗牌、截断。
        fileprivate let songs: [Song]
    }

    /// AI 歌单返回 nil: 它按身份对回库里的歌, 要用音乐源的账号映射, 那份映射没有
    /// 版本号可挂, 照旧每次现算(它只查自己那几十首, 本来就不贵)。
    static func inputs(
        for smart: SmartPlaylist,
        in library: MusicLibrary,
        history: PlayHistoryStore
    ) -> MatchInputs? {
        guard smart.effectiveKind != .ai else { return nil }
        #if os(tvOS)
        let includesAppleMusicLibrary = true
        #else
        let includesAppleMusicLibrary = AppleMusicFeatureSettings.autoAddToSmartPlaylistsEnabled
        #endif
        let rules = smart.effectiveRuleGroups.flatMap(\.rules)
        let usesRelativeDates = rules.contains { $0.value.hasPrefix("days:") }
        let usesPlaylists = rules.contains { $0.field == .isInPlaylist }
        let usesPlayStats = rules.contains { $0.field == .playCount || $0.field == .lastPlayedAt }
            || smart.sortField == .playCount || smart.sortField == .lastPlayedAt
        return MatchInputs(
            smart: smart,
            visibleSongs: library.visibleSongsVersion,
            librarySongs: library.songMutationGenerationForMaintenance,
            playlists: usesPlaylists ? library.playlistContentVersion : nil,
            artistNameConfiguration: library.artistNameConfiguration,
            history: ObjectIdentifier(history),
            historyVersion: usesPlayStats ? history.playCountsVersion : nil,
            includesAppleMusicLibrary: includesAppleMusicLibrary,
            minute: usesRelativeDates ? Int(Date().timeIntervalSince1970 / 60) : nil
        )
    }

    /// 从 library 当前快照里查出匹配 smart 定义的歌曲列表。
    static func match(
        _ smart: SmartPlaylist,
        in library: MusicLibrary,
        history: PlayHistoryStore
    ) -> [Song] {
        guard let inputs = inputs(for: smart, in: library, history: history) else {
            return computeMatch(smart, in: library, history: history)
        }
        if let entry = library.smartPlaylistMatchCache[smart.id], entry.inputs == inputs {
            return finalized(entry.songs, smart: smart)
        }
        let songs = computeMatch(smart, in: library, history: history)
        if library.smartPlaylistMatchCache.count >= 64 {
            library.smartPlaylistMatchCache.removeAll(keepingCapacity: true)
        }
        library.smartPlaylistMatchCache[smart.id] = CacheEntry(inputs: inputs, songs: songs)
        return finalized(songs, smart: smart)
    }

    /// 随机排序在取用时才洗牌, 与原来每次匹配都重新洗一遍一致。
    private static func finalized(_ songs: [Song], smart: SmartPlaylist) -> [Song] {
        guard smart.sortField == .random else { return songs }
        let safeLimit = max(0, smart.limit ?? Int.max)
        return Array(songs.shuffled().prefix(safeLimit))
    }

    /// macOS 规则编辑器实时预览的只读摘要，在后台线程算出后回填，不污染主缓存。
    struct PreviewSummary: Equatable, Sendable {
        let count: Int
        let totalDuration: TimeInterval
        let sourceCount: Int
        // crash-pattern: allow library-array-property 最多 4 首用于编辑器预览叠放封面
        let previewCovers: [Song]

        static let empty = PreviewSummary(count: 0, totalDuration: 0, sourceCount: 0, previewCovers: [])
    }

    /// 供规则匹配与排序复用的已编译计划，只保存预解析后的规则和按需播放统计。
    struct EvaluationPlan: Sendable {
        fileprivate let activeGroups: [CompiledRuleGroup]
        fileprivate let groupCombinator: SmartPlaylistCombinator
        fileprivate let sortField: SmartPlaylistSortField
        fileprivate let sortDirection: SmartPlaylistSortDirection
        fileprivate let limit: Int?
        fileprivate let artistConfiguration: ArtistNameConfiguration
        fileprivate let stats: PlayStats?
    }

    /// 采集规则编辑器预览所需的候选快照与编译计划，不写入 `library.smartPlaylistMatchCache`。
    static func makePreviewInputs(
        for smart: SmartPlaylist,
        in library: MusicLibrary,
        history: PlayHistoryStore
    ) -> (songs: [Song], plan: EvaluationPlan) {
        (
            candidateSongs(in: library),
            makeEvaluationPlan(for: smart, in: library, history: history)
        )
    }

    /// 在任意线程上按已编译规则算出编辑器实时预览摘要。
    nonisolated static func evaluatePreview(
        songs: [Song],
        plan: EvaluationPlan
    ) -> PreviewSummary {
        let matched = execute(songs, plan: plan, finalizeRandom: true)
        var totalDuration: TimeInterval = 0
        var sourceIDs = Set<String>()
        for song in matched {
            totalDuration += song.duration
            sourceIDs.insert(song.sourceID)
        }
        return PreviewSummary(
            count: matched.count,
            totalDuration: totalDuration,
            sourceCount: sourceIDs.count,
            previewCovers: Array(matched.prefix(4))
        )
    }

    private static func computeMatch(
        _ smart: SmartPlaylist,
        in library: MusicLibrary,
        history: PlayHistoryStore
    ) -> [Song] {
        if smart.effectiveKind == .ai {
            let identities = smart.aiConfiguration?.selections.map(\.identity) ?? []
            return library.visibleSongs(matching: identities)
        }

        let startedAt = Date()
        let songs = candidateSongs(in: library)
        let plan = makeEvaluationPlan(for: smart, in: library, history: history)
        let totalSongs = songs.count

        // 空规则集合: 命中 library 全部 (用户可能新建后还没编辑规则就先看个全量)
        guard !plan.activeGroups.isEmpty else {
            let result = sortAndLimit(songs, plan: plan, finalizeRandom: false)
            let elapsed = Date().timeIntervalSince(startedAt)
            plog(String(format: "🎯 SmartPlaylist '%@' match: 0 rules → matched=%d/%d in %.0fms",
                        smart.name, result.count, totalSongs, elapsed * 1000))
            return result
        }

        let matched = filterSongs(songs, plan: plan)
        let result = sortAndLimit(matched, plan: plan, finalizeRandom: false)
        let elapsed = Date().timeIntervalSince(startedAt)
        let ruleCount = plan.activeGroups.reduce(0) { $0 + $1.rules.count }
        plog(String(format: "🎯 SmartPlaylist '%@' match: groups=%d rules=%d sortBy=%@ limit=%@ → matched=%d/%d (truncated to %d) in %.0fms",
                    smart.name,
                    plan.activeGroups.count,
                    ruleCount,
                    smart.sortField.rawValue,
                    smart.limit.map(String.init) ?? "none",
                    matched.count, totalSongs, result.count,
                    elapsed * 1000))
        return result
    }

    private static func makeEvaluationPlan(
        for smart: SmartPlaylist,
        in library: MusicLibrary,
        history: PlayHistoryStore
    ) -> EvaluationPlan {
        let now = Date()
        let calendar = Calendar.current
        // 空组 (无规则) 不参与组合 —— 在循环前一次性剔除并预编译所有规则值，避免逐首重复解析日期与分配格式化器。
        let activeGroups = smart.effectiveRuleGroups.compactMap { group -> CompiledRuleGroup? in
            guard !group.rules.isEmpty else { return nil }
            let compiledRules = group.rules.map { compile($0, in: library, now: now, calendar: calendar) }
            return CompiledRuleGroup(
                rules: compiledRules,
                combinator: group.combinator,
                isExcluded: group.isExcluded
            )
        }
        let usesPlayStats = smart.sortField == .playCount
            || smart.sortField == .lastPlayedAt
            || activeGroups.contains { group in
                group.rules.contains { $0.field == .playCount || $0.field == .lastPlayedAt }
            }
        let stats = usesPlayStats ? PlayStats(history: history) : nil
        return EvaluationPlan(
            activeGroups: activeGroups,
            groupCombinator: smart.effectiveGroupCombinator,
            sortField: smart.sortField,
            sortDirection: smart.sortDirection,
            limit: smart.limit,
            artistConfiguration: library.artistNameConfiguration,
            stats: stats
        )
    }

    nonisolated private static func execute(
        _ songs: [Song],
        plan: EvaluationPlan,
        finalizeRandom: Bool
    ) -> [Song] {
        let matched = plan.activeGroups.isEmpty ? songs : filterSongs(songs, plan: plan)
        return sortAndLimit(matched, plan: plan, finalizeRandom: finalizeRandom)
    }

    nonisolated private static func filterSongs(_ songs: [Song], plan: EvaluationPlan) -> [Song] {
        songs.filter { song in
            evaluate(
                groups: plan.activeGroups,
                groupCombinator: plan.groupCombinator,
                song: song,
                stats: plan.stats,
                artistConfiguration: plan.artistConfiguration
            )
        }
    }

    // MARK: - Streaming evaluation (catalog)

    /// 流式匹配时一首命中的歌只留 id 与排序要比的那几项(同 `sortAndLimit` 各排序方式)。
    private struct MatchedSongKey: Sendable {
        let id: String
        var text = ""
        var albumID = ""
        var disc = 0
        var track = 0
        var title = ""
        var number = 0.0
    }

    nonisolated private static func matchedKey(for song: Song, plan: EvaluationPlan) -> MatchedSongKey {
        var key = MatchedSongKey(id: song.id)
        switch plan.sortField {
        case .title:
            key.text = song.title
        case .artistName:
            key.text = song.displayArtistName(configuration: plan.artistConfiguration) ?? ""
        case .albumTitle:
            key.text = song.albumTitle ?? ""
            key.albumID = song.albumID ?? ""
            key.disc = AlbumTrackOrder.discNumber(for: song)
            key.track = AlbumTrackOrder.trackNumber(for: song) ?? Int.max
            key.title = song.title
        case .dateAdded:
            key.number = song.dateAdded.timeIntervalSinceReferenceDate
        case .duration:
            key.number = song.duration
        case .lastPlayedAt:
            key.number = (plan.stats?.lastPlayedBySongID[song.id] ?? .distantPast).timeIntervalSinceReferenceDate
        case .playCount:
            key.number = Double(plan.stats?.countBySongID[song.id] ?? 0)
        case .random:
            break
        }
        return key
    }

    /// 同 `execute(_:plan:finalizeRandom: false)` 的 id,歌由 `forEachSong` 按库内顺序逐首给出
    /// (可见歌曲),只留命中那些的 id 与排序值,不留整份歌曲。比较规则与内存匹配逐项相同,
    /// 同样的输入顺序得到同样的结果。随机排序不洗牌也不截断(取用时做,同 `finalized`)。
    /// `excludedSourceID`:不算进来的源(没开「自动加进智能歌单」时的 Apple Music 资料库)。
    nonisolated static func matchedSongIDs(
        plan: EvaluationPlan,
        excludedSourceID: String?,
        forEachSong: (_ body: (Song) throws -> Void) throws -> Void
    ) throws -> [String] {
        var matched: [MatchedSongKey] = []
        try forEachSong { song in
            if let excludedSourceID, song.sourceID == excludedSourceID { return }
            guard plan.activeGroups.isEmpty || evaluate(
                groups: plan.activeGroups,
                groupCombinator: plan.groupCombinator,
                song: song,
                stats: plan.stats,
                artistConfiguration: plan.artistConfiguration
            ) else { return }
            matched.append(matchedKey(for: song, plan: plan))
        }
        let sorted: [MatchedSongKey]
        switch plan.sortField {
        case .title, .artistName:
            sorted = matched.sorted { $0.text < $1.text }
        case .albumTitle:
            // 同 `sortAndLimit`:专辑名、专辑 id,再按 `AlbumTrackOrder.isOrderedBefore`(碟号、曲号、歌名、id)。
            sorted = matched.sorted { lhs, rhs in
                if lhs.text != rhs.text { return lhs.text < rhs.text }
                if lhs.albumID != rhs.albumID { return lhs.albumID < rhs.albumID }
                if lhs.disc != rhs.disc { return lhs.disc < rhs.disc }
                if lhs.track != rhs.track { return lhs.track < rhs.track }
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
        case .dateAdded, .duration, .lastPlayedAt, .playCount:
            sorted = matched.sorted { $0.number < $1.number }
        case .random:
            return matched.map(\.id)
        }
        let directional = plan.sortDirection == .descending ? Array(sorted.reversed()) : sorted
        return directional.prefix(max(0, plan.limit ?? Int.max)).map(\.id)
    }

    /// 智能歌单命中的歌的 id(排好序、截断;随机排序时每次重新洗牌、截断)。
    ///
    /// 曲库目录可读时在主线程外流式匹配目录里的可见歌曲,结果与内存匹配相同(目录跟写内存有一小段
    /// 滞后,刚改的歌下一次才算进来,同 P2 的列表);按目录修订号与规则输入缓存。AI 歌单(按身份对回
    /// 几十首)、目录读不了或读失败时照旧在内存里匹配。
    static func matchedSongIDs(
        _ smart: SmartPlaylist,
        in library: MusicLibrary,
        history: PlayHistoryStore
    ) async -> [String] {
        guard smart.effectiveKind != .ai,
              let memoryInputs = inputs(for: smart, in: library, history: history),
              let host = library.catalogHost, host.revisions.isReadable else {
            return match(smart, in: library, history: history).map(\.id)
        }
        let key = CatalogMatchKey(inputs: memoryInputs, revisions: host.revisions)
        if let entry = library.smartPlaylistCatalogMatchCache[smart.id], entry.key == key {
            return finalized(ids: entry.ids, smart: smart)
        }
        let plan = makeEvaluationPlan(for: smart, in: library, history: history)
        // 同 `candidateSongs`:没开「自动加进智能歌单」时不算 Apple Music 资料库的歌(电视上总算)。
        let excludedSourceID = memoryInputs.includesAppleMusicLibrary ? nil : AppleMusicLibraryIdentity.sourceID
        let ids: [String]
        do {
            ids = try await host.reader.read { catalog in
                try matchedSongIDs(plan: plan, excludedSourceID: excludedSourceID) { body in
                    try catalog.forEachSong(.visible) { _, song in
                        try body(song)
                        return true
                    }
                }
            }
        } catch {
            plog("🎯 SmartPlaylist '\(smart.name)' catalog match failed (\(error)); using the in-memory library")
            return match(smart, in: library, history: history).map(\.id)
        }
        // 很大的结果不留(整库那种规则):下次重新流式扫一遍,不常驻一整份 id。
        if ids.count <= Self.catalogMatchCacheLimit {
            if library.smartPlaylistCatalogMatchCache.count >= 16 {
                library.smartPlaylistCatalogMatchCache.removeAll(keepingCapacity: true)
            }
            library.smartPlaylistCatalogMatchCache[smart.id] = CatalogCacheEntry(key: key, ids: ids)
        }
        return finalized(ids: ids, smart: smart)
    }

    static let catalogMatchCacheLimit = 20_000

    /// 目录匹配结果的缓存键:规则输入(不含内存模型的版本号)加目录修订号。
    struct CatalogMatchKey: Equatable {
        let smart: SmartPlaylist
        let playlists: MusicLibrary.PlaylistContentVersion?
        let artistNameConfiguration: ArtistNameConfiguration
        let history: ObjectIdentifier
        let historyVersion: UInt64?
        let includesAppleMusicLibrary: Bool
        let minute: Int?
        let catalogRevision: Int64
        let everything: UInt64

        @MainActor
        init(inputs: MatchInputs, revisions: LibraryCatalogRevisions) {
            smart = inputs.smart
            playlists = inputs.playlists
            artistNameConfiguration = inputs.artistNameConfiguration
            history = inputs.history
            historyVersion = inputs.historyVersion
            includesAppleMusicLibrary = inputs.includesAppleMusicLibrary
            minute = inputs.minute
            catalogRevision = revisions.catalogRevision
            everything = revisions.everything
        }
    }

    struct CatalogCacheEntry {
        fileprivate let key: CatalogMatchKey
        /// 随机排序时存的是没洗牌、没截断的结果。
        // crash-pattern: allow song-id-collection-property 只缓存不超过 catalogMatchCacheLimit 首的结果
        fileprivate let ids: [String]
    }

    private static func finalized(ids: [String], smart: SmartPlaylist) -> [String] {
        guard smart.sortField == .random else { return ids }
        return Array(ids.shuffled().prefix(max(0, smart.limit ?? Int.max)))
    }

    private static func candidateSongs(in library: MusicLibrary) -> [Song] {
        #if os(tvOS)
        return library.visibleSongs
        #else
        guard !AppleMusicFeatureSettings.autoAddToSmartPlaylistsEnabled else {
            return library.visibleSongs
        }
        return library.visibleSongs.filter { $0.sourceID != AppleMusicLibraryService.systemSourceID }
        #endif
    }

    // MARK: - Rule compilation & evaluation

    private static func compile(
        _ rule: SmartPlaylistRule,
        in library: MusicLibrary,
        now: Date,
        calendar: Calendar
    ) -> CompiledRule {
        let matcher: CompiledMatcher
        switch rule.field {
        case .title, .artistName, .albumTitle, .genre, .fileFormat, .sourceID:
            matcher = .string(rule.value.lowercased())
        case .year, .fileSize, .bitRate, .playCount:
            if rule.op == .between {
                let parts = rule.value.split(separator: "|")
                if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]) {
                    matcher = .intRange(lo, hi)
                } else {
                    matcher = .never
                }
            } else if let target = Int(rule.value) {
                matcher = .intValue(target)
            } else {
                matcher = .never
            }
        case .durationSec:
            if rule.op == .between {
                let parts = rule.value.split(separator: "|")
                if parts.count == 2, let lo = Double(parts[0]), let hi = Double(parts[1]) {
                    matcher = .doubleRange(lo, hi)
                } else {
                    matcher = .never
                }
            } else if let target = Double(rule.value) {
                matcher = .doubleValue(target)
            } else {
                matcher = .never
            }
        case .dateAdded, .lastPlayedAt:
            matcher = .date(compileDateMatcher(value: rule.value, op: rule.op, now: now, calendar: calendar))
        case .isInPlaylist:
            if rule.op == .equals || rule.op == .notEquals {
                let members = Set(library.songIDs(forPlaylist: rule.value))
                    .subtracting(library.locallyRemovedMirrorSongs(in: rule.value))
                matcher = .playlistMembers(members)
            } else {
                matcher = .never
            }
        }
        return CompiledRule(field: rule.field, op: rule.op, matcher: matcher)
    }

    private static func compileDateMatcher(
        value: String,
        op: SmartPlaylistOperator,
        now: Date,
        calendar: Calendar
    ) -> CompiledDateMatcher {
        if value.hasPrefix("days:"),
           let threshold = parseDate(value, now: now, calendar: calendar) {
            switch op {
            case .equals, .greaterThan:
                return .atOrAfter(threshold)
            case .notEquals, .lessThan:
                return .before(threshold)
            default:
                return .never
            }
        }

        switch op {
        case .equals:
            guard let target = parseDate(value, now: now, calendar: calendar),
                  let dayInterval = calendar.dateInterval(of: .day, for: target) else { return .never }
            return .inDay(dayInterval.start, dayInterval.end)
        case .notEquals:
            guard let target = parseDate(value, now: now, calendar: calendar),
                  let dayInterval = calendar.dateInterval(of: .day, for: target) else { return .never }
            return .notInDay(dayInterval.start, dayInterval.end)
        case .greaterThan:
            guard let target = parseDate(value, now: now, calendar: calendar) else { return .never }
            return .after(target)
        case .lessThan:
            guard let target = parseDate(value, now: now, calendar: calendar) else { return .never }
            return .before(target)
        case .between:
            let parts = value.split(separator: "|")
            guard parts.count == 2,
                  let lo = parseDate(String(parts[0]), now: now, calendar: calendar),
                  let hi = parseDate(String(parts[1]), now: now, calendar: calendar) else { return .never }
            return .between(lo, hi)
        default:
            return .never
        }
    }

    nonisolated private static func evaluate(
        groups: [CompiledRuleGroup],
        groupCombinator: SmartPlaylistCombinator,
        song: Song,
        stats: PlayStats?,
        artistConfiguration: ArtistNameConfiguration
    ) -> Bool {
        let matches: (CompiledRuleGroup) -> Bool = { group in
            let matched = evaluate(
                rules: group.rules,
                combinator: group.combinator,
                song: song,
                stats: stats,
                artistConfiguration: artistConfiguration
            )
            return group.isExcluded ? !matched : matched
        }

        switch groupCombinator {
        case .and:
            return groups.allSatisfy(matches)
        case .or:
            return groups.contains(where: matches)
        }
    }

    nonisolated private static func evaluate(
        rules: [CompiledRule],
        combinator: SmartPlaylistCombinator,
        song: Song,
        stats: PlayStats?,
        artistConfiguration: ArtistNameConfiguration
    ) -> Bool {
        switch combinator {
        case .and:
            return rules.allSatisfy {
                evaluate($0, song: song, stats: stats, artistConfiguration: artistConfiguration)
            }
        case .or:
            return rules.contains {
                evaluate($0, song: song, stats: stats, artistConfiguration: artistConfiguration)
            }
        }
    }

    nonisolated private static func evaluate(
        _ rule: CompiledRule,
        song: Song,
        stats: PlayStats?,
        artistConfiguration: ArtistNameConfiguration
    ) -> Bool {
        switch rule.field {
        case .title:
            return compareString(song.title, rule)
        case .artistName:
            return compareStrings(
                MusicLibrary.resolvedArtistNames(for: song, configuration: artistConfiguration),
                rule
            )
        case .albumTitle:
            return compareString(song.albumTitle ?? "", rule)
        case .genre:
            return compareStrings(GenreTagValues.browseNames(for: song), rule)
        case .fileFormat:
            // M4A 里的 ALAC 既算 M4A，也算 ALAC。
            let codec = song.codecFormat
            return compareStrings(
                codec == song.fileFormat ? [codec.rawValue] : [song.fileFormat.rawValue, codec.rawValue],
                rule
            )
        case .sourceID:
            return compareString(song.sourceID, rule)
        case .year:
            return compareInt(song.year, rule)
        case .fileSize:
            return compareInt(Int(song.fileSize), rule)
        case .bitRate:
            return compareInt(song.bitRate, rule)
        case .durationSec:
            return compareDouble(song.duration, rule)
        case .dateAdded:
            return compareDate(song.dateAdded, rule)
        case .playCount:
            let count = stats?.countBySongID[song.id] ?? 0
            return compareInt(count, rule)
        case .lastPlayedAt:
            return compareDate(stats?.lastPlayedBySongID[song.id], rule)
        case .isInPlaylist:
            guard case .playlistMembers(let members) = rule.matcher else { return false }
            let inSet = members.contains(song.id)
            switch rule.op {
            case .equals: return inSet
            case .notEquals: return !inSet
            default: return false
            }
        }
    }

    // MARK: - Comparators

    nonisolated private static func compareString(_ value: String, _ rule: CompiledRule) -> Bool {
        guard case .string(let target) = rule.matcher else { return false }
        // 大小写不敏感, 配合用户随手输入。
        let v = value.lowercased()
        switch rule.op {
        case .equals: return v == target
        case .notEquals: return v != target
        case .contains: return v.contains(target)
        case .notContains: return !v.contains(target)
        default: return false
        }
    }

    nonisolated private static func compareStrings(_ values: [String], _ rule: CompiledRule) -> Bool {
        let values = values.isEmpty ? [""] : values
        switch rule.op {
        case .notEquals, .notContains:
            return values.allSatisfy { compareString($0, rule) }
        default:
            return values.contains { compareString($0, rule) }
        }
    }

    nonisolated private static func compareInt(_ value: Int?, _ rule: CompiledRule) -> Bool {
        let v = value ?? 0
        switch (rule.op, rule.matcher) {
        case (.equals, .intValue(let target)):
            return target == v
        case (.notEquals, .intValue(let target)):
            return target != v
        case (.greaterThan, .intValue(let target)):
            return v > target
        case (.lessThan, .intValue(let target)):
            return v < target
        case (.between, .intRange(let lo, let hi)):
            return v >= lo && v <= hi
        default:
            return false
        }
    }

    nonisolated private static func compareDouble(_ value: Double, _ rule: CompiledRule) -> Bool {
        switch (rule.op, rule.matcher) {
        case (.equals, .doubleValue(let target)):
            return abs(target - value) < 0.0001
        case (.notEquals, .doubleValue(let target)):
            return abs(target - value) >= 0.0001
        case (.greaterThan, .doubleValue(let target)):
            return value > target
        case (.lessThan, .doubleValue(let target)):
            return value < target
        case (.between, .doubleRange(let lo, let hi)):
            return value >= lo && value <= hi
        default:
            return false
        }
    }

    nonisolated private static func compareDate(_ value: Date?, _ rule: CompiledRule) -> Bool {
        guard let value, case .date(let matcher) = rule.matcher else { return false }
        switch matcher {
        case .atOrAfter(let threshold):
            return value.timeIntervalSinceReferenceDate >= threshold.timeIntervalSinceReferenceDate
        case .after(let threshold):
            return value > threshold
        case .before(let threshold):
            return value < threshold
        case .inDay(let start, let end):
            return value >= start && value < end
        case .notInDay(let start, let end):
            return value < start || value >= end
        case .between(let lo, let hi):
            return value.timeIntervalSinceReferenceDate >= lo.timeIntervalSinceReferenceDate
                && value.timeIntervalSinceReferenceDate <= hi.timeIntervalSinceReferenceDate
        case .never:
            return false
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainISOFormatter: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private static func parseDate(_ text: String, now: Date, calendar: Calendar) -> Date? {
        if text.hasPrefix("days:"),
           let days = Int(text.dropFirst("days:".count)),
           days >= 0 {
            return calendar.date(byAdding: .day, value: -days, to: now)
        }
        if let d = isoFormatter.date(from: text) { return d }
        return plainISOFormatter.date(from: text)
    }

    // MARK: - Sort + Limit

    nonisolated private static func sortAndLimit(
        _ songs: [Song],
        plan: EvaluationPlan,
        finalizeRandom: Bool
    ) -> [Song] {
        let safeLimit = max(0, plan.limit ?? Int.max)
        let sorted: [Song]
        switch plan.sortField {
        case .title:
            sorted = songs.sorted { ($0.title) < ($1.title) }
        case .artistName:
            let artistConfiguration = plan.artistConfiguration
            sorted = songs.sorted {
                ($0.displayArtistName(configuration: artistConfiguration) ?? "")
                    < ($1.displayArtistName(configuration: artistConfiguration) ?? "")
            }
        case .albumTitle:
            sorted = songs.sorted { lhs, rhs in
                let lhsTitle = lhs.albumTitle ?? ""
                let rhsTitle = rhs.albumTitle ?? ""
                if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
                let lhsAlbum = lhs.albumID ?? ""
                let rhsAlbum = rhs.albumID ?? ""
                if lhsAlbum != rhsAlbum { return lhsAlbum < rhsAlbum }
                return AlbumTrackOrder.isOrderedBefore(lhs, rhs)
            }
        case .dateAdded:
            sorted = songs.sorted { $0.dateAdded < $1.dateAdded }
        case .duration:
            sorted = songs.sorted { $0.duration < $1.duration }
        case .lastPlayedAt:
            let lookup = plan.stats?.lastPlayedBySongID ?? [:]
            sorted = songs.sorted { (lookup[$0.id] ?? .distantPast) < (lookup[$1.id] ?? .distantPast) }
        case .playCount:
            let lookup = plan.stats?.countBySongID ?? [:]
            sorted = songs.sorted { (lookup[$0.id] ?? 0) < (lookup[$1.id] ?? 0) }
        case .random:
            // random 模式忽略 direction (用户既然要随机就别再纠结升降序)。
            // 缓存模式下洗牌与截断留到取用时做(见 `finalized`), 预览模式下直接按上限截断。
            if finalizeRandom {
                return Array(songs.shuffled().prefix(safeLimit))
            }
            return songs
        }

        let directional = plan.sortDirection == .descending ? Array(sorted.reversed()) : sorted
        if directional.count > safeLimit {
            return Array(directional.prefix(safeLimit))
        }
        return directional
    }
}

private struct CompiledRuleGroup: Sendable {
    let rules: [CompiledRule]
    let combinator: SmartPlaylistCombinator
    let isExcluded: Bool
}

private struct CompiledRule: Sendable {
    let field: SmartPlaylistField
    let op: SmartPlaylistOperator
    let matcher: CompiledMatcher
}

private enum CompiledMatcher: Sendable {
    case string(String)
    case intValue(Int)
    case intRange(Int, Int)
    case doubleValue(Double)
    case doubleRange(Double, Double)
    case date(CompiledDateMatcher)
    case playlistMembers(Set<String>)
    case never
}

private enum CompiledDateMatcher: Sendable {
    case atOrAfter(Date)
    case after(Date)
    case before(Date)
    case inDay(Date, Date)
    case notInDay(Date, Date)
    case between(Date, Date)
    case never
}

// MARK: - Aggregated stats

/// 一次性把 PlayHistoryStore.entries 聚合成两个字典, 给规则评估和排序复用。
/// O(n) 一次扫描, library 几千首歌 / history 几千条都 ok。
private struct PlayStats: Sendable {
    let countBySongID: [String: Int]
    let lastPlayedBySongID: [String: Date]

    @MainActor
    init(history: PlayHistoryStore) {
        var count: [String: Int] = [:]
        var last: [String: Date] = [:]
        for entry in history.entries {
            count[entry.songID, default: 0] += 1
            if let prev = last[entry.songID] {
                if entry.playedAt > prev { last[entry.songID] = entry.playedAt }
            } else {
                last[entry.songID] = entry.playedAt
            }
        }
        self.countBySongID = count
        self.lastPlayedBySongID = last
    }
}
