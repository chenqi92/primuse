import Foundation

public extension ScrapedMetadataMergePolicy.Candidate {
    init(_ fields: ScrapedMetadataMergePolicy.Fields) {
        self.init(title: fields.title, artist: fields.artist, albumArtist: fields.albumArtist,
                  album: fields.albumTitle, year: fields.year, genres: fields.genre.map { [$0] },
                  trackNumber: fields.trackNumber, discNumber: fields.discNumber)
    }
}

public enum ScrapeField: String, CaseIterable, Codable, Sendable {
    case title, artist, album, albumArtist, year, track, disc, genre, cover, lyrics

    public static let tags = Set(allCases.filter { $0.part == .metadata })

    public var part: ScrapeParts {
        switch self {
        case .cover: .cover
        case .lyrics: .lyrics
        default: .metadata
        }
    }

    public func changed(from old: ScrapedMetadataMergePolicy.Fields, to new: ScrapedMetadataMergePolicy.Fields) -> Bool {
        switch self {
        case .title: old.title != new.title
        case .artist: old.artist != new.artist || old.sourceArtistNames != new.sourceArtistNames
        case .album: old.albumTitle != new.albumTitle
        case .albumArtist: old.albumArtist != new.albumArtist
        case .year: old.year != new.year
        case .track: old.trackNumber != new.trackNumber
        case .disc: old.discNumber != new.discNumber
        case .genre: old.genre != new.genre
        case .cover, .lyrics: false
        }
    }

    public func hasValue(in tags: ScrapedMetadataMergePolicy.Fields, hasCover: Bool, hasLyrics: Bool) -> Bool {
        func present(_ text: String?) -> Bool {
            text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        switch self {
        case .title: return present(tags.title)
        case .artist: return present(tags.artist)
        case .album: return present(tags.albumTitle)
        case .albumArtist: return present(tags.albumArtist)
        case .year: return (tags.year ?? 0) > 0
        case .track: return (tags.trackNumber ?? 0) > 0
        case .disc: return (tags.discNumber ?? 0) > 0
        case .genre: return present(tags.genre)
        case .cover: return hasCover
        case .lyrics: return hasLyrics
        }
    }
}

public enum ScrapeFieldMode: String, Codable, CaseIterable, Sendable {
    case inherit, skip, fillMissing, overwrite
}

public struct ScrapeFieldPreference: Equatable, Codable, Sendable {
    public var mode: ScrapeFieldMode
    public var preferredSource: String?

    public init(mode: ScrapeFieldMode = .inherit, preferredSource: String? = nil) {
        self.mode = mode
        self.preferredSource = preferredSource
    }
}

public struct ScrapeFieldRules: Equatable, Codable, Sendable {
    private var preferences: [String: ScrapeFieldPreference] = [:]

    public init() {}

    public subscript(_ field: ScrapeField) -> ScrapeFieldPreference {
        get { preferences[field.rawValue] ?? .init() }
        set { preferences[field.rawValue] = newValue == .init() ? nil : newValue }
    }

    public func request(parts: ScrapeParts = .all, overwriteByDefault: Bool, fillOnly: Bool = false) -> ScrapeFieldRequest {
        var request = ScrapeFieldRequest()
        for field in ScrapeField.allCases where parts.contains(field.part) {
            let mode = self[field].mode
            guard mode != .skip else { continue }
            request.fields.insert(field)
            if !fillOnly && (mode == .overwrite || (mode == .inherit && overwriteByDefault)) {
                request.overwrites.insert(field)
            }
        }
        return request
    }
}

public struct ScrapeFieldRequest: Sendable, Equatable, Codable {
    public var fields: Set<ScrapeField> = []
    public var overwrites: Set<ScrapeField> = []

    public init() {}

    public func needed(for tags: ScrapedMetadataMergePolicy.Fields, hasCover: Bool, hasLyrics: Bool,
                       titleIsPlaceholder: Bool = false) -> Self {
        var result = self
        result.fields = fields.filter { field in
            overwrites.contains(field) || (field == .title && titleIsPlaceholder)
                || !field.hasValue(in: tags, hasCover: hasCover, hasLyrics: hasLyrics)
        }
        result.overwrites.formIntersection(result.fields)
        return result
    }

    /// `fields` has already been narrowed against the current row. An album artist is
    /// independent of the track artist, including when one of those two fields is skipped.
    public func merging(_ original: ScrapedMetadataMergePolicy.Fields,
                        candidate: ScrapedMetadataMergePolicy.Candidate) -> ScrapedMetadataMergePolicy.Fields {
        let proposed = ScrapedMetadataMergePolicy.merged(original, with: candidate, overwrite: true)
        var result = original
        if fields.contains(.title) { result.title = proposed.title }
        if fields.contains(.artist) {
            result.artist = proposed.artist
            result.sourceArtistNames = proposed.sourceArtistNames
        }
        if fields.contains(.album) { result.albumTitle = proposed.albumTitle }
        if fields.contains(.albumArtist), candidate.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.albumArtist = proposed.albumArtist
        }
        if fields.contains(.year), (candidate.year ?? 0) > 0 { result.year = proposed.year }
        if fields.contains(.track), (candidate.trackNumber ?? 0) > 0 { result.trackNumber = proposed.trackNumber }
        if fields.contains(.disc), (candidate.discNumber ?? 0) > 0 { result.discNumber = proposed.discNumber }
        if fields.contains(.genre) { result.genre = proposed.genre }
        return result
    }
}
