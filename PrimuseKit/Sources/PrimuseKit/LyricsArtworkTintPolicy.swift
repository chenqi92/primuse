import Foundation

/// 歌词颜色选「封面取色」时，当前歌词用哪种颜色。
///
/// 色相跟正在播放的封面走；明暗按歌词所在的底调到读得清：深色底（默认歌词是浅色字）提亮，
/// 浅色底（默认歌词是深色字）压暗。只调到够用为止，颜色不被洗成白色或黑色。
/// 封面接近黑白灰时没有可跟的颜色，返回空，歌词用默认颜色。
///
/// 刻意不用平台颜色类型，规则要能在没有图形栈的地方直接跑测试。
public enum LyricsArtworkTintPolicy {
    public typealias RGB = ThemeAccentContrastPolicy.RGB

    /// 饱和度低于这个值的封面色当作黑白灰。
    public static let minimumSaturation = 0.08

    /// 深色底上歌词的饱和度区间：太淡看着像白色，太浓压在同色系的背景上发闷。
    public static let darkBackdropSaturation: ClosedRange<Double> = 0.4...0.62
    /// 深色底上歌词的相对亮度下限。播放页的深色背景相对亮度在 0.1 以内，
    /// 这样大号歌词对背景至少 3:1，对纯黑约 9:1。
    public static let minimumLuminanceOnDarkBackdrop = 0.4

    /// 浅色底上歌词的最低饱和度，压暗后仍看得出颜色。
    public static let lightBackdropMinimumSaturation = 0.6
    /// 浅色底上歌词起步的明度（HSB）：太亮的先压到上限，很暗的封面色先提到下限，压暗后还看得出颜色。
    public static let lightBackdropBrightness: ClosedRange<Double> = 0.35...0.55
    /// 浅色底上歌词的相对亮度上限：对白底约 6:1，对浅色背景也在 4.5:1 上下。
    public static let maximumLuminanceOnLightBackdrop = 0.12

    public static func lyricColor(for artwork: RGB, onDarkBackdrop: Bool) -> RGB? {
        guard let hsb = hsb(of: artwork), hsb.saturation >= minimumSaturation else { return nil }
        if onDarkBackdrop {
            let saturation = min(max(hsb.saturation, darkBackdropSaturation.lowerBound),
                                 darkBackdropSaturation.upperBound)
            let start = rgb(hue: hsb.hue, saturation: saturation, brightness: 1)
            return lightened(start, toLuminance: minimumLuminanceOnDarkBackdrop)
        }
        let saturation = max(hsb.saturation, lightBackdropMinimumSaturation)
        let brightness = min(max(hsb.brightness, lightBackdropBrightness.lowerBound),
                             lightBackdropBrightness.upperBound)
        let start = rgb(hue: hsb.hue, saturation: saturation, brightness: brightness)
        return darkened(start, toLuminance: maximumLuminanceOnLightBackdrop)
    }

    /// 往白色混到相对亮度刚好够下限；已经够了原样返回。
    private static func lightened(_ color: RGB, toLuminance floor: Double) -> RGB {
        guard luminance(color) < floor else { return color }
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if luminance(mixed(color, toward: .white, by: mid)) >= floor {
                high = mid
            } else {
                low = mid
            }
        }
        return mixed(color, toward: .white, by: high)
    }

    /// 等比压暗（色相、饱和度不变）到相对亮度刚好不超过上限；已经够暗原样返回。
    private static func darkened(_ color: RGB, toLuminance ceiling: Double) -> RGB {
        guard luminance(color) > ceiling else { return color }
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if luminance(scaled(color, by: mid)) <= ceiling {
                low = mid
            } else {
                high = mid
            }
        }
        return scaled(color, by: low)
    }

    // MARK: - 颜色计算

    public static func luminance(_ color: RGB) -> Double {
        ThemeAccentContrastPolicy.relativeLuminance(of: color)
    }

    struct HSB {
        let hue: Double
        let saturation: Double
        let brightness: Double
    }

    static func hsb(of color: RGB) -> HSB? {
        let maxC = max(color.red, color.green, color.blue)
        let minC = min(color.red, color.green, color.blue)
        guard maxC > 0 else { return nil }
        let delta = maxC - minC
        let saturation = delta / maxC
        guard delta > 0 else { return HSB(hue: 0, saturation: 0, brightness: maxC) }
        var hue: Double
        if maxC == color.red {
            hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == color.green {
            hue = (color.blue - color.red) / delta + 2
        } else {
            hue = (color.red - color.green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return HSB(hue: hue, saturation: saturation, brightness: maxC)
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        let sector = (hue - hue.rounded(.down)) * 6
        let index = Int(sector.rounded(.down)) % 6
        let fraction = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return RGB(red: brightness, green: t, blue: p)
        case 1: return RGB(red: q, green: brightness, blue: p)
        case 2: return RGB(red: p, green: brightness, blue: t)
        case 3: return RGB(red: p, green: q, blue: brightness)
        case 4: return RGB(red: t, green: p, blue: brightness)
        default: return RGB(red: brightness, green: p, blue: q)
        }
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
}
