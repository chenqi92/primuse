import SwiftUI
import PrimuseKit

// 按设计稿做的三种风格。它们的共同点是"海报上不只有歌词" —— 还有一张
// 照片、一段自己写的话和一个落款，看起来像做给某个人的东西。

// MARK: - 复古信笺

/// 牛皮纸上贴着一张照片，旁边是手写的几句话。胶带、日期戳、邮戳都是
/// 画上去的，不依赖任何图片素材。
struct RetroLetterPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.retroLetter, symbol: "envelope", order: -3)

    private let paper = Color(red: 0.902, green: 0.863, blue: 0.784)
    private let paperDeep = Color(red: 0.80, green: 0.745, blue: 0.655)
    private let ink = Color(red: 0.192, green: 0.161, blue: 0.129)
    private let stampRed = Color(red: 0.549, green: 0.235, blue: 0.188)

    /// 相纸整体：照片是方的，下面留出宽白边（拍立得就是这么长的）。
    private func photoSide(_ context: LyricPosterRenderContext) -> CGFloat {
        min(context.size.width * 0.52, context.size.height * 0.34)
    }

    private func printHeight(_ context: LyricPosterRenderContext) -> CGFloat {
        photoSide(context) + context.scaled(28) * 2 + context.scaled(42)
    }

    /// 相纸 + 页眉 56 + 两段 spacing 80 + 歌名块 82 + 一段 spacing 32
    /// + 页脚 50 + 上下内边距 144。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics {
        context.metrics(
            textWidthRatio: 0.70,
            reservedHeight: Double(printHeight(context)) + 444
        )
    }

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = metrics(for: context)
        let margin: CGFloat = (context.size.width - CGFloat(metrics.textWidth)) / 2

        return AnyView(
            ZStack {
                paperBackground(context: context)

                VStack(alignment: .leading, spacing: context.scaled(40)) {
                    header(context: context, metrics: metrics)

                    taped(context: context) {
                        photoPrint(context: context, metrics: metrics)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: context.scaled(32)) {
                        titleBlock(context: context, metrics: metrics)

                        LyricPosterPassageView(
                            context: context,
                            metrics: metrics,
                            primaryStyle: AnyShapeStyle(ink.opacity(0.88)),
                            pendingStyle: AnyShapeStyle(ink.opacity(0.22)),
                            translationStyle: AnyShapeStyle(ink.opacity(0.58)),
                            fontDesign: .serif,
                            fontWeight: .medium,
                            noteStyle: AnyShapeStyle(ink.opacity(0.74))
                        )
                    }

                    Spacer(minLength: 0)

                    footer(context: context, metrics: metrics)
                }
                .padding(.horizontal, margin)
                .padding(.vertical, context.scaled(72))

                postmark(context: context, metrics: metrics)

                LyricPosterGrainOverlay(context: context, opacity: 0.16)
            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }

    // MARK: 纸

    private func paperBackground(context: LyricPosterRenderContext) -> some View {
        ZStack {
            LinearGradient(
                colors: [paper, paperDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 四边压暗，像一张放久了的纸。
            RadialGradient(
                colors: [.clear, paperDeep.opacity(0.55)],
                center: .center,
                startRadius: context.size.width * 0.28,
                endRadius: context.size.width * 0.78
            )
        }
    }

    private func header(
        context: LyricPosterRenderContext,
        metrics: LyricPosterTypeMetrics
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: context.scaled(4)) {
                Text(verbatim: "GOOD SONGS")
                Text(verbatim: "BRIGHTER PEOPLE")
            }
            .font(.system(size: metrics.captionFontSize * 0.82, weight: .semibold, design: .monospaced))
            .tracking(context.scaled(2))
            .foregroundStyle(ink.opacity(0.5))

            Spacer(minLength: 0)

            if let stamp = dateStamp(context: context) {
                Text(verbatim: stamp)
                    .font(.system(size: metrics.captionFontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(stampRed.opacity(0.85))
                    .padding(.horizontal, context.scaled(14))
                    .padding(.vertical, context.scaled(7))
                    .overlay(
                        RoundedRectangle(cornerRadius: context.scaled(4))
                            .stroke(stampRed.opacity(0.65), lineWidth: context.scaled(2))
                    )
                    .rotationEffect(.degrees(-1.5))
            }
        }
    }

    /// 年份来自歌曲信息；没有年份就不盖这个戳，而不是印一个今天的日期
    /// 假装是当年。
    private func dateStamp(context: LyricPosterRenderContext) -> String? {
        guard let year = context.content.year else { return nil }
        return String(year)
    }

    // MARK: 照片

    private func photoPrint(
        context: LyricPosterRenderContext,
        metrics: LyricPosterTypeMetrics
    ) -> some View {
        let side = photoSide(context)

        return VStack(spacing: context.scaled(14)) {
            ZStack(alignment: .bottomLeading) {
                if let artwork = context.artworkImage {
                    artwork
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .scaleEffect(context.artworkMotionScale)
                        .clipped()
                } else {
                    context.palette.backdropGradient
                        .frame(width: side, height: side)
                }

                // 手写歌名压在照片左下角，和设计稿一样。
                VStack(alignment: .leading, spacing: context.scaled(2)) {
                    Text(context.content.songTitle)
                        .font(.system(size: metrics.titleFontSize * 0.86, weight: .semibold, design: .serif))
                        .lineLimit(1)
                    if let artist = context.content.artistName {
                        Text(artist)
                            .font(.system(size: metrics.captionFontSize * 0.9, weight: .regular, design: .serif))
                            .italic()
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.6), radius: context.scaled(10))
                .padding(context.scaled(20))
            }
            .frame(width: side, height: side)

            Text(verbatim: "SOME SONGS STAY WITH US FOREVER")
                .font(.system(size: metrics.captionFontSize * 0.7, weight: .medium, design: .monospaced))
                .tracking(context.scaled(1.5))
                .foregroundStyle(ink.opacity(0.42))
                .frame(width: side, alignment: .leading)
        }
        .padding(context.scaled(28))
        .padding(.bottom, context.scaled(14))
        .background(Color(red: 0.976, green: 0.961, blue: 0.929))
        .shadow(color: .black.opacity(0.22), radius: context.scaled(26), y: context.scaled(12))
    }

    /// 相纸左右各贴一条半透明胶带。
    private func taped<Content: View>(
        context: LyricPosterRenderContext,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .rotationEffect(.degrees(-1.2))
            .overlay(alignment: .topLeading) {
                tape(context: context)
                    .rotationEffect(.degrees(-28))
                    .offset(x: -context.scaled(26), y: -context.scaled(18))
            }
            .overlay(alignment: .topTrailing) {
                tape(context: context)
                    .rotationEffect(.degrees(24))
                    .offset(x: context.scaled(26), y: -context.scaled(20))
            }
    }

    private func tape(context: LyricPosterRenderContext) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.42),
                        Color.white.opacity(0.24),
                        Color.white.opacity(0.42),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: context.scaled(150), height: context.scaled(46))
            .overlay(Rectangle().stroke(Color.white.opacity(0.3), lineWidth: context.scaled(1)))
    }

    // MARK: 文字

    private func titleBlock(
        context: LyricPosterRenderContext,
        metrics: LyricPosterTypeMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: context.scaled(6)) {
            Text(context.content.songTitle)
                .font(.system(size: metrics.titleFontSize, weight: .semibold, design: .serif))
                .foregroundStyle(ink)
                .lineLimit(2)

            if let subtitle = subtitleText(context) {
                Text(subtitle)
                    .font(.system(size: metrics.captionFontSize, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(ink.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private func subtitleText(_ context: LyricPosterRenderContext) -> String? {
        let parts = [context.content.artistName, context.content.albumTitle].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func footer(
        context: LyricPosterRenderContext,
        metrics: LyricPosterTypeMetrics
    ) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: context.scaled(2)) {
                if context.showsCredit {
                    Text(context.appName)
                        .font(.system(size: metrics.titleFontSize * 0.68, weight: .semibold, design: .serif))
                        .foregroundStyle(ink.opacity(0.78))
                    Text(verbatim: "Music Lives Beyond Listening")
                        .font(.system(size: metrics.captionFontSize * 0.74, weight: .regular, design: .monospaced))
                        .tracking(context.scaled(1.2))
                        .foregroundStyle(ink.opacity(0.42))
                }
            }
            Spacer(minLength: 0)
            LyricPosterWaveformView(context: context, tint: ink.opacity(0.55), barCount: 18)
                .frame(width: context.scaled(180), height: context.scaled(28))
        }
    }

    /// 右下角的圆形邮戳。
    private func postmark(
        context: LyricPosterRenderContext,
        metrics: LyricPosterTypeMetrics
    ) -> some View {
        let size = context.scaled(190)

        return ZStack {
            Circle()
                .strokeBorder(
                    stampRed.opacity(0.42),
                    style: StrokeStyle(lineWidth: context.scaled(3), dash: [context.scaled(9), context.scaled(7)])
                )
            Circle()
                .strokeBorder(stampRed.opacity(0.3), lineWidth: context.scaled(1.5))
                .padding(context.scaled(14))
            VStack(spacing: context.scaled(3)) {
                Text(verbatim: "MUSIC")
                Text(verbatim: "FOR A BRIGHTER")
                Text(verbatim: "TOMORROW")
            }
            .font(.system(size: metrics.captionFontSize * 0.6, weight: .bold, design: .monospaced))
            .tracking(context.scaled(1))
            .foregroundStyle(stampRed.opacity(0.5))
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-14))
        .position(
            x: context.size.width * 0.80,
            y: context.size.height * 0.62
        )
    }
}

// MARK: - 聚光

/// 深色底，大字歌词，唱到的那一句被主色点亮。设计稿里最像"海报"的一种。
struct SpotlightPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.spotlight, symbol: "sun.max", order: -2)

    private func coverHeight(_ context: LyricPosterRenderContext) -> CGFloat {
        context.size.height * 0.34
    }

    /// 封面 + 手写行 40 + 封面缩略 96 + 页脚 50 + 三段 spacing 120
    /// + 上下内边距 192。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics {
        context.metrics(
            textWidthRatio: 0.80,
            reservedHeight: Double(coverHeight(context)) + 498
        )
    }

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = metrics(for: context)
        let margin: CGFloat = (context.size.width - CGFloat(metrics.textWidth)) / 2
        let accent = context.palette.accent

        return AnyView(
            ZStack(alignment: .top) {
                Color(red: 0.055, green: 0.051, blue: 0.055)

                cover(context: context)

                VStack(alignment: .leading, spacing: context.scaled(40)) {
                    Spacer(minLength: coverHeight(context) * 0.82)

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        primaryStyle: AnyShapeStyle(Color.white),
                        pendingStyle: AnyShapeStyle(Color.white.opacity(0.24)),
                        translationStyle: AnyShapeStyle(Color.white.opacity(0.62)),
                        fontDesign: .default,
                        fontWeight: .bold,
                        shadow: .black.opacity(0.5),
                        highlightStyle: AnyShapeStyle(accent),
                        noteStyle: AnyShapeStyle(Color.white.opacity(0.66))
                    )

                    Spacer(minLength: 0)

                    Rectangle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: context.scaled(72), height: context.scaled(2))

                    footer(context: context, metrics: metrics)
                }
                .padding(.horizontal, margin)
                .padding(.vertical, context.scaled(96))

            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }

    private func cover(context: LyricPosterRenderContext) -> some View {
        ZStack(alignment: .bottom) {
            if let artwork = context.artworkImage {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(context.artworkMotionScale)
            } else {
                context.palette.backdropGradient
            }

            // 底部化进黑色，歌词才压得住。
            LinearGradient(
                colors: [
                    .clear,
                    Color(red: 0.055, green: 0.051, blue: 0.055).opacity(0.65),
                    Color(red: 0.055, green: 0.051, blue: 0.055),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: context.size.width, height: coverHeight(context) * 1.35)
        .clipped()
    }

    private func footer(
        context: LyricPosterRenderContext,
        metrics: LyricPosterTypeMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: context.scaled(26)) {
            LyricPosterCreditView(
                context: context,
                metrics: metrics,
                titleColor: .white,
                detailColor: .white.opacity(0.6),
                showsArtwork: context.hasArtwork,
                artworkCorner: 10
            )

            if context.showsCredit {
                HStack(spacing: context.scaled(16)) {
                    Text(context.appName)
                        .font(.system(size: metrics.captionFontSize, weight: .semibold, design: .default))
                        .tracking(context.scaled(3))
                        .foregroundStyle(.white.opacity(0.7))
                    LyricPosterWaveformView(
                        context: context,
                        tint: context.palette.accent.opacity(0.8),
                        barCount: 22
                    )
                    .frame(height: context.scaled(26))
                }
            }
        }
        .frame(width: metrics.textWidth, alignment: .leading)
    }
}

// MARK: - 动态歌词卡

/// 为实况照片设计的一张卡：封面旁边露出半张唱片，底部是声波。
/// 静止时它也成立，动起来才是它的主场。
struct MotionCardPosterStyle: LyricPosterStyleRendering {
    let descriptor = builtInPosterDescriptor(.motionCard, symbol: "opticaldisc.fill", order: -1)

    private func coverSide(_ context: LyricPosterRenderContext) -> CGFloat {
        min(context.size.width * 0.46, context.size.height * 0.28)
    }

    /// 封面与唱片 + 两段 spacing 112 + 署名 34 + 声波 72 + 手写落款 40
    /// + 上下内边距 160。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics {
        context.metrics(
            textWidthRatio: 0.74,
            reservedHeight: Double(coverSide(context)) + 418
        )
    }

    func makeBody(context: LyricPosterRenderContext) -> AnyView {
        let metrics = metrics(for: context)

        return AnyView(
            ZStack {
                LyricPosterArtworkBackdrop(context: context, blurRadius: 120, overlayOpacity: 0.52)

                VStack(spacing: context.scaled(56)) {
                    Spacer(minLength: 0)

                    coverWithDisc(context: context)

                    LyricPosterPassageView(
                        context: context,
                        metrics: metrics,
                        alignment: .center,
                        textAlignment: .center,
                        primaryStyle: AnyShapeStyle(Color.white),
                        pendingStyle: AnyShapeStyle(Color.white.opacity(0.26)),
                        translationStyle: AnyShapeStyle(Color.white.opacity(0.7)),
                        fontDesign: .rounded,
                        fontWeight: .semibold,
                        shadow: .black.opacity(0.45),
                        noteStyle: AnyShapeStyle(Color.white.opacity(0.72))
                    )

                    Spacer(minLength: 0)

                    VStack(spacing: context.scaled(18)) {
                        if context.showsCredit {
                            Text(context.appName)
                                .font(.system(size: metrics.captionFontSize, weight: .medium, design: .rounded))
                                .tracking(context.scaled(4))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        LyricPosterWaveformView(
                            context: context,
                            tint: .white.opacity(0.85),
                            barCount: 26
                        )
                        .frame(width: context.size.width * 0.42, height: context.scaled(34))

                        Text(verbatim: "Good Music  Better People")
                            .font(.system(size: metrics.captionFontSize * 0.88, weight: .regular, design: .serif))
                            .italic()
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.vertical, context.scaled(80))

            }
            .frame(width: context.size.width, height: context.size.height)
        )
    }

    /// 封面右侧露出半张黑胶。动态海报里唱片在转。
    private func coverWithDisc(context: LyricPosterRenderContext) -> some View {
        let side = coverSide(context)
        let discSize = side * 0.92
        let rotation: Double = context.isMotion ? context.time * 96 : -8

        return ZStack {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.20), Color(white: 0.05)],
                            center: .center,
                            startRadius: discSize * 0.16,
                            endRadius: discSize * 0.5
                        )
                    )
                ForEach(0..<6, id: \.self) { ring in
                    let ringScale = CGFloat(0.44 + Double(ring) * 0.08)
                    Circle()
                        .stroke(Color.white.opacity(0.07), lineWidth: context.scaled(1.4))
                        .frame(width: discSize * ringScale)
                }
                Circle()
                    .fill(context.palette.accent.opacity(0.85))
                    .frame(width: discSize * 0.24)
                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: discSize * 0.05)
            }
            .frame(width: discSize, height: discSize)
            .rotationEffect(.degrees(rotation))
            .offset(x: side * 0.46)

            if let artwork = context.artworkImage {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .scaleEffect(context.artworkMotionScale)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: context.scaled(18), style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: context.scaled(18), style: .continuous)
                    .fill(context.palette.backdropGradient)
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side * 1.5, height: side)
        .shadow(color: .black.opacity(0.45), radius: context.scaled(34), y: context.scaled(16))
    }
}
