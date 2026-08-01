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

    private static func make(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // 放大到清晰像素(二维码本身分辨率低,放大避免模糊)。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
