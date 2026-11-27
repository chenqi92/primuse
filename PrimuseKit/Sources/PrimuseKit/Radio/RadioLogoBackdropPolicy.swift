import Foundation

/// 台标背后那块纯色衬底的颜色，0...1 的 sRGB 分量。
///
/// 刻意不用平台颜色类型：取色规则要能在没有图形栈的地方直接跑测试。
public struct RadioLogoBackdrop: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// 有台标时背后垫什么颜色。
///
/// 默认台标是渐变加同心环的“广播信号”图案。台标一旦带透明通道，或者调用方按
/// `.fit` 摆放（台标不是正方形，两侧留白），那个图案就从台标后面透出来，看着
/// 像两张图叠在一起。所以有台标时不再画占位图，改垫一块由台标自己定的纯色。
public enum RadioLogoBackdropPolicy {
    /// 取样边长。只为判色，24×24 已经够；再大只是白跑一遍缩放。
    public static let sampleSide = 24

    public static let light = RadioLogoBackdrop(red: 0.96, green: 0.96, blue: 0.97)
    public static let dark = RadioLogoBackdrop(red: 0.11, green: 0.11, blue: 0.12)

    /// 高于这个 alpha 才算“这一格是实心的”。
    private static let opaqueAlpha = 0.9
    /// 低于这个 alpha 的格子不参与亮度统计：抗锯齿边缘的颜色不代表台标本身。
    private static let visibleAlpha = 0.5
    /// 最外一圈里实心格子占到这个比例，就认定整张图是不透明的。
    private static let opaqueBorderRatio = 0.9
    /// Rec.709 亮度低于此值算深色台标。
    private static let darkLogoLuminance = 0.55

    /// - Parameter pixels: RGBA8、预乘 alpha、行优先，长度应为 `width * height * 4`。
    public static func backdrop(pixels: [UInt8], width: Int, height: Int) -> RadioLogoBackdrop {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return light }

        // 不透明的图直接取最外一圈的平均色：`.fit` 留出来的边与图片边缘无缝
        // 衔接，`.fill` 时衬底本来也看不见，两种摆法都不会露馅。
        if let edge = opaqueEdgeColor(pixels: pixels, width: width, height: height) {
            return edge
        }
        return contrastingBackdrop(pixels: pixels, width: width, height: height)
    }

    // MARK: - 不透明图：取最外一圈

    private static func opaqueEdgeColor(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> RadioLogoBackdrop? {
        var total = 0.0
        var opaque = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0

        forEachEdgePixel(width: width, height: height) { index in
            let base = index * 4
            let alpha = Double(pixels[base + 3]) / 255.0
            total += 1
            guard alpha > opaqueAlpha else { return }
            opaque += 1
            red += unpremultiplied(pixels[base], alpha: alpha)
            green += unpremultiplied(pixels[base + 1], alpha: alpha)
            blue += unpremultiplied(pixels[base + 2], alpha: alpha)
        }

        guard total > 0, opaque > 0, opaque / total >= opaqueBorderRatio else { return nil }
        return RadioLogoBackdrop(
            red: clamped(red / opaque),
            green: clamped(green / opaque),
            blue: clamped(blue / opaque)
        )
    }

    // MARK: - 透明底台标：按亮度反衬

    private static func contrastingBackdrop(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> RadioLogoBackdrop {
        var sum = 0.0
        var count = 0.0

        for index in 0..<(width * height) {
            let base = index * 4
            let alpha = Double(pixels[base + 3]) / 255.0
            guard alpha > visibleAlpha else { continue }
            let red = unpremultiplied(pixels[base], alpha: alpha)
            let green = unpremultiplied(pixels[base + 1], alpha: alpha)
            let blue = unpremultiplied(pixels[base + 2], alpha: alpha)
            sum += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            count += 1
        }

        guard count > 0 else { return light }
        let luminance = sum / count
        guard luminance.isFinite else { return light }
        return luminance < darkLogoLuminance ? light : dark
    }

    // MARK: - 取样细节

    /// 最外一圈：首尾两行整行，中间各行只有首尾两格。
    private static func forEachEdgePixel(width: Int, height: Int, _ body: (Int) -> Void) {
        for y in 0..<height {
            let rowStart = y * width
            if y == 0 || y == height - 1 {
                for x in 0..<width { body(rowStart + x) }
            } else {
                body(rowStart)
                if width > 1 { body(rowStart + width - 1) }
            }
        }
    }

    private static func unpremultiplied(_ value: UInt8, alpha: Double) -> Double {
        guard alpha > 0 else { return 0 }
        let straight = Double(value) / 255.0 / alpha
        guard straight.isFinite else { return 0 }
        return clamped(straight)
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
