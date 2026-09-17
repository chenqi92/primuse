import SwiftUI
import PrimuseKit

// 随界面皮肤提供的海报风格。每套皮肤在自己的定义里(`SkinCompanions`)声明带来哪几款,
// 渲染实现放在这里,登记方式与内置风格完全一样。

// MARK: - 深海(极简)

/// 极简皮肤的配套海报:深海蓝的底、右上角一团跟着封面取色的光、左上角一张封面。
/// 不依赖封面 —— 没有封面的歌只是少了那张小图,光改用兜底色。
struct DeepSeaPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.deepSea, symbol: "water.waves", order: 8)

    /// 上下内边距 192 + 封面 220 + 封面到歌词 84 + 色条 10 + 色条到署名 44 + 署名 96。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics {
        context.metrics(textWidthRatio: 0.78, reservedHeight: 646)
    }

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = metrics(for: context)
        let margin: CGFloat = (context.size.width - CGFloat(metrics.textWidth)) / 2
        let entrance = CGFloat(context.entrance)
        let glowSize: CGFloat = context.size.width * 0.86
        let glowDriftX: CGFloat = context.size.width * (0.34 - 0.03 * entrance)
        let glowDriftY: CGFloat = -context.size.height * (0.40 - 0.02 * entrance)
        let coverSide: CGFloat = context.scaled(220)
        let coverScale: CGFloat = 0.94 + 0.06 * entrance

        return AnyView(
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.086, green: 0.161, blue: 0.290), location: 0),
                        .init(color: Color(red: 0.047, green: 0.094, blue: 0.188), location: 0.46),
                        .init(color: Color(red: 0.027, green: 0.051, blue: 0.102), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // 唯一的颜色来自这首歌自己。
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [context.palette.accent.opacity(0.62), context.palette.accent.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: glowSize / 2
                        )
                    )
                    .frame(width: glowSize, height: glowSize)
                    .offset(x: glowDriftX, y: glowDriftY)

                VStack(alignment: .leading, spacing: 0) {
                    if let artwork = context.artworkImage {
                        artwork
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: coverSide, height: coverSide)
                            .clipShape(
                                RoundedRectangle(cornerRadius: context.scaled(36), style: .continuous)
                            )
                            .shadow(
                                color: .black.opacity(0.45),
                                radius: context.scaled(36),
                                y: context.scaled(20)
                            )
                            .scaleEffect(coverScale, anchor: .topLeading)
                            .padding(.bottom, context.scaled(84))
                    }

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        primaryStyle: AnyShapeStyle(Color.white),
                        pendingStyle: AnyShapeStyle(Color.white.opacity(0.34)),
                        translationStyle: AnyShapeStyle(Color.white.opacity(0.62)),
                        shadow: .black.opacity(0.3)
                    )

                    Spacer(minLength: 0)

                    Capsule()
                        .fill(context.palette.accent)
                        .frame(width: context.scaled(112), height: context.scaled(10))
                        .padding(.bottom, context.scaled(44))

                    LyricPosterCreditView(
                        context: context,
                        metrics: metrics,
                        titleColor: .white,
                        detailColor: .white.opacity(0.6),
                        showsArtwork: false
                    )
                    .frame(width: metrics.textWidth, alignment: .leading)
                }
                .padding(.horizontal, margin)
                .padding(.vertical, context.scaled(96))

                LyricPosterGrainOverlay(context: context, opacity: 0.05)
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }
}
