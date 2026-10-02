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
        case .lossless: return PMString("audio.quality.lossless")
        case .standard: return PMString("audio.quality.standard")
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

/// 播放信息里的采样率:源与实际输出不同(被重采样)时写成「44.1 → 48 kHz」,一样就只写一个值。
public enum OutputSampleRateTextPolicy {
    /// - Parameters:
    ///   - sourceSampleRate: 歌曲的采样率(Hz),不知道时为 nil / 0。
    ///   - outputSampleRate: 当前输出设备的采样率(Hz),拿不到时为 nil / 0。
    public static func text(sourceSampleRate: Int?, outputSampleRate: Double?) -> String? {
        guard let sourceSampleRate, sourceSampleRate > 0 else { return nil }
        let source = Double(sourceSampleRate)
        guard let output = outputSampleRate, output > 0, abs(output - source) >= 1 else {
            return "\(kilohertz(source)) kHz"
        }
        return "\(kilohertz(source)) → \(kilohertz(output)) kHz"
    }

    /// 44100 → "44.1",48000 → "48",88200 → "88.2"。
    static func kilohertz(_ hertz: Double) -> String {
        let khz = hertz / 1_000
        let rounded = (khz * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

/// 播放页标题下那行音频信息的显示档位(设置里的三档)。
public enum NowPlayingAudioInfoMode: String, CaseIterable, Sendable {
    case off
    /// 只给无损、高解析、DSD 显示;有损的歌不占这一行。
    case nonStandardOnly
    case always

    /// 这首歌要不要显示那一行。
    public func showsSummary(for quality: AudioQuality) -> Bool {
        switch self {
        case .off: false
        case .nonStandardOnly: quality != .standard
        case .always: true
        }
    }

    /// 存储值读不出来(没设过、旧版本写的别的值)时退回 `fallback`。
    public static func resolved(rawValue: String?, fallback: Self) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? fallback
    }
}

/// 播放页音频信息的文字:「FLAC · 24bit/96kHz · 2304kbps」,点开后是实际输出的采样率。
public enum NowPlayingAudioInfoTextPolicy {
    /// 规格段,按「格式 · 位深/采样率 · 码率」排。缺的段直接省掉;DSD 的采样率写成
    /// DSD64 这种通行叫法,1bit 不写。
    public static func specParts(
        formatName: String,
        sampleRate: Int?,
        bitDepth: Int?,
        bitRate: Int?,
        isDSD: Bool
    ) -> [String] {
        var parts: [String] = []
        let format = formatName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !format.isEmpty, format != "—" { parts.append(format) }

        let sampleRate = sampleRate.flatMap { $0 > 0 ? $0 : nil }
        if isDSD {
            if let sampleRate, sampleRate >= 2_822_400 {
                parts.append("DSD\(Int((Double(sampleRate) / 44_100).rounded()))")
            }
        } else {
            let depth = bitDepth.flatMap { $0 > 0 ? "\($0)bit" : nil }
            let rate = sampleRate.map { "\(OutputSampleRateTextPolicy.kilohertz(Double($0)))kHz" }
            let resolution = [depth, rate].compactMap { $0 }.joined(separator: "/")
            if !resolution.isEmpty { parts.append(resolution) }
        }

        if let bitRate, bitRate > 0 { parts.append("\(bitRate)kbps") }
        return parts
    }

    public enum OutputMatch: Equatable, Sendable {
        /// 输出与源采样率一致。
        case matched
        /// 输出被重采样到别的采样率。
        case resampled
        /// 不知道源的采样率,只能报输出。
        case sourceUnknown
    }

    public struct OutputDescription: Equatable, Sendable {
        /// 「48kHz」。
        public let rateText: String
        public let match: OutputMatch
    }

    /// 实际输出的采样率与源比较的结果。拿不到输出值时 nil(不给展开那一行)。
    public static func output(sourceSampleRate: Int?, outputSampleRate: Double?) -> OutputDescription? {
        guard let output = outputSampleRate, output.isFinite, output > 0 else { return nil }
        let rateText = "\(OutputSampleRateTextPolicy.kilohertz(output))kHz"
        guard let source = sourceSampleRate, source > 0 else {
            return OutputDescription(rateText: rateText, match: .sourceUnknown)
        }
        return OutputDescription(
            rateText: rateText,
            match: abs(output - Double(source)) >= 1 ? .resampled : .matched
        )
    }
}
