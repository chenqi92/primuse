import Foundation
import PrimuseKit

struct ScrapeReviewCover: Sendable {
    var data: Data?
    var url: String?
    var config: ScraperSourceConfig?

    func load() async throws -> Data {
        if let data { return data }
        guard let url, let config,
              let bytes = try await ConfigurableScraper.downloadResource(from: url, sourceConfig: config, timeout: 12),
              ArtworkImageCompatibility.isCompleteImage(bytes) else { throw ScraperError.parseError(String(localized: "scrape_song_failed")) }
        return bytes
    }
}

struct ScrapeReviewLyrics: Sendable {
    let lines: [LyricLine]
    let format: String?
    let summary: LyricsDocumentSummary

    init(_ lines: [LyricLine], raw: String? = nil) {
        self.lines = lines
        summary = LyricsDocumentSummary(lines: lines)
        if let raw, LyricsContentParser.isTTML(raw) { format = "TTML" }
        else if let raw, let type = WordTimedLyricsParser.detect(raw) { format = type.rawValue.uppercased() }
        else if let raw, let type = SubtitleLyricsParser.detect(raw) {
            switch type { case .webVTT: format = "VTT"; case .subRip: format = "SRT"; case .substationAlpha: format = "ASS/SSA" }
        }
        else if let raw, LyricsFormat.detect(raw) != .plain { format = "LRC" }
        else { format = nil }
    }
}

/// 选项属于哪一首：歌名、歌手、专辑、年份、时长，有什么带什么。结果页在选项下面显示成一行副标题，
/// 时长和这首歌自己的时长对着看，就分得清是不是同一个录音。
struct ScrapeReviewContext: Sendable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var year: Int?
    var durationMs: Int?

    init(title: String? = nil, artist: String? = nil, album: String? = nil, year: Int? = nil, durationMs: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.durationMs = durationMs
    }

    init(_ item: ScraperSearchItem) {
        self.init(title: item.title, artist: item.artist, album: item.album, year: item.year, durationMs: item.durationMs)
    }

    init(_ detail: ScraperDetail) {
        self.init(title: detail.title, artist: detail.artist, album: detail.album, year: detail.year, durationMs: detail.durationMs)
    }

    /// 资料库里这首歌现在的样子，「当前」那一项用。
    init(song: Song) {
        let milliseconds: Int? = song.duration > 0 && song.duration.isFinite ? Int((song.duration * 1000).rounded()) : nil
        self.init(title: song.title, artist: song.artistName, album: song.albumTitle, year: song.year, durationMs: milliseconds)
    }

    var isEmpty: Bool { subtitle(for: nil) == nil }

    /// 去掉这个字段自己那一项（专辑字段不再重复专辑名）。
    func subtitle(for field: ScrapeField?) -> String? {
        var parts: [String] = []
        func append(_ text: String?) {
            guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            parts.append(value)
        }
        if field != .title { append(title) }
        if field != .artist && field != .albumArtist { append(artist) }
        if field != .album { append(album) }
        if field != .year, let year, year > 0 { parts.append(String(year)) }
        if let durationMs, durationMs > 0 {
            let seconds = durationMs / 1000
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 选项来自哪一条候选。只拿到搜索行字段的候选（`hasDetail == false`）选中后可以按需补拉这一条的详情。
struct ScrapeReviewCandidate: Sendable {
    let config: ScraperSourceConfig
    let item: ScraperSearchItem
    var hasDetail: Bool

    var id: String { config.id + "|" + item.externalId }
}

struct ScrapeReviewOption: Identifiable, Sendable {
    enum Value: Sendable {
        case text(String)
        case cover(ScrapeReviewCover)
        case lyrics(ScrapeReviewLyrics)
    }

    let id: String
    let source: String?
    var value: Value
    var context: ScrapeReviewContext? = nil
    var candidate: ScrapeReviewCandidate? = nil
}

/// 结果页这次搜索用的刮削器和设置。选中一条还没拉过详情的候选、或改选了别的歌名歌手时，
/// 用同一个刮削器补拉（共用它的冷却和熔断状态），搜到的选项并回这次的结果里。
struct ScrapeReviewSession: Sendable {
    let id = UUID()
    let manager: ScraperManager
    let settings: ScraperSettings
    /// 这次按什么歌名、歌手找的歌词：改选回同一个身份时不必再找。
    let title: String
    let artist: String?
}

struct ScrapeReviewCatalog: Sendable {
    var options: [ScrapeField: [ScrapeReviewOption]] = [:]
    var recommended: [ScrapeField: String] = [:]
    var session: ScrapeReviewSession?

    /// 已经有同一个值时不重复列；新来的这份带着更全的出处（副标题、拉过详情的候选）就补上。
    mutating func add(_ option: ScrapeReviewOption, for field: ScrapeField) {
        guard let index = options[field]?.firstIndex(where: { $0.id == option.id }) else {
            options[field, default: []].append(option)
            return
        }
        guard var existing = options[field]?[index] else { return }
        if existing.context == nil || existing.context?.isEmpty == true, let context = option.context {
            existing.context = context
        }
        if existing.candidate == nil {
            existing.candidate = option.candidate
        } else if let candidate = option.candidate, candidate.hasDetail, existing.candidate?.id == candidate.id {
            existing.candidate?.hasDetail = true
        }
        options[field]?[index] = existing
    }

    mutating func addText(_ text: String?, field: ScrapeField, source: String?,
                          context: ScrapeReviewContext? = nil, candidate: ScrapeReviewCandidate? = nil) {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        add(.init(id: value, source: source, value: .text(value), context: context, candidate: candidate), for: field)
    }

    mutating func addCover(_ url: String, config: ScraperSourceConfig, data: Data? = nil,
                           context: ScrapeReviewContext? = nil, candidate: ScrapeReviewCandidate? = nil) {
        let choice = ScrapeReviewOption(id: url, source: config.displayName, value: .cover(.init(data: data, url: url, config: config)),
                                        context: context, candidate: candidate)
        if let index = options[.cover]?.firstIndex(where: { $0.id == url }), data != nil {
            var upgraded = choice
            upgraded.context = choice.context ?? options[.cover]?[index].context
            upgraded.candidate = choice.candidate ?? options[.cover]?[index].candidate
            options[.cover]?[index] = upgraded
        } else { add(choice, for: .cover) }
        if data != nil, recommended[.cover] == nil { recommended[.cover] = url }
    }

    mutating func addLyrics(_ lines: [LyricLine], source: String?, raw: String? = nil, context: ScrapeReviewContext? = nil) {
        guard !lines.isEmpty else { return }
        let id = LyricsDocumentFingerprint(lines: lines).rawValue
        add(.init(id: id, source: source, value: .lyrics(.init(lines, raw: raw)), context: context), for: .lyrics)
    }

    /// 并进补拉回来的选项：只加新值、补全已有选项的出处，不动推荐项，也不清掉已有的选项。
    mutating func merge(_ other: ScrapeReviewCatalog) {
        for field in ScrapeField.reviewOrder {
            for option in other.options[field] ?? [] { add(option, for: field) }
        }
    }

    mutating func includeLocalResults(original: Song, updated: Song, fields: Set<ScrapeField>, cover: Data?, lyrics: [LyricLine]?) {
        for field in fields.intersection(ScrapeField.tags) {
            guard recommended[field] == nil, let value = field.text(in: updated.scrapeFields),
                  value != field.text(in: original.scrapeFields) else { continue }
            addText(value, field: field, source: nil)
            recommended[field] = value
        }
        if fields.contains(.cover), recommended[.cover] == nil, let cover {
            let id = "embedded"
            add(.init(id: id, source: nil, value: .cover(.init(data: cover))), for: .cover)
            recommended[.cover] = id
        }
        if fields.contains(.lyrics), recommended[.lyrics] == nil, let lyrics, !lyrics.isEmpty {
            addLyrics(lyrics, source: nil)
            recommended[.lyrics] = LyricsDocumentFingerprint(lines: lyrics).rawValue
        }
    }

}

extension ScrapeField {
    static let reviewOrder: [Self] = [.cover, .title, .artist, .album, .albumArtist, .year, .track, .disc, .genre, .lyrics]

    func text(in tags: ScrapedMetadataMergePolicy.Fields) -> String? {
        switch self {
        case .title: tags.title
        case .artist: tags.artist
        case .album: tags.albumTitle
        case .albumArtist: tags.albumArtist
        case .year: tags.year.map(String.init)
        case .track: tags.trackNumber.map(String.init)
        case .disc: tags.discNumber.map(String.init)
        case .genre: tags.genre
        case .cover, .lyrics: nil
        }
    }

    func apply(_ value: String, to tags: inout ScrapedMetadataMergePolicy.Fields) {
        switch self {
        case .title: tags.title = value
        case .artist:
            if tags.artist != value { tags.sourceArtistNames = nil }
            tags.artist = value
        case .album: tags.albumTitle = value
        case .albumArtist: tags.albumArtist = value
        case .year: tags.year = Int(value)
        case .track: tags.trackNumber = Int(value)
        case .disc: tags.discNumber = Int(value)
        case .genre: tags.genre = value
        case .cover, .lyrics: break
        }
    }
}

extension ScraperDetail {
    var reviewTags: ScrapedMetadataMergePolicy.Fields {
        .init(title: title, artist: artist, albumTitle: album, albumArtist: albumArtist, year: year,
              genre: genres.flatMap { GenreTagValues.joined(Array($0.prefix(3))) },
              trackNumber: trackNumber, discNumber: discNumber)
    }
}

/// Selection is local to one presentation. A missing selection keeps the library value.
struct ScrapeReviewDraft: Sendable {
    let original: Song
    private(set) var catalog: ScrapeReviewCatalog
    private(set) var fields: [ScrapeField]
    private(set) var selected: [ScrapeField: String]
    private let initial: [ScrapeField: String]
    private let requested: Set<ScrapeField>

    init(song: Song, catalog: ScrapeReviewCatalog, request: ScrapeFieldRequest, defaults: ScrapeFieldRequest) {
        original = song
        self.catalog = catalog
        requested = request.fields
        fields = ScrapeField.reviewOrder.filter { request.fields.contains($0) && catalog.options[$0]?.isEmpty == false }
        var picks: [ScrapeField: String] = [:]
        for field in fields where defaults.fields.contains(field) {
            if field == .cover && song.isCueTrack { continue }
            guard let id = catalog.recommended[field],
                  catalog.options[field]?.contains(where: { $0.id == id }) == true,
                  field.text(in: song.scrapeFields) != id else { continue }
            picks[field] = id
        }
        selected = picks
        initial = picks
    }

    var isEdited: Bool { selected != initial }
    var hasChanges: Bool { !selected.isEmpty }

    /// 这一项是不是用户自己改选过（和打开时的默认勾选不一样）。
    func isEdited(_ field: ScrapeField) -> Bool { selected[field] != initial[field] }

    func choice(for field: ScrapeField) -> ScrapeReviewOption? {
        guard let id = selected[field] else { return nil }
        return catalog.options[field]?.first { $0.id == id }
    }

    func choices(for field: ScrapeField) -> [ScrapeReviewOption] {
        var values = (catalog.options[field] ?? []).filter { $0.id != field.text(in: original.scrapeFields) }
        if let index = values.firstIndex(where: { $0.id == catalog.recommended[field] }), index != 0 {
            let best = values.remove(at: index)
            values.insert(best, at: 0)
        }
        return values
    }

    mutating func select(_ id: String?, for field: ScrapeField) {
        guard fields.contains(field), id == nil || choices(for: field).contains(where: { $0.id == id }) else { return }
        selected[field] = id
    }

    /// 这次结果页要不要这个字段（勾了这部分、CUE 分轨没被拦下）。
    func requests(_ field: ScrapeField) -> Bool { requested.contains(field) }

    /// 并进补拉回来的选项：只加不删，推荐项和用户已经选中的都不变。不是这次搜索的结果（换过搜索词）不并。
    mutating func merge(_ more: ScrapeReviewCatalog, from session: ScrapeReviewSession) {
        guard catalog.session?.id == session.id else { return }
        catalog.merge(more)
        fields = ScrapeField.reviewOrder.filter { requested.contains($0) && catalog.options[$0]?.isEmpty == false }
    }

    /// 选中了、但只拿到搜索行字段的候选，还没补拉过详情。
    var selectedCandidatesWithoutDetail: [ScrapeReviewCandidate] {
        var seen: Set<String> = []
        return ScrapeField.reviewOrder.compactMap { choice(for: $0)?.candidate }
            .filter { !$0.hasDetail && seen.insert($0.id).inserted }
    }

    /// 按所选的信息找歌词用的歌名、歌手、专辑：选了别的候选的值就用它，没选就是这首歌现在的。
    var lyricsLookup: (title: String, artist: String?, album: String?) {
        func text(_ field: ScrapeField) -> String? {
            if case .text(let value) = choice(for: field)?.value { return value }
            return field.text(in: original.scrapeFields)
        }
        return (text(.title) ?? original.title, text(.artist), text(.album))
    }

    func proposedTags(on current: Song) -> ScrapedMetadataMergePolicy.Fields {
        var tags = current.scrapeFields
        for field in ScrapeField.tags {
            if case .text(let value) = choice(for: field)?.value { field.apply(value, to: &tags) }
        }
        return tags
    }

    var lyrics: [LyricLine]? {
        guard case .lyrics(let choice) = choice(for: .lyrics)?.value else { return nil }
        return choice.lines
    }

    var cover: ScrapeReviewCover? {
        guard case .cover(let cover) = choice(for: .cover)?.value else { return nil }
        return cover
    }
}

extension ScraperSettings {
    /// CUE 分轨共用整张专辑的这几项，结果页不让单首改。
    static let cueAlbumIdentityFields: Set<ScrapeField> = [.artist, .album, .albumArtist, .track, .disc]

    /// 单曲刮削结果页搜哪些字段、能选哪些字段：这次勾的几部分全都算。刮削规则里的「跳过」
    /// 只管批量刮削、后台自动补全和结果页的预选，用户点开这首歌来换东西时照样能挑。
    func reviewFields(for song: Song, parts: ScrapeParts) -> ScrapeFieldRequest {
        var request = ScrapeFieldRequest()
        request.fields = Set(ScrapeField.allCases.filter { parts.contains($0.part) })
        if song.isCueTrack {
            request.fields.subtract(Self.cueAlbumIdentityFields)
        }
        request.overwrites = request.fields
        return request
    }

    /// 结果页默认勾选哪些字段。用户是专门打开这首歌来换东西的：有变化的标签、找到的封面和歌词都勾上
    /// (CUE 分轨的封面和专辑身份除外)。「仅补全缺失字段」和覆盖 / 补缺规则只管批量和后台；
    /// 规则里设成「跳过」的字段不预选，但仍列出来可以手动选。
    func reviewDefaults(for song: Song, parts: ScrapeParts) -> ScrapeFieldRequest {
        var request = fieldRules.request(parts: parts, overwriteByDefault: true)
        if song.isCueTrack {
            request.fields.subtract(Self.cueAlbumIdentityFields)
            request.overwrites.subtract(Self.cueAlbumIdentityFields)
        }
        return request
    }
}
