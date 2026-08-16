#if os(iOS)
import SwiftUI

/// 轻量的全屏效果选择页。列表不创建 TimelineView、Canvas 或实时频谱，
/// 真正的动态渲染只在进入全屏播放器后启动。
struct FullscreenPlayerEffectSettingsView: View {
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var selectedRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue

    private var selectedEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: selectedRawValue) ?? .defaultValue
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

                            ForEach(collection.effects) { effect in
                                effectCard(effect)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("immersive_lyrics_motion_title")
                    .font(.system(size: 16, weight: .semibold))
                Text("immersive_lyrics_motion_subtitle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(ImmersiveStagePalette.accent600)
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
            HStack(spacing: 15) {
                EffectMechanismThumbnail(effect: effect)
                    .frame(width: 82, height: 82)

                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: effect.localizedTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(verbatim: effect.localizedSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Label(effect.motionDescription, systemImage: effect.usesRealtimeSpectrum ? "waveform" : "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(effect.previewAccent)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? effect.previewAccent : Color.secondary.opacity(0.45))
                    .symbolRenderingMode(.hierarchical)
            }
            .padding(13)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        selected ? effect.previewAccent.opacity(0.85) : Color.primary.opacity(0.07),
                        lineWidth: selected ? 1.4 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: effect.localizedTitle))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct EffectMechanismThumbnail: View {
    let effect: FullscreenPlayerEffect

    var body: some View {
        ZStack {
            LinearGradient(
                colors: effect.previewColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 72
            )

            Image(systemName: effect.symbolName)
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(.white.opacity(0.93))
                .symbolRenderingMode(.hierarchical)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.7)
        }
    }
}

private extension FullscreenPlayerEffect {
    var previewAccent: Color {
        switch self {
        case .native: .secondary
        case .coverFlow: Color(red: 0.49, green: 0.39, blue: 0.92)
        case .coverGallery: Color(red: 0.44, green: 0.53, blue: 0.93)
        case .starryNight: Color(red: 0.39, green: 0.59, blue: 0.98)
        case .flowingLines: Color(red: 0.58, green: 0.49, blue: 0.96)
        case .lightRhythm: Color(red: 0.68, green: 0.43, blue: 0.93)
        case .kineticTitle: Color(red: 0.53, green: 0.49, blue: 0.89)
        case .radialPulse: Color(red: 0.48, green: 0.55, blue: 1.00)
        case .liveWaveform: Color(red: 0.38, green: 0.68, blue: 0.96)
        }
    }

    var previewColors: [Color] {
        switch self {
        case .native: [Color(red: 0.22, green: 0.23, blue: 0.27), Color(red: 0.10, green: 0.11, blue: 0.14)]
        case .coverFlow: [Color(red: 0.38, green: 0.26, blue: 0.74), Color(red: 0.08, green: 0.09, blue: 0.19)]
        case .coverGallery: [Color(red: 0.24, green: 0.31, blue: 0.58), Color(red: 0.05, green: 0.06, blue: 0.11)]
        case .starryNight: [Color(red: 0.13, green: 0.21, blue: 0.47), Color(red: 0.03, green: 0.04, blue: 0.10)]
        case .flowingLines: [Color(red: 0.30, green: 0.24, blue: 0.57), Color(red: 0.04, green: 0.05, blue: 0.11)]
        case .lightRhythm: [Color(red: 0.46, green: 0.24, blue: 0.68), Color(red: 0.10, green: 0.10, blue: 0.27)]
        case .kineticTitle: [Color(red: 0.27, green: 0.25, blue: 0.46), Color(red: 0.05, green: 0.06, blue: 0.11)]
        case .radialPulse: [Color(red: 0.25, green: 0.29, blue: 0.64), Color(red: 0.04, green: 0.05, blue: 0.12)]
        case .liveWaveform: [Color(red: 0.18, green: 0.37, blue: 0.66), Color(red: 0.05, green: 0.07, blue: 0.16)]
        }
    }
}
#endif
