import AVFoundation
import Foundation
import PrimuseKit

enum FileMetadataReader {
    struct Metadata {
        var title: String?
        var artist: String?
        var albumTitle: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var genre: String?
        var duration: TimeInterval?
        var coverArtData: Data?
        var sampleRate: Int?
        var bitRate: Int?
        var bitDepth: Int?
        var replayGainTrackGain: Double?
        var replayGainTrackPeak: Double?
        var replayGainAlbumGain: Double?
        var replayGainAlbumPeak: Double?
        var lyricsText: String?
    }

    /// Reads metadata from an audio file using AVFoundation
    static func read(from url: URL) async -> Metadata {
        var metadata = Metadata()

        let asset = AVURLAsset(url: url)

        // Get duration
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 {
                metadata.duration = seconds
            }
        }

        // Read metadata items
        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                let value = try? await item.load(.value)

                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue:
                    metadata.title = decodedText(value)
                case AVMetadataKey.commonKeyArtist.rawValue:
                    metadata.artist = decodedText(value)
                case AVMetadataKey.commonKeyAlbumName.rawValue:
                    metadata.albumTitle = decodedText(value)
                case AVMetadataKey.commonKeyArtwork.rawValue:
                    if let data = value as? Data {
                        metadata.coverArtData = data
                    }
                default:
                    break
                }
            }

            // Try format-specific metadata for more detail
            for item in items {
                guard let identifier = item.identifier else { continue }
                let value = try? await item.load(.value)

                switch identifier {
                case .id3MetadataTrackNumber, .iTunesMetadataTrackNumber:
                    if let str = decodedText(value) {
                        metadata.trackNumber = Int(str.split(separator: "/").first.map(String.init) ?? "")
                    } else if let num = value as? Int {
                        metadata.trackNumber = num
                    }
                case .id3MetadataPartOfASet:
                    if let str = decodedText(value) {
                        metadata.discNumber = Int(str.split(separator: "/").first.map(String.init) ?? "")
                    }
                case .id3MetadataYear, .id3MetadataRecordingTime:
                    if let str = decodedText(value) {
                        metadata.year = Int(String(str.prefix(4)))
                    }
                case .id3MetadataContentType:
                    metadata.genre = decodedText(value)
                case .id3MetadataUnsynchronizedLyric:
                    if let text = decodedText(value), !text.isEmpty {
                        metadata.lyricsText = text
                    }
                case .iTunesMetadataLyrics:
                    if let text = decodedText(value), !text.isEmpty, metadata.lyricsText == nil {
                        metadata.lyricsText = text
                    }
                case .id3MetadataUserText:
                    // TXXX frames: ReplayGain tags stored in extraAttributes[.info]
                    if let extras = try? await item.load(.extraAttributes),
                       let desc = extras[.info] as? String {
                        let stringValue = try? await item.load(.stringValue)
                        switch desc.lowercased() {
                        case "replaygain_track_gain":
                            metadata.replayGainTrackGain = parseReplayGainDB(stringValue)
                        case "replaygain_track_peak":
                            metadata.replayGainTrackPeak = Double(stringValue ?? "")
                        case "replaygain_album_gain":
                            metadata.replayGainAlbumGain = parseReplayGainDB(stringValue)
                        case "replaygain_album_peak":
                            metadata.replayGainAlbumPeak = Double(stringValue ?? "")
                        default:
                            break
                        }
                    }
                default:
                    break
                }
            }
        }

        // Get audio format details
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                if track.mediaType == .audio {
                    if let formatDescriptions = try? await track.load(.formatDescriptions) {
                        for desc in formatDescriptions {
                            let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                            if let basic = basicDescription?.pointee {
                                metadata.sampleRate = Int(basic.mSampleRate)
                                metadata.bitDepth = Int(basic.mBitsPerChannel)
                            }
                        }
                    }

                    if let bitRate = try? await track.load(.estimatedDataRate) {
                        metadata.bitRate = Int(bitRate / 1000) // kbps
                    }
                }
            }
        }

        applyID3Fallback(to: &metadata, url: url)
        applyFLACFallback(to: &metadata, url: url)

        // 注意: 不在这里用 url filename 兜底 title。
        // 调用方 (MetadataService) 自己决定 fallback 名 (走原始 NAS 文件名),
        // 这里要保持 metadata.title == nil 真实反映「文件里没有 TIT2」。
        // 否则 cache 内 sanitized 文件名 (如 "_music_xxx") 会被当成嵌入标题,
        // 污染 scrape 查询和 UI 预览。

        return metadata
    }

    private static let id3MetadataReadLimit = 4 * 1024 * 1024
    private static let flacMetadataReadLimit = 1024 * 1024

    private static func applyID3Fallback(to metadata: inout Metadata, url: URL) {
        let tagData = readID3TagData(from: url)
        let text = ID3TextMetadataParser.parse(tagData)
        let artwork = parseID3Metadata(from: tagData)
        guard text != nil || artwork != nil else { return }

        // AVFoundation may reject a truncated cloud-Range temp file even
        // though its complete ID3v2 tag is present at byte zero. Keep its
        // values when available, but fill every missing field from the small
        // native parser below. Previously this fallback only recovered APIC,
        // so a readable TIT2 still fell back to the filename.
        metadata.title = metadata.title ?? text?.title
        metadata.artist = metadata.artist ?? text?.artist
        metadata.albumTitle = metadata.albumTitle ?? text?.albumTitle
        metadata.albumArtist = metadata.albumArtist ?? text?.albumArtist
        metadata.trackNumber = metadata.trackNumber ?? text?.trackNumber
        metadata.discNumber = metadata.discNumber ?? text?.discNumber
        metadata.year = metadata.year ?? text?.year
        metadata.genre = metadata.genre ?? text?.genre
        metadata.coverArtData = metadata.coverArtData ?? artwork?.coverArtData
    }

    static func id3TagByteCount(in data: Data) -> Int? {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            return nil
        }
        let tagSize = readSyncSafeInt(data, at: 6)
        let hasFooter = (data[5] & 0x10) != 0
        return 10 + tagSize + (hasFooter ? 10 : 0)
    }

    private static func readID3TagData(from url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 10),
              let tagByteCount = id3TagByteCount(in: header) else {
            return Data()
        }

        let cappedByteCount = min(tagByteCount, id3MetadataReadLimit)
        try? handle.seek(toOffset: 0)
        return (try? handle.read(upToCount: cappedByteCount)) ?? Data()
    }

    private struct ID3NativeMetadata {
        var coverArtData: Data?
    }

    private struct ID3Picture {
        var type: Int
        var data: Data
    }

    private static func parseID3Metadata(from data: Data) -> ID3NativeMetadata? {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            return nil
        }
        let majorVersion = Int(data[3])
        guard (2...4).contains(majorVersion),
              let tagByteCount = id3TagByteCount(in: data) else {
            return nil
        }

        let tagEnd = min(data.count, tagByteCount)
        guard tagEnd > 10 else { return nil }

        var tag = data.subdata(in: 10..<tagEnd)
        if (data[5] & 0x80) != 0 {
            tag = removeID3Unsynchronization(from: tag)
        }

        var cursor = id3ExtendedHeaderLength(in: tag, version: majorVersion, flags: data[5])
        var pictures: [ID3Picture] = []

        while cursor < tag.count {
            if majorVersion == 2 {
                guard cursor + 6 <= tag.count else { break }
                guard let frameID = asciiString(tag, start: cursor, length: 3),
                      !frameID.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty else {
                    break
                }
                let frameSize = readUInt24BE(tag, at: cursor + 3)
                cursor += 6
                guard frameSize > 0, cursor + frameSize <= tag.count else { break }
                let payload = tag.subdata(in: cursor..<(cursor + frameSize))
                cursor += frameSize

                if frameID == "PIC", let picture = parseID3PictureFrame(payload, isV22PIC: true) {
                    pictures.append(picture)
                }
            } else {
                guard cursor + 10 <= tag.count else { break }
                guard let frameID = asciiString(tag, start: cursor, length: 4),
                      !frameID.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty else {
                    break
                }
                let frameSize = majorVersion == 4
                    ? readSyncSafeInt(tag, at: cursor + 4)
                    : readUInt32BE(tag, at: cursor + 4)
                let formatFlags = tag[cursor + 9]
                cursor += 10
                guard frameSize > 0, cursor + frameSize <= tag.count else { break }

                var payload = tag.subdata(in: cursor..<(cursor + frameSize))
                cursor += frameSize

                if majorVersion == 4, (formatFlags & 0x02) != 0 {
                    payload = removeID3Unsynchronization(from: payload)
                }

                if frameID == "APIC", let picture = parseID3PictureFrame(payload, isV22PIC: false) {
                    pictures.append(picture)
                }
            }
        }

        let preferred = pictures.first(where: { $0.type == 3 }) ?? pictures.first
        guard let preferred else { return nil }
        return ID3NativeMetadata(coverArtData: preferred.data)
    }

    private static func id3ExtendedHeaderLength(in tag: Data, version: Int, flags: UInt8) -> Int {
        guard (flags & 0x40) != 0 else { return 0 }
        if version == 3 {
            guard tag.count >= 4 else { return tag.count }
            return min(tag.count, 4 + readUInt32BE(tag, at: 0))
        }
        if version == 4 {
            guard tag.count >= 4 else { return tag.count }
            return min(tag.count, readSyncSafeInt(tag, at: 0))
        }
        return 0
    }

    private static func parseID3PictureFrame(_ payload: Data, isV22PIC: Bool) -> ID3Picture? {
        guard payload.count > (isV22PIC ? 5 : 4) else { return nil }
        let encoding = payload[0]
        var cursor = 1

        if isV22PIC {
            cursor += 3 // image format, e.g. JPG/PNG
        } else {
            guard let mimeEnd = firstZeroByte(in: payload, from: cursor) else { return nil }
            cursor = mimeEnd + 1
        }

        guard cursor < payload.count else { return nil }
        let pictureType = Int(payload[cursor])
        cursor += 1

        guard let imageStart = encodedStringTerminatorEnd(in: payload, from: cursor, encoding: encoding),
              imageStart < payload.count else {
            return nil
        }

        let rawImage = payload.subdata(in: imageStart..<payload.count)
        guard let imageData = normalizedEmbeddedImageData(rawImage) else { return nil }
        return ID3Picture(type: pictureType, data: imageData)
    }

    private static func encodedStringTerminatorEnd(in data: Data, from start: Int, encoding: UInt8) -> Int? {
        guard start <= data.count else { return nil }
        if encoding == 1 || encoding == 2 {
            guard start + 1 <= data.count else { return nil }
            var i = start
            while i + 1 < data.count {
                if data[i] == 0, data[i + 1] == 0 {
                    return i + 2
                }
                i += 1
            }
            return nil
        }
        guard let end = firstZeroByte(in: data, from: start) else { return nil }
        return end + 1
    }

    private static func normalizedEmbeddedImageData(_ data: Data) -> Data? {
        if isSupportedImageData(data) { return data }

        for signature in embeddedImageSignatures {
            if let range = data.range(of: signature, options: [], in: data.startIndex..<data.endIndex),
               range.lowerBound < min(data.count, 64) {
                let sliced = data.subdata(in: range.lowerBound..<data.endIndex)
                if isSupportedImageData(sliced) { return sliced }
            }
        }
        return nil
    }

    private static let embeddedImageSignatures: [Data] = [
        Data([0xFF, 0xD8, 0xFF]), // JPEG
        Data([0x89, 0x50, 0x4E, 0x47]), // PNG
        Data("GIF8".utf8),
        Data("RIFF".utf8),
        Data("BM".utf8)
    ]

    private static func isSupportedImageData(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        if data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return true }
        if data.count >= 8,
           data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47,
           data[4] == 0x0D, data[5] == 0x0A, data[6] == 0x1A, data[7] == 0x0A { return true }
        if asciiString(data, start: 0, length: 4) == "GIF8" { return true }
        if data.count >= 12,
           asciiString(data, start: 0, length: 4) == "RIFF",
           asciiString(data, start: 8, length: 4) == "WEBP" { return true }
        if data[0] == 0x42, data[1] == 0x4D { return true }
        return false
    }

    private static func firstZeroByte(in data: Data, from start: Int) -> Int? {
        guard start < data.count else { return nil }
        return data[start..<data.count].firstIndex(of: 0)
    }

    private static func removeID3Unsynchronization(from data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            let byte = data[i]
            result.append(byte)
            if byte == 0xFF, i + 1 < data.count, data[i + 1] == 0 {
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private static func applyFLACFallback(to metadata: inout Metadata, url: URL) {
        guard url.pathExtension.lowercased() == "flac",
              let flac = parseFLACMetadata(from: readPrefix(from: url, byteCount: flacMetadataReadLimit)) else {
            return
        }

        if metadata.duration == nil || (metadata.duration ?? 0) <= 0 {
            metadata.duration = flac.duration
        }
        metadata.sampleRate = metadata.sampleRate ?? flac.sampleRate
        metadata.bitDepth = metadata.bitDepth ?? flac.bitDepth
        metadata.title = metadata.title ?? flac.title
        metadata.artist = metadata.artist ?? flac.artist
        metadata.albumTitle = metadata.albumTitle ?? flac.albumTitle
        metadata.albumArtist = metadata.albumArtist ?? flac.albumArtist
        metadata.trackNumber = metadata.trackNumber ?? flac.trackNumber
        metadata.discNumber = metadata.discNumber ?? flac.discNumber
        metadata.year = metadata.year ?? flac.year
        metadata.genre = metadata.genre ?? flac.genre
        metadata.lyricsText = metadata.lyricsText ?? flac.lyricsText
        metadata.coverArtData = metadata.coverArtData ?? flac.coverArtData
        metadata.replayGainTrackGain = metadata.replayGainTrackGain ?? flac.replayGainTrackGain
        metadata.replayGainTrackPeak = metadata.replayGainTrackPeak ?? flac.replayGainTrackPeak
        metadata.replayGainAlbumGain = metadata.replayGainAlbumGain ?? flac.replayGainAlbumGain
        metadata.replayGainAlbumPeak = metadata.replayGainAlbumPeak ?? flac.replayGainAlbumPeak
    }

    private static func readPrefix(from url: URL, byteCount: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: byteCount)) ?? Data()
    }

    private struct FLACNativeMetadata {
        var title: String?
        var artist: String?
        var albumTitle: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var genre: String?
        var duration: TimeInterval?
        var coverArtData: Data?
        var sampleRate: Int?
        var bitDepth: Int?
        var replayGainTrackGain: Double?
        var replayGainTrackPeak: Double?
        var replayGainAlbumGain: Double?
        var replayGainAlbumPeak: Double?
        var lyricsText: String?
    }

    private static func parseFLACMetadata(from data: Data) -> FLACNativeMetadata? {
        guard let flacOffset = findFLACSignature(in: data) else { return nil }

        var result = FLACNativeMetadata()
        var cursor = flacOffset + 4

        while cursor + 4 <= data.count {
            let header = data[cursor]
            let isLastBlock = (header & 0x80) != 0
            let blockType = header & 0x7F
            let length = readUInt24BE(data, at: cursor + 1)
            let bodyStart = cursor + 4
            let bodyEnd = bodyStart + length
            guard length >= 0, bodyEnd >= bodyStart, bodyEnd <= data.count else { break }

            let block = data.subdata(in: bodyStart..<bodyEnd)
            switch blockType {
            case 0:
                applyFLACStreamInfo(block, to: &result)
            case 4:
                applyVorbisComments(block, to: &result)
            case 6:
                if result.coverArtData == nil {
                    result.coverArtData = parseFLACPicture(block)
                }
            default:
                break
            }

            cursor = bodyEnd
            if isLastBlock { break }
        }

        return result.duration != nil
            || result.title != nil
            || result.artist != nil
            || result.albumTitle != nil
            || result.coverArtData != nil
            ? result
            : nil
    }

    private static func findFLACSignature(in data: Data) -> Int? {
        let signature = Data([0x66, 0x4C, 0x61, 0x43]) // fLaC
        if data.count >= 4, Data(data[0..<4]) == signature {
            return 0
        }

        if data.count >= 10,
           data[0] == 0x49, data[1] == 0x44, data[2] == 0x33,
           let id3End = readID3v2Length(data),
           id3End + 4 <= data.count,
           Data(data[id3End..<(id3End + 4)]) == signature {
            return id3End
        }

        let searchEnd = min(data.count, 64 * 1024)
        return data.range(of: signature, options: [], in: 0..<searchEnd)?.lowerBound
    }

    private static func readID3v2Length(_ data: Data) -> Int? {
        guard data.count >= 10 else { return nil }
        let size = (Int(data[6] & 0x7F) << 21)
            | (Int(data[7] & 0x7F) << 14)
            | (Int(data[8] & 0x7F) << 7)
            | Int(data[9] & 0x7F)
        let hasFooter = (data[5] & 0x10) != 0
        return 10 + size + (hasFooter ? 10 : 0)
    }

    private static func applyFLACStreamInfo(_ block: Data, to result: inout FLACNativeMetadata) {
        guard block.count >= 18 else { return }

        let sampleRate = (Int(block[10]) << 12)
            | (Int(block[11]) << 4)
            | (Int(block[12]) >> 4)
        let bitDepth = (((Int(block[12]) & 0x01) << 4) | (Int(block[13]) >> 4)) + 1
        let totalSamples = (UInt64(block[13] & 0x0F) << 32)
            | (UInt64(block[14]) << 24)
            | (UInt64(block[15]) << 16)
            | (UInt64(block[16]) << 8)
            | UInt64(block[17])

        if sampleRate > 0 {
            result.sampleRate = sampleRate
            if totalSamples > 0 {
                result.duration = Double(totalSamples) / Double(sampleRate)
            }
        }
        if bitDepth > 0 {
            result.bitDepth = bitDepth
        }
    }

    private static func applyVorbisComments(_ block: Data, to result: inout FLACNativeMetadata) {
        var cursor = 0
        guard let vendorLength = readUInt32LE(block, cursor: &cursor),
              skip(vendorLength, in: block, cursor: &cursor),
              let commentCount = readUInt32LE(block, cursor: &cursor) else {
            return
        }

        var comments: [String: [String]] = [:]
        for _ in 0..<min(commentCount, 10_000) {
            guard let length = readUInt32LE(block, cursor: &cursor),
                  cursor + length <= block.count else {
                break
            }
            let raw = block.subdata(in: cursor..<(cursor + length))
            cursor += length

            guard let text = String(data: raw, encoding: .utf8),
                  let separator = text.firstIndex(of: "=") else {
                continue
            }
            let key = String(text[..<separator]).uppercased()
            let value = String(text[text.index(after: separator)...])
            comments[key, default: []].append(value)
        }

        func first(_ keys: String...) -> String? {
            for key in keys {
                if let value = comments[key]?.first {
                    let repaired = repairLegacyChineseMojibake(value.trimmingCharacters(in: .whitespacesAndNewlines))
                    if let cleaned = repaired.nilIfEmpty { return cleaned }
                }
            }
            return nil
        }

        result.title = result.title ?? first("TITLE")
        result.artist = result.artist ?? first("ARTIST", "ALBUMARTIST", "ALBUM ARTIST")
        result.albumTitle = result.albumTitle ?? first("ALBUM")
        result.albumArtist = result.albumArtist ?? first("ALBUMARTIST", "ALBUM ARTIST")
        result.trackNumber = result.trackNumber ?? leadingInt(first("TRACKNUMBER", "TRACK"))
        result.discNumber = result.discNumber ?? leadingInt(first("DISCNUMBER", "DISC"))
        result.year = result.year ?? parseYear(first("DATE", "YEAR"))
        result.genre = result.genre ?? first("GENRE")
        result.lyricsText = result.lyricsText ?? first("LYRICS", "UNSYNCEDLYRICS")
        result.replayGainTrackGain = result.replayGainTrackGain ?? parseReplayGainDB(first("REPLAYGAIN_TRACK_GAIN"))
        result.replayGainTrackPeak = result.replayGainTrackPeak ?? Double(first("REPLAYGAIN_TRACK_PEAK") ?? "")
        result.replayGainAlbumGain = result.replayGainAlbumGain ?? parseReplayGainDB(first("REPLAYGAIN_ALBUM_GAIN"))
        result.replayGainAlbumPeak = result.replayGainAlbumPeak ?? Double(first("REPLAYGAIN_ALBUM_PEAK") ?? "")
    }

    private static func parseFLACPicture(_ block: Data) -> Data? {
        var cursor = 0
        guard readUInt32BE(block, cursor: &cursor) != nil,
              let mimeLength = readUInt32BE(block, cursor: &cursor),
              skip(mimeLength, in: block, cursor: &cursor),
              let descriptionLength = readUInt32BE(block, cursor: &cursor),
              skip(descriptionLength, in: block, cursor: &cursor),
              skip(16, in: block, cursor: &cursor),
              let imageLength = readUInt32BE(block, cursor: &cursor),
              imageLength > 0,
              cursor + imageLength <= block.count else {
            return nil
        }
        return block.subdata(in: cursor..<(cursor + imageLength))
    }

    private static func readUInt24BE(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 3 else { return 0 }
        return (Int(data[offset]) << 16)
            | (Int(data[offset + 1]) << 8)
            | Int(data[offset + 2])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 4 else { return 0 }
        return (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    private static func readSyncSafeInt(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 4 else { return 0 }
        return (Int(data[offset] & 0x7F) << 21)
            | (Int(data[offset + 1] & 0x7F) << 14)
            | (Int(data[offset + 2] & 0x7F) << 7)
            | Int(data[offset + 3] & 0x7F)
    }

    private static func asciiString(_ data: Data, start: Int, length: Int) -> String? {
        guard start >= 0, length >= 0, start <= data.count, length <= data.count - start else {
            return nil
        }
        return String(data: data.subdata(in: start..<(start + length)), encoding: .isoLatin1)
    }

    private static func readUInt32LE(_ data: Data, cursor: inout Int) -> Int? {
        guard cursor + 4 <= data.count else { return nil }
        let value = Int(data[cursor])
            | (Int(data[cursor + 1]) << 8)
            | (Int(data[cursor + 2]) << 16)
            | (Int(data[cursor + 3]) << 24)
        cursor += 4
        return value
    }

    private static func readUInt32BE(_ data: Data, cursor: inout Int) -> Int? {
        guard cursor + 4 <= data.count else { return nil }
        let value = (Int(data[cursor]) << 24)
            | (Int(data[cursor + 1]) << 16)
            | (Int(data[cursor + 2]) << 8)
            | Int(data[cursor + 3])
        cursor += 4
        return value
    }

    private static func skip(_ byteCount: Int, in data: Data, cursor: inout Int) -> Bool {
        guard byteCount >= 0, cursor + byteCount <= data.count else { return false }
        cursor += byteCount
        return true
    }

    private static func leadingInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(String(digits))
    }

    private static func parseYear(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4)
        return digits.count == 4 ? Int(String(digits)) : nil
    }

    /// Parse ReplayGain dB string like "-7.43 dB" or "+3.21 dB" to Double
    private static func parseReplayGainDB(_ value: String?) -> Double? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: " dB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private static func decodedText(_ value: Any?) -> String? {
        if let text = value as? String {
            return repairLegacyChineseMojibake(text).nilIfEmpty
        }

        if let data = value as? Data {
            return decodeTextData(data)?.nilIfEmpty
        }

        return nil
    }

    private static func decodeTextData(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        // ID3 text frames may carry a leading text encoding byte.
        let firstByte = data[data.startIndex]
        if [0, 1, 2, 3].contains(firstByte) {
            let payload = data.dropFirst()
            let decoded: String?

            switch firstByte {
            case 0:
                decoded = bestDecodedString(from: Data(payload), encodings: [gb18030Encoding, .isoLatin1, .windowsCP1252])
            case 1:
                decoded = bestDecodedString(from: Data(payload), encodings: [.utf16, .utf16LittleEndian, .utf16BigEndian])
            case 2:
                decoded = bestDecodedString(from: Data(payload), encodings: [.utf16BigEndian])
            case 3:
                decoded = bestDecodedString(from: Data(payload), encodings: [.utf8])
            default:
                decoded = nil
            }

            if let decoded {
                return repairLegacyChineseMojibake(decoded)
            }
        }

        return bestDecodedString(from: data, encodings: [.utf8, gb18030Encoding, .utf16, .isoLatin1, .windowsCP1252])
            .map(repairLegacyChineseMojibake)
    }

    static func repairLegacyChineseMojibake(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\0", with: "")
        guard looksLikeLegacyChineseMojibake(normalized) else { return normalized }

        let candidates = repairedTextCandidates(from: normalized)
        guard let best = candidates.max(by: { candidateScore($0, original: normalized) < candidateScore($1, original: normalized) }),
              shouldUseRepairedText(best, over: normalized) else {
            return normalized
        }

        return best
    }

    private static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    private static func bestDecodedString(from data: Data, encodings: [String.Encoding]) -> String? {
        let candidates = encodings.compactMap { String(data: data, encoding: $0) }
        guard !candidates.isEmpty else { return nil }

        return candidates.max { lhs, rhs in
            decodedStringScore(lhs) < decodedStringScore(rhs)
        }?.replacingOccurrences(of: "\0", with: "")
    }

    private static func repairedTextCandidates(from text: String) -> [String] {
        var candidates: [String] = []

        for sourceEncoding in [String.Encoding.isoLatin1, .windowsCP1252] {
            guard let bytes = text.data(using: sourceEncoding) else { continue }

            if let utf8 = String(data: bytes, encoding: .utf8) {
                candidates.append(utf8.replacingOccurrences(of: "\0", with: ""))
            }

            if let gb18030 = String(data: bytes, encoding: gb18030Encoding) {
                candidates.append(gb18030.replacingOccurrences(of: "\0", with: ""))
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func looksLikeLegacyChineseMojibake(_ text: String) -> Bool {
        suspiciousMojibakeScalarCount(in: text) >= 2
    }

    private static func shouldUseRepairedText(_ candidate: String, over original: String) -> Bool {
        candidate != original
            && cjkScalarCount(in: candidate) > cjkScalarCount(in: original)
            && cjkScalarCount(in: candidate) > 0
            && suspiciousMojibakeScalarCount(in: candidate) < suspiciousMojibakeScalarCount(in: original)
            && replacementCharacterCount(in: candidate) == 0
    }

    private static func candidateScore(_ candidate: String, original: String) -> Int {
        decodedStringScore(candidate)
            + cjkScalarCount(in: candidate) * 8
            - abs(candidate.count - original.count)
    }

    private static func decodedStringScore(_ text: String) -> Int {
        cjkScalarCount(in: text) * 5
            - suspiciousMojibakeScalarCount(in: text) * 3
            - replacementCharacterCount(in: text) * 12
    }

    private static func cjkScalarCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            let value = scalar.value
            return count + (isCJKScalar(value) ? 1 : 0)
        }
    }

    private static func suspiciousMojibakeScalarCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            let value = scalar.value
            return count + ((0x00A1...0x00FF).contains(value) ? 1 : 0)
        }
    }

    private static func replacementCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + (scalar.value == 0xFFFD ? 1 : 0)
        }
    }

    private static func isCJKScalar(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
