import Foundation

/// 「流动色彩」背景用的一个颜色(sRGB,0…1)。
public struct LiquidBackdropColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public func mixed(with other: LiquidBackdropColor, amount: Double) -> LiquidBackdropColor {
        let t = min(max(amount, 0), 1)
        return LiquidBackdropColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    // MARK: HSL

    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let lightness = (maxValue + minValue) / 2
        let delta = maxValue - minValue
        guard delta > 0.000_1 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch maxValue {
        case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, min(saturation, 1), lightness)
    }

    init(hue: Double, saturation: Double, lightness: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = lightness - chroma / 2
        self.init(red: r + m, green: g + m, blue: b + m)
    }
}

/// 从封面小图里挑出「流动色彩」用的几个代表色:主色、鲜艳色、亮鲜艳、暗鲜艳、柔和色、亮柔和、暗柔和
/// (和 Android Palette 的几类目标同一个思路)。只在换歌、封面变了的时候算一次,动画只用算好的颜色。
public enum LiquidBackdropPalettePolicy {
    /// 一块颜色最多这么亮(HSL 明度),免得整屏发白、压不住上面的字。
    public static let maximumLightness = 0.82
    /// 最暗不低于这个,免得在深色背景里看不见。
    public static let minimumLightness = 0.12

    private struct Swatch {
        var color: LiquidBackdropColor
        var population: Int
        var hue: Double
        var saturation: Double
        var lightness: Double
    }

    private struct Target {
        var lightness: ClosedRange<Double>
        var targetLightness: Double
        var saturation: ClosedRange<Double>
        var targetSaturation: Double
    }

    private static let targets: [Target] = [
        // 鲜艳
        Target(lightness: 0.3...0.7, targetLightness: 0.5, saturation: 0.35...1, targetSaturation: 1),
        // 亮鲜艳
        Target(lightness: 0.55...1, targetLightness: 0.74, saturation: 0.35...1, targetSaturation: 1),
        // 暗鲜艳
        Target(lightness: 0...0.45, targetLightness: 0.26, saturation: 0.35...1, targetSaturation: 1),
        // 柔和
        Target(lightness: 0.3...0.7, targetLightness: 0.5, saturation: 0...0.4, targetSaturation: 0.3),
        // 亮柔和
        Target(lightness: 0.55...1, targetLightness: 0.74, saturation: 0...0.4, targetSaturation: 0.3),
        // 暗柔和
        Target(lightness: 0...0.45, targetLightness: 0.26, saturation: 0...0.4, targetSaturation: 0.3),
    ]

    /// - Parameter pixels: 小图的像素,每个是 0…255 的 RGB。透明的像素调用方先去掉。
    /// - Returns: 2…7 个颜色,主色在最前;像素太少、或全是一个颜色时返回空数组,调用方用主题色兜底。
    public static func palette(fromRGB pixels: [(UInt8, UInt8, UInt8)], maximumCount: Int = 7) -> [LiquidBackdropColor] {
        guard pixels.count >= 16 else { return [] }
        // 每通道 4 位量化,同一格取平均。
        var sums: [Int: (r: Int, g: Int, b: Int, count: Int)] = [:]
        for (r, g, b) in pixels {
            let key = (Int(r) >> 4) << 8 | (Int(g) >> 4) << 4 | (Int(b) >> 4)
            var entry = sums[key] ?? (0, 0, 0, 0)
            entry.r += Int(r)
            entry.g += Int(g)
            entry.b += Int(b)
            entry.count += 1
            sums[key] = entry
        }
        var swatches = sums.values.map { entry -> Swatch in
            let color = LiquidBackdropColor(
                red: Double(entry.r) / Double(entry.count) / 255,
                green: Double(entry.g) / Double(entry.count) / 255,
                blue: Double(entry.b) / Double(entry.count) / 255
            )
            let hsl = color.hsl
            return Swatch(color: color, population: entry.count, hue: hsl.hue, saturation: hsl.saturation, lightness: hsl.lightness)
        }
        // 太零碎的格子(不到千分之五)不算一种颜色。
        let minimumPopulation = max(1, pixels.count / 200)
        swatches = swatches.filter { $0.population >= minimumPopulation }
        guard let dominant = swatches.max(by: { $0.population < $1.population }) else { return [] }
        let maxPopulation = Double(dominant.population)

        var picked: [Swatch] = [dominant]
        for target in targets {
            let candidates = swatches.filter { swatch in
                target.lightness.contains(swatch.lightness)
                    && target.saturation.contains(swatch.saturation)
                    && !picked.contains { isSimilar($0, swatch) }
            }
            let best = candidates.max { score($0, target, maxPopulation) < score($1, target, maxPopulation) }
            if let best { picked.append(best) }
        }
        // 每一类目标只挑一个:几块同样鲜艳的大色块拼成的封面(蓝、橙、洋红)只会留下一种。目标挑完后,
        // 占比 3% 以上、和已选颜色差得开的也补上,补到上限,封面里的每种主要颜色都能出场。
        let significant = max(minimumPopulation, pixels.count * 3 / 100)
        for swatch in swatches.sorted(by: { $0.population > $1.population })
        where picked.count < maximumCount
            && swatch.population >= significant
            && !picked.contains(where: { isSimilar($0, swatch) }) {
            picked.append(swatch)
        }
        // 还是不够四种时,不看占比再补几种。
        if picked.count < 4 {
            for swatch in swatches.sorted(by: { $0.population > $1.population })
            where picked.count < 4 && !picked.contains(where: { isSimilar($0, swatch) }) {
                picked.append(swatch)
            }
        }
        let colors = picked.prefix(maximumCount).map { clamped($0.color) }
        var distinct: [LiquidBackdropColor] = []
        for color in colors where !distinct.contains(color) { distinct.append(color) }
        return distinct.count >= 2 ? distinct : []
    }

    /// 底色:前两个颜色混一下,压暗、降一点饱和度,铺在色块下面。
    public static func baseColor(for palette: [LiquidBackdropColor], isLight: Bool) -> LiquidBackdropColor {
        guard let first = palette.first else {
            return isLight ? LiquidBackdropColor(red: 0.96, green: 0.96, blue: 0.97) : LiquidBackdropColor(red: 0.05, green: 0.05, blue: 0.06)
        }
        let mixed = palette.count > 1 ? first.mixed(with: palette[1], amount: 0.5) : first
        let hsl = mixed.hsl
        return isLight
            ? LiquidBackdropColor(hue: hsl.hue, saturation: min(hsl.saturation, 0.35), lightness: 0.9)
            : LiquidBackdropColor(hue: hsl.hue, saturation: min(hsl.saturation, 0.7), lightness: 0.14)
    }

    /// 七团色块各用哪个颜色:颜色不够七个时循环取用。
    public static func blobColors(for palette: [LiquidBackdropColor], count: Int = LiquidBackdropMotion.blobCount) -> [LiquidBackdropColor] {
        guard !palette.isEmpty else { return [] }
        return (0..<count).map { palette[$0 % palette.count] }
    }

    private static func score(_ swatch: Swatch, _ target: Target, _ maxPopulation: Double) -> Double {
        let saturation = 1 - abs(swatch.saturation - target.targetSaturation)
        let lightness = 1 - abs(swatch.lightness - target.targetLightness)
        let population = Double(swatch.population) / maxPopulation
        return saturation * 0.24 + lightness * 0.52 + population * 0.24
    }

    private static func isSimilar(_ lhs: Swatch, _ rhs: Swatch) -> Bool {
        let dr = lhs.color.red - rhs.color.red
        let dg = lhs.color.green - rhs.color.green
        let db = lhs.color.blue - rhs.color.blue
        return (dr * dr + dg * dg + db * db).squareRoot() < 0.12
    }

    private static func clamped(_ color: LiquidBackdropColor) -> LiquidBackdropColor {
        let hsl = color.hsl
        guard hsl.lightness > maximumLightness || hsl.lightness < minimumLightness else { return color }
        return LiquidBackdropColor(
            hue: hsl.hue,
            saturation: hsl.saturation,
            lightness: min(max(hsl.lightness, minimumLightness), maximumLightness)
        )
    }
}

/// 「流动色彩」七团色块在某一时刻的位置与大小。几组频率互不成整数比的正弦叠在一起,
/// 看上去不重复、不突然拐弯;只和「动了多久」有关,暂停时传同一个时间就原地停住,
/// 换歌不重置。
public enum LiquidBackdropMotion {
    public static let blobCount = 7
    /// 主周期(秒)。
    public static let cycleDuration: Double = 18
    /// 每团色块的不透明度。
    public static let blobOpacity: Double = 0.65

    public struct Blob: Equatable, Sendable {
        /// 圆心,以画布宽高为 1。
        public var x: Double
        public var y: Double
        /// 半径,以画布长边为 1。
        public var radius: Double
    }

    // 每团色块自己的频率倍数与相位;两组频率比是无理数,轨迹不会很快重复。
    private static let xRates: [Double] = [1.0, 0.77, 1.31, 0.59, 1.13, 0.89, 1.47]
    private static let yRates: [Double] = [0.83, 1.19, 0.67, 1.41, 0.97, 1.27, 0.71]
    private static let golden = 1.618_033_988_75

    public static func blobs(at elapsed: Double) -> [Blob] {
        let angle = elapsed / cycleDuration * 2 * Double.pi
        return (0..<blobCount).map { index in
            let i = Double(index)
            let phase = i * 2 * Double.pi / Double(blobCount)
            let xr = xRates[index]
            let yr = yRates[index]
            // 主运动 + 一层慢得多、频率比为黄金比的扰动。
            let dx = 0.72 * sin(angle * xr + phase) + 0.28 * sin(angle * xr / golden + phase * 1.7)
            let dy = 0.72 * cos(angle * yr + phase) + 0.28 * cos(angle * yr / golden + phase * 2.3)
            // 移动范围约为画布的 ±42%,圆心始终在画布以内。
            let x = 0.5 + dx * 0.42
            let y = 0.5 + dy * 0.42
            // 半径约为长边的一半,各团略有大小,随时间 ±10% 慢慢呼吸。比 Linx 的 55% 小一点:
            // 七团都盖满整屏时颜色会被平均成一片浑色,小一点封面里的几种颜色才分得出来。
            let base = 0.48 * (0.9 + 0.2 * (i / Double(blobCount - 1)))
            let breath = 1 + 0.1 * sin(angle * 0.6 + i * 1.3)
            return Blob(x: x, y: y, radius: base * breath)
        }
    }
}
