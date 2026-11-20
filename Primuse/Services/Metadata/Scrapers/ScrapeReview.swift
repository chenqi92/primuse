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

struct ScrapeReviewOption: Identifiable, Sendable {
    enum Value: Sendable {
        case text(String)
        case cover(ScrapeReviewCover)
        case lyrics(ScrapeReviewLyrics)
    }

    let id: String
    let source: String?
    var value: Value
}

struct ScrapeReviewCatalog: Sendable {
    var options: [ScrapeField: [ScrapeReviewOption]] = [:]
    var recommended: [ScrapeField: String] = [:]

    mutating func add(_ option: ScrapeReviewOption, for field: ScrapeField) {
        if options[field]?.contains(where: { $0.id == option.id }) != true {
            options[field, default: []].append(option)
        }
    }

    mutating func addText(_ text: String?, field: ScrapeField, source: String?) {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        add(.init(id: value, source: source, value: .text(value)), for: field)
    }

    mutating func addCover(_ url: String, config: ScraperSourceConfig, data: Data? = nil) {
        let choice = ScrapeReviewOption(id: url, source: config.displayName, value: .cover(.init(data: data, url: url, config: config)))
        if let index = options[.cover]?.firstIndex(where: { $0.id == url }) {
            if data != nil { options[.cover]?[index] = choice }
        } else { add(choice, for: .cover) }
        if data != nil, recommended[.cover] == nil { recommended[.cover] = url }
    }

    mutating func addLyrics(_ lines: [LyricLine], source: String?, raw: String? = nil) {
        guard !lines.isEmpty else { return }
        let id = LyricsDocumentFingerprint(lines: lines).rawValue
        guard options[.lyrics]?.contains(where: { $0.id == id }) != true else { return }
        add(.init(id: id, source: source, value: .lyrics(.init(lines, raw: raw))), for: .lyrics)
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
    let catalog: ScrapeReviewCatalog
    let fields: [ScrapeField]
    private(set) var selected: [ScrapeField: String]
    private let initial: [ScrapeField: String]

    init(song: Song, catalog: ScrapeReviewCatalog, request: ScrapeFieldRequest, defaults: ScrapeFieldRequest) {
        original = song
        self.catalog = catalog
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
    func reviewFields(for song: Song, parts: ScrapeParts) -> ScrapeFieldRequest {
        var fields = fieldRules.request(parts: parts, overwriteByDefault: true)
        if song.isCueTrack {
            fields.fields.subtract([.artist, .album, .albumArtist, .track, .disc])
        }
        return fields
    }
}
