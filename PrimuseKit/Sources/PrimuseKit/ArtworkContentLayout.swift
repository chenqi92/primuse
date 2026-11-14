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

    /// 等比放大到盖满 `bounds`,多出来的两头裁掉。
    public static func filledRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// 槽位比方形长出这么多以内仍按方框对待(整张放进去);再长出 `slotFillRamp` 就完全铺满。
    public static let squareSlotTolerance: CGFloat = 0.03
    public static let slotFillRamp: CGFloat = 0.12

    /// 槽位本身不是方的(播放页「铺满」)时,长方形封面也要盖满整个槽位、两头裁掉,和方封面一样;
    /// 只有方框里才整张放进去、四周垫模糊底。返回 0...1,槽位越接近方形越接近 0:
    /// 封面从铺满的大槽位飞到歌词旁的小方框途中,两种摆法跟着槽位形状连续过渡,不会跳一下。
    public static func slotFillAmount(slotSize: CGSize) -> CGFloat {
        guard slotSize.width.isFinite, slotSize.height.isFinite,
              slotSize.width > 0, slotSize.height > 0 else { return 0 }
        let elongation = max(slotSize.width / slotSize.height, slotSize.height / slotSize.width) - 1
        return min(1, max(0, (elongation - squareSlotTolerance) / slotFillRamp))
    }

    /// 播放页封面层里长方形封面盖满槽位的程度。`fullBleed` 是铺满的程度(铺满的封面位 1,卡片与歌词小封面 0,
    /// 飞行途中插值):铺满的槽位不论长得方不方都盖满。手机横屏、封面下歌词选「自动」、矮一些的屏上铺满的槽位
    /// 接近方形,只按 `slotFillAmount` 判断时长方形封面整张缩进避开顶栏和渐隐的那一小块里,正中间只剩一张小图。
    /// 和槽位形状两者取大,其它非方形槽位照旧盖满。
    public static func contentFillAmount(slotSize: CGSize, fullBleed: CGFloat) -> CGFloat {
        let explicit = fullBleed.isFinite ? min(1, max(0, fullBleed)) : 0
        return max(explicit, slotFillAmount(slotSize: slotSize))
    }

    public static func interpolate(from start: CGRect, to end: CGRect, fraction: CGFloat) -> CGRect {
        let t = min(1, max(0, fraction.isFinite ? fraction : 0))
        return CGRect(
            x: start.minX + (end.minX - start.minX) * t,
            y: start.minY + (end.minY - start.minY) * t,
            width: start.width + (end.width - start.width) * t,
            height: start.height + (end.height - start.height) * t
        )
    }

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
