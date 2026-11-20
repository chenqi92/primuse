import Foundation

/// macOS 26 起「系统设置 › 外观 › 图标与小组件样式」里的样式。
public enum AppIconStyle: String, Sendable, CaseIterable {
    /// 默认、深色
    case regular = "Regular"
    /// 透明
    case clear = "Clear"
    /// 色调
    case tinted = "Tinted"
}

/// 备选图标该用哪一版 Dock 图。
public struct AppIconAppearance: Equatable, Sendable {
    public var style: AppIconStyle
    public var isDark: Bool

    public init(style: AppIconStyle, isDark: Bool) {
        self.style = style
        self.isDark = isDark
    }

    /// 资源名后缀：RegularLight、ClearDark、TintedLight……
    public var assetSuffix: String { style.rawValue + (isDark ? "Dark" : "Light") }

    public static let standard = AppIconAppearance(style: .regular, isDark: false)
}

/// 着色系数图的定点编码范围（由生成脚本写进 `AppIconTintTable`）。
public struct AppIconTintMapRange: Equatable, Sendable {
    public var aLow: Double
    public var aHigh: Double
    public var bLow: Double
    public var bHigh: Double

    public init(aLow: Double, aHigh: Double, bLow: Double, bHigh: Double) {
        self.aLow = aLow
        self.aHigh = aHigh
        self.bLow = bLow
        self.bHigh = bHigh
    }
}

/// 备选图标跟随系统图标样式。
///
/// 包里的默认图标由系统按样式显示；备选图标只能在运行时盖到 Dock 上，系统不替它换外观，
/// 所以 App 自己读系统设置写在全局偏好里的样式，换上预先渲染好的那一版。着色版随用户选的
/// 颜色变化，用「A + B × T」合成：A、B 是每款图标的系数图，T 由颜色查 `AppIconTintTable` 得到。
public enum AppIconStylePolicy {
    /// 系统设置写在全局偏好里的键，App 只读。
    public static let themeKey = "AppleIconAppearanceTheme"
    public static let tintColorKey = "AppleIconAppearanceTintColor"
    public static let customTintColorKey = "AppleIconAppearanceCustomTintColor"

    /// - Parameters:
    ///   - theme: `AppleIconAppearanceTheme` 原值，如 `TintedAutomatic`；没改过样式时没有这个键。
    ///   - systemIsDark: 系统（不是 App 自己的明暗设置）当前是不是深色，样式选「自动」时用。
    public static func appearance(theme: String?, systemIsDark: Bool) -> AppIconAppearance {
        guard let theme, let style = AppIconStyle.allCases.first(where: { theme.hasPrefix($0.rawValue) }) else {
            return .standard
        }
        switch theme.dropFirst(style.rawValue.count) {
        case "Light": return AppIconAppearance(style: style, isDark: false)
        case "Dark": return AppIconAppearance(style: style, isDark: true)
        default: return AppIconAppearance(style: style, isDark: systemIsDark)
        }
    }

    /// 着色用的颜色从哪来。
    public enum TintSource: Equatable, Sendable {
        /// 系统给的颜色名：Red、Orange、Yellow、Green、Blue、Purple、Pink、Graphite。
        case named(String)
        /// 「其他」里自己挑的颜色，sRGB 0...1。
        case custom(red: Double, green: Double, blue: Double)
        /// 没单独选，跟强调色。
        case accent
    }

    public static func tintSource(name: String?, custom: String?) -> TintSource {
        guard let name, !name.isEmpty else { return .accent }
        if name == "Other" {
            guard let rgb = customTintComponents(custom) else { return .accent }
            return .custom(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        return .named(name)
    }

    /// 自选颜色存成 `"r g b a"`（0...1，空格分隔）。
    public static func customTintComponents(_ raw: String?) -> (red: Double, green: Double, blue: Double)? {
        guard let raw else { return nil }
        let values = raw.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard values.count >= 3, values.prefix(3).allSatisfy({ $0.isFinite }) else { return nil }
        let clamp = { (value: Double) in min(max(value, 0), 1) }
        return (clamp(values[0]), clamp(values[1]), clamp(values[2]))
    }

    /// 把系统着色颜色（sRGB 0...1）换算成颜色表里的 T。
    ///
    /// ictool 的着色参数是「色相 × 强度」，色相刻度和常说的色相不是一回事，所以先按颜色表里
    /// 每个网格色相实际画出来的色相反查，再按饱和度当强度，在表里双线性插值。
    ///
    /// ictool 的强度调到 0 也还带着色相，石墨这类近乎灰的颜色在表里查不到中性灰；饱和度低于
    /// `neutralSaturation` 时按比例把 T 收拢到灰（A、B 三个通道共用，T 是灰的图就是灰的）。
    /// 灰的亮度取这个强度下各色相的平均，不然灰里带一点蓝就会按蓝色那格的亮度，深色下图形发暗。
    public static func tintFactor(red: Double, green: Double, blue: Double, isDark: Bool) -> (Double, Double, Double) {
        let (hue, saturation) = hueSaturation(red: red, green: green, blue: blue)
        let value = tintFactor(gridHue: gridHue(forDisplayHue: hue), strength: saturation, isDark: isDark)
        let chroma = min(saturation / neutralSaturation, 1)
        let gray = neutralLevel(strength: saturation, isDark: isDark)
        return (gray + (value.0 - gray) * chroma, gray + (value.1 - gray) * chroma, gray + (value.2 - gray) * chroma)
    }

    static let neutralSaturation = 0.25

    static func neutralLevel(strength: Double, isDark: Bool) -> Double {
        let hues = AppIconTintTable.hues
        let total = hues.reduce(0.0) { sum, hue in
            let value = tintFactor(gridHue: hue, strength: strength, isDark: isDark)
            return sum + 0.299 * value.0 + 0.587 * value.1 + 0.114 * value.2
        }
        return total / Double(hues.count)
    }

    static func tintFactor(gridHue: Double, strength: Double, isDark: Bool) -> (Double, Double, Double) {
        let table = isDark ? AppIconTintTable.dark : AppIconTintTable.light
        let hueCount = AppIconTintTable.hues.count
        let strengths = AppIconTintTable.strengths
        let position = (gridHue - gridHue.rounded(.down)) * Double(hueCount)
        let h0 = Int(position.rounded(.down)) % hueCount
        let h1 = (h0 + 1) % hueCount
        let hueFraction = position - position.rounded(.down)
        let clamped = min(max(strength, strengths[0]), strengths[strengths.count - 1])
        var s0 = 0
        while s0 + 2 < strengths.count, clamped > strengths[s0 + 1] { s0 += 1 }
        let s1 = s0 + 1
        let strengthFraction = (clamped - strengths[s0]) / (strengths[s1] - strengths[s0])
        func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
            zip(a, b).map { $0 + ($1 - $0) * t }
        }
        let low = mix(table[s0][h0], table[s0][h1], hueFraction)
        let high = mix(table[s1][h0], table[s1][h1], hueFraction)
        let value = mix(low, high, strengthFraction)
        return (value[0], value[1], value[2])
    }

    /// 实际色相 → 网格色相（0..<1）。`displayHues` 是首尾相接的一圈，按圈展开后线性反查。
    static func gridHue(forDisplayHue hue: Double) -> Double {
        let display = AppIconTintTable.displayHues
        let count = display.count
        var unwrapped = [display[0]]
        for value in display.dropFirst() {
            var next = value
            while next < unwrapped[unwrapped.count - 1] { next += 1 }
            unwrapped.append(next)
        }
        unwrapped.append(display[0] + 1)
        var target = hue - hue.rounded(.down)
        while target < unwrapped[0] { target += 1 }
        while target >= unwrapped[0] + 1 { target -= 1 }
        var index = 0
        while index + 1 < count, target >= unwrapped[index + 1] { index += 1 }
        let span = unwrapped[index + 1] - unwrapped[index]
        let fraction = span > 0 ? (target - unwrapped[index]) / span : 0
        let grid = (Double(index) + fraction) / Double(count)
        return grid - grid.rounded(.down)
    }

    static func hueSaturation(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let delta = high - low
        guard high > 0, delta > 0 else { return (0, 0) }
        var hue: Double
        if high == red {
            hue = (green - blue) / delta
        } else if high == green {
            hue = 2 + (blue - red) / delta
        } else {
            hue = 4 + (red - green) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / high)
    }

    public static func tintMapRange(isDark: Bool) -> AppIconTintMapRange {
        isDark ? AppIconTintTable.darkRange : AppIconTintTable.lightRange
    }

    /// 合成着色图。`map` 每像素依次是 A、B、透明度（各 8 位定点），输出预乘的 RGBA。
    public static func composeTinted(
        map: [UInt8],
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int,
        tint: (Double, Double, Double),
        range: AppIconTintMapRange
    ) -> [UInt8] {
        precondition(bytesPerPixel >= 3 && bytesPerRow >= width * bytesPerPixel)
        precondition(map.count >= bytesPerRow * (height - 1) + width * bytesPerPixel)
        var output = [UInt8](repeating: 0, count: width * height * 4)
        let aScale = (range.aHigh - range.aLow) / 255
        let bScale = (range.bHigh - range.bLow) / 255
        let tints = [tint.0, tint.1, tint.2]
        map.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                for y in 0..<height {
                    for x in 0..<width {
                        let input = y * bytesPerRow + x * bytesPerPixel
                        let alpha = Double(source[input + 2]) / 255
                        let out = (y * width + x) * 4
                        target[out + 3] = source[input + 2]
                        guard alpha > 0 else { continue }
                        let a = range.aLow + Double(source[input]) * aScale
                        let b = range.bLow + Double(source[input + 1]) * bScale
                        for channel in 0..<3 {
                            let value = min(max(a + b * tints[channel], 0), alpha)
                            target[out + channel] = UInt8((value * 255).rounded())
                        }
                    }
                }
            }
        }
        return output
    }
}
