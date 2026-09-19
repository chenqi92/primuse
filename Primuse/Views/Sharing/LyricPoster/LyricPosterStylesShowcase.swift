import SwiftUI
import PrimuseKit

// 内置海报风格(二)。更"有道具"的四种: 电影字幕、霓虹、拍立得、磁带。

// MARK: - 电影剧照

/// 宽银幕画格 + 字幕条。歌词当成台词来读, 竖屏九宫格里最像一帧电影。
struct FilmStillPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.filmStill, symbol: "film", order: 4)

    /// 2.39:1 的画格, 上下留黑 —— 宽银幕的比例本身就是"电影感"的来源。
    /// 方形画幅下这个画格会吃掉太多高度, 再按画布高度压一道。
    private func frameHeight(_ context: LyricPosterRenderContext) -> CGFloat {
        min(context.size.width / 2.39, context.size.height * 0.30)
    }

    /// 画格 + 四段 spacing 192 + 时间码行 34 + 上下内边距 112。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics {
        context.metrics(
            textWidthRatio: 0.82,
            reservedHeight: Double(frameHeight(context)) + 338
        )
    }

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = metrics(for: context)
        let frameHeight = frameHeight(context)
        let push = CGFloat(1.06 + 0.10 * context.entrance) * context.artworkMotionScale

        return AnyView(
            ZStack {
                Color.black

                VStack(spacing: context.scaled(48)) {
                    Spacer(minLength: 0)

                    ZStack {
                        if let artwork = context.artworkImage {
                            artwork
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                // 缓推: 静态海报固定在推近的终点。
                                .scaleEffect(push)
                        } else {
                            context.palette.backdropGradient
                        }

                        // 暗角, 把视线收回到画面中心。
                        RadialGradient(
                            colors: [.clear, .black.opacity(0.55)],
                            center: .center,
                            startRadius: context.size.width * 0.18,
                            endRadius: context.size.width * 0.62
                        )
                    }
                    .frame(width: context.size.width, height: frameHeight)
                    .clipped()

                    VStack(spacing: context.scaled(28)) {
                        LyricPosterPassageView(
                            context: context,
                            metrics: metrics,
                            alignment: .center,
                            textAlignment: .center,
                            primaryStyle: AnyShapeStyle(Color.white),
                            pendingStyle: AnyShapeStyle(Color.white.opacity(0.22)),
                            translationStyle: AnyShapeStyle(Color.white.opacity(0.72)),
                            fontDesign: .default,
                            fontWeight: .semibold,
                            shadow: .black.opacity(0.9)
                        )
                    }

                    Spacer(minLength: 0)

                    HStack {
                        Text(verbatim: timecode(context))
                            .font(.system(size: metrics.captionFontSize, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text(creditLine(context))
                            .font(.system(size: metrics.captionFontSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, context.scaled(80))
                }
                .padding(.vertical, context.scaled(56))
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }

    /// 首句在歌里的位置, 写成 mm:ss —— 未同步的歌词没有这个信息。
    private func timecode(_ context: LyricPosterRenderContext) -> String {
        guard let first = context.content.lines.first, first.isSynchronized else {
            return context.appName.uppercased()
        }
        let total = Int(first.timestamp.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func creditLine(_ context: LyricPosterRenderContext) -> String {
        [context.content.songTitle, context.content.artistName]
            .compactMap { $0 }
            .joined(separator: " — ")
    }
}

// MARK: - 霓虹夜

/// 深夜霓虹。发光跟着时间呼吸, 唱到的那一行最亮。
struct NeonNightPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.neonNight, symbol: "bolt.fill", order: 5)

    /// 装饰行 54 + 四段 spacing 192 + 署名 96 + 上下内边距 200。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics {
        context.metrics(textWidthRatio: 0.78, reservedHeight: 542)
    }

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = metrics(for: context)
        let glow = context.palette.accent
        // 呼吸: 动态海报按时间起伏, 静态海报取一个偏亮的定值。
        let wave: Double = 0.5 + 0.5 * sin(context.time * 2.6)
        let pulse: Double = context.isMotion ? 0.72 + 0.28 * wave : 0.92
        let margin: CGFloat = (context.size.width - CGFloat(metrics.textWidth)) / 2

        return AnyView(
            ZStack {
                Color(red: 0.03, green: 0.03, blue: 0.07)

                perspectiveGrid(context: context, color: glow)

                // 地平线上的光晕
                Ellipse()
                    .fill(glow.opacity(0.5 * pulse))
                    .frame(width: context.size.width * 1.2, height: context.size.height * 0.20)
                    .blur(radius: context.scaled(110))
                    .offset(y: context.size.height * 0.16)

                VStack(alignment: .leading, spacing: context.scaled(48)) {
                    Spacer(minLength: 0)

                    Text(verbatim: "◢ ◤")
                        .font(.system(size: metrics.captionFontSize * 1.6, weight: .black, design: .monospaced))
                        .foregroundStyle(context.palette.secondary.opacity(0.9))

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        primaryStyle: AnyShapeStyle(Color.white),
                        pendingStyle: AnyShapeStyle(Color.white.opacity(0.18)),
                        translationStyle: AnyShapeStyle(glow.opacity(0.82)),
                        fontDesign: .rounded,
                        fontWeight: .heavy
                    )
                    // 霓虹管效果 = 同一段文字叠两层辉光, 近处紧、远处散。
                    .shadow(color: glow.opacity(pulse), radius: context.scaled(18))
                    .shadow(color: glow.opacity(0.55 * pulse), radius: context.scaled(52))

                    Spacer(minLength: 0)

                    LyricPosterCreditView(
                        context: context,
                        metrics: metrics,
                        titleColor: .white,
                        detailColor: glow.opacity(0.85),
                        showsArtwork: context.hasArtwork,
                        artworkCorner: 10
                    )
                    .frame(width: metrics.textWidth, alignment: .leading)
                }
                .padding(.horizontal, margin)
                .padding(.vertical, context.scaled(100))
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }

    /// 透视网格。线距按平方展开, 越靠近地平线越密。
    private func perspectiveGrid(context: LyricPosterRenderContext, color: Color) -> some View {
        Canvas { canvasContext, size in
            let horizon: CGFloat = size.height * 0.66
            let vanishing = CGPoint(x: size.width / 2, y: horizon)
            var path = Path()

            let start: CGFloat = -size.width * 0.6
            let span: CGFloat = size.width * 2.2
            for step in 0...14 {
                let ratio = CGFloat(Double(step) / 14)
                let x: CGFloat = start + span * ratio
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: vanishing)
            }
            let depth: CGFloat = size.height - horizon
            for row in 1...12 {
                let ratio = CGFloat(pow(Double(row) / 12, 2.1))
                let y: CGFloat = horizon + depth * ratio
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            canvasContext.stroke(
                path,
                with: .color(color.opacity(0.35)),
                lineWidth: context.scaled(2)
            )
        }
        .mask {
            LinearGradient(
                colors: [.clear, .white, .white.opacity(0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - 拍立得

/// 白边相纸 + 手写感衬线。动态海报里是"显影": 封面从灰到彩。
struct PolaroidPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.polaroid, symbol: "camera", order: 6)

    private let paper = Color(red: 0.98, green: 0.975, blue: 0.96)
    private let ink = Color(red: 0.13, green: 0.12, blue: 0.14)

    /// 照片本来是正方形(宽度决定边长), 但相纸还要装下歌词和落款,
    /// 方形画幅下必须让照片先让步, 否则整张相纸伸出画布。
    private func photoSide(_ context: LyricPosterRenderContext) -> CGFloat {
        min(context.size.width * 0.80 - context.scaled(72), context.size.height * 0.52)
    }

    /// 文字列要跟照片一样宽: 列窄了长句会被迫折成两行, 相纸立刻装不下。
    /// 照片 + 两段 spacing 72 + 落款 46 + 相纸内边距 72。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics {
        context.metrics(
            textWidthRatio: 0.70,
            reservedHeight: Double(photoSide(context)) + 190
        )
    }

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = metrics(for: context)
        let paperWidth: CGFloat = context.size.width * 0.80
        let photoSide = photoSide(context)
        // 显影: 入场前半段完成上色, 后半段留给歌词。
        let development: Double = context.isMotion ? min(1, context.entrance * 2.2) : 1
        let tilt: Double = context.isMotion ? -3.2 + 1.2 * context.entrance : -2.0

        return AnyView(
            ZStack {
                LinearGradient(
                    colors: [
                        context.palette.deep,
                        context.palette.accent.opacity(0.45),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: context.scaled(36)) {
                    if let artwork = context.artworkImage {
                        artwork
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: photoSide, height: photoSide)
                            .scaleEffect(context.artworkMotionScale)
                            .clipped()
                            .saturation(development)
                            .brightness((1 - development) * 0.18)
                            .contrast(0.7 + 0.3 * development)
                    }

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        alignment: .center,
                        textAlignment: .center,
                        primaryStyle: AnyShapeStyle(ink),
                        pendingStyle: AnyShapeStyle(ink.opacity(0.20)),
                        translationStyle: AnyShapeStyle(ink.opacity(0.55)),
                        fontDesign: .serif,
                        fontWeight: .medium
                    )

                    HStack(spacing: context.scaled(10)) {
                        Text(context.content.songTitle)
                            .font(.system(size: metrics.captionFontSize, weight: .semibold, design: .serif))
                            .foregroundStyle(ink.opacity(0.7))
                            .lineLimit(1)
                        if let artist = context.content.artistName {
                            Text(verbatim: "·")
                                .foregroundStyle(ink.opacity(0.4))
                            Text(artist)
                                .font(.system(size: metrics.captionFontSize, weight: .regular, design: .serif))
                                .foregroundStyle(ink.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    .padding(.bottom, context.scaled(12))
                }
                .padding(context.scaled(36))
                .frame(width: paperWidth)
                .background(
                    RoundedRectangle(cornerRadius: context.scaled(10), style: .continuous)
                        .fill(paper)
                        .shadow(color: .black.opacity(0.45), radius: context.scaled(48), y: context.scaled(24))
                )
                // 手放上去的角度。动态海报里最后一点点回正。
                .rotationEffect(.degrees(tilt))
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }
}

// MARK: - 磁带

/// 卡带 J 卡。等宽字 + 转动的卷轴, 整张海报像一盒亲手录的混音带。
struct CassettePosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.cassette, symbol: "recordingtape", order: 7)

    private let shell = Color(red: 0.13, green: 0.13, blue: 0.15)

    /// 卡带外壳按宽度定高(0.62 比例), 方形画幅下改由高度决定。
    private func shellWidth(_ context: LyricPosterRenderContext) -> CGFloat {
        min(context.size.width * 0.72, context.size.height * 0.44 / 0.62)
    }

    /// 外壳 + 两段 spacing 88 + SIDE A 行 34 + 上下内边距 168。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics {
        context.metrics(
            textWidthRatio: 0.72,
            reservedHeight: Double(shellWidth(context) * 0.62) + 290
        )
    }

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = metrics(for: context)
        let shellWidth = shellWidth(context)

        return AnyView(
            ZStack {
                LinearGradient(
                    colors: [
                        context.palette.accent.opacity(0.85),
                        context.palette.secondary.opacity(0.75),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: context.scaled(44)) {
                    cassetteShell(context: context, metrics: metrics, width: shellWidth)

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        alignment: .leading,
                        textAlignment: .leading,
                        primaryStyle: AnyShapeStyle(Color.white),
                        pendingStyle: AnyShapeStyle(Color.white.opacity(0.26)),
                        translationStyle: AnyShapeStyle(Color.white.opacity(0.70)),
                        fontDesign: .monospaced,
                        fontWeight: .semibold,
                        shadow: .black.opacity(0.3)
                    )

                    HStack {
                        Text(verbatim: "SIDE A")
                            .font(.system(size: metrics.captionFontSize, weight: .bold, design: .monospaced))
                        Spacer()
                        Text(context.appName)
                            .font(.system(size: metrics.captionFontSize, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: metrics.textWidth)
                }
                .padding(.vertical, context.scaled(84))

                LyricPosterGrainOverlay(context: context, opacity: 0.07)
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }

    private func cassetteShell(
        context: LyricPosterRenderContext,
        metrics: LyricPosterTypeMetrics,
        width: CGFloat
    ) -> some View {
        let height: CGFloat = width * 0.62
        let reelSize: CGFloat = height * 0.38
        let rotation: Double = context.isMotion ? context.time * 110 : 0

        return ZStack {
            RoundedRectangle(cornerRadius: context.scaled(18), style: .continuous)
                .fill(shell)

            VStack(spacing: context.scaled(14)) {
                // 标签条: 写歌名和歌手, 就像手写贴纸。
                VStack(alignment: .leading, spacing: context.scaled(4)) {
                    Text(context.content.songTitle)
                        .font(.system(size: metrics.captionFontSize * 1.15, weight: .bold, design: .monospaced))
                        .foregroundStyle(shell)
                        .lineLimit(1)
                    if let artist = context.content.artistName {
                        Text(artist)
                            .font(.system(size: metrics.captionFontSize * 0.9, weight: .medium, design: .monospaced))
                            .foregroundStyle(shell.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, context.scaled(18))
                .padding(.vertical, context.scaled(12))
                .background(
                    RoundedRectangle(cornerRadius: context.scaled(6), style: .continuous)
                        .fill(Color(red: 0.93, green: 0.91, blue: 0.86))
                )

                // 磁带窗
                ZStack {
                    RoundedRectangle(cornerRadius: context.scaled(10), style: .continuous)
                        .fill(Color.black.opacity(0.55))

                    HStack(spacing: reelSize * 0.7) {
                        reel(context: context, size: reelSize, rotation: rotation)
                        reel(context: context, size: reelSize, rotation: -rotation)
                    }
                }
                .frame(height: height * 0.46)
            }
            .padding(context.scaled(22))
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.35), radius: context.scaled(30), y: context.scaled(14))
    }

    private func reel(context: LyricPosterRenderContext, size: CGFloat, rotation: Double) -> some View {
        ZStack {
            Circle()
                .fill(Color(white: 0.22))
            Circle()
                .stroke(Color(white: 0.45), lineWidth: context.scaled(3))
            ForEach(0..<6, id: \.self) { spoke in
                Capsule()
                    .fill(Color(white: 0.55))
                    .frame(width: context.scaled(5), height: size * 0.34)
                    .offset(y: -size * 0.20)
                    .rotationEffect(.degrees(Double(spoke) * 60))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
    }
}
