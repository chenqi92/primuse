import PrimuseKit
import SwiftUI

/// 环境音的播放页版式。一段声音要的是「一直放、到点停」,所以没有歌词区,也没有上一首 / 下一首的
/// 主位:中间是封面外面一圈随颜色呼吸的光环,下面是声音名、一颗大的播放 / 暂停、定时胶囊(显示还剩多久,
/// 点开选时长)、循环开关和音量。播放页外壳(背景、下拉收起、全屏)仍由 `NowPlayingView` 管。
struct AmbientNowPlayingLayout<Volume: View>: View {
    let size: CGSize
    let topInset: CGFloat
    let primary: Color
    let secondary: Color
    let tertiary: Color
    /// 封面取出来的控件色,光环按它和环境音自己的颜色呼吸。
    let accent: Color
    let showsVolume: Bool
    @ViewBuilder let volume: () -> Volume
    let onShowSleepTimer: () -> Void
    let onEnterFullscreen: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isLandscape = size.width > size.height * 1.15
        let side = isLandscape
            ? min(size.height * 0.52, size.width * 0.34, 320)
            : min(size.width * 0.62, size.height * 0.36, 340)
        VStack(spacing: 0) {
            Capsule()
                .fill(tertiary)
                .frame(width: 48, height: 5)
                .padding(.top, topInset + 6)

            if let error = player.lastPlaybackError {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.82), in: Capsule())
                    .padding(.top, 14)
            }

            Spacer(minLength: 12)
            if isLandscape {
                HStack(spacing: 44) {
                    centerpiece(side: side)
                    controls
                        .frame(maxWidth: 420)
                }
                .padding(.horizontal, 32)
            } else {
                centerpiece(side: side)
                Spacer(minLength: 28)
                controls
                    .padding(.horizontal, 28)
            }
            Spacer(minLength: 20)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: 中间

    private func centerpiece(side: CGFloat) -> some View {
        let song = player.currentSong
        return ZStack {
            ImmersiveBreathingHalo(
                palette: ImmersiveArtworkPalette(primary: accent, secondary: ListeningSpace.ambient.tint),
                isAnimating: player.isPlaying && !reduceMotion,
                diameter: side
            )
            CachedArtworkView(
                coverRef: song?.coverArtFileName,
                songID: song?.id,
                size: side * 0.74,
                cornerRadius: side * 0.37,
                sourceID: song?.sourceID,
                filePath: song?.filePath,
                fileFormat: song?.fileFormat,
                placeholderIcon: ListeningSpace.ambient.systemImage
            )
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        }
        .frame(width: side * 1.18, height: side * 1.18)
        .accessibilityHidden(true)
    }

    // MARK: 下面

    private var controls: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(verbatim: player.currentSong?.title ?? "")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(verbatim: subtitle)
                    .font(.body)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(primary)
                    .frame(width: 80, height: 80)
                    .background(primary.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? Text("a11y_pause") : Text("a11y_play"))
            .accessibilityIdentifier("ambient.player.playPause")

            HStack(spacing: 12) {
                timerCapsule
                loopToggle
                Button(action: onEnterFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(primary)
                        .frame(width: 40, height: 36)
                        .background(primary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("ambient_fullscreen"))
            }

            if showsVolume {
                volume()
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 8)
            }

            AmbientBackToMusicButton(tint: primary)
                .frame(maxWidth: 360)
        }
    }

    private var subtitle: String {
        if let album = player.currentSong?.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !album.isEmpty { return album }
        return String(localized: "listening_space_ambient")
    }

    /// 定时胶囊:倒数中显示还剩多久,没定时写「定时」;点开是睡眠定时面板(环境音那一套时长)。
    private var timerCapsule: some View {
        Button(action: onShowSleepTimer) {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.subheadline.weight(.semibold))
                if let end = player.sleepTimerEndDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: AmbientSleepRemainingText.text(until: end, now: context.date))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                } else {
                    Text("ambient_timer_button")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(player.sleepTimerEndDate == nil ? primary : ListeningSpace.ambient.tint)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(primary.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("sleep_timer"))
        .accessibilityIdentifier("ambient.player.timer")
    }

    /// 循环开关:单曲循环(默认)与放完就停之间切。
    private var loopToggle: some View {
        let loops = player.repeatMode == .one
        return Button {
            player.repeatBehavior = RepeatBehavior(repeatMode: loops ? .off : .one, eachTrackStop: nil)
        } label: {
            Image(systemName: "repeat.1")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(loops ? Color.white : primary)
                .frame(width: 40, height: 36)
                .background(
                    Capsule().fill(loops ? AnyShapeStyle(ListeningSpace.ambient.tint) : AnyShapeStyle(primary.opacity(0.12)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("ambient_loop"))
        .accessibilityAddTraits(loops ? .isSelected : [])
    }
}

/// 定时还剩多久:「还剩 12:34」,一小时以上写成「1:02:03」。
enum AmbientSleepRemainingText {
    static func text(until end: Date, now: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        let clock = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return String(format: String(localized: "ambient_timer_remaining_format"), clock)
    }
}

/// Mac 播放页右栏在放环境音时的样子:左边仍是封面与播放控件,右边不摆歌词,换成一圈呼吸的光环、
/// 循环开关、快捷定时和「回到音乐」。
struct AmbientNowPlayingSidePane: View {
    let primary: Color
    let secondary: Color
    let accent: Color

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let loops = player.repeatMode == .one
        VStack(spacing: 22) {
            ZStack {
                ImmersiveBreathingHalo(
                    palette: ImmersiveArtworkPalette(primary: accent, secondary: ListeningSpace.ambient.tint),
                    isAnimating: player.isPlaying && !reduceMotion,
                    diameter: 170
                )
                Image(systemName: ListeningSpace.ambient.systemImage)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(ListeningSpace.ambient.tint)
            }
            .frame(width: 210, height: 210)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("listening_space_ambient")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(primary)
                (loops ? Text("ambient_looping_hint") : Text("ambient_play_once_hint"))
                    .font(.callout)
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                player.repeatBehavior = RepeatBehavior(repeatMode: loops ? .off : .one, eachTrackStop: nil)
            } label: {
                Label("ambient_loop", systemImage: "repeat.1")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(loops ? Color.white : primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(loops ? AnyShapeStyle(ListeningSpace.ambient.tint) : AnyShapeStyle(primary.opacity(0.12)))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(loops ? .isSelected : [])

            AmbientQuickTimerRow()
                .fixedSize(horizontal: true, vertical: false)

            if let end = player.sleepTimerEndDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: AmbientSleepRemainingText.text(until: end, now: context.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(secondary)
                }
            }

            AmbientBackToMusicButton(tint: primary)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
