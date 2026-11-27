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

    // MARK: - 元数据与结果校验

    /// 去掉 JPEG 里描述性的元数据段，像素数据原样保留。
    ///
    /// 网图被反复缩放、另存后，EXIF 里的尺寸常常和真实像素对不上（300×300 的图
    /// 写着 3745×3745），还可能有两段 EXIF、截断的内嵌缩略图。真机上的 ImageIO
    /// 生成缩略图时会参考这些信息，结果是整张图退化成一块纯色，而模拟器和 Mac
    /// 上完全正常。剥掉之后解码器只能按 SOF 里的真实尺寸来。
    ///
    /// 保留 APP0 (JFIF)、APP2 (ICC 色彩配置) 和 APP14 (Adobe 色彩变换标记)，
    /// 后两者决定颜色怎么解释，去掉会偏色；其余 APPn 与注释段都丢弃。方向信息
    /// 只在 EXIF 里，调用方要在剥之前自己读出来。
    ///
    /// 不是 JPEG、结构读不通、或者本来就没有可剥的段时返回 nil，调用方照用原数据。
    public static func strippingJPEGMetadata(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var output: [UInt8] = [0xFF, 0xD8]
        output.reserveCapacity(bytes.count)
        var index = 2
        var removedAny = false
        while index < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            var markerIndex = index + 1
            // 段之间允许填充 0xFF。
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < bytes.count else { return nil }
            let marker = bytes[markerIndex]
            // 独立标记没有长度字段；扫描开始之前出现 EOI 说明文件是坏的。
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                output.append(contentsOf: [0xFF, marker])
                index = markerIndex + 1
                continue
            }
            guard marker != 0xD9, markerIndex + 2 < bytes.count else { return nil }
            let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
            let segmentEnd = markerIndex + 1 + length
            guard length >= 2, segmentEnd <= bytes.count else { return nil }
            if marker == 0xDA {
                // SOS 之后是熵编码数据，连同后面的全部原样照抄。
                output.append(contentsOf: [0xFF, marker])
                output.append(contentsOf: bytes[(markerIndex + 1)...])
                break
            }
            let isDescriptive = (0xE0...0xEF).contains(marker) || marker == 0xFE
            let isKept = marker == 0xE0 || marker == 0xE2 || marker == 0xEE
            if isDescriptive && !isKept {
                removedAny = true
            } else {
                output.append(contentsOf: [0xFF, marker])
                output.append(contentsOf: bytes[(markerIndex + 1)..<segmentEnd])
            }
            index = segmentEnd
        }
        guard removedAny, output.count > 2 else { return nil }
        return Data(output)
    }

    /// 解出来的位图是不是预期的大小。允许 1 像素的取整误差。
    ///
    /// 预期大小由 SOF 里的真实像素尺寸算出；缩略图接口给的结果对不上，就说明它
    /// 参考了别的信息（EXIF 尺寸、内嵌缩略图），这张结果不能用。
    public static func matchesExpectedSize(
        width: Int,
        height: Int,
        expected: (width: Int, height: Int)
    ) -> Bool {
        abs(width - expected.width) <= 1 && abs(height - expected.height) <= 1
    }

    /// 抽样亮度几乎没有起伏 —— 整张图退化成一块纯色时的样子。
    ///
    /// 只拿来决定「换一条路再解一次」：真正的纯色图两条路结果一样，照样收下。
    public static func looksUniform(minimumLuma: Int, maximumLuma: Int) -> Bool {
        maximumLuma - minimumLuma <= 2
    }
}
