import CoreGraphics
import Foundation
import ImageIO
import PrimuseKit
import SwiftDraw
import UniformTypeIdentifiers

/// 把矢量台标栅格化成位图。
///
/// ImageIO 没有 SVG 解码器，而电台清单里的 `tvg-logo` 相当一部分是 SVG。
/// 走一遍 SwiftDraw 把它画成位图，后面的缓存、降采样、锁屏与车机就全都照旧。
///
/// 全程只用 CoreGraphics，不碰 UIKit/AppKit —— 解码跑在协作线程池上，
/// SwiftDraw 自带的 `rasterize()` 入口会用到 `UIGraphicsImageRenderer`
/// 和 `NSScreen.main`，那是主线程的东西。
enum SVGArtworkRasterizer {
    /// 单张台标的像素上限。矢量图放多大都"清晰"，但内存不是无限的。
    private static let maximumRenderedPixels = 4_096 * 4_096

    /// 按 `maximumPixelSize` 的方框等比画出位图。
    ///
    /// 矢量图放大不掉细节，所以这里是「缩放到方框」而不是「只缩不放」：
    /// 一张 16×16 的图标放进封面格也不该是糊的。
    static func makeCGImage(from data: Data, maximumPixelSize: Int) -> CGImage? {
        guard SVGImageSupport.looksLikeSVG(data),
              let svg = SwiftDraw.Image(data: data) else { return nil }

        let intrinsic = svg.size
        guard intrinsic.width > 0, intrinsic.height > 0 else { return nil }
        let box = CGFloat(max(maximumPixelSize, 1))
        let factor = box / max(intrinsic.width, intrinsic.height)
        let width = max(Int((intrinsic.width * factor).rounded()), 1)
        let height = max(Int((intrinsic.height * factor).rounded()), 1)
        guard width * height <= maximumRenderedPixels else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // SwiftDraw 的命令流按左上角原点绘制(它自己的 UIKit / AppKit 入口拿到的
        // 都是翻转过的上下文)，而裸 CGContext 是左下角原点 —— 不翻这一下，
        // 画出来的台标是上下颠倒的。
        context.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
        context.draw(svg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }

    /// 栅格化成 PNG 字节。
    ///
    /// 台标在磁盘缓存里存成位图而不是原始 SVG 是有意的：这份缓存还要被
    /// 电视端、小组件、锁屏读到，而它们没有矢量解析器。
    static func pngData(from data: Data, maximumPixelSize: Int) -> Data? {
        guard let image = makeCGImage(from: data, maximumPixelSize: maximumPixelSize) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }
}
