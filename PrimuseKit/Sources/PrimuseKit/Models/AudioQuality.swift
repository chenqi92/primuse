import Foundation

/// 单首歌的音质等级 — 给 UI 显示 badge 用。从 Song 的 fileFormat /
/// sampleRate / bitDepth 推导, 不入库。
public enum AudioQuality: String, Sendable, CaseIterable {
    case dsd
    case hiRes
    case lossless
    case standard

    public var displayName: String {
        switch self {
        case .dsd: return "DSD"
        case .hiRes: return "Hi-Res"
        case .lossless: return "Lossless"
        case .standard: return "Standard"
        }
    }

    /// SF Symbol name 给 badge 用。
    public var symbolName: String {
        switch self {
        case .dsd: return "waveform.badge.exclamationmark"
        case .hiRes: return "waveform.badge.plus"
        case .lossless: return "waveform"
        case .standard: return "waveform.path"
        }
    }
}

extension Song {
    /// 音质等级。判定规则:
    /// - DSF / DFF 文件 → .dsd
    /// - lossless format + (sampleRate >= 88.2k 或 bitDepth >= 24) → .hiRes
    /// - 其他 lossless → .lossless
    /// - 有损 (MP3/AAC/Opus 等) → .standard
    public var audioQuality: AudioQuality {
        if fileFormat == .dsf || fileFormat == .dff {
            return .dsd
        }
        guard fileFormat.isLossless else {
            return .standard
        }
        let highSR = (sampleRate ?? 0) >= 88_200
        let highBD = (bitDepth ?? 0) >= 24
        if highSR || highBD {
            return .hiRes
        }
        return .lossless
    }

    /// 采样率的用户可读形式，例如 `44.1 kHz`。
    public var formattedSampleRate: String? {
        guard let sampleRate, sampleRate > 0 else { return nil }
        if sampleRate >= 1_000 {
            let khz = Double(sampleRate) / 1_000
            return String(format: khz.rounded() == khz ? "%.0f kHz" : "%.1f kHz", khz)
        }
        return "\(sampleRate) Hz"
    }

    /// 位深的用户可读形式，例如 `24 bit`。
    public var formattedBitDepth: String? {
        guard let bitDepth, bitDepth > 0 else { return nil }
        return "\(bitDepth) bit"
    }

    /// Song.bitRate 的单位是 kbps，不要再次除以 1000。
    public var formattedBitRate: String? {
        guard let bitRate, bitRate > 0 else { return nil }
        return "\(bitRate.formatted()) kbps"
    }

    /// "96 kHz / 24 bit" 这种规格描述, NowPlaying 详情用。两者都缺返回 nil。
    public var qualitySpecText: String? {
        let parts = [formattedSampleRate, formattedBitDepth].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
}
