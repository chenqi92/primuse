import Foundation

/// 音量条这一刻究竟在控制什么。
///
/// 应用音量始终是应用自己的音量：它只缩放 Primuse 送出去的声音，不去改系统
/// 音量，也就不会影响别的 app。播放链路有好几条，它们各自的增益位置不同 ——
///
/// - `applicationGain` —— 能施加增益的路径：音效模式走混音器，高保真直通走输出
///   单元的应用级音量，电台与 MV 走各自的 AVPlayer，投屏把音量发给远端渲染器。
/// - `unavailable` —— 应用确实无能为力：DoP/DSD 直通的样本里装的是 1bit 码流，
///   乘任何系数都会变成噪声；Apple Music 由系统播放器解码播放，应用拿不到它的
///   任何增益节点。此时控件禁用并说明原因。
public enum PlaybackVolumeControlTarget: String, Equatable, Sendable {
    case applicationGain
    case unavailable

    /// 控件是否可交互。
    public var isAdjustable: Bool { self != .unavailable }
}

public enum PlaybackVolumeControlPolicy {
    /// - Parameters:
    ///   - isLiveRadio: 电台走独立的 AVPlayer，音量始终由应用施加，
    ///     与本地播放选的输出模式无关。
    ///   - isCastingToRemoteRenderer: 正在投屏。声音在远端设备上出，音量发给
    ///     渲染器，同样属于应用侧音量。
    ///   - isSystemManagedPlayback: 这一刻的声音由系统播放器负责(Apple Music
    ///     的 DRM 流)。应用拿不到任何增益节点。
    ///   - applicationGainIsAvailable: 本地播放图这一刻能不能施加应用增益
    ///     (DoP/DSD 直通不能)。
    public static func target(
        isLiveRadio: Bool,
        isCastingToRemoteRenderer: Bool = false,
        isSystemManagedPlayback: Bool = false,
        applicationGainIsAvailable: Bool
    ) -> PlaybackVolumeControlTarget {
        if isLiveRadio || isCastingToRemoteRenderer { return .applicationGain }
        if isSystemManagedPlayback { return .unavailable }
        return applicationGainIsAvailable ? .applicationGain : .unavailable
    }

    /// 控件应当显示的位置。
    ///
    /// `unavailable` 显示满格是有意的：那条路径上应用没有衰减，此刻输出的就是
    /// 原始电平，显示一个用户设置过的中间值反而是在骗人。
    public static func displayValue(
        target: PlaybackVolumeControlTarget,
        userVolume: Double
    ) -> Double {
        switch target {
        case .applicationGain: return clamped(userVolume)
        case .unavailable: return 1
        }
    }

    /// 音量图标与百分比读数用的值，和滑块保持同一个来源。
    public static func indicatorValue(
        target: PlaybackVolumeControlTarget,
        userVolume: Double
    ) -> Double {
        displayValue(target: target, userVolume: userVolume)
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
