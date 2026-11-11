import SwiftUI

extension View {
    /// 红心的那一下。点亮时心形弹一下(symbolEffect bounce),一小圈光点和小心形从心形向外
    /// 散开、减速、淡掉;取消时只轻轻缩一下再回来。
    ///
    /// 只在同一个对象(`identity`:正在播的那首、这一页的专辑)上从「未喜欢」变成「喜欢」时放。
    /// 换歌、翻到另一页时带出来的已喜欢状态不放,不然每切到一首喜欢过的歌都要冒一次花。
    /// 状态全在这个修饰符里,放一次只重画红心这一小块。减少动态效果时什么都不加,
    /// 图标本身的替换过渡照旧。
    func pmLikeBurst(isLiked: Bool, identity: AnyHashable? = nil, tint: Color) -> some View {
        modifier(PMLikeBurstModifier(isLiked: isLiked, identity: identity, tint: tint))
    }
}

private struct PMLikeBurstModifier: ViewModifier {
    let isLiked: Bool
    let identity: AnyHashable?
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounceToken = 0
    @State private var shrinkToken = 0
    @State private var burstToken = 0

    /// 对象和喜欢状态放在一起比较:两者同一次更新里变了(换到一首喜欢过的歌)时,
    /// 分开监听的两个回调谁先谁后说不准,合在一起才判得出「是不是同一首」。
    private struct LikeSnapshot: Equatable {
        let identity: AnyHashable?
        let isLiked: Bool
    }

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, options: .nonRepeating, value: bounceToken)
            .keyframeAnimator(initialValue: 1.0, trigger: shrinkToken) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                // 取消:往里收一点,再按 pop 那种弹簧回到原大小。
                KeyframeTrack {
                    CubicKeyframe(0.84, duration: 0.1)
                    SpringKeyframe(1.0, duration: 0.32, spring: Spring(response: 0.34, dampingRatio: 0.56))
                }
            }
            .overlay {
                PMLikeBurstParticles(trigger: burstToken, tint: tint)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: LikeSnapshot(identity: identity, isLiked: isLiked)) { old, new in
                guard old.identity == new.identity, !reduceMotion else { return }
                if new.isLiked, !old.isLiked {
                    bounceToken &+= 1
                    burstToken &+= 1
                } else if !new.isLiked, old.isLiked {
                    shrinkToken &+= 1
                }
            }
    }
}

/// 散开的那圈光点。没在放的时候只是一层透明的占位,不画任何东西。
private struct PMLikeBurstParticles: View {
    let trigger: Int
    let tint: Color

    var body: some View {
        Color.clear
            .keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, progress in
                view.overlay {
                    if progress > 0, progress < 1 {
                        GeometryReader { proxy in
                            // 按短边算:挂在带字的宽按钮上时,光点仍按心形那么大散开,不铺满整颗按钮。
                            let side = min(proxy.size.width, proxy.size.height)
                            PMLikeBurstCanvas(progress: progress, tint: tint, heartSide: side)
                                .frame(width: side * 3, height: side * 3)
                                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        }
                    }
                }
            } keyframes: { _ in
                // 时间线跟 `PMMotion.burst` 那一档:同样长、同样先快后慢。
                KeyframeTrack {
                    MoveKeyframe(0.0)
                    LinearKeyframe(1.0, duration: PMMotion.burst.settleDuration, timingCurve: .easeOut)
                }
            }
    }
}

private struct PMLikeBurstCanvas: View {
    let progress: Double
    let tint: Color
    let heartSide: CGFloat

    /// 一圈多少颗。单数,心形与圆点交替,第一颗朝正上方。
    private static let particleCount = 7

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(max(progress, 0), 1)
            // 头两成淡入,之后慢慢淡掉。
            let fade = p < 0.2 ? p / 0.2 : (1 - p) / 0.8

            // 先是一道向外扩开的细环。
            let ringRadius = heartSide * (0.35 + 0.55 * p)
            let ring = Path(ellipseIn: CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ))
            context.stroke(
                ring,
                with: .color(tint.opacity(0.45 * (1 - p))),
                lineWidth: max(0.5, 2.4 * (1 - p))
            )

            var heart = context.resolve(Image(systemName: "heart.fill").renderingMode(.template))
            heart.shading = .color(tint)
            let start = heartSide * 0.4
            let travel = heartSide * 0.85
            for index in 0..<Self.particleCount {
                let angle = -Double.pi / 2 + Double(index) / Double(Self.particleCount) * 2 * .pi
                // 每颗飞的距离略有长短,看起来不像一个规规矩矩的圆。
                let reach = start + travel * p * (index.isMultiple(of: 2) ? 1 : 0.82)
                let point = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * reach,
                    y: center.y + CGFloat(sin(angle)) * reach
                )
                var particle = context
                particle.opacity = max(0, fade)
                if index.isMultiple(of: 2) {
                    let side = heartSide * (0.16 + 0.06 * p)
                    particle.draw(heart, in: CGRect(
                        x: point.x - side / 2,
                        y: point.y - side / 2,
                        width: side,
                        height: side
                    ))
                } else {
                    let radius = heartSide * 0.05 * (1.2 - 0.5 * p)
                    particle.fill(
                        Path(ellipseIn: CGRect(
                            x: point.x - radius,
                            y: point.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )),
                        with: .color(tint)
                    )
                }
            }
        }
    }
}
