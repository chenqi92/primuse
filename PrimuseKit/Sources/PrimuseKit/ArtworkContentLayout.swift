import Foundation

public enum ArtworkContentLayout {
    public static func isRectangular(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return false }
        return abs(size.width / size.height - 1) > 0.03
    }

    public static func fittedRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// 长方形封面放进方框时的位置:先整张放进去,短边盖不到框的 `minimumCoverage` 时再等比放大,
    /// 长边两头裁掉一点,剩下的边仍由模糊底补齐。放大最多 `maximumBoost` 倍,特别扁、特别长的图
    /// 也至少留下大半张。整张放进去时 16:9 只剩框高的一半多、3:1 只剩三分之一,小图里几乎看不清。
    public static let minimumCoverage: CGFloat = 0.78
    public static let maximumBoost: CGFloat = 1.6

    public static func displayRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        let fitted = fittedRect(imageSize: imageSize, in: bounds)
        guard fitted.width > 0, fitted.height > 0 else { return fitted }
        let coverage = min(fitted.width / bounds.width, fitted.height / bounds.height)
        guard coverage < minimumCoverage else { return fitted }
        let boost = min(minimumCoverage / coverage, maximumBoost)
        let size = CGSize(width: fitted.width * boost, height: fitted.height * boost)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
