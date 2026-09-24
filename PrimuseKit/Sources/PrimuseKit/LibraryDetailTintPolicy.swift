import Foundation

/// 详情页底色的一段颜色，HSB 三个分量都在 0...1。
///
/// 刻意不用平台颜色类型：压深与对比度这套规则要能在没有图形栈的地方直接跑测试。
public struct LibraryDetailTintStop: Equatable, Sendable {
    public let hue: Double
    public let saturation: Double
    public let brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

/// 一整页详情页的底色：顶部一段、底部一段，中间线性过渡。
public struct LibraryDetailTint: Equatable, Sendable {
    public let top: LibraryDetailTintStop
    public let bottom: LibraryDetailTintStop

    public init(top: LibraryDetailTintStop, bottom: LibraryDetailTintStop) {
        self.top = top
        self.bottom = bottom
    }
}

/// 专辑 / 艺术家 / 风格详情页那块随封面变化的底色怎么定。
///
/// 封面主色直接铺满一页是不能用的：饱和度高的封面会刺眼，亮色封面上白字会糊掉。
/// 这里把封面色的**色相**留下来当身份，饱和度收进一个区间，亮度压到白字读得清
/// 为止 —— 所以整页(头图、歌曲列表、页尾)可以共用一个前景色，看上去才是一体的。
public enum LibraryDetailTintPolicy {
    public enum Appearance: Sendable, Equatable {
        case light
        case dark
    }

    /// 正文一律白字，底色必须先满足这个对比度才允许上屏。WCAG AA 的正文门槛。
    public static let minimumContrastRatio = 4.5

    /// 饱和度区间。下限保证还看得出是"这张封面的颜色"，上限挡住霓虹色封面。
    private static let minimumSaturation = 0.24
    private static let maximumSaturation = 0.58
    /// 低于这个饱和度的封面(黑白照、灰调专辑)不硬凑颜色，当作中性底处理。
    private static let achromaticSaturation = 0.08
    private static let achromaticTintSaturation = 0.10

    /// 底部相对顶部的亮度系数。差太小看不出层次，差太大又会像两块色。
    private static let bottomBrightnessFactor = 0.58

    /// 取不到封面色时的中性底：偏蓝的深灰，不会被误认成某张封面的颜色。
    private static let neutralHue = 0.62
    private static let neutralSaturation = 0.06

    /// - Parameters:
    ///   - hue: 封面主色的色相，允许超出 0...1(会归一化)。
    ///   - saturation: 封面主色的饱和度。
    ///   - brightness: 封面主色的明度，只用来在区间内微调，不直接采用。
    public static func tint(
        hue: Double,
        saturation: Double,
        brightness: Double,
        appearance: Appearance
    ) -> LibraryDetailTint {
        let sourceSaturation = clamp01(saturation)
        guard sourceSaturation >= achromaticSaturation else {
            return neutralTint(appearance: appearance)
        }

        let normalizedHue = normalizedHue(hue)
        let tintSaturation = min(max(sourceSaturation, minimumSaturation), maximumSaturation)
        return tint(
            hue: normalizedHue,
            tintSaturation: tintSaturation,
            sourceBrightness: clamp01(brightness),
            appearance: appearance
        )
    }

    /// 整页底色里的「副色」：取封面调色板的第二色，按和主色同一套规则压深，白字照样读得清。
    ///
    /// 第二色是灰调、或者调色板里压根没有第二色时，副色就等于主色 —— 整页不会凭空多出一块灰。
    public static func accentTint(
        primary: (hue: Double, saturation: Double, brightness: Double),
        secondary: (hue: Double, saturation: Double, brightness: Double)?,
        appearance: Appearance
    ) -> LibraryDetailTint {
        guard let secondary, clamp01(secondary.saturation) >= achromaticSaturation else {
            return tint(
                hue: primary.hue,
                saturation: primary.saturation,
                brightness: primary.brightness,
                appearance: appearance
            )
        }
        return tint(
            hue: secondary.hue,
            saturation: secondary.saturation,
            brightness: secondary.brightness,
            appearance: appearance
        )
    }

    /// 封面读不出代表色时用的底色。加载途中也先用它，颜色到位后再过渡。
    public static func neutralTint(appearance: Appearance) -> LibraryDetailTint {
        tint(
            hue: neutralHue,
            tintSaturation: neutralSaturation,
            sourceBrightness: 0.5,
            appearance: appearance
        )
    }

    private static func tint(
        hue: Double,
        tintSaturation: Double,
        sourceBrightness: Double,
        appearance: Appearance
    ) -> LibraryDetailTint {
        // 2.0 的详情页整页是「封面色的海报」:颜色要亮到一眼认得出是这张封面,
        // 白字读不读得清交给下面的对比度二分兜底 —— 亮黄、亮青这类封面会被自动压到 4.5:1。
        // 浅色外观下再亮一档,但仍然是"彩色页配白字",跟深色外观同一套版式。
        let target = appearance == .dark ? 0.44 : 0.50
        // 封面本身的明暗只在 ±12% 内影响页面，避免深色封面把页面压成纯黑。
        let nudged = target * (0.88 + 0.24 * sourceBrightness)

        let topBrightness = readableBrightness(
            hue: hue,
            saturation: tintSaturation,
            preferred: nudged
        )
        let top = LibraryDetailTintStop(
            hue: hue,
            saturation: tintSaturation,
            brightness: topBrightness
        )
        let bottom = LibraryDetailTintStop(
            hue: hue,
            saturation: tintSaturation,
            brightness: topBrightness * bottomBrightnessFactor
        )
        return LibraryDetailTint(top: top, bottom: bottom)
    }

    /// 在不超过 `preferred` 的前提下取最亮的那个仍满足对比度的亮度。
    ///
    /// 亮度升高则相对亮度单调升高、与白色的对比度单调下降，所以可以二分。
    private static func readableBrightness(
        hue: Double,
        saturation: Double,
        preferred: Double
    ) -> Double {
        let candidate = LibraryDetailTintStop(
            hue: hue,
            saturation: saturation,
            brightness: preferred
        )
        if contrastRatioAgainstWhite(candidate) >= minimumContrastRatio {
            return preferred
        }

        var low = 0.0
        var high = preferred
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let stop = LibraryDetailTintStop(hue: hue, saturation: saturation, brightness: mid)
            if contrastRatioAgainstWhite(stop) >= minimumContrastRatio {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - 颜色计算

    /// 白色与该底色的 WCAG 对比度。
    public static func contrastRatioAgainstWhite(_ stop: LibraryDetailTintStop) -> Double {
        (1.0 + 0.05) / (relativeLuminance(of: stop) + 0.05)
    }

    /// sRGB 相对亮度。
    public static func relativeLuminance(of stop: LibraryDetailTintStop) -> Double {
        let rgb = rgbComponents(of: stop)
        return 0.2126 * linearize(rgb.red)
            + 0.7152 * linearize(rgb.green)
            + 0.0722 * linearize(rgb.blue)
    }

    /// HSB → sRGB。平台颜色类型的同名转换在这里手写一份，测试才跑得起来。
    public static func rgbComponents(
        of stop: LibraryDetailTintStop
    ) -> (red: Double, green: Double, blue: Double) {
        let hue = normalizedHue(stop.hue)
        let saturation = clamp01(stop.saturation)
        let brightness = clamp01(stop.brightness)

        guard saturation > 0 else { return (brightness, brightness, brightness) }

        let sector = hue * 6
        let index = Int(sector.rounded(.down)) % 6
        let offset = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * offset)
        let t = brightness * (1 - saturation * (1 - offset))

        switch index {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }

    private static func linearize(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        guard hue.isFinite else { return 0 }
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
