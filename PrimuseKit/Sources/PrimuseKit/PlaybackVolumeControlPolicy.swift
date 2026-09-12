import Foundation

/// 音量条这一刻究竟在控制什么。
///
/// 播放链路有三条互不相干的音量通道，过去它们被同一个 `volume` 属性搅在一起，
/// 结果是「高保真下读到的恒为 1」污染了电台起播音量、MV 音量和 DLNA 上报：
///
/// - `applicationGain` —— 应用自己施加的增益。音效模式走混音器，电台与 MV 走
///   各自的 AVPlayer，三者都是应用内音量。
/// - `outputDevice` —— 高保真直通不允许在音频数据上动手脚，音量只能交给输出
///   设备的硬件音量。
/// - `unavailable` —— 高保真直通，而这台设备不给调硬件音量(部分 USB DAC 只有
///   物理旋钮)。此时应用确实无能为力，控件应当禁用并说明原因。
public enum PlaybackVolumeControlTarget: String, Equatable, Sendable {
    case applicationGain
    case outputDevice
    case unavailable

    /// 控件是否可交互。
    public var isAdjustable: Bool { self != .unavailable }
}

public enum PlaybackVolumeControlPolicy {
    /// - Parameters:
    ///   - isLiveRadio: 电台走独立的 AVPlayer，音量始终由应用施加，
    ///     与本地播放选的输出模式无关。
    ///   - isHighFidelityDirect: 本地播放正处于高保真直通(图里没有增益节点)。
    ///   - outputDeviceVolumeIsControllable: 当前输出设备暴露了可写的硬件音量。
    public static func target(
        isLiveRadio: Bool,
        isHighFidelityDirect: Bool,
        outputDeviceVolumeIsControllable: Bool
    ) -> PlaybackVolumeControlTarget {
        if isLiveRadio { return .applicationGain }
        guard isHighFidelityDirect else { return .applicationGain }
        return outputDeviceVolumeIsControllable ? .outputDevice : .unavailable
    }

    /// 控件应当显示的位置。
    ///
    /// `unavailable` 显示满格是有意的：高保真直通不衰减，此刻应用输出的就是
    /// 原始电平，显示一个用户设置过的中间值反而是在骗人。
    public static func displayValue(
        target: PlaybackVolumeControlTarget,
        userVolume: Double,
        deviceVolume: Double?
    ) -> Double {
        switch target {
        case .applicationGain:
            return clamped(userVolume)
        case .outputDevice:
            // 设备音量还没读到时先按用户音量占位，避免控件从 0 跳到真实值。
            return clamped(deviceVolume ?? userVolume)
        case .unavailable:
            return 1
        }
    }

    /// 音量图标与百分比读数用的值，和滑块保持同一个来源。
    public static func indicatorValue(
        target: PlaybackVolumeControlTarget,
        userVolume: Double,
        deviceVolume: Double?
    ) -> Double {
        displayValue(target: target, userVolume: userVolume, deviceVolume: deviceVolume)
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
