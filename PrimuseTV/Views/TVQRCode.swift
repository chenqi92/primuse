#if os(tvOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// 二维码视图(CoreImage 生成)。Apple TV 上展示,手机相机扫码后打开 iOS app。
struct TVQRCode: View {
    let content: String
    var size: CGFloat = 200

    var body: some View {
        Group {
            if let image = Self.make(content) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .background(.white)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TVColor.surface)
                    .overlay { Image(systemName: "qrcode").font(.system(size: 48)).foregroundStyle(TVColor.textGhost) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// body 每次重算都会走到这里(源页焦点一动就算一次)。CIContext 建一次要初始化 Metal,
    /// 共用一个;同一内容生成过就直接用。
    @MainActor private static let context = CIContext()
    @MainActor private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()

    @MainActor private static func make(_ string: String) -> UIImage? {
        if let cached = cache.object(forKey: string as NSString) { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // 放大到清晰像素(二维码本身分辨率低,放大避免模糊)。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: string as NSString)
        return image
    }
}
#endif
