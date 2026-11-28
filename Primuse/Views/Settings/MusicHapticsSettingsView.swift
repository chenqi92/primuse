import PrimuseKit
import SwiftUI

extension MusicHapticsStyle {
    var displayName: String {
        switch self {
        case .balanced: String(localized: "music_haptics_style_balanced")
        case .bassFocus: String(localized: "music_haptics_style_bass_focus")
        case .rhythmFocus: String(localized: "music_haptics_style_rhythm_focus")
        case .subtle: String(localized: "music_haptics_style_subtle")
        case .immersive: String(localized: "music_haptics_style_immersive")
        }
    }

    var symbolName: String {
        switch self {
        case .balanced: "waveform.path"
        case .bassFocus: "speaker.wave.3.fill"
        case .rhythmFocus: "metronome.fill"
        case .subtle: "wind"
        case .immersive: "sparkles"
        }
    }
}

#if os(iOS)
/// Settings → Playback → Music Haptics (iOS, #469).
struct MusicHapticsSettingsView: View {
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(AudioPlayerService.self) private var player

    private static let styleColumns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        @Bindable var settings = playbackSettings
        let hardwareSupported = MusicHapticsEngine.isHardwareSupported
        let isHighFidelity = settings.outputMode == .highFidelity

        Form {
            if !hardwareSupported {
                Section {
                    Label("music_haptics_unsupported", systemImage: "iphone.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Toggle("music_haptics_enabled", isOn: $settings.musicHapticsEnabled.pmAnimated())
                        .settingsAnchor("playback.musicHaptics")
                }
                .disabled(isHighFidelity)

                if settings.musicHapticsEnabled {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("music_haptics_intensity")
                                Spacer()
                                Text("\(Int((settings.musicHapticsIntensity * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: $settings.musicHapticsIntensity,
                                in: MusicHapticsConfiguration.intensityRange,
                                step: 0.05
                            ) {
                                Text("music_haptics_intensity")
                            } minimumValueLabel: {
                                Text("music_haptics_intensity_subtle").font(.caption2)
                            } maximumValueLabel: {
                                Text("music_haptics_intensity_strong").font(.caption2)
                            } onEditingChanged: { editing in
                                if !editing {
                                    player.musicHapticsEngine.playPreviewPulse(
                                        style: settings.musicHapticsStyle,
                                        intensity: settings.musicHapticsIntensity
                                    )
                                }
                            }
                        }
                    }
                    .disabled(isHighFidelity)
                    .pmFadeTransition()

                    Section {
                        LazyVGrid(columns: Self.styleColumns, spacing: 8) {
                            ForEach(MusicHapticsStyle.allCases) { style in
                                styleTile(
                                    style,
                                    isSelected: settings.musicHapticsStyle == style
                                ) {
                                    settings.musicHapticsStyle = style
                                    player.musicHapticsEngine.playPreviewPulse(
                                        style: style,
                                        intensity: settings.musicHapticsIntensity
                                    )
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    } header: {
                        Text("music_haptics_style")
                    }
                    .disabled(isHighFidelity)
                    .pmFadeTransition()
                }
            }
        }
        .navigationTitle("music_haptics_title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func styleTile(
        _ style: MusicHapticsStyle,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: style.symbolName)
                    .font(.title3)
                    .frame(height: 24)
                Text(verbatim: style.displayName)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 68)
            .padding(.horizontal, 6)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                in: shape
            )
            .overlay {
                shape.strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
