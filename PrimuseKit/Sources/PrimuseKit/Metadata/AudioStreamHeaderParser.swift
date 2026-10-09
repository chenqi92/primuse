import Foundation

/// 文件头里写着的音轨编码与规格。只填文件头里真有的值。
public struct AudioStreamHeaderInfo: Equatable, Sendable {
    public var codec: AudioFormat?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channelCount: Int?

    public init(codec: AudioFormat? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil, channelCount: Int? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
    }
}

/// 从文件开头的字节读出容器里装的是什么编码。AVFoundation 打不开 WMA、WavPack、
/// Matroska,而这几种容器装的东西有损无损都有:WMA 可能是 WMA Lossless,WavPack 可能是
/// 混合(有损)模式,MKA 里可能是 FLAC 也可能是 Opus。CAF 也在这里读,省得只靠 AVFoundation。
public enum AudioStreamHeaderParser {
    public static func parse(_ data: Data, container: AudioFormat) -> AudioStreamHeaderInfo? {
        let bytes = [UInt8](data.prefix(maximumInspectedByteCount))
        switch container {
        case .wma: return parseASF(bytes)
        case .wv: return parseWavPack(bytes)
        case .caf: return parseCAF(bytes)
        case .mka, .webm: return parseMatroska(bytes)
        default: return nil
        }
    }

    /// 编码信息都在文件最前面;多给的字节不看。
    static let maximumInspectedByteCount = 4 * 1024 * 1024

    // MARK: - ASF (WMA)

    private static let asfHeaderGUID: [UInt8] = [
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
    ]
    private static let asfStreamPropertiesGUID: [UInt8] = [
        0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
    ]
    private static let asfAudioMediaGUID: [UInt8] = [
        0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B,
    ]

    /// 头对象里第一条音频流的 WAVEFORMATEX。
    static func parseASF(_ b: [UInt8]) -> AudioStreamHeaderInfo? {
        guard b.count >= 30, Array(b[0..<16]) == asfHeaderGUID else { return nil }
        let headerEnd = min(b.count, Int(clamping: readUInt64LE(b, 16) ?? 0))
        var cursor = 30
        while cursor + 24 <= headerEnd {
            guard let size = readUInt64LE(b, cursor + 16), size >= 24 else { return nil }
            let objectEnd = cursor + Int(clamping: size)
            if Array(b[cursor..<(cursor + 16)]) == asfStreamPropertiesGUID {
                let payload = cursor + 24
                if payload + 54 + 16 <= min(objectEnd, b.count),
                   Array(b[payload..<(payload + 16)]) == asfAudioMediaGUID {
                    return waveFormat(b, at: payload + 54)
                }
            }
            guard objectEnd > cursor else { return nil }
            cursor = objectEnd
        }
        return nil
    }

    private static func waveFormat(_ b: [UInt8], at offset: Int) -> AudioStreamHeaderInfo? {
        guard let tag = readUInt16LE(b, offset),
              let channels = readUInt16LE(b, offset + 2),
              let sampleRate = readUInt32LE(b, offset + 4),
              let bits = readUInt16LE(b, offset + 14) else { return nil }
        let codec: AudioFormat?
        switch tag {
        case 0x0163: codec = .wmaLossless
        case 0x000A, 0x0160, 0x0161, 0x0162: codec = .wma
        case 0x0001: codec = .pcm
        case 0x0055: codec = .mp3
        default: codec = nil
        }
        let isLossless = codec?.isLossless == true
        return AudioStreamHeaderInfo(
            codec: codec,
            sampleRate: sampleRate > 0 ? Int(sampleRate) : nil,
            bitDepth: isLossless && bits > 0 ? Int(bits) : nil,
            channelCount: channels > 0 ? Int(channels) : nil
        )
    }

    // MARK: - WavPack

    private static let wavPackSampleRates = [
        6_000, 8_000, 9_600, 11_025, 12_000, 16_000, 22_050, 24_000,
        32_000, 44_100, 48_000, 64_000, 88_200, 96_000, 192_000,
    ]

    /// 第一个带音频的块头。混合模式(HYBRID_FLAG)只存有损部分,另配的 `.wvc`
    /// 校正文件 Primuse 播放时用不上,所以按有损算。
    static func parseWavPack(_ b: [UInt8]) -> AudioStreamHeaderInfo? {
        var cursor = 0
        let limit = min(b.count, 1024 * 1024)
        while cursor + 32 <= limit {
            guard b[cursor] == 0x77, b[cursor + 1] == 0x76, b[cursor + 2] == 0x70, b[cursor + 3] == 0x6B,
                  let blockSize = readUInt32LE(b, cursor + 4),
                  let version = readUInt16LE(b, cursor + 8),
                  (0x402...0x410).contains(version),
                  let blockSamples = readUInt32LE(b, cursor + 20),
                  let flags = readUInt32LE(b, cursor + 24) else {
                cursor += 1
                continue
            }
            guard blockSamples > 0 else {
                cursor += 8 + Int(blockSize)
                continue
            }
            let isDSD = flags & 0x8000_0000 != 0
            let isHybrid = flags & 0x8 != 0
            let isFloat = flags & 0x80 != 0
            let rateIndex = Int((flags >> 23) & 0xF)
            let bytesStored = Int(flags & 0x3) + 1
            let shift = Int((flags >> 13) & 0x1F)
            let bits = isFloat ? 32 : bytesStored * 8 - shift
            return AudioStreamHeaderInfo(
                codec: isHybrid && !isDSD ? .wavpackHybrid : .wv,
                sampleRate: !isDSD && rateIndex < wavPackSampleRates.count ? wavPackSampleRates[rateIndex] : nil,
                bitDepth: isHybrid || isDSD || bits <= 0 ? nil : bits,
                channelCount: flags & 0x4 != 0 ? 1 : nil
            )
        }
        return nil
    }

    // MARK: - CAF

    /// CAF 规定 `desc` 必须是第一个块。
    static func parseCAF(_ b: [UInt8]) -> AudioStreamHeaderInfo? {
        guard b.count >= 8 + 12 + 32,
              b[0] == 0x63, b[1] == 0x61, b[2] == 0x66, b[3] == 0x66,
              b[8] == 0x64, b[9] == 0x65, b[10] == 0x73, b[11] == 0x63,
              let rateBits = readUInt64BE(b, 20),
              let formatID = readUInt32BE(b, 28),
              let formatFlags = readUInt32BE(b, 32),
              let channels = readUInt32BE(b, 44),
              let bitsPerChannel = readUInt32BE(b, 48) else { return nil }
        let sampleRate = Double(bitPattern: rateBits)
        let codec = ContainerAudioCodecPolicy.codec(coreAudioFormatID: formatID)
        let bitDepth: Int? = if formatID == ContainerAudioCodecPolicy.fourCC("lpcm") {
            bitsPerChannel > 0 ? Int(bitsPerChannel) : nil
        } else {
            AppleMusicLocalFileDetailsPolicy.bitDepth(
                codecID: formatID, bitsPerChannel: bitsPerChannel, formatFlags: formatFlags
            )
        }
        return AudioStreamHeaderInfo(
            codec: codec,
            sampleRate: sampleRate.isFinite && sampleRate >= 1 ? Int(sampleRate.rounded()) : nil,
            bitDepth: bitDepth,
            channelCount: channels > 0 ? Int(channels) : nil
        )
    }

    // MARK: - Matroska / WebM

    private enum EBML {
        static let header: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let tracks: UInt32 = 0x1654_AE6B
        static let cluster: UInt32 = 0x1F43_B675
        static let trackEntry: UInt32 = 0xAE
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let bitDepth: UInt32 = 0x6264
    }

    private struct EBMLElement {
        let id: UInt32
        let payload: Range<Int>
    }

    /// 第一条音轨(TrackType 2)的 CodecID 与采样率、位深。读到 Cluster 就停:轨道表在它前面。
    static func parseMatroska(_ b: [UInt8]) -> AudioStreamHeaderInfo? {
        guard let first = element(b, at: 0), first.id == EBML.header else { return nil }
        var cursor = first.payload.upperBound
        while let segment = element(b, at: cursor) {
            if segment.id == EBML.segment {
                var inner = segment.payload.lowerBound
                while inner < segment.payload.upperBound, let child = element(b, at: inner) {
                    if child.id == EBML.cluster { return nil }
                    if child.id == EBML.tracks {
                        return audioTrack(b, in: child.payload)
                    }
                    guard child.payload.upperBound > inner else { return nil }
                    inner = child.payload.upperBound
                }
                return nil
            }
            guard segment.payload.upperBound > cursor else { return nil }
            cursor = segment.payload.upperBound
        }
        return nil
    }

    private static func audioTrack(_ b: [UInt8], in range: Range<Int>) -> AudioStreamHeaderInfo? {
        var cursor = range.lowerBound
        while cursor < range.upperBound, let entry = element(b, at: cursor) {
            if entry.id == EBML.trackEntry {
                var type: UInt64?
                var codecID: String?
                var info = AudioStreamHeaderInfo()
                var inner = entry.payload.lowerBound
                while inner < entry.payload.upperBound, let field = element(b, at: inner) {
                    switch field.id {
                    case EBML.trackType: type = unsigned(b, field.payload)
                    case EBML.codecID: codecID = string(b, field.payload)
                    case EBML.audio:
                        var audioCursor = field.payload.lowerBound
                        while audioCursor < field.payload.upperBound, let value = element(b, at: audioCursor) {
                            switch value.id {
                            case EBML.samplingFrequency:
                                if let rate = float(b, value.payload), rate.isFinite, rate >= 1 {
                                    info.sampleRate = Int(rate.rounded())
                                }
                            case EBML.channels: info.channelCount = unsigned(b, value.payload).map(Int.init)
                            case EBML.bitDepth: info.bitDepth = unsigned(b, value.payload).map(Int.init)
                            default: break
                            }
                            guard value.payload.upperBound > audioCursor else { break }
                            audioCursor = value.payload.upperBound
                        }
                    default: break
                    }
                    guard field.payload.upperBound > inner else { break }
                    inner = field.payload.upperBound
                }
                if type == 2 {
                    info.codec = codecID.flatMap(matroskaCodec)
                    if info.codec?.isLossless != true { info.bitDepth = nil }
                    return info
                }
            }
            guard entry.payload.upperBound > cursor else { return nil }
            cursor = entry.payload.upperBound
        }
        return nil
    }

    static func matroskaCodec(_ codecID: String) -> AudioFormat? {
        let id = codecID.uppercased()
        if id.hasPrefix("A_AAC") { return .aac }
        if id.hasPrefix("A_DTS") { return .dts }
        if id.hasPrefix("A_PCM/") { return .pcm }
        switch id {
        case "A_FLAC": return .flac
        case "A_OPUS": return .opus
        case "A_VORBIS": return .ogg
        case "A_MPEG/L3": return .mp3
        case "A_MPEG/L2", "A_MPEG/L1": return .mp2
        case "A_AC3": return .ac3
        case "A_EAC3": return .eac3
        case "A_TRUEHD": return .truehd
        case "A_MLP": return .mlp
        case "A_ALAC": return .alac
        case "A_WAVPACK4": return .wv
        case "A_TTA1": return .tta
        default: return nil
        }
    }

    /// 一个 EBML 元素:ID 保留长度标记位,大小去掉标记位;大小全 1 表示「未知」,
    /// 当作一直延续到数据末尾。负载超出手里的字节时截到末尾,上层照样能读前面的子元素。
    private static func element(_ b: [UInt8], at offset: Int) -> EBMLElement? {
        guard offset < b.count else { return nil }
        let first = b[offset]
        guard first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4, offset + idLength < b.count else { return nil }
        var id: UInt32 = 0
        for index in 0..<idLength { id = (id << 8) | UInt32(b[offset + index]) }

        let sizeOffset = offset + idLength
        let sizeFirst = b[sizeOffset]
        guard sizeFirst != 0 else { return nil }
        let sizeLength = sizeFirst.leadingZeroBitCount + 1
        guard sizeOffset + sizeLength <= b.count else { return nil }
        var size = UInt64(sizeFirst & (0xFF >> sizeLength))
        var allOnes = size == UInt64(0xFF >> sizeLength)
        for index in 1..<max(1, sizeLength) {
            let byte = b[sizeOffset + index]
            size = (size << 8) | UInt64(byte)
            allOnes = allOnes && byte == 0xFF
        }
        let start = sizeOffset + sizeLength
        let end = allOnes ? b.count : min(b.count, start + Int(clamping: size))
        guard end >= start else { return nil }
        return EBMLElement(id: id, payload: start..<end)
    }

    private static func unsigned(_ b: [UInt8], _ range: Range<Int>) -> UInt64? {
        guard !range.isEmpty, range.count <= 8 else { return nil }
        return range.reduce(UInt64(0)) { ($0 << 8) | UInt64(b[$1]) }
    }

    private static func float(_ b: [UInt8], _ range: Range<Int>) -> Double? {
        switch range.count {
        case 4: return unsigned(b, range).map { Double(Float(bitPattern: UInt32($0))) }
        case 8: return unsigned(b, range).map { Double(bitPattern: $0) }
        default: return nil
        }
    }

    private static func string(_ b: [UInt8], _ range: Range<Int>) -> String? {
        let raw = b[range].prefix { $0 != 0 }
        return String(bytes: raw, encoding: .ascii)
    }

    // MARK: - Integers

    static func readUInt16LE(_ b: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= b.count else { return nil }
        return UInt16(b[offset]) | UInt16(b[offset + 1]) << 8
    }

    static func readUInt32LE(_ b: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= b.count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[offset + $1]) << (8 * $1) }
    }

    static func readUInt64LE(_ b: [UInt8], _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= b.count else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[offset + $1]) << (8 * $1) }
    }

    static func readUInt32BE(_ b: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= b.count else { return nil }
        return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(b[offset + $1]) }
    }

    static func readUInt64BE(_ b: [UInt8], _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= b.count else { return nil }
        return (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(b[offset + $1]) }
    }
}

// MARK: - FLAC 实际位深

/// 24 bit 的 FLAC 有不少是 16 bit 补零出来的。FLAC 编码器会把每个子帧里样本共同的
/// 末尾零位记成 wasted bits,读几帧子帧头就知道实际用了几位,不用解码。
public enum FLACEffectiveBitDepthParser {
    public enum AudioOffset: Equatable, Sendable {
        /// 第一个音频帧的位置。
        case offset(Int)
        /// 元数据块链还没走完,要先拿到这个位置的 4 字节块头。
        case needsHeader(at: Int)
        case invalid
    }

    /// 走完元数据块链得出音频从哪开始。`header` 返回某个绝对位置的 4 个字节,拿不到时 nil。
    /// 开头的 ID3v2 会跳过。
    public static func audioOffset(header: (Int) -> [UInt8]?) -> AudioOffset {
        guard let leading = header(0) else { return .needsHeader(at: 0) }
        var start = 0
        if leading[0] == 0x49, leading[1] == 0x44, leading[2] == 0x33 {
            guard let id3 = header(6) else { return .needsHeader(at: 6) }
            guard id3.allSatisfy({ $0 & 0x80 == 0 }) else { return .invalid }
            let size = id3.reduce(0) { ($0 << 7) | Int($1) }
            let hasFooter = leading[3] >= 4 && (header(5)?[0] ?? 0) & 0x10 != 0
            start = 10 + size + (hasFooter ? 10 : 0)
        }
        guard let signature = header(start) else { return .needsHeader(at: start) }
        guard signature == [0x66, 0x4C, 0x61, 0x43] else { return .invalid }
        var cursor = start + 4
        for _ in 0..<512 {
            guard let block = header(cursor) else { return .needsHeader(at: cursor) }
            let isLast = block[0] & 0x80 != 0
            let length = (Int(block[1]) << 16) | (Int(block[2]) << 8) | Int(block[3])
            cursor += 4 + length
            if isLast { return .offset(cursor) }
        }
        return .invalid
    }

    /// 连续数据里按块头读出的音频起点。
    public static func audioOffset(in data: Data) -> AudioOffset {
        let bytes = [UInt8](data)
        return audioOffset { offset in
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Array(bytes[offset..<(offset + 4)])
        }
    }

    public struct Result: Equatable, Sendable {
        /// 实际用到的位数。
        public let effectiveBitDepth: Int
        /// 拿来下结论的帧数。
        public let inspectedFrames: Int
    }

    /// 这首 FLAC 标的位深高于 16 bit,还没查过是不是补零。
    public static func needsInspection(format: AudioFormat, bitDepth: Int?, effectiveBitDepth: Int?) -> Bool {
        format == .flac && (bitDepth ?? 0) > 16 && effectiveBitDepth == nil
    }

    /// 读过之后存的值:查出来就存实际位深,查不出(帧不够、全是 mid/side)记成标称位深,
    /// 表示查过、不再为它重读。
    public static func inspectedBitDepth(_ found: Int?, declared: Int?) -> Int? {
        guard let declared, declared > 16 else { return found }
        return found ?? declared
    }

    /// 至少看这么多帧才下结论;真 24 bit 的帧几乎不可能整帧末位都是零,补零的每一帧都是。
    public static let minimumFrames = 6

    /// `frames` 从第一个音频帧(或它之前)开始。按帧同步码找帧,核对帧头 CRC-8,
    /// 只看第一个声道的子帧头:静音的常量子帧不算数,mid/side 帧的 mid 声道少一位、
    /// 不能当证据也跳过。帧不够时 nil。
    public static func effectiveBitDepth(frames data: Data, declaredBitDepth: Int) -> Result? {
        guard declaredBitDepth > 8 else { return nil }
        let b = [UInt8](data)
        var cursor = 0
        var minimumWasted = Int.max
        var counted = 0
        var expected: (rate: UInt8, size: UInt8)?
        while cursor + 6 <= b.count, counted < 64 {
            guard b[cursor] == 0xFF, b[cursor + 1] & 0xFE == 0xF8,
                  let frame = frameHeader(b, at: cursor) else {
                cursor += 1
                continue
            }
            if let expected, expected != (frame.rateCode, frame.sizeCode) {
                cursor += 1
                continue
            }
            expected = (frame.rateCode, frame.sizeCode)
            cursor = frame.subframeOffset + 1
            let frameBits = frame.bitsPerSample ?? declaredBitDepth
            guard frameBits == declaredBitDepth, frame.channelAssignment != 10 else { continue }
            let subframe = b[frame.subframeOffset]
            let type = (subframe >> 1) & 0x3F
            guard type != 0 else { continue }  // 常量子帧(静音)
            guard type == 1 || (8...12).contains(type) || type >= 32 else { continue }
            var wasted = 0
            if subframe & 1 != 0 {
                guard let unary = unaryLength(b, fromBit: (frame.subframeOffset + 1) * 8) else { continue }
                wasted = unary + 1
            }
            minimumWasted = min(minimumWasted, wasted)
            counted += 1
        }
        guard counted >= minimumFrames, minimumWasted < declaredBitDepth else { return nil }
        return Result(effectiveBitDepth: declaredBitDepth - minimumWasted, inspectedFrames: counted)
    }

    private struct FrameHeader {
        let rateCode: UInt8
        let sizeCode: UInt8
        let channelAssignment: UInt8
        let bitsPerSample: Int?
        /// 第一个子帧头所在字节。
        let subframeOffset: Int
    }

    private static func frameHeader(_ b: [UInt8], at start: Int) -> FrameHeader? {
        let blockCode = b[start + 2] >> 4
        let rateCode = b[start + 2] & 0x0F
        let channelAssignment = b[start + 3] >> 4
        let sizeCode = (b[start + 3] >> 1) & 0x07
        guard blockCode != 0, rateCode != 0x0F, channelAssignment <= 10,
              sizeCode != 3, b[start + 3] & 1 == 0 else { return nil }

        // UTF-8 式编码的帧号 / 样本号。
        let lead = b[start + 4]
        let numberLength: Int
        switch lead {
        case 0x00...0x7F: numberLength = 1
        case 0xC0...0xDF: numberLength = 2
        case 0xE0...0xEF: numberLength = 3
        case 0xF0...0xF7: numberLength = 4
        case 0xF8...0xFB: numberLength = 5
        case 0xFC...0xFD: numberLength = 6
        case 0xFE: numberLength = 7
        default: return nil
        }
        var cursor = start + 4 + numberLength
        guard cursor <= b.count else { return nil }
        for index in 1..<numberLength where b[start + 4 + index] & 0xC0 != 0x80 { return nil }
        if blockCode == 6 { cursor += 1 } else if blockCode == 7 { cursor += 2 }
        if rateCode == 12 { cursor += 1 } else if rateCode == 13 || rateCode == 14 { cursor += 2 }
        guard cursor + 1 < b.count, crc8(b, start..<cursor) == b[cursor] else { return nil }

        let bits: Int? = switch sizeCode {
        case 1: 8
        case 2: 12
        case 4: 16
        case 5: 20
        case 6: 24
        case 7: 32
        default: nil
        }
        guard b[cursor + 1] & 0x80 == 0 else { return nil }
        return FrameHeader(
            rateCode: rateCode,
            sizeCode: sizeCode,
            channelAssignment: channelAssignment,
            bitsPerSample: bits,
            subframeOffset: cursor + 1
        )
    }

    /// 从某一位开始数连续的 0,直到遇到 1。
    private static func unaryLength(_ b: [UInt8], fromBit start: Int) -> Int? {
        var bit = start
        var zeros = 0
        while bit / 8 < b.count, zeros <= 32 {
            if b[bit / 8] & (0x80 >> UInt8(bit % 8)) != 0 { return zeros }
            zeros += 1
            bit += 1
        }
        return nil
    }

    private static func crc8(_ b: [UInt8], _ range: Range<Int>) -> UInt8 {
        var crc: UInt8 = 0
        for index in range {
            crc ^= b[index]
            for _ in 0..<8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }
}
