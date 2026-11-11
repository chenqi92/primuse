#if os(iOS)
import PrimuseKit
import SwiftUI

/// 转轮的「接下来」一面:接下来怎么放。顶上一条播放方式(随机、循环、A-B、睡眠定时,开着的亮起),
/// 下面是播放队列本身,照样能长按拖动排序、点垃圾桶删除。
struct NowPlayingCarouselUpNextFace: View {
    let context: NowPlayingCarouselFaceContext
    let appearance: NowPlayingAppearance
    let onShowSleepTimer: () -> Void
    let onShowABRepeatEditor: () -> Void

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let showsModes = context.cards.contains(.playbackModes)
        let showsQueue = context.cards.contains(.queue)
        VStack(spacing: 12) {
            if showsModes {
                NowPlayingCarouselPlaybackModesCard(
                    appearance: appearance,
                    onShowSleepTimer: onShowSleepTimer,
                    onShowABRepeatEditor: onShowABRepeatEditor
                )
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .nowPlayingCarouselCardEntrance(index: 0, isCommitted: context.isCommitted)
            }
            if showsQueue {
                QueueView(player: player, isEmbedded: true)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .nowPlayingCarouselCardEntrance(index: showsModes ? 1 : 0, isCommitted: context.isCommitted)
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

/// 四颗状态键。点一下就切,长按看全部选项(循环方式、A-B 区间);睡眠定时点开定时面板,开着时写还剩多久。
private struct NowPlayingCarouselPlaybackModesCard: View {
    let appearance: NowPlayingAppearance
    let onShowSleepTimer: () -> Void
    let onShowABRepeatEditor: () -> Void

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        NowPlayingCarouselCardContainer(card: .playbackModes, appearance: appearance) {
            HStack(alignment: .top, spacing: 6) {
                shuffleKey
                repeatKey
                abRepeatKey
                sleepKey
            }
        }
    }

    // MARK: 随机

    private var shuffleKey: some View {
        let isOn = player.shuffleEnabled
        let isEnabled = isOn || player.queueCount >= 2
        return Button {
            PMHaptics.playbackModeToggled()
            player.shuffleEnabled.toggle()
        } label: {
            NowPlayingCarouselModeKeyFace(
                symbol: "shuffle",
                caption: Text("play_mode_shuffle"),
                isActive: isOn,
                appearance: appearance
            )
        }
        .buttonStyle(.pmPressable)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(Text("play_mode_shuffle"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: 循环

    private var repeatKey: some View {
        let behavior = player.repeatBehavior
        return Menu {
            Picker(selection: Binding(
                get: { player.repeatBehavior },
                set: { player.repeatBehavior = $0 }
            )) {
                ForEach(RepeatBehavior.choices(
                    includingEachTrackStops: player.supportsEachTrackStop || behavior.eachTrackStop != nil
                )) { option in
                    Label {
                        Text(option.titleKey)
                    } icon: {
                        Image(systemName: option.symbolName)
                    }
                    .tag(option)
                }
            } label: {
                Text("repeat")
            }
            .pickerStyle(.inline)
        } label: {
            NowPlayingCarouselModeKeyFace(
                symbol: behavior.symbolName,
                caption: Text(behavior.isActive ? behavior.titleKey : LocalizedStringKey("repeat")),
                isActive: behavior.isActive,
                appearance: appearance
            )
        } primaryAction: {
            PMHaptics.playbackModeToggled()
            player.repeatBehavior = behavior.next
        }
        .buttonStyle(.pmPressable)
        .accessibilityLabel(Text("repeat"))
        .accessibilityValue(Text(behavior.titleKey))
    }

    // MARK: A-B

    private var abRepeatKey: some View {
        let state = player.abRepeat
        let canUse = player.canUseABRepeat
        let isEnabled = canUse || state.isActive
        return Menu {
            if canUse {
                Button(action: onShowABRepeatEditor) {
                    Label(
                        state.loop == nil
                            ? LocalizedStringKey("ab_repeat_choose_range")
                            : LocalizedStringKey("ab_repeat_edit_range"),
                        systemImage: "selection.pin.in.out"
                    )
                }
            }
            if state.isActive {
                Button(role: .destructive) {
                    PMHaptics.playbackModeToggled()
                    player.clearABRepeat()
                } label: {
                    Label("ab_repeat_off", systemImage: "xmark.circle")
                }
            }
        } label: {
            NowPlayingCarouselModeKeyFace(
                symbol: Self.abSymbol(state),
                caption: Text(Self.abCaption(state)),
                isActive: state.isActive,
                appearance: appearance
            )
        } primaryAction: {
            PMHaptics.playbackModeToggled()
            player.advanceABRepeat()
        }
        .buttonStyle(.pmPressable)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(Text("ab_repeat"))
    }

    private static func abSymbol(_ state: ABRepeatState) -> String {
        switch state {
        case .off: "selection.pin.in.out"
        case .pointA: "a.circle"
        case .looping: "selection.pin.in.out"
        }
    }

    /// 关着时写「A-B 循环」;设了 A 写「设为 B 点」提示下一下;循环中写区间。
    private static func abCaption(_ state: ABRepeatState) -> LocalizedStringKey {
        switch state {
        case .off: "ab_repeat"
        case .pointA: "ab_repeat_set_b"
        case .looping(let loop): "player_carousel_ab_range \(loop.start.formattedDuration) \(loop.end.formattedDuration)"
        }
    }

    // MARK: 睡眠定时

    private var sleepKey: some View {
        let isActive = player.isSleepTimerActive
        return Button(action: onShowSleepTimer) {
            NowPlayingCarouselModeKeyFace(
                symbol: isActive ? "moon.zzz.fill" : "moon.zzz",
                caption: sleepCaption,
                isActive: isActive,
                appearance: appearance
            )
        }
        .buttonStyle(.pmPressable)
        .accessibilityLabel(Text(isActive ? LocalizedStringKey("sleep_timer_active") : LocalizedStringKey("sleep_timer")))
        .accessibilityValue(Text(verbatim: SleepTimerStatusText.summary(player) ?? ""))
    }

    /// 定时开着:倒计时的写还剩多久(自己走),播完再停的写停在哪儿;关着写「睡眠定时器」。
    private var sleepCaption: Text {
        if let end = player.sleepTimerEndDate, end > .now {
            return Text(timerInterval: Date.now...end, countsDown: true, showsHours: true)
                .monospacedDigit()
        }
        if player.isSleepTimerActive {
            return Text(verbatim: SleepTimerStatusText.summary(player) ?? String(localized: "sleep_timer_active"))
        }
        return Text("sleep_timer")
    }
}

/// 一颗状态键的样子:圆钮在上,说明在下;开着时圆钮填上这一面的颜色。
private struct NowPlayingCarouselModeKeyFace: View {
    let symbol: String
    let caption: Text
    let isActive: Bool
    let appearance: NowPlayingAppearance

    var body: some View {
        let tint = NowPlayingCarouselPanel.upNext.tint
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : appearance.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 50, height: 50)
                .background(Circle().fill(isActive ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(appearance.primary.opacity(0.1))))
                .shadow(color: isActive ? tint.opacity(0.35) : .clear, radius: 8, y: 3)
            caption
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? appearance.primary : appearance.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .pmAnimation(.control, value: isActive)
    }
}
#endif
