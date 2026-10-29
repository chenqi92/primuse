import Foundation
import PrimuseKit

struct ScraperSearchItem: Sendable {
    let externalId: String
    let source: MusicScraperType
    let title: String
    var artist: String?
    var album: String?
    var year: Int?
    var durationMs: Int?
    var coverUrl: String?
    var trackNumber: Int?
    var genres: [String]?
}

struct ScraperSearchResult: Sendable {
    let items: [ScraperSearchItem]
    let source: MusicScraperType

    var isEmpty: Bool { items.isEmpty }

    static func empty(_ source: MusicScraperType) -> ScraperSearchResult {
        ScraperSearchResult(items: [], source: source)
    }
}

struct ScraperDetail: Sendable {
    let externalId: String
    let source: MusicScraperType
    let title: String
    var artist: String?
    var albumArtist: String?
    var album: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var durationMs: Int?
    var genres: [String]?
    var coverUrl: String?
}

extension ScrapedMetadataMergePolicy.Candidate {
    init(_ detail: ScraperDetail) {
        self.init(
            title: detail.title,
            artist: detail.artist,
            albumArtist: detail.albumArtist,
            album: detail.album,
            year: detail.year,
            genres: detail.genres,
            trackNumber: detail.trackNumber,
            discNumber: detail.discNumber
        )
    }
}

struct ScraperLyricsResult: Sendable {
    let source: MusicScraperType
    var lrcContent: String?
    var plainText: String?
    var format: LyricsFormat

    init(source: MusicScraperType, lrcContent: String? = nil, plainText: String? = nil) {
        self.source = source
        self.lrcContent = lrcContent
        self.plainText = plainText
        self.format = LyricsFormat.detect(lrcContent ?? plainText)
    }

    var hasLyrics: Bool {
        (lrcContent != nil && !lrcContent!.isEmpty) ||
        (plainText != nil && !plainText!.isEmpty)
    }
}

struct ScraperCoverResult: Sendable {
    let source: MusicScraperType
    let coverUrl: String
    var thumbnailUrl: String?
}

struct ScrapeResult: Sendable {
    var detail: ScraperDetail?
    var coverData: Data?
    var lyrics: [PrimuseKit.LyricLine]?
    var errors: [String]
}

struct ScraperAlbum: Identifiable, Sendable {
    let externalID: String
    let source: MusicScraperType
    let title: String
    var artist: String?
    var year: Int?
    var trackCount: Int?
    var edition: String?

    var id: String { source.rawValue + ":" + externalID }
}

/// Suggestions stay inside the selected release and never assign one track to two files.
enum AlbumMetadataMatching {
    static func assignments(songs: [Song], tracks: [ScraperDetail]) -> [String: String] {
        var options: [String: [String]] = [:]
        for song in songs {
            let title = normalizedTitle(song.title)
            let candidates = tracks.filter { track in
                if let disc = song.discNumber, disc > 0,
                   let remoteDisc = track.discNumber, remoteDisc != disc { return false }
                if song.duration > 0, let milliseconds = track.durationMs, milliseconds > 0,
                   abs(song.duration - Double(milliseconds) / 1000) > 8 { return false }
                return true
            }
            let titled = candidates.filter { !title.isEmpty && normalizedTitle($0.title) == title }
            let numbered = candidates.filter { track in
                guard let number = song.trackNumber ?? fileTrackNumber(song.filePath), number > 0 else { return false }
                return track.trackNumber == number
            }
            // A known title conflicting with track order needs an explicit choice.
            if !titled.isEmpty {
                let exact = titled.filter { candidate in numbered.contains { $0.externalId == candidate.externalId } }
                options[song.id] = (exact.isEmpty ? titled : exact).map(\.externalId)
            } else if isNumberOnlyTitle(song.title) {
                options[song.id] = numbered.map(\.externalId)
            }
        }
        let unique = options.compactMapValues { $0.count == 1 ? $0.first : nil }
        let uses = Dictionary(grouping: unique.keys, by: { unique[$0]! })
        return unique.filter { uses[$0.value]?.count == 1 }
    }

    static func proposals(song: Song, track: ScraperDetail) -> [TagCleanupProposal] {
        let values: [(TagCleanupField, String?, String?)] = [
            (.title, song.title, track.title),
            (.artist, song.artistName, track.artist),
            (.albumArtist, song.albumArtistName, track.albumArtist),
            (.album, song.albumTitle, track.album),
            (.year, song.year.map(String.init), track.year.map(String.init)),
            (.genre, song.genre, track.genres?.joined(separator: "; ")),
            (.trackNumber, song.trackNumber.map(String.init), track.trackNumber.map(String.init)),
            (.discNumber, song.discNumber.map(String.init), track.discNumber.map(String.init)),
        ]
        return values.compactMap { field, old, proposed in
            guard let proposed, !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  proposed != old else { return nil }
            return TagCleanupProposal(songID: song.id, field: field, oldValue: old,
                                      newValue: proposed, reason: .unifiedSpelling)
        }
    }

    private static func normalizedTitle(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*\d{1,3}[\s._-]+"#, with: "", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static func isNumberOnlyTitle(_ title: String) -> Bool {
        title.range(of: #"(?i)^\s*(track\s*)?\d{1,3}(\.[a-z0-9]{2,4})?\s*$"#, options: .regularExpression) != nil
    }

    private static func fileTrackNumber(_ path: String) -> Int? {
        let stem = (path as NSString).lastPathComponent
        let digits = stem.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        return Int(digits)
    }
}
