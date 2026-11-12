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

    var body: some View {
        switch availability {
        case .available:
            Picker(selection: $semitones) {
                ForEach(PlaybackPitchPolicy.choices, id: \.self) { value in
                    Text(verbatim: PlaybackPitchText.valueLabel(value)).tag(value)
                }
            } label: {
                Label(PlaybackPitchText.menuTitle(semitones), systemImage: PlaybackPitchText.symbol)
            }
            .pickerStyle(.menu)
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
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(appearance.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
                .environment(\.colorScheme, appearance.colorScheme)
        }
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
#endif
