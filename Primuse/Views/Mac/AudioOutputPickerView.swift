#if os(macOS)
import SwiftUI
import AudioToolbox
import AppKit
import PrimuseKit

/// 弹在 AirPlay 按钮上方的输出设备 popover。每个设备一行,点击切换
/// Primuse 自己的输出 (不影响系统默认)。"跟随系统"那一行让用户回到
/// 默认行为,Primuse 跟系统 default output 走。
struct AudioOutputPickerView: View {
    @Environment(AudioEngine.self) private var engine
    @State private var manager = AudioOutputDeviceManager()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                        .accessibilityHidden(true)
                    Text("audio_output")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                }
                Spacer()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(String(localized: "open_system_settings"), systemImage: "gear")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 24, height: 24)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
                .help(Text("open_system_settings"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            // 设备少 (一般 ≤10 台), 直接全部平铺, popover 高度跟内容走, 不需要
            // ScrollView。之前用 ScrollView + maxHeight 240 + 强制隐滚动条, 还
            // 是会被系统"总是显示"模式偷偷加一条粗滚动条。
            VStack(alignment: .leading, spacing: 0) {
                deviceRow(
                    title: String(localized: "audio_output_follow_system"),
                    symbol: "checkmark.circle",
                    subtitle: systemDefaultSubtitle,
                    isSelected: engine.followsSystemOutput,
                    accent: nil
                ) {
                    followSystem()
                }

                if !manager.devices.isEmpty {
                    Rectangle()
                        .fill(PMColor.divider)
                        .frame(height: 0.5)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                }

                ForEach(manager.devices) { device in
                    deviceRow(
                        title: device.name,
                        symbol: device.symbolName,
                        subtitle: device.subtitle,
                        isSelected: engine.selectedOutputDeviceID == device.id,
                        accent: device.isAirPlay ? PMColor.brand : nil
                    ) {
                        applyDevice(device.id)
                    }
                }
            }
            .padding(.vertical, 6)

            if let errorMessage {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(PMColor.bad)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }

            // 设置里开了独占输出：说清楚这台设备现在是独占还是共享。
            if let exclusive = engine.exclusiveOutputStatus.pickerDescription {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: engine.exclusiveOutputStatus.fallbackDescription == nil
                          ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(verbatim: exclusive)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(engine.exclusiveOutputStatus.fallbackDescription == nil
                                 ? PMColor.textMuted : PMColor.warn)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 280)
        // popover 一打开就会把键盘焦点放在第一个按钮上, 给它描一圈 accent 焦点环。
        // 行是整幅宽的, 环的左右两边落在 popover 边界外被裁掉, 只剩贴着行上下沿的
        // 两条横线, 看着像凭空多了两条分隔线。菜单是鼠标点开的, 关掉焦点描边。
        .focusEffectDisabled()
        // 系统 popover 已经包了 chrome (material + 圆角 + 边框 + 阴影 + 箭头), 不要
        // 再自己画 RoundedRectangle / strokeBorder / shadow, 否则跟系统 chrome 叠成
        // 双层框 (用户截图里那一圈外框就是这么来的)。同 CastDevicePickerSheet。
        .onAppear {
            manager.refresh()
        }
    }

    private var systemDefaultSubtitle: String {
        if let id = manager.systemDefaultID,
           let device = manager.devices.first(where: { $0.id == id }) {
            return "\(device.name) · \(device.subtitle)"
        }
        return String(localized: "audio_output_system_default")
    }

    private func deviceRow(title: String, symbol: String, subtitle: String?, isSelected: Bool,
                           accent: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(accent ?? PMColor.textMuted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(PMColor.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                        .accessibilityHidden(true)
                        // 只淡入淡出, 不缩放 —— 缩放会把行高一起撑动。
                        // 选择是在这里裸赋值的, 所以曲线附在过渡上, 跟行底色同一档。
                        .pmFadeTransition(motion: .hover)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .pmRowBackground(selected: isSelected, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func applyDevice(_ id: AudioDeviceID) {
        do {
            try engine.setOutputDevice(deviceID: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func followSystem() {
        errorMessage = nil
        do {
            try engine.followSystemOutput()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 均衡器的第二层,播放器「更多」与菜单栏面板共用:「关闭」、预设(与均衡器页的卡片同序)、
/// 「调整均衡器…」。高保真直通的图里没有均衡器,这时先说明原因、给一个切到音效输出的按钮;
/// 切过去播放图当场重建,这一层随即换成预设列表,接着就能选。
struct MacEqualizerMenuPanel: View {
    let player: AudioPlayerService
    let onPicked: () -> Void
    let onAdjust: () -> Void

    private var eq: EqualizerService { player.equalizerService }

    var body: some View {
        Group {
            if player.outputMode(for: player.currentSong) == .highFidelity {
                bypassNotice
            } else {
                presetList
            }
        }
        .padding(.vertical, 6)
        .focusEffectDisabled()
    }

    private var bypassNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("eq_high_fidelity_alert_title")
                .font(.callout.weight(.semibold))
                .foregroundStyle(PMColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("eq_high_fidelity_alert_message")
                .font(.caption)
                .foregroundStyle(PMColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("eq_use_effects_output") {
                player.playbackSettings.outputMode = .effects
            }
            .buttonStyle(.macSheetPrimary)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(width: 250, alignment: .leading)
    }

    @ViewBuilder
    private var presetList: some View {
        let presets = eq.menuPresets
        // 自己存的预设多了,中间这段改成滚动,别把浮层撑出屏幕。
        let visibleRows = 14
        VStack(alignment: .leading, spacing: 0) {
            pickerRow(String(localized: "eq_menu_off"), id: EqualizerService.menuOffID)
            divider
            if presets.count > visibleRows {
                ScrollView {
                    presetRows(presets)
                }
                .frame(height: CGFloat(visibleRows) * 28)
            } else {
                presetRows(presets)
            }
            divider
            Button(action: onAdjust) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").frame(width: 18)
                        .foregroundStyle(PMColor.textMuted)
                    Text("eq_menu_adjust")
                        .font(.callout)
                        .foregroundStyle(PMColor.text)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .pmRowBackground(cornerRadius: 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 210)
    }

    private func presetRows(_ presets: [EQPreset]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presets) { preset in
                pickerRow(preset.localizedName, id: preset.id)
            }
        }
    }

    private func pickerRow(_ title: String, id: String) -> some View {
        let isSelected = eq.menuSelectionID == id
        return Button {
            eq.selectFromMenu(id)
            onPicked()
        } label: {
            HStack {
                Text(verbatim: title)
                    .font(.callout)
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var divider: some View {
        Rectangle()
            .fill(PMColor.divider)
            .frame(height: 0.5)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }
}

/// 「更多」里播放速度的第二层:和 iPhone 播放页那颗速度键同一组档位。有声内容按书记速度,
/// 音乐用全局那一档;高保真直通下音乐不能变速,这里先说明原因。
struct MacPlaybackRatePanel: View {
    let player: AudioPlayerService
    let onPicked: () -> Void

    static let presets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// 有声内容总走效果链,语速随时可调;音乐只有效果模式能变速。
    static func canChangeRate(_ player: AudioPlayerService) -> Bool {
        player.currentItemIsSpokenWord || player.playbackSettings.outputMode == .effects
    }

    static func currentRate(_ player: AudioPlayerService) -> Float {
        guard canChangeRate(player) else { return 1 }
        return player.currentItemIsSpokenWord
            ? player.currentSpokenWordRate
            : player.playbackSettings.playbackRate
    }

    static func valueLabel(_ rate: Float) -> String {
        abs(rate - 1) < 0.001
            ? String(localized: "playback_rate_normal")
            : SpokenWordPlaybackRatePolicy.label(for: rate)
    }

    var body: some View {
        Group {
            if Self.canChangeRate(player) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.presets, id: \.self) { rate in
                        rateRow(rate)
                    }
                }
                .frame(width: 180)
            } else {
                MacPlaybackUnavailableNotice(
                    title: String(localized: "playback_rate"),
                    message: String(localized: "player_controls_unavailable_speed_high_fidelity"),
                    offersEffectsOutput: true,
                    playbackSettings: player.playbackSettings
                )
            }
        }
        .padding(.vertical, 6)
        .focusEffectDisabled()
    }

    private func rateRow(_ rate: Float) -> some View {
        let isSelected = abs(Self.currentRate(player) - rate) < 0.001
        return Button {
            if player.currentItemIsSpokenWord {
                player.setSpokenWordRateForCurrentBook(rate)
            } else {
                player.playbackSettings.playbackRate = rate
            }
            onPicked()
        } label: {
            HStack {
                Text(verbatim: Self.valueLabel(rate))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(PMColor.text)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 「更多」里伴唱的第二层(#377):开关、原唱留多少,以及此刻为什么还是原唱。选一档原唱音量也就打开了伴唱。
struct MacSingAlongPanel: View {
    let player: AudioPlayerService

    private var singAlong: KaraokeSingAlong { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { singAlong.isEnabled },
                set: { singAlong.setEnabled($0) }
            )) {
                Text("sing_along_title")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PMColor.text)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                Text("sing_along_level_title")
                    .font(.caption)
                    .foregroundStyle(PMColor.textMuted)
                // 和弹框里的分段选择同一种(不用系统的蓝色分段控件)。
                MacSheetSegmentedControl(
                    selection: Binding(
                        get: { singAlong.level },
                        set: { level in
                            singAlong.setLevel(level)
                            singAlong.setEnabled(true)
                        }
                    ),
                    segments: KaraokeSingAlongLevel.allCases.map {
                        .init(value: $0, title: KaraokeSingAlongText.levelTitle($0))
                    },
                    fillsWidth: true
                )
                .accessibilityLabel(Text("sing_along_level_title"))
            }
            ForEach(KaraokeSingAlongText.notes(singAlong), id: \.self) { note in
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(PMColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if KaraokeSingAlongText.offersEffectsOutput(singAlong.phase) || KaraokeSingAlongText.canRetry(singAlong.phase) {
                HStack(spacing: 8) {
                    if KaraokeSingAlongText.offersEffectsOutput(singAlong.phase) {
                        Button("karaoke_use_effects_output") {
                            player.playbackSettings.outputMode = .effects
                        }
                    }
                    if KaraokeSingAlongText.canRetry(singAlong.phase) {
                        Button("karaoke_ai_retry") { singAlong.retry() }
                    }
                }
                .buttonStyle(.macSheet)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        // 开关跟品牌色。
        .tint(PMColor.brand)
        .focusEffectDisabled()
    }
}

/// 「更多」里升降调的第二层(#332):降调、当前调、升调,点了不收起,能连着调;移了调时下面给「原调」。
/// 投放、高保真直通时先说明为什么听不到,高保真直通能一键切到音效输出。
struct MacPlaybackPitchPanel: View {
    let player: AudioPlayerService

    static func availability(_ player: AudioPlayerService) -> PlaybackPitchPolicy.Availability {
        PlaybackPitchPolicy.availability(
            isSpokenWord: player.currentItemIsSpokenWord,
            isLiveRadio: player.isLiveRadio,
            isAppleMusic: player.isAppleMusicMode,
            isCasting: player.castingRenderer != nil,
            isHighFidelityOutput: player.outputMode(for: player.currentSong) == .highFidelity
        )
    }

    private var semitones: Int { player.playbackSettings.pitchSemitones }

    var body: some View {
        let availability = Self.availability(player)
        Group {
            if let message = PlaybackPitchText.message(availability) {
                MacPlaybackUnavailableNotice(
                    title: String(localized: "karaoke_key"),
                    message: message,
                    offersEffectsOutput: availability == .highFidelity,
                    playbackSettings: player.playbackSettings
                )
            } else {
                stepper
            }
        }
        .padding(.vertical, 6)
        .focusEffectDisabled()
    }

    private var stepper: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                stepButton(symbol: "minus", label: "karaoke_key_down",
                           enabled: semitones > PlaybackPitchPolicy.range.lowerBound) {
                    player.playbackSettings.pitchSemitones = semitones - 1
                }
                Text(verbatim: PlaybackPitchText.valueLabel(semitones))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(semitones == 0 ? PMColor.text : PMColor.brand)
                    .frame(minWidth: 56)
                    .contentTransition(.numericText())
                    .accessibilityLabel(Text("karaoke_key"))
                    .accessibilityValue(Text(verbatim: PlaybackPitchText.valueLabel(semitones)))
                stepButton(symbol: "plus", label: "karaoke_key_up",
                           enabled: semitones < PlaybackPitchPolicy.range.upperBound) {
                    player.playbackSettings.pitchSemitones = semitones + 1
                }
            }
            Button("karaoke_key_original") {
                player.playbackSettings.pitchSemitones = 0
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(semitones == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 200)
    }

    private func stepButton(
        symbol: String,
        label: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? PMColor.text : PMColor.textFaint)
                .frame(width: 30, height: 30)
                .background(PMColor.bgElev, in: Circle())
                .overlay(Circle().strokeBorder(PMColor.dividerStrong, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }
}

/// 速度、升降调在当前输出下用不了时第二层的说明,和均衡器那一层同一画法。
private struct MacPlaybackUnavailableNotice: View {
    let title: String
    let message: String
    let offersEffectsOutput: Bool
    let playbackSettings: PlaybackSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(PMColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(PMColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if offersEffectsOutput {
                Button("eq_use_effects_output") {
                    playbackSettings.outputMode = .effects
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(width: 250, alignment: .leading)
    }
}
#endif
