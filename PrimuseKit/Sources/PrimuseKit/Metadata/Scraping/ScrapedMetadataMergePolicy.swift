import Foundation

/// 把一条在线刮削结果并进一首歌已有的标签。iOS / macOS 的自动刮削与 Apple TV
/// 的补全、手动匹配共用这一份规则:`overwrite` 为 false 时只补空缺,为 true 时
/// 用候选覆盖;候选里的空值在两种模式下都不会抹掉本地已有的值。
public enum ScrapedMetadataMergePolicy {
    /// 一首歌参与合并的标签字段。
    public struct Fields: Codable, Sendable, Equatable {
        public var title: String
        public var artist: String?
        public var sourceArtistNames: [String]?
        public var albumTitle: String?
        public var albumArtist: String?
        public var year: Int?
        public var genre: String?
        public var trackNumber: Int?
        public var discNumber: Int?

        public init(
            title: String,
            artist: String? = nil,
            sourceArtistNames: [String]? = nil,
            albumTitle: String? = nil,
            albumArtist: String? = nil,
            year: Int? = nil,
            genre: String? = nil,
            trackNumber: Int? = nil,
            discNumber: Int? = nil
        ) {
            self.title = title
            self.artist = artist
            self.sourceArtistNames = sourceArtistNames
            self.albumTitle = albumTitle
            self.albumArtist = albumArtist
            self.year = year
            self.genre = genre
            self.trackNumber = trackNumber
            self.discNumber = discNumber
        }
    }

    /// 刮削源给出的候选详情(只取合并用得到的字段)。
    public struct Candidate: Sendable, Equatable {
        public var title: String
        public var artist: String?
        public var albumArtist: String?
        public var album: String?
        public var year: Int?
        public var genres: [String]?
        public var trackNumber: Int?
        public var discNumber: Int?

        public init(
            title: String,
            artist: String? = nil,
            albumArtist: String? = nil,
            album: String? = nil,
            year: Int? = nil,
            genres: [String]? = nil,
            trackNumber: Int? = nil,
            discNumber: Int? = nil
        ) {
            self.title = title
            self.artist = artist
            self.albumArtist = albumArtist
            self.album = album
            self.year = year
            self.genres = genres
            self.trackNumber = trackNumber
            self.discNumber = discNumber
        }
    }

    public static func merged(
        _ fields: Fields,
        with candidate: Candidate,
        overwrite: Bool
    ) -> Fields {
        var result = fields
        let previousArtist = result.artist
        let previousAlbumArtist = result.albumArtist
        result.title = ScrapeMetadataApplicationPolicy.resolvedText(
            original: result.title,
            scraped: candidate.title,
            overwrite: overwrite
        ) ?? result.title
        result.artist = ScrapeMetadataApplicationPolicy.resolvedText(
            original: result.artist,
            scraped: candidate.artist,
            overwrite: overwrite
        )
        // 歌手换了,源里原先的多值歌手就不再对应这个名字。
        if result.artist != previousArtist {
            result.sourceArtistNames = nil
        }
        result.albumTitle = ScrapeMetadataApplicationPolicy.resolvedText(
            original: result.albumTitle,
            scraped: candidate.album,
            overwrite: overwrite
        )
        let scrapedAlbumArtist = ScrapeMetadataApplicationPolicy.resolvedText(
            original: result.albumArtist,
            scraped: candidate.albumArtist,
            overwrite: overwrite
        )
        if candidate.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.albumArtist = scrapedAlbumArtist
        } else {
            // 候选没给专辑艺术家:原本就是「跟着曲目歌手」的回退值时跟着新歌手走,
            // 明确写过的专辑艺术家保持不动。
            result.albumArtist = AlbumGroupingPolicy.updatedAlbumArtistName(
                existingAlbumArtistName: previousAlbumArtist,
                previousTrackArtistName: previousArtist,
                updatedTrackArtistName: result.artist
            )
        }
        result.year = ScrapeMetadataApplicationPolicy.resolvedValue(
            original: result.year,
            scraped: candidate.year,
            overwrite: overwrite
        )
        result.genre = ScrapeMetadataApplicationPolicy.resolvedText(
            original: result.genre,
            scraped: candidate.genres.flatMap { GenreTagValues.joined(Array($0.prefix(3))) },
            overwrite: overwrite
        )
        result.trackNumber = ScrapeMetadataApplicationPolicy.resolvedValue(
            original: result.trackNumber,
            scraped: candidate.trackNumber,
            overwrite: overwrite
        )
        result.discNumber = ScrapeMetadataApplicationPolicy.resolvedValue(
            original: result.discNumber,
            scraped: candidate.discNumber,
            overwrite: overwrite
        )
        return result
    }
}

/// 手动匹配预览里可以逐项勾选的标签。
public enum ScrapeTagField: String, CaseIterable, Hashable, Sendable {
    case title, artist, album, year, genre, track, disc

    /// 这一项在候选里是否和现在不同。专辑这一项也算上候选明确给出的专辑艺术家
    /// (只是跟着曲目艺术家走的回退值归艺术家那一项)。
    public func differs(
        _ original: ScrapedMetadataMergePolicy.Fields,
        _ proposed: ScrapedMetadataMergePolicy.Fields
    ) -> Bool {
        switch self {
        case .title: original.title != proposed.title
        case .artist: original.artist != proposed.artist
        case .album:
            original.albumTitle != proposed.albumTitle
                || (proposed.albumArtist != proposed.artist && original.albumArtist != proposed.albumArtist)
        case .year: original.year != proposed.year
        case .genre: original.genre != proposed.genre
        case .track: original.trackNumber != proposed.trackNumber
        case .disc: original.discNumber != proposed.discNumber
        }
    }

    /// 预览打开时默认勾哪些:有变化的都勾。CUE 分轨一项都不勾 —— 标签以 CUE 表为准,
    /// 候选常是别的版本或合辑,打开匹配多半只是为了歌词。
    public static func defaultSelection(
        original: ScrapedMetadataMergePolicy.Fields,
        proposed: ScrapedMetadataMergePolicy.Fields,
        isCueTrack: Bool
    ) -> Set<ScrapeTagField> {
        guard !isCueTrack else { return [] }
        return Set(allCases.filter { $0.differs(original, proposed) })
    }
}

public extension ScrapedMetadataMergePolicy.Fields {
    /// 只把勾选的标签换成候选的值。艺术家换了,原本只是跟着曲目艺术家的专辑艺术家
    /// 跟着走;候选明确给的专辑艺术家随专辑一起应用。
    func applying(_ proposed: Self, fields: Set<ScrapeTagField>) -> Self {
        var result = self
        if fields.contains(.title) { result.title = proposed.title }
        if fields.contains(.artist) {
            result.artist = proposed.artist
            result.sourceArtistNames = proposed.sourceArtistNames
            result.albumArtist = AlbumGroupingPolicy.updatedAlbumArtistName(
                existingAlbumArtistName: albumArtist,
                previousTrackArtistName: artist,
                updatedTrackArtistName: proposed.artist
            )
        }
        if fields.contains(.album) {
            result.albumTitle = proposed.albumTitle
            if proposed.albumArtist != proposed.artist { result.albumArtist = proposed.albumArtist }
        }
        if fields.contains(.year) { result.year = proposed.year }
        if fields.contains(.genre) { result.genre = proposed.genre }
        if fields.contains(.track) { result.trackNumber = proposed.trackNumber }
        if fields.contains(.disc) { result.discNumber = proposed.discNumber }
        return result
    }
}

public extension Song {
    /// 刮削会改动的那几项标签。
    var scrapeFields: ScrapedMetadataMergePolicy.Fields {
        ScrapedMetadataMergePolicy.Fields(
            title: title,
            artist: artistName,
            sourceArtistNames: sourceArtistNames,
            albumTitle: albumTitle,
            albumArtist: albumArtistName,
            year: year,
            genre: genre,
            trackNumber: trackNumber,
            discNumber: discNumber
        )
    }

    mutating func applyScrapeFields(_ fields: ScrapedMetadataMergePolicy.Fields) {
        title = fields.title
        artistName = fields.artist
        sourceArtistNames = fields.sourceArtistNames
        albumTitle = fields.albumTitle
        if albumArtistName != fields.albumArtist { sourceAlbumArtistNames = nil }
        albumArtistName = fields.albumArtist
        year = fields.year
        genre = fields.genre
        trackNumber = fields.trackNumber
        discNumber = fields.discNumber
    }
}
