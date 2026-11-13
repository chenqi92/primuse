import Foundation

// 读标签时不开 AVFoundation 也能拿到时长与音频参数的两种常见格式。
//
// AVFoundation 每首歌要建一个 AVURLAsset、经由资源加载器一段段要字节, 而给它喂字节
// 的队列是全进程共用的一条串行队列 —— 读取位开得再多, MP3/M4A 也挤在这一条上。
// 这里的解析器只认结构完整、写法常见的文件; 认不准的一律返回 nil, 交回原来的
// AVFoundation 路径, 所以冷门写法的结果不变。

// MARK: - MPEG audio (MP3)

/// 一段 MPEG Layer III 码流的头部信息。时长优先取 Xing/Info/VBRI 头里的总帧数;
/// 没有这些头时 `frameCount` 为 nil, 由调用方按字节数估算(与 AVFoundation 只拿到
/// 一段前缀时的做法相同, 远端读取之后会再按整个文件的大小折算)。
public struct MPEGAudioStreamInfo: Equatable, Sendable {
    public let frameOffset: Int
    public let sampleRate: Int
    /// 第一帧帧头里的码率。
    public let bitRateKbps: Int
    public let channelCount: Int
    public let samplesPerFrame: Int
    public let frameCount: Int?
    public let streamByteCount: Int?
    /// 没有时长头时, 在手里这段字节里逐帧走出来的平均码率(VBR 也不会被第一帧带偏)。
    public let scannedAverageBitRateKbps: Double?

    public var exactDuration: TimeInterval? {
        guard let frameCount, frameCount > 0, sampleRate > 0 else { return nil }
        return Double(frameCount) * Double(samplesPerFrame) / Double(sampleRate)
    }

    /// 时长头给了总帧数与总字节数时的平均码率。
    public var headerAverageBitRateKbps: Int? {
        guard let streamByteCount, streamByteCount > 0,
              let duration = exactDuration, duration > 0 else { return nil }
        let kbps = Double(streamByteCount) * 8 / duration / 1_000
        guard kbps.isFinite, kbps > 0 else { return nil }
        return Int(kbps.rounded())
    }
}

public enum MPEGAudioStreamParser {
    /// 从 `audioStart`(ID3v2 标签之后)起找第一帧 Layer III。帧头要被紧接着的下一帧
    /// 印证(或者这一帧本身带着 Xing/Info/VBRI 头), 防止把封面里碰巧的 0xFFE 当成帧。
    public static func parse(
        _ data: Data,
        audioStart: Int,
        searchWindow: Int = 64 * 1024
    ) -> MPEGAudioStreamInfo? {
        let count = data.count
        guard audioStart >= 0, audioStart <= count - 4 else { return nil }
        let searchEnd = min(count - 4, audioStart + searchWindow)
        var offset = audioStart
        while offset <= searchEnd {
            defer { offset += 1 }
            guard let header = header(in: data, at: offset) else { continue }
            let durationHeader = durationHeader(in: data, frameOffset: offset, header: header)
            let next = offset + header.frameLength
            if next <= count - 4 {
                guard let following = Self.header(in: data, at: next),
                      following.versionBits == header.versionBits,
                      following.sampleRate == header.sampleRate else { continue }
            } else if durationHeader == nil {
                // 手里只有这半帧, 又没有时长头可以印证, 不当真。
                continue
            }
            let scanned = durationHeader == nil
                ? scannedAverageBitRate(in: data, from: offset, first: header)
                : nil
            return MPEGAudioStreamInfo(
                frameOffset: offset,
                sampleRate: header.sampleRate,
                bitRateKbps: header.bitRateKbps,
                channelCount: header.isMono ? 1 : 2,
                samplesPerFrame: header.samplesPerFrame,
                frameCount: durationHeader?.frames,
                streamByteCount: durationHeader?.bytes,
                scannedAverageBitRateKbps: scanned
            )
        }
        return nil
    }

    struct FrameHeader: Equatable {
        let versionBits: Int
        let sampleRate: Int
        let bitRateKbps: Int
        let frameLength: Int
        let isMono: Bool

        var isMPEG1: Bool { versionBits == 3 }
        var samplesPerFrame: Int { isMPEG1 ? 1_152 : 576 }
        /// Layer III 边信息的长度, Xing/Info 头紧跟在它后面。
        var sideInformationLength: Int {
            isMPEG1 ? (isMono ? 17 : 32) : (isMono ? 9 : 17)
        }
    }

    static func header(in data: Data, at offset: Int) -> FrameHeader? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let base = data.startIndex + offset
        let b0 = data[base], b1 = data[base + 1], b2 = data[base + 2], b3 = data[base + 3]
        guard b0 == 0xFF, (b1 & 0xE0) == 0xE0 else { return nil }
        let versionBits = Int((b1 >> 3) & 0x03)
        let layerBits = Int((b1 >> 1) & 0x03)
        guard versionBits != 1, layerBits == 1 else { return nil } // MPEG Layer III
        let bitRateIndex = Int((b2 >> 4) & 0x0F)
        let sampleRateIndex = Int((b2 >> 2) & 0x03)
        // 0 是自由码率, 15 非法; 两种都交回 AVFoundation。
        guard (1...14).contains(bitRateIndex), sampleRateIndex < 3 else { return nil }
        let bitRateKbps = versionBits == 3
            ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320][bitRateIndex - 1]
            : [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160][bitRateIndex - 1]
        let baseSampleRate = [44_100, 48_000, 32_000][sampleRateIndex]
        let sampleRate = switch versionBits {
        case 3: baseSampleRate
        case 2: baseSampleRate / 2
        default: baseSampleRate / 4
        }
        let padding = Int((b2 >> 1) & 0x01)
        let coefficient = versionBits == 3 ? 144 : 72
        let frameLength = coefficient * bitRateKbps * 1_000 / sampleRate + padding
        guard frameLength >= 4 else { return nil }
        return FrameHeader(
            versionBits: versionBits,
            sampleRate: sampleRate,
            bitRateKbps: bitRateKbps,
            frameLength: frameLength,
            isMono: (b3 >> 6) == 0x03
        )
    }

    private struct DurationHeader: Equatable {
        let frames: Int?
        let bytes: Int?
    }

    private static func durationHeader(
        in data: Data,
        frameOffset: Int,
        header: FrameHeader
    ) -> DurationHeader? {
        let xingOffset = frameOffset + 4 + header.sideInformationLength
        if let tag = ascii(data, at: xingOffset, count: 4), tag == "Xing" || tag == "Info",
           let flags = uint32BE(data, at: xingOffset + 4) {
            var cursor = xingOffset + 8
            var frames: Int?
            var bytes: Int?
            if flags & 0x1 != 0 {
                frames = uint32BE(data, at: cursor).map(Int.init)
                cursor += 4
            }
            if flags & 0x2 != 0 {
                bytes = uint32BE(data, at: cursor).map(Int.init)
            }
            guard let frames, frames > 0 else { return nil }
            return DurationHeader(frames: frames, bytes: bytes.flatMap { $0 > 0 ? $0 : nil })
        }
        // VBRI 固定在帧头后 32 字节处。
        let vbriOffset = frameOffset + 4 + 32
        if ascii(data, at: vbriOffset, count: 4) == "VBRI",
           let bytes = uint32BE(data, at: vbriOffset + 10),
           let frames = uint32BE(data, at: vbriOffset + 14), frames > 0 {
            return DurationHeader(frames: Int(frames), bytes: bytes > 0 ? Int(bytes) : nil)
        }
        return nil
    }

    /// 在手里这段字节里逐帧往后走, 求平均码率。CBR 就是帧头码率; VBR 没有时长头时
    /// 也不会只看第一帧。帧链断掉就停, 至少走过两帧才算数。
    private static func scannedAverageBitRate(
        in data: Data,
        from start: Int,
        first: FrameHeader
    ) -> Double? {
        var offset = start
        var frames = 0
        var bytes = 0
        while let header = header(in: data, at: offset),
              header.versionBits == first.versionBits,
              header.sampleRate == first.sampleRate,
              offset + header.frameLength <= data.count {
            frames += 1
            bytes += header.frameLength
            offset += header.frameLength
        }
        guard frames >= 2 else { return nil }
        let seconds = Double(frames * first.samplesPerFrame) / Double(first.sampleRate)
        let kbps = Double(bytes) * 8 / seconds / 1_000
        return kbps.isFinite && kbps > 0 ? kbps : nil
    }

    private static func ascii(_ data: Data, at offset: Int, count: Int) -> String? {
        guard offset >= 0, offset <= data.count - count else { return nil }
        let start = data.startIndex + offset
        return String(data: data[start..<(start + count)], encoding: .isoLatin1)
    }

    private static func uint32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }
}

// MARK: - ISO Base Media (M4A / M4B / ALAC)

/// 一个完整 `moov` 里 AVFoundation 原来提供给标签读取的那些值。
public struct ISOBaseMediaNativeMetadata: Equatable, Sendable {
    public var duration: TimeInterval
    public var codecFourCC: String
    public var sampleRate: Int
    public var channelCount: Int
    /// ALAC 配置里的源位深; AAC 没有位深。
    public var bitDepth: Int?
    /// 音轨所有样本的字节数折成的平均码率(比特/秒)。
    public var averageBitRate: Int?
    public var titles: [String] = []
    public var artists: [String] = []
    public var albumTitle: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var releaseDate: String?
    public var userGenre: String?
    public var predefinedGenreCode: Int?
    public var coverArtData: Data?
    public var lyrics: String?
}

public enum ISOBaseMediaNativeMetadataParser {
    /// 只认这些常见结构: 一条音轨、`stsd` 是 v0 的 AAC-LC 或 ALAC、标签全在
    /// `udta/meta/ilst`。QuickTime 的 `mdta` 键表、HE-AAC、多条音轨、分片 MP4、
    /// `udta` 里的 QuickTime 文本条目等一律返回 nil, 由 AVFoundation 读。
    public static func parse(_ data: Data) -> ISOBaseMediaNativeMetadata? {
        let topLevel = atoms(in: data, range: data.startIndex..<data.endIndex)
        let movies = topLevel.filter { $0.type == "moov" }
        guard movies.count == 1, let moov = movies.first else { return nil }
        let children = atoms(in: data, range: moov.payload)
        guard !children.contains(where: { $0.type == "mvex" || $0.type == "meta" }),
              let mvhd = children.first(where: { $0.type == "mvhd" }),
              let movieDuration = movieDuration(in: data, mvhd: mvhd), movieDuration > 0 else {
            return nil
        }
        let audioTracks = children.filter { $0.type == "trak" }.compactMap { audioTrack(in: data, trak: $0) }
        guard audioTracks.count == 1, let track = audioTracks.first,
              let entry = sampleEntry(in: data, stsd: track.stsd) else { return nil }

        var result = ISOBaseMediaNativeMetadata(
            duration: movieDuration,
            codecFourCC: entry.codec,
            sampleRate: entry.sampleRate,
            channelCount: entry.channelCount,
            bitDepth: entry.bitDepth
        )
        if let stsz = track.stsz, let sampleBytes = totalSampleBytes(in: data, stsz: stsz),
           let mediaDuration = track.mediaDuration, mediaDuration > 0 {
            let bitsPerSecond = Double(sampleBytes) * 8 / mediaDuration
            if bitsPerSecond.isFinite, bitsPerSecond > 0 {
                result.averageBitRate = Int(bitsPerSecond.rounded())
            }
        }
        if let udta = children.first(where: { $0.type == "udta" }) {
            guard applyUserData(in: data, udta: udta, to: &result) else { return nil }
        }
        return result
    }

    // MARK: Tracks

    private struct AudioTrack {
        let stsd: Atom
        let stsz: Atom?
        let mediaDuration: TimeInterval?
    }

    private struct SampleEntry {
        let codec: String
        let sampleRate: Int
        let channelCount: Int
        let bitDepth: Int?
    }

    private static func movieDuration(in data: Data, mvhd: Atom) -> TimeInterval? {
        timescaledDuration(in: data, fullBox: mvhd)
    }

    /// `mvhd` 与 `mdhd` 的版本 0/1 布局相同: 创建/修改时间之后是 timescale 与 duration。
    private static func timescaledDuration(in data: Data, fullBox: Atom) -> TimeInterval? {
        let start = fullBox.payload.lowerBound
        guard let version = byte(data, at: start) else { return nil }
        let timescale: UInt32?
        let duration: UInt64?
        if version == 1 {
            timescale = uint32BE(data, at: start + 4 + 16)
            duration = uint64BE(data, at: start + 4 + 20)
        } else {
            timescale = uint32BE(data, at: start + 4 + 8)
            duration = uint32BE(data, at: start + 4 + 12).map(UInt64.init)
        }
        guard let timescale, timescale > 0, let duration, duration > 0,
              duration != UInt64(UInt32.max), duration != UInt64.max else { return nil }
        let seconds = Double(duration) / Double(timescale)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func audioTrack(in data: Data, trak: Atom) -> AudioTrack? {
        guard let mdia = atoms(in: data, range: trak.payload).first(where: { $0.type == "mdia" }) else { return nil }
        let media = atoms(in: data, range: mdia.payload)
        guard let hdlr = media.first(where: { $0.type == "hdlr" }),
              fourCC(data, at: hdlr.payload.lowerBound + 8) == "soun",
              let minf = media.first(where: { $0.type == "minf" }),
              let stbl = atoms(in: data, range: minf.payload).first(where: { $0.type == "stbl" }) else {
            return nil
        }
        let table = atoms(in: data, range: stbl.payload)
        guard let stsd = table.first(where: { $0.type == "stsd" }) else { return nil }
        return AudioTrack(
            stsd: stsd,
            stsz: table.first(where: { $0.type == "stsz" }),
            mediaDuration: media.first(where: { $0.type == "mdhd" }).flatMap {
                timescaledDuration(in: data, fullBox: $0)
            }
        )
    }

    private static func sampleEntry(in data: Data, stsd: Atom) -> SampleEntry? {
        // stsd: FullBox(4) + entry_count(4), 只认一个条目。
        guard uint32BE(data, at: stsd.payload.lowerBound + 4) == 1,
              let entry = atom(in: data, startingAt: stsd.payload.lowerBound + 8, limit: stsd.payload.upperBound),
              entry.payload.count >= 28 else { return nil }
        let fields = entry.payload.lowerBound
        // SampleEntry(8) 之后是 AudioSampleEntry: version(2) revision(2) vendor(4)
        // channelcount(2) samplesize(2) compression(2) packetsize(2) samplerate(4, 16.16)。
        guard uint16BE(data, at: fields + 8) == 0,
              let channels = uint16BE(data, at: fields + 16),
              let rateFixed = uint32BE(data, at: fields + 24) else { return nil }
        let declaredRate = Int(rateFixed >> 16)
        let boxes = atoms(in: data, range: (fields + 28)..<entry.payload.upperBound)
        switch entry.type {
        case "mp4a":
            guard let esds = boxes.first(where: { $0.type == "esds" }),
                  let config = aacConfig(in: data, esds: esds),
                  config.audioObjectType == 2,
                  // 低于 32 kHz 的 LC 多半是隐式 SBR 的 HE-AAC, AVFoundation 报的是解出来的采样率。
                  config.sampleRate >= 32_000,
                  declaredRate == 0 || declaredRate == config.sampleRate else { return nil }
            let channelCount = config.channelConfiguration > 0
                ? min(Int(config.channelConfiguration), 8) : Int(channels)
            return SampleEntry(codec: "mp4a", sampleRate: config.sampleRate,
                               channelCount: channelCount, bitDepth: nil)
        case "alac":
            // alac 子盒: FullBox(4) + ALACSpecificConfig(24)。
            guard let cookie = boxes.first(where: { $0.type == "alac" }),
                  cookie.payload.count >= 28,
                  let depth = byte(data, at: cookie.payload.lowerBound + 4 + 5),
                  [16, 20, 24, 32].contains(Int(depth)),
                  let channelCount = byte(data, at: cookie.payload.lowerBound + 4 + 9),
                  let rate = uint32BE(data, at: cookie.payload.lowerBound + 4 + 20), rate > 0 else {
                return nil
            }
            return SampleEntry(codec: "alac", sampleRate: Int(rate),
                               channelCount: Int(channelCount), bitDepth: Int(depth))
        default:
            return nil
        }
    }

    private struct AACConfig {
        let audioObjectType: Int
        let sampleRate: Int
        let channelConfiguration: Int
    }

    private static let aacSampleRates = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// esds: FullBox(4) + ES_Descriptor(0x03) → DecoderConfigDescriptor(0x04) → DecoderSpecificInfo(0x05)。
    private static func aacConfig(in data: Data, esds: Atom) -> AACConfig? {
        var cursor = esds.payload.lowerBound + 4
        let end = esds.payload.upperBound
        guard let es = descriptor(in: data, at: &cursor, end: end), es.tag == 0x03 else { return nil }
        cursor = es.body.lowerBound + 2 // ES_ID
        guard let flags = byte(data, at: cursor) else { return nil }
        cursor += 1
        if flags & 0x80 != 0 { cursor += 2 }
        if flags & 0x40 != 0 {
            guard let length = byte(data, at: cursor) else { return nil }
            cursor += 1 + Int(length)
        }
        if flags & 0x20 != 0 { cursor += 2 }
        guard let decoderConfig = descriptor(in: data, at: &cursor, end: es.body.upperBound),
              decoderConfig.tag == 0x04,
              byte(data, at: decoderConfig.body.lowerBound) == 0x40 else { return nil } // MPEG-4 Audio
        cursor = decoderConfig.body.lowerBound + 13
        guard let specific = descriptor(in: data, at: &cursor, end: decoderConfig.body.upperBound),
              specific.tag == 0x05, specific.body.count >= 2 else { return nil }
        var reader = BitReader(data: data, range: specific.body)
        guard var objectType = reader.read(5) else { return nil }
        if objectType == 31 {
            guard let extended = reader.read(6) else { return nil }
            objectType = 32 + extended
        }
        guard let rateIndex = reader.read(4) else { return nil }
        let sampleRate: Int
        if rateIndex == 0x0F {
            guard let explicit = reader.read(24) else { return nil }
            sampleRate = explicit
        } else {
            guard rateIndex < aacSampleRates.count else { return nil }
            sampleRate = aacSampleRates[rateIndex]
        }
        guard let channels = reader.read(4) else { return nil }
        return AACConfig(audioObjectType: objectType, sampleRate: sampleRate, channelConfiguration: channels)
    }

    private struct Descriptor {
        let tag: UInt8
        let body: Range<Int>
    }

    private static func descriptor(in data: Data, at cursor: inout Int, end: Int) -> Descriptor? {
        guard cursor < end, let tag = byte(data, at: cursor) else { return nil }
        cursor += 1
        var length = 0
        for _ in 0..<4 {
            guard cursor < end, let value = byte(data, at: cursor) else { return nil }
            cursor += 1
            length = (length << 7) | Int(value & 0x7F)
            if value & 0x80 == 0 { break }
        }
        guard length <= end - cursor else { return nil }
        let body = cursor..<(cursor + length)
        cursor += length
        return Descriptor(tag: tag, body: body)
    }

    private struct BitReader {
        let data: Data
        let range: Range<Int>
        var bitOffset = 0

        init(data: Data, range: Range<Int>) {
            self.data = data
            self.range = range
        }

        mutating func read(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                let index = range.lowerBound + bitOffset / 8
                guard index < range.upperBound else { return nil }
                let bit = (Int(data[index]) >> (7 - bitOffset % 8)) & 1
                value = (value << 1) | bit
                bitOffset += 1
            }
            return value
        }
    }

    private static func totalSampleBytes(in data: Data, stsz: Atom) -> Int64? {
        let start = stsz.payload.lowerBound
        guard let uniformSize = uint32BE(data, at: start + 4),
              let sampleCount = uint32BE(data, at: start + 8), sampleCount > 0 else { return nil }
        if uniformSize > 0 { return Int64(uniformSize) * Int64(sampleCount) }
        let tableStart = start + 12
        guard Int(sampleCount) <= (stsz.payload.upperBound - tableStart) / 4 else { return nil }
        var total: Int64 = 0
        var cursor = data.startIndex + tableStart
        for _ in 0..<Int(sampleCount) {
            total += Int64((UInt32(data[cursor]) << 24) | (UInt32(data[cursor + 1]) << 16)
                | (UInt32(data[cursor + 2]) << 8) | UInt32(data[cursor + 3]))
            cursor += 4
        }
        return total > 0 ? total : nil
    }

    // MARK: Tags

    /// `udta` 里只认 iTunes 式的 `meta/ilst` 与几种不承载标签的盒子。别的(QuickTime
    /// 的 `©nam` 等文本条目、3GPP 资产盒)AVFoundation 会读成标题、艺人, 交回给它。
    private static let ignorableUserDataTypes: Set<String> = ["chpl", "free", "skip", "Xtra", "tsel", "hnti"]
    private static let ignorableMetaTypes: Set<String> = ["hdlr", "free", "skip"]

    private static func applyUserData(
        in data: Data,
        udta: Atom,
        to result: inout ISOBaseMediaNativeMetadata
    ) -> Bool {
        for child in atoms(in: data, range: udta.payload) {
            if child.type == "meta" {
                guard applyMeta(in: data, meta: child, to: &result) else { return false }
            } else if !ignorableUserDataTypes.contains(child.type) {
                return false
            }
        }
        return true
    }

    private static func applyMeta(
        in data: Data,
        meta: Atom,
        to result: inout ISOBaseMediaNativeMetadata
    ) -> Bool {
        // iTunes 的 meta 是 FullBox; 第一个子盒必须是 mdir 处理器。
        let childrenStart = meta.payload.lowerBound + 4
        guard fourCC(data, at: childrenStart + 4) == "hdlr" else { return false }
        let children = atoms(in: data, range: childrenStart..<meta.payload.upperBound)
        guard let hdlr = children.first(where: { $0.type == "hdlr" }),
              fourCC(data, at: hdlr.payload.lowerBound + 8) == "mdir" else { return false }
        for child in children {
            if child.type == "ilst" {
                for item in atoms(in: data, range: child.payload) {
                    apply(item: item, in: data, to: &result)
                }
            } else if !ignorableMetaTypes.contains(child.type) {
                return false
            }
        }
        return true
    }

    private static func apply(item: Atom, in data: Data, to result: inout ISOBaseMediaNativeMetadata) {
        let values = atoms(in: data, range: item.payload).filter { $0.type == "data" && $0.payload.count >= 8 }
        guard !values.isEmpty else { return }
        func texts() -> [String] {
            values.compactMap { value in
                guard let type = uint32BE(data, at: value.payload.lowerBound) else { return nil }
                return decodeText(data.subdata(in: (value.payload.lowerBound + 8)..<value.payload.upperBound),
                                  declaredType: type & 0x00FF_FFFF)
            }
        }
        func firstPayload() -> Data {
            let value = values[0]
            return data.subdata(in: (value.payload.lowerBound + 8)..<value.payload.upperBound)
        }
        func indexPair() -> Int? {
            let payload = firstPayload()
            if let type = uint32BE(data, at: values[0].payload.lowerBound), type & 0x00FF_FFFF == 1 {
                return texts().first.flatMap { Int($0.split(separator: "/").first.map(String.init) ?? "") }
            }
            return MP4IndexPairAtom.decode(payload)?.number
        }
        switch item.type {
        case "\u{A9}nam": result.titles.append(contentsOf: texts())
        case "\u{A9}ART": result.artists.append(contentsOf: texts())
        case "\u{A9}alb": result.albumTitle = result.albumTitle ?? texts().first
        case "aART": result.albumArtist = result.albumArtist ?? texts().first
        case "\u{A9}day": result.releaseDate = result.releaseDate ?? texts().first
        case "\u{A9}gen": result.userGenre = result.userGenre ?? texts().first
        case "\u{A9}lyr": result.lyrics = result.lyrics ?? texts().first
        case "gnre":
            let payload = firstPayload()
            if (1...2).contains(payload.count) {
                result.predefinedGenreCode = result.predefinedGenreCode
                    ?? payload.reduce(0) { ($0 << 8) | Int($1) }
            }
        case "trkn": result.trackNumber = result.trackNumber ?? indexPair()
        case "disk": result.discNumber = result.discNumber ?? indexPair()
        case "covr":
            let payload = firstPayload()
            if result.coverArtData == nil, !payload.isEmpty { result.coverArtData = payload }
        default:
            break
        }
    }

    /// 与 `ISOBaseMediaLyricsParser` 同一套解码: 标成 UTF-8 的 GB18030/Big5 等也能还原。
    private static func decodeText(_ data: Data, declaredType: UInt32) -> String? {
        guard !data.isEmpty else { return nil }
        let isUTF16 = [2, 5].contains(declaredType)
            || (data.count >= 2 && ((data[data.startIndex] == 0xFE && data[data.startIndex + 1] == 0xFF)
                || (data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xFE)))
        let decoded: String?
        if isUTF16 {
            decoded = TextEncodingRepair.bestDecoding(of: data, encodings: [.utf16, .utf16BigEndian, .utf16LittleEndian])
        } else if [0, 1, 3, 4].contains(declaredType) {
            decoded = TextEncodingRepair.bestDecoding(of: data, encodings: TextEncodingRepair.legacyTextEncodings)
        } else {
            return nil
        }
        guard let decoded else { return nil }
        let normalized = decoded.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0\u{FEFF}"))
        )
        guard !normalized.isEmpty else { return nil }
        return TextEncodingRepair.repaired(normalized) ?? normalized
    }

    // MARK: Atoms

    private struct Atom {
        let type: String
        let payload: Range<Int>
    }

    /// 相对 `data` 的偏移(与 `data.startIndex` 无关)。
    private static func atoms(in data: Data, range: Range<Int>) -> [Atom] {
        var result: [Atom] = []
        var cursor = range.lowerBound
        while let child = atom(in: data, startingAt: cursor, limit: range.upperBound) {
            result.append(child)
            cursor = child.payload.upperBound
        }
        return result
    }

    private static func atom(in data: Data, startingAt start: Int, limit: Int) -> Atom? {
        guard start >= 0, start <= limit - 8, limit <= data.count,
              let size32 = uint32BE(data, at: start),
              let type = fourCC(data, at: start + 4) else { return nil }
        let headerLength: Int
        let totalLength: UInt64
        switch size32 {
        case 0:
            headerLength = 8
            totalLength = UInt64(limit - start)
        case 1:
            guard start <= limit - 16, let extended = uint64BE(data, at: start + 8) else { return nil }
            headerLength = 16
            totalLength = extended
        default:
            headerLength = 8
            totalLength = UInt64(size32)
        }
        guard totalLength >= UInt64(headerLength), totalLength <= UInt64(limit - start) else { return nil }
        return Atom(type: type, payload: (start + headerLength)..<(start + Int(totalLength)))
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let start = data.startIndex + offset
        return String(data: data[start..<(start + 4)], encoding: .isoLatin1)
    }

    private static func byte(_ data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    private static func uint16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    private static func uint32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func uint64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for index in base..<(base + 8) { value = (value << 8) | UInt64(data[index]) }
        return value
    }
}
