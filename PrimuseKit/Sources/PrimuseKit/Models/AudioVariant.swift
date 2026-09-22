import Foundation

/// Apple Music 目录曲目**提供**的音质版本，取自 MusicKit 的 `Song.audioVariants`。
///
/// 这里标的是「这首歌有哪些版本可选」，不是「此刻正在播什么」。目录曲是 DRM 流，
/// 只能交给 `ApplicationMusicPlayer` 播；实际到耳朵里的编码由系统「设置 → 音乐 →
/// 音频质量」以及输出设备（内建扬声器 / 有线 / 蓝牙 / AirPlay）共同决定，Apple
/// 没有公开接口让 App 读到，更改不了。所以界面上必须写成「提供」而不是「正在播放」。
///
/// 只有**目录**曲目能拿到这组值。资料库曲目（`MusicLibraryRequest`）不带这个扩展
/// 属性，要先对应到目录 ID 再查。
public enum AudioVariant: String, Codable, Sendable, CaseIterable {
    /// 有损立体声（AAC）。
    case lossyStereo
    /// 无损：ALAC，最高 24 位 / 48 kHz。
    case lossless
    /// 高解析度无损：ALAC，最高 24 位 / 192 kHz。
    case highResolutionLossless
    /// 杜比全景声。
    case dolbyAtmos
    /// 杜比音频（非全景声的杜比编码）。
    case dolbyAudio

    /// 本地化文案的键。三端共用 PrimuseKit 的表。
    public var localizationKey: String {
        switch self {
        case .lossyStereo: "audio_variant_lossy_stereo"
        case .lossless: "audio_variant_lossless"
        case .highResolutionLossless: "audio_variant_hi_res_lossless"
        case .dolbyAtmos: "audio_variant_dolby_atmos"
        case .dolbyAudio: "audio_variant_dolby_audio"
        }
    }

    /// 展示优先级 —— 数字大的更值得单独标出来。
    public var prominence: Int {
        switch self {
        case .dolbyAtmos: 4
        case .highResolutionLossless: 3
        case .lossless: 2
        case .dolbyAudio: 1
        case .lossyStereo: 0
        }
    }
}

public extension Array where Element == AudioVariant {
    /// 这组版本里最值得展示的无损档位。杜比单独成标，不参与这里的比较。
    var bestLosslessTier: AudioVariant? {
        if contains(.highResolutionLossless) { return .highResolutionLossless }
        if contains(.lossless) { return .lossless }
        return nil
    }

    /// 是否提供杜比全景声。
    var offersDolbyAtmos: Bool { contains(.dolbyAtmos) }

    /// 曲目提供无损时按 ALAC 记，否则按 AAC 记 —— Apple Music 的无损档位就是
    /// ALAC，有损档位就是 AAC，这一层归类是确定的。具体采样率 / 位深不写进
    /// `Song.sampleRate` / `bitDepth`：Apple 只保证「最高」多少，逐曲的真实数值
    /// 拿不到，写进去会让排序和规格行变成另一种假话。
    var impliedFileFormat: AudioFormat {
        bestLosslessTier == nil ? .aac : .alac
    }
}
