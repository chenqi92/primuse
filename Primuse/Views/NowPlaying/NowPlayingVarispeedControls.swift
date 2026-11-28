import PrimuseKit
import SwiftUI

/// Localized display helpers for Varispeed (linked speed & pitch, #494) shared across
/// Now Playing menus, the Sound Face carousel card, and Playback Settings.
enum VarispeedText {
    static let symbol = "waveform.path"

    static func modeTitle(_ mode: PlaybackSpeedPitchMode) -> String {
        switch mode {
        case .independent: String(localized: "speed_pitch_mode_independent")
        case .varispeed: String(localized: "speed_pitch_mode_varispeed")
        }
    }

    static func speedPresetShortName(_ preset: VarispeedPolicy.SpeedPreset) -> String? {
        switch preset.kind {
        case .slowed: String(localized: "varispeed_preset_slowed")
        case .nightcore: String(localized: "varispeed_preset_nightcore")
        case .original, .plain: nil
        }
    }

    static func speedPresetMenuTitle(_ preset: VarispeedPolicy.SpeedPreset) -> String {
        if let name = speedPresetShortName(preset) {
            return "\(preset.speedPercent)% · \(name)"
        }
        return "\(preset.speedPercent)%"
    }

    static func semitoneLabel(_ semitones: Int) -> String {
        semitones == 0 ? String(localized: "karaoke_key_original") : String(format: "%+d", semitones)
    }

    static func semitoneWithPercentLabel(_ preset: VarispeedPolicy.PitchPreset) -> String {
        if preset.semitones == 0 {
            return "\(String(localized: "karaoke_key_original")) (0%)"
        }
        return "\(String(format: "%+d", preset.semitones)) (\(VarispeedPolicy.signedPercentLabel(forRate: preset.rate)))"
    }

    static func semitoneDisplay(forRate rate: Float) -> String {
        guard let signed = VarispeedPolicy.signedSemitoneValue(forRate: rate) else {
            return String(localized: "karaoke_key_original")
        }
        return "\(signed) \(String(localized: "varispeed_semitone_unit"))"
    }

    static func menuTitle(mode: PlaybackSpeedPitchMode, rate: Float) -> String {
        let title = String(localized: "varispeed_title")
        guard mode == .varispeed, VarispeedPolicy.isActiveRate(rate) else { return title }
        return "\(title) \(VarispeedPolicy.signedPercentLabel(forRate: rate))"
    }
}

/// Reusable Playback Settings section for Independent Speed/Pitch and linked Varispeed (#494).
struct PlaybackSpeedPitchSettingsSection: View {
    @Environment(PlaybackSettingsStore.self) private var playbackSettings

    var body: some View {
        @Bindable var settings = playbackSettings
        let isHighFidelity = settings.outputMode == .highFidelity

        Section {
            Picker("speed_pitch_mode", selection: $settings.speedPitchMode.pmAnimated()) {
                ForEach(PlaybackSpeedPitchMode.allCases) { mode in
                    Text(verbatim: VarispeedText.modeTitle(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .settingsAnchor("playback.varispeedMode")

            switch settings.speedPitchMode {
            case .independent:
                independentControls(pitchSemitones: $settings.pitchSemitones, isHighFidelity: isHighFidelity)
            case .varispeed:
                varispeedControls(isHighFidelity: isHighFidelity)
            }
        } header: {
            Text("playback_rate_section")
        } footer: {
            if settings.speedPitchMode == .independent {
                Text("playback_pitch_desc")
            }
        }
        .disabled(isHighFidelity)
    }

    @ViewBuilder
    private func independentControls(
        pitchSemitones: Binding<Int>,
        isHighFidelity: Bool
    ) -> some View {
        HStack {
            Text("playback_rate")
            Spacer()
            Text(String(format: "%.2fx", Double(isHighFidelity ? Float(1) : playbackSettings.playbackRate)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        Slider(
            value: Binding(
                get: { isHighFidelity ? 1 : playbackSettings.playbackRate },
                set: { playbackSettings.playbackRate = $0 }
            ),
            in: 0.5...2.0,
            step: 0.05
        ) {
            Text("playback_rate")
        } minimumValueLabel: {
            Text("0.5x").font(.caption2)
        } maximumValueLabel: {
            Text("2.0x").font(.caption2)
        }
        .settingsAnchor("playback.speed")
        .accessibilityHint(Text("playback_rate_desc"))

        if playbackSettings.playbackRate != 1.0 {
            Button("playback_rate_reset") {
                playbackSettings.playbackRate = 1.0
            }
            .font(.caption)
        }

        let shownPitch = isHighFidelity ? 0 : playbackSettings.pitchSemitones
        Stepper(value: pitchSemitones, in: PlaybackPitchPolicy.range) {
            HStack {
                Text("karaoke_key")
                Spacer()
                Text(verbatim: PlaybackPitchText.valueLabel(shownPitch))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .settingsAnchor("playback.pitch")
        .accessibilityValue(Text(verbatim: PlaybackPitchText.valueLabel(shownPitch)))
        .accessibilityHint(Text("playback_pitch_desc"))
    }

    @ViewBuilder
    private func varispeedControls(isHighFidelity: Bool) -> some View {
        let rate = isHighFidelity ? VarispeedPolicy.defaultRate : playbackSettings.varispeedRate
        let percentChange = VarispeedPolicy.percentChange(forRate: rate)

        // 1. Percentage adjustment
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("varispeed_percent")
                Spacer()
                Text(verbatim: VarispeedPolicy.signedPercentLabel(forRate: rate))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                Text(verbatim: VarispeedText.semitoneDisplay(forRate: rate))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { percentChange },
                    set: { playbackSettings.setVarispeed(percentChange: $0) }
                ),
                in: VarispeedPolicy.percentChangeRange,
                step: 0.5
            ) {
                Text("varispeed_percent")
            } minimumValueLabel: {
                Text(verbatim: "-50%").font(.caption2)
            } maximumValueLabel: {
                Text(verbatim: "+100%").font(.caption2)
            }
            .settingsAnchor("playback.speed")
        }

        // 2. Align to target pitch in semitones
        Picker(
            "varispeed_align_pitch",
            selection: Binding(
                get: { VarispeedPolicy.nearestSemitone(forRate: rate) ?? Int(VarispeedPolicy.semitones(forRate: rate).rounded()) },
                set: { playbackSettings.setVarispeed(semitones: $0) }
            )
        ) {
            ForEach(VarispeedPolicy.pitchPresets) { preset in
                Text(verbatim: VarispeedText.semitoneWithPercentLabel(preset)).tag(preset.semitones)
            }
        }
        .settingsAnchor("playback.pitch")

        // 3. Align to target speed presets
        VStack(alignment: .leading, spacing: 8) {
            Text("varispeed_align_speed")
                .font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(VarispeedPolicy.speedPresets) { preset in
                        let isSelected = VarispeedPolicy.matchingSpeedPreset(forRate: rate)?.id == preset.id
                        Button {
                            playbackSettings.setVarispeed(speedPercent: Double(preset.speedPercent))
                        } label: {
                            VStack(spacing: 2) {
                                Text(verbatim: "\(preset.speedPercent)%")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                if let tag = VarispeedText.speedPresetShortName(preset) {
                                    Text(verbatim: tag)
                                        .font(.caption2)
                                        .opacity(0.85)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                            )
                            .overlay(
                                Capsule().strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        if VarispeedPolicy.isActiveRate(rate) {
            Button("varispeed_reset") {
                playbackSettings.resetVarispeed()
            }
            .font(.caption)
        }
    }
}

#if os(iOS)
/// 调音转轮里的「速度与音调」卡片: 支持独立控制与 Varispeed 联动切换 (#494)。
/// 独立模式下保留速度、升降调两颗步进; Varispeed 模式下提供百分比滑杆、目标音高半音对齐、
/// 速度预设(减速 75%、原速 100%、夜核 125% 等)与一键还原。
struct NowPlayingCarouselSpeedPitchCard: View {
    let appearance: NowPlayingAppearance

    @Environment(AudioPlayerService.self) private var player
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(\.nowPlayingCarouselTapGuard) private var tapGuard
    @Environment(\.nowPlayingCarouselControlEditing) private var reportsControlEditing

    var body: some View {
        let canChangeRate = playbackSettings.outputMode == .effects
        let pitchAvailability = PlaybackPitchPolicy.availability(
            isSpokenWord: player.currentItemIsSpokenWord,
            isLiveRadio: player.isLiveRadio,
            isAppleMusic: player.isAppleMusicMode,
            isCasting: player.castingRenderer != nil,
            isHighFidelityOutput: player.outputMode(for: player.currentSong) == .highFidelity
        )
        let offersVarispeed = pitchAvailability != .notOffered
        let isVarispeedMode = offersVarispeed && playbackSettings.speedPitchMode == .varispeed
        let isChanged: Bool = {
            if isVarispeedMode {
                return VarispeedPolicy.isActiveRate(playbackSettings.varispeedRate)
            }
            return abs(Double(playbackSettings.playbackRate) - 1) > 0.001 || playbackSettings.pitchSemitones != 0
        }()

        NowPlayingCarouselCardContainer(card: .speedAndPitch, appearance: appearance) {
            Button {
                tapGuard.perform {
                    pmWithAnimation(.control) {
                        playbackSettings.resetActiveSpeedAndPitch()
                    }
                }
            } label: {
                Label("player_carousel_reset_short", systemImage: "arrow.counterclockwise")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(appearance.primary.opacity(0.1)))
            }
            .buttonStyle(.pmPressable)
            .disabled(!isChanged)
            .opacity(isChanged ? 1 : 0.4)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if offersVarispeed {
                    modeSwitcher
                }

                if isVarispeedMode {
                    varispeedCardBody(canAdjust: pitchAvailability == .available)
                } else {
                    independentCardBody(canChangeRate: canChangeRate, pitchAvailability: pitchAvailability)
                }

                if !canChangeRate {
                    NowPlayingCarouselCardNotice(
                        message: String(localized: "eq_menu_high_fidelity_unavailable"),
                        actionTitle: "eq_use_effects_output",
                        appearance: appearance
                    ) {
                        playbackSettings.outputMode = .effects
                    }
                } else if pitchAvailability == .casting, let reason = PlaybackPitchText.shortReason(pitchAvailability) {
                    NowPlayingCarouselCardNotice(message: reason, appearance: appearance)
                }
            }
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(PlaybackSpeedPitchMode.allCases) { mode in
                let isSelected = playbackSettings.speedPitchMode == mode
                Button {
                    tapGuard.perform {
                        pmWithAnimation(.control) {
                            playbackSettings.setSpeedPitchMode(mode)
                        }
                    }
                } label: {
                    Text(verbatim: VarispeedText.modeTitle(mode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? appearance.primary : appearance.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isSelected ? NowPlayingCarouselPanel.sound.tint.opacity(0.24) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(appearance.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func independentCardBody(
        canChangeRate: Bool,
        pitchAvailability: PlaybackPitchPolicy.Availability
    ) -> some View {
        let rate = Double(playbackSettings.playbackRate)
        let pitch = playbackSettings.pitchSemitones
        let pitchChoices = PlaybackPitchPolicy.choices.map(Double.init)

        stepperRow(
            symbol: "speedometer",
            title: "playback_rate",
            value: Self.rateLabel(rate),
            canDecrease: canChangeRate && NowPlayingCarouselStepper.canStep(rate, by: -1, in: NowPlayingCarouselStepper.playbackRates),
            canIncrease: canChangeRate && NowPlayingCarouselStepper.canStep(rate, by: 1, in: NowPlayingCarouselStepper.playbackRates)
        ) { delta in
            let next = NowPlayingCarouselStepper.step(rate, by: delta, in: NowPlayingCarouselStepper.playbackRates)
            playbackSettings.playbackRate = Float(next)
        }

        if pitchAvailability != .notOffered {
            stepperRow(
                symbol: PlaybackPitchText.symbol,
                title: "karaoke_key",
                value: PlaybackPitchText.valueLabel(pitch),
                canDecrease: pitchAvailability == .available && NowPlayingCarouselStepper.canStep(Double(pitch), by: -1, in: pitchChoices),
                canIncrease: pitchAvailability == .available && NowPlayingCarouselStepper.canStep(Double(pitch), by: 1, in: pitchChoices)
            ) { delta in
                let next = NowPlayingCarouselStepper.step(Double(pitch), by: delta, in: pitchChoices)
                playbackSettings.pitchSemitones = Int(next.rounded())
            }
        }
    }

    @ViewBuilder
    private func varispeedCardBody(canAdjust: Bool) -> some View {
        let rate = canAdjust ? playbackSettings.varispeedRate : VarispeedPolicy.defaultRate
        let percentChange = VarispeedPolicy.percentChange(forRate: rate)
        let exactSemitones = VarispeedPolicy.semitones(forRate: rate)
        let roundedSemitone = Int(exactSemitones.rounded())

        // 1. Percentage slider & fine ±1% stepper
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: VarispeedText.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appearance.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(verbatim: VarispeedPolicy.signedPercentLabel(forRate: rate))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.primary)
                    .contentTransition(.numericText())
                Text(verbatim: VarispeedText.semitoneDisplay(forRate: rate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    stepButton(symbol: "minus", isEnabled: canAdjust && percentChange > VarispeedPolicy.percentChangeRange.lowerBound + 0.01) {
                        playbackSettings.setVarispeed(percentChange: (percentChange - 1.0).rounded())
                    }
                    stepButton(symbol: "plus", isEnabled: canAdjust && percentChange < VarispeedPolicy.percentChangeRange.upperBound - 0.01) {
                        playbackSettings.setVarispeed(percentChange: (percentChange + 1.0).rounded())
                    }
                }
                .background(Capsule().fill(appearance.primary.opacity(0.08)))
            }

            Slider(
                value: Binding(
                    get: { percentChange },
                    set: { playbackSettings.setVarispeed(percentChange: $0) }
                ),
                in: VarispeedPolicy.percentChangeRange,
                step: 0.5,
                onEditingChanged: reportsControlEditing
            )
            .tint(NowPlayingCarouselPanel.sound.tint)
            .disabled(!canAdjust)
            .nowPlayingCarouselHorizontalRegion()
        }

        // 2. Align to pitch (semitone stepper + exact percentage readout)
        stepperRow(
            symbol: PlaybackPitchText.symbol,
            title: "varispeed_align_pitch",
            value: VarispeedPolicy.nearestSemitone(forRate: rate).map(VarispeedText.semitoneLabel)
                ?? (VarispeedPolicy.signedSemitoneValue(forRate: rate) ?? String(localized: "karaoke_key_original")),
            canDecrease: canAdjust && roundedSemitone > VarispeedPolicy.semitoneRange.lowerBound,
            canIncrease: canAdjust && roundedSemitone < VarispeedPolicy.semitoneRange.upperBound
        ) { delta in
            let base: Int
            if let exact = VarispeedPolicy.nearestSemitone(forRate: rate) {
                base = exact + delta
            } else {
                base = delta > 0 ? Int(ceil(exactSemitones)) : Int(floor(exactSemitones))
            }
            playbackSettings.setVarispeed(semitones: base)
        }

        // 3. Align to speed presets (75% Slowed, 85%, 90%, 100%, 110%, 125% Nightcore, 150%)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(VarispeedPolicy.speedPresets) { preset in
                    let isSelected = canAdjust && VarispeedPolicy.matchingSpeedPreset(forRate: rate)?.id == preset.id
                    Button {
                        tapGuard.perform {
                            pmWithAnimation(.control) {
                                playbackSettings.setVarispeed(speedPercent: Double(preset.speedPercent))
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: "\(preset.speedPercent)%")
                                .font(.caption.weight(.semibold).monospacedDigit())
                            if let tag = VarispeedText.speedPresetShortName(preset) {
                                Text(verbatim: tag)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(isSelected ? appearance.primary : appearance.secondary)
                            }
                        }
                        .foregroundStyle(isSelected ? appearance.primary : appearance.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                isSelected
                                    ? NowPlayingCarouselPanel.sound.tint.opacity(0.26)
                                    : appearance.primary.opacity(0.08)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAdjust)
                }
            }
        }
        .nowPlayingCarouselHorizontalRegion()
    }

    private func stepperRow(
        symbol: String,
        title: LocalizedStringKey,
        value: String,
        canDecrease: Bool,
        canIncrease: Bool,
        step: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(appearance.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                stepButton(symbol: "minus", isEnabled: canDecrease) { step(-1) }
                Text(verbatim: value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.primary)
                    .frame(minWidth: 58)
                    .contentTransition(.numericText())
                stepButton(symbol: "plus", isEnabled: canIncrease) { step(1) }
            }
            .background(Capsule().fill(appearance.primary.opacity(0.08)))
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrease { step(1) }
            case .decrement: if canDecrease { step(-1) }
            @unknown default: break
            }
        }
    }

    private func stepButton(symbol: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            tapGuard.perform { pmWithAnimation(.control, action) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(appearance.primary.opacity(isEnabled ? 1 : 0.3))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private static func rateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
#endif
