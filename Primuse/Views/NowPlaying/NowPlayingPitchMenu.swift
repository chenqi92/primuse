import SwiftUI
import PrimuseKit

/// 播放速度旁的「升降调」(#332)。iPhone 播放页的速度键和「更多」菜单里各放一个,紧跟在速度后面。
/// 单独成一个视图:播放页那条修饰链已经长到编译器推断不过来,菜单里的分支别再往那个文件里塞。
///
/// 用不了的时候(投放、高保真直通)不置灰:系统菜单里置灰的项点不动,所以第二行写原因,
/// 点了弹说明,高保真直通那条能一键切到音效输出。有声内容与电台保持原声,不给这一项。
struct NowPlayingPitchMenuItem: View {
    @Binding var semitones: Int
    let availability: PlaybackPitchPolicy.Availability
    let onShowUnavailableNotice: () -> Void

    @Environment(PlaybackSettingsStore.self) private var playbackSettings: PlaybackSettingsStore?

    var body: some View {
        switch availability {
        case .available:
            Picker(selection: Binding(
                get: { semitones },
                set: { newValue in
                    if playbackSettings?.speedPitchMode == .varispeed {
                        playbackSettings?.setSpeedPitchMode(.independent)
                    }
                    semitones = newValue
                }
            )) {
                ForEach(PlaybackPitchPolicy.choices, id: \.self) { value in
                    Text(verbatim: PlaybackPitchText.valueLabel(value)).tag(value)
                }
            } label: {
                Label(PlaybackPitchText.menuTitle(semitones), systemImage: PlaybackPitchText.symbol)
            }
            .pickerStyle(.menu)

            if let playbackSettings {
                NowPlayingVarispeedMenuItem(playbackSettings: playbackSettings)
            }
        case .appleMusic, .casting, .highFidelity:
            Button(action: onShowUnavailableNotice) {
                Label {
                    Text("karaoke_key")
                    if let reason = PlaybackPitchText.shortReason(availability) {
                        Text(verbatim: reason)
                    }
                } icon: {
                    Image(systemName: PlaybackPitchText.symbol)
                }
            }
        case .notOffered:
            EmptyView()
        }
    }
}

/// 播放页菜单里的 Varispeed 子菜单(#494): 模式切换、速度预设(减速 75% / 夜核 125% 等)、
/// 半音音高对齐(-12...+12 附精确百分比)与百分比微调。
struct NowPlayingVarispeedMenuItem: View {
    let playbackSettings: PlaybackSettingsStore

    var body: some View {
        let mode = playbackSettings.speedPitchMode
        let rate = playbackSettings.varispeedRate
        let currentPercent = VarispeedPolicy.percentChange(forRate: rate)

        Menu {
            Picker(
                selection: Binding(
                    get: { playbackSettings.speedPitchMode },
                    set: { playbackSettings.setSpeedPitchMode($0) }
                )
            ) {
                ForEach(PlaybackSpeedPitchMode.allCases) { option in
                    Text(verbatim: VarispeedText.modeTitle(option)).tag(option)
                }
            } label: {
                Text("speed_pitch_mode")
            }
            .pickerStyle(.inline)

            Section(String(localized: "varispeed_align_speed")) {
                ForEach(VarispeedPolicy.speedPresets) { preset in
                    let isSelected = mode == .varispeed
                        && VarispeedPolicy.matchingSpeedPreset(forRate: rate)?.id == preset.id
                    Button {
                        playbackSettings.setVarispeed(speedPercent: Double(preset.speedPercent))
                    } label: {
                        if isSelected {
                            Label(VarispeedText.speedPresetMenuTitle(preset), systemImage: "checkmark")
                        } else {
                            Text(verbatim: VarispeedText.speedPresetMenuTitle(preset))
                        }
                    }
                }
            }

            Menu {
                ForEach(VarispeedPolicy.pitchPresets) { preset in
                    let isSelected = mode == .varispeed
                        && VarispeedPolicy.nearestSemitone(forRate: rate) == preset.semitones
                    Button {
                        playbackSettings.setVarispeed(semitones: preset.semitones)
                    } label: {
                        if isSelected {
                            Label(VarispeedText.semitoneWithPercentLabel(preset), systemImage: "checkmark")
                        } else {
                            Text(verbatim: VarispeedText.semitoneWithPercentLabel(preset))
                        }
                    }
                }
            } label: {
                Label(
                    mode == .varispeed
                        ? "\(String(localized: "varispeed_align_pitch")) · \(VarispeedText.semitoneDisplay(forRate: rate))"
                        : String(localized: "varispeed_align_pitch"),
                    systemImage: PlaybackPitchText.symbol
                )
            }

            Menu {
                ForEach([5, 1, -1, -5], id: \.self) { step in
                    Button {
                        playbackSettings.setVarispeed(percentChange: currentPercent + Double(step))
                    } label: {
                        Text(verbatim: String(format: "%+d%%", step))
                    }
                }
            } label: {
                Label(
                    "\(String(localized: "varispeed_percent")) \(VarispeedPolicy.signedPercentLabel(forRate: rate))",
                    systemImage: "percent"
                )
            }

            if mode == .varispeed && VarispeedPolicy.isActiveRate(rate) {
                Section {
                    Button(role: .destructive) {
                        playbackSettings.resetVarispeed()
                    } label: {
                        Label("varispeed_reset", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        } label: {
            Label(VarispeedText.menuTitle(mode: mode, rate: rate), systemImage: VarispeedText.symbol)
        }
    }
}

/// 升降调的界面文字,iPhone 与 Mac 的播放器菜单、设置共用。
enum PlaybackPitchText {
    static let symbol = "tuningfork"

    /// 「原调」或带正负号的半音数。
    static func valueLabel(_ semitones: Int) -> String {
        PlaybackPitchPolicy.signedLabel(semitones) ?? String(localized: "karaoke_key_original")
    }

    /// 菜单项的标题:原调时只写「升降调」,移了调就带上数,和旁边速度那一项同一写法。
    static func menuTitle(_ semitones: Int) -> String {
        let title = String(localized: "karaoke_key")
        guard let value = PlaybackPitchPolicy.signedLabel(semitones) else { return title }
        return "\(title) \(value)"
    }

    /// 菜单里第二行的短原因。Apple Music 时速度与升降调整项都不出现,用不到。
    static func shortReason(_ availability: PlaybackPitchPolicy.Availability) -> String? {
        switch availability {
        case .highFidelity: String(localized: "eq_menu_high_fidelity_unavailable")
        case .casting: String(localized: "playback_pitch_casting_unavailable")
        case .appleMusic, .available, .notOffered: nil
        }
    }

    /// 点了用不了的那一项弹出的说明。
    static func message(_ availability: PlaybackPitchPolicy.Availability) -> String? {
        switch availability {
        case .highFidelity: String(localized: "playback_pitch_unavailable_high_fidelity")
        case .casting: String(localized: "playback_pitch_unavailable_casting")
        case .appleMusic: String(localized: "playback_pitch_unavailable_apple_music")
        case .available, .notOffered: nil
        }
    }
}

#if os(iOS)
/// 播放页的「歌词时间」:一把 0.1 秒一格的刻度尺,拖着走歌词就跟着挪,每过一格轻轻一震;
/// 两头的键一次挪一格。按这一首记住(`SpokenWordTranscriptOffsetStore` 的音乐那一层),
/// 以后再放这首、锁屏和桌面歌词也都按挪过的走。
struct LyricsTimingRulerPanel: View {
    let itemKey: String
    let appearance: NowPlayingAppearance
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 刻度尺正对中线的那一格;拖动途中跟着变。
    @State private var tick: Int?

    private static let tickSpacing: CGFloat = 9
    private static let rulerHeight: CGFloat = 54

    init(itemKey: String, appearance: NowPlayingAppearance, onClose: @escaping () -> Void) {
        self.itemKey = itemKey
        self.appearance = appearance
        self.onClose = onClose
        // 打开时就停在现在挪的那一格:放在 init 里,刻度尺第一次排版就对准,不会先停在 0 再跳过去。
        let stored = SpokenWordTranscriptOffsetStore.shared.itemDelay(forKey: itemKey) ?? 0
        _tick = State(initialValue: LyricsTimingPolicy.tickIndex(for: stored))
    }

    private var delay: TimeInterval {
        LyricsTimingPolicy.delay(forTick: tick ?? 0)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            ruler
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .modifier(NowPlayingFloatingPanelChrome(appearance: appearance))
        .sensoryFeedback(.selection, trigger: tick)
        .onChange(of: tick) { _, newTick in
            SpokenWordTranscriptOffsetStore.shared.setItemDelay(
                LyricsTimingPolicy.delay(forTick: newTick ?? 0),
                forKey: itemKey
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("lyrics_timing_title")
                    .font(.headline)
                    .foregroundStyle(appearance.primary)
                Text("lyrics_timing_hint")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(verbatim: SpokenWordTranscriptOffsetRow.valueText(delay))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(delay == 0 ? appearance.secondary : appearance.primary)
                .contentTransition(.numericText(value: delay))
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: delay)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(appearance.primary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(appearance.primary.opacity(0.12)))
                    .contentShape(Circle().inset(by: -6))
            }
            .buttonStyle(.pmPressable)
            .accessibilityLabel(Text("close"))
        }
    }

    /// 刻度在中线下面走,中线不动;两边淡出。
    private var ruler: some View {
        GeometryReader { geometry in
            let margin = max((geometry.size.width - Self.tickSpacing) / 2, 0)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(LyricsTimingPolicy.tickRange, id: \.self) { index in
                        tickMark(index)
                            .frame(width: Self.tickSpacing, height: Self.rulerHeight, alignment: .top)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $tick, anchor: .center)
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(appearance.primary)
                    .frame(width: 3, height: 30)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: Self.rulerHeight)
        .accessibilityElement()
        .accessibilityLabel(Text("lyrics_timing_title"))
        .accessibilityValue(Text(verbatim: SpokenWordTranscriptOffsetRow.valueText(delay)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(by: 1)
            case .decrement: step(by: -1)
            @unknown default: break
            }
        }
    }

    private func tickMark(_ index: Int) -> some View {
        let weight = LyricsTimingPolicy.weight(ofTick: index)
        let height: CGFloat = switch weight {
        case .major: 22
        case .medium: 15
        case .minor: 9
        }
        return Capsule()
            .fill(appearance.primary.opacity(weight == .minor ? 0.32 : 0.62))
            .frame(width: weight == .major ? 2 : 1.5, height: height)
            .padding(.top, 4)
            .overlay(alignment: .top) {
                if weight == .major {
                    Text(verbatim: Self.secondsLabel(index))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(appearance.secondary)
                        .fixedSize()
                        .padding(.top, 32)
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            stepButton(-1, symbol: "minus", label: "lyrics_timing_earlier_step")
            Text("lyrics_timing_earlier")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(appearance.secondary)
            Spacer(minLength: 8)
            if (tick ?? 0) != 0 {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { tick = 0 }
                } label: {
                    Text("lyrics_timing_reset")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(appearance.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(appearance.primary.opacity(0.12)))
                }
                .buttonStyle(.pmPressable)
                .transition(.opacity)
            }
            Spacer(minLength: 8)
            Text("lyrics_timing_later")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(appearance.secondary)
            stepButton(1, symbol: "plus", label: "lyrics_timing_later_step")
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: (tick ?? 0) != 0)
    }

    private func stepButton(_ amount: Int, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            step(by: amount)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(appearance.primary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(appearance.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.pmPressable)
        .accessibilityLabel(Text(label))
        .buttonRepeatBehavior(.enabled)
    }

    private func step(by amount: Int) {
        let next = min(max((tick ?? 0) + amount, LyricsTimingPolicy.tickRange.lowerBound), LyricsTimingPolicy.tickRange.upperBound)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { tick = next }
    }

    /// 整秒刻度下面写的数:0、+1、−1。
    private static func secondsLabel(_ index: Int) -> String {
        let seconds = index / 10
        return seconds == 0 ? "0" : seconds > 0 ? "+\(seconds)" : "\u{2212}\(-seconds)"
    }
}

/// 播放页底部浮着的「歌词时间」「文字稿时间」:有声书、播客挪文字稿,音乐挪这一首的歌词。
/// 「更多」里两项都打开这一块,按放的是什么换内容。
struct NowPlayingTimingPanel: View {
    let song: Song
    let appearance: NowPlayingAppearance
    let onClose: () -> Void

    var body: some View {
        let store = SpokenWordTranscriptOffsetStore.shared
        if store.itemKey(for: song) != nil {
            SpokenWordTranscriptTimingPanel(song: song, appearance: appearance, onClose: onClose)
        } else if let key = store.lyricsItemKey(for: song) {
            LyricsTimingRulerPanel(itemKey: key, appearance: appearance, onClose: onClose)
        }
    }
}

/// 播放页的「文字稿时间」(#423):和全屏文稿菜单、文稿设置里同一行「− 秒数 +」——一下 0.1 秒、
/// 按住连着走,点中间的秒数直接输入(插播的动态广告能差好几分钟);下面一行是所有文字稿那一层。
/// 浮在底部,文字稿留在上面看得见,挪的时候能对着声音看。
struct SpokenWordTranscriptTimingPanel: View {
    let song: Song
    let appearance: NowPlayingAppearance
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .padding(.trailing, 8)
            // 「+」键自己带着点按区的留白,行尾比标题少留一点,和上面的关闭键对齐。
            VStack(spacing: 0) {
                SpokenWordTranscriptOffsetRow(scope: .item(song))
                Divider()
                    .overlay(appearance.primary.opacity(0.10))
                SpokenWordTranscriptOffsetRow(scope: .all)
            }
            .font(.body)
        }
        .foregroundStyle(appearance.primary)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .modifier(NowPlayingFloatingPanelChrome(appearance: appearance))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("transcript_offset_title")
                    .font(.headline)
                Text("transcript_offset_panel_hint")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(appearance.primary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(appearance.primary.opacity(0.12)))
                    .contentShape(Circle().inset(by: -6))
            }
            .buttonStyle(.pmPressable)
            .accessibilityLabel(Text("close"))
        }
    }
}

/// 播放页底部浮着的小面板的底:毛玻璃圆角卡片,深浅跟播放页。
private struct NowPlayingFloatingPanelChrome: ViewModifier {
    let appearance: NowPlayingAppearance

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(appearance.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
                .environment(\.colorScheme, appearance.colorScheme)
        }
    }
}
#endif
