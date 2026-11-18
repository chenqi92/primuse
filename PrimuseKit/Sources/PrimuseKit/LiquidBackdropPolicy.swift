import Foundation

/// Tracks bass attacks in linear FFT power, before display compression and smoothing.
public struct PlayerBackdropBassPulse: Sendable {
    private var baselineDB = -60.0
    private var riseDB = 0.0

    public init() {}

    public mutating func update(power: Double, elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        let dt = min(elapsed, 1)
        let db = 10 * log10(max(power.isFinite ? power : 0, 1e-6))
        let aboveNoise = min(max((db + 54) / 12, 0), 1)
        let attack = min(max(db - baselineDB, 0), 14) * aboveNoise
        riseDB = max(attack, riseDB * exp(-dt / 0.13))
        // Follow the valleys between kicks and settle back to rest on a held note.
        let duration = db > baselineDB ? 0.16 : 0.09
        baselineDB += (db - baselineDB) * (1 - exp(-dt / duration))
    }

    public func intensity(sensitivity: Double) -> Double {
        let s = sensitivity.isFinite ? min(max(sensitivity, 0), 1) : 0.5
        return min(max((riseDB - (3.5 - 2.5 * s)) / (10 - 6 * s), 0), 1)
    }
}

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

public enum MeshBackdropPalettePolicy {
    /// A compact palette for white player controls. Tone each stop separately so a
    /// pale highlight cannot force a black scrim over every other cover color.
    public static func vividPalette(from palette: [LiquidBackdropColor], usesIncreasedContrast: Bool = false) -> [LiquidBackdropColor] {
        let chromatic = palette.filter {
            $0.hsl.saturation >= 0.18 && max($0.red, $0.green, $0.blue) - min($0.red, $0.green, $0.blue) >= 0.07
        }
        let candidates = chromatic.isEmpty ? palette : chromatic
        var selected: [LiquidBackdropColor] = []
        for color in candidates {
            let hsl = color.hsl
            let distinct = !selected.contains { existing in
                let other = existing.hsl
                let hueDistance = min(abs(hsl.hue - other.hue), 1 - abs(hsl.hue - other.hue))
                return hueDistance < 0.04 && abs(hsl.lightness - other.lightness) < 0.12
            }
            if distinct { selected.append(color) }
            if selected.count == 4 { break }
        }
        return selected.map { color in
            let hsl = color.hsl
            let toned = LiquidBackdropColor(hue: hsl.hue, saturation: hsl.saturation,
                                           lightness: min(max(hsl.lightness, 0.20), 0.60))
            let components = [toned.red, toned.green, toned.blue].map(linear)
            let luminance = components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
            let ceiling = usesIncreasedContrast ? 0.06 : 0.12
            let scale = luminance > ceiling ? ceiling / luminance : 1
            func encoded(_ value: Double) -> Double {
                let value = value * scale
                return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
            }
            return LiquidBackdropColor(red: encoded(components[0]), green: encoded(components[1]), blue: encoded(components[2]))
        }
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    public static func colors(for palette: [LiquidBackdropColor]) -> [LiquidBackdropColor] {
        guard !palette.isEmpty else { return [] }
        // 九个顶点容纳全部七种代表色，主色重复在左上和中央。
        return [0, 2, 1, 3, 0, 4, 1, 5, 6].map { palette[$0 % min(palette.count, 7)] }
    }

    public static func points(phase: Double, amplitude: Double) -> [SIMD2<Float>] {
        meshPoints(phase: phase, amplitude: min(max(amplitude, 0), 0.08))
    }

    private static func meshPoints(phase: Double, amplitude: Double) -> [SIMD2<Float>] {
        let a = Float(amplitude)
        return [
            [0, 0], [0.5 + Float(sin(phase * 0.83)) * a, 0], [1, 0],
            [0, 0.5 + Float(cos(phase * 0.71)) * a],
            [0.5 + Float(sin(phase)) * a, 0.5 + Float(cos(phase * 0.91)) * a],
            [1, 0.5 + Float(sin(phase * 0.63)) * a],
            [0, 1], [0.5 + Float(cos(phase * 0.57)) * a, 1], [1, 1]
        ]
    }

    /// 流动色彩保留网格的封面色块，用更大的位移缓慢流动；边缘仍固定在画布上。
    public static func liquidPoints(at elapsed: TimeInterval) -> [SIMD2<Float>] {
        meshPoints(phase: elapsed * 0.18, amplitude: 0.22)
    }

    public static func minimumLuma(in palette: [LiquidBackdropColor]) -> Double {
        palette.map { 0.2126 * $0.red + 0.7152 * $0.green + 0.0722 * $0.blue }.min() ?? 0
    }

    public static func lightOpacity(
        requested: Double,
        palette: [LiquidBackdropColor],
        overlayOpacity: Double,
        usesIncreasedContrast: Bool
    ) -> Double {
        let baseLuma = 0.94
        let darkest = minimumLuma(in: palette)
        let wash = min(max(overlayOpacity, 0), 1)
        let opacity = min(max(requested, 0), 1)
        guard darkest < baseLuma, wash < 1 else { return opacity }
        // Mesh 色块可以填满文字区域，不能沿用径向光团只覆盖部分区域的估算。
        let floor = NowPlayingLightAmbientPolicy.minimumLuma(usesIncreasedContrast: usesIncreasedContrast)
        let limit = (baseLuma * (1 - wash) + wash - floor) / ((baseLuma - darkest) * (1 - wash))
        return min(opacity, max(0, limit))
    }

    public static func maximumLuminance(in palette: [LiquidBackdropColor]) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return palette.map {
            0.2126 * linear($0.red) + 0.7152 * linear($0.green) + 0.0722 * linear($0.blue)
        }.max() ?? 0
    }
}

/// 从封面小图里挑出几个代表色:主色、鲜艳色、亮鲜艳、暗鲜艳、柔和色、亮柔和、暗柔和。
/// 只在换歌、封面变了的时候算一次，Mesh 与流动色彩共用调色板。
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
    /// - Returns: 1…7 个颜色,主色在最前;像素太少时返回空数组。纯色封面保留原色。
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
        return distinct
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

/// 播放页进度条的「封面取色」:从封面代表色里挑两三种色相分得开的,按播放页的深浅底调到看得清,
/// 从起点到播放头排成渐变,播放头那头是封面主色。只在换歌、改设置、换深浅外观时算一次。
public enum ProgressArtworkGradientPolicy {
    /// 最多用几种颜色。一条几点粗的线上再多就看不出层次,只显得花。
    public static let maximumStops = 3
    /// 饱和度、色度低于这个的封面色当作黑白灰,不拿来上色。
    public static let minimumSaturation = 0.2
    public static let minimumChroma = 0.08
    /// 两种颜色的色相至少差这么多(一圈为 1)才算两种。
    public static let minimumHueDistance = 0.06
    /// 封面只有一种彩色时,配一个色相挨着的颜色,渐变照样看得出走向。
    public static let companionHueShift = 0.08
    /// 深色底上每种颜色的相对亮度下限:细线对播放页的深色背景约 3:1 以上。
    public static let minimumLuminanceOnDarkBackdrop = 0.2
    /// 浅色底上每种颜色的相对亮度上限:细线对浅色背景约 3:1 以上。
    public static let maximumLuminanceOnLightBackdrop = 0.22

    /// - Parameter palette: 封面代表色,主色在最前(`LiquidBackdropPalettePolicy.palette` 的结果)。
    /// - Returns: 从起点到播放头的颜色,最后一个是主色;封面没有彩色时为空,调用方照旧用单色。
    public static func stops(from palette: [LiquidBackdropColor], onDarkBackdrop: Bool) -> [LiquidBackdropColor] {
        var selected: [LiquidBackdropColor] = []
        for color in palette where isChromatic(color) {
            let hue = color.hsl.hue
            guard selected.allSatisfy({ hueDistance($0.hsl.hue, hue) >= minimumHueDistance }) else { continue }
            selected.append(color)
            if selected.count == maximumStops { break }
        }
        guard let primary = selected.first else { return [] }
        if selected.count == 1 {
            let hsl = primary.hsl
            selected.append(LiquidBackdropColor(
                hue: hsl.hue + companionHueShift,
                saturation: hsl.saturation,
                lightness: hsl.lightness
            ))
        }
        return selected.map { toned($0, onDarkBackdrop: onDarkBackdrop) }.reversed()
    }

    static func isChromatic(_ color: LiquidBackdropColor) -> Bool {
        let chroma = max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
        return color.hsl.saturation >= minimumSaturation && chroma >= minimumChroma
    }

    /// 色相跟封面,明暗按底色调:深色底提亮到够亮,浅色底压暗到够深,饱和度保底,免得发灰。
    static func toned(_ color: LiquidBackdropColor, onDarkBackdrop: Bool) -> LiquidBackdropColor {
        let hsl = color.hsl
        if onDarkBackdrop {
            let start = LiquidBackdropColor(
                hue: hsl.hue,
                saturation: min(max(hsl.saturation, 0.55), 0.95),
                lightness: min(max(hsl.lightness, 0.55), 0.72)
            )
            return lightened(start, toLuminance: minimumLuminanceOnDarkBackdrop)
        }
        let start = LiquidBackdropColor(
            hue: hsl.hue,
            saturation: max(hsl.saturation, 0.6),
            lightness: min(max(hsl.lightness, 0.3), 0.48)
        )
        return darkened(start, toLuminance: maximumLuminanceOnLightBackdrop)
    }

    public static func relativeLuminance(_ color: LiquidBackdropColor) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private static func hueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let distance = abs(lhs - rhs).truncatingRemainder(dividingBy: 1)
        return min(distance, 1 - distance)
    }

    /// 往白色混到相对亮度刚好够下限;已经够了原样返回。
    private static func lightened(_ color: LiquidBackdropColor, toLuminance floor: Double) -> LiquidBackdropColor {
        guard relativeLuminance(color) < floor else { return color }
        let white = LiquidBackdropColor(red: 1, green: 1, blue: 1)
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if relativeLuminance(color.mixed(with: white, amount: mid)) >= floor { high = mid } else { low = mid }
        }
        return color.mixed(with: white, amount: high)
    }

    /// 等比压暗(色相、饱和度不变)到相对亮度刚好不超过上限;已经够暗原样返回。
    private static func darkened(_ color: LiquidBackdropColor, toLuminance ceiling: Double) -> LiquidBackdropColor {
        guard relativeLuminance(color) > ceiling else { return color }
        var low = 0.0
        var high = 1.0
        func scaled(_ factor: Double) -> LiquidBackdropColor {
            LiquidBackdropColor(red: color.red * factor, green: color.green * factor, blue: color.blue * factor)
        }
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if relativeLuminance(scaled(mid)) <= ceiling { low = mid } else { high = mid }
        }
        return scaled(low)
    }
}

/// 进度条「水流」动效的柔光:播放过的那段里一串等距的亮带朝播放头平移,像管子里流动的水面反光。
/// 两层间距、速度不同的亮带叠在一起,看着不像一格一格的传送带。整串平移一个周期后和开头接得上,
/// 动画只是一条无限重复的平移,交给合成层去跑。
public enum ProgressFlowPattern {
    public struct Layer: Equatable, Sendable {
        /// 相邻两道亮带隔多少点。
        public var period: Double
        /// 每秒往播放头走多少点。
        public var speed: Double
        /// 亮带最亮处的不透明度。
        public var peakOpacity: Double

        /// 走完一个周期要的秒数。
        public var duration: Double { period / speed }
    }

    public struct Stop: Equatable, Sendable {
        /// 0…1,整串亮带从头到尾。
        public var location: Double
        /// 0…1,乘到这一层的 `peakOpacity` 上。
        public var opacity: Double
    }

    public static let layers: [Layer] = [
        Layer(period: 96, speed: 60, peakOpacity: 0.42),
        Layer(period: 58, speed: 34, peakOpacity: 0.22),
    ]

    /// 一个周期里亮带的样子:两头透明,中间一道柔和的亮峰。
    public static let band: [Stop] = [
        Stop(location: 0, opacity: 0),
        Stop(location: 0.28, opacity: 0),
        Stop(location: 0.42, opacity: 0.55),
        Stop(location: 0.5, opacity: 1),
        Stop(location: 0.58, opacity: 0.55),
        Stop(location: 0.72, opacity: 0),
        Stop(location: 1, opacity: 0),
    ]

    /// 盖住整条轨道、平移时还不露底要排几个周期:轨道宽度向上取整再多一个。
    public static func periodCount(trackWidth: Double, period: Double) -> Int {
        guard period > 0, trackWidth.isFinite, trackWidth > 0 else { return 1 }
        return Int((trackWidth / period).rounded(.up)) + 1
    }

    /// 排 `count` 个周期时的全部色标。相邻周期首尾那两个透明色标位置相同,只留一个。
    public static func stops(periodCount count: Int) -> [Stop] {
        let count = max(1, count)
        var result: [Stop] = []
        result.reserveCapacity(count * (band.count - 1) + 1)
        for index in 0..<count {
            for (offset, stop) in band.enumerated() where offset < band.count - 1 || index == count - 1 {
                result.append(Stop(location: (Double(index) + stop.location) / Double(count), opacity: stop.opacity))
            }
        }
        return result
    }
}

/// 进度条「呼吸」动效:播放过的那段连同外面一圈光慢慢亮起、收淡。合成层用一条往返的缓入缓出动画,
/// 逐帧画的波浪用 `level(at:)` 取同样的起伏。
public enum ProgressBreathPolicy {
    /// 一呼一吸的秒数,约每分钟 16 次,和人放松时的呼吸差不多。
    public static let cycle: Double = 3.6
    /// 光晕不透明度的低点与高点(深色外观);浅色外观整体乘 `lightAppearanceScale`,免得像一道脏阴影。
    public static let haloOpacity: ClosedRange<Double> = 0.12...0.9
    public static let lightAppearanceScale = 0.5
    public static let haloRadius: ClosedRange<Double> = 3...10
    /// 进度条本身跟着轻轻明暗。
    public static let fillOpacity: ClosedRange<Double> = 0.75...1

    /// 某一时刻在一呼一吸里的位置:0 最暗,1 最亮,两头缓。
    public static func level(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        let phase = time.truncatingRemainder(dividingBy: cycle) / cycle
        return 0.5 - 0.5 * cos(phase * 2 * Double.pi)
    }

    public static func interpolate(_ range: ClosedRange<Double>, _ level: Double) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * min(max(level, 0), 1)
    }
}

/// 背景选了「自定义颜色」时，用这一个颜色排出的代表色，排法和从封面挑出来的一样：主色在最前，
/// 后面几种明暗、相邻色相各不相同。这样流动色彩和 Mesh 还有层次，不会糊成一整块纯色。
public enum CustomBackdropPalettePolicy {
    /// 相邻色相离主色多远(一圈为 1)。小到看着还是同一种颜色，大到几团光分得出来。
    public static let companionHueShift = 0.05

    public static func palette(for color: LiquidBackdropColor) -> [LiquidBackdropColor] {
        let hsl = color.hsl
        func tone(hueShift: Double, saturationScale: Double, lightnessShift: Double) -> LiquidBackdropColor {
            LiquidBackdropColor(
                hue: hsl.hue + hueShift,
                saturation: min(max(hsl.saturation * saturationScale, 0), 1),
                lightness: min(
                    max(hsl.lightness + lightnessShift, LiquidBackdropPalettePolicy.minimumLightness),
                    LiquidBackdropPalettePolicy.maximumLightness
                )
            )
        }
        let candidates = [
            tone(hueShift: 0, saturationScale: 1, lightnessShift: 0),
            tone(hueShift: companionHueShift, saturationScale: 1, lightnessShift: 0.12),
            tone(hueShift: -companionHueShift, saturationScale: 1, lightnessShift: -0.14),
            tone(hueShift: 0, saturationScale: 0.6, lightnessShift: 0.22),
            tone(hueShift: companionHueShift * 2, saturationScale: 0.85, lightnessShift: -0.04),
        ]
        var palette: [LiquidBackdropColor] = []
        for candidate in candidates where !palette.contains(candidate) { palette.append(candidate) }
        return palette
    }
}
