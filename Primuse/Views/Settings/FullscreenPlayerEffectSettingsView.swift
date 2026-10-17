#if os(iOS)
import PrimuseKit
import SwiftUI

/// 全屏效果选择页直接缩放正式舞台作为预览。只有当前选中的卡片运行动画，
/// 其余卡片停在真实静态帧，避免设置页同时启动多套高频渲染。
struct FullscreenPlayerEffectSettingsView: View {
    @Environment(ThemeService.self) private var theme
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var selectedRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @AppStorage(ImmersiveFrameRateMode.storageKey)
    private var frameRateRawValue = ImmersiveFrameRateMode.defaultValue.rawValue
    @AppStorage(ImmersiveMotionIntensity.storageKey)
    private var motionIntensityRawValue = ImmersiveMotionIntensity.defaultValue.rawValue
    /// 选了 60 帧或跟随屏幕、还没确认的那一档。
    @State private var pendingHighRefresh: ImmersiveFrameRateMode?
    @AppStorage(ImmersiveEffectRotationMode.storageKey)
    private var rotationModeRawValue = ImmersiveEffectRotationMode.defaultValue.rawValue
    @AppStorage(ImmersiveEffectRotationScope.storageKey)
    private var rotationScopeRawValue = ImmersiveEffectRotationScope.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.entersFullscreenInLandscapeKey)
    private var entersFullscreenInLandscape = PlayerAppearancePreferences.entersFullscreenInLandscapeByDefault

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
                frameRateCard
                motionIntensityCard
                deviceConstraintNote
                rotationCard
                landscapeFullscreenCard

                ForEach(FullscreenEffectCollection.allCases) { @Sendable collection in
                    LazyItemCell {
                        if !collection.effects.isEmpty {
                            VStack(alignment: .leading, spacing: 11) {
                                Text(collection.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                LazyVGrid(columns: previewColumns, alignment: .leading, spacing: 12) {
                                    ForEach(collection.effects) { @Sendable effect in
                                        LazyItemCell {
                                            effectCard(effect)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .settingsAnchor("appearance.fullscreenEffect")
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

    /// 原生全屏是播放页本身的沉浸歌词，不用这项；选着原生时直接写明，免得拨了看不出变化。
    private var lyricsMotionCard: some View {
        Toggle(isOn: $lyricsMotionEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                cardTitle("immersive_lyrics_motion_title", info: "immersive_lyrics_motion_subtitle")
                if selectedEffect.isNative {
                    Label("immersive_lyrics_motion_native_note", systemImage: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsAnchor("appearance.lyricsMotion")
        .tint(previewPalette.primary)
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    /// 手机转横屏直接进全屏(#191)。iPad 没有手机那副横屏播放页，不给这一项。
    @ViewBuilder
    private var landscapeFullscreenCard: some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            Toggle(isOn: $entersFullscreenInLandscape) {
                VStack(alignment: .leading, spacing: 4) {
                    cardTitle("player_landscape_fullscreen_title", info: "player_landscape_fullscreen_subtitle")
                }
            }
            .settingsAnchor("appearance.landscapeFullscreen")
            .tint(previewPalette.primary)
            .padding(16)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }

    /// 从省电、30 帧换到 60 帧或跟随屏幕时先说明耗电，确认了才写进设置。
    private var frameRateSelection: Binding<String> {
        Binding(
            get: { ImmersiveFrameRateMode(storedValue: frameRateRawValue).rawValue },
            set: { rawValue in
                let proposed = ImmersiveFrameRateMode(storedValue: rawValue)
                let current = ImmersiveFrameRateMode(storedValue: frameRateRawValue)
                if ImmersiveFrameRateMode.requiresConfirmation(from: current, to: proposed) {
                    pendingHighRefresh = proposed
                } else {
                    frameRateRawValue = proposed.rawValue
                }
            }
        )
    }

    private var isConfirmingHighRefresh: Binding<Bool> {
        Binding(
            get: { pendingHighRefresh != nil },
            set: { if !$0 { pendingHighRefresh = nil } }
        )
    }

    private var motionIntensitySelection: Binding<String> {
        Binding(
            get: { ImmersiveMotionIntensity(storedValue: motionIntensityRawValue).rawValue },
            set: { motionIntensityRawValue = $0 }
        )
    }

    /// 低电量模式或发热时全屏页临时降了档:写在两张卡下面,免得以为设置没生效。
    @ViewBuilder
    private var deviceConstraintNote: some View {
        let budget = ImmersiveDeviceConditions.shared.budget(
            frameRate: ImmersiveFrameRateMode(storedValue: frameRateRawValue),
            intensity: ImmersiveMotionIntensity(storedValue: motionIntensityRawValue)
        )
        if let item = budget.noticeItem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.symbol)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: item.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
            .pmAppearFade(.contentAppear)
        }
    }

    private var motionIntensityCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                cardTitle("immersive_motion_intensity_title", info: "immersive_motion_intensity_subtitle")
            }
            Spacer(minLength: 8)
            Picker(selection: motionIntensitySelection) {
                ForEach(ImmersiveMotionIntensity.allCases) { intensity in
                    Text(verbatim: intensity.localizedTitle).tag(intensity.rawValue)
                }
            } label: {
                Text("immersive_motion_intensity_title")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(previewPalette.primary)
        }
        .settingsAnchor("appearance.immersiveMotionIntensity")
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var frameRateCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                cardTitle("immersive_frame_rate_title", info: "immersive_frame_rate_subtitle")
            }
            Spacer(minLength: 8)
            Picker(selection: frameRateSelection) {
                ForEach(ImmersiveFrameRateMode.allCases) { mode in
                    Text(verbatim: mode.localizedTitle).tag(mode.rawValue)
                }
            } label: {
                Text("immersive_frame_rate_title")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(previewPalette.primary)
        }
        .settingsAnchor("appearance.immersiveFrameRate")
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .alert(
            Text("immersive_high_refresh_title"),
            isPresented: isConfirmingHighRefresh,
            presenting: pendingHighRefresh
        ) { mode in
            Button {
                frameRateRawValue = mode.rawValue
                motionIntensityRawValue = ImmersiveMotionIntensity.maximum.rawValue
            } label: {
                Text("immersive_high_refresh_maximize")
            }
            Button {
                frameRateRawValue = mode.rawValue
            } label: {
                Text("immersive_high_refresh_frame_rate_only")
            }
            Button(role: .cancel) {
            } label: {
                Text("cancel")
            }
        } message: { _ in
            Text(verbatim: ImmersiveFrameRateMode.highRefreshExplanation)
        }
    }

    private var rotationSelection: Binding<String> {
        Binding(
            get: { ImmersiveEffectRotationMode(storedValue: rotationModeRawValue).rawValue },
            set: { rotationModeRawValue = $0 }
        )
    }

    private var rotationScopeSelection: Binding<String> {
        Binding(
            get: { ImmersiveEffectRotationScope(storedValue: rotationScopeRawValue).rawValue },
            set: { rotationScopeRawValue = $0 }
        )
    }

    /// 自动换效果(#312):隔一段时间或每首歌换一种全屏效果。开着时下面再给一行「在哪些里换」。
    private var rotationCard: some View {
        let isEnabled = ImmersiveEffectRotationMode(storedValue: rotationModeRawValue).isEnabled
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    cardTitle("immersive_effect_rotation_title", info: "immersive_effect_rotation_subtitle")
                }
                Spacer(minLength: 8)
                Picker(selection: rotationSelection) {
                    ForEach(ImmersiveEffectRotationMode.allCases) { mode in
                        Text(verbatim: mode.localizedTitle).tag(mode.rawValue)
                    }
                } label: {
                    Text("immersive_effect_rotation_title")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(previewPalette.primary)
            }
            if isEnabled {
                Divider()
                HStack(spacing: 12) {
                    Text("immersive_effect_rotation_scope_title")
                        .font(.system(size: 15))
                    Spacer(minLength: 8)
                    Picker(selection: rotationScopeSelection) {
                        ForEach(ImmersiveEffectRotationScope.allCases) { scope in
                            Text(verbatim: scope.localizedTitle).tag(scope.rawValue)
                        }
                    } label: {
                        Text("immersive_effect_rotation_scope_title")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(previewPalette.primary)
                }
                .pmAppearFade(.contentAppear)
            }
        }
        .settingsAnchor("appearance.immersiveEffectRotation")
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    /// 卡片标题旁一个圈问号,说明点开才看,和设置页其它说明一样收起来。
    private func cardTitle(_ title: LocalizedStringKey, info: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            SettingsInfoButton { Text(info) }
        }
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
