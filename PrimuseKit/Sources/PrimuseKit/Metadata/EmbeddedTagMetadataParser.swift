import Foundation

/// Dependency-free metadata recovered from containers that AVFoundation does
/// not consistently inspect, especially when the caller only owns bounded
/// head/tail ranges from a remote file.
public struct EmbeddedTagMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var artists: [String]?
    public var albumTitle: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var lyrics: String?
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
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        lyrics: String? = nil,
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
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.lyrics = lyrics
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
            && albumArtist == nil
            && trackNumber == nil
            && discNumber == nil
            && year == nil
            && genre == nil
            && lyrics == nil
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
        albumArtist = albumArtist ?? fallback.albumArtist
        trackNumber = trackNumber ?? fallback.trackNumber
        discNumber = discNumber ?? fallback.discNumber
        year = year ?? fallback.year
        genre = genre ?? fallback.genre
        lyrics = lyrics ?? fallback.lyrics
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

        switch ext {
        case "ogg", "opus", "speex":
            if let parsed = parseOggComments(head) {
                result.fillMissing(from: parsed)
            }
        case "ape", "wv", "mpc", "tta":
            if let tail, let parsed = parseAPEv2(tail) {
                result.fillMissing(from: parsed)
            }
            if result.isEmpty, let parsed = parseAPEv2(head) {
                result.fillMissing(from: parsed)
            }
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
        default:
            break
        }

        // APEv2 is an EOF tag family rather than an audio container. Besides
        // Monkey's Audio/WavPack/Musepack/TTA it is commonly used by TAK and
        // can legally accompany tag-poor elementary streams. The footer is
        // accepted only at an exact EOF position (or immediately before
        // ID3v1), so applying this structural check across formats does not
        // mistake compressed payload bytes for metadata.
        if let tail, let parsed = parseAPEv2(tail) {
            result.fillMissing(from: parsed)
        }

        return result.isEmpty ? nil : result
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

        if ext == "wma", let declared = asfHeaderByteCount(in: currentData) {
            let wanted = min(fileLimit, declared)
            return wanted > currentData.count ? wanted : nil
        }

        guard ["ogg", "opus", "speex"].contains(ext) else { return nil }
        let scan = scanOggPackets(currentData)
        guard !oggCommentInspectionComplete(scan) else { return nil }
        let doubled = max(currentData.count + 64 * 1024, currentData.count * 2)
        let wanted = min(fileLimit, max(doubled, scan.minimumCompleteByteCount ?? 0))
        return wanted > currentData.count ? wanted : nil
    }

    /// APEv2 normally lives at EOF. Its footer declares the complete tag size,
    /// allowing a second negative Range request to be exact instead of pulling
    /// the full audio file.
    public static func expandedTailReadSize(
        fileSize: Int64,
        currentData: Data,
        fileExtension _: String
    ) -> Int? {
        guard let footer = lastAPEv2Footer(in: currentData) else {
            return nil
        }
        let tagSize = readUInt32LE(currentData, at: footer + 12)
        guard tagSize >= 32 else { return nil }
        let fileLimit = boundedFileLimit(fileSize)
        let wanted = min(fileLimit, tagSize + 128)
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
            if let tag = bigEndianID3Chunk(in: head) { return tag }
            if let tail, let tag = bigEndianID3Chunk(in: tail) { return tag }
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

    private struct OggPacketScan {
        var packets: [Data]
        var isTruncated: Bool
        var minimumCompleteByteCount: Int?
    }

    private static func scanOggPackets(_ data: Data) -> OggPacketScan {
        var packets: [Data] = []
        var packet = Data()
        var cursor = 0
        var minimumCompleteByteCount: Int?

        while cursor < data.count {
            guard cursor + 27 <= data.count else {
                return OggPacketScan(
                    packets: packets,
                    isTruncated: true,
                    minimumCompleteByteCount: cursor + 27
                )
            }
            guard data[cursor..<(cursor + 4)].elementsEqual(Data("OggS".utf8)),
                  data[cursor + 4] == 0 else {
                break
            }
            let segmentCount = Int(data[cursor + 26])
            let tableEnd = cursor + 27 + segmentCount
            guard tableEnd <= data.count else {
                return OggPacketScan(
                    packets: packets,
                    isTruncated: true,
                    minimumCompleteByteCount: tableEnd
                )
            }
            var bodyLength = 0
            for index in (cursor + 27)..<tableEnd {
                bodyLength += Int(data[index])
            }
            let pageEnd = tableEnd + bodyLength
            guard pageEnd <= data.count else {
                minimumCompleteByteCount = pageEnd
                return OggPacketScan(
                    packets: packets,
                    isTruncated: true,
                    minimumCompleteByteCount: minimumCompleteByteCount
                )
            }

            var bodyCursor = tableEnd
            for index in (cursor + 27)..<tableEnd {
                let length = Int(data[index])
                packet.append(data.subdata(in: bodyCursor..<(bodyCursor + length)))
                bodyCursor += length
                if length < 255 {
                    packets.append(packet)
                    packet.removeAll(keepingCapacity: true)
                    if packets.count >= 4 {
                        return OggPacketScan(
                            packets: packets,
                            isTruncated: false,
                            minimumCompleteByteCount: nil
                        )
                    }
                }
            }
            cursor = pageEnd
        }

        return OggPacketScan(
            packets: packets,
            isTruncated: !packet.isEmpty,
            minimumCompleteByteCount: minimumCompleteByteCount
        )
    }

    private static func oggCommentInspectionComplete(_ scan: OggPacketScan) -> Bool {
        if commentPayload(in: scan.packets) != nil { return true }
        guard let first = scan.packets.first else { return false }
        if first.starts(with: Data("OpusHead".utf8))
            || first.starts(with: Data([0x01]) + Data("vorbis".utf8))
            || first.starts(with: Data("Speex   ".utf8)) {
            return scan.packets.count >= 2 && !scan.isTruncated
        }
        return scan.packets.count >= 3 || (!scan.isTruncated && !scan.packets.isEmpty)
    }

    private static func parseOggComments(_ data: Data) -> EmbeddedTagMetadata? {
        let scan = scanOggPackets(data)
        guard let payload = commentPayload(in: scan.packets),
              let comments = parseVorbisCommentList(payload) else {
            return nil
        }
        return metadata(from: comments)
    }

    private static func commentPayload(in packets: [Data]) -> Data? {
        for packet in packets {
            let vorbisPrefix = Data([0x03]) + Data("vorbis".utf8)
            if packet.starts(with: vorbisPrefix) {
                return Data(packet.dropFirst(vorbisPrefix.count))
            }
            let opusPrefix = Data("OpusTags".utf8)
            if packet.starts(with: opusPrefix) {
                return Data(packet.dropFirst(opusPrefix.count))
            }
        }
        if packets.first?.starts(with: Data("Speex   ".utf8)) == true,
           packets.count >= 2 {
            return packets[1]
        }
        return nil
    }

    private static func parseVorbisCommentList(_ data: Data) -> [String: [String]]? {
        var cursor = 0
        guard let vendorLength = readBoundedUInt32LE(data, at: cursor) else { return nil }
        cursor += 4
        guard vendorLength <= data.count - cursor else { return nil }
        cursor += vendorLength
        guard let count = readBoundedUInt32LE(data, at: cursor), count <= 100_000 else {
            return nil
        }
        cursor += 4
        var comments: [String: [String]] = [:]
        for _ in 0..<count {
            guard let length = readBoundedUInt32LE(data, at: cursor) else { return nil }
            cursor += 4
            guard length <= data.count - cursor else { return nil }
            let item = data.subdata(in: cursor..<(cursor + length))
            cursor += length
            guard let string = String(data: item, encoding: .utf8),
                  let separator = string.firstIndex(of: "=") else {
                continue
            }
            let key = normalizedKey(String(string[..<separator]))
            let value = String(string[string.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            comments[key, default: []].append(value)
        }
        return comments
    }

    // MARK: - APEv2

    private static func parseAPEv2(_ data: Data) -> EmbeddedTagMetadata? {
        guard let footer = lastAPEv2Footer(in: data), footer + 32 <= data.count else {
            return nil
        }
        let tagSize = readUInt32LE(data, at: footer + 12)
        let itemCount = readUInt32LE(data, at: footer + 16)
        guard tagSize >= 32, tagSize <= maximumRangeByteCount,
              itemCount <= 100_000 else {
            return nil
        }
        let tagStart = footer + 32 - tagSize
        guard tagStart >= 0 else { return nil }
        var cursor = tagStart
        if cursor + 32 <= footer,
           data[cursor..<(cursor + 8)].elementsEqual(apeSignature) {
            cursor += 32
        }

        var values: [String: [String]] = [:]
        var cover: Data?
        for _ in 0..<itemCount {
            guard cursor + 8 <= footer else { return nil }
            let valueSize = readUInt32LE(data, at: cursor)
            let flags = readUInt32LE(data, at: cursor + 4)
            cursor += 8
            guard let keyEnd = data[cursor..<footer].firstIndex(of: 0) else { return nil }
            let keyData = data.subdata(in: cursor..<keyEnd)
            cursor = keyEnd + 1
            guard valueSize <= footer - cursor else { return nil }
            let value = data.subdata(in: cursor..<(cursor + valueSize))
            cursor += valueSize
            guard let rawKey = String(data: keyData, encoding: .utf8) else { continue }
            let key = normalizedKey(rawKey)
            let valueType = (flags >> 1) & 0x03
            if valueType == 0 {
                let strings = value.split(separator: 0, omittingEmptySubsequences: true)
                    .compactMap { String(data: Data($0), encoding: .utf8) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !strings.isEmpty { values[key, default: []].append(contentsOf: strings) }
            } else if valueType == 1,
                      ["COVER ART (FRONT)", "COVERART", "FRONT COVER"].contains(key),
                      cover == nil {
                let imageStart = value.firstIndex(of: 0).map { $0 + 1 } ?? 0
                if imageStart < value.count {
                    cover = normalizedImageData(value.subdata(in: imageStart..<value.count))
                }
            }
        }

        var metadata = metadata(from: values)
        metadata.coverArtData = metadata.coverArtData ?? cover
        return metadata.isEmpty ? nil : metadata
    }

    private static func lastAPEv2Footer(in data: Data) -> Int? {
        guard data.count >= 32 else { return nil }
        // The footer is either the final 32 bytes or immediately before an
        // ID3v1 footer. Restricting the signature to those two absolute EOF
        // positions prevents audio payload bytes from masquerading as a tag.
        let candidates = [data.count - 32, data.count - 160]
        for offset in candidates where offset >= 0 && offset + 32 <= data.count {
            if offset == data.count - 160,
               !data[(data.count - 128)..<(data.count - 125)]
                .elementsEqual(Data("TAG".utf8)) {
                continue
            }
            if data[offset..<(offset + 8)].elementsEqual(apeSignature),
               readUInt32LE(data, at: offset + 8) >= 1_000 {
                return offset
            }
        }
        return nil
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

    private static func asfHeaderByteCount(in data: Data) -> Int? {
        guard data.count >= 24,
              data.prefix(16).elementsEqual(asfHeaderGUID) else { return nil }
        let size = readUInt64LE(data, at: 16)
        guard size >= 30, size <= UInt64(Int.max) else { return nil }
        return Int(size)
    }

    private static func parseASF(_ data: Data) -> EmbeddedTagMetadata? {
        guard let declaredSize = asfHeaderByteCount(in: data),
              declaredSize <= data.count,
              data.count >= 30 else { return nil }
        let objectCount = readUInt32LE(data, at: 24)
        guard objectCount <= 100_000 else { return nil }
        var cursor = 30
        var values: [String: [String]] = [:]
        var cover: Data?

        for _ in 0..<objectCount {
            guard cursor + 24 <= declaredSize else { break }
            let guid = data.subdata(in: cursor..<(cursor + 16))
            let size64 = readUInt64LE(data, at: cursor + 16)
            guard size64 >= 24, size64 <= UInt64(Int.max) else { break }
            let objectEnd = cursor + Int(size64)
            guard objectEnd <= declaredSize else { break }
            let payloadStart = cursor + 24

            if guid == asfContentDescriptionGUID, payloadStart + 10 <= objectEnd {
                var lengthCursor = payloadStart
                let lengths = (0..<5).map { index in
                    readUInt16LE(data, at: lengthCursor + index * 2)
                }
                lengthCursor += 10
                let keys = ["TITLE", "AUTHOR", "COPYRIGHT", "DESCRIPTION", "RATING"]
                for (key, length) in zip(keys, lengths) {
                    guard length <= objectEnd - lengthCursor else { break }
                    if let text = decodedUTF16LE(data.subdata(in: lengthCursor..<(lengthCursor + length))) {
                        values[key, default: []].append(text)
                    }
                    lengthCursor += length
                }
            } else if guid == asfExtendedContentDescriptionGUID,
                      payloadStart + 2 <= objectEnd {
                let descriptorCount = readUInt16LE(data, at: payloadStart)
                var descriptorCursor = payloadStart + 2
                for _ in 0..<descriptorCount {
                    guard descriptorCursor + 2 <= objectEnd else { break }
                    let nameLength = readUInt16LE(data, at: descriptorCursor)
                    descriptorCursor += 2
                    guard nameLength <= objectEnd - descriptorCursor else { break }
                    let nameData = data.subdata(
                        in: descriptorCursor..<(descriptorCursor + nameLength)
                    )
                    descriptorCursor += nameLength
                    guard descriptorCursor + 4 <= objectEnd else { break }
                    let valueType = readUInt16LE(data, at: descriptorCursor)
                    let valueLength = readUInt16LE(data, at: descriptorCursor + 2)
                    descriptorCursor += 4
                    guard valueLength <= objectEnd - descriptorCursor else { break }
                    let valueData = data.subdata(
                        in: descriptorCursor..<(descriptorCursor + valueLength)
                    )
                    descriptorCursor += valueLength
                    guard let name = decodedUTF16LE(nameData) else { continue }
                    let key = normalizedKey(name)
                    if key == "WM/PICTURE", valueType == 1, cover == nil {
                        cover = parseASFPicture(valueData)
                    } else if let text = decodedASFValue(valueData, type: valueType) {
                        values[key, default: []].append(text)
                    }
                }
            }
            cursor = objectEnd
        }

        var metadata = metadata(from: values)
        metadata.coverArtData = metadata.coverArtData ?? cover
        return metadata.isEmpty ? nil : metadata
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

    private static func parseRIFFInfo(_ data: Data) -> EmbeddedTagMetadata? {
        guard data.count >= 12,
              data.prefix(4).elementsEqual(Data("RIFF".utf8)),
              data[8..<12].elementsEqual(Data("WAVE".utf8)) else { return nil }
        var cursor = 12
        var values: [String: [String]] = [:]
        while cursor + 8 <= data.count {
            guard let identifier = ascii(data, at: cursor, count: 4) else { break }
            let length = readUInt32LE(data, at: cursor + 4)
            let bodyStart = cursor + 8
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.count else { break }
            if identifier == "LIST", length >= 4,
               data[bodyStart..<(bodyStart + 4)].elementsEqual(Data("INFO".utf8)) {
                var infoCursor = bodyStart + 4
                while infoCursor + 8 <= bodyEnd {
                    guard let key = ascii(data, at: infoCursor, count: 4) else { break }
                    let valueLength = readUInt32LE(data, at: infoCursor + 4)
                    let valueStart = infoCursor + 8
                    let valueEnd = valueStart + valueLength
                    guard valueEnd <= bodyEnd else { break }
                    if let value = decodedNullTerminatedText(
                        data.subdata(in: valueStart..<valueEnd)
                    ) {
                        values[normalizedKey(key), default: []].append(value)
                    }
                    infoCursor = valueEnd + (valueLength.isMultiple(of: 2) ? 0 : 1)
                }
            }
            cursor = bodyEnd + (length.isMultiple(of: 2) ? 0 : 1)
        }
        let result = metadata(from: values)
        return result.isEmpty ? nil : result
    }

    private static func parseAIFFText(_ data: Data) -> EmbeddedTagMetadata? {
        guard data.count >= 12,
              data.prefix(4).elementsEqual(Data("FORM".utf8)),
              (data[8..<12].elementsEqual(Data("AIFF".utf8))
                || data[8..<12].elementsEqual(Data("AIFC".utf8))) else { return nil }
        var cursor = 12
        var values: [String: [String]] = [:]
        while cursor + 8 <= data.count {
            guard let identifier = ascii(data, at: cursor, count: 4) else { break }
            let length = readUInt32BE(data, at: cursor + 4)
            let bodyStart = cursor + 8
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.count else { break }
            let mappedKey: String? = switch identifier {
            case "NAME": "TITLE"
            case "AUTH": "ARTIST"
            case "(c) ": "COPYRIGHT"
            case "ANNO": "COMMENT"
            default: nil
            }
            if let mappedKey,
               let value = decodedNullTerminatedText(data.subdata(in: bodyStart..<bodyEnd)) {
                values[mappedKey, default: []].append(value)
            }
            cursor = bodyEnd + (length.isMultiple(of: 2) ? 0 : 1)
        }
        let result = metadata(from: values)
        return result.isEmpty ? nil : result
    }

    // MARK: - Embedded ID3 chunks

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

    private static func bigEndianID3Chunk(in data: Data) -> Data? {
        var cursor = data.prefix(4).elementsEqual(Data("FORM".utf8)) ? 12 : 0
        while cursor + 8 <= data.count {
            guard let identifier = ascii(data, at: cursor, count: 4) else { break }
            let headerSize = identifier == "ID3 " && cursor + 12 <= data.count ? 12 : 8
            let length: Int
            if headerSize == 12 {
                let size64 = readUInt64BE(data, at: cursor + 4)
                guard size64 <= UInt64(Int.max) else { break }
                length = Int(size64)
            } else {
                length = readUInt32BE(data, at: cursor + 4)
            }
            let bodyStart = cursor + headerSize
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.count else { break }
            if identifier == "ID3 " {
                return completeID3Tag(in: data.subdata(in: bodyStart..<bodyEnd))
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
        var searchStart = 0
        while searchStart + 10 <= data.count,
              let range = data.range(of: id3Signature, in: searchStart..<data.count) {
            let start = range.lowerBound
            let candidate = data.subdata(in: start..<data.count)
            if let byteCount = id3TagByteCount(in: candidate) {
                let end = start + byteCount
                let endsAtEOF = end == data.count
                let endsBeforeID3v1 = end == data.count - 128
                    && data.count >= 128
                    && data[(data.count - 128)..<(data.count - 125)]
                        .elementsEqual(Data("TAG".utf8))
                if byteCount <= candidate.count, endsAtEOF || endsBeforeID3v1 {
                    return candidate.subdata(in: 0..<byteCount)
                }
            }
            searchStart = start + 1
        }
        return nil
    }

    // MARK: - Shared field mapping

    private static func metadata(from values: [String: [String]]) -> EmbeddedTagMetadata {
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
        let track = first("TRACKNUMBER", "TRACK", "WM/TRACKNUMBER", "IPRT", "ITRK")
        let disc = first("DISCNUMBER", "DISC", "WM/PARTOFSET")
        let date = first("DATE", "YEAR", "WM/YEAR", "ICRD")
        var result = EmbeddedTagMetadata(
            title: first("TITLE", "WM/TITLE", "INAM"),
            artist: artists?.joined(separator: "; "),
            artists: artists,
            albumTitle: first("ALBUM", "ALBUMTITLE", "WM/ALBUMTITLE", "IPRD"),
            albumArtist: first(
                "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST", "WM/ALBUMARTIST"
            ),
            trackNumber: track.flatMap(leadingInteger),
            discNumber: disc.flatMap(leadingInteger),
            year: date.flatMap(year),
            genre: first("GENRE", "WM/GENRE", "IGNR"),
            lyrics: first("LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS", "WM/LYRICS"),
            replayGainTrackGain: first("REPLAYGAIN_TRACK_GAIN").flatMap(replayGain),
            replayGainTrackPeak: first("REPLAYGAIN_TRACK_PEAK").flatMap(Double.init),
            replayGainAlbumGain: first("REPLAYGAIN_ALBUM_GAIN").flatMap(replayGain),
            replayGainAlbumPeak: first("REPLAYGAIN_ALBUM_PEAK").flatMap(Double.init)
        )

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

    private static func decodedNullTerminatedText(_ data: Data) -> String? {
        let bytes = data.prefix(while: { $0 != 0 })
        guard !bytes.isEmpty else { return nil }
        let value = String(data: Data(bytes), encoding: .utf8)
            ?? String(data: Data(bytes), encoding: .isoLatin1)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
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
