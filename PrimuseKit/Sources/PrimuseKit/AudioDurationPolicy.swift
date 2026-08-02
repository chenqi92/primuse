import Foundation

/// Shared rules for provisional scan durations and authoritative decoder
/// corrections. Remote scanners do not always have a seekable file, while a
/// decoder that required a complete local file has already seen the full
/// payload and must be trusted over a size-based estimate.
public enum AudioDurationPolicy {
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


/// Builds a small, structurally valid ISO Base Media metadata file from
/// bounded head and tail ranges. A trailing `moov` cannot be parsed reliably
/// by concatenating arbitrary head/tail bytes because that leaves a partial
/// `mdat` atom between them. Keeping only `ftyp` and a complete `moov` gives
/// AVFoundation the container description it needs without materializing the
/// remote media payload.
public enum ISOBaseMediaMetadataSliceBuilder {
    public static func makeMetadataFile(head: Data, tail: Data) -> Data? {
        guard let ftyp = completeAtom(named: "ftyp", in: head),
              let moov = completeAtom(named: "moov", in: tail, requiredChild: "mvhd") else {
            return nil
        }
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
    public static let initialHeadByteCount = 256 * 1024
    public static let maximumHeadByteCount = 4 * 1024 * 1024
    public static let mp3FrameProbeByteCount = 64 * 1024
    public static let initialContainerTailByteCount = 256 * 1024
    public static let defaultMP3BitRateKbps = 192

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
