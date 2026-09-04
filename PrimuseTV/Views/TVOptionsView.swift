#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 正在播放选项覆层 — 底部动作网格(对应 TVOptionsArtboard)。
/// Apple TV 无右键,长按 select / 菜单键升起此层。
struct TVOptionsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private struct Action: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        var on: Bool = false
        let run: () -> Void
    }

    // 仅保留已真实接通的动作(其余如「加入歌单/相似歌曲/AirPlay 输出」需额外基建,
    // 暂不放占位假按钮)。
    private var actions: [Action] {
        let liked = store.currentSongID.map(store.isLiked) ?? false
        let sleepOn = store.sleepTimerMinutes > 0
        return [
            .init(icon: liked ? "heart.fill" : "heart",
                  label: liked ? PMString("ext.tv.options.loved") : PMString("ext.tv.options.love"), on: liked,
                  run: { if let id = store.currentSongID { store.toggleLiked(id) } }),
            .init(icon: "moon.zzz.fill",
                  label: sleepOn ? PMString("ext.tv.options.sleepActive", store.sleepTimerMinutes) : PMString("ext.tv.options.sleepTimer"), on: sleepOn,
                  run: { store.cycleSleepTimer() }),
        ]
    }

    var body: some View {
        let np = store.nowPlaying
        let colors = store.nowPlayingPresentationColors
        ZStack {
            TVAmbientBackdrop(tint: colors.primary, tint2: colors.secondary, strength: 0.5)
            TVColor.bg.opacity(0.52).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                                  songID: np.songID, coverRef: np.coverRef,
                                  tint: colors.primary, tint2: colors.secondary,
                                  glyph: np.glyph, size: 140, radius: 14)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(np.title).font(.system(size: 36, weight: .bold)).foregroundStyle(TVColor.text)
                        Text(np.artist).font(.system(size: 22)).foregroundStyle(TVColor.textMuted)
                    }
                    Spacer()
                }
                Rectangle()
                    .fill(TVColor.divider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 24) {
                    TVEyebrow(text: PMString("ext.tv.options.eyebrow"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(actions) { a in actionTile(a) }
                        }
                        .padding(.vertical, 18)
                        .padding(.horizontal, 18)
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 900, alignment: .leading)
            .tvPanel(radius: 24)
            .padding(.horizontal, 100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onExitCommand { dismiss() }
        .onAppear { FullscreenPlayerEffectSync.shared.install() }
    }

    private func actionTile(_ a: Action) -> some View {
        // 不 dismiss:执行后菜单保留,用户能看到状态变化(喜欢/睡眠定时切换);按返回键关闭。
        TVFocusButton(radius: 16, scale: 1.05, lift: 4, action: { a.run() }) { focused in
            VStack(spacing: 14) {
                Image(systemName: a.icon).font(.system(size: 40, weight: .regular))
                    .foregroundStyle(focused ? TVColor.onBrand : (a.on ? TVColor.brand : TVColor.text))
                Text(a.label).font(.system(size: 18, weight: focused ? .bold : .medium))
                    .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
            }
            .frame(width: 150, height: 150)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surfaceStrong))
        }
        .accessibilityAddTraits(a.on ? [.isButton, .isSelected] : .isButton)
    }
}

struct TVFullscreenEffectPicker: View {
    @Environment(TVStore.self) private var store
    @Binding var selectedRawValue: String
    @Binding var lyricsMotionEnabled: Bool
    let onDismiss: () -> Void

    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.coverDrivenAmbientKey)
    private var coverDrivenAmbient = AppThemePreferences.defaultCoverDrivenAmbient

    @FocusState private var focusedEffect: FullscreenPlayerEffect?
    @FocusState private var lyricsToggleFocused: Bool

    private var selectedEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: selectedRawValue) ?? .defaultValue
    }

    private var previewPalette: ImmersiveArtworkPalette {
        let playbackColors = store.nowPlayingPresentationColors
        return ImmersiveArtworkPalette(
            primary: coverDrivenAmbient ? playbackColors.primary : TVColor.brand(hex: accentHex),
            secondary: coverDrivenAmbient ? playbackColors.secondary : TVColor.brandSecondary(hex: accentHex)
        )
    }

    var body: some View {
        GeometryReader { _ in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(PMString("ext.tv.settings.immersive"))
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Button {
                            lyricsMotionEnabled.toggle()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(
                                    PMString("immersive_lyrics_motion_title"),
                                    systemImage: lyricsMotionEnabled ? "checkmark.circle.fill" : "circle"
                                )
                                    .font(.system(size: 19, weight: .semibold))
                                Text(PMString("immersive_lyrics_motion_subtitle"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.58))
                            }
                            .foregroundStyle(lyricsMotionEnabled ? previewPalette.primary : .white.opacity(0.82))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 13)
                            .background(.white.opacity(lyricsToggleFocused ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
                            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.20), lineWidth: 1) }
                            .tvFocusRing(lyricsToggleFocused, radius: 14, accent: .white, scale: 1.04, lift: 5)
                        }
                        .buttonStyle(TVBareButtonStyle())
                        .focused($lyricsToggleFocused)
                        .focusEffectDisabled()
                        .accessibilityAddTraits(
                            lyricsMotionEnabled ? [.isButton, .isSelected] : .isButton
                        )
                    }

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(FullscreenEffectCollection.allCases) { collection in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(collection.title)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.66))

                                    LazyVGrid(columns: columns, spacing: 18) {
                                        ForEach(collection.effects) { candidate in
                                            effectChoice(candidate)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 70)
                .padding(.vertical, 46)
            }
        }
        .focusSection()
        .onAppear { focusedEffect = selectedEffect }
        .accessibilityAddTraits(.isModal)
        .environment(\.colorScheme, .dark)
    }

    private func effectChoice(_ candidate: FullscreenPlayerEffect) -> some View {
        let focused = focusedEffect == candidate
        let selected = selectedEffect == candidate
        return Button {
            selectedRawValue = candidate.rawValue
            FullscreenPlayerEffectSync.shared.select(candidate)
            onDismiss()
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                ImmersiveEffectPreview(
                    effect: candidate,
                    isActive: focused || selected,
                    palette: previewPalette
                )
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(selected ? previewPalette.primary : .white.opacity(0.56))
                        .symbolRenderingMode(.hierarchical)
                        .padding(10)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.localizedTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(candidate.localizedSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                    Label(candidate.motionDescription, systemImage: "waveform.path")
                        .font(.system(size: 12))
                        .foregroundStyle(previewPalette.primary.opacity(0.84))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? previewPalette.primary : .white.opacity(0.90))
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.white.opacity(focused ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? previewPalette.primary : .white.opacity(0.20), lineWidth: selected ? 2 : 1)
            }
            .tvFocusRing(focused, radius: 14, accent: .white, scale: 1.04, lift: 6)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedEffect, equals: candidate)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
