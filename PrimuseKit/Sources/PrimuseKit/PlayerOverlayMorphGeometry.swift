import CoreGraphics

public struct PlayerOverlayMorphGeometry {
    public let transform: CGAffineTransform
    /// 页面坐标里保留的高度（顶边对齐）。
    public let clipHeight: CGFloat
    public let cornerRadius: CGFloat
    public let contentOpacity: Double
    public let cardFillOpacity: Double
    public let overallOpacity: Double

    public init(progress t: CGFloat, offset: CGSize, capsule: CGRect, container: CGSize) {
        let width = max(container.width, 1)
        let height = max(container.height, 1)
        if abs(t - 1) < 0.001 {
            // 铺满之后：拖动、横滑收起是平移；往上越过停靠位置时底边钉住、往上拉伸。
            // 展开冲过头（t > 1）不走这里，按下面的插值让卡片略大于屏幕。
            let stretch = offset.height < 0 ? (height - offset.height) / height : 1
            transform = CGAffineTransform(a: 1, b: 0, c: 0, d: stretch, tx: offset.width, ty: offset.height)
            clipHeight = height
            cornerRadius = Self.exposedCornerRadius(
                frame: CGRect(x: offset.width, y: offset.height, width: width, height: height * stretch),
                container: CGSize(width: width, height: height),
                preferredRadius: 40
            )
            contentOpacity = 1
            cardFillOpacity = 0
            overallOpacity = 1
            return
        }
        func lerp(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }
        let vertical = Self.verticalProgress(t)
        let minX = lerp(capsule.minX, offset.width, t)
        let maxX = lerp(capsule.maxX, offset.width + width, t)
        let minY = lerp(capsule.minY, offset.height, vertical)
        let maxY = lerp(capsule.maxY, offset.height + height, vertical)
        let scale = max((maxX - minX) / width, 0.01)
        transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: minX, ty: minY)
        clipHeight = max(maxY - minY, 0) / scale

        let clamped = min(max(t, 0), 1)
        let capsuleRadius = min(capsule.height / 2, 28)
        cornerRadius = Self.exposedCornerRadius(
            frame: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            container: CGSize(width: width, height: height),
            preferredRadius: capsuleRadius + (40 - capsuleRadius) * clamped
        ) / scale
        contentOpacity = Double(Self.smoothstep((clamped - 0.25) / 0.45))
        cardFillOpacity = 1
        overallOpacity = Double(min(max(t / 0.12, 0), 1))
    }

    // 用同一套边缘距离衔接拖动与胶囊变形，松手时不会切回直角；上拉回弹覆盖屏幕时不裁出空隙。
    private static func exposedCornerRadius(frame: CGRect, container: CGSize, preferredRadius: CGFloat) -> CGFloat {
        let exposure = max(frame.minX, frame.minY, container.width - frame.maxX, container.height - frame.maxY, 0)
        return preferredRadius * smoothstep(exposure / max(preferredRadius, 1))
    }

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let v = min(max(x, 0), 1)
        return v * v * (3 - 2 * v)
    }

    /// 竖直方向（上下边）的进度。宽度照旧按 t 线性走；高度在开头这一段按二次曲线起步，
    /// 卡片还在淡入淡出（t < 0.12）时高度贴着胶囊，不会顶着两三倍胶囊高的一块半透明卡片
    /// 出现或淡掉。过了这一段改成直线，弹簧收尾那几帧不再拖出一截往上爬的位移；两段在
    /// 衔接处数值与斜率都连续，t = 1 时正好是 1，回弹越过 1 时沿同一斜率接着走。
    private static func verticalProgress(_ t: CGFloat) -> CGFloat {
        let easeIn: CGFloat = 0.25
        let slope = 1 / (1 - easeIn / 2)
        let p = max(t, 0)
        return p < easeIn ? slope * p * p / (2 * easeIn) : slope * (p - easeIn / 2)
    }
}
