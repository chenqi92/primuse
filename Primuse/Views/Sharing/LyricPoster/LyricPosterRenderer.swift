import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import PrimuseKit

/// 把风格视图变成像素。
///
/// 全部走 `ImageRenderer`: 海报的画布是固定的 1080 宽设计稿, 跟屏幕尺寸、
/// 安全区、深浅色都无关, 用离屏渲染才能保证每台设备导出的是同一张图。
@MainActor
enum LyricPosterRenderer {
    /// 海报视图。预览和导出必须走同一个入口, 否则"所见"和"所存"会分叉。
    static func makeView(
        style: any LyricPosterStyleRendering,
        context: LyricPosterRenderContext
    ) -> AnyView {
        AnyView(
            style.makeBody(context: context)
                .frame(width: context.size.width, height: context.size.height)
                // 风格内部用了 plusLighter / overlay 混合(光晕、颗粒)。不圈一层
                // 合成组, 这些混合会算到海报外面的底色上 —— 预览里混进 sheet
                // 背景, 导出时混进渲染器底色, 两边还不一样。
                .compositingGroup()
                .environment(\.colorScheme, style.descriptor.prefersDarkChrome ? .dark : .light)
                // 海报是定死的版面, 不跟随系统字号 —— 动态字体会把精心算好的
                // 行数顶出画布。
                .environment(\.dynamicTypeSize, .large)
                .environment(\.layoutDirection, context.layoutDirection)
        )
    }

    static func renderImage(
        style: any LyricPosterStyleRendering,
        context: LyricPosterRenderContext,
        scale: CGFloat = 1
    ) -> PlatformImage? {
        let renderer = makeRenderer(style: style, context: context, scale: scale)
        #if os(iOS)
        return renderer.uiImage
        #else
        return renderer.nsImage
        #endif
    }

    static func renderCGImage(
        style: any LyricPosterStyleRendering,
        context: LyricPosterRenderContext,
        scale: CGFloat = 1
    ) -> CGImage? {
        makeRenderer(style: style, context: context, scale: scale).cgImage
    }

    private static func makeRenderer(
        style: any LyricPosterStyleRendering,
        context: LyricPosterRenderContext,
        scale: CGFloat
    ) -> ImageRenderer<AnyView> {
        let renderer = ImageRenderer(content: makeView(style: style, context: context))
        renderer.scale = scale
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(context.size)
        return renderer
    }

    /// 预先糊好的封面。ImageRenderer 对 SwiftUI `.blur` 的支持并不稳定,
    /// 背景模糊这种"糊不掉就没法读歌词"的地方改用 Core Image 先做掉。
    nonisolated static func blurredArtwork(
        from image: PlatformImage,
        radius: Double = 48
    ) -> PlatformImage? {
        guard let cgImage = image.platformCGImage else { return nil }
        let source = CIImage(cgImage: cgImage)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = source.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: source.extent) else { return nil }
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let rendered = ciContext.createCGImage(output, from: source.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: rendered)
        #else
        return NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        #endif
    }

    /// 等比缩小到指定边长。滤镜缩略图用它 —— 对 1024 的封面连做六次
    /// Core Image 太慢, 缩到 160 再做就无感了。
    nonisolated static func downscaled(_ image: PlatformImage, maxPixel: Int) -> PlatformImage? {
        guard let cgImage = image.platformCGImage, maxPixel > 0 else { return nil }
        let longest = max(cgImage.width, cgImage.height)
        guard longest > maxPixel else { return image }
        let ratio = Double(maxPixel) / Double(longest)
        let width = max(Int(Double(cgImage.width) * ratio), 1)
        let height = max(Int(Double(cgImage.height) * ratio), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        #if os(iOS)
        return UIImage(cgImage: scaled)
        #else
        return NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
        #endif
    }

    /// 把滤镜作用到封面上。
    ///
    /// 只在换封面或换滤镜时做一次 —— 动态海报有一百多帧，每帧过一遍
    /// Core Image 会把导出拖成几十秒。
    nonisolated static func filtered(
        _ image: PlatformImage,
        spec: LyricPosterFilterSpec
    ) -> PlatformImage? {
        guard !spec.isIdentity, let cgImage = image.platformCGImage else { return nil }
        let source = CIImage(cgImage: cgImage)
        let extent = source.extent
        var output = source

        if spec.saturation != 1 || spec.contrast != 1 || spec.brightness != 0 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: spec.saturation,
                kCIInputContrastKey: spec.contrast,
                kCIInputBrightnessKey: spec.brightness,
            ])
        }
        if spec.warmth != 0 {
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + spec.warmth, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if spec.sepiaIntensity > 0 {
            output = output.applyingFilter("CISepiaTone", parameters: [
                kCIInputIntensityKey: spec.sepiaIntensity,
            ])
        }
        if spec.vignette > 0 {
            output = output.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: spec.vignette * 2.2,
                kCIInputRadiusKey: 1.6,
            ])
        }
        if spec.grain > 0 {
            output = grained(output, extent: extent, amount: spec.grain)
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let rendered = ciContext.createCGImage(output, from: extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: rendered)
        #else
        return NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        #endif
    }

    /// 颗粒：一层去色的随机噪声压在画面上。滤镜只跑一次，所以这里的
    /// 随机不会在动画里闪。
    private nonisolated static func grained(
        _ image: CIImage,
        extent: CGRect,
        amount: Double
    ) -> CIImage {
        guard let generator = CIFilter(name: "CIRandomGenerator"),
              let noise = generator.outputImage else { return image }
        let alpha = min(max(amount, 0), 1) * 0.35
        let monochrome = noise
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        return monochrome.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: image,
        ])
    }

    /// PNG 数据。分享面板和"存为文件"都用它 —— 海报有大片渐变, PNG 不会
    /// 像 JPEG 那样在色带边缘糊出块。
    nonisolated static func pngData(from image: PlatformImage) -> Data? {
        guard let cgImage = image.platformCGImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
