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
