import AVFoundation
import Foundation
import PrimuseKit
import SFBAudioEngine

enum FileMetadataReader {
    struct Metadata {
        var title: String?
        var artist: String?
        var sourceArtistNames: [String]?
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

        mutating func fillMissing(from fallback: Metadata) {
            title = title ?? fallback.title
            artist = artist ?? fallback.artist
            sourceArtistNames = sourceArtistNames ?? fallback.sourceArtistNames
            if let sourceArtistNames, sourceArtistNames.count > 1 {
                artist = sourceArtistNames.joined(separator: "; ")
            }
            albumTitle = albumTitle ?? fallback.albumTitle
            albumArtist = albumArtist ?? fallback.albumArtist
            trackNumber = trackNumber ?? fallback.trackNumber
            discNumber = discNumber ?? fallback.discNumber
            year = year ?? fallback.year
            genre = genre ?? fallback.genre
            if !(duration?.isFinite == true && (duration ?? 0) > 0) {
                duration = fallback.duration
            }
            coverArtData = coverArtData ?? fallback.coverArtData
            if (sampleRate ?? 0) <= 0 { sampleRate = fallback.sampleRate }
            if (bitRate ?? 0) <= 0 { bitRate = fallback.bitRate }
            if (bitDepth ?? 0) <= 0 { bitDepth = fallback.bitDepth }
            replayGainTrackGain = replayGainTrackGain ?? fallback.replayGainTrackGain
            replayGainTrackPeak = replayGainTrackPeak ?? fallback.replayGainTrackPeak
            replayGainAlbumGain = replayGainAlbumGain ?? fallback.replayGainAlbumGain
            replayGainAlbumPeak = replayGainAlbumPeak ?? fallback.replayGainAlbumPeak
            if lyricsText == nil
                || lyricsText.map(TextEncodingRepair.requiresRawByteVerification) == true {
                lyricsText = fallback.lyricsText ?? lyricsText
            }
        }
    }

    /// Reads metadata from an audio file using AVFoundation.
    static func read(from url: URL) async -> Metadata {
        let asset = AVURLAsset(url: url)
        var metadata = await read(from: asset)

        if let metadataFile = readISOBaseMediaMetadataFile(from: url) {
            applyISOBaseMediaLyricsFallback(
                to: &metadata,
                data: metadataFile,
                fileExtension: url.pathExtension
            )
        }

        applyID3Fallback(to: &metadata, data: readID3FallbackData(from: url))
        applyFLACFallback(
            to: &metadata,
            data: readFLACMetadataPrefix(from: url),
            fileExtension: url.pathExtension
        )
        applyWAVEFallback(
            to: &metadata,
            data: readPrefix(from: url, byteCount: waveHeaderReadLimit),
            fileExtension: url.pathExtension
        )
        applyMPEGFrameFallback(
            to: &metadata,
            data: readPrefix(from: url, byteCount: mpegHeaderReadLimit),
            fileExtension: url.pathExtension
        )
        let fileExtension = url.pathExtension.lowercased()
        if boundedContainerTagExtensions.contains(fileExtension) {
            let head = readExpandableContainerHead(from: url)
            let tail = apeTailTagExtensions.contains(fileExtension)
                ? readExpandableContainerTail(from: url)
                : nil
            applyContainerTagFallback(
                to: &metadata,
                headData: head,
                tailData: tail,
                fileExtension: fileExtension
            )
        }
        applySFBAudioFallback(to: &metadata, url: url)

        // 注意: 不在这里用 url filename 兜底 title。
        // 调用方 (MetadataService) 自己决定 fallback 名 (走原始 NAS 文件名),
        // 这里要保持 metadata.title == nil 真实反映「文件里没有 TIT2」。
        // 否则 cache 内 sanitized 文件名 (如 "_music_xxx") 会被当成嵌入标题,
        // 污染 scrape 查询和 UI 预览。
        return metadata
    }

    /// Reads a bounded remote-file prefix directly from memory. The previous
    /// implementation wrote every prefix to a temporary file solely because
    /// `AVURLAsset` needs a URL. A custom resource loader gives AVFoundation
    /// the same random-access view without generating whole-library disk I/O.
    /// `Data` is copy-on-write, so the loader borrows the caller's storage;
    /// only individual AVFoundation byte-range responses are materialized.
    static func read(
        from data: Data,
        fileExtension: String,
        id3TailData: Data? = nil
    ) async -> Metadata {
        guard !data.isEmpty else { return Metadata() }

        let loader = InMemoryAudioAssetLoader(
            data: data,
            contentType: AudioFormat.from(fileExtension: fileExtension)?.avPlayerContentType
        )
        let asset = loader.makeAsset(fileExtension: fileExtension)
        var metadata = await read(from: asset)

        applyISOBaseMediaLyricsFallback(
            to: &metadata,
            data: data,
            fileExtension: fileExtension
        )
        applyID3Fallback(to: &metadata, data: data, tailData: id3TailData)
        applyFLACFallback(to: &metadata, data: data, fileExtension: fileExtension)
        applyWAVEFallback(to: &metadata, data: data, fileExtension: fileExtension)
        applyMPEGFrameFallback(to: &metadata, data: data, fileExtension: fileExtension)
        applyContainerTagFallback(
            to: &metadata,
            headData: data,
            tailData: id3TailData,
            fileExtension: fileExtension
        )

        // AVAssetResourceLoader's delegate is not retained strongly by the
        // resource loader. Keep the in-memory provider alive through every
        // asynchronous AVFoundation load above, then release it immediately
        // at the per-song boundary.
        withExtendedLifetime(loader) {}
        return metadata
    }

    /// Parses a complete fast-start or trailing `moov` without pretending
    /// arbitrary head/tail bytes are adjacent in the original file. The slice
    /// builder retains only `ftyp` + `moov`, which is a valid metadata-only
    /// container and therefore preserves AVFoundation's tag handling.
    static func readISOBaseMediaMetadata(
        head: Data,
        tail: Data,
        fileExtension: String
    ) async -> Metadata? {
        guard isoBaseMediaExtensions.contains(fileExtension.lowercased()),
              let metadataFile = ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(
                head: head,
                tail: tail
              ) else {
            return nil
        }
        return await read(from: metadataFile, fileExtension: fileExtension)
    }

    private static func read(from asset: AVAsset) async -> Metadata {
        var metadata = Metadata()

        // Get duration
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 {
                metadata.duration = seconds
            }
        }

        // Read metadata items
        if let items = try? await asset.load(.metadata) {
            var commonArtists: [String] = []
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                let value = try? await item.load(.value)

                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue:
                    metadata.title = decodedText(value)
                case AVMetadataKey.commonKeyArtist.rawValue:
                    if let artist = decodedText(value),
                       !commonArtists.contains(where: {
                           $0.compare(
                            artist,
                            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
                           ) == .orderedSame
                       }) {
                        commonArtists.append(artist)
                    }
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
            if commonArtists.count > 1 {
                metadata.sourceArtistNames = commonArtists
                metadata.artist = commonArtists.joined(separator: "; ")
            } else if let artist = commonArtists.first {
                metadata.artist = artist
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

        return metadata
    }

    private static let id3MetadataReadLimit = 4 * 1024 * 1024
    private static let waveHeaderReadLimit = 1024 * 1024
    private static let mpegHeaderReadLimit = 512 * 1024
    private static let isoBaseMediaExtensions: Set<String> = [
        "m4a", "m4b", "mp4", "m4v", "mov", "alac",
    ]
    private static let boundedContainerTagExtensions: Set<String> = [
        "ogg", "opus", "speex", "ape", "wv", "mpc", "tta", "wma",
    ]
    private static let apeTailTagExtensions: Set<String> = [
        "ape", "wv", "mpc", "tta",
    ]

    private static func applyISOBaseMediaLyricsFallback(
        to metadata: inout Metadata,
        data: Data,
        fileExtension: String
    ) {
        guard isoBaseMediaExtensions.contains(fileExtension.lowercased()),
              let lyrics = ISOBaseMediaLyricsParser.lyrics(in: data) else {
            return
        }
        metadata.lyricsText = lyrics
    }

    private static func readISOBaseMediaMetadataFile(from url: URL) -> Data? {
        guard isoBaseMediaExtensions.contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }
        let rangeSizes = RemoteMetadataReadPolicy.containerTailReadSizes(
            fileSize: Int64(clamping: fileSize)
        )
        for byteCount in rangeSizes {
            try? handle.seek(toOffset: 0)
            guard let head = try? handle.read(upToCount: byteCount), !head.isEmpty else {
                continue
            }
            if let metadataFile = ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(
                head: head,
                tail: Data()
            ) {
                return metadataFile
            }

            guard UInt64(byteCount) < fileSize else { continue }
            try? handle.seek(toOffset: fileSize - UInt64(byteCount))
            guard let tail = try? handle.read(upToCount: byteCount) else { continue }
            if let metadataFile = ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(
                head: head,
                tail: tail
            ) {
                return metadataFile
            }
        }
        return nil
    }

    private static func applyWAVEFallback(
        to metadata: inout Metadata,
        data: Data,
        fileExtension: String
    ) {
        guard ["wav", "wave"].contains(fileExtension.lowercased()),
              let info = WAVEHeaderParser.parse(data) else {
            return
        }

        // AVFoundation bases the duration on the bytes physically present in
        // a truncated Range temp file (about 0.5 s for a 256 KB PCM prefix).
        // RIFF's data-chunk byte count describes the complete remote payload,
        // so it is authoritative for both full local files and partial reads.
        metadata.duration = info.duration
        metadata.sampleRate = info.sampleRate
        metadata.bitRate = info.bitRateKbps
        metadata.bitDepth = info.bitDepth
    }

    /// SFBAudioEngine already powers the complete-file decoder and supports
    /// the metadata families AVFoundation commonly skips (APEv2, Vorbis
    /// comments, ASF, DSF/DFF ID3, and several legacy lossless containers).
    /// Use it as a local-file fallback while preserving AVFoundation/native
    /// values that were decoded successfully.
    private static func applySFBAudioFallback(to metadata: inout Metadata, url: URL) {
        guard let audioFile = try? AudioFile(readingPropertiesAndMetadataFrom: url) else {
            return
        }
        let tags = audioFile.metadata
        let properties = audioFile.properties
        let frontCover = tags.attachedPictures(ofType: .frontCover).first?.imageData
        let anyCover = tags.attachedPictures.first?.imageData

        let fallback = Metadata(
            title: tags.title,
            artist: tags.artist,
            albumTitle: tags.albumTitle,
            albumArtist: tags.albumArtist,
            trackNumber: tags.trackNumber,
            discNumber: tags.discNumber,
            year: parsedYear(tags.releaseDate),
            genre: tags.genre,
            duration: properties.duration,
            coverArtData: frontCover ?? anyCover,
            sampleRate: properties.sampleRate.map(Int.init),
            bitRate: properties.bitrate.map(Int.init),
            bitDepth: properties.bitDepth,
            replayGainTrackGain: tags.replayGainTrackGain,
            replayGainTrackPeak: tags.replayGainTrackPeak,
            replayGainAlbumGain: tags.replayGainAlbumGain,
            replayGainAlbumPeak: tags.replayGainAlbumPeak,
            lyricsText: tags.lyrics
        )
        metadata.fillMissing(from: fallback)
    }

    /// Applies dependency-free parsers to bounded remote ranges. ID3 carried
    /// inside DSF/DFF, AIFF, or RIFF is extracted first and then handed to the
    /// same text/artwork parser used by MP3.
    private static func applyContainerTagFallback(
        to metadata: inout Metadata,
        headData: Data,
        tailData: Data?,
        fileExtension: String
    ) {
        if let parsed = EmbeddedTagMetadataParser.parse(
            head: headData,
            tail: tailData,
            fileExtension: fileExtension
        ) {
            apply(parsed, to: &metadata)
        }
        if let id3 = EmbeddedTagMetadataParser.embeddedID3Data(
            head: headData,
            tail: tailData,
            fileExtension: fileExtension
        ) {
            applyID3Fallback(to: &metadata, data: id3)
        }
    }

    private static func apply(_ parsed: EmbeddedTagMetadata, to metadata: inout Metadata) {
        metadata.title = preferredMetadataText(current: metadata.title, rawID3: parsed.title)
        if let artists = parsed.artists, !artists.isEmpty {
            metadata.sourceArtistNames = artists.count > 1 ? artists : nil
            metadata.artist = artists.count > 1
                ? artists.joined(separator: "; ")
                : preferredMetadataText(current: metadata.artist, rawID3: artists.first)
        } else {
            metadata.artist = preferredMetadataText(current: metadata.artist, rawID3: parsed.artist)
        }
        metadata.albumTitle = preferredMetadataText(
            current: metadata.albumTitle,
            rawID3: parsed.albumTitle
        )
        metadata.albumArtist = preferredMetadataText(
            current: metadata.albumArtist,
            rawID3: parsed.albumArtist
        )
        metadata.trackNumber = metadata.trackNumber ?? parsed.trackNumber
        metadata.discNumber = metadata.discNumber ?? parsed.discNumber
        metadata.year = metadata.year ?? parsed.year
        metadata.genre = preferredMetadataText(current: metadata.genre, rawID3: parsed.genre)
        metadata.lyricsText = metadata.lyricsText ?? parsed.lyrics
        metadata.coverArtData = metadata.coverArtData ?? parsed.coverArtData
        metadata.replayGainTrackGain = metadata.replayGainTrackGain ?? parsed.replayGainTrackGain
        metadata.replayGainTrackPeak = metadata.replayGainTrackPeak ?? parsed.replayGainTrackPeak
        metadata.replayGainAlbumGain = metadata.replayGainAlbumGain ?? parsed.replayGainAlbumGain
        metadata.replayGainAlbumPeak = metadata.replayGainAlbumPeak ?? parsed.replayGainAlbumPeak
    }

    private static func parsedYear(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return Int(digits.prefix(4))
    }

    private static func applyID3Fallback(
        to metadata: inout Metadata,
        data tagData: Data,
        tailData: Data? = nil
    ) {
        let text = ID3TextMetadataParser.parse(head: tagData, tail: tailData)
        let artwork = parseID3Metadata(from: tagData)
        guard text != nil || artwork != nil else { return }

        // AVFoundation may reject a truncated cloud-Range temp file even
        // though its complete ID3v2 tag is present at byte zero. Keep its
        // values when available, but fill every missing field from the small
        // native parser below. Previously this fallback only recovered APIC,
        // so a readable TIT2 still fell back to the filename.
        metadata.title = preferredMetadataText(current: metadata.title, rawID3: text?.title)
        if let artists = text?.artists {
            metadata.sourceArtistNames = artists.count > 1 ? artists : nil
            if artists.count > 1 {
                metadata.artist = artists.joined(separator: "; ")
            } else {
                metadata.artist = preferredMetadataText(
                    current: metadata.artist,
                    rawID3: artists.first
                )
            }
        } else {
            metadata.artist = preferredMetadataText(current: metadata.artist, rawID3: text?.artist)
        }
        metadata.albumTitle = preferredMetadataText(current: metadata.albumTitle, rawID3: text?.albumTitle)
        metadata.albumArtist = preferredMetadataText(current: metadata.albumArtist, rawID3: text?.albumArtist)
        metadata.trackNumber = metadata.trackNumber ?? text?.trackNumber
        metadata.discNumber = metadata.discNumber ?? text?.discNumber
        metadata.year = metadata.year ?? text?.year
        metadata.genre = metadata.genre ?? text?.genre
        metadata.coverArtData = metadata.coverArtData ?? artwork?.coverArtData
        metadata.lyricsText = metadata.lyricsText ?? artwork?.lyricsText
        metadata.replayGainTrackGain = metadata.replayGainTrackGain ?? artwork?.replayGainTrackGain
        metadata.replayGainTrackPeak = metadata.replayGainTrackPeak ?? artwork?.replayGainTrackPeak
        metadata.replayGainAlbumGain = metadata.replayGainAlbumGain ?? artwork?.replayGainAlbumGain
        metadata.replayGainAlbumPeak = metadata.replayGainAlbumPeak ?? artwork?.replayGainAlbumPeak
    }

    private static func preferredMetadataText(current: String?, rawID3: String?) -> String? {
        guard let rawID3, !MediaMetadataTextRepair.isSuspicious(rawID3) else {
            return current
        }
        guard let current else { return rawID3 }
        return MediaMetadataTextRepair.isSuspicious(current) ? rawID3 : current
    }

    private static func applyMPEGFrameFallback(
        to metadata: inout Metadata,
        data: Data,
        fileExtension: String
    ) {
        guard fileExtension.lowercased() == "mp3" else { return }
        guard let info = MPEGFrameHeaderParser.parse(data) else { return }
        if (metadata.sampleRate ?? 0) <= 0 {
            metadata.sampleRate = info.sampleRate
        }
        if (metadata.bitRate ?? 0) <= 0 {
            metadata.bitRate = info.bitRateKbps
        }
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

    private static func readID3FallbackData(from url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }

        var result = Data()
        if let header = try? handle.read(upToCount: 10),
           let tagByteCount = id3TagByteCount(in: header) {
            let cappedByteCount = min(tagByteCount, id3MetadataReadLimit)
            try? handle.seek(toOffset: 0)
            result = (try? handle.read(upToCount: cappedByteCount)) ?? Data()
        }

        if let fileSize = try? handle.seekToEnd(), fileSize >= 128 {
            try? handle.seek(toOffset: fileSize - 128)
            if let tail = try? handle.read(upToCount: 128), tail.count == 128 {
                result.append(tail)
            }
        }
        return result
    }

    private struct ID3NativeMetadata {
        var coverArtData: Data?
        var lyricsText: String?
        var replayGainTrackGain: Double?
        var replayGainTrackPeak: Double?
        var replayGainAlbumGain: Double?
        var replayGainAlbumPeak: Double?
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
        var result = ID3NativeMetadata()

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
                } else if frameID == "ULT" {
                    result.lyricsText = result.lyricsText ?? parseID3LyricsFrame(payload)
                } else if frameID == "TXX", let pair = parseID3UserTextFrame(payload) {
                    applyID3UserText(pair, to: &result)
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
                } else if frameID == "USLT" {
                    result.lyricsText = result.lyricsText ?? parseID3LyricsFrame(payload)
                } else if frameID == "TXXX", let pair = parseID3UserTextFrame(payload) {
                    applyID3UserText(pair, to: &result)
                }
            }
        }

        let preferred = pictures.first(where: { $0.type == 3 }) ?? pictures.first
        result.coverArtData = preferred?.data
        return result.coverArtData != nil
            || result.lyricsText != nil
            || result.replayGainTrackGain != nil
            || result.replayGainTrackPeak != nil
            || result.replayGainAlbumGain != nil
            || result.replayGainAlbumPeak != nil
            ? result
            : nil
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

    private static func parseID3LyricsFrame(_ payload: Data) -> String? {
        guard payload.count >= 5 else { return nil }
        let encoding = payload[0]
        let descriptionStart = 4 // encoding + ISO-639-2 language
        guard let lyricsStart = encodedStringTerminatorEnd(
            in: payload,
            from: descriptionStart,
            encoding: encoding
        ), lyricsStart < payload.count else {
            return nil
        }
        return TextEncodingRepair.decodeID3Text(
            payload.subdata(in: lyricsStart..<payload.count),
            encodingByte: encoding
        )
    }

    private static func parseID3UserTextFrame(_ payload: Data) -> (String, String)? {
        guard payload.count >= 3 else { return nil }
        let encoding = payload[0]
        guard let valueStart = encodedStringTerminatorEnd(
            in: payload,
            from: 1,
            encoding: encoding
        ), valueStart < payload.count else {
            return nil
        }
        let terminatorLength = (encoding == 1 || encoding == 2) ? 2 : 1
        let descriptionEnd = valueStart - terminatorLength
        guard descriptionEnd >= 1 else { return nil }
        let description = TextEncodingRepair.decodeID3Text(
            payload.subdata(in: 1..<descriptionEnd),
            encodingByte: encoding
        )
        let value = TextEncodingRepair.decodeID3Text(
            payload.subdata(in: valueStart..<payload.count),
            encodingByte: encoding
        )
        guard let description, let value, !description.isEmpty, !value.isEmpty else {
            return nil
        }
        return (description, value)
    }

    private static func applyID3UserText(
        _ pair: (String, String),
        to metadata: inout ID3NativeMetadata
    ) {
        switch pair.0.lowercased() {
        case "replaygain_track_gain":
            metadata.replayGainTrackGain = metadata.replayGainTrackGain ?? parseReplayGainDB(pair.1)
        case "replaygain_track_peak":
            metadata.replayGainTrackPeak = metadata.replayGainTrackPeak ?? Double(pair.1)
        case "replaygain_album_gain":
            metadata.replayGainAlbumGain = metadata.replayGainAlbumGain ?? parseReplayGainDB(pair.1)
        case "replaygain_album_peak":
            metadata.replayGainAlbumPeak = metadata.replayGainAlbumPeak ?? Double(pair.1)
        default:
            break
        }
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

    private static func applyFLACFallback(
        to metadata: inout Metadata,
        data: Data,
        fileExtension: String
    ) {
        guard fileExtension.lowercased() == "flac",
              let flac = parseFLACMetadata(from: data) else {
            return
        }

        if metadata.duration == nil || (metadata.duration ?? 0) <= 0 {
            metadata.duration = flac.duration
        }
        metadata.sampleRate = metadata.sampleRate ?? flac.sampleRate
        metadata.bitDepth = metadata.bitDepth ?? flac.bitDepth
        metadata.title = metadata.title ?? flac.title
        if let artists = flac.sourceArtistNames {
            metadata.sourceArtistNames = artists.count > 1 ? artists : nil
            metadata.artist = artists.count > 1
                ? artists.joined(separator: "; ")
                : (metadata.artist ?? artists.first)
        } else {
            metadata.artist = metadata.artist ?? flac.artist
        }
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

    private static func readExpandableContainerHead(from url: URL) -> Data {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize > 0 else {
            return Data()
        }
        var data = readPrefix(
            from: url,
            byteCount: RemoteMetadataReadPolicy.initialReadSize(fileSize: fileSize)
        )
        while let expanded = EmbeddedTagMetadataParser.expandedHeadReadSize(
            fileSize: fileSize,
            currentData: data,
            fileExtension: url.pathExtension
        ) {
            let replacement = readPrefix(from: url, byteCount: expanded)
            guard replacement.count > data.count else { break }
            data = replacement
        }
        return data
    }

    private static func readExpandableContainerTail(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }

        func readTail(byteCount: Int) -> Data? {
            let bounded = min(Int(clamping: fileSize), max(0, byteCount))
            guard bounded > 0 else { return nil }
            try? handle.seek(toOffset: fileSize - UInt64(bounded))
            return try? handle.read(upToCount: bounded)
        }

        guard var data = readTail(
            byteCount: RemoteMetadataReadPolicy.initialContainerTailByteCount
        ) else {
            return nil
        }
        if let expanded = EmbeddedTagMetadataParser.expandedTailReadSize(
            fileSize: Int64(clamping: fileSize),
            currentData: data,
            fileExtension: url.pathExtension
        ), expanded > data.count,
           let replacement = readTail(byteCount: expanded),
           replacement.count > data.count {
            data = replacement
        }
        return data
    }

    private static func readFLACMetadataPrefix(from url: URL) -> Data {
        guard url.pathExtension.lowercased() == "flac",
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize > 0 else {
            return Data()
        }

        var data = readPrefix(
            from: url,
            byteCount: RemoteMetadataReadPolicy.initialReadSize(fileSize: fileSize)
        )
        while let expandedByteCount = RemoteMetadataReadPolicy.expandedFLACReadSize(
            fileSize: fileSize,
            currentData: data
        ) {
            let expanded = readPrefix(from: url, byteCount: expandedByteCount)
            guard expanded.count > data.count else { break }
            data = expanded
        }
        return data
    }

    private struct FLACNativeMetadata {
        var title: String?
        var artist: String?
        var sourceArtistNames: [String]?
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

        func all(_ keys: String...) -> [String] {
            var result: [String] = []
            for key in keys {
                for value in comments[key] ?? [] {
                    let repaired = repairLegacyChineseMojibake(
                        value.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    guard let cleaned = repaired.nilIfEmpty,
                          !result.contains(where: {
                            $0.compare(
                                cleaned,
                                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
                            ) == .orderedSame
                          }) else { continue }
                    result.append(cleaned)
                }
            }
            return result
        }

        result.title = result.title ?? first("TITLE")
        let artists = all("ARTIST")
        result.sourceArtistNames = artists.isEmpty ? nil : artists
        if artists.count > 1 {
            result.artist = artists.joined(separator: "; ")
        } else {
            result.artist = result.artist
                ?? artists.first
                ?? first("ALBUMARTIST", "ALBUM ARTIST")
        }
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
        if [0, 1, 2, 3].contains(firstByte),
           let decoded = TextEncodingRepair.decodeID3Text(
               Data(data.dropFirst()),
               encodingByte: firstByte
           ) {
            return decoded
        }

        guard let decoded = TextEncodingRepair.bestDecoding(
            of: data,
            encodings: TextEncodingRepair.legacyTextEncodings
        ) else {
            return nil
        }
        return repairLegacyChineseMojibake(decoded)
    }

    static func repairLegacyChineseMojibake(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\0", with: "")
        return TextEncodingRepair.repaired(normalized) ?? normalized
    }
}

/// Supplies one bounded remote metadata slice to AVFoundation without a
/// temporary file. The delegate queue is deliberately shared and serial: the
/// backfill service keeps its established three network workers, but range
/// copies requested by AVFoundation are materialized one at a time so several
/// simultaneous songs cannot multiply short-lived allocation peaks.
private final class InMemoryAudioAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let delegateQueue = DispatchQueue(
        label: "com.welape.primuse.metadata-memory-loader",
        qos: .utility
    )

    private let data: Data
    private let contentType: String?

    init(data: Data, contentType: String?) {
        self.data = data
        self.contentType = contentType
        super.init()
    }

    func makeAsset(fileExtension: String) -> AVURLAsset {
        let sanitizedExtension = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let suffix = sanitizedExtension.isEmpty ? "bin" : sanitizedExtension
        let url = URL(string: "primuse-metadata://memory/\(UUID().uuidString).\(suffix)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: Self.delegateQueue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            if let contentType {
                information.contentType = contentType
            }
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = true
        }

        if let request = loadingRequest.dataRequest {
            let requestedOffset = max(request.currentOffset, request.requestedOffset)
            if requestedOffset >= 0, requestedOffset < Int64(data.count) {
                let start = Int(requestedOffset)
                let available = data.count - start
                let length = request.requestsAllDataToEndOfResource
                    ? available
                    : min(available, max(0, request.requestedLength))
                if length > 0 {
                    request.respond(with: data.subdata(in: start..<(start + length)))
                }
            }
        }

        loadingRequest.finishLoading()
        return true
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
