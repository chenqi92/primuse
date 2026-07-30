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
            requested = max(requested, declaredID3ByteCount)
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
        providedByteCount: Int
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
        let estimated = Double(fileSize) / (Double(effectiveBitRate) * 125.0)
        guard estimated.isFinite,
              estimated > 0,
              !parsed.isFinite || parsed <= 0 || parsed < estimated * 0.5 else {
            return parsed
        }
        return estimated
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
