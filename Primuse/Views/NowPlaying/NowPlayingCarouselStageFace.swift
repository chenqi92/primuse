#if os(iOS)
import PrimuseKit
import SwiftUI

/// 转轮的「舞台」一面:换个方式听。能唱卡拉 OK 时整面是卡拉 OK 舞台(停稳才挂真身,一挂上就开始分离人声、
/// 开麦克风),底下一排全屏效果的缩略卡;唱不了的歌(Apple Music 曲目)只留全屏效果,不出空壳。
///
/// 卡拉 OK 舞台顶上和别的面一样是转轮那一行(转盘、进全屏、回到播放器):舞台挂着、交给全屏、还是占位,
/// 都看得到去别的面和回播放器的路,不会只剩一页全屏的舞台。拖走、转走途中舞台留着(面的阶段转到别的页
/// 停稳才变),停到别的页后这一面整个卸掉真身(会话随之停下),下次再停稳在这里才挂。
struct NowPlayingCarouselStageFace: View {
    let context: NowPlayingCarouselFaceContext
    let appearance: NowPlayingAppearance
    let side: NowPlayingCarouselConfiguration.Side
    let safeInsets: EdgeInsets
    let state: NowPlayingCarouselState
    let onExpand: () -> Void
    let onReturnToPlayer: () -> Void
    let onPresentEffect: (FullscreenPlayerEffect) -> Void

    /// 整面有多高:矮屏上底下那一排全屏效果收成小胶囊(`NowPlayingCarouselStageLayout`)。
    @State private var faceHeight: CGFloat = 0

    /// 舞台上的字、键一律是深色舞台上的浅色。
    private static var stageAppearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: .dark, contrast: .standard)
    }

    var body: some View {
        if context.cards.contains(.karaoke) {
            karaokeStage
        } else {
            NowPlayingCarouselPanelPage(
                panel: .stage,
                side: side,
                safeInsets: safeInsets,
                appearance: appearance,
                onExpand: onExpand,
                onReturnToPlayer: onReturnToPlayer
            ) {
                NowPlayingCarouselCardStack {
                    if context.cards.contains(.fullscreenEffects) {
                        NowPlayingCarouselCardContainer(card: .fullscreenEffects, appearance: appearance) {
                            NowPlayingCarouselEffectShelfView(
                                layout: .grid,
                                showsPreviews: context.isSettled,
                                appearance: appearance,
                                onPresent: onPresentEffect
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: 卡拉 OK

    private var karaokeStage: some View {
        let showsStage = context.isSettled && !state.isKaraokeHandedOff
        return VStack(spacing: 0) {
            // 左边留给转轮的转盘(转盘画在转轮那一层,停在这一面时换浅色的字),右边进全屏、回到播放器。
            NowPlayingCarouselFaceHeader(
                side: side,
                safeInsets: safeInsets,
                appearance: Self.stageAppearance,
                onExpand: onExpand,
                onReturnToPlayer: onReturnToPlayer
            )
            .padding(.leading, safeInsets.leading)
            .padding(.trailing, safeInsets.trailing)

            ZStack {
                if showsStage {
                    // 收起、进全屏两颗键已经在上面那一行,舞台自己那一行只留歌名、分数与更多。
                    KaraokeStageView(onClose: onReturnToPlayer, isEmbeddedInCarousel: true)
                        .safeAreaPadding(EdgeInsets(
                            top: 0,
                            leading: safeInsets.leading,
                            // 底下有一排全屏效果时由那一排让开底部安全区。
                            bottom: context.cards.contains(.fullscreenEffects) ? 0 : safeInsets.bottom,
                            trailing: safeInsets.trailing
                        ))
                        .transition(.opacity)
                } else {
                    karaokePlaceholder
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if context.cards.contains(.fullscreenEffects) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("player_carousel_card_fullscreen_effects")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 20)
                    NowPlayingCarouselEffectShelfView(
                        layout: NowPlayingCarouselStageLayout.effectStrip(forFaceHeight: Double(faceHeight)) == .chips
                            ? .chips : .strip,
                        showsPreviews: context.isSettled,
                        appearance: Self.stageAppearance,
                        onPresent: onPresentEffect
                    )
                }
                .padding(.top, 10)
                .padding(.bottom, max(safeInsets.bottom, 12))
                .background(Color.black.opacity(0.28).ignoresSafeArea(edges: .bottom))
            }
        }
        .background {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.05, blue: 0.14), Color(red: 0.03, green: 0.02, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.3), value: showsStage)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { faceHeight = $0 }
        .nowPlayingCarouselPinchToExpand(onExpand)
    }

    /// 预先挂着、拖进来、转到位途中、交给全屏的那一会儿画一张同色调的占位(顶上那一行照样在)。
    private var karaokePlaceholder: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(NowPlayingCarouselPanel.stage.tint.gradient)
                    .frame(width: 88, height: 88)
                    .shadow(color: NowPlayingCarouselPanel.stage.tint.opacity(0.5), radius: 24)
                Image(systemName: NowPlayingCarouselPanel.stage.symbolName)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("karaoke_title")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("player_carousel_karaoke_hint")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 全屏效果一排

/// 全屏效果的缩略卡:当前选定的在最前(标着「当前」),然后是最近从转轮进过的,不够按推荐补。点一张就以那一种
/// 进全屏;这只是这一次,不改设置里选定的效果。缩略图是真实舞台的静止一帧,转停在这一面以后才一张接一张换上,
/// 转动途中先放图标(换上那一下要建整套舞台,放在转动途中会把转动卡成一跳)。
struct NowPlayingCarouselEffectShelfView: View {
    enum Layout {
        /// 一排横着滑(卡拉 OK 舞台底下)。
        case strip
        /// 同一排收成图标加名字的小胶囊(矮屏上的卡拉 OK 舞台底下)。
        case chips
        /// 两列铺开(唱不了卡拉 OK 时这一面只有它)。
        case grid
    }

    let layout: Layout
    let showsPreviews: Bool
    let appearance: NowPlayingAppearance
    let onPresent: (FullscreenPlayerEffect) -> Void

    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var selectedRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(NowPlayingCarouselEffectShelf.recentStorageKey) private var recentStorage = ""
    @Environment(ThemeService.self) private var theme
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    /// 没用过几种时按这个顺序补:频谱、封面流、动态歌词这几种和转轮的几面最搭。
    private static let suggestions: [FullscreenPlayerEffect] = [
        .spectrumHorizon, .albumFlow, .kineticLyrics, .vinylDeck, .auroraVeil, .radialPulse, .coverGallery,
    ]

    private var effects: [FullscreenPlayerEffect] {
        let selected = FullscreenPlayerEffect(rawValue: selectedRawValue) ?? .defaultValue
        let ids = NowPlayingCarouselEffectShelf.shelf(
            current: selected.rawValue,
            recent: NowPlayingCarouselEffectShelf.decodeRecent(recentStorage),
            suggestions: Self.suggestions.map(\.rawValue),
            available: FullscreenPlayerEffect.allCases.map(\.rawValue)
        )
        return ids.compactMap(FullscreenPlayerEffect.init(rawValue:))
    }

    var body: some View {
        let selected = FullscreenPlayerEffect(rawValue: selectedRawValue) ?? .defaultValue
        let palette = ImmersiveArtworkPalette(primary: theme.accentColor, secondary: theme.secondaryDarkAccent)
        switch layout {
        case .strip:
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                        tile(effect, sequence: index, isSelected: effect == selected, palette: palette, width: 124)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .nowPlayingCarouselHorizontalRegion()
        case .chips:
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(effects) { effect in
                        chip(effect, isSelected: effect == selected)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .nowPlayingCarouselHorizontalRegion()
        case .grid:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 14) {
                ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                    tile(effect, sequence: index, isSelected: effect == selected, palette: palette, width: nil)
                }
            }
        }
    }

    private func chip(_ effect: FullscreenPlayerEffect, isSelected: Bool) -> some View {
        Button { onPresent(effect) } label: {
            HStack(spacing: 6) {
                Image(systemName: effect.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: effect.localizedTitle)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(appearance.primary.opacity(isSelected ? 1 : 0.82))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(appearance.primary.opacity(isSelected ? 0.2 : 0.1)))
            .overlay {
                Capsule().strokeBorder(appearance.primary.opacity(isSelected ? 0.7 : 0), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.pmPressable)
        .accessibilityLabel(Text(verbatim: effect.localizedTitle))
        .accessibilityHint(Text("player_carousel_effect_hint"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tile(
        _ effect: FullscreenPlayerEffect,
        sequence: Int,
        isSelected: Bool,
        palette: ImmersiveArtworkPalette,
        width: CGFloat?
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { onPresent(effect) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ImmersiveEffectThumbnail(
                    effect: effect,
                    palette: palette,
                    sequence: sequence,
                    // 转停那一下卡拉 OK 舞台也正挂上来,让它先。
                    startDelay: 0.12,
                    isEnabled: showsPreviews,
                    song: .current(player: player, library: library)
                )
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: width)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(
                        isSelected ? appearance.primary.opacity(0.85) : appearance.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
                }
                .overlay(alignment: .topLeading) {
                    if isSelected {
                        Text("player_carousel_effect_current")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .padding(6)
                    }
                }

                Text(verbatim: effect.localizedTitle)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(appearance.primary.opacity(isSelected ? 1 : 0.8))
                    .lineLimit(1)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pmPressable)
        .accessibilityLabel(Text(verbatim: effect.localizedTitle))
        .accessibilityHint(Text("player_carousel_effect_hint"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
