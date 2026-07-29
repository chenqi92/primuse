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
