import SwiftUI

struct AudioEffectsView: View {
    @Environment(AudioEffectsService.self) private var effects

    var body: some View {
        @Bindable var fx = effects

        Form {
            // MARK: - Reverb Section

            Section {
                Toggle("reverb_enabled", isOn: $fx.reverbEnabled)

                if effects.reverbEnabled {
                    // Preset picker
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ReverbPreset.allCases) { preset in
                                Button {
                                    effects.reverbPreset = preset
                                } label: {
                                    Text(preset.localizedName)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            effects.reverbPreset == preset
                                            ? AnyShapeStyle(.tint)
                                            : AnyShapeStyle(.ultraThinMaterial)
                                        )
                                        .foregroundStyle(
                                            effects.reverbPreset == preset ? .white : .primary
                                        )
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    // Wet/Dry mix
                    VStack(alignment: .leading) {
                        Text("reverb_mix")
                            .font(.caption)
                        Slider(value: $fx.reverbWetDryMix, in: 0...100, step: 1)
                        Text("\(Int(effects.reverbWetDryMix))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("reverb")
            } footer: {
                Text("reverb_desc")
            }

            // MARK: - Compressor / Limiter Section

            Section {
                Toggle("compressor_enabled", isOn: $fx.compressorEnabled)

                if effects.compressorEnabled {
                    // Preset picker
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CompressorPreset.allPresets) { preset in
                                Button {
                                    effects.applyCompressorPreset(preset)
                                } label: {
                                    Text(preset.localizedName)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            effects.compressorPresetId == preset.id
                                            ? AnyShapeStyle(.tint)
                                            : AnyShapeStyle(.ultraThinMaterial)
                                        )
                                        .foregroundStyle(
                                            effects.compressorPresetId == preset.id ? .white : .primary
                                        )
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    // Threshold
                    VStack(alignment: .leading) {
                        HStack {
                            Text("compressor_threshold")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(effects.compressorThreshold)) dB")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fx.compressorThreshold, in: -40...0, step: 1)
                    }

                    // Head Room
                    VStack(alignment: .leading) {
                        HStack {
                            Text("compressor_headroom")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.1f dB", effects.compressorHeadRoom))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fx.compressorHeadRoom, in: 0.1...40, step: 0.5)
                    }

                    // Attack Time
                    VStack(alignment: .leading) {
                        HStack {
                            Text("compressor_attack")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.1f ms", effects.compressorAttackTime * 1000))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fx.compressorAttackTime, in: 0.0001...0.2, step: 0.001)
                    }

                    // Release Time
                    VStack(alignment: .leading) {
                        HStack {
                            Text("compressor_release")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.0f ms", effects.compressorReleaseTime * 1000))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fx.compressorReleaseTime, in: 0.01...3, step: 0.01)
                    }

                    // Master Gain
                    VStack(alignment: .leading) {
                        HStack {
                            Text("compressor_gain")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.0f dB", effects.compressorMasterGain))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fx.compressorMasterGain, in: -40...40, step: 1)
                    }
                }
            } header: {
                Text("compressor_limiter")
            } footer: {
                Text("compressor_desc")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #else
        .navigationTitle("audio_effects")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
