#if os(macOS)
import SwiftUI
import PrimuseKit

/// 音量控件这一刻在控制什么，以及应该显示成什么样。
///
/// 图标、百分比和滑块必须走同一个来源 —— 过去它们各自读 `engine.volume`，
/// 高保真下那个值恒为 1，于是三者一起显示满格，而滑块又是禁用的，
/// 用户看到的就是一根「永远满格、拖不动」的死条。
@MainActor
private struct PMVolumeControlState {
    let target: PlaybackVolumeControlTarget
    let displayValue: Double

    init(player: AudioPlayerService, engine: AudioEngine) {
        let controller = OutputDeviceVolumeController.shared
        target = PlaybackVolumeControlPolicy.target(
            isLiveRadio: player.isLiveRadio,
            isHighFidelityDirect: player.playbackSettings.outputMode == .highFidelity,
            outputDeviceVolumeIsControllable: controller.isControllable
        )
        displayValue = PlaybackVolumeControlPolicy.displayValue(
            target: target,
            userVolume: Double(engine.userVolume),
            deviceVolume: controller.volume.map(Double.init)
        )
    }

    var helpKey: LocalizedStringKey {
        switch target {
        case .applicationGain: return "volume"
        case .outputDevice: return "volume_output_device_hint"
        case .unavailable: return "volume_high_fidelity_system_hint"
        }
    }

    var accessibilityHelp: String? {
        switch target {
        case .applicationGain: return nil
        case .outputDevice: return String(localized: "volume_output_device_hint")
        case .unavailable: return String(localized: "volume_high_fidelity_system_hint")
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
    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
    @State private var isEditing = false

    var body: some View {
        let state = PMVolumeControlState(player: player, engine: engine)

        PMVolumeSlider(
            value: Binding(
                get: { state.displayValue },
                set: { write($0, target: state.target) }
            ),
            isEnabled: state.target.isAdjustable,
            accessibilityHelp: state.accessibilityHelp,
            onEditingChanged: { editing in
                isEditing = editing
                // 只有应用增益需要落盘；设备音量归系统保存。
                if !editing { engine.persistVolume() }
            }
        )
        .help(Text(state.helpKey))
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
        .task {
            // 硬件音量可能被系统音量键或别的应用改动，得盯着；
            // 输出设备也要跟上引擎当前钉住的那一台。
            let controller = OutputDeviceVolumeController.shared
            controller.start()
            controller.preferredDeviceID = engine.currentOutputDeviceID
        }
    }

    private func write(_ value: Double, target: PlaybackVolumeControlTarget) {
        switch target {
        case .applicationGain:
            // 拖动过程中不落盘，指针抬起时再提交最终值。
            player.setPlaybackVolume(Float(value), persist: !isEditing)
        case .outputDevice:
            OutputDeviceVolumeController.shared.setVolume(Float(value))
        case .unavailable:
            break
        }
    }
}
#endif
