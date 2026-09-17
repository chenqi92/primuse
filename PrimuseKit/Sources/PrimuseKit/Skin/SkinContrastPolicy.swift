import Foundation

/// 固定色值样式的可读性校验。
///
/// 经典样式映射到系统语义色,可读性由系统负责。自定义样式用的是写死的色值,
/// 「次要文字压在底色上看不清」这种问题要到真机、某个特定亮度下才会被人注意到 ——
/// 所以在这里按 WCAG 的相对亮度公式算出来,写成本机可跑的断言。
public enum SkinContrastPolicy {
    public enum Scheme: String, Sendable, CaseIterable { case light, dark }

    public struct Finding: Sendable, Equatable {
        public let skinID: String
        public let scheme: Scheme
        public let foreground: SkinColorToken
        public let background: SkinColorToken
        public let ratio: Double
        public let required: Double
    }

    /// 要检查的前景/背景组合与各自的下限。
    ///
    /// 主文字取增强对比度(7),次要文字按正文标准(4.5)。第三级是时长、计数、格式这类
    /// 辅助信息,但它们常常是 11–13pt 的小字,所以不按装饰元素放宽,取 WCAG 对图形与
    /// 大字号的下限 3.0。
    public static let requirements: [(SkinColorToken, SkinColorToken, Double)] = [
        (.textPrimary, .canvas, 7.0),
        (.textPrimary, .canvasGlow, 7.0),
        (.textPrimary, .canvasElevated, 7.0),
        (.textSecondary, .canvas, 4.5),
        (.textSecondary, .canvasGlow, 4.5),
        (.textSecondary, .canvasElevated, 4.5),
        (.textTertiary, .canvas, 3.0),
        (.textTertiary, .canvasGlow, 3.0),
        (.textTertiary, .canvasElevated, 3.0),
        (.chromeItem, .canvas, 4.5),
        (.danger, .canvas, 3.0),
        (.success, .canvas, 3.0),
        (.warning, .canvas, 3.0),
    ]

    /// 只检查两侧都能解析成固定色值的组合;跟随系统或跟随主题色的色位无从计算,跳过。
    public static func findings(in skin: SkinDefinition) -> [Finding] {
        var findings: [Finding] = []
        for scheme in Scheme.allCases {
            for (foreground, background, required) in requirements {
                guard let bottom = opaqueColor(skin.colors[background], scheme: scheme),
                      let top = color(skin.colors[foreground], scheme: scheme) else {
                    continue
                }
                let composited = top.composited(over: bottom)
                let ratio = contrastRatio(composited, bottom)
                if ratio + 0.005 < required {
                    findings.append(
                        Finding(
                            skinID: skin.id,
                            scheme: scheme,
                            foreground: foreground,
                            background: background,
                            ratio: ratio,
                            required: required
                        )
                    )
                }
            }
        }
        return findings
    }

    // MARK: - 计算

    struct RGBA: Sendable, Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        func composited(over background: RGBA) -> RGBA {
            RGBA(
                red: red * alpha + background.red * (1 - alpha),
                green: green * alpha + background.green * (1 - alpha),
                blue: blue * alpha + background.blue * (1 - alpha),
                alpha: 1
            )
        }
    }

    static func color(_ spec: SkinColorSpec?, scheme: Scheme) -> RGBA? {
        guard case .fixed(let light, let dark)? = spec else { return nil }
        let value = scheme == .dark ? dark : light
        return RGBA(red: value.red, green: value.green, blue: value.blue, alpha: value.opacity)
    }

    /// 背景必须不透明才有确定的亮度。
    static func opaqueColor(_ spec: SkinColorSpec?, scheme: Scheme) -> RGBA? {
        guard let color = color(spec, scheme: scheme), color.alpha >= 0.999 else { return nil }
        return color
    }

    static func relativeLuminance(_ color: RGBA) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    static func contrastRatio(_ first: RGBA, _ second: RGBA) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
