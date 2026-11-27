import Foundation

/// 语音增强(REQ-174):有声内容在放、开关打开时,效果链里已有的均衡和压缩器换成说话用的设定 ——
/// 均衡压掉低频的轰鸣和中低频的浑浊、提一点人声清晰度所在的频段,压缩器把小声的地方拉起来、
/// 大声的地方压住,各期节目听起来差不多响。不加新的节点:两者原本就有不咔哒的切换(均衡交叉淡变,
/// 压缩器按 `CompressorTransitionPolicy` 一小步一小步挪),音乐时完全照用户自己的设置。
public enum SpokenWordVoiceBoostPolicy {
    // MARK: - Compressor

    /// 阈值压得低、余量小:说话的动态大部分被压平,轻声也能拉上来。
    public static let threshold: Float = -28
    public static let headRoom: Float = 3
    public static let attackTime: Float = 0.003
    public static let releaseTime: Float = 0.15
    /// 想要的总增益;实际不超过 `CompressorTransitionPolicy.maximumGainDB`,满幅的节目也不会削波。
    public static let requestedGain: Float = 9

    /// 语音增强开着时压缩器要走到的参数。
    public static var compressorTarget: CompressorTransitionPolicy.Parameters {
        CompressorTransitionPolicy.target(
            enabled: true,
            threshold: threshold,
            headRoom: headRoom,
            gain: requestedGain
        )
    }

    // MARK: - Equalizer

    /// 叠在用户自己的均衡后面的几段:低频架式衰减去轰鸣,250 Hz 附近稍压去浑浊,3 kHz 附近提清晰度。
    public static let filters: [PEQFilter] = [
        PEQFilter(kind: .lowShelf, frequency: 100, gain: -6, q: 0.7),
        PEQFilter(kind: .peak, frequency: 250, gain: -2, q: 1.0),
        PEQFilter(kind: .peak, frequency: 3_000, gain: 4, q: 0.8),
    ]

    /// 在 `base`(用户的均衡,没开就是 `.flat`)后面叠上人声那几段。整体先压低到叠加后的峰值不超过
    /// 0 dB,不比原来的预衰减更响。放不下(用户的参数均衡已经用满)时原样返回,只靠压缩器。
    public static func equalizerConfiguration(
        adding base: EQRenderConfiguration,
        sampleRate: Double
    ) -> EQRenderConfiguration {
        guard sampleRate.isFinite, sampleRate >= 8_000 else { return base }
        let voice = filters
            .filter { $0.frequency < sampleRate * 0.5 }
            .map { EQBiquad(filter: $0, sampleRate: sampleRate) }
        guard base.filters.count + voice.count <= ParametricEQ.maximumFilters else { return base }
        let combined = base.filters + voice
        let peak = EQRenderConfiguration.peakGainDB(filters: combined, sampleRate: sampleRate)
        let safety = peak > 0.05 ? -peak : 0
        return EQRenderConfiguration(filters: combined, preampDB: min(0, base.preampDB, safety))
    }
}
