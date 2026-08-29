import Foundation

/// What a successful metadata inspection actually recovered. Technical media
/// properties are deliberately separate from descriptive tags so a playable
/// file is never reported as though it contained an embedded title or artist.
public enum MetadataReadCompletionKind: String, Codable, CaseIterable, Sendable {
    case embeddedTags
    case sidecarMetadata
    case filenameInference
    case technicalProperties
    case verifiedNoMetadata
}

/// A conservative signature from the bytes that were actually read. The file
/// extension remains a hint, but a verified signature may select a more
/// appropriate metadata parser for mislabeled remote files.
public enum AudioFileSignatureKind: String, Codable, CaseIterable, Sendable {
    case unknown
    case mpegAudio
    case adtsAAC
    case adifAAC
    case flac
    case ogg
    case isoBaseMedia
    case riffWave
    case dtsInWave
    case aiff
    case asf
    case monkeyAudio
    case wavPack
    case musepack
    case trueAudio
    case tak
    case dsf
    case dff
    case dts
    case ac3
    case eac3
    case mlp
    case trueHD
    case amr
    case atrac
    case shorten
    case au
    case caf
    case qoa

    public var parserFileExtension: String? {
        switch self {
        case .unknown: nil
        case .mpegAudio: "mp3"
        case .adtsAAC, .adifAAC: "aac"
        case .flac: "flac"
        case .ogg: "ogg"
        case .isoBaseMedia: "m4a"
        case .riffWave, .dtsInWave: "wav"
        case .aiff: "aiff"
        case .asf: "wma"
        case .monkeyAudio: "ape"
        case .wavPack: "wv"
        case .musepack: "mpc"
        case .trueAudio: "tta"
        case .tak: "tak"
        case .dsf: "dsf"
        case .dff: "dff"
        case .dts: "dts"
        case .ac3: "ac3"
        case .eac3: "eac3"
        case .mlp: "mlp"
        case .trueHD: "truehd"
        case .amr: "amr"
        case .atrac: "atrac"
        case .shorten: "shn"
        case .au: "au"
        case .caf: "caf"
        case .qoa: "qoa"
        }
    }
}

public enum RemoteMetadataTailStrategy: String, Codable, CaseIterable, Sendable {
    case none
    case isoBaseMedia
    case mp3ID3
    case apeV2
    case dsfOffset
    case containerID3
    /// Explicit rereads inspect a structurally validated ID3v1, ID3v2 or
    /// APEv2 footer even for tag-poor elementary streams.
    case genericEOF
}

public enum AudioFileSignaturePolicy {
    private static let asfHeader = Data([
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
        0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
    ])
    private static let dtsSyncPatterns: [[UInt8]] = [
        [0x7F, 0xFE, 0x80, 0x01],
        [0xFE, 0x7F, 0x01, 0x80],
        [0x1F, 0xFF, 0xE8, 0x00],
        [0xFF, 0x1F, 0x00, 0xE8],
    ]

    public static func inspect(_ data: Data) -> AudioFileSignatureKind {
        guard !data.isEmpty else { return .unknown }
        let start = leadingAudioOffset(in: data)
        guard start < data.count else { return .unknown }
        let bytes = Data(data[start...])

        if bytes.starts(with: Data("fLaC".utf8)) { return .flac }
        if bytes.starts(with: Data("OggS".utf8)) { return .ogg }
        if bytes.starts(with: Data("DSD ".utf8)) { return .dsf }
        if bytes.starts(with: Data("FRM8".utf8)) { return .dff }
        if bytes.starts(with: Data("MAC ".utf8)) { return .monkeyAudio }
        if bytes.starts(with: Data("wvpk".utf8)) { return .wavPack }
        if bytes.starts(with: Data("MPCK".utf8))
            || bytes.starts(with: Data("MP+".utf8)) { return .musepack }
        if bytes.starts(with: Data("TTA1".utf8)) { return .trueAudio }
        if bytes.starts(with: Data("tBaK".utf8)) { return .tak }
        if bytes.starts(with: Data("ajkg".utf8)) { return .shorten }
        if bytes.starts(with: Data(".snd".utf8)) { return .au }
        if bytes.starts(with: Data("caff".utf8)) { return .caf }
        if bytes.starts(with: Data("qoaf".utf8)) { return .qoa }
        if bytes.starts(with: Data("#!AMR".utf8)) { return .amr }
        if bytes.starts(with: Data("ADIF".utf8)) { return .adifAAC }
        if isOMAHeader(bytes) { return .atrac }
        if let mlpFamily = mlpFamilySignature(in: bytes) { return mlpFamily }
        if bytes.count >= asfHeader.count,
           bytes.prefix(asfHeader.count).elementsEqual(asfHeader) { return .asf }

        if bytes.count >= 12,
           bytes.prefix(4).elementsEqual(Data("RIFF".utf8)),
           bytes[8..<12].elementsEqual(Data("WAVE".utf8)) {
            return containsDTSSync(bytes) ? .dtsInWave : .riffWave
        }
        if bytes.count >= 12,
           bytes.prefix(4).elementsEqual(Data("FORM".utf8)),
           (bytes[8..<12].elementsEqual(Data("AIFF".utf8))
                || bytes[8..<12].elementsEqual(Data("AIFC".utf8))) {
            return .aiff
        }
        if bytes.count >= 12,
           bytes[4..<8].elementsEqual(Data("ftyp".utf8)) { return .isoBaseMedia }
        if startsWithDTSSync(bytes) { return .dts }
        if bytes.count >= 6, bytes[0] == 0x0B, bytes[1] == 0x77 {
            let bitstreamID = (bytes[5] >> 3) & 0x1F
            return bitstreamID > 10 ? .eac3 : .ac3
        }
        if bytes.count >= 2,
           bytes[0] == 0xFF,
           (bytes[1] & 0xF6) == 0xF0 { return .adtsAAC }
        if containsMPEGFrameSequence(bytes) { return .mpegAudio }
        return .unknown
    }

    private static func leadingAudioOffset(in data: Data) -> Int {
        if let byteCount = EmbeddedTagMetadataParser.id3TagByteCount(in: data) {
            return min(byteCount, data.count)
        }
        guard data.count >= 10,
              data[0..<3].elementsEqual(Data("ea3".utf8)),
              data[3] != 0xFF,
              data[4] != 0xFF,
              data[6...9].allSatisfy({ ($0 & 0x80) == 0 }) else { return 0 }
        let payloadByteCount = (Int(data[6]) << 21)
            | (Int(data[7]) << 14)
            | (Int(data[8]) << 7)
            | Int(data[9])
        let footerByteCount = (data[5] & 0x10) != 0 ? 10 : 0
        return min(10 + payloadByteCount + footerByteCount, data.count)
    }

    private static func isOMAHeader(_ data: Data) -> Bool {
        data.count >= 6
            && data[0..<3].elementsEqual(Data("EA3".utf8))
            && data[4] == 0
            && data[5] == 96
    }

    private static func mlpFamilySignature(in data: Data) -> AudioFileSignatureKind? {
        guard data.count >= 32 else { return nil }
        let accessUnitWords = ((Int(data[0]) << 8) | Int(data[1])) & 0x0FFF
        let accessUnitByteCount = accessUnitWords * 2
        guard accessUnitByteCount >= 32, accessUnitByteCount <= data.count else { return nil }
        let sync = data[4..<8]
        if sync.elementsEqual(Data([0xF8, 0x72, 0x6F, 0xBA])) { return .trueHD }
        if sync.elementsEqual(Data([0xF8, 0x72, 0x6F, 0xBB])) { return .mlp }
        return nil
    }

    private struct MPEGFrameHeader {
        let versionBits: Int
        let sampleRate: Int
        let byteCount: Int
    }

    private static func containsMPEGFrameSequence(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let finalOffset = min(data.count - 4, 4 * 1024)
        for offset in 0...finalOffset {
            guard let first = mpegFrameHeader(in: data, at: offset) else { continue }
            let nextOffset = offset + first.byteCount
            guard let second = mpegFrameHeader(in: data, at: nextOffset),
                  second.versionBits == first.versionBits,
                  second.sampleRate == first.sampleRate else { continue }
            return true
        }
        return false
    }

    private static func mpegFrameHeader(in data: Data, at offset: Int) -> MPEGFrameHeader? {
        guard offset >= 0, offset <= data.count - 4,
              data[offset] == 0xFF,
              (data[offset + 1] & 0xE0) == 0xE0 else { return nil }

        let second = data[offset + 1]
        let third = data[offset + 2]
        let versionBits = Int((second >> 3) & 0x03)
        let layerBits = Int((second >> 1) & 0x03)
        let bitRateIndex = Int((third >> 4) & 0x0F)
        let sampleRateIndex = Int((third >> 2) & 0x03)
        guard versionBits != 1,
              layerBits == 1,
              (1...14).contains(bitRateIndex),
              sampleRateIndex < 3 else { return nil }

        let bitRates = versionBits == 3
            ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let baseSampleRate = [44_100, 48_000, 32_000][sampleRateIndex]
        let sampleRate = switch versionBits {
        case 3: baseSampleRate
        case 2: baseSampleRate / 2
        case 0: baseSampleRate / 4
        default: 0
        }
        guard sampleRate > 0 else { return nil }
        let coefficient = versionBits == 3 ? 144 : 72
        let byteCount = coefficient * bitRates[bitRateIndex - 1] * 1_000 / sampleRate
            + Int((third >> 1) & 0x01)
        guard byteCount >= 4 else { return nil }
        return MPEGFrameHeader(
            versionBits: versionBits,
            sampleRate: sampleRate,
            byteCount: byteCount
        )
    }

    private static func containsDTSSync(_ data: Data) -> Bool {
        let limit = min(data.count, 64 * 1024)
        guard limit >= 4 else { return false }
        for offset in 0...(limit - 4) {
            for pattern in dtsSyncPatterns
            where data[offset..<(offset + 4)].elementsEqual(pattern) {
                return true
            }
        }
        return false
    }

    private static func startsWithDTSSync(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return dtsSyncPatterns.contains {
            data.prefix(4).elementsEqual($0)
        }
    }
}

public enum RemoteMetadataInspectionPolicy {
    private static let isoBaseMediaExtensions: Set<String> = [
        "m4a", "m4b", "mp4", "m4v", "mov", "alac",
    ]
    private static let apeExtensions: Set<String> = [
        "ape", "wv", "mpc", "mpp", "tta", "tak",
    ]
    private static let containerID3Extensions: Set<String> = [
        "dff", "aiff", "aif", "wav", "wave",
    ]

    public static func parserFileExtension(
        declaredFileExtension: String,
        signature: AudioFileSignatureKind
    ) -> String {
        signature.parserFileExtension ?? normalized(declaredFileExtension)
    }

    public static func tailStrategy(
        fileExtension: String,
        isExplicitReread: Bool
    ) -> RemoteMetadataTailStrategy {
        let ext = normalized(fileExtension)
        if isoBaseMediaExtensions.contains(ext) { return .isoBaseMedia }
        if ext == "mp3" { return .mp3ID3 }
        if apeExtensions.contains(ext) { return .apeV2 }
        if ext == "dsf" { return .dsfOffset }
        if containerID3Extensions.contains(ext) { return .containerID3 }
        return isExplicitReread ? .genericEOF : .none
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
    }
}

/// Gates filename-derived identity and the "verified no metadata" result on
/// objective evidence that the bytes are an audio file. A readable error page
/// or cloud placeholder must never become a successful filename inference.
public enum MetadataReadEvidencePolicy {
    public static func hasVerifiedAudioFile(
        signature: AudioFileSignatureKind,
        hasTechnicalProperties: Bool
    ) -> Bool {
        signature != .unknown || hasTechnicalProperties
    }

    /// A complete read must prove that the media bytes are audio. Sidecar
    /// artwork or lyrics are deliberately excluded because they describe the
    /// library item without making an empty or placeholder media object
    /// playable.
    public static func completeReadIsUnrecognizedAudio(
        providedByteCount: Int,
        expectedFileByteCount: Int64,
        hasCompleteFileAccess: Bool,
        signature: AudioFileSignatureKind,
        hasTechnicalProperties: Bool
    ) -> Bool {
        let coveredExpectedFile = expectedFileByteCount > 0
            && Int64(providedByteCount) >= expectedFileByteCount
        guard hasCompleteFileAccess || coveredExpectedFile else { return false }
        return !hasVerifiedAudioFile(
            signature: signature,
            hasTechnicalProperties: hasTechnicalProperties
        )
    }
}

public enum MetadataResolvedTextSource: String, Codable, Sendable {
    case existing
    case embedded
    case filenameInference
    case cueSheet
    case userEdit
}

public struct MetadataResolvedText: Equatable, Sendable {
    public let value: String?
    public let source: MetadataResolvedTextSource

    public init(value: String?, source: MetadataResolvedTextSource) {
        self.value = value
        self.source = source
    }
}

/// Resolves one identity field without allowing a filename guess to replace a
/// reliable source value. Legacy rows are considered filename-derived only
/// when they equal the raw stem, equal the same conservative inference, or are
/// visibly damaged text.
public enum MetadataIdentityFallbackPolicy {
    public static func resolve(
        existing: String?,
        embedded: String?,
        filenameInference: String?,
        rawFileStem: String?,
        isCueTrack: Bool,
        userEdited: Bool
    ) -> MetadataResolvedText {
        if userEdited {
            return MetadataResolvedText(value: normalized(existing), source: .userEdit)
        }
        if isCueTrack {
            return MetadataResolvedText(value: normalized(existing), source: .cueSheet)
        }

        if let embedded = trustworthy(embedded) {
            return MetadataResolvedText(value: embedded, source: .embedded)
        }

        let current = normalized(existing)
        let inferred = trustworthy(filenameInference)
        let stem = normalized(rawFileStem)
        let currentLooksFilenameDerived = current == nil
            || equivalent(current, inferred)
            || equivalent(current, stem)
            || MediaMetadataTextRepair.isSuspicious(current)

        if currentLooksFilenameDerived, let inferred {
            return MetadataResolvedText(value: inferred, source: .filenameInference)
        }
        return MetadataResolvedText(value: current, source: .existing)
    }

    private static func trustworthy(_ value: String?) -> String? {
        guard let repaired = MediaMetadataTextRepair.repaired(value),
              !MediaMetadataTextRepair.isSuspicious(repaired) else { return nil }
        return normalized(repaired)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func equivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return false }
        return lhs.compare(
            rhs,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) == .orderedSame
    }
}
