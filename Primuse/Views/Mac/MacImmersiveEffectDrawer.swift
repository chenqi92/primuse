#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// macOS 的全屏效果抽屉。
///
/// 原先三个入口各自弹一块清单：底栏是系统菜单，全屏与沉浸页是贴在按钮下方的
/// 浮动面板，列的都是图标加两行说明 —— 选之前看不见效果长什么样，跟 iOS 的缩略图
/// 转轮、tvOS 的预览网格完全不是一回事。这里统一成从窗口右侧滑入的抽屉，卡片用的
/// 是与另外两端同一份真实舞台缩略图（`ImmersiveEffectPreview`）。
///
/// 遮罩与滑入过渡由宿主负责：宿主才知道抽屉开着，要继续暂停浮动控件的自动隐藏。
struct MacImmersiveEffectDrawer: View {
    let selected: FullscreenPlayerEffect
    /// 要列出的效果。分组标题按 `FullscreenEffectCollection` 的顺序排，只显示有内容的组。
    let effects: [FullscreenPlayerEffect]
    let palette: ImmersiveArtworkPalette
    /// 顶部要额外让开的高度。全屏时是系统菜单栏，见 `PMFullScreenChrome`。
    var topInset: CGFloat = 0
    let onSelect: (FullscreenPlayerEffect) -> Void
    let onClose: () -> Void

    @State private var hoveredID: String?

    var body: some View {
        panel
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onClose)
    }

    // MARK: - 面板

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            wheel
        }
        .frame(width: Self.panelWidth)
        .frame(maxHeight: .infinity)
        .background { surface }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("fullscreen_effect_settings_title")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ImmersiveStagePalette.ink)
                    .lineLimit(1)
                Text(verbatim: selected.localizedTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.primary.opacity(0.92))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .pmAnimation(.control, value: selected.id)
            }
            Spacer(minLength: 8)
            ImmersiveGlassActionButton(
                symbol: "xmark",
                label: "close",
                diameter: Self.closeButtonDiameter,
                action: onClose
            )
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.top, topInset + Self.headerTopPadding)
        .padding(.bottom, 14)
    }

    private var wheel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // 十四张卡片一次建好,不用 Lazy 容器:惰性容器会在滚动途中一行一行装载,
            // 每装一行就是一轮 SwiftUI 更新,主窗口的自定义标题栏跟着逐帧重算,
            // 左上角的红绿灯就会抖。卡片都停在静态帧,一次建好并不贵。
            VStack(alignment: .leading, spacing: 20) {
                ForEach(groups, id: \.collection.id) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: group.collection.title)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(ImmersiveStagePalette.text.opacity(0.52))

                        ForEach(group.effects) { effect in
                            card(effect)
                        }
                    }
                }
            }
            .padding(.horizontal, Self.contentInset)
            .padding(.bottom, 26)
        }
        .frame(maxHeight: .infinity)
    }

    private func card(_ effect: FullscreenPlayerEffect) -> some View {
        let isCurrent = effect == selected
        let isHovered = hoveredID == effect.id
        return Button {
            onSelect(effect)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                // 卡片一律停在静态帧,指针划过只换描边和底色:缩略图里是完整的舞台
                // （Canvas、实时模糊），让其中一张动起来就等于指针停在抽屉上的整段时间
                // 窗口都在逐帧重绘。真正在动的预览是选中效果之后的全屏本身。
                ImmersiveEffectPreview(effect: effect, isActive: false, palette: palette)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                            .strokeBorder(
                                isCurrent
                                    ? palette.primary.opacity(0.92)
                                    : Color.white.opacity(isHovered ? 0.32 : 0.12),
                                lineWidth: isCurrent ? 1.6 : 0.8
                            )
                    }
                    .overlay(alignment: .topTrailing) {
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(palette.primary)
                                .symbolRenderingMode(.hierarchical)
                                .padding(8)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: effect.localizedTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isCurrent ? palette.primary : ImmersiveStagePalette.ink)
                        .lineLimit(1)
                    Text(verbatim: effect.motionDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(ImmersiveStagePalette.text.opacity(0.58))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 缩略图自己关掉了命中测试，不补一层整卡的命中形状就只有文字那两行点得动。
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: Self.cardCornerRadius + 6, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0.03))
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius + 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .pmPointingHand()
        .onHover { hovering in
            pmWithAnimation(.control) {
                if hovering {
                    hoveredID = effect.id
                } else if hoveredID == effect.id {
                    hoveredID = nil
                }
            }
        }
        .accessibilityLabel(Text(verbatim: effect.localizedTitle))
        .accessibilityValue(Text(verbatim: effect.motionDescription))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// 靠内的一侧圆角，贴边的一侧切平 —— 与 iOS 抽屉同一套外观。
    private var surface: some View {
        let outline = UnevenRoundedRectangle(
            topLeadingRadius: Self.panelCornerRadius,
            bottomLeadingRadius: Self.panelCornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
        return ZStack {
            Rectangle().fill(.ultraThinMaterial)
            ImmersiveStagePalette.obsidian.opacity(0.78)
            LinearGradient(
                colors: [
                    palette.secondary.opacity(0.56),
                    palette.primary.opacity(0.18),
                    ImmersiveStagePalette.obsidian.opacity(0.94),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .environment(\.colorScheme, .dark)
        .clipShape(outline)
        .overlay {
            outline.strokeBorder(ImmersiveStagePalette.ink.opacity(0.18), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.44), radius: 28)
    }

    // MARK: - 分组

    private struct Group {
        let collection: FullscreenEffectCollection
        let effects: [FullscreenPlayerEffect]
    }

    private var groups: [Group] {
        let available = Set(effects.map(\.id))
        return FullscreenEffectCollection.allCases.compactMap { collection in
            let members = collection.effects.filter { available.contains($0.id) }
            return members.isEmpty ? nil : Group(collection: collection, effects: members)
        }
    }

    // MARK: - 尺寸

    static let panelWidth: CGFloat = 330
    private static let contentInset: CGFloat = 18
    private static let headerTopPadding: CGFloat = 20
    private static let closeButtonDiameter: CGFloat = 30
    private static let cardCornerRadius: CGFloat = 12
    private static let panelCornerRadius: CGFloat = 22
}
#endif
