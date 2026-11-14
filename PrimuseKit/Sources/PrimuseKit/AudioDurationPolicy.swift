import Foundation

/// Shared rules for provisional scan durations and authoritative decoder
/// corrections. Remote scanners do not always have a seekable file, while a
/// decoder that required a complete local file has already seen the full
/// payload and must be trusted over a size-based estimate.
public enum AudioDurationPolicy {
    private static let provisionalDTSFileExtensions: Set<String> = [
        "dts", "dtswav", "wav", "wave",
    ]

    public static func fallbackEstimate(
        fileSize: Int64,
        format: AudioFormat
    ) -> TimeInterval {
        guard fileSize > 0 else { return 0 }

        let assumedBitRate: Double
        switch format {
        case .dts:
            // The common full-rate DTS core used by standalone .dts files is
            // 1,536 kbps. Treating it like a 192 kbps lossy file inflates the
            // displayed duration by exactly 8x until playback resolves it.
            assumedBitRate = 1_536_000
        case .flac:
            assumedBitRate = 900_000
        default:
            assumedBitRate = 192_000
        }
        return Double(fileSize) * 8.0 / assumedBitRate
    }

    /// Returns a provisional duration for a standalone DTS core stream when a
    /// remote scanner knows the complete byte count but cannot seek through the
    /// complete payload. WAV is accepted only after the caller has verified a
    /// DTS sync word; DTS-HD extensions are deliberately excluded because a
    /// core-rate estimate cannot describe their extension payload reliably.
    public static func provisionalStandaloneDTSDuration(
        fileSize: Int64,
        bitRateKbps: Int? = nil,
        fileExtension: String
    ) -> TimeInterval? {
        guard fileSize > 0 else { return nil }
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard provisionalDTSFileExtensions.contains(normalizedExtension) else {
            return nil
        }

        let bitRate: Double
        if let bitRateKbps, bitRateKbps > 0, bitRateKbps <= 100_000 {
            bitRate = Double(bitRateKbps) * 1_000.0
        } else {
            bitRate = 1_536_000.0
        }
        let duration = Double(fileSize) * 8.0 / bitRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    /// Repairs only provisional DTS values. Positive decoder/server durations
    /// remain untouched, while a zero value and the characteristic legacy
    /// 192-kbps estimate are replaced with the best available core estimate.
    public static func repairedStoredDTSDuration(
        stored: TimeInterval,
        fileSize: Int64,
        bitRateKbps: Int?,
        fileExtension: String,
        format: AudioFormat
    ) -> TimeInterval? {
        guard format == .dts,
              provisionalStandaloneDTSDuration(
                fileSize: fileSize,
                fileExtension: fileExtension
              ) != nil else {
            return nil
        }

        if let corrected = correctedLegacyStoredDuration(
            stored: stored,
            fileSize: fileSize,
            format: format
        ) {
            return provisionalStandaloneDTSDuration(
                fileSize: fileSize,
                bitRateKbps: bitRateKbps,
                fileExtension: fileExtension
            ) ?? corrected
        }
        guard !stored.isFinite || stored <= 0 else { return nil }
        return provisionalStandaloneDTSDuration(
            fileSize: fileSize,
            bitRateKbps: bitRateKbps,
            fileExtension: fileExtension
        )
    }

    /// A gapless or crossfade preparation keeps a value snapshot of the next
    /// song while its decoder may resolve and persist a better duration. At the
    /// handoff boundary, prefer that newer positive library value without
    /// discarding a valid snapshot when the library still has no duration.
    public static func playbackHandoffDuration(
        snapshot: TimeInterval,
        latestLibrary: TimeInterval?
    ) -> TimeInterval {
        let validSnapshot = snapshot.isFinite && snapshot > 0 ? snapshot : 0
        guard let latestLibrary,
              latestLibrary.isFinite,
              latestLibrary > 0 else {
            return validSnapshot
        }
        return latestLibrary
    }

    public static func shouldIgnoreResolvedDuration(
        resolved: TimeInterval,
        stored: TimeInterval,
        fileSize: Int64,
        bitRateKbps: Int?,
        format: AudioFormat,
        formatRequiresCompleteLocalFile: Bool
    ) -> Bool {
        guard resolved.isFinite, resolved > 0 else { return true }

        // Complete-file decoders (notably FFmpeg for DTS) report an
        // authoritative duration. A shorter value here is commonly the
        // correction of an inflated scan estimate, not a partial cloud read.
        if formatRequiresCompleteLocalFile {
            return false
        }

        if stored > 30, resolved < stored * 0.5 {
            return true
        }

        guard format == .mp3, fileSize > 512 * 1024 else {
            return false
        }
        let effectiveBitRate = max(bitRateKbps ?? 0, 192)
        let estimatedFromFileSize = Double(fileSize) / (Double(effectiveBitRate) * 125.0)
        return estimatedFromFileSize > 30 && resolved < estimatedFromFileSize * 0.5
    }

    /// Repairs the provisional duration written by builds that estimated every
    /// unparsed lossy file at 192 kbps. Standalone DTS commonly uses a 1,536
    /// kbps core, so that old estimate is characteristically eight times too
    /// large. Match the old formula tightly to avoid rewriting authoritative
    /// decoder/server durations.
    public static func correctedLegacyStoredDuration(
        stored: TimeInterval,
        fileSize: Int64,
        format: AudioFormat
    ) -> TimeInterval? {
        guard format == .dts,
              fileSize > 0,
              stored.isFinite,
              stored > 0 else { return nil }

        let legacyEstimate = Double(fileSize) * 8.0 / 192_000.0
        let correctedEstimate = fallbackEstimate(fileSize: fileSize, format: format)
        let tolerance = max(2.0, legacyEstimate * 0.01)
        guard abs(stored - legacyEstimate) <= tolerance,
              stored > correctedEstimate * 4 else { return nil }
        return correctedEstimate
    }
}

public struct ISOBaseMediaAudioProfile: Equatable, Sendable {
    public enum Codec: String, Equatable, Sendable {
        case aac = "mp4a"
        case alac
        case ac3 = "ac-3"
        case enhancedAC3 = "ec-3"
        case applePositionalAudio = "apac"
        case unknown
    }

    public let codec: Codec
    public let codecFourCC: String
    public let channelCount: Int

    public init(codecFourCC: String, channelCount: Int) {
        self.codecFourCC = codecFourCC
        self.channelCount = channelCount
        self.codec = Codec(rawValue: codecFourCC) ?? .unknown
    }

    /// Preserve encoded multichannel and spatial metadata by handing these
    /// presentations to AVPlayer instead of decoding them into Primuse's PCM
    /// effects graph. Stereo AAC/ALAC intentionally remain on the established
    /// decoder path so EQ, transitions, ReplayGain, and cache behavior do not
    /// change for ordinary M4A files.
    public var prefersSystemMediaPlayback: Bool {
        channelCount > 2
            || codec == .ac3
            || codec == .enhancedAC3
            || codec == .applePositionalAudio
    }
}

public enum ISOBaseMediaAudioProfileParser {
    public static func parse(head: Data, tail: Data = Data()) -> [ISOBaseMediaAudioProfile] {
        guard let metadataFile = ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(
            head: head,
            tail: tail
        ) else { return [] }
        return parseMetadataFile(metadataFile)
    }

    public static func parseMetadataFile(_ data: Data) -> [ISOBaseMediaAudioProfile] {
        atoms(in: data, range: data.startIndex..<data.endIndex)
            .filter { $0.type == "moov" }
            .flatMap { profiles(in: data, container: $0, expectedType: "trak") }
    }

    private struct Atom {
        let type: String
        let full: Range<Int>
        let payload: Range<Int>
    }

    private static func profiles(
        in data: Data,
        container: Atom,
        expectedType: String
    ) -> [ISOBaseMediaAudioProfile] {
        atoms(in: data, range: container.payload)
            .filter { $0.type == expectedType }
            .flatMap { profiles(inTrack: $0, data: data) }
    }

    private static func profiles(inTrack track: Atom, data: Data) -> [ISOBaseMediaAudioProfile] {
        guard let media = atoms(in: data, range: track.payload).first(where: { $0.type == "mdia" }),
              isAudioMedia(media, data: data),
              let mediaInfo = atoms(in: data, range: media.payload).first(where: { $0.type == "minf" }),
              let sampleTable = atoms(in: data, range: mediaInfo.payload).first(where: { $0.type == "stbl" }),
              let descriptions = atoms(in: data, range: sampleTable.payload).first(where: { $0.type == "stsd" }) else {
            return []
        }
        return sampleEntryProfiles(in: descriptions, data: data)
    }

    private static func isAudioMedia(_ media: Atom, data: Data) -> Bool {
        guard let handler = atoms(in: data, range: media.payload).first(where: { $0.type == "hdlr" }),
              handler.payload.count >= 12 else { return false }
        return fourCC(in: data, at: handler.payload.lowerBound + 8) == "soun"
    }

    private static func sampleEntryProfiles(
        in descriptions: Atom,
        data: Data
    ) -> [ISOBaseMediaAudioProfile] {
        // stsd is a FullBox: version/flags followed by entry_count.
        guard descriptions.payload.count >= 8 else { return [] }
        let entryCount = Int(readUInt32BE(data, at: descriptions.payload.lowerBound + 4))
        var cursor = descriptions.payload.lowerBound + 8
        var result: [ISOBaseMediaAudioProfile] = []
        for _ in 0..<entryCount {
            guard let entry = atom(in: data, startingAt: cursor),
                  entry.full.upperBound <= descriptions.payload.upperBound else { break }
            if entry.full.count >= 26,
               let codec = fourCC(in: data, at: entry.full.lowerBound + 4) {
                let version = readUInt16BE(data, at: entry.full.lowerBound + 16)
                let channels: Int
                if version == 2 {
                    // QuickTime SoundDescription v2 keeps a compatibility
                    // constant (`always3`) at +24. Its real channel count is
                    // the UInt32 `numAudioChannels` field at +48.
                    guard entry.full.count >= 52 else {
                        cursor = entry.full.upperBound
                        continue
                    }
                    channels = Int(readUInt32BE(data, at: entry.full.lowerBound + 48))
                } else {
                    channels = Int(readUInt16BE(data, at: entry.full.lowerBound + 24))
                }
                result.append(ISOBaseMediaAudioProfile(
                    codecFourCC: codec,
                    channelCount: channels
                ))
            }
            cursor = entry.full.upperBound
        }
        return result
    }

    private static func atoms(in data: Data, range: Range<Int>) -> [Atom] {
        var result: [Atom] = []
        var cursor = range.lowerBound
        while cursor <= range.upperBound - 8,
              let child = atom(in: data, startingAt: cursor),
              child.full.upperBound <= range.upperBound,
              child.full.upperBound > cursor {
            result.append(child)
            cursor = child.full.upperBound
        }
        return result
    }

    private static func atom(in data: Data, startingAt start: Int) -> Atom? {
        guard start >= data.startIndex, start <= data.endIndex - 8,
              let type = fourCC(in: data, at: start + 4) else { return nil }
        let size32 = readUInt32BE(data, at: start)
        let headerLength: Int
        let totalLength: UInt64
        switch size32 {
        case 0:
            headerLength = 8
            totalLength = UInt64(data.endIndex - start)
        case 1:
            guard start <= data.endIndex - 16 else { return nil }
            headerLength = 16
            totalLength = readUInt64BE(data, at: start + 8)
        default:
            headerLength = 8
            totalLength = UInt64(size32)
        }
        guard totalLength >= UInt64(headerLength),
              totalLength <= UInt64(data.endIndex - start) else { return nil }
        let end = start + Int(totalLength)
        return Atom(type: type, full: start..<end, payload: (start + headerLength)..<end)
    }

    private static func fourCC(in data: Data, at offset: Int) -> String? {
        guard offset >= data.startIndex, offset <= data.endIndex - 4 else { return nil }
        return String(data: data.subdata(in: offset..<(offset + 4)), encoding: .isoLatin1)
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= data.startIndex, offset <= data.endIndex - 2 else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= data.startIndex, offset <= data.endIndex - 4 else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= data.startIndex, offset <= data.endIndex - 8 else { return 0 }
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }
}


/// Builds a small, structurally valid ISO Base Media metadata file from
/// bounded head and tail ranges. A fast-start `moov` can live in the head,
/// while the common trailing form cannot be parsed reliably by concatenating
/// arbitrary ranges because that leaves a partial `mdat` atom between them.
/// Keeping only `ftyp` and one complete `moov` gives AVFoundation the container
/// description it needs without materializing the remote media payload.
public enum ISOBaseMediaMetadataSliceBuilder {
    public static func makeMetadataFile(head: Data, tail: Data) -> Data? {
        guard let ftyp = completeAtom(named: "ftyp", in: head) else {
            return nil
        }
        let moov = completeAtom(named: "moov", in: head, requiredChild: "mvhd")
            ?? completeAtom(named: "moov", in: tail, requiredChild: "mvhd")
        guard let moov else { return nil }
        return ftyp + moov
    }

    private struct AtomRange {
        let full: Range<Int>
        let payload: Range<Int>
    }

    private static func completeAtom(
        named name: String,
        in data: Data,
        requiredChild: String? = nil
    ) -> Data? {
        let type = Data(name.utf8)
        guard type.count == 4, data.count >= 8 else { return nil }

        var searchStart = data.startIndex + 4
        while searchStart <= data.endIndex - 4,
              let match = data.range(of: type, in: searchStart..<data.endIndex) {
            let atomStart = match.lowerBound - 4
            if let atom = atomRange(in: data, startingAt: atomStart),
               atom.full.lowerBound == atomStart,
               requiredChild.map({ containsDirectChild(named: $0, in: data, payload: atom.payload) }) ?? true {
                return data.subdata(in: atom.full)
            }
            searchStart = match.lowerBound + 1
        }
        return nil
    }

    private static func containsDirectChild(
        named name: String,
        in data: Data,
        payload: Range<Int>
    ) -> Bool {
        var cursor = payload.lowerBound
        while cursor <= payload.upperBound - 8 {
            guard let child = atomRange(in: data, startingAt: cursor),
                  child.full.upperBound <= payload.upperBound else {
                return false
            }
            if atomType(in: data, startingAt: cursor) == name {
                return true
            }
            guard child.full.upperBound > cursor else { return false }
            cursor = child.full.upperBound
        }
        return false
    }

    private static func atomRange(in data: Data, startingAt start: Int) -> AtomRange? {
        guard start >= data.startIndex, start <= data.endIndex - 8 else { return nil }
        let size32 = readUInt32BE(data, at: start)
        let headerLength: Int
        let totalLength: UInt64

        switch size32 {
        case 0:
            headerLength = 8
            totalLength = UInt64(data.endIndex - start)
        case 1:
            guard start <= data.endIndex - 16 else { return nil }
            headerLength = 16
            totalLength = readUInt64BE(data, at: start + 8)
        default:
            headerLength = 8
            totalLength = UInt64(size32)
        }

        guard totalLength >= UInt64(headerLength),
              totalLength <= UInt64(data.endIndex - start) else {
            return nil
        }
        let end = start + Int(totalLength)
        return AtomRange(full: start..<end, payload: (start + headerLength)..<end)
    }

    private static func atomType(in data: Data, startingAt start: Int) -> String? {
        guard start >= data.startIndex, start <= data.endIndex - 8 else { return nil }
        return String(data: data.subdata(in: (start + 4)..<(start + 8)), encoding: .isoLatin1)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= data.startIndex, offset <= data.endIndex - 4 else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= data.startIndex, offset <= data.endIndex - 8 else { return 0 }
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }
}


/// Bounds remote metadata reads independently of library size. MP3 exposes
/// its complete tag size in the ID3 header, so it starts at 256 KB and expands
/// only when necessary. Other containers retain the scanner's historical 4 MB
/// read ceiling because FLAC pictures and MP4 atoms may legitimately occur
/// after the first 256 KB. All formats remain bounded, and callers no longer
/// need to materialize the slice as a temporary file.
public enum RemoteMetadataReadPolicy {
    /// Preserve the parsed prefix when a tag declares more bytes than the first probe.
    public static func extendingHead(
        _ head: Data,
        to byteCount: Int,
        fetch: (Int64, Int64) async throws -> Data
    ) async throws -> Data {
        try Task.checkCancellation()
        guard byteCount > head.count else { return head }
        let missing = byteCount - head.count
        let suffix = try await fetch(Int64(head.count), Int64(missing))
        try Task.checkCancellation()
        guard !suffix.isEmpty, suffix.count <= missing else { throw URLError(.badServerResponse) }
        var result = head
        result.append(suffix)
        return result
    }

    public static let initialHeadByteCount = 256 * 1024
    public static let maximumHeadByteCount = 4 * 1024 * 1024
    public static let mp3FrameProbeByteCount = 64 * 1024
    public static let initialContainerTailByteCount = 256 * 1024
    public static let defaultMP3BitRateKbps = 192

    /// 不必连嵌入封面一起取时的首段大小。标签本身(标题/艺人/专辑)加上定位第一
    /// 个音频帧所需的字节远小于这个数, 32 KB 足够, 也对齐常见的 IO 块大小。
    public static let compactInitialHeadByteCount = 32 * 1024

    /// 首段读多少字节。
    ///
    /// 还要顺带取嵌入封面的歌保持整段读: 封面通常就落在前 256 KB 里, 一次取回
    /// 比"先小段拿到标签声明的长度、再按长度补第二段"少一次往返, 字节数也更少。
    /// 不取封面时反过来——绝大多数歌的标签只有几 KB, 整段读等于白拉 200 多 KB。
    ///
    /// 小首段只给头部标签自带长度声明、且回填侧已有按需扩展路径的格式:
    /// MP3 的 ID3 头写着整个 tag 的长度, FLAC 每个 metadata block 的 header 带
    /// 24-bit 长度, Ogg/Opus/Speex 按页边界、WMA 按 header object 声明扩展。
    /// M4A(moov 可能在尾部)、APE、WAV 这些头部没有可依赖的声明, 缩小首段只会把
    /// 一次读取拆成一次读取加一次兜底。
    public static func backfillInitialHeadByteCount(
        declaredFileExtension: String,
        needsEmbeddedArtwork: Bool
    ) -> Int {
        guard !needsEmbeddedArtwork,
              formatsWithDeclaredHeadTagLength.contains(declaredFileExtension.lowercased())
        else { return initialHeadByteCount }
        return compactInitialHeadByteCount
    }

    /// 头部标签自带长度声明, 回填可以按声明补齐的格式。
    private static let formatsWithDeclaredHeadTagLength: Set<String> = [
        "mp3", "flac", "ogg", "oga", "opus", "spx", "speex", "wma"
    ]

    public static func initialReadSize(fileSize: Int64) -> Int {
        guard fileSize > 0 else { return 0 }
        return min(Int(clamping: fileSize), initialHeadByteCount)
    }

    public static func initialReadSize(fileSize: Int64, fileExtension: String) -> Int {
        guard fileSize > 0 else { return 0 }
        let limit = fileExtension.lowercased() == "mp3"
            ? initialHeadByteCount
            : maximumHeadByteCount
        return min(Int(clamping: fileSize), limit)
    }

    /// Returns the next bounded FLAC prefix needed to finish the metadata block
    /// currently visible in `data`. FLAC stores each block's exact byte length
    /// in its four-byte header, so large embedded pictures can be fetched
    /// precisely instead of expanding every cover-less file to the 4 MB cap.
    /// A final padding block needs no body bytes because it cannot contain tags.
    public static func expandedFLACReadSize(
        fileSize: Int64,
        currentData data: Data
    ) -> Int? {
        guard let signatureOffset = flacSignatureOffset(in: data) else { return nil }

        let fileLimit = fileSize > 0
            ? min(Int(clamping: fileSize), maximumHeadByteCount)
            : maximumHeadByteCount
        guard fileLimit > data.count else { return nil }

        var cursor = signatureOffset + 4
        while true {
            guard cursor <= fileLimit else { return nil }
            guard cursor + 4 <= data.count else {
                let requested = min(fileLimit, cursor + 4)
                return requested > data.count ? requested : nil
            }

            let header = data[cursor]
            let isLastBlock = (header & 0x80) != 0
            let blockType = header & 0x7F
            let blockLength = (Int(data[cursor + 1]) << 16)
                | (Int(data[cursor + 2]) << 8)
                | Int(data[cursor + 3])
            let bodyStart = cursor + 4
            let (bodyEnd, overflow) = bodyStart.addingReportingOverflow(blockLength)
            guard !overflow, bodyEnd >= bodyStart else { return nil }

            if bodyEnd > data.count {
                // Padding carries no metadata. If it is the final block, the
                // headers already prove that there is nothing useful after it.
                if blockType == 1, isLastBlock { return nil }
                let nextHeaderEnd = isLastBlock ? bodyEnd : bodyEnd + 4
                let requested = min(fileLimit, nextHeaderEnd)
                return requested > data.count ? requested : nil
            }

            cursor = bodyEnd
            if isLastBlock { return nil }
        }
    }

    /// moov 在首段里放不下时补读的上限。moov 里只有样本表和标签, 十几个小时的整本书也就
    /// 几 MB; 比别的格式的 4 MB 高, 是因为 moov 读不全就一个标签都拿不到。
    public static let maximumISOBaseMediaHeadByteCount = 16 * 1024 * 1024

    /// fast-start 的 m4a/m4b 把 moov(连同全部标签)紧接在 ftyp 后面, 而 moov 随时长线性
    /// 增长: AAC 每分钟约 10 KB 的样本表, 标签还排在 moov 的最后。半小时上下的有声书单集
    /// 就超出 256 KB 首段, AVFoundation 打不开这段截断的数据, 一个标签都读不出来; 尾部
    /// 读取也帮不上, moov 不在那里。顶层 atom 的头部都写着自己的长度, 走到 moov 时按声明
    /// 补到它的末尾。moov 排在 mdat 之后(尾部那种排法)返回 nil, 交给尾部读取。
    public static func expandedISOBaseMediaReadSize(
        fileSize: Int64,
        currentData data: Data
    ) -> Int? {
        let fileLimit = fileSize > 0
            ? min(Int(clamping: fileSize), maximumISOBaseMediaHeadByteCount)
            : maximumISOBaseMediaHeadByteCount
        guard fileLimit > data.count,
              data.count >= 8,
              isoAtomType(in: data, at: 0) == "ftyp" else { return nil }

        var cursor = 0
        while true {
            let headerEnd = cursor + 16
            guard cursor + 8 <= data.count else {
                let requested = min(fileLimit, headerEnd)
                return requested > data.count ? requested : nil
            }
            let size32 = isoUInt32(in: data, at: cursor)
            let length: UInt64
            switch size32 {
            case 0:
                // 一直延伸到文件末尾的 atom: 后面不会再有 moov 了。
                return nil
            case 1:
                guard headerEnd <= data.count else {
                    let requested = min(fileLimit, headerEnd)
                    return requested > data.count ? requested : nil
                }
                length = isoUInt64(in: data, at: cursor + 8)
                guard length >= 16 else { return nil }
            default:
                length = UInt64(size32)
                guard length >= 8 else { return nil }
            }
            guard length <= UInt64(fileLimit) else { return nil }
            let end = cursor + Int(length)
            guard end <= fileLimit else { return nil }

            switch isoAtomType(in: data, at: cursor) {
            case "mdat":
                return nil
            case "moov":
                return end > data.count ? end : nil
            default:
                // free/skip/uuid 这类垫在 moov 前面的 atom: 补到能看见下一个头部为止。
                if end > data.count {
                    let requested = min(fileLimit, end + 16)
                    return requested > data.count ? requested : nil
                }
                cursor = end
            }
        }
    }

    private static func isoAtomType(in data: Data, at offset: Int) -> String? {
        let start = data.startIndex + offset + 4
        guard offset >= 0, start + 4 <= data.endIndex else { return nil }
        return String(data: data[start..<(start + 4)], encoding: .isoLatin1)
    }

    private static func isoUInt32(in data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<(start + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func isoUInt64(in data: Data, at offset: Int) -> UInt64 {
        let start = data.startIndex + offset
        return data[start..<(start + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    public static func expandedReadSize(
        fileSize: Int64,
        currentByteCount: Int,
        declaredID3ByteCount: Int?,
        metadataInsufficient: Bool
    ) -> Int? {
        guard fileSize > 0, currentByteCount >= 0 else { return nil }

        var requested = currentByteCount
        if let declaredID3ByteCount, declaredID3ByteCount > currentByteCount {
            // The exact ID3 boundary contains no MPEG audio bytes. Include a
            // small post-tag probe so the frame-header fallback can recover
            // bitrate/sample rate even when APIC occupies the entire initial
            // 256 KB prefix.
            let probeEnd = declaredID3ByteCount.addingReportingOverflow(mp3FrameProbeByteCount)
            requested = max(
                requested,
                probeEnd.overflow ? maximumHeadByteCount : probeEnd.partialValue
            )
        }
        if metadataInsufficient {
            requested = maximumHeadByteCount
        }

        let bounded = min(Int(clamping: fileSize), min(requested, maximumHeadByteCount))
        return bounded > currentByteCount ? bounded : nil
    }

    private static func flacSignatureOffset(in data: Data) -> Int? {
        let signature = Data([0x66, 0x4C, 0x61, 0x43])
        if data.count >= signature.count,
           data.prefix(signature.count).elementsEqual(signature) {
            return 0
        }
        let searchEnd = min(data.count, 64 * 1024)
        return data.range(of: signature, in: 0..<searchEnd)?.lowerBound
    }

    /// Corrects the characteristic short duration reported when AVFoundation
    /// sees only a bounded MP3 prefix and the file has no usable Xing/VBRI
    /// duration header. A duration already in the same ballpark is preserved,
    /// as is any duration parsed from a slice that represents most of the file.
    public static func correctedMP3Duration(
        parsed: TimeInterval,
        fileSize: Int64,
        bitRateKbps: Int?,
        providedByteCount: Int,
        leadingMetadataByteCount: Int = 0
    ) -> TimeInterval {
        guard fileSize > 0,
              providedByteCount > 0,
              fileSize > Int64(providedByteCount) * 2 else {
            return parsed
        }

        let effectiveBitRate: Int
        if let bitRateKbps, bitRateKbps > 0 {
            effectiveBitRate = bitRateKbps
        } else {
            effectiveBitRate = defaultMP3BitRateKbps
        }
        // ID3v2 artwork can be several hundred KB. It is not audio payload and
        // must not inflate the bytes/bitrate estimate for large-cover files.
        let boundedLeadingMetadata = min(
            max(Int64(leadingMetadataByteCount), 0),
            max(fileSize - 1, 0)
        )
        let audioByteCount = fileSize - boundedLeadingMetadata
        let estimated = Double(audioByteCount) / (Double(effectiveBitRate) * 125.0)
        guard estimated.isFinite,
              estimated > 0,
              !parsed.isFinite || parsed <= 0 || parsed < estimated * 0.5 else {
            return parsed
        }
        return estimated
    }

    /// Progressive tail reads recover the common small `moov` cheaply while
    /// still supporting large embedded artwork. Each returned size is unique,
    /// file-size bounded, and never exceeds the same 4 MB metadata ceiling.
    public static func containerTailReadSizes(fileSize: Int64) -> [Int] {
        guard fileSize > 0 else { return [] }
        let candidates = [
            initialContainerTailByteCount,
            1024 * 1024,
            maximumHeadByteCount,
        ]
        var result: [Int] = []
        for candidate in candidates {
            let bounded = min(Int(clamping: fileSize), candidate)
            if bounded > 0, result.last != bounded {
                result.append(bounded)
            }
        }
        return result
    }
}

public struct MPEGFrameAudioInfo: Equatable, Sendable {
    public let sampleRate: Int
    public let bitRateKbps: Int

    public init(sampleRate: Int, bitRateKbps: Int) {
        self.sampleRate = sampleRate
        self.bitRateKbps = bitRateKbps
    }
}

/// Extracts the technical fields needed for an MP3 duration estimate from a
/// bounded prefix. This is a fallback for truncated Range data that
/// AVFoundation cannot identify; it never scans beyond the bytes already in
/// memory and validates a following frame whenever one is available.
public enum MPEGFrameHeaderParser {
    public static func parse(_ data: Data) -> MPEGFrameAudioInfo? {
        guard data.count >= 4 else { return nil }

        let audioStart = min(id3TagByteCount(in: data) ?? 0, data.count)
        let finalHeaderOffset = data.count - 4
        guard audioStart <= finalHeaderOffset else { return nil }

        for offset in audioStart...finalHeaderOffset {
            guard let header = parseHeader(data, at: offset) else { continue }
            let nextOffset = offset + header.frameLength

            // A second matching frame rejects accidental 0xFFE bit patterns
            // in artwork or tags. If the provided Range ends inside the first
            // frame, the fully validated first header is still useful.
            if nextOffset <= finalHeaderOffset {
                guard let next = parseHeader(data, at: nextOffset),
                      next.sampleRate == header.sampleRate,
                      next.versionBits == header.versionBits else {
                    continue
                }
            }

            return MPEGFrameAudioInfo(
                sampleRate: header.sampleRate,
                bitRateKbps: header.bitRateKbps
            )
        }
        return nil
    }

    private struct Header {
        let versionBits: Int
        let sampleRate: Int
        let bitRateKbps: Int
        let frameLength: Int
    }

    private static func parseHeader(_ data: Data, at offset: Int) -> Header? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let b0 = data[offset]
        let b1 = data[offset + 1]
        let b2 = data[offset + 2]

        guard b0 == 0xFF, (b1 & 0xE0) == 0xE0 else { return nil }
        let versionBits = Int((b1 >> 3) & 0x03)
        let layerBits = Int((b1 >> 1) & 0x03)
        guard versionBits != 1, layerBits == 1 else { return nil } // MPEG Layer III

        let bitRateIndex = Int((b2 >> 4) & 0x0F)
        let sampleRateIndex = Int((b2 >> 2) & 0x03)
        guard (1...14).contains(bitRateIndex), sampleRateIndex < 3 else { return nil }

        let bitRateKbps: Int
        if versionBits == 3 { // MPEG-1 Layer III
            bitRateKbps = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320][bitRateIndex - 1]
        } else { // MPEG-2 / MPEG-2.5 Layer III
            bitRateKbps = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160][bitRateIndex - 1]
        }

        let baseSampleRate = [44_100, 48_000, 32_000][sampleRateIndex]
        let sampleRate: Int
        switch versionBits {
        case 3: sampleRate = baseSampleRate
        case 2: sampleRate = baseSampleRate / 2
        case 0: sampleRate = baseSampleRate / 4
        default: return nil
        }

        let padding = Int((b2 >> 1) & 0x01)
        let coefficient = versionBits == 3 ? 144 : 72
        let frameLength = coefficient * bitRateKbps * 1_000 / sampleRate + padding
        guard frameLength >= 4 else { return nil }
        return Header(
            versionBits: versionBits,
            sampleRate: sampleRate,
            bitRateKbps: bitRateKbps,
            frameLength: frameLength
        )
    }

    private static func id3TagByteCount(in data: Data) -> Int? {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            return nil
        }
        let size = (Int(data[6] & 0x7F) << 21)
            | (Int(data[7] & 0x7F) << 14)
            | (Int(data[8] & 0x7F) << 7)
            | Int(data[9] & 0x7F)
        return 10 + size + ((data[5] & 0x10) != 0 ? 10 : 0)
    }
}


/// 顶层 box 链的纯步进: 只看每个 box 头里的长度和类型, 不碰负载 —— 几个 GB 的
/// mdat 只是一次跳转。首段里看得见的头直接用; 看不见的由调用方按 `step` 去读那一小段
/// (最多 16 字节, 64 位长度也在里面), 再交给 `consume(header:)`。
///
/// 起点跳过文件开头垫着的 ID3v2 标签(签名检测同样跳过它, 这种文件照样认成 ISO 容器);
/// 没有 ftyp 的老 QuickTime 文件照走。第一个 box 必须是顶层会出现的类型, 之后每个
/// 类型都得是四字符码, 长度不能小于头、不能超出文件 —— 不是 ISO 容器的字节第一步就停,
/// 不会拿乱码当长度满文件跳着读。
public struct ISOBaseMediaTopLevelBoxWalk: Sendable {
    public enum Step: Equatable, Sendable {
        /// 下一个 box 头不在手里: 读 `offset` 起的 `count` 字节交给 `consume(header:)`。
        case needsHeader(offset: Int64, count: Int)
        /// moov 的完整范围(含 box 头)。
        case foundMoov(offset: Int64, size: Int64)
        case stopped(StopReason)
    }

    public enum StopReason: Equatable, Sendable {
        /// 不知道文件多大: 跳过 mdat 之后无从判断有没有越界。
        case unknownFileSize
        /// 第一个 box 就不是顶层类型, 不按 ISO 容器走。
        case notISOBaseMedia
        /// 长度小于头, 或类型不是四字符码。
        case malformedHeader
        /// 声明的长度超出文件。
        case exceedsFile
        /// 长度为 0 的 box 一直延伸到文件末尾, 后面不会再有 moov。
        case extendsToEndOfFile
        /// 走到文件末尾也没见到 moov。
        case endOfFile
        /// box 太多, 或要调用方读的头太多。
        case tooManyBoxes
        /// moov 比调用方给的上限还大。
        case moovTooLarge(size: Int64)
        /// 读回来的头不够长。
        case truncatedHeader
    }

    public static let headerProbeByteCount = 16
    public static let defaultMaximumBoxCount = 128
    public static let defaultMaximumFetchedHeaderCount = 32

    public private(set) var step: Step
    /// moov 前面那个 ftyp 的范围; 没有 ftyp 的老 QuickTime 文件为 nil。
    public private(set) var ftyp: Range<Int64>?
    /// moov 前面第一个 sidx 的范围: 分片 MP4 拿它算时长。
    public private(set) var segmentIndex: Range<Int64>?
    /// 已经交给调用方去读的头的个数。
    public private(set) var fetchedHeaderCount = 0
    /// 第一个 box 的位置: 文件开头垫着 ID3v2 标签时在标签之后。
    public let startOffset: Int64

    private let head: Data
    private let fileSize: Int64
    private let maximumMoovByteCount: Int64
    private let maximumBoxCount: Int
    private let maximumFetchedHeaderCount: Int
    private var cursor: Int64
    private var boxCount = 0

    /// 文件开头会出现的顶层 box。
    private static let leadingBoxTypes: Set<String> = [
        "ftyp", "moov", "mdat", "free", "skip", "wide", "uuid",
        "pnot", "pdin", "junk", "styp", "sidx",
    ]

    public init(
        head: Data,
        fileSize: Int64,
        maximumMoovByteCount: Int64,
        maximumBoxCount: Int = ISOBaseMediaTopLevelBoxWalk.defaultMaximumBoxCount,
        maximumFetchedHeaderCount: Int = ISOBaseMediaTopLevelBoxWalk.defaultMaximumFetchedHeaderCount
    ) {
        let normalized = head.startIndex == 0 ? head : Data(head)
        let leading = Int64(EmbeddedTagMetadataParser.id3TagByteCount(in: normalized) ?? 0)
        self.head = normalized
        self.fileSize = fileSize
        self.maximumMoovByteCount = maximumMoovByteCount
        self.maximumBoxCount = maximumBoxCount
        self.maximumFetchedHeaderCount = maximumFetchedHeaderCount
        self.startOffset = leading
        self.cursor = leading
        self.step = .stopped(.unknownFileSize)
        guard fileSize > 0 else { return }
        step = advance(fetched: nil)
    }

    /// `header` 是从上一步 `needsHeader` 的 offset 起读回来的字节。别的时候调用不起作用。
    public mutating func consume(header: Data) {
        guard case .needsHeader = step else { return }
        step = advance(fetched: header.startIndex == 0 ? header : Data(header))
    }

    private mutating func advance(fetched: Data?) -> Step {
        var fetched = fetched
        while true {
            let remaining = fileSize - cursor
            guard remaining >= 8 else { return .stopped(.endOfFile) }
            guard boxCount < maximumBoxCount else { return .stopped(.tooManyBoxes) }
            let wanted = Int(min(Int64(Self.headerProbeByteCount), remaining))
            var header = bytesInHead(at: cursor, count: wanted)
            if header.count < 8 || (Self.uint32(header, at: 0) == 1 && header.count < 16) {
                guard let supplied = fetched else {
                    guard fetchedHeaderCount < maximumFetchedHeaderCount else {
                        return .stopped(.tooManyBoxes)
                    }
                    fetchedHeaderCount += 1
                    return .needsHeader(offset: cursor, count: wanted)
                }
                fetched = nil
                header = supplied
            }
            let box: BoxHeader
            switch Self.parseHeader(header, remaining: remaining, isFirstBox: boxCount == 0) {
            case .stop(let reason):
                return .stopped(reason)
            case .box(let parsed):
                box = parsed
            }
            boxCount += 1

            if box.type == "moov" {
                guard box.size <= maximumMoovByteCount else {
                    return .stopped(.moovTooLarge(size: box.size))
                }
                return .foundMoov(offset: cursor, size: box.size)
            }
            if box.type == "ftyp", ftyp == nil {
                ftyp = cursor..<(cursor + box.size)
            }
            if box.type == "sidx", segmentIndex == nil {
                segmentIndex = cursor..<(cursor + box.size)
            }
            if box.extendsToEnd { return .stopped(.extendsToEndOfFile) }
            // size 不超过 remaining, 相加不会越过文件长度。
            cursor += box.size
        }
    }

    /// 一个顶层 box 头。长度为 0 的 box 一直延伸到文件末尾(`extendsToEnd`)。
    struct BoxHeader: Equatable, Sendable {
        let type: String
        let size: Int64
        let headerSize: Int
        let extendsToEnd: Bool
    }

    enum HeaderParse: Equatable, Sendable {
        case box(BoxHeader)
        case stop(StopReason)
    }

    /// `header` 从 box 开头起; `remaining` 是 box 开头到文件末尾的字节数。
    static func parseHeader(_ header: Data, remaining: Int64, isFirstBox: Bool) -> HeaderParse {
        guard header.count >= 8 else { return .stop(.truncatedHeader) }
        guard let type = boxType(header) else {
            return .stop(isFirstBox ? .notISOBaseMedia : .malformedHeader)
        }
        if isFirstBox, !leadingBoxTypes.contains(type) {
            return .stop(.notISOBaseMedia)
        }
        let size32 = uint32(header, at: 0)
        switch size32 {
        case 0:
            return .box(BoxHeader(type: type, size: remaining, headerSize: 8, extendsToEnd: true))
        case 1:
            guard remaining >= 16 else { return .stop(.malformedHeader) }
            guard header.count >= 16 else { return .stop(.truncatedHeader) }
            let large = uint64(header, at: 8)
            guard large >= 16 else { return .stop(.malformedHeader) }
            guard large <= UInt64(remaining) else { return .stop(.exceedsFile) }
            return .box(BoxHeader(type: type, size: Int64(large), headerSize: 16, extendsToEnd: false))
        case 2..<8:
            return .stop(.malformedHeader)
        default:
            guard Int64(size32) <= remaining else { return .stop(.exceedsFile) }
            return .box(BoxHeader(type: type, size: Int64(size32), headerSize: 8, extendsToEnd: false))
        }
    }

    private func bytesInHead(at offset: Int64, count: Int) -> Data {
        guard offset < Int64(head.count) else { return Data() }
        let start = Int(offset)
        return head.subdata(in: start..<min(head.count, start + count))
    }

    private static func boxType(_ header: Data) -> String? {
        let start = header.startIndex + 4
        let bytes = header[start..<(start + 4)]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) || $0 == 0xA9 }) else { return nil }
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<(start + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        let start = data.startIndex + offset
        return data[start..<(start + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// 分片 MP4(moov 里有 mvex、mvhd 时长写 0)的时长。总时长不在 moov 里, 只能从
/// mehd、sidx、文件末尾的 mfra/tfra、或者逐个 moof 里的样本时长算出来。这里全是纯函数,
/// 输入是已经读回来的完整 box; 读哪几段由 `ISOBaseMediaRangeReader` 按预算决定。
public enum ISOBaseMediaFragmentDuration {
    public struct MovieInfo: Equatable, Sendable {
        public let movieTimescale: UInt32
        public let movieDuration: UInt64
        public let isFragmented: Bool
        /// mehd 的 fragment_duration, 以 movieTimescale 计。
        public let fragmentDuration: UInt64?
        /// 算时长用的轨道: 有声音轨用声音轨, 没有就用第一条。
        public let trackID: UInt32?
        public let trackTimescale: UInt32?
        /// 各轨道 trex 里的默认样本时长。
        public let defaultSampleDurations: [UInt32: UInt32]

        public var needsFragmentDuration: Bool { isFragmented && movieDuration == 0 }

        public var movieExtendsSeconds: TimeInterval? {
            guard let fragmentDuration else { return nil }
            return ISOBaseMediaFragmentDuration.seconds(fragmentDuration, timescale: movieTimescale)
        }

        public func trackSeconds(_ ticks: UInt64) -> TimeInterval? {
            guard let trackTimescale else { return nil }
            return ISOBaseMediaFragmentDuration.seconds(ticks, timescale: trackTimescale)
        }
    }

    public struct SegmentIndex: Equatable, Sendable {
        public let referenceID: UInt32
        public let timescale: UInt32
        /// 所有引用的 subsegment_duration 之和。指向下一级 sidx 的引用也写着它覆盖的时长,
        /// 所以层级式、链式的 sidx 只看第一个就够。
        public let totalDuration: UInt64

        public var seconds: TimeInterval? {
            ISOBaseMediaFragmentDuration.seconds(totalDuration, timescale: timescale)
        }
    }

    public struct RandomAccessEntry: Equatable, Sendable {
        public let trackID: UInt32
        /// 以轨道 timescale 计的展示时间。
        public let time: UInt64
        public let moofOffset: UInt64
        /// 从 1 数起: moof 里第几个 traf、traf 里第几个 trun、trun 里第几个样本。
        public let trafNumber: UInt32
        public let trunNumber: UInt32
        public let sampleNumber: UInt32
    }

    public struct TrackRun: Equatable, Sendable {
        public let sampleCount: Int
        /// 每个样本自己的时长; nil 时都是 `defaultDuration`。
        public let durations: [UInt32]?
        public let defaultDuration: UInt32

        public var total: UInt64 {
            if let durations {
                return durations.reduce(UInt64(0)) { $0 + UInt64($1) }
            }
            return UInt64(sampleCount) * UInt64(defaultDuration)
        }

        /// 从第 `index` 个样本(从 0 数)到这段末尾的时长。
        func duration(fromSample index: Int) -> UInt64? {
            guard index >= 0, index < sampleCount else { return nil }
            if let durations {
                return durations[index...].reduce(UInt64(0)) { $0 + UInt64($1) }
            }
            return UInt64(sampleCount - index) * UInt64(defaultDuration)
        }
    }

    public struct TrackFragment: Equatable, Sendable {
        public let trackID: UInt32
        /// tfdt 的 baseMediaDecodeTime。
        public let baseDecodeTime: UInt64?
        public let runs: [TrackRun]

        public var total: UInt64 { runs.reduce(UInt64(0)) { $0 + $1.total } }
    }

    public struct FragmentTiming: Equatable, Sendable {
        /// moof 里全部 traf, 按出现顺序(tfra 的 traf_number 就按这个数)。
        public let fragments: [TrackFragment]

        public func duration(trackID: UInt32?) -> UInt64? {
            var total: UInt64 = 0
            var matched = false
            for fragment in fragments where trackID == nil || fragment.trackID == trackID {
                total += fragment.total
                matched = true
            }
            return matched ? total : nil
        }

        /// tfra 条目指向的样本所在 traf 的结束时间: 条目时间加上从那个样本到 traf 末尾的时长;
        /// 编号对不上时退到 tfdt + 整个 traf 的时长。
        public func endTime(after entry: RandomAccessEntry) -> UInt64? {
            let trafIndex = Int(entry.trafNumber) - 1
            let runIndex = Int(entry.trunNumber) - 1
            if fragments.indices.contains(trafIndex) {
                let runs = fragments[trafIndex].runs
                if runs.indices.contains(runIndex),
                   let first = runs[runIndex].duration(fromSample: Int(entry.sampleNumber) - 1) {
                    var rest: UInt64 = 0
                    for run in runs[(runIndex + 1)...] { rest += run.total }
                    return ISOBaseMediaFragmentDuration.add(entry.time, first, rest)
                }
            }
            for fragment in fragments where fragment.trackID == entry.trackID {
                guard let base = fragment.baseDecodeTime else { continue }
                return ISOBaseMediaFragmentDuration.add(base, fragment.total, 0)
            }
            return nil
        }
    }

    // MARK: moov

    public static func movieInfo(moov: Data) -> MovieInfo? {
        let data = normalized(moov)
        guard let movie = children(data, in: 0..<data.count).first, movie.type == "moov" else {
            return nil
        }
        let boxes = children(data, in: movie.payload)
        guard let mvhd = boxes.first(where: { $0.type == "mvhd" }),
              let movieTiming = timescaleAndDuration(data, fullBox: mvhd.payload) else { return nil }

        var fragmentDuration: UInt64?
        var defaults: [UInt32: UInt32] = [:]
        let mvex = boxes.first(where: { $0.type == "mvex" })
        if let mvex {
            for box in children(data, in: mvex.payload) {
                let start = box.payload.lowerBound
                let limit = box.payload.upperBound
                if box.type == "mehd", let version = byte(data, start, limit) {
                    fragmentDuration = version == 1
                        ? uint64(data, start + 4, limit)
                        : uint32(data, start + 4, limit).map(UInt64.init)
                } else if box.type == "trex",
                          let trackID = uint32(data, start + 4, limit),
                          let duration = uint32(data, start + 12, limit) {
                    defaults[trackID] = duration
                }
            }
        }

        var sound: (id: UInt32, timescale: UInt32)?
        var first: (id: UInt32, timescale: UInt32)?
        for trak in boxes where trak.type == "trak" {
            let trakBoxes = children(data, in: trak.payload)
            guard let tkhd = trakBoxes.first(where: { $0.type == "tkhd" }),
                  let version = byte(data, tkhd.payload.lowerBound, tkhd.payload.upperBound),
                  let trackID = uint32(
                    data,
                    tkhd.payload.lowerBound + (version == 1 ? 20 : 12),
                    tkhd.payload.upperBound
                  ),
                  let mdia = trakBoxes.first(where: { $0.type == "mdia" }) else { continue }
            let mediaBoxes = children(data, in: mdia.payload)
            guard let mdhd = mediaBoxes.first(where: { $0.type == "mdhd" }),
                  let timing = timescaleAndDuration(data, fullBox: mdhd.payload) else { continue }
            let handler = mediaBoxes.first(where: { $0.type == "hdlr" }).flatMap {
                fourCC(data, $0.payload.lowerBound + 8, $0.payload.upperBound)
            }
            if first == nil { first = (trackID, timing.timescale) }
            if handler == "soun" {
                sound = (trackID, timing.timescale)
                break
            }
        }
        let track = sound ?? first
        return MovieInfo(
            movieTimescale: movieTiming.timescale,
            movieDuration: movieTiming.duration,
            isFragmented: mvex != nil,
            fragmentDuration: fragmentDuration,
            trackID: track?.id,
            trackTimescale: track?.timescale,
            defaultSampleDurations: defaults
        )
    }

    /// 补出时长后的 moov: mvhd 写上时长, mvex 改成 free(长度不变)。拿到的就是一个
    /// 普通的、只有元数据的 moov, 原生解析和 AVFoundation 都按它读时长。
    /// 版本 0 的 mvhd 按原 timescale 放不下时改用 1000。
    public static func patchedMovie(moov: Data, durationSeconds seconds: TimeInterval) -> Data? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        var data = normalized(moov)
        guard let movie = children(data, in: 0..<data.count).first, movie.type == "moov" else {
            return nil
        }
        let boxes = children(data, in: movie.payload)
        guard let mvhd = boxes.first(where: { $0.type == "mvhd" }) else { return nil }
        let start = mvhd.payload.lowerBound
        let limit = mvhd.payload.upperBound
        guard let version = byte(data, start, limit) else { return nil }
        if version == 1 {
            guard let timescale = uint32(data, start + 20, limit), timescale > 0,
                  start + 32 <= limit else { return nil }
            let ticks = (seconds * Double(timescale)).rounded()
            guard ticks >= 1, ticks < Double(UInt64(UInt32.max) << 16) else { return nil }
            write(UInt64(ticks), byteCount: 8, into: &data, at: start + 24)
        } else {
            guard let original = uint32(data, start + 12, limit), start + 20 <= limit else { return nil }
            var timescale = original
            var ticks = (seconds * Double(timescale)).rounded()
            if timescale == 0 || ticks >= Double(UInt32.max) {
                timescale = 1000
                ticks = (seconds * 1000).rounded()
            }
            guard ticks >= 1, ticks < Double(UInt32.max) else { return nil }
            write(UInt64(timescale), byteCount: 4, into: &data, at: start + 12)
            write(UInt64(ticks), byteCount: 4, into: &data, at: start + 16)
        }
        if let mvex = boxes.first(where: { $0.type == "mvex" }) {
            data.replaceSubrange((mvex.start + 4)..<(mvex.start + 8), with: Data("free".utf8))
        }
        return data
    }

    // MARK: sidx / mfra / moof

    public static func segmentIndex(_ box: Data) -> SegmentIndex? {
        let data = normalized(box)
        guard let sidx = children(data, in: 0..<data.count).first, sidx.type == "sidx" else {
            return nil
        }
        let start = sidx.payload.lowerBound
        let limit = sidx.payload.upperBound
        guard let version = byte(data, start, limit),
              let referenceID = uint32(data, start + 4, limit),
              let timescale = uint32(data, start + 8, limit), timescale > 0 else { return nil }
        // earliest_presentation_time 与 first_offset: 版本 0 各 4 字节, 版本 1 各 8 字节;
        // 之后是 reserved(2) + reference_count(2), 再是每条 12 字节的引用。
        let reserved = start + 12 + (version == 1 ? 16 : 8)
        guard let countWord = uint32(data, reserved, limit) else { return nil }
        let referenceCount = Int(countWord & 0xFFFF)
        let references = reserved + 4
        guard referenceCount > 0, references + referenceCount * 12 <= limit else { return nil }
        var total: UInt64 = 0
        for index in 0..<referenceCount {
            // referenced_type + referenced_size(4) 之后是 subsegment_duration(4)。
            guard let duration = uint32(data, references + index * 12 + 4, limit) else { return nil }
            total += UInt64(duration)
        }
        guard total > 0 else { return nil }
        return SegmentIndex(referenceID: referenceID, timescale: timescale, totalDuration: total)
    }

    /// 文件最后 16 字节的 mfro 写着整个 mfra 的长度。
    public static func randomAccessBoxSize(mfro: Data) -> Int64? {
        let data = normalized(mfro)
        guard data.count == 16,
              uint32(data, 0, 16) == 16,
              fourCC(data, 4, 16) == "mfro",
              let size = uint32(data, 12, 16), size >= 24 else { return nil }
        return Int64(size)
    }

    /// mfra 里这条轨道(没有就第一条)的 tfra 中时间最大的那一条。
    public static func lastRandomAccessEntry(mfra: Data, trackID: UInt32?) -> RandomAccessEntry? {
        let data = normalized(mfra)
        guard let box = children(data, in: 0..<data.count).first, box.type == "mfra" else {
            return nil
        }
        var fallback: RandomAccessEntry?
        for tfra in children(data, in: box.payload) where tfra.type == "tfra" {
            guard let entry = lastEntry(data, tfra: tfra.payload) else { continue }
            if trackID == nil || entry.trackID == trackID { return entry }
            if fallback == nil { fallback = entry }
        }
        return fallback
    }

    /// moof 里每个 traf 的样本时长。样本时长依次取 trun 里各自写的、tfhd 的默认值、
    /// trex 的默认值; 都没有就算不出来。
    public static func fragmentTiming(
        moof: Data,
        defaultSampleDurations: [UInt32: UInt32]
    ) -> FragmentTiming? {
        let data = normalized(moof)
        guard let box = children(data, in: 0..<data.count).first, box.type == "moof" else {
            return nil
        }
        var fragments: [TrackFragment] = []
        for traf in children(data, in: box.payload) where traf.type == "traf" {
            let boxes = children(data, in: traf.payload)
            guard let tfhd = boxes.first(where: { $0.type == "tfhd" }),
                  let flagWord = uint32(data, tfhd.payload.lowerBound, tfhd.payload.upperBound),
                  let trackID = uint32(data, tfhd.payload.lowerBound + 4, tfhd.payload.upperBound) else {
                return nil
            }
            let flags = flagWord & 0x00FF_FFFF
            var cursor = tfhd.payload.lowerBound + 8
            if flags & 0x01 != 0 { cursor += 8 }
            if flags & 0x02 != 0 { cursor += 4 }
            var defaultDuration = defaultSampleDurations[trackID]
            if flags & 0x08 != 0 {
                guard let declared = uint32(data, cursor, tfhd.payload.upperBound) else { return nil }
                defaultDuration = declared
            }
            var baseDecodeTime: UInt64?
            if let tfdt = boxes.first(where: { $0.type == "tfdt" }),
               let version = byte(data, tfdt.payload.lowerBound, tfdt.payload.upperBound) {
                baseDecodeTime = version == 1
                    ? uint64(data, tfdt.payload.lowerBound + 4, tfdt.payload.upperBound)
                    : uint32(data, tfdt.payload.lowerBound + 4, tfdt.payload.upperBound).map(UInt64.init)
            }
            var runs: [TrackRun] = []
            for trun in boxes where trun.type == "trun" {
                guard let run = trackRun(data, trun: trun.payload, defaultDuration: defaultDuration) else {
                    return nil
                }
                runs.append(run)
            }
            fragments.append(TrackFragment(trackID: trackID, baseDecodeTime: baseDecodeTime, runs: runs))
        }
        return fragments.isEmpty ? nil : FragmentTiming(fragments: fragments)
    }

    // MARK: Helpers

    struct Child {
        let type: String
        let start: Int
        let payload: Range<Int>
    }

    private static let maximumChildCount = 100_000
    private static let maximumSampleCount = 10_000_000

    static func seconds(_ ticks: UInt64, timescale: UInt32) -> TimeInterval? {
        guard ticks > 0, timescale > 0 else { return nil }
        let value = Double(ticks) / Double(timescale)
        return value.isFinite && value > 0 ? value : nil
    }

    static func add(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64? {
        let (ab, first) = a.addingReportingOverflow(b)
        let (sum, second) = ab.addingReportingOverflow(c)
        return first || second ? nil : sum
    }

    private static func normalized(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }

    /// `range` 里一层 box。长度不合法就停在那里, 已经认出的照样返回。
    static func children(_ data: Data, in range: Range<Int>) -> [Child] {
        var result: [Child] = []
        var cursor = range.lowerBound
        let end = min(range.upperBound, data.count)
        while end - cursor >= 8, result.count < maximumChildCount {
            guard let size32 = uint32(data, cursor, end),
                  let type = fourCC(data, cursor + 4, end) else { break }
            let size: Int
            var headerSize = 8
            switch size32 {
            case 0:
                size = end - cursor
            case 1:
                guard let large = uint64(data, cursor + 8, end),
                      large >= 16, large <= UInt64(end - cursor) else { return result }
                size = Int(large)
                headerSize = 16
            default:
                guard size32 >= 8, Int(size32) <= end - cursor else { return result }
                size = Int(size32)
            }
            result.append(Child(type: type, start: cursor, payload: (cursor + headerSize)..<(cursor + size)))
            cursor += size
        }
        return result
    }

    private static func timescaleAndDuration(
        _ data: Data,
        fullBox payload: Range<Int>
    ) -> (timescale: UInt32, duration: UInt64)? {
        let start = payload.lowerBound
        let limit = payload.upperBound
        guard let version = byte(data, start, limit) else { return nil }
        if version == 1 {
            guard let timescale = uint32(data, start + 20, limit),
                  let duration = uint64(data, start + 24, limit) else { return nil }
            return (timescale, duration)
        }
        guard let timescale = uint32(data, start + 12, limit),
              let duration = uint32(data, start + 16, limit) else { return nil }
        return (timescale, UInt64(duration))
    }

    private static func lastEntry(_ data: Data, tfra payload: Range<Int>) -> RandomAccessEntry? {
        let start = payload.lowerBound
        let limit = payload.upperBound
        guard let version = byte(data, start, limit),
              let trackID = uint32(data, start + 4, limit),
              let lengths = uint32(data, start + 8, limit),
              let count32 = uint32(data, start + 12, limit), count32 > 0 else { return nil }
        let trafLength = Int((lengths >> 4) & 0x3) + 1
        let trunLength = Int((lengths >> 2) & 0x3) + 1
        let sampleLength = Int(lengths & 0x3) + 1
        let timeLength = version == 1 ? 8 : 4
        let entryLength = timeLength * 2 + trafLength + trunLength + sampleLength
        let count = Int(count32)
        guard count <= (limit - start - 16) / entryLength else { return nil }
        var last: RandomAccessEntry?
        for index in 0..<count {
            var cursor = start + 16 + index * entryLength
            guard let time = number(data, cursor, timeLength, limit),
                  let moofOffset = number(data, cursor + timeLength, timeLength, limit) else { return nil }
            cursor += timeLength * 2
            guard let traf = number(data, cursor, trafLength, limit),
                  let trun = number(data, cursor + trafLength, trunLength, limit),
                  let sample = number(data, cursor + trafLength + trunLength, sampleLength, limit) else {
                return nil
            }
            if let previous = last, previous.time > time { continue }
            last = RandomAccessEntry(
                trackID: trackID,
                time: time,
                moofOffset: moofOffset,
                trafNumber: UInt32(truncatingIfNeeded: traf),
                trunNumber: UInt32(truncatingIfNeeded: trun),
                sampleNumber: UInt32(truncatingIfNeeded: sample)
            )
        }
        return last
    }

    private static func trackRun(
        _ data: Data,
        trun payload: Range<Int>,
        defaultDuration: UInt32?
    ) -> TrackRun? {
        let start = payload.lowerBound
        let limit = payload.upperBound
        guard let flagWord = uint32(data, start, limit),
              let count32 = uint32(data, start + 4, limit),
              count32 <= UInt32(maximumSampleCount) else { return nil }
        let flags = flagWord & 0x00FF_FFFF
        let count = Int(count32)
        var cursor = start + 8
        if flags & 0x001 != 0 { cursor += 4 }
        if flags & 0x004 != 0 { cursor += 4 }
        var fieldCount = 0
        for bit: UInt32 in [0x100, 0x200, 0x400, 0x800] where flags & bit != 0 {
            fieldCount += 1
        }
        let stride = fieldCount * 4
        guard cursor <= limit, count * stride <= limit - cursor else { return nil }
        if flags & 0x100 != 0 {
            var durations: [UInt32] = []
            durations.reserveCapacity(count)
            for index in 0..<count {
                guard let duration = uint32(data, cursor + index * stride, limit) else { return nil }
                durations.append(duration)
            }
            return TrackRun(sampleCount: count, durations: durations, defaultDuration: 0)
        }
        guard count == 0 || defaultDuration != nil else { return nil }
        return TrackRun(sampleCount: count, durations: nil, defaultDuration: defaultDuration ?? 0)
    }

    private static func byte(_ data: Data, _ offset: Int, _ limit: Int) -> UInt8? {
        guard offset >= 0, offset < limit, offset < data.count else { return nil }
        return data[offset]
    }

    static func uint32(_ data: Data, _ offset: Int, _ limit: Int) -> UInt32? {
        number(data, offset, 4, limit).map { UInt32(truncatingIfNeeded: $0) }
    }

    static func uint64(_ data: Data, _ offset: Int, _ limit: Int) -> UInt64? {
        number(data, offset, 8, limit)
    }

    /// 大端序, `length` 是 1...8 字节。
    private static func number(_ data: Data, _ offset: Int, _ length: Int, _ limit: Int) -> UInt64? {
        guard offset >= 0, length > 0, length <= 8,
              offset + length <= limit, offset + length <= data.count else { return nil }
        var value: UInt64 = 0
        for index in offset..<(offset + length) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }

    private static func fourCC(_ data: Data, _ offset: Int, _ limit: Int) -> String? {
        guard offset >= 0, offset + 4 <= limit, offset + 4 <= data.count else { return nil }
        return String(data[offset..<(offset + 4)].map { Character(Unicode.Scalar($0)) })
    }

    private static func write(_ value: UInt64, byteCount: Int, into data: inout Data, at offset: Int) {
        for index in 0..<byteCount {
            let shift = UInt64((byteCount - 1 - index) * 8)
            data[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }
}

/// Locates metadata by top-level atom boundaries, without reading media payloads.
public enum ISOBaseMediaRangeReader {
    public static let maximumMetadataByteCount = 64 * 1024 * 1024
    public static let chunkByteCount = 1024 * 1024
    private static let maximumAtomCount = 128
    private static let maximumFTYPByteCount: Int64 = 64 * 1024

    public enum ReadError: Error, Sendable {
        case incompleteRange
    }

    /// 拼好的 `ftyp` + `moov`, 以及 moov 在原文件里的位置。
    public struct Located: Sendable {
        public let metadataFile: Data
        public let moov: Range<Int64>
        /// 原文件在 moov 前面有 ftyp; 没有时 `metadataFile` 里是补上的 QuickTime ftyp。
        public let hasOriginalFTYP: Bool
        /// 分片 MP4 补出来的时长(秒)。补出来时 `metadataFile` 里的 moov 已经写上这个时长。
        public let fragmentDuration: TimeInterval?
        public let fragmentDurationSource: FragmentDurationSource?
    }

    /// 分片 MP4 的时长从哪儿来, 便宜的在前。
    public enum FragmentDurationSource: String, Sendable, Equatable {
        /// moov/mvex/mehd, 不用多读。
        case movieExtends
        /// sidx 里各段时长之和。
        case segmentIndex
        /// 文件末尾 mfra 的最后一个随机访问点, 加上它所在分片剩下的时长。
        case randomAccess
        /// 同上, 但那个分片没读到: 只用随机访问点的时间, 偏短, 差不到一个分片。
        case randomAccessFloor
        /// 逐个 moof 加样本时长。
        case fragmentWalk
    }

    /// 补分片时长时最多发几个请求、最多下多少字节(首段里有的不算)。
    public static let maximumFragmentRecoveryRequestCount = 64
    public static let maximumFragmentRecoveryByteCount: Int64 = 4 * 1024 * 1024
    /// sidx 和单个 moof 的上限。
    static let maximumFragmentIndexBoxByteCount: Int64 = 1024 * 1024
    /// mfra 的上限: 每条 tfra 不到 30 字节, 2 MB 足够几万个分片。
    static let maximumRandomAccessBoxByteCount: Int64 = 2 * 1024 * 1024
    /// 在首段、已读窗口之外读 box 头时顺带多读这么多: 音频的 moof 只有几百字节,
    /// moof 本身和它后面 mdat 的头多半一起回来, 一个分片一个请求。
    static let fragmentHeaderReadAheadByteCount: Int64 = 8 * 1024
    /// moov 之后找 sidx 最多看几个 box; 逐个 moof 最多走几个 box。
    static let maximumBoxesAfterMovie = 8
    static let maximumFragmentWalkBoxCount = 512

    /// 没有 ftyp 的老 QuickTime 文件: 补一个 QuickTime 品牌的 ftyp, 解析器按 QuickTime 的规矩读 moov。
    private static let quickTimeFTYP: Data = {
        var data = Data([0x00, 0x00, 0x00, 0x14])
        data.append(contentsOf: Array("ftypqt  ".utf8))
        data.append(contentsOf: [0x20, 0x05, 0x03, 0x00])
        data.append(contentsOf: Array("qt  ".utf8))
        return data
    }()

    /// Returns a complete `ftyp` + `moov` file, or nil for unsupported layouts.
    /// The supplied prefix is reused, including a partially available fast-start
    /// moov. All subsequent reads use absolute offsets, including past 4 GiB.
    public static func read(
        head: Data,
        fileSize: Int64,
        fetch: (Int64, Int64) async throws -> Data
    ) async throws -> Data? {
        try await readLocated(head: head, fileSize: fileSize, fetch: fetch)?.metadataFile
    }

    /// 同 `read`, 另外给出 moov 的位置。顶层 box 链由 `ISOBaseMediaTopLevelBoxWalk` 走:
    /// 首段之外的 box 头每个只读一小段, moov 按 1 MB 一块读回。
    public static func readLocated(
        head: Data,
        fileSize: Int64,
        fetch: (Int64, Int64) async throws -> Data
    ) async throws -> Located? {
        guard fileSize >= 8, head.count >= 8 else { return nil }

        func bytes(at offset: Int64, count: Int) async throws -> Data {
            var result = Data()
            if offset < Int64(head.count) {
                let start = Int(offset)
                let end = start + min(count, head.count - start)
                result.append(head[head.startIndex + start..<head.startIndex + end])
            }
            while result.count < count {
                try Task.checkCancellation()
                let length = min(chunkByteCount, count - result.count)
                let part = try await fetch(offset + Int64(result.count), Int64(length))
                guard part.count == length else { throw ReadError.incompleteRange }
                result.append(part)
            }
            return result
        }

        var walk = ISOBaseMediaTopLevelBoxWalk(
            head: head,
            fileSize: fileSize,
            maximumMoovByteCount: Int64(maximumMetadataByteCount),
            maximumBoxCount: maximumAtomCount
        )
        while case .needsHeader(let offset, let count) = walk.step {
            try Task.checkCancellation()
            let header = try await fetch(offset, Int64(count))
            // 要的长度从不越过文件末尾, 读短了跟 moov 正文读短一样当作这次读取失败。
            guard header.count == count else { throw ReadError.incompleteRange }
            walk.consume(header: header)
        }
        guard case .foundMoov(let moovOffset, let moovSize) = walk.step else { return nil }

        let ftyp: Data
        if let range = walk.ftyp {
            let length = range.upperBound - range.lowerBound
            guard length <= maximumFTYPByteCount else { return nil }
            ftyp = try await bytes(at: range.lowerBound, count: Int(length))
        } else {
            ftyp = quickTimeFTYP
        }
        var moov = try await bytes(at: moovOffset, count: Int(moovSize))

        // 分片 MP4: mvhd 是 0, 时长要从 moov 之外找。补不出来不影响已经读到的 moov ——
        // 读失败(包括服务器不认 Range)只是没有时长, 取消照常往上抛。
        var fragmentDuration: TimeInterval?
        var fragmentDurationSource: FragmentDurationSource?
        if let movie = ISOBaseMediaFragmentDuration.movieInfo(moov: moov), movie.needsFragmentDuration {
            do {
                if let recovered = try await recoverFragmentDuration(
                    movie: movie,
                    moovEnd: moovOffset + moovSize,
                    segmentIndexBeforeMovie: walk.segmentIndex,
                    head: head,
                    fileSize: fileSize,
                    fetch: fetch
                ) {
                    fragmentDuration = recovered.seconds
                    fragmentDurationSource = recovered.source
                    if let patched = ISOBaseMediaFragmentDuration.patchedMovie(
                        moov: moov,
                        durationSeconds: recovered.seconds
                    ) {
                        moov = patched
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 这段补读失败: 没有时长, moov 照用。调用方的读取函数自己记下服务器不认 Range。
            }
        }

        guard let metadataFile = ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(
            head: ftyp,
            tail: moov
        ) else { return nil }
        return Located(
            metadataFile: metadataFile,
            moov: moovOffset..<(moovOffset + moovSize),
            hasOriginalFTYP: walk.ftyp != nil,
            fragmentDuration: fragmentDuration,
            fragmentDurationSource: fragmentDurationSource
        )
    }

    /// 按 mehd → sidx → mfra/tfra → 逐个 moof 的顺序找分片 MP4 的时长, 前一种有结果就停。
    /// 首段里有的字节不花预算; 之外的读取受 `maximumFragmentRecoveryRequestCount` 和
    /// `maximumFragmentRecoveryByteCount` 约束, 用完就放弃(返回 nil)。
    static func recoverFragmentDuration(
        movie: ISOBaseMediaFragmentDuration.MovieInfo,
        moovEnd: Int64,
        segmentIndexBeforeMovie: Range<Int64>?,
        head: Data,
        fileSize: Int64,
        fetch: (Int64, Int64) async throws -> Data
    ) async throws -> (seconds: TimeInterval, source: FragmentDurationSource)? {
        if let seconds = movie.movieExtendsSeconds {
            return (seconds, .movieExtends)
        }

        var requestCount = 0
        var fetchedByteCount: Int64 = 0
        var windowOffset: Int64 = 0
        var window = Data()

        /// 首段或上一次读回的窗口里有就直接给。
        func cached(at offset: Int64, count: Int64) -> Data? {
            guard offset >= 0, count > 0 else { return nil }
            if offset + count <= Int64(head.count) {
                let start = head.startIndex + Int(offset)
                return head.subdata(in: start..<(start + Int(count)))
            }
            if offset >= windowOffset, offset + count <= windowOffset + Int64(window.count) {
                let start = window.startIndex + Int(offset - windowOffset)
                return window.subdata(in: start..<(start + Int(count)))
            }
            return nil
        }

        /// 预算用完返回 nil。
        func read(at offset: Int64, count: Int64) async throws -> Data? {
            guard offset >= 0, count > 0, count <= fileSize - offset else { return nil }
            if let data = cached(at: offset, count: count) { return data }
            guard requestCount < maximumFragmentRecoveryRequestCount,
                  count <= maximumFragmentRecoveryByteCount - fetchedByteCount else { return nil }
            try Task.checkCancellation()
            requestCount += 1
            fetchedByteCount += count
            let data = try await fetch(offset, count)
            guard data.count == Int(count) else { throw ReadError.incompleteRange }
            windowOffset = offset
            window = data
            return data
        }

        func boxHeader(at offset: Int64) async throws -> ISOBaseMediaTopLevelBoxWalk.BoxHeader? {
            let remaining = fileSize - offset
            guard remaining >= 8 else { return nil }
            let probe = min(Int64(ISOBaseMediaTopLevelBoxWalk.headerProbeByteCount), remaining)
            let header: Data
            if let data = cached(at: offset, count: probe) {
                header = data
            } else {
                let ahead = min(max(probe, fragmentHeaderReadAheadByteCount), remaining)
                guard let data = try await read(at: offset, count: ahead) else { return nil }
                header = data.prefix(Int(probe))
            }
            guard case .box(let box) = ISOBaseMediaTopLevelBoxWalk.parseHeader(
                header,
                remaining: remaining,
                isFirstBox: false
            ) else { return nil }
            return box
        }

        func segmentIndexSeconds(at offset: Int64, size: Int64) async throws -> TimeInterval? {
            guard size <= maximumFragmentIndexBoxByteCount,
                  let box = try await read(at: offset, count: size) else { return nil }
            return ISOBaseMediaFragmentDuration.segmentIndex(box)?.seconds
        }

        func fragmentTiming(at offset: Int64) async throws -> ISOBaseMediaFragmentDuration.FragmentTiming? {
            guard let header = try await boxHeader(at: offset),
                  header.type == "moof",
                  header.size <= maximumFragmentIndexBoxByteCount,
                  let moof = try await read(at: offset, count: header.size) else { return nil }
            return ISOBaseMediaFragmentDuration.fragmentTiming(
                moof: moof,
                defaultSampleDurations: movie.defaultSampleDurations
            )
        }

        // sidx: moov 前面走过的, 或者紧跟在 moov 后面的几个 box 里。
        if let range = segmentIndexBeforeMovie,
           let seconds = try await segmentIndexSeconds(
            at: range.lowerBound,
            size: range.upperBound - range.lowerBound
           ) {
            return (seconds, .segmentIndex)
        }
        var cursor = moovEnd
        var mediaStart: Int64?
        for _ in 0..<maximumBoxesAfterMovie {
            guard let box = try await boxHeader(at: cursor) else { break }
            if box.type == "sidx",
               let seconds = try await segmentIndexSeconds(at: cursor, size: box.size) {
                return (seconds, .segmentIndex)
            }
            if box.type == "moof" || box.type == "mdat" {
                mediaStart = cursor
                break
            }
            if box.type == "mfra" || box.extendsToEnd { break }
            cursor += box.size
        }

        // mfra: 文件最后 16 字节的 mfro 写着 mfra 多长, tfra 里最后一条是最后一个随机访问点。
        if fileSize >= 24,
           let mfro = try await read(at: fileSize - 16, count: 16),
           let mfraSize = ISOBaseMediaFragmentDuration.randomAccessBoxSize(mfro: mfro),
           mfraSize <= maximumRandomAccessBoxByteCount, mfraSize <= fileSize,
           let mfra = try await read(at: fileSize - mfraSize, count: mfraSize),
           let entry = ISOBaseMediaFragmentDuration.lastRandomAccessEntry(mfra: mfra, trackID: movie.trackID) {
            if let moofOffset = Int64(exactly: entry.moofOffset),
               moofOffset < fileSize,
               let timing = try await fragmentTiming(at: moofOffset),
               let end = timing.endTime(after: entry),
               let seconds = movie.trackSeconds(end) {
                return (seconds, .randomAccess)
            }
            if let seconds = movie.trackSeconds(entry.time) {
                return (seconds, .randomAccessFloor)
            }
        }

        // 最后一招: 从第一个分片起逐个 moof 加样本时长, mdat 只看头。走到文件末尾才算数,
        // 预算或 box 数用完就放弃 —— 只加了一部分的时长差得太多, 不如没有。
        guard var walkCursor = mediaStart else { return nil }
        var total: UInt64 = 0
        var sawFragment = false
        for _ in 0..<maximumFragmentWalkBoxCount {
            if fileSize - walkCursor < 8 {
                guard sawFragment, let seconds = movie.trackSeconds(total) else { return nil }
                return (seconds, .fragmentWalk)
            }
            guard let box = try await boxHeader(at: walkCursor) else { return nil }
            if box.type == "moof" {
                guard let timing = try await fragmentTiming(at: walkCursor),
                      let duration = timing.duration(trackID: movie.trackID) else { return nil }
                let (sum, overflow) = total.addingReportingOverflow(duration)
                guard !overflow else { return nil }
                total = sum
                sawFragment = true
            }
            if box.type == "mfra" || box.extendsToEnd {
                guard sawFragment, let seconds = movie.trackSeconds(total) else { return nil }
                return (seconds, .fragmentWalk)
            }
            walkCursor += box.size
        }
        return nil
    }
}
