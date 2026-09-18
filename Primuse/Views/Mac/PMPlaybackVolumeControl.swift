#if os(macOS)
import SwiftUI
import PrimuseKit

/// 音量控件这一刻在控制什么，以及应该显示成什么样。
///
/// 图标、百分比和滑块必须走同一个来源 —— 过去它们各自读 `engine.volume`，
/// 高保真下那个值恒为 1，于是三者一起显示满格，而滑块又是禁用的，
/// 用户看到的就是一根「永远满格、拖不动」的死条。
///
/// 这里调的自始至终是应用自己的音量，跟系统音量互不影响。
@MainActor
private struct PMVolumeControlState {
    let target: PlaybackVolumeControlTarget
    let displayValue: Double
    /// 控件不可用时用来挑对应的说明：系统播放器在放 / 本地直通加不了增益。
    let isSystemManagedPlayback: Bool

    init(player: AudioPlayerService, engine: AudioEngine) {
        isSystemManagedPlayback = player.isAppleMusicMode && !player.isCastingMode
        target = PlaybackVolumeControlPolicy.target(
            isLiveRadio: player.isLiveRadio,
            isCastingToRemoteRenderer: player.isCastingMode,
            isSystemManagedPlayback: player.isAppleMusicMode,
            applicationGainIsAvailable: engine.applicationGainIsAvailable
        )
        displayValue = PlaybackVolumeControlPolicy.displayValue(
            target: target,
            userVolume: Double(engine.userVolume)
        )
    }

    var helpKey: LocalizedStringKey {
        switch target {
        case .applicationGain: return "volume"
        case .unavailable:
            return isSystemManagedPlayback
                ? "apple_music_now_playing_hint"
                : "volume_high_fidelity_system_hint"
        }
    }

    var accessibilityHelp: String? {
        switch target {
        case .applicationGain: return nil
        case .unavailable:
            return isSystemManagedPlayback
                ? String(localized: "apple_music_now_playing_hint")
                : String(localized: "volume_high_fidelity_system_hint")
        }
    }
}

/// Keep high-frequency volume observation out of the artwork and lyrics views.
struct PMVolumeSymbol: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        let volume = PMVolumeControlState(player: player, engine: engine).displayValue
        if volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.4 { return "speaker.wave.1.fill" }
        if volume < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct PMVolumePercentage: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        let value = PMVolumeControlState(player: player, engine: engine).displayValue
        Text(verbatim: "\(Int((value * 100).rounded()))")
    }
}

struct PMPlaybackVolumeSlider: View {
    /// 跟同一处进度条的填充色一致；nil 时用主题品牌色。
    var tint: Color?

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
    @State private var isEditing = false

    // 有 private 属性时合成的逐成员初始化器只在本文件可见。
    init(tint: Color? = nil) {
        self.tint = tint
    }

    var body: some View {
        let state = PMVolumeControlState(player: player, engine: engine)

        PMVolumeSlider(
            value: Binding(
                get: { state.displayValue },
                set: { write($0, target: state.target) }
            ),
            isEnabled: state.target.isAdjustable,
            fillColor: tint ?? PMColor.brand,
            accessibilityHelp: state.accessibilityHelp,
            onEditingChanged: { editing in
                isEditing = editing
                // 拖动过程中不落盘，指针抬起时提交最终值。
                if !editing { engine.persistVolume() }
            }
        )
        .help(Text(state.helpKey))
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }

    private func write(_ value: Double, target: PlaybackVolumeControlTarget) {
        switch target {
        case .applicationGain:
            // 拖动过程中不落盘，指针抬起时再提交最终值。
            player.setPlaybackVolume(Float(value), persist: !isEditing)
        case .unavailable:
            break
        }
    }
}
#endif
