import AppIntents
import SwiftUI
import WidgetKit
import PrimuseKit

// ControlWidget 是 iOS 18+ 专有 API, 原生 macOS 不存在该类型 —— 整个文件用
// `#if os(iOS)` 守卫, 让扩展能为 macOS 编译。
#if os(iOS)

// iOS 18 引入的 Control Widget —— 用户在控制中心 / 锁屏 / 设置侧"操作"页加入,
// 一键播控,不用先开 app。
//
// 几个关键点:
// - intent 必须 conform `AudioPlaybackIntent`, 系统会在主 app 进程跑 perform()
//   (必要时唤醒主 app), 然后通过 `PrimuseIntentBridge` 调真实 player。
// - `ControlWidgetToggle` 需要一个 valueProvider 给当前 isPlaying 状态。
// - 状态 valueProvider 从 App Group `PlaybackState.load()` 读, 跟桌面 widget
//   走同一份数据。
// - 显式 `availability` 声明 iOS 18+; 老系统部署不会被加载。

// MARK: - Play / Pause toggle

@available(iOS 18.0, *)
struct PrimusePlayPauseControl: ControlWidget {
    static let kind = "com.welape.yuanyin.control.playpause"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: PlayPauseValueProvider()
        ) { value in
            ControlWidgetToggle(
                "猿音",
                isOn: value.isPlaying,
                action: PrimuseSetPlayingIntent(value: !value.isPlaying)
            ) { isPlaying in
                Label(
                    isPlaying ? "暂停" : "播放",
                    systemImage: isPlaying ? "pause.fill" : "play.fill"
                )
            }
        }
        .displayName("猿音 播放 / 暂停")
        .description("一键控制猿音播放")
    }
}

@available(iOS 18.0, *)
struct PlayPauseValue {
    let isPlaying: Bool
}

@available(iOS 18.0, *)
struct PlayPauseValueProvider: AppIntentControlValueProvider {
    func previewValue(configuration: PlayPauseConfigIntent) -> PlayPauseValue {
        PlayPauseValue(isPlaying: false)
    }

    func currentValue(configuration: PlayPauseConfigIntent) async throws -> PlayPauseValue {
        // 从主 app 共享的 App Group 读最新一帧 PlaybackState。Widget 不需要写。
        let state = PlaybackState.load()
        return PlayPauseValue(isPlaying: state?.isPlaying ?? false)
    }
}

/// 空 config —— Control Widget 至少要绑一个 ConfigurationIntent, 我们这个
/// toggle 没有用户可配项, 但 API 要求, 留个空壳。
@available(iOS 18.0, *)
struct PlayPauseConfigIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Play / Pause"
}

// MARK: - Shuffle library button

@available(iOS 18.0, *)
struct PrimuseShuffleControl: ControlWidget {
    static let kind = "com.welape.yuanyin.control.shuffle"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: PrimuseShuffleAllIntent()) {
                Label("随机播放", systemImage: "shuffle")
            }
        }
        .displayName("猿音 随机播放")
        .description("随机打散整库并开始播放")
    }
}

// MARK: - Next / Previous buttons

@available(iOS 18.0, *)
struct PrimuseNextControl: ControlWidget {
    static let kind = "com.welape.yuanyin.control.next"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: PrimuseNextIntent()) {
                Label("下一首", systemImage: "forward.fill")
            }
        }
        .displayName("猿音 下一首")
        .description("跳到下一首")
    }
}

@available(iOS 18.0, *)
struct PrimusePreviousControl: ControlWidget {
    static let kind = "com.welape.yuanyin.control.previous"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: PrimusePreviousIntent()) {
                Label("上一首", systemImage: "backward.fill")
            }
        }
        .displayName("猿音 上一首")
        .description("回到上一首")
    }
}

#endif
