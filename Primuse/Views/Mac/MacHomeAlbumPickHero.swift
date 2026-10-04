#if os(macOS)
import SwiftUI
import PrimuseKit

/// 首页主卡的尺寸。叙事版与情景推荐版共用一个高度。
enum MacHomeHeroMetrics {
    static let height: CGFloat = 296
    /// 主卡至少这么宽时「接着听」排在卡内右侧一列, 窄了就排到主内容下面。
    /// 右侧一列时主卡最窄约 900 (封面 240 + 按钮收成图标的文字列 + 260 宽的一列),
    /// 必须小于这个阈值: 否则窗口缩到阈值以下时主卡会把窗口顶回来, 再也切不回窄排法。
    static let resumeColumnMinWidth: CGFloat = 960
    /// 上次量到的主卡宽度。主卡在叙事版与推荐版之间换、或离开首页再回来时,
    /// 新的一张从这个宽度起排, 不会先按另一种排法画一帧再跳过去。只在主线程读写。
    nonisolated(unsafe) static var lastMeasuredWidth: CGFloat = 0
}

/// 「接着听」在主卡里的位置。
enum MacHomeResumePlacement {
    /// 主内容右边一列, 宽度定死。
    case column(width: CGFloat)
    /// 主内容下面一行, 几张平分。
    case band
}

/// 首页主卡的外壳: 暖色背板, 主内容在左。「接着听」是这张卡的一部分而不是旁边另一张卡 ——
/// 卡够宽时在右侧一列, 窄了排到主内容下面。没有能接着听的东西时 `resume` 什么都不画,
/// 主内容独占整张卡。
struct MacHomeHeroCard<Base: View, Content: View, Resume: View>: View {
    @ViewBuilder let resume: (MacHomeResumePlacement) -> Resume
    /// 最底下那层底色。叙事版把它做成整张卡的点击区。
    @ViewBuilder let base: Base
    @ViewBuilder let content: Content

    @State private var width = MacHomeHeroMetrics.lastMeasuredWidth

    /// 主内容区的高度: 卡高减去上下留白。
    private static var contentHeight: CGFloat { MacHomeHeroMetrics.height - 2 * PMSpace.l24 }

    /// 右侧一列的宽度: 随卡宽在 260–320 之间。
    private var columnWidth: CGFloat {
        min(320, max(260, width * 0.27))
    }

    var body: some View {
        Group {
            // 还没量到宽度时先按右侧一列排: 首页多半在宽窗口里打开。
            if width == 0 || width >= MacHomeHeroMetrics.resumeColumnMinWidth {
                HStack(alignment: .center, spacing: PMSpace.xl) {
                    content
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    resume(.column(width: columnWidth))
                }
                .frame(height: Self.contentHeight)
            } else {
                VStack(alignment: .leading, spacing: PMSpace.l) {
                    content
                        .frame(height: Self.contentHeight)
                    resume(.band)
                }
            }
        }
        .padding(.horizontal, PMSpace.xxl)
        .padding(.vertical, PMSpace.l24)
        // 不向窗口要最小宽度: 右侧一列时的最小宽度一旦超过切换阈值, 窗口就缩不回窄排法了。
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
            MacHomeHeroMetrics.lastMeasuredWidth = newWidth
        }
        // 背板放在 background 里: 卡的大小只由内容决定, 窄排法下卡随「接着听」长高时背板跟着铺满。
        .background {
            ZStack {
                base
                // Hero 的 ambient 用固定 brand 暖色, 不跟 theme.accentColor 走。
                // AmbientBackdrop 内部用 blur + offset 把色圈推到卡外, 不靠内部 clipShape
                // (drawingGroup 栅格化会让 clip 失效), 在最外层统一裁剪。
                AmbientBackdrop(
                    accent: PMColor.brand,
                    darkAccent: PMColor.brand.opacity(0.55),
                    strength: 0.72
                )
                // 色斑是 720 见方的固定圆, 不让它把主卡撑到 720 宽: 窄窗口下主卡会越出右边。
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        // 整张卡裁到圆角矩形 —— 色圈的 blur 会越界, 不切的话暖色会漏到卡的上下方。
        .clipShape(RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous))
        // 边框 + 收紧的浮动阴影 (半径小, 免得阴影把卡边的暖色又扩散回外面)。
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }
}

/// Mac 首页主卡的情景推荐版:原来的「叙事文案 + 封面拼贴」换成此刻情景下推荐的一整张
/// 专辑 —— 单张封面、情景标题(通勤路上 / 周末午后 / 睡前…)、推荐理由,整张播放、
/// 换一张,以及原有的随机播放整个曲库。推荐与 iPhone 首页、电视首页同源
/// (`AlbumRecommendationService`)。
struct MacHomeAlbumPickHero<Resume: View>: View {
    let pick: AlbumRecommendation
    let album: Album
    let moment: ListeningMoment
    let canShowAnother: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAnother: () -> Void
    let onDismiss: () -> Void
    let onShuffleLibrary: () -> Void
    /// 同一张卡里的「接着听」。
    @ViewBuilder let resume: (MacHomeResumePlacement) -> Resume

    var body: some View {
        MacHomeHeroCard(resume: resume) {
            Rectangle().fill(PMColor.bgElev)
        } content: {
            HStack(alignment: .center, spacing: 36) {
                NavigationLink(value: album) {
                    AlbumArtworkView(album: album, size: 240, cornerRadius: PMRadius.l)
                        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                }
                .buttonStyle(.plain)
                .help(Text("go_to_album"))
                .contextMenu { menu }

                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: moment.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))

                    NavigationLink(value: album) {
                        Text(verbatim: pick.title)
                            .font(.system(size: 36, weight: .bold))
                            .tracking(-0.7)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)

                    Text(verbatim: [pick.artistName, pick.detailLine].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)

                    Label(pick.reason.text, systemImage: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)

                    // 窗口窄、或卡里排着「接着听」时文字列放不下三颗带字按钮,
                    // 后两颗收成只有图标的圆钮(悬停有说明)。
                    ViewThatFits(in: .horizontal) {
                        actionButtons(compact: false)
                        actionButtons(compact: true)
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            // 换一张时只有这一块淡入, 同卡里的「接着听」不跟着闪。
            .id(pick.albumID)
            .pmAppearFade(.contentAppear)
        }
    }

    private func actionButtons(compact: Bool) -> some View {
        HStack(spacing: PMSpace.s10) {
            Button(action: onPlay) {
                Label("album_pick_play", systemImage: "play.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(PMColor.brand, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .shadow(color: PMColor.brand.opacity(0.45), radius: 10, y: 4)
            .accessibilityIdentifier("macHome.albumPick.play")

            glassButton("album_pick_another", symbol: "arrow.triangle.2.circlepath", compact: compact, action: onAnother)
                .disabled(!canShowAnother)
                .accessibilityIdentifier("macHome.albumPick.another")

            glassButton("shuffle_all", symbol: "shuffle", compact: compact, action: onShuffleLibrary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func glassButton(
        _ title: LocalizedStringKey,
        symbol: String,
        compact: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if compact {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.18), in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.24), lineWidth: 0.5) }
                    .foregroundStyle(.white)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text(title))
            .accessibilityLabel(Text(title))
        } else {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 13.5, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 0.5) }
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(action: onPlay) {
            Label("album_pick_play", systemImage: "play.fill")
        }
        Button(action: onPlayNext) {
            Label("album_pick_play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button(action: onAddToQueue) {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Divider()
        Button(action: onDismiss) {
            Label("album_pick_dismiss", systemImage: "hand.thumbsdown")
        }
    }
}
#endif
