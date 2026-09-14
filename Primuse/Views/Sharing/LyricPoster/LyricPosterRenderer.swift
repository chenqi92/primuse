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
