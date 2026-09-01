#if os(iOS)
import SwiftUI

/// 全屏效果选择页直接缩放正式舞台作为预览。只有当前选中的卡片运行动画，
/// 其余卡片停在真实静态帧，避免设置页同时启动多套高频渲染。
struct FullscreenPlayerEffectSettingsView: View {
    @Environment(ThemeService.self) private var theme
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var selectedRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue

    private var selectedEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: selectedRawValue) ?? .defaultValue
    }

    private var previewPalette: ImmersiveArtworkPalette {
        ImmersiveArtworkPalette(primary: theme.accentColor, secondary: theme.secondaryDarkAccent)
    }

    private var previewColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                lyricsMotionCard

                ForEach(FullscreenEffectCollection.allCases) { collection in
                    if !collection.effects.isEmpty {
                        VStack(alignment: .leading, spacing: 11) {
                            Text(collection.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            LazyVGrid(columns: previewColumns, alignment: .leading, spacing: 12) {
                                ForEach(collection.effects) { effect in
                                    effectCard(effect)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("fullscreen_effect_settings_title")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            if selectedRawValue != selectedEffect.rawValue {
                selectedRawValue = selectedEffect.rawValue
            }
        }
    }

    private var lyricsMotionCard: some View {
        Toggle(isOn: $lyricsMotionEnabled) {
            Text("immersive_lyrics_motion_title")
                .font(.system(size: 16, weight: .semibold))
        }
        .accessibilityHint(Text("immersive_lyrics_motion_subtitle"))
        .tint(previewPalette.primary)
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func effectCard(_ effect: FullscreenPlayerEffect) -> some View {
        let selected = selectedEffect == effect
        return Button {
            selectedRawValue = effect.rawValue
            FullscreenPlayerEffectSync.shared.select(effect)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                ImmersiveEffectPreview(
                    effect: effect,
                    isActive: selected,
                    palette: previewPalette
                )
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(selected ? previewPalette.primary : .white.opacity(0.58))
                            .symbolRenderingMode(.hierarchical)
                            .padding(10)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                selected ? previewPalette.primary.opacity(0.90) : .white.opacity(0.13),
                                lineWidth: selected ? 1.6 : 0.7
                            )
                    }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: effect.localizedTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Label(
                            effect.motionDescription,
                            systemImage: effect.usesRealtimeSpectrum ? "waveform" : "sparkles"
                        )
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(previewPalette.primary)
                        .lineLimit(1)
                    }

                    Text(verbatim: effect.localizedSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        selected ? previewPalette.primary.opacity(0.85) : Color.primary.opacity(0.07),
                        lineWidth: selected ? 1.4 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: effect.localizedTitle))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
