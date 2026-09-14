import SwiftUI
import PrimuseKit

// 内置海报风格(一)。每个风格只负责"画面", 歌词的逐行呈现一律交给
// LyricPosterPassageView —— 换风格换的是氛围, 不是歌词的读法。

// MARK: - 极光玻璃

/// 模糊封面铺满, 歌词落在一块磨砂卡片上。封面色彩主导整张海报的情绪,
/// 所以没有封面时这个风格不出现在选择器里。
struct AuroraGlassPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.auroraGlass, symbol: "sparkles", order: 0)

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = context.metrics(textWidthRatio: 0.68, lyricHeightRatio: 0.46)
        let cardPadding = context.scaled(64)
        // 尺寸(CGFloat)和进度(Double)先各自收敛成命名常量再相乘。
        let glowShift: CGFloat = context.size.width * CGFloat(-0.28 + 0.18 * context.entrance)
        let glowRise: CGFloat = -context.size.height * 0.26

        return AnyView(
            ZStack {
                LyricPosterArtworkBackdrop(context: context, blurRadius: 110, overlayOpacity: 0.34)

                // 主色光晕: 随时间缓慢横移, 让静止的模糊底也有呼吸。
                Circle()
                    .fill(context.palette.accent.opacity(0.55))
                    .frame(width: context.size.width * 0.9)
                    .blur(radius: context.scaled(140))
                    .offset(x: glowShift, y: glowRise)
                    .blendMode(.plusLighter)

                VStack(spacing: context.scaled(40)) {
                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: context.scaled(44)) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: context.scaled(54), weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))

                        LyricPosterPassageView(
                            context: context,
                            metrics: metrics,
                            primaryStyle: AnyShapeStyle(Color.white),
                            pendingStyle: AnyShapeStyle(Color.white.opacity(0.35)),
                            translationStyle: AnyShapeStyle(Color.white.opacity(0.74)),
                            shadow: .black.opacity(0.35)
                        )

                        Rectangle()
                            .fill(Color.white.opacity(0.22))
                            .frame(height: context.scaled(1.5))

                        LyricPosterCreditView(
                            context: context,
                            metrics: metrics,
                            titleColor: .white,
                            detailColor: .white.opacity(0.72)
                        )
                    }
                    .padding(cardPadding)
                    .frame(width: context.size.width * 0.86, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: context.scaled(52), style: .continuous)
                            .fill(Color.white.opacity(0.14))
                            .overlay(
                                RoundedRectangle(cornerRadius: context.scaled(52), style: .continuous)
                                    .stroke(Color.white.opacity(0.30), lineWidth: context.scaled(2))
                            )
                    )

                    Spacer(minLength: 0)
                }

                LyricPosterGrainOverlay(context: context)
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }
}

// MARK: - 渐变引号

/// 纯色彩版面, 不依赖封面: 没有封面的电台录音、纯本地文件也能分享得好看。
struct GradientQuotePosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.gradientQuote, symbol: "quote.opening", order: 1)

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = context.metrics(textWidthRatio: 0.76, lyricHeightRatio: 0.50)
        let margin: CGFloat = (context.size.width - CGFloat(metrics.textWidth)) / 2
        let warmDrift: CGFloat = context.size.height * CGFloat(0.30 + 0.04 * context.entrance)
        let coolDrift: CGFloat = -context.size.height * CGFloat(0.28 + 0.04 * context.entrance)

        return AnyView(
            ZStack {
                context.palette.backdropGradient

                // 两团错位的色块, 跟着入场缓缓分开 —— 单层线性渐变在
                // 大画布上太平, 这层让画面有纵深。
                Ellipse()
                    .fill(context.palette.secondary.opacity(0.7))
                    .frame(width: context.size.width * 1.1, height: context.size.height * 0.52)
                    .blur(radius: context.scaled(120))
                    .offset(x: context.size.width * 0.24, y: warmDrift)
                Ellipse()
                    .fill(context.palette.accent.opacity(0.65))
                    .frame(width: context.size.width * 0.9, height: context.size.height * 0.42)
                    .blur(radius: context.scaled(130))
                    .offset(x: -context.size.width * 0.26, y: coolDrift)

                VStack(alignment: .leading, spacing: context.scaled(52)) {
                    Spacer(minLength: 0)

                    Image(systemName: "quote.opening")
                        .font(.system(size: context.scaled(96), weight: .bold))
                        .foregroundStyle(.white.opacity(0.32))
                        .offset(y: context.scaled(30) * (1 - context.entrance))

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        primaryStyle: AnyShapeStyle(Color.white),
                        pendingStyle: AnyShapeStyle(Color.white.opacity(0.30)),
                        translationStyle: AnyShapeStyle(Color.white.opacity(0.76)),
                        shadow: .black.opacity(0.25)
                    )

                    Spacer(minLength: 0)

                    LyricPosterCreditView(
                        context: context,
                        metrics: metrics,
                        titleColor: .white,
                        detailColor: .white.opacity(0.75)
                    )
                    .frame(width: metrics.textWidth, alignment: .leading)
                }
                .padding(.horizontal, margin)
                .padding(.vertical, context.scaled(96))

                LyricPosterGrainOverlay(context: context, opacity: 0.06)
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }
}

// MARK: - 杂志排版

/// 纸白 + 衬线黑字。唯一的浅色风格, 打印出来或贴进浅色聊天背景都不违和。
struct MagazinePosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.magazine, symbol: "newspaper", order: 2)

    private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    private let ink = Color(red: 0.09, green: 0.09, blue: 0.10)

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = context.metrics(textWidthRatio: 0.78, lyricHeightRatio: 0.52)
        let textWidth = CGFloat(metrics.textWidth)
        let margin: CGFloat = (context.size.width - textWidth) / 2
        let ruleWidth: CGFloat = textWidth * CGFloat(entranceLineWidth(context))

        return AnyView(
            ZStack {
                paper

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: "LYRICS")
                            .font(.system(size: metrics.captionFontSize, weight: .black, design: .default))
                            .tracking(context.scaled(8))
                        Spacer()
                        if let year = context.content.year {
                            Text(verbatim: String(year))
                                .font(.system(size: metrics.captionFontSize, weight: .semibold, design: .monospaced))
                        }
                    }
                    .foregroundStyle(ink.opacity(0.65))

                    // 标题线从左侧展开, 动态海报里是第一个动作。
                    Rectangle()
                        .fill(ink.opacity(0.85))
                        .frame(width: ruleWidth, height: context.scaled(4))
                        .frame(width: textWidth, alignment: .leading)
                        .padding(.top, context.scaled(24))

                    Spacer(minLength: context.scaled(40))

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        primaryStyle: AnyShapeStyle(ink),
                        pendingStyle: AnyShapeStyle(ink.opacity(0.22)),
                        translationStyle: AnyShapeStyle(ink.opacity(0.58)),
                        fontDesign: .serif,
                        fontWeight: .semibold
                    )

                    Spacer(minLength: context.scaled(40))

                    Rectangle()
                        .fill(ink.opacity(0.25))
                        .frame(height: context.scaled(1.5))
                        .padding(.bottom, context.scaled(28))

                    LyricPosterCreditView(
                        context: context,
                        metrics: metrics,
                        titleColor: ink,
                        detailColor: ink.opacity(0.55),
                        showsArtwork: context.hasArtwork,
                        artworkCorner: 4
                    )
                }
                .frame(width: textWidth)
                .padding(.horizontal, margin)
                .padding(.vertical, context.scaled(104))

                LyricPosterGrainOverlay(context: context, opacity: 0.08)
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }

    private func entranceLineWidth(_ context: LyricPosterRenderContext) -> Double {
        guard context.isMotion else { return 1 }
        return min(1, max(0.08, context.entrance * 2.2))
    }
}

// MARK: - 黑胶

/// 封面当作唱片。动态海报里唱片真的在转 —— Live Photo 长按播放时最像
/// "这首歌正在放"。
struct VinylPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.vinyl, symbol: "opticaldisc", order: 3)

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = context.metrics(textWidthRatio: 0.72, lyricHeightRatio: 0.34)
        let discSize = context.size.width * 0.46

        return AnyView(
            ZStack {
                LinearGradient(
                    colors: [
                        context.palette.deep,
                        context.palette.accent.opacity(0.42),
                        context.palette.deep,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: context.scaled(56)) {
                    disc(context: context, size: discSize)

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        alignment: .center,
                        textAlignment: .center,
                        primaryStyle: AnyShapeStyle(Color.white),
                        pendingStyle: AnyShapeStyle(Color.white.opacity(0.28)),
                        translationStyle: AnyShapeStyle(Color.white.opacity(0.70)),
                        shadow: .black.opacity(0.4)
                    )

                    LyricPosterCreditView(
                        context: context,
                        metrics: metrics,
                        titleColor: .white,
                        detailColor: .white.opacity(0.68),
                        showsArtwork: false
                    )
                    .frame(width: metrics.textWidth)
                }
                .padding(.vertical, context.scaled(80))

                LyricPosterGrainOverlay(context: context, opacity: 0.07)
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }

    private func disc(context: LyricPosterRenderContext, size: CGFloat) -> some View {
        // 静态海报固定一个轻微角度: 正过来看像贴图, 歪一点才像唱片。
        let rotation: Double = context.isMotion ? context.time * 150 : -14

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.16), Color(white: 0.04)],
                        center: .center,
                        startRadius: size * 0.18,
                        endRadius: size * 0.5
                    )
                )

            // 纹路
            ForEach(0..<9, id: \.self) { ring in
                let ringScale = CGFloat(0.46 + Double(ring) * 0.06)
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: context.scaled(1.4))
                    .frame(width: size * ringScale)
            }

            // 高光: 跟着唱片一起转, 所以放在旋转层内部。
            Circle()
                .trim(from: 0.05, to: 0.22)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.001), .white.opacity(0.26), .white.opacity(0.001)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: size * 0.42
                )
                .frame(width: size * 0.72)
                .blur(radius: context.scaled(18))

            if let artwork = context.artworkImage {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size * 0.40, height: size * 0.40)
                    .clipShape(Circle())
            }

            Circle()
                .fill(context.palette.deep)
                .frame(width: size * 0.045)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
        .shadow(color: .black.opacity(0.5), radius: context.scaled(40), y: context.scaled(16))
    }
}
