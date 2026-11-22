import Foundation
import ImageIO

/// Dependency-free metadata recovered from containers that AVFoundation does
/// not consistently inspect, especially when the caller only owns bounded
/// head/tail ranges from a remote file.
public struct EmbeddedTagMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var artists: [String]?
    public var albumTitle: String?
    public var releaseType: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var lyrics: String?
    public var lyricsLanguageCode: String?
    public var translatedLyrics: String?
    public var translatedLyricsLanguageCode: String?
    public var languageTaggedLyrics: [String: String]
    public var languageTaggedTranslations: [String: String]
    /// 不止一份原文歌词时按在文件里的先后都记下（`lyrics` 是按设置挑出来的那份），见 `EmbeddedLyricsVariantPolicy`。
    public var lyricsVariants: [EmbeddedLyricsVariant]
    public var lyricFields: [EmbeddedLyricField] = []
    public var coverArtData: Data?
    public var replayGainTrackGain: Double?
    public var replayGainTrackPeak: Double?
    public var replayGainAlbumGain: Double?
    public var replayGainAlbumPeak: Double?

    public init(
        title: String? = nil,
        artist: String? = nil,
        artists: [String]? = nil,
        albumTitle: String? = nil,
        releaseType: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        lyrics: String? = nil,
        lyricsLanguageCode: String? = nil,
        translatedLyrics: String? = nil,
        translatedLyricsLanguageCode: String? = nil,
        languageTaggedLyrics: [String: String] = [:],
        languageTaggedTranslations: [String: String] = [:],
        lyricsVariants: [EmbeddedLyricsVariant] = [],
        coverArtData: Data? = nil,
        replayGainTrackGain: Double? = nil,
        replayGainTrackPeak: Double? = nil,
        replayGainAlbumGain: Double? = nil,
        replayGainAlbumPeak: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.artists = artists
        self.albumTitle = albumTitle
        self.releaseType = releaseType
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.lyrics = lyrics
        self.lyricsLanguageCode = lyricsLanguageCode
        self.translatedLyrics = translatedLyrics
        self.translatedLyricsLanguageCode = translatedLyricsLanguageCode
        self.languageTaggedLyrics = languageTaggedLyrics
        self.languageTaggedTranslations = languageTaggedTranslations
        self.lyricsVariants = lyricsVariants
        self.coverArtData = coverArtData
        self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak
    }

    public var isEmpty: Bool {
        title == nil
            && artist == nil
            && albumTitle == nil
            && releaseType == nil
            && albumArtist == nil
            && trackNumber == nil
            && discNumber == nil
            && year == nil
            && genre == nil
            && lyrics == nil
            && translatedLyrics == nil
            && languageTaggedLyrics.isEmpty
            && languageTaggedTranslations.isEmpty
            && lyricFields.isEmpty
            && coverArtData == nil
            && replayGainTrackGain == nil
            && replayGainTrackPeak == nil
            && replayGainAlbumGain == nil
            && replayGainAlbumPeak == nil
    }

    mutating func fillMissing(from fallback: EmbeddedTagMetadata) {
        title = title ?? fallback.title
        artist = artist ?? fallback.artist
        artists = artists ?? fallback.artists
        albumTitle = albumTitle ?? fallback.albumTitle
        releaseType = releaseType ?? fallback.releaseType
        albumArtist = albumArtist ?? fallback.albumArtist
        trackNumber = trackNumber ?? fallback.trackNumber
        discNumber = discNumber ?? fallback.discNumber
        year = year ?? fallback.year
        genre = genre ?? fallback.genre
        EmbeddedLyricField.merge(fallback.lyricFields, into: &lyricFields)
        if lyrics == nil {
            lyrics = fallback.lyrics
            lyricsLanguageCode = fallback.lyricsLanguageCode
            lyricsVariants = fallback.lyricsVariants
        } else if lyrics == fallback.lyrics, lyricsLanguageCode == nil {
            lyricsLanguageCode = fallback.lyricsLanguageCode
        }
        if let chosen = EmbeddedLyricsVariantPolicy.merge(
            fallback.lyrics, languageCode: fallback.lyricsLanguageCode, variants: fallback.lyricsVariants,
            current: lyrics, currentLanguage: lyricsLanguageCode, into: &lyricsVariants, preferringIncomingOrder: false
        ) {
            lyrics = chosen.text
            lyricsLanguageCode = chosen.languageCode ?? lyricsLanguageCode
        }
        if translatedLyrics == nil {
            translatedLyrics = fallback.translatedLyrics
            translatedLyricsLanguageCode = fallback.translatedLyricsLanguageCode
        } else if translatedLyrics == fallback.translatedLyrics,
                  translatedLyricsLanguageCode == nil {
            translatedLyricsLanguageCode = fallback.translatedLyricsLanguageCode
        }
        languageTaggedLyrics.merge(fallback.languageTaggedLyrics) { current, _ in current }
        languageTaggedTranslations.merge(fallback.languageTaggedTranslations) { current, _ in
            current
        }
        coverArtData = coverArtData ?? fallback.coverArtData
        replayGainTrackGain = replayGainTrackGain ?? fallback.replayGainTrackGain
        replayGainTrackPeak = replayGainTrackPeak ?? fallback.replayGainTrackPeak
        replayGainAlbumGain = replayGainAlbumGain ?? fallback.replayGainAlbumGain
        replayGainAlbumPeak = replayGainAlbumPeak ?? fallback.replayGainAlbumPeak
    }
}

public enum EmbeddedTagMetadataParser {
    private static let maximumRangeByteCount = RemoteMetadataReadPolicy.maximumHeadByteCount
    private static let apeSignature = Data("APETAGEX".utf8)
    private static let id3Signature = Data("ID3".utf8)

    private static let originalLyricKeys = [
        "LYRICS", "SYNCEDLYRICS", "SYNCED LYRICS",
        "UNSYNCEDLYRICS", "UNSYNCED LYRICS", "WM/LYRICS",
    ]

    /// Keep the order across different keys as well as repeated values of one key.
    public static func metadata(fromOrderedTagValues fields: [(key: String, value: String)]) -> EmbeddedTagMetadata {
        var values: [String: [String]] = [:]
        var lyricFields: [EmbeddedLyricField] = []
        for field in fields {
            let key = normalizedKey(field.key)
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key, default: []].append(value)
            if let role = ISOBaseMediaLyricsParser.lyricFieldRole(field.key, text: value) {
                lyricFields.append(role.field(name: field.key, text: value))
            }
        }
        return metadata(from: values, orderedFields: lyricFields)
    }

    public static func metadata(fromLyricFields fields: [EmbeddedLyricField]) -> EmbeddedTagMetadata {
        metadata(from: [:], orderedFields: fields)
    }

    /// Resolves already-decoded text fields with the same mapping used by the
    /// container parsers. Callers that own a format-specific comment decoder
    /// can therefore preserve lyric translations without reimplementing the
    /// field-priority rules.
    public static func metadata(
        fromTagValues rawValues: [String: [String]]
    ) -> EmbeddedTagMetadata {
        var values: [String: [String]] = [:]
        for (rawKey, rawItems) in rawValues {
            let key = normalizedKey(rawKey)
            let items = rawItems.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if !key.isEmpty, !items.isEmpty {
                values[key, default: []].append(contentsOf: items)
            }
        }
        return metadata(from: values)
    }

    /// Parses format-specific tags from independently fetched ranges. The
    /// ranges are never concatenated because their absolute adjacency is not
    /// known; each container is inspected within its own bounded slice.
    public static func parse(
        head: Data,
        tail: Data? = nil,
        fileExtension: String
    ) -> EmbeddedTagMetadata? {
        let ext = normalizedExtension(fileExtension)
        var result = EmbeddedTagMetadata()
        let leadingID3Size = id3TagByteCount(in: head)
        if let leadingID3Size, leadingID3Size <= head.count {
            let fields = ID3EmbeddedLyrics.fields(in: head)
            if !fields.isEmpty { result.fillMissing(from: metadata(from: [:], orderedFields: fields)) }
        }
        let leadingAPE = leadingAPEItems(in: head)
        if let leadingAPE, leadingAPE.end <= head.count,
           let parsed = parseAPEItems(in: head, range: leadingAPE.items, count: leadingAPE.count) {
            result.fillMissing(from: parsed)
        }

        switch ext {
        case "flac":
            if let parsed = parseFLACComments(head) {
                result.fillMissing(from: parsed)
            }
        case "ogg", "opus", "speex":
            if let parsed = parseOggComments(head) {
                result.fillMissing(from: parsed)
            }
        case "mod", "xm", "it", "s3m", "stm", "mtm", "ptm":
            result.title = trackerModuleTitle(head, fileExtension: ext)
        case "wma":
            if let parsed = parseASF(head) {
                result.fillMissing(from: parsed)
            }
        case "wav", "wave":
            if let parsed = parseRIFFInfo(head) {
                result.fillMissing(from: parsed)
            }
            if let tail, let parsed = parseRIFFInfo(tail) {
                result.fillMissing(from: parsed)
            }
        case "aiff", "aif":
            if let parsed = parseAIFFText(head) {
                result.fillMissing(from: parsed)
            }
            if let tail, let parsed = parseAIFFText(tail) {
                result.fillMissing(from: parsed)
            }
        case "dff":
            for data in [head, tail].compactMap({ $0 }) {
                let chunks = dsdiffID3Chunks(in: data).map(ChunkField.id3)
                if let parsed = metadata(from: chunks) { result.fillMissing(from: parsed) }
            }
        default:
            break
        }

        let suffix = tail ?? head
        lazy var frameDuration = AudioFileSignaturePolicy.verifiedMPEGFrameDuration(in: head, from: leadingID3Size ?? leadingAPE?.end ?? 0)
        var suffixFields: [EmbeddedLyricField] = []
        let precedingFields = result.lyricFields
        for tag in trailingTags(in: suffix, fileExtension: ext).tags.reversed() {
            let parsed: EmbeddedTagMetadata?
            switch tag {
            case .id3(let range):
                if range.lowerBound == 0, leadingID3Size == range.count, (tail == nil || head == suffix) { continue }
                let fields = ID3EmbeddedLyrics.fields(in: suffix.subdata(in: range), mpegFrameDuration: frameDuration)
                parsed = metadata(from: [:], orderedFields: fields)
            case .ape(let footer):
                if let leadingAPE, leadingAPE.end == footer + 32, leadingAPE.items.upperBound == footer,
                   (tail == nil || head == suffix) { continue }
                let start = footer + 32 - readUInt32LE(suffix, at: footer + 12)
                parsed = parseAPEItems(in: suffix, range: start..<footer, count: readUInt32LE(suffix, at: footer + 16))
            case .lyrics3(let bodies):
                let texts = TextEncodingRepair.decodeTagValues(bodies.map { suffix.subdata(in: $0) })
                parsed = metadata(fromOrderedTagValues: texts.compactMap { $0.map { ("LYRICS3", $0) } })
            }
            if let parsed {
                suffixFields.append(contentsOf: parsed.lyricFields)
                result.fillMissing(from: parsed)
            }
        }
        if !suffixFields.isEmpty { result.lyricFields = precedingFields + suffixFields }

        return result.isEmpty ? nil : result
    }

    /// The song name every tracker stores at a fixed offset of its header,
    /// NUL- or space-padded 8-bit text. A module has no artist, album or
    /// cover field; composers who sign their work do it in sample names,
    /// which are free text and not read here.
    static func trackerModuleTitle(_ data: Data, fileExtension: String) -> String? {
        let field: (offset: Int, length: Int)
        switch fileExtension {
        case "xm":
            guard data.starts(with: Data("Extended Module: ".utf8)) else { return nil }
            field = (17, 20)
        case "it":
            guard data.starts(with: Data("IMPM".utf8)) else { return nil }
            field = (4, 26)
        case "mtm":
            guard data.starts(with: Data("MTM".utf8)) else { return nil }
            field = (4, 20)
        case "s3m":
            guard TrackerModuleSignature.ascii(data, at: 44, count: 4) == "SCRM" else { return nil }
            field = (0, 28)
        case "ptm":
            guard TrackerModuleSignature.ascii(data, at: 44, count: 4) == "PTMF" else { return nil }
            field = (0, 28)
        case "mod", "stm":
            // Neither has a tag at offset 0; the signature check vouches for
            // the header before the first 20 bytes are taken as a name.
            guard TrackerModuleSignature.matches(data) else { return nil }
            field = (0, 20)
        default:
            return nil
        }
        guard data.count >= field.offset + field.length else { return nil }
        let start = data.startIndex + field.offset
        let raw = data[start..<(start + field.length)].prefix { $0 != 0 }
        let title = String(decoding: raw.map { $0 < 0x20 ? 0x20 : $0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Latin-1 bytes that are not valid UTF-8 decode as U+FFFD; such a
        // name is better replaced by the file name than shown garbled.
        guard title.contains(where: { $0.isLetter || $0.isNumber }),
              !title.contains("\u{FFFD}") else { return nil }
        return title
    }

    /// Folds the tags an FFmpeg demuxer exported onto the shared field map.
    /// Used for containers no bounded parser here reads (Matroska/WebM,
    /// RealAudio, Wave64, RF64). Keys arrive in FFmpeg's spelling: mixed case,
    /// and for Matroska tags scoped to a target type, a prefix such as
    /// `ALBUM/TITLE` — which is the album name, not the song title.
    public static func parseContainerTags(
        _ entries: [(key: String, value: String)],
        coverArtData: Data? = nil
    ) -> EmbeddedTagMetadata? {
        let fields = entries.compactMap { entry -> (key: String, value: String)? in
            guard let key = containerTagKey(entry.key) else { return nil }
            return (key, entry.value)
        }
        var result = metadata(fromOrderedTagValues: fields)
        if result.coverArtData == nil, let coverArtData {
            result.coverArtData = normalizedImageData(coverArtData)
        }
        return result.isEmpty ? nil : result
    }

    private static func containerTagKey(_ rawKey: String) -> String? {
        let key = normalizedKey(rawKey)
        guard let slash = key.lastIndex(of: "/") else {
            switch key {
            // Matroska's own names, where FFmpeg left them unconverted.
            case "PART_NUMBER": return "TRACKNUMBER"
            case "DATE_RELEASED", "DATE_RECORDED": return "DATE"
            default: return key
            }
        }
        let name = String(key[key.index(after: slash)...])
        switch key[..<slash] {
        case "ALBUM":
            switch name {
            case "TITLE": return "ALBUM"
            case "ARTIST": return "ALBUMARTIST"
            case "DATE", "DATE_RELEASED", "DATE_RECORDED": return "DATE"
            case "GENRE": return "GENRE"
            default: return nil
            }
        case "TRACK", "SONG":
            return containerTagKey(name)
        case "PART", "SESSION":
            return name == "PART_NUMBER" ? "DISCNUMBER" : nil
        default:
            // `WM/…` and other vendor keys contain a slash of their own.
            return key
        }
    }

    /// Returns the next exact/bounded prefix size required to complete an ASF
    /// header or an Ogg comment packet. A nil result means the relevant tag
    /// region is already complete or the format has no head-size declaration.
    public static func expandedHeadReadSize(
        fileSize: Int64,
        currentData: Data,
        fileExtension: String
    ) -> Int? {
        let ext = normalizedExtension(fileExtension)
        let fileLimit = boundedFileLimit(fileSize)
        guard currentData.count < fileLimit else { return nil }

        if let header = leadingAPEItems(in: currentData), header.end > currentData.count {
            return min(fileLimit, header.end)
        }
        if ext == "wma", let declared = asfHeaderByteCount(in: currentData) {
            let wanted = min(fileLimit, declared)
            return wanted > currentData.count ? wanted : nil
        }

        guard ["ogg", "opus", "speex"].contains(ext) else { return nil }
        guard let required = scanOggComments(currentData).nextReadSize else { return nil }
        let doubled = max(currentData.count + 64 * 1024, currentData.count * 2)
        let wanted = min(fileLimit, max(doubled, required))
        return wanted > currentData.count ? wanted : nil
    }

    /// Both APE and Lyrics3v2 declare their size at EOF, optionally before ID3v1.
    public static func expandedTailReadSize(
        fileSize: Int64,
        currentData: Data,
        fileExtension: String
    ) -> Int? {
        guard let needed = trailingTags(in: currentData, fileExtension: normalizedExtension(fileExtension)).needed else { return nil }
        let wanted = min(boundedFileLimit(fileSize), needed)
        return wanted > currentData.count ? wanted : nil
    }

    /// DSF stores an absolute ID3 pointer in its fixed 28-byte `DSD ` header.
    public static func dsfMetadataOffset(in data: Data) -> Int64? {
        guard data.count >= 28,
              data.prefix(4).elementsEqual(Data("DSD ".utf8)) else {
            return nil
        }
        let offset = readUInt64LE(data, at: 20)
        guard offset > 0, offset <= UInt64(Int64.max) else { return nil }
        return Int64(offset)
    }

    /// Extracts a structurally complete ID3v2 tag embedded in DSF/DFF, AIFF,
    /// or RIFF/WAVE ranges. The caller can then reuse its full ID3 text/artwork
    /// decoder rather than maintaining container-specific frame mappings.
    public static func embeddedID3Data(
        head: Data,
        tail: Data? = nil,
        fileExtension: String
    ) -> Data? {
        let ext = normalizedExtension(fileExtension)

        if ext == "wav" || ext == "wave" {
            if let tag = riffID3Chunk(in: head) { return tag }
            if let tail, let tag = riffID3Chunk(in: tail) { return tag }
        } else if ext == "aiff" || ext == "aif" || ext == "dff" {
            if let tag = bigEndianID3Chunk(in: head, dsdiff: ext == "dff") { return tag }
            if let tail, let tag = bigEndianID3Chunk(in: tail, dsdiff: ext == "dff") { return tag }
        } else {
            if let tag = completeLeadingID3Tag(in: head) { return tag }
            if let tail, let tag = completeTrailingID3Tag(in: tail) { return tag }
            return nil
        }

        if let tag = completeID3Tag(in: head) { return tag }
        if let tail, let tag = completeID3Tag(in: tail) { return tag }
        return nil
    }

    public static func id3TagByteCount(in data: Data) -> Int? {
        guard data.count >= 10,
              data.prefix(3).elementsEqual(id3Signature),
              (2...4).contains(data[3]),
              data[6] < 0x80, data[7] < 0x80,
              data[8] < 0x80, data[9] < 0x80 else {
            return nil
        }
        let payload = (Int(data[6]) << 21)
            | (Int(data[7]) << 14)
            | (Int(data[8]) << 7)
            | Int(data[9])
        let footer = (data[5] & 0x10) != 0 ? 10 : 0
        let (count, overflow) = 10.addingReportingOverflow(payload + footer)
        return overflow ? nil : count
    }

    // MARK: - Ogg/Vorbis comments

    private struct OggCommentScan {
        enum Packet { case payload(Data), fields([EmbeddedLyricField]) }
        var packets: [Packet] = []
        var nextReadSize: Int?
    }

    private enum OggHeaderPhase {
        case identify, vorbis, opus, speex, flac, complete

        mutating func commentOffset(prefix bytes: Data, packetSize: Int) -> Int? {
            if self == .identify {
                if bytes.starts(with: [0x01] + "vorbis".utf8) { self = .vorbis; return nil }
                if bytes.starts(with: "OpusHead".utf8) { self = .opus; return nil }
                if bytes.starts(with: "Speex   ".utf8) { self = .speex; return nil }
                if bytes.starts(with: [0x7F] + "FLAC".utf8 + [1]) { self = .flac; return nil }
            }
            defer { self = .complete }
            if (self == .vorbis || self == .identify), bytes.starts(with: [0x03] + "vorbis".utf8) { return 7 }
            if (self == .opus || self == .identify), bytes.starts(with: "OpusTags".utf8) { return 8 }
            if self == .speex { return 0 }
            if self == .flac, bytes.count >= 4, bytes[0] & 0x7f == 4 {
                let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
                if length == packetSize - 4 { return 4 }
            }
            return nil
        }
    }

    private static func scanOggComments(_ data: Data, collecting: Bool = false) -> OggCommentScan {
        var result = OggCommentScan()
        var streams: [Int: SparseOggStream] = [:]
        var cursor = 0
        while cursor < data.count {
            guard cursor <= data.count - 27 else { result.nextReadSize = cursor + 27; return result }
            guard data[cursor..<(cursor + 4)].elementsEqual("OggS".utf8), data[cursor + 4] == 0 else { return result }
            let flags = data[cursor + 5]
            let serial = readUInt32LE(data, at: cursor + 14)
            let sequence = UInt32(readUInt32LE(data, at: cursor + 18))
            let tableStart = cursor + 27
            let tableEnd = tableStart + Int(data[cursor + 26])
            guard tableEnd <= data.count else { result.nextReadSize = tableEnd; return result }
            let lacing = data[tableStart..<tableEnd]
            let pageEnd = lacing.reduce(tableEnd) { $0 + Int($1) }
            guard pageEnd <= data.count else { result.nextReadSize = pageEnd; return result }

            var stream = streams.removeValue(forKey: serial) ?? SparseOggStream()
            let continuation = flags & 1 != 0
            var skipPartial = continuation && (stream.size == 0 || stream.sequence != sequence)
            if !continuation || skipPartial { stream.resetPacket() }
            stream.sequence = sequence &+ 1
            var offset = tableEnd
            for lace in lacing {
                guard stream.phase != .complete else { break }
                let length = Int(lace)
                if !skipPartial {
                    stream.append(Int64(offset)..<Int64(offset + length))
                    if length < 255, let packet = stream.finish(in: data, collecting: collecting) { result.packets.append(packet) }
                } else if length < 255 { skipPartial = false }
                offset += length
            }
            streams[serial] = stream
            cursor = pageEnd
            // All BOS pages of multiplexed streams precede their other pages.
            if flags & 2 == 0, streams.values.allSatisfy({ $0.phase == .complete }) { return result }
        }
        if streams.isEmpty || streams.values.contains(where: { $0.phase != .complete }) {
            result.nextReadSize = cursor + 27
        }
        return result
    }

    private static func parseFLACComments(_ data: Data) -> EmbeddedTagMetadata? {
        let start = id3TagByteCount(in: data) ?? 0
        guard start <= data.count - 4, data[start..<(start + 4)].elementsEqual("fLaC".utf8) else { return nil }
        var cursor = start + 4
        var fields: [(key: String, value: String)] = []
        while cursor + 4 <= data.count {
            let header = data[cursor]
            let count = Int(data[cursor + 1]) << 16 | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            cursor += 4
            guard count <= data.count - cursor else { break }
            if header & 0x7f == 4,
               let comments = parseVorbisCommentList(data.subdata(in: cursor..<(cursor + count))) {
                fields.append(contentsOf: comments)
            }
            cursor += count
            if header & 0x80 != 0 { break }
        }
        return fields.isEmpty ? nil : metadata(fromOrderedTagValues: fields)
    }

    private static func parseOggComments(_ data: Data) -> EmbeddedTagMetadata? {
        var result = EmbeddedTagMetadata()
        var fields: [EmbeddedLyricField] = []
        for packet in scanOggComments(data, collecting: true).packets {
            let parsed: EmbeddedTagMetadata
            switch packet {
            case .payload(let bytes):
                guard let values = parseVorbisCommentList(bytes) else { continue }
                parsed = metadata(fromOrderedTagValues: values)
            case .fields(let lyrics):
                parsed = metadata(fromLyricFields: lyrics)
            }
            fields.append(contentsOf: parsed.lyricFields)
            result.fillMissing(from: parsed)
        }
        result.lyricFields = fields
        return result.isEmpty ? nil : result
    }

    private static func parseVorbisCommentList(_ data: Data) -> [(key: String, value: String)]? {
        var cursor = 0
        guard let vendorLength = readBoundedUInt32LE(data, at: cursor) else { return nil }
        cursor += 4
        guard vendorLength <= data.count - cursor else { return nil }
        cursor += vendorLength
        guard let count = readBoundedUInt32LE(data, at: cursor), count <= 100_000 else {
            return nil
        }
        cursor += 4
        var fields: [(key: String, value: Data)] = []
        for _ in 0..<count {
            guard let length = readBoundedUInt32LE(data, at: cursor) else { return nil }
            cursor += 4
            guard length <= data.count - cursor else { return nil }
            let item = data.subdata(in: cursor..<(cursor + length))
            cursor += length
            if let field = vorbisCommentField(item) { fields.append(field) }
        }
        var comments: [(key: String, value: String)] = []
        for (field, decoded) in zip(fields, TextEncodingRepair.decodeTagValues(fields.map(\.value))) {
            if let decoded { comments.append((field.key, decoded)) }
        }
        return comments
    }

    /// 一条 Vorbis 注释 `KEY=value`, 值还是原始字节, 编码交给 `TextEncodingRepair.decodeTagValues`
    /// 按整块标签判。0x3D 不会出现在 UTF-8 多字节字符里, 也不会是 GBK / Big5 / Shift_JIS
    /// 双字节字的后半, 按字节找第一个「=」切开是安全的。
    public static func vorbisCommentField(_ item: Data) -> (key: String, value: Data)? {
        guard let separator = item.firstIndex(of: 0x3D),
              let key = String(data: item[item.startIndex..<separator], encoding: .utf8) else {
            return nil
        }
        return (key, Data(item[item.index(after: separator)...]))
    }

    /// The prefix parser can read a whole small tag. A range reader can also step over an
    /// embedded picture without allocating it or losing the comments that follow it.
    public static func rangedCommentLyrics(head: Data, tail: Data?, fileSize: Int64, fileExtension: String,
                                            fetch: (Int64, Int64) async throws -> Data) async throws -> [EmbeddedLyricField] {
        guard fileSize > 0 else { return [] }
        func read(_ offset: Int64, _ count: Int) async throws -> Data {
            guard offset >= 0, count >= 0, Int64(count) <= fileSize - offset else { throw URLError(.cannotParseResponse) }
            if let tail, tail.count <= fileSize, offset >= fileSize - Int64(tail.count) {
                let start = tail.startIndex + Int(offset - (fileSize - Int64(tail.count)))
                return tail.subdata(in: start..<(start + count))
            }
            return try await tagBytes(head: head, at: offset, count: count, fetch: fetch)
        }
        let ext = normalizedExtension(fileExtension)
        var fields: [EmbeddedLyricField] = []
        if head.starts(with: "OggS".utf8) {
            fields = try await rangedOggLyrics(fileSize: fileSize, read: read)
        }
        if tail != nil || head.starts(with: apeSignature) ||
            ["ape", "wv", "mp3", "mp2", "mp1", "mpa", "m2a", "mpc", "tak", "tta", "dts", "ac3"].contains(ext) {
            fields += try await rangedAPELyrics(head: head, fileSize: fileSize, read: read)
        }
        return fields
    }

    private typealias TagRead = (Int64, Int) async throws -> Data

    private struct SparseCommentFields {
        var fields: [EmbeddedLyricField] = []
        private var values: [(key: String, bytes: Data)] = []
        private var byteCount = 0

        mutating func append(key: String, bytes: Data) {
            if byteCount + bytes.count > maximumRangeByteCount { flush() }
            values.append((key, bytes))
            byteCount += bytes.count
        }

        mutating func flush() {
            let decoded = TextEncodingRepair.decodeTagValues(values.map(\.bytes))
            let entries = zip(values, decoded).compactMap { value, text in text.map { (value.key, $0) } }
            fields.append(contentsOf: metadata(fromOrderedTagValues: entries).lyricFields)
            values = []
            byteCount = 0
        }
    }

    private static func isPictureField(_ key: String) -> Bool {
        let key = normalizedKey(key)
        return key.hasPrefix("COVER ART") || ["COVERART", "METADATA_BLOCK_PICTURE", "FRONT COVER", "BACK COVER"].contains(key)
    }

    /// A packet can be scattered across pages and interleaved with other logical streams.
    /// The cursor advances across physical spans even when a field is skipped.
    private struct OggPacketCursor {
        let spans: [Range<Int64>]
        var remaining: Int
        var index = 0
        var usedInSpan = 0

        mutating func take(_ count: Int) -> [Range<Int64>]? {
            guard count >= 0, count <= remaining else { return nil }
            var result: [Range<Int64>] = []
            var left = count
            while left > 0, index < spans.count {
                let span = spans[index]
                let start = span.lowerBound + Int64(usedInSpan)
                let used = min(left, span.count - usedInSpan)
                result.append(start..<(start + Int64(used)))
                usedInSpan += used
                if usedInSpan == span.count { index += 1; usedInSpan = 0 }
                left -= used
            }
            guard left == 0 else { return nil }
            remaining -= count
            return result
        }

    }

    private struct VorbisFieldReader {
        enum Step { case vendorLength, count, length, prefix(Int), value(Data, Int) }
        var cursor: OggPacketCursor
        var step: Step? = .vendorLength
        var remainingFields = 0

        mutating func nextSpans() -> [Range<Int64>]? {
            switch step {
            case .vendorLength, .count, .length: return cursor.take(4)
            case .prefix(let size): return cursor.take(min(256, size))
            case .value(_, let rest): return cursor.take(rest)
            case nil: return nil
            }
        }

        mutating func accept(_ data: Data, into comments: inout SparseCommentFields) {
            switch step {
            case .vendorLength:
                step = cursor.take(readUInt32LE(data, at: 0)) == nil ? nil : .count
            case .count:
                remainingFields = readUInt32LE(data, at: 0)
                step = (1...100_000).contains(remainingFields) && remainingFields <= cursor.remaining / 4 ? .length : nil
            case .length:
                let size = readUInt32LE(data, at: 0)
                guard size <= cursor.remaining else { step = nil; return }
                if size > maximumRangeByteCount { _ = cursor.take(size); finishField() }
                else { step = .prefix(size) }
            case .prefix(let size):
                let rest = size - data.count
                if let field = vorbisCommentField(data), isPictureField(field.key) {
                    _ = cursor.take(rest)
                    finishField()
                } else { step = .value(data, rest) }
            case .value(let prefix, _):
                if let field = vorbisCommentField(prefix + data) { comments.append(key: field.key, bytes: field.value) }
                finishField()
            case nil: break
            }
        }

        mutating func finishField() {
            remainingFields -= 1
            step = remainingFields > 0 ? .length : nil
        }
    }

    private struct SparseOggStream {
        var phase: OggHeaderPhase = .identify
        var sequence: UInt32?
        var spans: [Range<Int64>] = []
        var size = 0

        mutating func append(_ span: Range<Int64>) {
            guard !span.isEmpty else { return }
            if let last = spans.last, last.upperBound == span.lowerBound {
                spans[spans.count - 1] = last.lowerBound..<span.upperBound
            } else { spans.append(span) }
            size += span.count
        }

        mutating func resetPacket() { spans = []; size = 0 }

        mutating func finish(in data: Data, collecting: Bool) -> OggCommentScan.Packet? {
            defer { resetPacket() }
            func bytes(_ spans: [Range<Int64>]) -> Data {
                spans.reduce(into: Data()) { bytes, span in
                    bytes.append(contentsOf: data[Int(span.lowerBound)..<Int(span.upperBound)])
                }
            }
            var cursor = OggPacketCursor(spans: spans, remaining: size)
            var probe = cursor
            guard let prefix = probe.take(min(8, size)), let start = phase.commentOffset(prefix: bytes(prefix), packetSize: size),
                  collecting, cursor.take(start) != nil else { return nil }
            if size <= maximumRangeByteCount, let spans = cursor.take(cursor.remaining) { return .payload(bytes(spans)) }
            var parser = VorbisFieldReader(cursor: cursor)
            var comments = SparseCommentFields()
            while let spans = parser.nextSpans() { parser.accept(bytes(spans), into: &comments) }
            comments.flush()
            return .fields(comments.fields)
        }

        mutating func finish(into comments: inout SparseCommentFields, read: TagRead) async throws {
            defer { resetPacket() }
            func bytes(_ spans: [Range<Int64>]) async throws -> Data {
                var result = Data()
                for span in spans { result.append(try await read(span.lowerBound, span.count)) }
                return result
            }
            var cursor = OggPacketCursor(spans: spans, remaining: size)
            var probe = cursor
            guard let prefix = probe.take(min(8, size)), let start = phase.commentOffset(prefix: try await bytes(prefix), packetSize: size),
                  cursor.take(start) != nil else { return }
            var parser = VorbisFieldReader(cursor: cursor)
            while let spans = parser.nextSpans() { parser.accept(try await bytes(spans), into: &comments) }
        }
    }

    private static func rangedOggLyrics(fileSize: Int64, read: TagRead) async throws -> [EmbeddedLyricField] {
        var streams: [Int: SparseOggStream] = [:]
        var offset: Int64 = 0
        var comments = SparseCommentFields()
        var inspected = 0
        while offset <= fileSize - 27, inspected < maximumRangeByteCount {
            try Task.checkCancellation()
            let header = try await read(offset, Int(min(282, fileSize - offset)))
            guard header.starts(with: "OggS".utf8), header[4] == 0 else { break }
            let count = Int(header[26])
            guard header.count >= 27 + count else { break }
            inspected += header.count
            let flags = header[5]
            let serial = readUInt32LE(header, at: 14)
            let sequence = UInt32(readUInt32LE(header, at: 18))
            let lacing = header[27..<(27 + count)]
            let body = offset + Int64(27 + count)
            let size = lacing.reduce(0) { $0 + Int($1) }
            guard Int64(size) <= fileSize - body else { break }
            offset = body + Int64(size)
            var stream = streams.removeValue(forKey: serial) ?? SparseOggStream()
            let continuation = flags & 1 != 0
            var skip = continuation && (stream.size == 0 || stream.sequence != sequence)
            if !continuation || skip { stream.resetPacket() }
            stream.sequence = sequence &+ 1
            var location = body
            for lace in lacing where stream.phase != .complete {
                let end = location + Int64(lace)
                if !skip {
                    stream.append(location..<end)
                    if lace < 255 { try await stream.finish(into: &comments, read: read) }
                } else if lace < 255 { skip = false }
                location = end
            }
            streams[serial] = stream
            if flags & 2 == 0, streams.values.allSatisfy({ $0.phase == .complete }) { break }
        }
        comments.flush()
        return comments.fields
    }

    // MARK: - APEv2

    private static func rangedAPELyrics(head: Data, fileSize: Int64, read: TagRead) async throws -> [EmbeddedLyricField] {
        guard fileSize >= 32 else { return [] }
        var regions: [Int64: (end: Int64, count: Int)] = [:]
        if head.starts(with: apeSignature) {
            let header = try await read(0, 32)
            let flags = readUInt32LE(header, at: 20)
            let size = Int64(readUInt32LE(header, at: 12))
            let footer: Int64 = flags & 0x40000000 == 0 ? 32 : 0
            if flags & 0xa0000000 == 0xa0000000, readUInt32LE(header, at: 8) == 2_000,
               size >= footer, size <= fileSize - 32 {
                let end = 32 + size - footer
                let validFooter = footer == 0 ? true : try await read(end, 8).elementsEqual(apeSignature)
                if validFooter { regions[32] = (end, readUInt32LE(header, at: 16)) }
            }
        }
        var end = fileSize
        if end >= 128, try await read(end - 128, 3).elementsEqual("TAG".utf8) { end -= 128 }
        while end >= 32 {
            try Task.checkCancellation()
            let footer = try await read(end - 32, 32)
            if footer.starts(with: apeSignature), (1_000...2_000).contains(readUInt32LE(footer, at: 8)) {
                let size = Int64(readUInt32LE(footer, at: 12))
                let flags = readUInt32LE(footer, at: 20)
                guard size >= 32, size <= end, flags & 0x20000000 == 0 else { break }
                let start = end - size
                regions[start] = (end - 32, readUInt32LE(footer, at: 16))
                end = start
                if flags & 0x80000000 != 0, end >= 32, try await read(end - 32, 8).elementsEqual(apeSignature) { end -= 32 }
            } else if footer.suffix(9).elementsEqual("LYRICS200".utf8), let size = decimal(footer[17..<23]) {
                let start = end - 15 - Int64(size)
                guard size >= lyrics3Begin.count, start >= 0, try await read(start, lyrics3Begin.count) == lyrics3Begin else { break }
                end = start
            } else if footer[22..<25].elementsEqual("3DI".utf8), footer[25] == 4, footer[27] & 0x10 != 0 {
                let header = id3Signature + footer[25..<32]
                guard let size = id3TagByteCount(in: header), size <= end,
                      try await read(end - Int64(size), 10) == header else { break }
                end -= Int64(size)
            } else { break }
        }

        var comments = SparseCommentFields()
        for (start, region) in regions.sorted(by: { $0.key < $1.key }) {
            var offset = start
            guard region.count <= 100_000, Int64(region.count) <= (region.end - start) / 9 else { continue }
            for _ in 0..<region.count {
                try Task.checkCancellation()
                guard offset <= region.end - 9 else { break }
                let header = try await read(offset, Int(min(264, region.end - offset)))
                guard let keyEnd = header[8...].firstIndex(of: 0), keyEnd > 8,
                      let key = String(data: header[8..<keyEnd], encoding: .utf8) else { break }
                let size = readUInt32LE(header, at: 0)
                let valueType = (readUInt32LE(header, at: 4) >> 1) & 3
                let valueStart = offset + Int64(keyEnd + 1)
                guard Int64(size) <= region.end - valueStart else { break }
                offset = valueStart + Int64(size)
                guard valueType <= 1, size <= maximumRangeByteCount, !isPictureField(key) else { continue }
                let value = try await read(valueStart, size)
                if valueType == 0 {
                    for part in value.split(separator: 0) { comments.append(key: key, bytes: Data(part)) }
                } else if let field = binaryLyricText(in: value, name: key) {
                    comments.append(key: field.key, bytes: Data(field.value.utf8))
                }
            }
        }
        comments.flush()
        return comments.fields
    }

    private static func leadingAPEItems(in data: Data) -> (items: Range<Int>, count: Int, end: Int)? {
        guard data.count >= 32, data.starts(with: apeSignature), readUInt32LE(data, at: 8) == 2_000 else { return nil }
        let flags = readUInt32LE(data, at: 20)
        guard flags & 0xa0000000 == 0xa0000000 else { return nil }
        let size = readUInt32LE(data, at: 12)
        let footerSize = flags & 0x40000000 == 0 ? 32 : 0
        guard size >= footerSize, size <= max(data.count, maximumRangeByteCount) - 32 else { return nil }
        let end = 32 + size
        if footerSize == 32 && end <= data.count,
           !data[(end - 32)..<(end - 24)].elementsEqual(apeSignature) { return nil }
        return (32..<(end - footerSize), readUInt32LE(data, at: 16), end)
    }

    private static func parseAPEItems(in data: Data, range: Range<Int>, count: Int) -> EmbeddedTagMetadata? {
        guard count <= 100_000 else { return nil }
        let end = range.upperBound
        var cursor = range.lowerBound
        if cursor + 32 <= end, data[cursor..<(cursor + 8)].elementsEqual(apeSignature) {
            cursor += 32
        }

        var fields: [(key: String, value: String)] = []
        var textItems: [(key: String, values: [Data])] = []
        var cover: Data?
        for _ in 0..<count {
            guard cursor + 8 <= end else { return nil }
            let valueSize = readUInt32LE(data, at: cursor)
            let flags = readUInt32LE(data, at: cursor + 4)
            cursor += 8
            guard let keyEnd = data[cursor..<end].firstIndex(of: 0) else { return nil }
            let keyData = data.subdata(in: cursor..<keyEnd)
            cursor = keyEnd + 1
            guard valueSize <= end - cursor else { return nil }
            let valueStart = cursor
            cursor += valueSize
            guard valueSize <= maximumRangeByteCount else { continue }
            let value = data.subdata(in: valueStart..<cursor)
            guard let rawKey = String(data: keyData, encoding: .utf8) else { continue }
            let key = normalizedKey(rawKey)
            let valueType = (flags >> 1) & 0x03
            if valueType == 0 {
                let pieces = value.split(separator: 0, omittingEmptySubsequences: true).map { Data($0) }
                if !pieces.isEmpty { textItems.append((rawKey, pieces)) }
            } else if valueType == 1,
                      ["COVER ART (FRONT)", "COVERART", "FRONT COVER"].contains(key),
                      cover == nil {
                let imageStart = value.firstIndex(of: 0).map { $0 + 1 } ?? 0
                if imageStart < value.count {
                    cover = normalizedImageData(value.subdata(in: imageStart..<value.count))
                }
            } else if valueType == 1, let field = binaryLyricText(in: value, name: rawKey) {
                textItems.append((field.key, [Data(field.value.utf8)]))
            }
        }

        // 和 Vorbis 注释一样, 千千静听等老工具写的 GBK / Big5 值按整块标签判编码。
        var decoded = TextEncodingRepair.decodeTagValues(textItems.flatMap(\.values))[...]
        for item in textItems {
            let strings = decoded.prefix(item.values.count)
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            decoded = decoded.dropFirst(item.values.count)
            fields.append(contentsOf: strings.map { (item.key, $0) })
        }

        var metadata = metadata(fromOrderedTagValues: fields)
        metadata.coverArtData = metadata.coverArtData ?? cover
        return metadata.isEmpty ? nil : metadata
    }

    private static func binaryLyricText(in data: Data, name: String) -> (key: String, value: String)? {
        guard !data.isEmpty, data.count <= LyricsRawDocumentPolicy.maximumByteCount else { return nil }
        var bytes = data
        var key = name
        // Some attachments prefix their document with a NUL-terminated file name.
        if let separator = data.prefix(256).firstIndex(of: 0), separator > 0,
           let filename = String(data: data.prefix(separator), encoding: .utf8), LyricsDocumentFormat(fileName: filename) != nil {
            if ISOBaseMediaLyricsParser.lyricFieldRole(key) == nil { key = filename }
            bytes = Data(data.dropFirst(separator + 1))
        }
        let declared = ISOBaseMediaLyricsParser.lyricFieldRole(key) != nil
        if !declared {
            let first = bytes.prefix(128).first { ![9, 10, 13, 32].contains($0) }
            guard let first, "[<0123456789WD".utf8.contains(first) || [0, 0xef, 0xfe, 0xff].contains(first) else { return nil }
        }
        guard let text = TextEncodingRepair.decodeTextFile(bytes)?.text,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              declared || ISOBaseMediaLyricsParser.lyricFieldRole(key, text: text) != nil else { return nil }
        return (key, text)
    }

    private enum TrailingTag {
        case ape(footer: Int)
        case id3(Range<Int>)
        case lyrics3(bodies: [Range<Int>])
    }

    private static let lyrics3Begin = Data("LYRICSBEGIN".utf8)

    /// Walk adjacent footer-delimited tags backwards. Signatures found in the
    /// audio body or inside a field never establish another tag boundary.
    private static func trailingTags(in data: Data, fileExtension: String) -> (tags: [TrailingTag], needed: Int?) {
        var tags: [TrailingTag] = []
        var end = data.count
        if end >= 128, data[(end - 128)..<(end - 125)].elementsEqual("TAG".utf8) { end -= 128 }
        let allowsLyrics3 = ["mp3", "mp2", "mp1", "mpa", "m2a"].contains(fileExtension)
        while end >= 9 {
            let footer = end - 32
            if footer >= 0, data[footer..<(footer + 8)].elementsEqual(apeSignature),
               (1_000...2_000).contains(readUInt32LE(data, at: footer + 8)) {
                let size = readUInt32LE(data, at: footer + 12)
                let flags = readUInt32LE(data, at: footer + 20)
                guard size >= 32, size <= max(maximumRangeByteCount, end), flags & 0x20000000 == 0 else { break }
                let headerSize = flags & 0x80000000 == 0 ? 0 : 32
                let start = end - size
                guard start >= 0 else { return (tags, size + max(128, data.count - end + headerSize)) }
                tags.append(.ape(footer: footer))
                end = start
                if headerSize > 0, start >= 32, data[(start - 32)..<(start - 24)].elementsEqual(apeSignature) {
                    end -= 32
                }
                continue
            }
            guard allowsLyrics3 else { break }
            if end >= 10, data[(end - 10)..<(end - 7)].elementsEqual("3DI".utf8),
               data[end - 7] == 4, data[end - 5] & 0x10 != 0 {
                let header = id3Signature + data[(end - 7)..<end]
                guard let length = id3TagByteCount(in: header), length <= max(maximumRangeByteCount, end) else { break }
                let start = end - length
                guard start >= 0 else { return (tags, data.count - end + length) }
                guard data[start..<(start + 10)].elementsEqual(header) else { break }
                tags.append(.id3(start..<end))
                end = start
                continue
            }
            let marker = data[(end - 9)..<end]
            if marker.elementsEqual("LYRICS200".utf8), end >= 15,
               let size = decimal(data[(end - 15)..<(end - 9)]), size >= lyrics3Begin.count {
                let payloadEnd = end - 15
                let start = payloadEnd - size
                guard start >= 0 else { return (tags, data.count - end + 15 + size) }
                guard data[start..<(start + lyrics3Begin.count)].elementsEqual(lyrics3Begin),
                      let bodies = lyrics3Fields(in: data, range: (start + lyrics3Begin.count)..<payloadEnd) else { break }
                tags.append(.lyrics3(bodies: bodies))
                end = start
            } else if marker.elementsEqual("LYRICSEND".utf8) {
                let payloadEnd = end - 9
                let lowerBound = max(0, payloadEnd - 5_100 - lyrics3Begin.count)
                guard let start = data.range(of: lyrics3Begin, in: lowerBound..<payloadEnd) else {
                    return (tags, data.count - end + 9 + 5_100 + lyrics3Begin.count)
                }
                let body = start.upperBound..<payloadEnd
                guard !data[body].contains(0), !data[body].contains(255) else { break }
                tags.append(.lyrics3(bodies: [body]))
                end = start.lowerBound
            } else if let range = trailingID3Range(in: data, endingAt: end) {
                tags.append(.id3(range))
                end = range.lowerBound
            } else { break }
        }
        return (tags, nil)
    }

    private static func decimal(_ bytes: Data.SubSequence) -> Int? {
        var value = 0
        for byte in bytes {
            guard (48...57).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    private static func lyrics3Fields(in data: Data, range: Range<Int>) -> [Range<Int>]? {
        var bodies: [Range<Int>] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor <= range.upperBound - 8,
                  let length = decimal(data[(cursor + 3)..<(cursor + 8)]),
                  length <= range.upperBound - cursor - 8 else { return nil }
            let body = (cursor + 8)..<(cursor + 8 + length)
            if data[cursor..<(cursor + 3)].elementsEqual("LYR".utf8) { bodies.append(body) }
            cursor = body.upperBound
        }
        return bodies
    }

    // MARK: - ASF/WMA

    private static let asfHeaderGUID = Data([
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
        0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
    ])
    private static let asfContentDescriptionGUID = Data([
        0x33, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
        0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
    ])
    private static let asfExtendedContentDescriptionGUID = Data([
        0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11,
        0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50,
    ])
    private static let asfHeaderExtensionGUID = Data([
        0xB5, 0x03, 0xBF, 0x5F, 0x2E, 0xA9, 0xCF, 0x11,
        0x8E, 0xE3, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
    ])
    private static let asfMetadataGUID = Data([
        0xEA, 0xCB, 0xF8, 0xC5, 0xAF, 0x5B, 0x77, 0x48,
        0x84, 0x67, 0xAA, 0x8C, 0x44, 0xFA, 0x4C, 0xCA,
    ])
    private static let asfMetadataLibraryGUID = Data([
        0x94, 0x1C, 0x23, 0x44, 0x98, 0x94, 0xD1, 0x49,
        0xA1, 0x41, 0x1D, 0x13, 0x4E, 0x45, 0x70, 0x54,
    ])
    private static let asfLanguageListGUID = Data([
        0xA9, 0x46, 0x43, 0x7C, 0xE0, 0xEF, 0xFC, 0x4B,
        0xB2, 0x29, 0x39, 0x3E, 0xDE, 0x41, 0x5C, 0x85,
    ])
    private static let asfXMPGUID = Data([
        0xCB, 0xCF, 0x7A, 0xBE, 0xA9, 0x97, 0xE8, 0x42,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
    ])

    private static func asfHeaderByteCount(in data: Data) -> Int? {
        guard data.count >= 24,
              data.prefix(16).elementsEqual(asfHeaderGUID) else { return nil }
        let size = readUInt64LE(data, at: 16)
        guard size >= 30, size <= UInt64(Int.max) else { return nil }
        return Int(size)
    }

    /// An ASF XMP object is a sibling of the data object and can follow all audio packets.
    public static func topLevelASFXMP(head: Data, fileSize: Int64,
                                      fetch: (Int64, Int64) async throws -> Data) async throws -> [EmbeddedLyricField] {
        guard let headerSize = asfHeaderByteCount(in: head), fileSize >= Int64(headerSize) else { return [] }
        var offset = Int64(headerSize)
        var fields: [EmbeddedLyricField] = []
        while offset <= fileSize - 24 {
            try Task.checkCancellation()
            let header = try await tagBytes(head: head, at: offset, count: 24, fetch: fetch)
            guard let length = Int64(exactly: readUInt64LE(header, at: 16)), length >= 24, length <= fileSize - offset else { break }
            if header.starts(with: asfXMPGUID), length - 24 <= LyricsRawDocumentPolicy.maximumByteCount {
                let packet = try await tagBytes(head: head, at: offset + 24, count: Int(length - 24), fetch: fetch)
                fields.append(contentsOf: xmpLyricFields(in: packet))
            }
            offset += length
        }
        return fields
    }

    private struct ASFObject {
        let guid: Data
        let body: Range<Int>
    }

    private static func asfObjects(in data: Data, range: Range<Int>, maximumCount: Int) -> [ASFObject] {
        var result: [ASFObject] = []
        var cursor = range.lowerBound
        for _ in 0..<maximumCount {
            guard cursor <= range.upperBound - 24 else { break }
            let size = readUInt64LE(data, at: cursor + 16)
            guard size >= 24, size <= UInt64(range.upperBound - cursor) else { break }
            let end = cursor + Int(size)
            result.append(.init(guid: data.subdata(in: cursor..<(cursor + 16)), body: (cursor + 24)..<end))
            cursor = end
        }
        return result
    }

    private static func asfLanguages(in data: Data, range: Range<Int>) -> [String?] {
        guard range.count >= 2 else { return [] }
        let count = readUInt16LE(data, at: range.lowerBound)
        var cursor = range.lowerBound + 2
        var result: [String?] = []
        for _ in 0..<count {
            guard cursor < range.upperBound else { break }
            let length = Int(data[cursor])
            cursor += 1
            guard length <= range.upperBound - cursor else { break }
            result.append(decodedUTF16LE(data.subdata(in: cursor..<(cursor + length))))
            cursor += length
        }
        return result
    }

    private static func parseASF(_ data: Data) -> EmbeddedTagMetadata? {
        guard let declaredSize = asfHeaderByteCount(in: data),
              declaredSize <= data.count,
              data.count >= 30 else { return nil }
        let objectCount = readUInt32LE(data, at: 24)
        guard objectCount <= 100_000 else { return nil }
        let objects = asfObjects(in: data, range: 30..<declaredSize, maximumCount: objectCount).flatMap { object -> [ASFObject] in
            guard object.guid == asfHeaderExtensionGUID else { return [object] }
            guard object.body.count >= 22 else { return [] }
            let length = readUInt32LE(data, at: object.body.lowerBound + 18)
            let start = object.body.lowerBound + 22
            guard length <= object.body.upperBound - start else { return [] }
            return asfObjects(in: data, range: start..<(start + length), maximumCount: length / 24)
        }
        // A language list may follow the metadata library that references it.
        let languages = objects.first(where: { $0.guid == asfLanguageListGUID })
            .map { asfLanguages(in: data, range: $0.body) } ?? []
        var values: [String: [String]] = [:]
        var lyricFields: [EmbeddedLyricField] = []
        var cover: Data?
        func append(_ name: String, text: String, language: String? = nil) {
            values[normalizedKey(name), default: []].append(text)
            guard let role = ISOBaseMediaLyricsParser.lyricFieldRole(name, text: text) else { return }
            var field = role.field(name: name, text: text)
            field.languageCode = field.languageCode ?? language.flatMap(LyricLanguageCodePolicy.canonicalIdentifier)
            lyricFields.append(field)
        }
        for object in objects {
            let payloadStart = object.body.lowerBound
            let objectEnd = object.body.upperBound
            if object.guid == asfContentDescriptionGUID, object.body.count >= 10 {
                var lengthCursor = payloadStart
                let lengths = (0..<5).map { index in
                    readUInt16LE(data, at: lengthCursor + index * 2)
                }
                lengthCursor += 10
                let keys = ["TITLE", "AUTHOR", "COPYRIGHT", "DESCRIPTION", "RATING"]
                for (key, length) in zip(keys, lengths) {
                    guard length <= objectEnd - lengthCursor else { break }
                    if let text = decodedUTF16LE(data.subdata(in: lengthCursor..<(lengthCursor + length))) {
                        append(key, text: text)
                    }
                    lengthCursor += length
                }
            } else if [asfExtendedContentDescriptionGUID, asfMetadataGUID, asfMetadataLibraryGUID].contains(object.guid),
                      object.body.count >= 2 {
                let descriptorCount = readUInt16LE(data, at: payloadStart)
                var descriptorCursor = payloadStart + 2
                for _ in 0..<descriptorCount {
                    let name: Range<Int>
                    let valueType: Int
                    let valueLength: Int
                    var language: String?
                    if object.guid == asfExtendedContentDescriptionGUID {
                        guard descriptorCursor <= objectEnd - 2 else { break }
                        let length = readUInt16LE(data, at: descriptorCursor)
                        descriptorCursor += 2
                        guard length <= objectEnd - descriptorCursor - 4 else { break }
                        name = descriptorCursor..<(descriptorCursor + length)
                        valueType = readUInt16LE(data, at: name.upperBound)
                        valueLength = readUInt16LE(data, at: name.upperBound + 2)
                        descriptorCursor = name.upperBound + 4
                    } else {
                        guard descriptorCursor <= objectEnd - 12 else { break }
                        let languageIndex = readUInt16LE(data, at: descriptorCursor)
                        if object.guid == asfMetadataLibraryGUID, languageIndex < languages.count {
                            language = languages[languageIndex]
                        }
                        let length = readUInt16LE(data, at: descriptorCursor + 4)
                        valueType = readUInt16LE(data, at: descriptorCursor + 6)
                        valueLength = readUInt32LE(data, at: descriptorCursor + 8)
                        descriptorCursor += 12
                        guard length <= objectEnd - descriptorCursor else { break }
                        name = descriptorCursor..<(descriptorCursor + length)
                        descriptorCursor = name.upperBound
                    }
                    guard valueLength <= objectEnd - descriptorCursor else { break }
                    let valueData = data.subdata(
                        in: descriptorCursor..<(descriptorCursor + valueLength)
                    )
                    descriptorCursor += valueLength
                    guard let label = decodedUTF16LE(data.subdata(in: name)) else { continue }
                    let key = normalizedKey(label)
                    if key == "WM/PICTURE", valueType == 1 {
                        if cover == nil { cover = parseASFPicture(valueData) }
                    } else if key == "ID3", valueType == 1 {
                        for var field in ID3EmbeddedLyrics.fields(in: valueData) {
                            field.languageCode = field.languageCode ?? language.flatMap(LyricLanguageCodePolicy.canonicalIdentifier)
                            lyricFields.append(field)
                        }
                    } else if let field = asfTextField(name: label, type: valueType, data: valueData) {
                        append(field.key, text: field.value, language: language)
                    }
                }
            }
        }

        let following = declaredSize..<data.count
        for object in asfObjects(in: data, range: following, maximumCount: following.count / 24) where object.guid == asfXMPGUID {
            if object.body.count <= LyricsRawDocumentPolicy.maximumByteCount {
                lyricFields.append(contentsOf: xmpLyricFields(in: data.subdata(in: object.body)))
            }
        }
        var metadata = metadata(from: values, orderedFields: lyricFields)
        metadata.coverArtData = metadata.coverArtData ?? cover
        return metadata.isEmpty ? nil : metadata
    }

    private static func asfTextField(name: String, type: Int, data: Data) -> (key: String, value: String)? {
        let key = normalizedKey(name)
        if type == 1, ["WM/LYRICS_SYNCHRONISED", "WM/LYRICS_SYNCHRONIZED"].contains(key) {
            guard data.count >= 8, [1, 2].contains(data[0]), [1, 2].contains(data[1]),
                  let descriptionEnd = utf16NullOffset(in: data, from: 6),
                  readUInt32LE(data, at: 2) == data.count - descriptionEnd - 2 else { return nil }
            let descriptor = decodedUTF16LE(data.subdata(in: 6..<descriptionEnd))
            let field = descriptor.flatMap { ISOBaseMediaLyricsParser.id3UserTextRole($0) == nil ? nil : $0 } ?? name
            var cursor = descriptionEnd + 2
            var cues: [(text: String, milliseconds: Int)] = []
            while cursor < data.count {
                guard let end = utf16NullOffset(in: data, from: cursor), end <= data.count - 6,
                      let text = String(data: data.subdata(in: cursor..<end), encoding: .utf16LittleEndian) else { return nil }
                cues.append((text, readUInt32LE(data, at: end + 2)))
                cursor = end + 6
            }
            // A frame counter cannot be converted to clock time without its stream timebase.
            let text = data[0] == 2 ? ID3SynchronizedLyricsParser.renderedCues(cues) : cues.map(\.text).joined()
            return text.flatMap { $0.isEmpty ? nil : (field, $0) }
        }
        if key == "WM/TEXT", type == 1,
           let end = utf16NullOffset(in: data, from: 0),
           let label = decodedUTF16LE(data.subdata(in: 0..<end)),
           let text = decodedUTF16LE(data.subdata(in: (end + 2)..<data.count)),
           ISOBaseMediaLyricsParser.id3UserTextRole(label, text: text) != nil {
            return (label, text)
        }
        if type == 1 { return binaryLyricText(in: data, name: name) }
        return decodedASFValue(data, type: type).map { (name, $0) }
    }

    private static func parseASFPicture(_ data: Data) -> Data? {
        guard data.count >= 5 else { return nil }
        let imageLength = readUInt32LE(data, at: 1)
        var cursor = 5
        guard let mimeEnd = utf16NullOffset(in: data, from: cursor) else { return nil }
        cursor = mimeEnd + 2
        guard let descriptionEnd = utf16NullOffset(in: data, from: cursor) else { return nil }
        cursor = descriptionEnd + 2
        guard imageLength <= data.count - cursor else { return nil }
        return normalizedImageData(data.subdata(in: cursor..<(cursor + imageLength)))
    }

    private static func decodedASFValue(_ data: Data, type: Int) -> String? {
        switch type {
        case 0:
            return decodedUTF16LE(data)
        case 2, 3:
            guard data.count >= 4 else { return nil }
            return String(readUInt32LE(data, at: 0))
        case 4:
            guard data.count >= 8 else { return nil }
            return String(readUInt64LE(data, at: 0))
        case 5:
            guard data.count >= 2 else { return nil }
            return String(readUInt16LE(data, at: 0))
        default:
            return nil
        }
    }

    // MARK: - RIFF/AIFF text

    /// Rebuilds RIFF/WAVE or FORM/AIFF with just the tag chunks missing from the
    /// prefix. Chunk lengths let a range reader skip PCM and padding.
    public static func waveMetadataFile(
        head: Data, fileSize: Int64,
        fetch: (Int64, Int64) async throws -> Data
    ) async throws -> Data? {
        if var scan = DSDIFFChunks(head), scan.end <= fileSize, scan.end > head.count {
            var chunks = Data()
            while let offset = scan.nextOffset {
                try Task.checkCancellation()
                let header = try await tagBytes(head: head, at: offset, count: scan.headerLength, fetch: fetch)
                guard let range = scan.advance(header), range.upperBound > head.count,
                      range.count <= 32 * 1024 * 1024 - chunks.count - 13 else { continue }
                chunks.append(header.prefix(12))
                chunks.append(try await tagBytes(head: head, at: range.lowerBound, count: range.count, fetch: fetch))
                if !range.count.isMultiple(of: 2) { chunks.append(0) }
            }
            guard !chunks.isEmpty else { return nil }
            var result = Data("FRM8".utf8)
            var length = UInt64(4 + chunks.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            return result + Data("DSD ".utf8) + chunks
        }
        guard head.count >= 12 else { return nil }
        let form = head[8..<12]
        let wave = head.starts(with: "RIFF".utf8) && form.elementsEqual("WAVE".utf8)
        let aiff = head.starts(with: "FORM".utf8) && (form.elementsEqual("AIFF".utf8) || form.elementsEqual("AIFC".utf8))
        guard wave || aiff else { return nil }
        func chunkSize(_ bytes: Data) -> Int { wave ? readUInt32LE(bytes, at: 4) : readUInt32BE(bytes, at: 4) }
        let end = Int64(chunkSize(head)) + 8
        guard end > head.count, end <= fileSize else { return nil }

        var offset: Int64 = 12
        var chunks = Data()
        let maximumTagBytes = 32 * 1024 * 1024
        while offset <= end - 8 {
            try Task.checkCancellation()
            let header = try await tagBytes(head: head, at: offset, count: Int(min(12, end - offset)), fetch: fetch)
            let length = chunkSize(header)
            let body = offset + 8
            let next = body + Int64(length)
            guard next <= end else { break }
            offset = next + Int64(length % 2)
            guard next > head.count, length > 0,
                  length + 9 <= maximumTagBytes - chunks.count else { continue }
            guard let id = ascii(header, at: 0, count: 4) else { continue }
            let isInfo = wave && id == "LIST" && length >= 4 && header.suffix(4).elementsEqual("INFO".utf8)
            let isWaveXMP = wave && id == "_PMX"
            let isAIFFText = aiff && ["NAME", "AUTH", "(c) ", "ANNO", "COMT"].contains(id)
            let isAIFFXMP = aiff && id == "APPL" && length >= 4 && header.suffix(4).elementsEqual("XMP ".utf8)
            guard id == "id3 " || id == "ID3 " || isInfo || isWaveXMP || isAIFFText || isAIFFXMP else { continue }
            let prefixLength = min(length, header.count - 8)
            chunks.append(header.prefix(8 + prefixLength))
            if prefixLength < length {
                chunks.append(try await tagBytes(head: head, at: body + Int64(prefixLength), count: length - prefixLength, fetch: fetch))
            }
            if !length.isMultiple(of: 2) { chunks.append(0) }
        }
        guard !chunks.isEmpty else { return nil }
        var result = Data(head.prefix(4))
        var size = wave ? UInt32(4 + chunks.count).littleEndian : UInt32(4 + chunks.count).bigEndian
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(contentsOf: form)
        result.append(chunks)
        // Some writers also append legacy tags outside RIFF, including ID3v1 or APEv2.
        if end < fileSize {
            let count = min(fileSize - end, Int64(RemoteMetadataReadPolicy.initialContainerTailByteCount))
            result.append(try await fetch(fileSize - count, count))
        }
        return result
    }

    private static func tagBytes(head: Data, at offset: Int64, count: Int,
                                 fetch: (Int64, Int64) async throws -> Data) async throws -> Data {
        let cached = min(count, max(0, head.count - Int(offset)))
        var bytes = cached > 0 ? head.subdata(in: Int(offset)..<(Int(offset) + cached)) : Data()
        // A provider may cap a successful range response below its requested length.
        while bytes.count < count {
            try Task.checkCancellation()
            let missing = count - bytes.count
            let part = try await fetch(offset + Int64(bytes.count), Int64(missing))
            guard !part.isEmpty, part.count <= missing else { throw URLError(.badServerResponse) }
            bytes.append(part)
        }
        return bytes
    }

    private static func parseRIFFInfo(_ data: Data) -> EmbeddedTagMetadata? {
        guard data.count >= 12,
              data.prefix(4).elementsEqual(Data("RIFF".utf8)),
              data[8..<12].elementsEqual(Data("WAVE".utf8)) else { return nil }
        var cursor = 12
        var fields: [ChunkField] = []
        let end = min(data.count, 8 + readUInt32LE(data, at: 4))
        while cursor + 8 <= end {
            guard let identifier = ascii(data, at: cursor, count: 4) else { break }
            let length = readUInt32LE(data, at: cursor + 4)
            let bodyStart = cursor + 8
            let bodyEnd = bodyStart + length
            guard bodyEnd <= end else { break }
            if identifier == "id3 " || identifier == "ID3 " {
                fields.append(.id3(data.subdata(in: bodyStart..<bodyEnd)))
            } else if identifier == "_PMX" {
                fields.append(.xmp(data.subdata(in: bodyStart..<bodyEnd)))
            } else if identifier == "LIST", length >= 4,
               data[bodyStart..<(bodyStart + 4)].elementsEqual(Data("INFO".utf8)) {
                var infoCursor = bodyStart + 4
                while infoCursor + 8 <= bodyEnd {
                    guard let key = ascii(data, at: infoCursor, count: 4) else { break }
                    let valueLength = readUInt32LE(data, at: infoCursor + 4)
                    let valueStart = infoCursor + 8
                    let valueEnd = valueStart + valueLength
                    guard valueEnd <= bodyEnd else { break }
                    let bytes = data[valueStart..<valueEnd].prefix(while: { $0 != 0 })
                    if !bytes.isEmpty {
                        fields.append(.text(normalizedKey(key), Data(bytes)))
                    }
                    infoCursor = valueEnd + (valueLength.isMultiple(of: 2) ? 0 : 1)
                }
            }
            cursor = bodyEnd + (length.isMultiple(of: 2) ? 0 : 1)
        }
        return metadata(from: fields)
    }

    private static func parseAIFFText(_ data: Data) -> EmbeddedTagMetadata? {
        guard data.count >= 12,
              data.prefix(4).elementsEqual(Data("FORM".utf8)),
              (data[8..<12].elementsEqual(Data("AIFF".utf8))
                || data[8..<12].elementsEqual(Data("AIFC".utf8))) else { return nil }
        var cursor = 12
        var fields: [ChunkField] = []
        let end = min(data.count, 8 + readUInt32BE(data, at: 4))
        while cursor + 8 <= end {
            guard let identifier = ascii(data, at: cursor, count: 4) else { break }
            let length = readUInt32BE(data, at: cursor + 4)
            let bodyStart = cursor + 8
            let bodyEnd = bodyStart + length
            guard bodyEnd <= end else { break }
            let mappedKey: String? = switch identifier {
            case "NAME": "TITLE"
            case "AUTH": "ARTIST"
            case "(c) ": "COPYRIGHT"
            case "ANNO": "COMMENT"
            default: nil
            }
            if let mappedKey {
                fields.append(.text(mappedKey, Data(data[bodyStart..<bodyEnd].prefix(while: { $0 != 0 }))))
            } else if identifier == "ID3 " || identifier == "id3 " {
                fields.append(.id3(data.subdata(in: bodyStart..<bodyEnd)))
            } else if identifier == "APPL", length >= 4, data[bodyStart..<(bodyStart + 4)].elementsEqual("XMP ".utf8) {
                fields.append(.xmp(data.subdata(in: (bodyStart + 4)..<bodyEnd)))
            } else if identifier == "COMT", length >= 2 {
                var pos = bodyStart + 2
                for _ in 0..<readUInt16BE(data, at: bodyStart) {
                    guard pos <= bodyEnd - 8 else { break }
                    let count = readUInt16BE(data, at: pos + 6)
                    pos += 8
                    guard count <= bodyEnd - pos else { break }
                    fields.append(.text("COMMENT", data.subdata(in: pos..<(pos + count))))
                    pos += count + count % 2
                }
            }
            cursor = bodyEnd + (length.isMultiple(of: 2) ? 0 : 1)
        }
        return metadata(from: fields)
    }

    private enum ChunkField { case text(String, Data), id3(Data), xmp(Data) }

    private static func metadata(from chunks: [ChunkField]) -> EmbeddedTagMetadata? {
        let bytes = chunks.compactMap { field -> Data? in
            if case .text(_, let value) = field { return value }
            return nil
        }
        var decoded = TextEncodingRepair.decodeTagValues(bytes).makeIterator()
        var values: [String: [String]] = [:]
        var lyrics: [EmbeddedLyricField] = []
        for field in chunks {
            switch field {
            case .id3(let payload):
                lyrics.append(contentsOf: ID3EmbeddedLyrics.fields(in: payload))
            case .xmp(let payload):
                lyrics.append(contentsOf: xmpLyricFields(in: payload))
            case .text(let name, _):
                guard let item = decoded.next(), let text = item else { continue }
                values[name, default: []].append(text)
                if let role = ISOBaseMediaLyricsParser.lyricFieldRole(name, text: text) {
                    lyrics.append(role.field(name: name, text: text))
                }
            }
        }
        let result = metadata(from: values, orderedFields: lyrics)
        return result.isEmpty ? nil : result
    }

    /// Adobe Dynamic Media defines its lyrics property as text. Other fields
    /// in the RDF packet (such as comments or rights) describe the asset itself.
    public static func xmpLyricFields(in data: Data) -> [EmbeddedLyricField] {
        guard !data.isEmpty else { return [] }
        let reader = XMPLyricReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = reader
        if parser.parse(), !reader.fields.isEmpty { return reader.fields }
        guard let packet = CGImageMetadataCreateFromXMPData(data as CFData) else { return [] }
        var result: [EmbeddedLyricField] = []
        CGImageMetadataEnumerateTagsUsingBlock(packet, nil, nil) { _, tag in
            guard CGImageMetadataTagCopyName(tag) as String? == "lyrics",
                  CGImageMetadataTagCopyNamespace(tag) as String? == "http://ns.adobe.com/xmp/1.0/DynamicMedia/",
                  let text = CGImageMetadataTagCopyValue(tag) as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            let qualifiers = CGImageMetadataTagCopyQualifiers(tag) as? [CGImageMetadataTag] ?? []
            let language = qualifiers.first { qualifier in
                CGImageMetadataTagCopyName(qualifier) as String? == "lang"
                    && CGImageMetadataTagCopyNamespace(qualifier) as String? == "http://www.w3.org/XML/1998/namespace"
            }.flatMap { CGImageMetadataTagCopyValue($0) as? String }.flatMap(LyricLanguageCodePolicy.canonicalIdentifier)
            result.append(.init(name: "xmpDM:lyrics", text: text, languageCode: language))
            return true
        }
        return result
    }

    private final class XMPLyricReader: NSObject, XMLParserDelegate {
        private let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        private let dynamicMedia = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"
        private var prefixes: [String: [String]] = [:]
        private var languages: [String?] = []
        private var lyricDepth: Int?
        private var valueDepth: Int?
        private var value = ""
        var fields: [EmbeddedLyricField] = []

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
            prefixes[prefix, default: []].append(uri)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            _ = prefixes[prefix]?.popLast()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let language = attributes["xml:lang"].flatMap(LyricLanguageCodePolicy.canonicalIdentifier) ?? languages.last ?? nil
            languages.append(language)
            if uri == rdf && name == "Description" {
                for (attribute, text) in attributes {
                    let parts = attribute.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[1] == "lyrics", prefixes[String(parts[0])]?.last == dynamicMedia {
                        add(text)
                    }
                }
            }
            if uri == dynamicMedia && name == "lyrics" {
                lyricDepth = languages.count
                valueDepth = languages.count
                value = ""
            } else if lyricDepth != nil, uri == rdf && (name == "li" || name == "value") {
                valueDepth = languages.count
                value = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters text: String) {
            if valueDepth == languages.count { value += text }
        }

        func parser(_ parser: XMLParser, foundCDATA bytes: Data) {
            if valueDepth == languages.count { value += String(decoding: bytes, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI uri: String?, qualifiedName: String?) {
            if valueDepth == languages.count { add(value); value = ""; valueDepth = nil }
            if lyricDepth == languages.count { lyricDepth = nil }
            _ = languages.popLast()
        }

        private func add(_ text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            fields.append(.init(name: "xmpDM:lyrics", text: text, languageCode: languages.last ?? nil))
        }
    }

    // MARK: - Embedded ID3 chunks

    /// DSDIFF writers put ID3 at the top level or inside PROP/SND. Chunk sizes
    /// are 64-bit and exclude the pad byte, even on files larger than 4 GB.
    private struct DSDIFFChunks {
        let end: Int64
        private var pending: [Range<Int64>]

        init?(_ head: Data) {
            guard head.count >= 16, head.starts(with: "FRM8".utf8), head[12..<16].elementsEqual("DSD ".utf8),
                  let size = Int64(exactly: readUInt64BE(head, at: 4)), size >= 4, size <= Int64.max - 12 else { return nil }
            end = size + 12
            pending = end >= 28 ? [16..<end] : []
        }

        var nextOffset: Int64? { pending.last?.lowerBound }
        var headerLength: Int { pending.last.map { Int(min(16, $0.upperBound - $0.lowerBound)) } ?? 0 }

        mutating func advance(_ header: Data) -> Range<Int64>? {
            guard let remaining = pending.popLast(), header.count >= 12,
                  let size = Int64(exactly: readUInt64BE(header, at: 4)) else { return nil }
            let start = remaining.lowerBound + 12
            guard size <= remaining.upperBound - start else { return nil }
            let end = start + size
            if remaining.upperBound - end >= 12 + size % 2 {
                pending.append((end + size % 2)..<remaining.upperBound)
            }
            if header.starts(with: "PROP".utf8), size >= 16, header.count >= 16, header[12..<16].elementsEqual("SND ".utf8) {
                pending.append((start + 4)..<end)
            }
            return header.starts(with: "ID3 ".utf8) || header.starts(with: "id3 ".utf8) ? start..<end : nil
        }
    }

    private static func dsdiffID3Chunks(in data: Data) -> [Data] {
        guard var scan = DSDIFFChunks(data) else { return [] }
        var result: [Data] = []
        while let offset = scan.nextOffset, offset <= data.count - scan.headerLength {
            let header = data.subdata(in: Int(offset)..<(Int(offset) + scan.headerLength))
            if let range = scan.advance(header), range.upperBound <= data.count {
                result.append(data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
            }
        }
        return result
    }

    private static func riffID3Chunk(in data: Data) -> Data? {
        guard data.count >= 12,
              data.prefix(4).elementsEqual(Data("RIFF".utf8)) else {
            return completeID3Tag(in: data)
        }
        var cursor = 12
        while cursor + 8 <= data.count {
            guard let identifier = ascii(data, at: cursor, count: 4) else { break }
            let length = readUInt32LE(data, at: cursor + 4)
            let bodyStart = cursor + 8
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.count else { break }
            if ["id3 ", "ID3 "].contains(identifier) {
                return completeID3Tag(in: data.subdata(in: bodyStart..<bodyEnd))
            }
            cursor = bodyEnd + (length.isMultiple(of: 2) ? 0 : 1)
        }
        return completeID3Tag(in: data)
    }

    private static func bigEndianID3Chunk(in data: Data, dsdiff: Bool) -> Data? {
        if dsdiff, DSDIFFChunks(data) != nil, let embedded = dsdiffID3Chunks(in: data).first {
            return completeLeadingID3Tag(in: embedded)
        }
        var cursor = 0
        if data.starts(with: "FORM".utf8) { cursor = 12 }
        else if dsdiff, data.starts(with: "FRM8".utf8) { cursor = 16 }
        let headerSize = dsdiff ? 12 : 8
        while cursor <= data.count - headerSize {
            guard let identifier = ascii(data, at: cursor, count: 4) else { break }
            let bodyStart = cursor + headerSize
            let size = dsdiff ? readUInt64BE(data, at: cursor + 4) : UInt64(readUInt32BE(data, at: cursor + 4))
            guard size <= UInt64(data.count - bodyStart) else { break }
            let length = Int(size)
            let bodyEnd = bodyStart + length
            if identifier == "ID3 " || identifier == "id3 " {
                if let tag = completeLeadingID3Tag(in: data.subdata(in: bodyStart..<bodyEnd)) { return tag }
            }
            cursor = bodyEnd + (length.isMultiple(of: 2) ? 0 : 1)
        }
        return completeID3Tag(in: data)
    }

    private static func completeID3Tag(in data: Data) -> Data? {
        var searchStart = 0
        while searchStart + 10 <= data.count,
              let range = data.range(of: id3Signature, in: searchStart..<data.count) {
            let start = range.lowerBound
            let candidate = data.subdata(in: start..<data.count)
            if let byteCount = id3TagByteCount(in: candidate), byteCount <= candidate.count {
                return candidate.subdata(in: 0..<byteCount)
            }
            searchStart = start + 1
        }
        return nil
    }

    private static func completeLeadingID3Tag(in data: Data) -> Data? {
        guard let byteCount = id3TagByteCount(in: data), byteCount <= data.count else {
            return nil
        }
        return data.subdata(in: 0..<byteCount)
    }

    private static func completeTrailingID3Tag(in data: Data) -> Data? {
        var end = data.count
        if end >= 128, data[(end - 128)..<(end - 125)].elementsEqual("TAG".utf8) { end -= 128 }
        return trailingID3Range(in: data, endingAt: end).map { data.subdata(in: $0) }
    }

    private static func trailingID3Range(in data: Data, endingAt end: Int) -> Range<Int>? {
        if id3TagByteCount(in: data) == end { return 0..<end }
        var searchStart = max(0, end - maximumRangeByteCount)
        while searchStart <= end - 10,
              let range = data.range(of: id3Signature, in: searchStart..<(end - 7)) {
            let start = range.lowerBound
            if let byteCount = id3TagByteCount(in: data.subdata(in: start..<(start + 10))), byteCount == end - start {
                return start..<end
            }
            searchStart = start + 1
        }
        return nil
    }

    // MARK: - Shared field mapping

    private static func metadata(from values: [String: [String]], orderedFields: [EmbeddedLyricField]? = nil) -> EmbeddedTagMetadata {
        func first(_ keys: String...) -> String? {
            for key in keys {
                if let value = values[normalizedKey(key)]?.first, !value.isEmpty { return value }
            }
            return nil
        }
        func all(_ keys: String...) -> [String]? {
            var result: [String] = []
            for key in keys {
                for value in values[normalizedKey(key)] ?? [] where !result.contains(value) {
                    result.append(value)
                }
            }
            return result.isEmpty ? nil : result
        }

        let artists = all("ARTIST", "AUTHOR", "WM/AUTHOR", "IART")
        let albumArtists = all("ALBUMARTIST")
            ?? all("ALBUM ARTIST")
            ?? all("ALBUM_ARTIST")
            ?? all("WM/ALBUMARTIST")
        let track = first("TRACKNUMBER", "TRACK", "WM/TRACKNUMBER", "IPRT", "ITRK")
        let disc = first("DISCNUMBER", "DISC", "WM/PARTOFSET")
        let date = first("DATE", "YEAR", "WM/YEAR", "ICRD")
        // Dictionary-only decoders do not have file order; retain the legacy order of known keys.
        let fields = orderedFields ?? (originalLyricKeys + values.keys.sorted().filter { !originalLyricKeys.contains($0) }).flatMap { key in
            (values[key] ?? []).compactMap { text in
                ISOBaseMediaLyricsParser.lyricFieldRole(key, text: text)?.field(name: key, text: text)
            }
        }
        let lyricFields = resolvedLyricFields(from: values, fields: fields)
        var result = EmbeddedTagMetadata(
            title: first("TITLE", "WM/TITLE", "INAM"),
            artist: artists?.joined(separator: "; "),
            artists: artists,
            albumTitle: first("ALBUM", "ALBUMTITLE", "WM/ALBUMTITLE", "IPRD"),
            releaseType: all("RELEASETYPE", "RELEASE TYPE", "MUSICBRAINZ_ALBUMTYPE", "MusicBrainz Album Type", "ALBUMTYPE")?.joined(separator: "; "),
            albumArtist: albumArtists?.joined(separator: "; "),
            trackNumber: track.flatMap(leadingInteger),
            discNumber: disc.flatMap(leadingInteger),
            year: date.flatMap(year),
            genre: GenreTagValues.joined(all("GENRE") ?? all("WM/GENRE") ?? all("IGNR") ?? []),
            lyrics: lyricFields.lyrics,
            lyricsLanguageCode: lyricFields.lyricsLanguageCode,
            translatedLyrics: lyricFields.translatedLyrics,
            translatedLyricsLanguageCode: lyricFields.translatedLyricsLanguageCode,
            languageTaggedLyrics: lyricFields.languageTaggedLyrics,
            languageTaggedTranslations: lyricFields.languageTaggedTranslations,
            lyricsVariants: lyricFields.lyricsVariants,
            replayGainTrackGain: first("REPLAYGAIN_TRACK_GAIN").flatMap(replayGain),
            replayGainTrackPeak: first("REPLAYGAIN_TRACK_PEAK").flatMap(Double.init),
            replayGainAlbumGain: first("REPLAYGAIN_ALBUM_GAIN").flatMap(replayGain),
            replayGainAlbumPeak: first("REPLAYGAIN_ALBUM_PEAK").flatMap(Double.init)
        )

        result.lyricFields = fields

        if let encoded = first("METADATA_BLOCK_PICTURE"),
           let picture = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
            result.coverArtData = parseFLACPicture(picture)
        }
        if result.coverArtData == nil,
           let encoded = first("COVERART"),
           let picture = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
            result.coverArtData = normalizedImageData(picture)
        }
        return result
    }

    private struct ResolvedLyricFields {
        var lyrics: String?
        var lyricsLanguageCode: String?
        var translatedLyrics: String?
        var translatedLyricsLanguageCode: String?
        var languageTaggedLyrics: [String: String] = [:]
        var languageTaggedTranslations: [String: String] = [:]
        var lyricsVariants: [EmbeddedLyricsVariant] = []
    }

    /// Keeps explicitly translated fields separate from the canonical lyric
    /// body. Language-suffixed variants are retained even when there is not
    /// enough information to decide which one is the source language.
    private static func resolvedLyricFields(
        from values: [String: [String]],
        fields: [EmbeddedLyricField]
    ) -> ResolvedLyricFields {
        let translationRoots = [
            "TRANSLATEDLYRICS", "TRANSLATED LYRICS", "TRANSLATION",
            "LYRICS TRANSLATION", "WM/TRANSLATEDLYRICS", "WM/TRANSLATION",
        ]

        func first(_ keys: [String]) -> String? {
            for key in keys {
                if let value = values[normalizedKey(key)]?.first, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        func taggedValues(for role: EmbeddedLyricField.Role) -> [String: String] {
            var result: [String: String] = [:]
            for field in fields where field.role == role {
                if let code = field.languageCode, result[code] == nil { result[code] = field.text }
            }
            return result
        }

        let taggedLyrics = taggedValues(for: .original)
        let taggedTranslations = taggedValues(for: .translation)
        let declaredLyricsLanguage = normalizedLyricLanguageCode(
            first(["LYRICS_LANGUAGE", "LYRICS LANGUAGE"])
        )
        let declaredTranslationLanguage = normalizedLyricLanguageCode(
            first([
                "TRANSLATEDLYRICS_LANGUAGE", "TRANSLATED LYRICS LANGUAGE",
                "TRANSLATION_LANGUAGE", "TRANSLATION LANGUAGE",
            ])
        )

        let originals = fields.filter { $0.role == .original }
        let untaggedTexts = Set(originals.filter { $0.languageCode == nil }.map(\.text))
        let sourceLanguage: String?
        if let declaredLyricsLanguage {
            sourceLanguage = declaredLyricsLanguage
        } else {
            let possibleLanguages = Set(originals.compactMap { entry in
                untaggedTexts.isEmpty || untaggedTexts.contains(entry.text) ? entry.languageCode : nil
            })
            sourceLanguage = possibleLanguages.count == 1 ? possibleLanguages.first
                : (untaggedTexts.isEmpty ? originals.first?.languageCode : nil)
        }
        var variants: [EmbeddedLyricsVariant] = []
        for entry in originals where entry.languageCode == nil || entry.languageCode == sourceLanguage {
            EmbeddedLyricsVariantPolicy.append(entry.text, languageCode: sourceLanguage, to: &variants)
        }
        var result = ResolvedLyricFields(
            lyrics: EmbeddedLyricsVariantPolicy.preferred(
                in: variants,
                priority: EmbeddedLyricsVariantPriority.current()
            )?.text,
            lyricsLanguageCode: sourceLanguage,
            translatedLyrics: first(translationRoots) ?? fields.first { $0.role == .translation && $0.languageCode == nil }?.text,
            translatedLyricsLanguageCode: declaredTranslationLanguage,
            languageTaggedLyrics: taggedLyrics,
            languageTaggedTranslations: taggedTranslations,
            lyricsVariants: variants
        )

        if result.lyrics == nil {
            if let declaredLyricsLanguage,
               let tagged = taggedLyrics[declaredLyricsLanguage] {
                result.lyrics = tagged
                result.lyricsLanguageCode = declaredLyricsLanguage
            } else if taggedLyrics.count == 1,
                      let only = taggedLyrics.first {
                result.lyrics = only.value
                result.lyricsLanguageCode = only.key
            }
        } else if result.lyricsLanguageCode == nil,
                  let matching = taggedLyrics.first(where: { $0.value == result.lyrics }) {
            result.lyricsLanguageCode = matching.key
        }

        if result.translatedLyrics == nil {
            if let declaredTranslationLanguage,
               let tagged = taggedTranslations[declaredTranslationLanguage] {
                result.translatedLyrics = tagged
                result.translatedLyricsLanguageCode = declaredTranslationLanguage
            } else if taggedTranslations.count == 1,
                      let only = taggedTranslations.first {
                result.translatedLyrics = only.value
                result.translatedLyricsLanguageCode = only.key
            } else if result.lyrics != nil {
                let distinctAlternates = taggedLyrics.filter { languageCode, text in
                    text != result.lyrics && languageCode != result.lyricsLanguageCode
                }
                if distinctAlternates.count == 1,
                   let only = distinctAlternates.first {
                    result.translatedLyrics = only.value
                    result.translatedLyricsLanguageCode = only.key
                }
            }
        } else if result.translatedLyricsLanguageCode == nil,
                  let matching = taggedTranslations.first(where: {
                      $0.value == result.translatedLyrics
                  }) {
            result.translatedLyricsLanguageCode = matching.key
        }

        return result
    }

    private static func normalizedLyricLanguageCode(_ value: String?) -> String? {
        value.flatMap(LyricLanguageCodePolicy.canonicalIdentifier)
    }

    private static func parseFLACPicture(_ data: Data) -> Data? {
        guard data.count >= 32 else { return nil }
        let mimeLength = readUInt32BE(data, at: 4)
        var cursor = 8
        guard mimeLength <= data.count - cursor else { return nil }
        cursor += mimeLength
        guard cursor + 4 <= data.count else { return nil }
        let descriptionLength = readUInt32BE(data, at: cursor)
        cursor += 4
        guard descriptionLength <= data.count - cursor else { return nil }
        cursor += descriptionLength
        guard cursor + 20 <= data.count else { return nil }
        let imageLength = readUInt32BE(data, at: cursor + 16)
        cursor += 20
        guard imageLength <= data.count - cursor else { return nil }
        return normalizedImageData(data.subdata(in: cursor..<(cursor + imageLength)))
    }

    private static func normalizedImageData(_ data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        if data.starts(with: Data([0xFF, 0xD8, 0xFF])) { return data }
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return data }
        if data.starts(with: Data("GIF8".utf8)) { return data }
        if data.count >= 12,
           data.prefix(4).elementsEqual(Data("RIFF".utf8)),
           data[8..<12].elementsEqual(Data("WEBP".utf8)) { return data }
        if data.starts(with: Data("BM".utf8)) { return data }
        return nil
    }

    private static func normalizedExtension(_ value: String) -> String {
        switch value.lowercased() {
        case "asf": "wma"
        case "oga": "ogg"
        case "mpp": "mpc"
        case "spx": "speex"
        case "aifc": "aiff"
        case "bwf": "wav"
        default: value.lowercased()
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            .uppercased()
    }

    private static func leadingInteger(_ value: String) -> Int? {
        let prefix = value.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return prefix.isEmpty ? nil : Int(prefix)
    }

    private static func year(_ value: String) -> Int? {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return Int(digits.prefix(4))
    }

    private static func replayGain(_ value: String) -> Double? {
        Double(value.lowercased().replacingOccurrences(of: "db", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func decodedUTF16LE(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf16LittleEndian) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func utf16NullOffset(in data: Data, from start: Int) -> Int? {
        guard start >= 0, start < data.count else { return nil }
        var cursor = start
        while cursor + 1 < data.count {
            if data[cursor] == 0, data[cursor + 1] == 0 { return cursor }
            cursor += 2
        }
        return nil
    }

    private static func boundedFileLimit(_ fileSize: Int64) -> Int {
        guard fileSize > 0 else { return maximumRangeByteCount }
        return min(Int(clamping: fileSize), maximumRangeByteCount)
    }

    private static func ascii(_ data: Data, at offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset <= data.count - count else { return nil }
        return String(data: data.subdata(in: offset..<(offset + count)), encoding: .isoLatin1)
    }

    private static func readBoundedUInt32LE(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return readUInt32LE(data, at: offset)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 2 else { return 0 }
        return Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) << 8 | Int(data[offset + 1])
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 4 else { return 0 }
        return Int(data[offset])
            | (Int(data[offset + 1]) << 8)
            | (Int(data[offset + 2]) << 16)
            | (Int(data[offset + 3]) << 24)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 4 else { return 0 }
        return (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }
}
