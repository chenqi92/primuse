import Foundation

// 刮削结果按部分（封面、歌词、标签）结算。一首歌「已更新」只看这三部分有没有真的补上并落了地；
// 时长、码率这些技术参数照常静默保存，但不算更新。写回音乐源另记一本账。

/// 一首歌的封面、歌词或标签这一部分在这一轮里的结局。
public enum ScrapePartOutcome: String, Codable, Sendable, CaseIterable {
    /// 补上了：新内容写进了本机缓存（标签写进了资料库）并且核对过。
    case filled
    /// 本来就有，这一轮没去刮。
    case alreadyPresent
    /// 去刮了，在线源没有结果（或结果和现有的一样）。
    case notFound
    /// 刮到了，但没能存下：本机缓存写失败、存下的图读不回来、歌词没有有效行或缓存拒收。
    case saveFailed
    /// 这一轮不管这部分：只补歌词时的封面、字段规则设成跳过的、服务端曲库的封面和歌词。
    case notRequested
}

public enum ScrapePartJudgment {
    /// - Parameters:
    ///   - considered: 这一部分在这一轮的范围里（选了这部分、字段规则不是跳过）。
    ///   - fetched: 这一部分进了这首歌的请求（本来没有，或者要覆盖）。
    ///   - received: 在线源给了结果。
    ///   - stored: 结果落了地并核对过。
    public static func outcome(considered: Bool, fetched: Bool, received: Bool, stored: Bool) -> ScrapePartOutcome {
        guard considered else { return .notRequested }
        guard fetched else { return .alreadyPresent }
        guard received else { return .notFound }
        return stored ? .filled : .saveFailed
    }
}

public enum ScrapedLyricsValidity {
    /// 刮到的歌词里有没有能显示的行（正文去掉空白后不空）。只有时间轴、空行或文件头的不算。
    public static func hasUsableLines(_ lines: [LyricLine]?) -> Bool {
        guard let lines else { return false }
        return lines.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public enum ScrapeTagChange {
    /// 看得见的标签里哪些变了。时长、码率、采样率、位深、MV 路径不算。
    public static func changedFields(from original: Song, to updated: Song) -> Set<ScrapeField> {
        let old = original.scrapeFields
        let new = updated.scrapeFields
        return ScrapeField.tags.filter { $0.changed(from: old, to: new) }
    }
}

/// 一首歌这一轮的总结局。
public enum ScrapeSongResult: String, Codable, Sendable {
    /// 至少一部分补上了，并且没有哪部分存失败。
    case updated
    /// 什么都没补上，也没有失败（只改了技术参数的歌也算这里）。
    case unchanged
    /// 有一部分刮到了却没存下，或者整首出错：不能算进成功数里悄悄过去。
    case failed
}

public struct ScrapeSongParts: Equatable, Sendable {
    public var cover: ScrapePartOutcome
    public var lyrics: ScrapePartOutcome
    public var tags: ScrapePartOutcome

    public init(cover: ScrapePartOutcome, lyrics: ScrapePartOutcome, tags: ScrapePartOutcome) {
        self.cover = cover
        self.lyrics = lyrics
        self.tags = tags
    }

    public var result: ScrapeSongResult {
        let all = [cover, lyrics, tags]
        if all.contains(.saveFailed) { return .failed }
        if all.contains(.filled) { return .updated }
        return .unchanged
    }
}

// MARK: - 封面、歌词引用还在不在

/// 歌曲记着的封面或歌词引用核对下来的状态。
public enum ScrapeAssetReferenceState: String, Codable, Sendable {
    /// 没有引用，本机也没有按歌曲存的那份。
    case absent
    /// 有，而且（能核对的）都还在。
    case present
    /// 引用指着本机缓存，文件已经没了（卸载重装、缓存被清、当初没存成留下的引用）。
    case staleLocal
    /// 引用指着音乐源上的旁路文件，「已知缺失」的记录说它不在了。
    case staleSource

    /// 刮不到时要把失效的本机引用清掉，免得界面一直是默认封面、又永远不再补。
    public var clearsReferenceWhenMissed: Bool { self == .staleLocal }
}

public struct ScrapeAssetPresence: Equatable, Sendable {
    public var cover: ScrapeAssetReferenceState
    public var lyrics: ScrapeAssetReferenceState

    public init(cover: ScrapeAssetReferenceState, lyrics: ScrapeAssetReferenceState) {
        self.cover = cover
        self.lyrics = lyrics
    }

    /// 后台补全只补空着的：失效的引用照旧当成有，不去白刮一张存不进去的图。
    public var treatingStaleAsPresent: ScrapeAssetPresence {
        ScrapeAssetPresence(cover: cover == .absent ? .absent : .present,
                            lyrics: lyrics == .absent ? .absent : .present)
    }

    /// 只看引用空不空，不查文件。
    public static func referencesOnly(cover: String?, lyrics: String?) -> ScrapeAssetPresence {
        ScrapeAssetPresence(cover: cover?.isEmpty == false ? .present : .absent,
                            lyrics: lyrics?.isEmpty == false ? .present : .absent)
    }
}

public enum ScrapeAssetPresencePolicy {
    /// 封面：本机缓存的引用要读得到；音乐源上的路径、服务端的封面 ID 不做网络探测，按有处理。
    /// 被容量清理掉内容、留着「已清理」标记的封面也算有：它靠按需从音乐源恢复，不是丢了。
    /// 没有引用时看按歌曲存的那份（和播放页读封面的顺序一致）。参数按需求值，只多一次本机文件判断。
    public static func coverState(
        reference: String?,
        isLocalCacheName: Bool,
        referenceReadable: @autoclosure () -> Bool,
        contentEvicted: @autoclosure () -> Bool,
        songCacheReadable: @autoclosure () -> Bool
    ) -> ScrapeAssetReferenceState {
        guard let reference, !reference.isEmpty else {
            return songCacheReadable() ? .present : .absent
        }
        guard isLocalCacheName else { return .present }
        if referenceReadable() || contentEvicted() { return .present }
        return .staleLocal
    }

    /// 歌词：播放先读按歌曲存的缓存，它在就算有。引用指着本机缓存时查文件；指着音乐源上的
    /// 歌词文件（路径里带 `/`）时不做网络探测，除非已知缺失的记录说它不在。
    public static func lyricsState(
        reference: String?,
        isLocalCacheName: Bool,
        songCacheExists: @autoclosure () -> Bool,
        referenceExists: @autoclosure () -> Bool,
        sourceConfirmedAbsent: @autoclosure () -> Bool
    ) -> ScrapeAssetReferenceState {
        if songCacheExists() { return .present }
        guard let reference, !reference.isEmpty else { return .absent }
        if isLocalCacheName { return referenceExists() ? .present : .staleLocal }
        if reference.contains("/") { return sourceConfirmedAbsent() ? .staleSource : .present }
        return .present
    }

    /// 本机歌词缓存自己起的文件名：32 位小写十六进制加 `.json`。
    public static func isLocalLyricsCacheName(_ reference: String) -> Bool {
        guard reference.hasSuffix(".json") else { return false }
        let stem = reference.utf8.dropLast(5)
        return stem.count == 32 && stem.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

// MARK: - 写回音乐源

/// 写回音乐源失败的原因分类。
public enum ScrapeWritebackFailureReason: String, Codable, Sendable, CaseIterable {
    /// 音乐源只读、没有写入权限、登录失效或连不上。
    case unavailable
    /// 音频文件在别处被改过，没有覆盖。
    case conflict
    /// 等音乐源回应超时。
    case timeout
    /// 刮削被打断（离开前台、后台时间用完、点了停止），这首还没写完。
    case interrupted
    case other
}

public enum ScrapeWritebackOutcome: Equatable, Sendable {
    /// 这首歌没有要写回的（开关关着、源不能写、什么都没补上）。
    case notAttempted
    case written
    case failed(ScrapeWritebackFailureReason)

    /// 同一首歌好几处写回（嵌入、歌词文件、封面文件、媒体服务器）合成一个结局：有一处失败就算失败，
    /// 原因取先出现的那个。
    public func combined(with other: ScrapeWritebackOutcome) -> ScrapeWritebackOutcome {
        switch (self, other) {
        case (.failed, _): return self
        case (_, .failed): return other
        case (.written, _), (_, .written): return .written
        default: return .notAttempted
        }
    }
}

/// 刮到的封面、歌词要不要写回音乐源。
public enum ScrapeWritebackSourcePolicy {
    /// 歌词本来就是从这个文件里（内嵌）或旁边的歌词文件读出来的，只进本机缓存：再写回去只会把
    /// 逐字时间轴、多语言内嵌歌词有损地合成一份，还把同一份内容又写成歌词文件。
    public static func writesBackLyrics(sourceKind: LyricsDocumentSource.Kind?) -> Bool {
        sourceKind != .embedded && sourceKind != .file
    }

    /// 封面同理：从文件里内嵌的图或旁边的封面图读出来的，不再写回。
    public static func writesBackCover(readFromFile: Bool) -> Bool {
        !readFromFile
    }
}

/// 等这一轮写回结束的兜底：嵌入要整首下载、改写、上传、回读，网盘上一首大文件就可能好几分钟，
/// 所以按这一轮里实际最慢的一首放宽，连续这么久一首都没写完才不再等。
public enum ScrapeWritebackWaitPolicy {
    public static func stallLimit(sidecarTimeout: Double, longestObservedWrite: Double) -> Double {
        max(180, sidecarTimeout * 4, longestObservedWrite * 3)
    }
}

// MARK: - 整批的账

/// 失败清单里的一行：哪首歌、哪一部分、为什么。
public struct BatchScrapeFailureEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Part: String, Codable, Sendable {
        case cover, lyrics, song, writeback
    }

    public var songID: String
    public var title: String
    public var part: Part
    public var reason: ScrapeWritebackFailureReason?
    /// 给人看的原因原文（音乐源报的错）。可能为空。
    public var detail: String?

    public var id: String { songID + "\u{1F}" + part.rawValue }

    public init(songID: String, title: String, part: Part,
                reason: ScrapeWritebackFailureReason? = nil, detail: String? = nil) {
        self.songID = songID
        self.title = title
        self.part = part
        self.reason = reason
        self.detail = detail
    }
}

public struct BatchScrapePartCounts: Codable, Equatable, Sendable {
    public var filled = 0
    public var alreadyPresent = 0
    public var notFound = 0
    public var saveFailed = 0

    public init(filled: Int = 0, alreadyPresent: Int = 0, notFound: Int = 0, saveFailed: Int = 0) {
        self.filled = filled
        self.alreadyPresent = alreadyPresent
        self.notFound = notFound
        self.saveFailed = saveFailed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filled = try container.decodeIfPresent(Int.self, forKey: .filled) ?? 0
        alreadyPresent = try container.decodeIfPresent(Int.self, forKey: .alreadyPresent) ?? 0
        notFound = try container.decodeIfPresent(Int.self, forKey: .notFound) ?? 0
        saveFailed = try container.decodeIfPresent(Int.self, forKey: .saveFailed) ?? 0
    }

    public mutating func record(_ outcome: ScrapePartOutcome) {
        switch outcome {
        case .filled: filled += 1
        case .alreadyPresent: alreadyPresent += 1
        case .notFound: notFound += 1
        case .saveFailed: saveFailed += 1
        case .notRequested: break
        }
    }
}

/// 一轮批量刮削的分项计数。随断点一起存，所有字段解码时可缺省，老断点照常读。
public struct BatchScrapeTally: Codable, Equatable, Sendable {
    /// 失败清单最多留这么多行，整库刮削也不会把断点撑大。
    public static let maximumFailureEntries = 200

    public var cover = BatchScrapePartCounts()
    public var lyrics = BatchScrapePartCounts()
    public var tags = BatchScrapePartCounts()
    public var writebackWritten = 0
    public var writebackFailedUnavailable = 0
    public var writebackFailedConflict = 0
    public var writebackFailedTimeout = 0
    public var writebackFailedInterrupted = 0
    public var writebackFailedOther = 0
    /// 整首出错（不是哪一部分没存下，是这首歌刮的时候就出错了）的首数。
    public var songErrors = 0
    public var failures: [BatchScrapeFailureEntry] = []
    /// 失败清单装满之后没记下的行数。
    public var omittedFailureCount = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cover = try container.decodeIfPresent(BatchScrapePartCounts.self, forKey: .cover) ?? .init()
        lyrics = try container.decodeIfPresent(BatchScrapePartCounts.self, forKey: .lyrics) ?? .init()
        tags = try container.decodeIfPresent(BatchScrapePartCounts.self, forKey: .tags) ?? .init()
        writebackWritten = try container.decodeIfPresent(Int.self, forKey: .writebackWritten) ?? 0
        writebackFailedUnavailable = try container.decodeIfPresent(Int.self, forKey: .writebackFailedUnavailable) ?? 0
        writebackFailedConflict = try container.decodeIfPresent(Int.self, forKey: .writebackFailedConflict) ?? 0
        writebackFailedTimeout = try container.decodeIfPresent(Int.self, forKey: .writebackFailedTimeout) ?? 0
        writebackFailedInterrupted = try container.decodeIfPresent(Int.self, forKey: .writebackFailedInterrupted) ?? 0
        writebackFailedOther = try container.decodeIfPresent(Int.self, forKey: .writebackFailedOther) ?? 0
        songErrors = try container.decodeIfPresent(Int.self, forKey: .songErrors) ?? 0
        failures = try container.decodeIfPresent([BatchScrapeFailureEntry].self, forKey: .failures) ?? []
        omittedFailureCount = try container.decodeIfPresent(Int.self, forKey: .omittedFailureCount) ?? 0
    }

    public var writebackFailed: Int {
        writebackFailedUnavailable + writebackFailedConflict + writebackFailedTimeout
            + writebackFailedInterrupted + writebackFailedOther
    }

    public var hasFailures: Bool { !failures.isEmpty || omittedFailureCount > 0 }

    public mutating func record(_ parts: ScrapeSongParts) {
        cover.record(parts.cover)
        lyrics.record(parts.lyrics)
        tags.record(parts.tags)
    }

    public mutating func recordWriteback(_ outcome: ScrapeWritebackOutcome) {
        switch outcome {
        case .notAttempted: break
        case .written: writebackWritten += 1
        case .failed(.unavailable): writebackFailedUnavailable += 1
        case .failed(.conflict): writebackFailedConflict += 1
        case .failed(.timeout): writebackFailedTimeout += 1
        case .failed(.interrupted): writebackFailedInterrupted += 1
        case .failed(.other): writebackFailedOther += 1
        }
    }

    public mutating func recordSongError(songID: String, title: String, detail: String?) {
        songErrors += 1
        recordFailure(.init(songID: songID, title: title, part: .song, detail: detail))
    }

    public mutating func recordFailure(_ entry: BatchScrapeFailureEntry) {
        if let index = failures.firstIndex(where: { $0.id == entry.id }) {
            failures[index] = entry
        } else if failures.count < Self.maximumFailureEntries {
            failures.append(entry)
        } else {
            omittedFailureCount += 1
        }
    }

    /// 完成提示要显示的几行。数量为 0 的项不显示；一轮什么都没补上、也没有失败时只说一句。
    public var summary: BatchScrapeSummary {
        func segments(_ counts: BatchScrapePartCounts) -> [BatchScrapeSummary.Segment] {
            var result: [BatchScrapeSummary.Segment] = []
            if counts.filled > 0 { result.append(.filled(counts.filled)) }
            if counts.alreadyPresent > 0 { result.append(.alreadyPresent(counts.alreadyPresent)) }
            if counts.notFound > 0 { result.append(.notFound(counts.notFound)) }
            if counts.saveFailed > 0 { result.append(.saveFailed(counts.saveFailed)) }
            return result
        }
        let filledAnything = cover.filled + lyrics.filled + tags.filled > 0
        let failedAnything = cover.saveFailed + lyrics.saveFailed + writebackFailed + songErrors > 0 || hasFailures
        return BatchScrapeSummary(
            foundNothing: !filledAnything && !failedAnything,
            cover: segments(cover),
            lyrics: segments(lyrics),
            tagsFilled: tags.filled,
            writebackWritten: writebackWritten,
            writebackFailed: writebackFailed,
            songErrors: songErrors
        )
    }
}

public struct BatchScrapeSummary: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case filled(Int)
        case alreadyPresent(Int)
        case notFound(Int)
        case saveFailed(Int)
    }

    /// 什么都没补上，也没有失败：只显示「没有找到可以补充的内容」。
    public var foundNothing: Bool
    public var cover: [Segment]
    public var lyrics: [Segment]
    public var tagsFilled: Int
    public var writebackWritten: Int
    public var writebackFailed: Int
    public var songErrors: Int

    public init(foundNothing: Bool, cover: [Segment], lyrics: [Segment],
                tagsFilled: Int, writebackWritten: Int, writebackFailed: Int, songErrors: Int = 0) {
        self.foundNothing = foundNothing
        self.cover = cover
        self.lyrics = lyrics
        self.tagsFilled = tagsFilled
        self.writebackWritten = writebackWritten
        self.writebackFailed = writebackFailed
        self.songErrors = songErrors
    }
}
