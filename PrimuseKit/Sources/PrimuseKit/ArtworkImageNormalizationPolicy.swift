import Foundation

/// 把用户挑来的图片压成一张「JPEG 一定写得出来」的位图时，需要的纯计算部分。
///
/// 封面存进内容池前统一转成 JPEG，而 JPEG 的表达能力比相册里可能出现的图窄得多：
/// 没有 alpha 通道，也放不下 16 bit / 浮点分量和 CMYK 这类色彩模型。ImageIO 在
/// 这些输入上不会给出错误，它要么直接让 `CGImageDestinationFinalize` 返回 false，
/// 要么把透明区域压成黑块 —— 两种结果在界面上都表现为「这张图选了没反应」。
///
/// 所以编码前先判断要不要重画一遍，以及重画成多大、要不要按 EXIF 摆正。这里只做
/// 判断与算术，CoreGraphics 的位图操作留在 app 层。
public enum ArtworkImageNormalizationPolicy {

    /// 长边收进 `longSide` 的方框，等比缩放。
    ///
    /// **不放大**：一张 300×300 的图在 1200 的方框里仍然是 300×300。放大既不会
    /// 增加细节，又会让 JPEG 体积凭空翻几倍，把本来能过的图顶到容量上限之外。
    ///
    /// 返回 nil 表示输入尺寸本身不合法（0 或负数），调用方应当换下一档或放弃。
    public static func boundedPixelSize(
        width: Int,
        height: Int,
        longSide: Int
    ) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, longSide > 0 else { return nil }
        let longest = max(width, height)
        guard longest > longSide else { return (width, height) }
        let scale = Double(longSide) / Double(longest)
        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }

    /// 这张位图能不能直接交给 JPEG 编码器，还是得先重画成不透明的 8 bit RGB。
    ///
    /// 四种都要重画：带 alpha（JPEG 没有这个通道）、分量不是 8 bit、浮点分量
    /// （HDR / 宽色域源常见）、色彩模型不是灰度或 RGB（CMYK、Lab、索引色）。
    public static func requiresOpaqueRedraw(
        hasAlpha: Bool,
        bitsPerComponent: Int,
        usesFloatComponents: Bool,
        isJPEGCompatibleColorModel: Bool
    ) -> Bool {
        hasAlpha
            || bitsPerComponent != 8
            || usesFloatComponents
            || !isJPEGCompatibleColorModel
    }

    /// 把图摆正需要的旋转与镜像。
    ///
    /// 约定是**先水平镜像，再顺时针旋转** `quarterTurnsClockwise` 个 90°。
    /// EXIF 的 8 个取值都能这么拆；越界或缺失的值按 1（不用动）处理，因为
    /// 一张摆正失败的图也比一张不显示的图有用。
    ///
    /// 注意 CoreGraphics 的变换是后写的先作用，所以调用方要先 `rotate` 再
    /// `scaleBy(x: -1, y: 1)`，顺序和这里的语义正好相反。
    public static func orientationSteps(
        forExif value: Int
    ) -> (quarterTurnsClockwise: Int, mirroredHorizontally: Bool) {
        switch value {
        case 2: return (0, true)   // 水平镜像
        case 3: return (2, false)  // 旋转 180°
        case 4: return (2, true)   // 垂直镜像 = 180° + 水平镜像
        case 5: return (3, true)   // 主对角线翻转
        case 6: return (1, false)  // 顺时针 90°
        case 7: return (1, true)   // 副对角线翻转
        case 8: return (3, false)  // 顺时针 270°
        default: return (0, false)
        }
    }

    /// 摆正后宽高是否互换。5…8 这四个取值带奇数次 90° 旋转。
    public static func swapsDimensions(forExif value: Int) -> Bool {
        orientationSteps(forExif: value).quarterTurnsClockwise % 2 == 1
    }
}
