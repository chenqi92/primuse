import Foundation

/// 主题强调色在浅色、深色外观下各用哪一档才读得清。
///
/// 封面取出来的颜色只在 HSB 里限过亮度，黄、绿、青、浅粉这类封面在白底上的对比度只有
/// 1.5–2.5:1，用作按钮文字、图标和开关就糊掉了。这里保留色相，只把明暗推到够用为止：
/// 浅色外观压暗到白底上 4.5:1，深色外观提亮到黑底上 4.5:1。已经够用的颜色原样返回。
///
/// 刻意不用平台颜色类型，规则要能在没有图形栈的地方直接跑测试。
public enum ThemeAccentContrastPolicy {
    public enum Appearance: Sendable, Equatable {
        case light
        case dark
    }

    /// sRGB 分量，都在 0...1。
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = ThemeAccentContrastPolicy.clamp01(red)
            self.green = ThemeAccentContrastPolicy.clamp01(green)
            self.blue = ThemeAccentContrastPolicy.clamp01(blue)
        }

        public static let white = RGB(red: 1, green: 1, blue: 1)
        public static let black = RGB(red: 0, green: 0, blue: 0)
    }

    /// WCAG AA 的正文门槛。强调色会当文字色用（「查看全部」、链接、按钮标题），按正文算。
    public static let minimumContrastRatio = 4.5

    /// 浅色外观以白底衡量，深色外观以黑底衡量。
    public static func background(for appearance: Appearance) -> RGB {
        appearance == .light ? .white : .black
    }

    public static func legible(_ color: RGB, for appearance: Appearance) -> RGB {
        let ground = background(for: appearance)
        if contrastRatio(color, ground) >= minimumContrastRatio { return color }
        switch appearance {
        case .light:
            return darkened(color, against: ground)
        case .dark:
            return lightened(color, against: ground)
        }
    }

    /// 按比例压暗（色相、饱和度不变），取仍满足对比度的最亮那一档。
    private static func darkened(_ color: RGB, against ground: RGB) -> RGB {
        // 亮度系数越小相对亮度越低、与白底的对比度越高，单调，可以二分。
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if contrastRatio(scaled(color, by: mid), ground) >= minimumContrastRatio {
                low = mid
            } else {
                high = mid
            }
        }
        return scaled(color, by: low)
    }

    /// 先提亮度（最多到最亮的分量为 1，色相、饱和度不变），还不够再往白色混，
    /// 都取刚好满足对比度的那一档，免得颜色被洗得太淡。
    private static func lightened(_ color: RGB, against ground: RGB) -> RGB {
        let peak = max(color.red, color.green, color.blue)
        var brightest = color
        if peak > 0 {
            let limit = 1 / peak
            brightest = scaled(color, by: limit)
            if contrastRatio(brightest, ground) >= minimumContrastRatio {
                var low = 1.0
                var high = limit
                for _ in 0..<32 {
                    let mid = (low + high) / 2
                    if contrastRatio(scaled(color, by: mid), ground) >= minimumContrastRatio {
                        high = mid
                    } else {
                        low = mid
                    }
                }
                return scaled(color, by: high)
            }
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if contrastRatio(mixed(brightest, toward: .white, by: mid), ground) >= minimumContrastRatio {
                high = mid
            } else {
                low = mid
            }
        }
        return mixed(brightest, toward: .white, by: high)
    }

    // MARK: - 颜色计算

    public static func contrastRatio(_ lhs: RGB, _ rhs: RGB) -> Double {
        let a = relativeLuminance(of: lhs)
        let b = relativeLuminance(of: rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// sRGB 相对亮度。
    public static func relativeLuminance(of color: RGB) -> Double {
        0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }

    private static func scaled(_ color: RGB, by factor: Double) -> RGB {
        RGB(red: color.red * factor, green: color.green * factor, blue: color.blue * factor)
    }

    private static func mixed(_ color: RGB, toward target: RGB, by amount: Double) -> RGB {
        RGB(
            red: color.red + (target.red - color.red) * amount,
            green: color.green + (target.green - color.green) * amount,
            blue: color.blue + (target.blue - color.blue) * amount
        )
    }

    private static func linearize(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    fileprivate static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
