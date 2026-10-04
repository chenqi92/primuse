import SwiftUI

/// 音效:混响与压缩/限制。
///
/// 预设铺成一格格的图块,一眼看全,点一下就开启并选中 —— 不必先开开关再在一条
/// 横滑的小胶囊里找。参数滑杆只在开启后出现,名称和当前数值同一行。
struct AudioEffectsView: View {
    @Environment(AudioEffectsService.self) private var effects

    /// 混响七种:手机上一行四格(4 + 3),宽屏按宽度多排几格。
    private static let reverbColumns = [GridItem(.adaptive(minimum: 76), spacing: 8)]
    /// 压缩三档正好一行三格,不随宽度留空格。
    private static let compressorColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        @Bindable var fx = effects

        Form {
            // MARK: - Reverb Section

            Section {
                Toggle("reverb_enabled", isOn: $fx.reverbEnabled.pmAnimated())
                .settingsAnchor("effects.reverb")
                    .accessibilityHint(Text("reverb_desc"))

                LazyVGrid(columns: Self.reverbColumns, spacing: 8) {
                    ForEach(ReverbPreset.allCases) { preset in
                        presetTile(
                            preset.localizedName,
                            symbol: preset.symbolName,
                            isSelected: effects.reverbEnabled && effects.reverbPreset == preset
                        ) {
                            effects.reverbPreset = preset
                            if !effects.reverbEnabled {
                                pmWithAnimation(.list) { effects.reverbEnabled = true }
                            }
                        }
                        .accessibilityIdentifier("effects.reverbPreset." + String(preset.rawValue))
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

                if effects.reverbEnabled {
                    parameterRow("reverb_mix", value: "\(Int(effects.reverbWetDryMix))%") {
                        Slider(value: $fx.reverbWetDryMix, in: 0...100, step: 1)
                    }
                    .settingsAnchor("effects.reverbMix")
                    .pmFadeTransition()
                }
            } header: {
                SettingsInfoHeader("reverb") {
                    Text("reverb_desc")
                }
            }
            .settingsAnchor("effects.reverbPreset")

            // MARK: - Compressor / Limiter Section

            Section {
                Toggle("compressor_enabled", isOn: $fx.compressorEnabled.pmAnimated())
                .settingsAnchor("effects.compressor")
                    .accessibilityHint(Text("compressor_desc"))

                LazyVGrid(columns: Self.compressorColumns, spacing: 8) {
                    ForEach(CompressorPreset.allPresets) { preset in
                        presetTile(
                            preset.localizedName,
                            symbol: preset.symbolName,
                            isSelected: effects.compressorEnabled && effects.compressorPresetId == preset.id
                        ) {
                            effects.applyCompressorPreset(preset)
                            if !effects.compressorEnabled {
                                pmWithAnimation(.list) { effects.compressorEnabled = true }
                            }
                        }
                        .accessibilityIdentifier("effects.compressorPreset." + preset.id)
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

                if effects.compressorEnabled {
                    parameterRow("compressor_threshold", value: "\(Int(effects.compressorThreshold)) dB") {
                        Slider(value: $fx.compressorThreshold, in: -40...0, step: 1)
                    }
                    .settingsAnchor("effects.compressorThreshold")
                    .pmFadeTransition()

                    parameterRow("compressor_headroom", value: String(format: "%.1f dB", effects.compressorHeadRoom)) {
                        Slider(value: $fx.compressorHeadRoom, in: 0.1...40, step: 0.5)
                    }
                    .settingsAnchor("effects.compressorHeadroom")
                    .pmFadeTransition()

                    parameterRow("compressor_attack", value: String(format: "%.1f ms", effects.compressorAttackTime * 1000)) {
                        Slider(value: $fx.compressorAttackTime, in: 0.0001...0.2, step: 0.001)
                    }
                    .settingsAnchor("effects.compressorAttack")
                    .pmFadeTransition()

                    parameterRow("compressor_release", value: String(format: "%.0f ms", effects.compressorReleaseTime * 1000)) {
                        Slider(value: $fx.compressorReleaseTime, in: 0.01...3, step: 0.01)
                    }
                    .settingsAnchor("effects.compressorRelease")
                    .pmFadeTransition()

                    parameterRow("compressor_gain", value: String(format: "%.0f dB", effects.compressorMasterGain)) {
                        Slider(value: $fx.compressorMasterGain, in: -40...40, step: 1)
                    }
                    .settingsAnchor("effects.compressorGain")
                    .pmFadeTransition()
                }
            } header: {
                SettingsInfoHeader("compressor_limiter") {
                    Text("compressor_desc")
                }
            }
            .settingsAnchor("effects.compressorPreset")
        }
        #if os(macOS)
        .formStyle(.grouped)
        #else
        .navigationTitle("audio_effects")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// 一格预设:图标在上、名字在下。选中时整格着色;效果关着时一格都不亮。
    private func presetTile(
        _ title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(height: 24)
                Text(title)
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

    /// 参数行:名称与当前数值在上,滑杆在下。
    private func parameterRow<Control: View>(
        _ title: LocalizedStringKey,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            control()
        }
    }
}

private extension ReverbPreset {
    /// 房间三档用声波的大小,音乐厅用廊柱,板式是一叠金属板,教堂是钟。
    var symbolName: String {
        switch self {
        case .smallRoom: "speaker.wave.1"
        case .mediumRoom: "speaker.wave.2"
        case .largeRoom: "speaker.wave.3"
        case .mediumHall: "building.columns"
        case .largeHall: "building.columns.fill"
        case .plate: "square.stack.3d.up"
        case .cathedral: "bell"
        }
    }
}

private extension CompressorPreset {
    /// 压得越重,表针越往右。
    var symbolName: String {
        switch id {
        case "light": "gauge.with.dots.needle.33percent"
        case "heavy": "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.50percent"
        }
    }
}
