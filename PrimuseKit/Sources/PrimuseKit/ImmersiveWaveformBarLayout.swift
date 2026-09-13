import Foundation

/// 沉浸播放「实时波形」里那排音柱的几何。
public struct ImmersiveWaveformBarLayout: Sendable, Equatable {
    public let count: Int
    public let barWidth: Double
    public let spacing: Double

    public init(count: Int, barWidth: Double, spacing: Double) {
        self.count = count
        self.barWidth = barWidth
        self.spacing = spacing
    }

    /// 整排音柱实际占用的宽度。
    public var totalWidth: Double {
        guard count > 0 else { return 0 }
        return barWidth * Double(count) + spacing * Double(count - 1)
    }

    /// 柱宽与间距之比。超过 2 就会从「一排音柱」糊成「一整块色带」。
    public var widthToSpacingRatio: Double {
        spacing > 0 ? barWidth / spacing : .infinity
    }
}

public enum ImmersiveWaveformBarLayoutPolicy {
    /// 音柱数量上限存在的意义是别在超宽画布上画出几百根发丝;但它一旦先于柱宽
    /// 被定死,多出来的宽度就会被平摊到每根柱子上 —— Apple TV 的 1920pt 画布按
    /// 老参数只能排 68 根,于是每根粗到 17pt 而间距仍是 8pt,看着就是一条色带
    /// 而不是波形。所以柱宽由面板高度定,数量跟着可用宽度走,上限只做兜底。
    public static func layout(
        width: Double,
        height: Double,
        barWidthRatio: Double,
        minimumCount: Int,
        maximumCount: Int
    ) -> ImmersiveWaveformBarLayout {
        guard width > 0, height > 0, minimumCount > 0, maximumCount >= minimumCount else {
            return ImmersiveWaveformBarLayout(count: 0, barWidth: 0, spacing: 0)
        }
        let preferredWidth = max(height * barWidthRatio, 3)
        let preferredSpacing = max(preferredWidth * 0.82, 2.2)
        let availableCount = Int((width + preferredSpacing) / (preferredWidth + preferredSpacing))
        let count = min(max(availableCount, minimumCount), maximumCount)
        let spacing = max(min(preferredSpacing, width * 0.012), 2)
        let barWidth = max((width - spacing * Double(count - 1)) / Double(count), 2.4)
        return ImmersiveWaveformBarLayout(count: count, barWidth: barWidth, spacing: spacing)
    }

    /// 手机与 Mac 沿用原参数,像素级不变。
    public static let compactBarWidthRatio: Double = 0.045
    public static let compactMinimumCount = 38
    public static let compactMaximumCount = 68

    /// 电视:柱子细一档、根数放开,1920pt 宽的面板才排得出波形而不是色带。
    public static let televisionBarWidthRatio: Double = 0.038
    public static let televisionMinimumCount = 38
    public static let televisionMaximumCount = 140
}
