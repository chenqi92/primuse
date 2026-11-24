import Foundation
import GRDB

/// `Song` ↔ `song` 表一行,无损往返。
///
/// 热字段一字段一列;罕见字段放 `extra`(紧凑的标签-值二进制)。两种情况列装不下原值,
/// 原值另记在 `extra` 里:
/// - 字符串含 U+0000:GRDB 按 C 字符串绑定与读取文本,会在 NUL 处截断;
/// - 浮点数是 NaN 或 -0.0:SQLite 把 NaN 存成 NULL, REAL 列把 -0.0 存成整数 0。
/// 播放器给播放副本挂的 `appliedPlaybackRange` 不入库(与 JSON 编码一致,存整首的长度)。
enum LibraryCatalogSongCodec {
    /// 物化一首歌要读的列,顺序即 `decode` 的下标。
    static let selectColumns = """
        song.rowid, song.id, source.id, song.title, song.artistName, song.albumTitle, song.albumArtistName,
        song.albumID, song.artistID, song.trackNumber, song.discNumber, song.year, song.duration,
        song.fileFormat, song.audioCodec, song.filePath, song.serverFilePath, song.fileSize,
        song.bitRate, song.sampleRate, song.bitDepth, song.effectiveBitDepth, song.genre,
        song.dateAdded, song.serverDateAdded, song.lastModified, song.serverPlayCount,
        song.coverArtFileName, song.artistArtworkFileName, song.lyricsFileName, song.revision,
        song.lyricsText, song.extra
        """
    static let selectFrom = "FROM song JOIN source ON source.key = song.sourceKey"

    enum Column {
        static let rowid = 0, id = 1, sourceID = 2, title = 3, artistName = 4, albumTitle = 5
        static let albumArtistName = 6, albumID = 7, artistID = 8, trackNumber = 9, discNumber = 10
        static let year = 11, duration = 12, fileFormat = 13, audioCodec = 14, filePath = 15
        static let serverFilePath = 16, fileSize = 17, bitRate = 18, sampleRate = 19, bitDepth = 20
        static let effectiveBitDepth = 21, genre = 22, dateAdded = 23, serverDateAdded = 24
        static let lastModified = 25, serverPlayCount = 26, coverArtFileName = 27
        static let artistArtworkFileName = 28, lyricsFileName = 29, revision = 30, lyricsText = 31
        static let extra = 32
    }

    /// 写入时的存储列(不含派生列),值顺序与 `LibraryCatalogWriter` 的语句一致。
    struct StoredValues: Equatable {
        var title: String
        var artistName: String?
        var albumTitle: String?
        var albumArtistName: String?
        var albumID: String?
        var artistID: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var duration: Double?
        var fileFormat: String
        var audioCodec: String?
        var filePath: String
        var serverFilePath: String?
        var fileSize: Int64
        var bitRate: Int?
        var sampleRate: Int?
        var bitDepth: Int?
        var effectiveBitDepth: Int?
        var genre: String?
        var dateAdded: Double?
        var serverDateAdded: Double?
        var lastModified: Double?
        var serverPlayCount: Int?
        var coverArtFileName: String?
        var artistArtworkFileName: String?
        var lyricsFileName: String?
        var revision: String?
        var lyricsText: String?
        var extra: Data?

        var databaseValues: [DatabaseValueConvertible?] {
            [title, artistName, albumTitle, albumArtistName, albumID, artistID, trackNumber, discNumber,
             year, duration ?? 0, fileFormat, audioCodec, filePath, serverFilePath, fileSize, bitRate,
             sampleRate, bitDepth, effectiveBitDepth, genre, dateAdded ?? 0, serverDateAdded, lastModified,
             serverPlayCount, coverArtFileName, artistArtworkFileName, lyricsFileName, revision, lyricsText, extra]
        }

        /// 原始绑定用的列值(顺序同 `columnNames`)。
        var catalogValues: [CatalogValue] {
            [.text(title), .optionalText(artistName), .optionalText(albumTitle), .optionalText(albumArtistName),
             .optionalText(albumID), .optionalText(artistID), .optionalInt(trackNumber), .optionalInt(discNumber),
             .optionalInt(year), .real(duration ?? 0), .text(fileFormat), .optionalText(audioCodec), .text(filePath),
             .optionalText(serverFilePath.map(LibraryCatalogDerivedFields.columnText)), .int(fileSize),
             .optionalInt(bitRate), .optionalInt(sampleRate), .optionalInt(bitDepth), .optionalInt(effectiveBitDepth),
             .optionalText(genre), .real(dateAdded ?? 0), .optionalReal(serverDateAdded), .optionalReal(lastModified),
             .optionalInt(serverPlayCount), .optionalText(coverArtFileName), .optionalText(artistArtworkFileName),
             .optionalText(lyricsFileName), .optionalText(revision), .optionalText(lyricsText),
             extra.map(CatalogValue.blob) ?? .null]
        }

        static let columnNames = [
            "title", "artistName", "albumTitle", "albumArtistName", "albumID", "artistID", "trackNumber",
            "discNumber", "year", "duration", "fileFormat", "audioCodec", "filePath", "serverFilePath",
            "fileSize", "bitRate", "sampleRate", "bitDepth", "effectiveBitDepth", "genre", "dateAdded",
            "serverDateAdded", "lastModified", "serverPlayCount", "coverArtFileName", "artistArtworkFileName",
            "lyricsFileName", "revision", "lyricsText", "extra",
        ]
    }

    // MARK: - Encode

    static func encode(_ song: Song) -> StoredValues {
        var extra = ExtraWriter()
        func text(_ value: String, column: Int) -> String {
            guard value.utf8.contains(0) else { return value }
            extra.string(Tag.stringOverride + UInt8(column), value)
            return value.replacingOccurrences(of: "\0", with: "\u{FFFD}")
        }
        func optionalText(_ value: String?, column: Int) -> String? {
            value.map { text($0, column: column) }
        }
        func real(_ value: Double, column: Int) -> Double? {
            guard value.isNaN || (value == 0 && value.sign == .minus) else { return value }
            extra.bits(Tag.doubleOverride + UInt8(column), value.bitPattern)
            return value.isNaN ? nil : 0
        }
        func optionalReal(_ value: Double?, column: Int) -> Double? {
            value.flatMap { real($0, column: column) }
        }

        let duration = song.appliedPlaybackRange?.songDuration ?? song.duration
        let values = StoredValues(
            title: text(song.title, column: Column.title),
            artistName: optionalText(song.artistName, column: Column.artistName),
            albumTitle: optionalText(song.albumTitle, column: Column.albumTitle),
            albumArtistName: optionalText(song.albumArtistName, column: Column.albumArtistName),
            albumID: optionalText(song.albumID, column: Column.albumID),
            artistID: optionalText(song.artistID, column: Column.artistID),
            trackNumber: song.trackNumber,
            discNumber: song.discNumber,
            year: song.year,
            duration: real(duration, column: Column.duration),
            fileFormat: song.fileFormat.rawValue,
            audioCodec: song.audioCodec?.rawValue,
            filePath: text(song.filePath, column: Column.filePath),
            serverFilePath: song.serverFilePath,
            fileSize: song.fileSize,
            bitRate: song.bitRate,
            sampleRate: song.sampleRate,
            bitDepth: song.bitDepth,
            effectiveBitDepth: song.effectiveBitDepth,
            genre: optionalText(song.genre, column: Column.genre),
            dateAdded: real(song.dateAdded.timeIntervalSinceReferenceDate, column: Column.dateAdded),
            serverDateAdded: optionalReal(song.serverDateAdded?.timeIntervalSinceReferenceDate, column: Column.serverDateAdded),
            lastModified: optionalReal(song.lastModified?.timeIntervalSinceReferenceDate, column: Column.lastModified),
            serverPlayCount: song.serverPlayCount,
            coverArtFileName: optionalText(song.coverArtFileName, column: Column.coverArtFileName),
            artistArtworkFileName: optionalText(song.artistArtworkFileName, column: Column.artistArtworkFileName),
            lyricsFileName: optionalText(song.lyricsFileName, column: Column.lyricsFileName),
            revision: optionalText(song.revision, column: Column.revision),
            lyricsText: optionalText(song.lyricsText, column: Column.lyricsText),
            extra: nil
        )
        encodeRareFields(of: song, into: &extra)
        var result = values
        result.extra = extra.isEmpty ? nil : extra.data
        return result
    }

    private static func encodeRareFields(of song: Song, into extra: inout ExtraWriter) {
        if let names = song.sourceArtistNames { extra.strings(Tag.sourceArtistNames, names) }
        if let names = song.sourceAlbumArtistNames { extra.strings(Tag.sourceAlbumArtistNames, names) }
        if let value = song.referencedMusicVideoPath { extra.string(Tag.mvPath, value) }
        if let value = song.cueSheetPath { extra.string(Tag.cueSheetPath, value) }
        if let value = song.cueStartTime { extra.bits(Tag.cueStartTime, value.bitPattern) }
        if let value = song.cueEndTime { extra.bits(Tag.cueEndTime, value.bitPattern) }
        if let value = song.sacdTrackNumber { extra.int(Tag.sacdTrackNumber, Int64(value)) }
        if let value = song.isoAudioTrack, let data = try? jsonEncoder.encode(value) {
            extra.data(Tag.isoAudioTrack, data)
        }
        if let value = song.titlePinyin { extra.string(Tag.titlePinyin, value) }
        if let value = song.artistPinyin { extra.string(Tag.artistPinyin, value) }
        if let value = song.albumPinyin { extra.string(Tag.albumPinyin, value) }
        if let value = song.userMetadataEditedAt {
            extra.bits(Tag.userMetadataEditedAt, value.timeIntervalSinceReferenceDate.bitPattern)
        }
        if let value = song.audioVariants { extra.strings(Tag.audioVariants, value.map(\.rawValue)) }
        if let value = song.serverLibraryID { extra.string(Tag.serverLibraryID, value) }
        if let value = song.serverAlbumDateAdded {
            extra.bits(Tag.serverAlbumDateAdded, value.timeIntervalSinceReferenceDate.bitPattern)
        }
        if let value = song.contentMetadata { encodeContentMetadata(value, into: &extra) }
        if let value = song.serverCatalogAlbum {
            var payload = ExtraWriter()
            payload.rawString(value.id)
            payload.rawOptionalString(value.taggedArtist)
            extra.data(Tag.serverCatalogAlbum, payload.data)
        }
        if let value = song.isExternal { extra.int(Tag.isExternal, value ? 1 : 0) }
        if let value = song.replayGainTrackGain { extra.bits(Tag.replayGainTrackGain, value.bitPattern) }
        if let value = song.replayGainTrackPeak { extra.bits(Tag.replayGainTrackPeak, value.bitPattern) }
        if let value = song.replayGainAlbumGain { extra.bits(Tag.replayGainAlbumGain, value.bitPattern) }
        if let value = song.replayGainAlbumPeak { extra.bits(Tag.replayGainAlbumPeak, value.bitPattern) }
    }

    private static func encodeContentMetadata(_ value: SongContentMetadata, into extra: inout ExtraWriter) {
        var payload = ExtraWriter()
        var presence: UInt8 = 0
        if value.releaseType != nil { presence |= 1 }
        if value.copyright != nil { presence |= 2 }
        if value.iTunesAdvisory != nil { presence |= 4 }
        if value.isFileInspectionComplete { presence |= 8 }
        if value.embeddedChapterCount != nil { presence |= 16 }
        let tracks = value.embeddedMediaTracks.flatMap { try? jsonEncoder.encode($0) }
        if tracks != nil { presence |= 32 }
        payload.byte(presence)
        if let text = value.releaseType { payload.rawString(text) }
        if let text = value.copyright { payload.rawString(text) }
        if let number = value.iTunesAdvisory { payload.varint(zigzag(Int64(number))) }
        if let number = value.embeddedChapterCount { payload.varint(zigzag(Int64(number))) }
        if let tracks { payload.rawData(tracks) }
        extra.data(Tag.contentMetadata, payload.data)
    }

    // MARK: - Decode

    static func decode(_ row: Row) throws -> Song {
        let stringOverrides: [Int: String]
        let doubleOverrides: [Int: UInt64]
        var rare = RareFields()
        if let blob = row.dataNoCopy(atIndex: Column.extra) {
            var reader = ExtraReader(blob)
            var strings: [Int: String] = [:]
            var doubles: [Int: UInt64] = [:]
            try decodeRareFields(&reader, into: &rare, strings: &strings, doubles: &doubles)
            stringOverrides = strings
            doubleOverrides = doubles
        } else {
            stringOverrides = [:]
            doubleOverrides = [:]
        }
        func text(_ column: Int) -> String? {
            stringOverrides[column] ?? (row[column] as String?)
        }
        func real(_ column: Int) -> Double? {
            if let bits = doubleOverrides[column] { return Double(bitPattern: bits) }
            return row[column] as Double?
        }
        guard let id = text(Column.id), let sourceID = row[Column.sourceID] as String?,
              let title = text(Column.title), let filePath = text(Column.filePath),
              let formatRaw = row[Column.fileFormat] as String? else {
            throw LibraryCatalogError.corruptRow
        }
        guard let fileFormat = AudioFormat(rawValue: formatRaw) else {
            throw LibraryCatalogError.unknownAudioFormat(formatRaw)
        }
        var song = Song(
            id: id,
            title: title,
            albumID: text(Column.albumID),
            artistID: text(Column.artistID),
            albumTitle: text(Column.albumTitle),
            artistName: text(Column.artistName),
            sourceArtistNames: rare.sourceArtistNames,
            albumArtistName: text(Column.albumArtistName),
            trackNumber: row[Column.trackNumber] as Int?,
            discNumber: row[Column.discNumber] as Int?,
            duration: real(Column.duration) ?? 0,
            fileFormat: fileFormat,
            filePath: filePath,
            sourceID: sourceID,
            fileSize: row[Column.fileSize] as Int64? ?? 0,
            bitRate: row[Column.bitRate] as Int?,
            sampleRate: row[Column.sampleRate] as Int?,
            bitDepth: row[Column.bitDepth] as Int?,
            genre: text(Column.genre),
            year: row[Column.year] as Int?,
            lastModified: real(Column.lastModified).map(Date.init(timeIntervalSinceReferenceDate:)),
            dateAdded: Date(timeIntervalSinceReferenceDate: real(Column.dateAdded) ?? 0),
            serverPlayCount: row[Column.serverPlayCount] as Int?,
            coverArtFileName: text(Column.coverArtFileName),
            artistArtworkFileName: text(Column.artistArtworkFileName),
            lyricsFileName: text(Column.lyricsFileName),
            mvPath: rare.mvPath,
            replayGainTrackGain: rare.replayGainTrackGain,
            replayGainTrackPeak: rare.replayGainTrackPeak,
            replayGainAlbumGain: rare.replayGainAlbumGain,
            replayGainAlbumPeak: rare.replayGainAlbumPeak,
            cueSheetPath: rare.cueSheetPath,
            cueStartTime: rare.cueStartTime,
            cueEndTime: rare.cueEndTime,
            sacdTrackNumber: rare.sacdTrackNumber,
            isoAudioTrack: rare.isoAudioTrack,
            revision: text(Column.revision),
            titlePinyin: rare.titlePinyin,
            artistPinyin: rare.artistPinyin,
            albumPinyin: rare.albumPinyin,
            lyricsText: text(Column.lyricsText),
            userMetadataEditedAt: rare.userMetadataEditedAt,
            audioVariants: rare.audioVariants,
            serverLibraryID: rare.serverLibraryID,
            audioCodec: (row[Column.audioCodec] as String?).flatMap(AudioFormat.init(rawValue:)),
            effectiveBitDepth: row[Column.effectiveBitDepth] as Int?,
            serverDateAdded: real(Column.serverDateAdded).map(Date.init(timeIntervalSinceReferenceDate:)),
            serverAlbumDateAdded: rare.serverAlbumDateAdded,
            contentMetadata: rare.contentMetadata,
            serverCatalogAlbum: rare.serverCatalogAlbum,
            isExternal: rare.isExternal,
            sourceAlbumArtistNames: rare.sourceAlbumArtistNames
        )
        song.restoreStoredServerFilePath(row[Column.serverFilePath] as String?)
        return song
    }

    struct RareFields {
        var sourceArtistNames: [String]?
        var sourceAlbumArtistNames: [String]?
        var mvPath: String?
        var cueSheetPath: String?
        var cueStartTime: Double?
        var cueEndTime: Double?
        var sacdTrackNumber: Int?
        var isoAudioTrack: ISOAudioTrack?
        var titlePinyin: String?
        var artistPinyin: String?
        var albumPinyin: String?
        var userMetadataEditedAt: Date?
        var audioVariants: [AudioVariant]?
        var serverLibraryID: String?
        var serverAlbumDateAdded: Date?
        var contentMetadata: SongContentMetadata?
        var serverCatalogAlbum: ServerCatalogAlbumReference?
        var isExternal: Bool?
        var replayGainTrackGain: Double?
        var replayGainTrackPeak: Double?
        var replayGainAlbumGain: Double?
        var replayGainAlbumPeak: Double?
    }

    static func decodeRareFields(
        _ reader: inout ExtraReader,
        into rare: inout RareFields,
        strings: inout [Int: String],
        doubles: inout [Int: UInt64]
    ) throws {
        guard try reader.byte() == ExtraWriter.version else { throw LibraryCatalogError.corruptRow }
        func date(_ bits: UInt64) -> Date { Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits)) }
        while !reader.isAtEnd {
            let tag = try reader.byte()
            switch tag {
            case Tag.sourceArtistNames: rare.sourceArtistNames = try reader.strings()
            case Tag.sourceAlbumArtistNames: rare.sourceAlbumArtistNames = try reader.strings()
            case Tag.mvPath: rare.mvPath = try reader.string()
            case Tag.cueSheetPath: rare.cueSheetPath = try reader.string()
            case Tag.cueStartTime: rare.cueStartTime = Double(bitPattern: try reader.bits())
            case Tag.cueEndTime: rare.cueEndTime = Double(bitPattern: try reader.bits())
            case Tag.sacdTrackNumber: rare.sacdTrackNumber = Int(try reader.int())
            case Tag.isoAudioTrack:
                rare.isoAudioTrack = try jsonDecoder().decode(ISOAudioTrack.self, from: try reader.data())
            case Tag.titlePinyin: rare.titlePinyin = try reader.string()
            case Tag.artistPinyin: rare.artistPinyin = try reader.string()
            case Tag.albumPinyin: rare.albumPinyin = try reader.string()
            case Tag.userMetadataEditedAt: rare.userMetadataEditedAt = date(try reader.bits())
            case Tag.audioVariants:
                rare.audioVariants = try reader.strings().map { raw in
                    guard let variant = AudioVariant(rawValue: raw) else { throw LibraryCatalogError.corruptRow }
                    return variant
                }
            case Tag.serverLibraryID: rare.serverLibraryID = try reader.string()
            case Tag.serverAlbumDateAdded: rare.serverAlbumDateAdded = date(try reader.bits())
            case Tag.contentMetadata: rare.contentMetadata = try decodeContentMetadata(try reader.data())
            case Tag.serverCatalogAlbum:
                var payload = ExtraReader(try reader.data())
                rare.serverCatalogAlbum = ServerCatalogAlbumReference(
                    id: try payload.string(), taggedArtist: try payload.optionalString()
                )
            case Tag.isExternal: rare.isExternal = try reader.int() != 0
            case Tag.replayGainTrackGain: rare.replayGainTrackGain = Double(bitPattern: try reader.bits())
            case Tag.replayGainTrackPeak: rare.replayGainTrackPeak = Double(bitPattern: try reader.bits())
            case Tag.replayGainAlbumGain: rare.replayGainAlbumGain = Double(bitPattern: try reader.bits())
            case Tag.replayGainAlbumPeak: rare.replayGainAlbumPeak = Double(bitPattern: try reader.bits())
            case Tag.stringOverride..<(Tag.stringOverride + 0x20):
                strings[Int(tag - Tag.stringOverride)] = try reader.string()
            case Tag.doubleOverride..<(Tag.doubleOverride + 0x20):
                doubles[Int(tag - Tag.doubleOverride)] = try reader.bits()
            default:
                throw LibraryCatalogError.corruptRow
            }
        }
    }

    // MARK: - Grouping fields

    /// 分组维护读的几列(不解整首):专辑艺人推断的 `Track` 与专辑统计要用的字段。
    struct GroupingFields {
        let rowid: Int64
        let sourceKey: Int64
        let artistName: String?
        let albumTitle: String?
        let albumArtistName: String?
        let sourceAlbumArtistNames: [String]?
        let year: Int?
        let discNumber: Int?
        let trackNumber: Int?
        let serverCatalogAlbum: ServerCatalogAlbumReference?
        let userEdited: Bool
        let folderKey: Int64?
        let inferenceDirectory: String?
        let kind: Int
        let durationKey: Double
        let dateAdded: Double
        let titleHash: Int64?
        let effectiveAlbumRef: Int64?
        let genre: String?

        /// `AlbumArtistInferencePolicy.Track(song:directory:)` 的同一套取值;id 用行号。
        func track(sourceID: String, directory: String?) -> AlbumArtistInferencePolicy.Track {
            AlbumArtistInferencePolicy.Track(
                id: String(rowid),
                sourceID: sourceID,
                directory: directory,
                albumTitle: albumTitle,
                albumArtistName: albumArtistName,
                trackArtistName: artistName,
                year: year,
                discNumber: discNumber,
                trackNumber: trackNumber,
                serverAlbumID: serverCatalogAlbum?.id,
                taggedAlbumArtistName: serverCatalogAlbum.flatMap { userEdited ? albumArtistName : $0.taggedArtist }
            )
        }

        /// 不在服务器专辑里(推断按文件夹分)。与 `Track.serverAlbumID == nil` 同一口径(id 去空白后为空也算不在)。
        var isOutsideServerAlbum: Bool {
            guard let id = serverCatalogAlbum?.id else { return true }
            return id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `decodeGroupingFields` 读的列,顺序即下标。
    static let groupingColumns = """
        s.rowid, s.sourceKey, s.artistName, s.albumTitle, s.albumArtistName, s.year, s.discNumber, s.trackNumber,
        s.extra, s.folderKey, s.inferenceDirectory, s.kind, s.durationKey, s.dateAdded, s.titleHash, s.effectiveAlbumRef,
        s.genre
        """
    static let groupingColumnCount = 17

    static func decodeAlbumArtistFields(
        albumArtistColumn: String?,
        extraBlob: Data?
    ) throws -> (albumArtistName: String?, sourceAlbumArtistNames: [String]?) {
        guard let extraBlob else { return (albumArtistColumn, nil) }
        var reader = ExtraReader(extraBlob)
        var strings: [Int: String] = [:]
        var doubles: [Int: UInt64] = [:]
        var rare = RareFields()
        try decodeRareFields(&reader, into: &rare, strings: &strings, doubles: &doubles)
        return (strings[Column.albumArtistName] ?? albumArtistColumn, rare.sourceAlbumArtistNames)
    }

    static func decodeGroupingFields(_ row: Row) throws -> GroupingFields {
        var strings: [Int: String] = [:]
        var rare = RareFields()
        if let blob = row.dataNoCopy(atIndex: 8) {
            var reader = ExtraReader(blob)
            var doubles: [Int: UInt64] = [:]
            try decodeRareFields(&reader, into: &rare, strings: &strings, doubles: &doubles)
        }
        return GroupingFields(
            rowid: row[0],
            sourceKey: row[1],
            artistName: strings[Column.artistName] ?? row[2],
            albumTitle: strings[Column.albumTitle] ?? row[3],
            albumArtistName: strings[Column.albumArtistName] ?? row[4],
            sourceAlbumArtistNames: rare.sourceAlbumArtistNames,
            year: row[5],
            discNumber: row[6],
            trackNumber: row[7],
            serverCatalogAlbum: rare.serverCatalogAlbum,
            userEdited: rare.userMetadataEditedAt != nil,
            folderKey: row[9],
            inferenceDirectory: row[10],
            kind: row[11],
            durationKey: row[12],
            dateAdded: row[13],
            titleHash: row[14],
            effectiveAlbumRef: row[15],
            genre: strings[Column.genre] ?? row[16]
        )
    }

    private static func decodeContentMetadata(_ data: Data) throws -> SongContentMetadata {
        var reader = ExtraReader(data)
        let presence = try reader.byte()
        var value = SongContentMetadata()
        value.releaseType = presence & 1 != 0 ? try reader.string() : nil
        value.copyright = presence & 2 != 0 ? try reader.string() : nil
        value.iTunesAdvisory = presence & 4 != 0 ? Int(unzigzag(try reader.varint())) : nil
        value.isFileInspectionComplete = presence & 8 != 0
        value.embeddedChapterCount = presence & 16 != 0 ? Int(unzigzag(try reader.varint())) : nil
        if presence & 32 != 0 {
            value.embeddedMediaTracks = try jsonDecoder().decode(EmbeddedMediaTrackInventory.self, from: try reader.rawData())
        }
        return value
    }

    // MARK: - Extra blob

    enum Tag {
        static let sourceArtistNames: UInt8 = 0x01
        static let mvPath: UInt8 = 0x02
        static let cueSheetPath: UInt8 = 0x03
        static let cueStartTime: UInt8 = 0x04
        static let cueEndTime: UInt8 = 0x05
        static let sacdTrackNumber: UInt8 = 0x06
        static let isoAudioTrack: UInt8 = 0x07
        static let titlePinyin: UInt8 = 0x08
        static let artistPinyin: UInt8 = 0x09
        static let albumPinyin: UInt8 = 0x0A
        static let userMetadataEditedAt: UInt8 = 0x0B
        static let audioVariants: UInt8 = 0x0C
        static let serverLibraryID: UInt8 = 0x0D
        static let serverAlbumDateAdded: UInt8 = 0x0E
        static let contentMetadata: UInt8 = 0x0F
        static let serverCatalogAlbum: UInt8 = 0x10
        static let isExternal: UInt8 = 0x11
        static let replayGainTrackGain: UInt8 = 0x12
        static let replayGainTrackPeak: UInt8 = 0x13
        static let replayGainAlbumGain: UInt8 = 0x14
        static let replayGainAlbumPeak: UInt8 = 0x15
        static let sourceAlbumArtistNames: UInt8 = 0x16
        /// + 列下标(`Column`):该列字符串的原值。
        static let stringOverride: UInt8 = 0x40
        /// + 列下标:该列浮点数的原始位。
        static let doubleOverride: UInt8 = 0x60
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static func jsonDecoder() -> JSONDecoder { JSONDecoder() }

    static func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value << 1) ^ (value >> 63)) }
    static func unzigzag(_ value: UInt64) -> Int64 { Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1) }
}

struct ExtraWriter {
    static let version: UInt8 = 1
    private(set) var bytes: [UInt8] = []

    var isEmpty: Bool { bytes.isEmpty }
    var data: Data { Data(bytes) }

    private mutating func begin(_ tag: UInt8) {
        if bytes.isEmpty { bytes.append(Self.version) }
        bytes.append(tag)
    }

    mutating func byte(_ value: UInt8) { bytes.append(value) }

    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    mutating func rawString(_ value: String) {
        varint(UInt64(value.utf8.count))
        bytes.append(contentsOf: value.utf8)
    }

    mutating func rawOptionalString(_ value: String?) {
        guard let value else { return byte(0) }
        byte(1)
        rawString(value)
    }

    mutating func rawData(_ value: Data) {
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func string(_ tag: UInt8, _ value: String) {
        begin(tag)
        rawString(value)
    }

    mutating func strings(_ tag: UInt8, _ values: [String]) {
        begin(tag)
        varint(UInt64(values.count))
        for value in values { rawString(value) }
    }

    mutating func bits(_ tag: UInt8, _ value: UInt64) {
        begin(tag)
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func int(_ tag: UInt8, _ value: Int64) {
        begin(tag)
        varint(LibraryCatalogSongCodec.zigzag(value))
    }

    mutating func data(_ tag: UInt8, _ value: Data) {
        begin(tag)
        rawData(value)
    }
}

struct ExtraReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw LibraryCatalogError.corruptRow }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let next = try byte()
            guard shift < 64 else { throw LibraryCatalogError.corruptRow }
            result |= UInt64(next & 0x7F) << shift
            if next & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count - offset else { throw LibraryCatalogError.corruptRow }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func string() throws -> String {
        let count = Int(try varint())
        return String(decoding: try take(count), as: UTF8.self)
    }

    mutating func optionalString() throws -> String? {
        try byte() == 0 ? nil : try string()
    }

    mutating func strings() throws -> [String] {
        let count = Int(try varint())
        guard count <= bytes.count else { throw LibraryCatalogError.corruptRow }
        return try (0..<count).map { _ in try string() }
    }

    mutating func bits() throws -> UInt64 {
        let slice = try take(8)
        var value: UInt64 = 0
        for (shift, byte) in slice.enumerated() { value |= UInt64(byte) << (UInt64(shift) * 8) }
        return value
    }

    mutating func int() throws -> Int64 {
        LibraryCatalogSongCodec.unzigzag(try varint())
    }

    mutating func data() throws -> Data {
        let count = Int(try varint())
        return Data(try take(count))
    }

    mutating func rawData() throws -> Data { try data() }
}
