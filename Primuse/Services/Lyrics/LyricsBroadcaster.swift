import Foundation
import PrimuseKit

/// 歌词跟踪 service — 把 LyricsScrollView 内的 timer 逻辑搬到服务层,
/// 让锁屏 / 后台 / 切到 home 时歌词跟踪也持续, Live Activity 始终能
/// push 当前行 + 下一行。
///
/// LyricsScrollView 仍可订阅 `currentLineIndex` 做高亮 + 滚动 (替代之前
/// 自己跑 timer)。
@MainActor
@Observable
final class LyricsBroadcaster {
    static let shared = LyricsBroadcaster()

    private(set) var currentSongID: String?
    private(set) var lyrics: [LyricLine] = []
    private(set) var currentLineIndex: Int = 0

    /// DispatchSourceTimer 而非 NSTimer/Timer.scheduledTimer:
    /// 1. NSTimer 依赖 RunLoop, scrollView 切到 .tracking 模式 timer 不 fire
    /// 2. RunLoop 在 background 不一定继续跑 (audio playback 时 process
    ///    保持 active 但 RunLoop 行为依赖系统调度)
    /// 3. DispatchSourceTimer 跑在 GCD 队列, 不依赖 RunLoop, 只要进程
    ///    active (audio backgrounding 保证) 就 fire
    private var timer: DispatchSourceTimer?
    private weak var player: AudioPlayerService?

    /// 行级歌词 LRC 文件 timestamp 通常是"演唱开始那一刻", 但 LRC 制作时按
    /// spacebar 记录会有人为反应延迟 (常见 200-400ms), 加 250ms lookahead
    /// 提前切换。字级歌词 syllable 粒度精度高, 不补偿。
    private static let lineLevelLookahead: TimeInterval = 0.25

    private init() {}

    /// 由 PrimuseApp / AppServices 启动时绑一次 player。
    /// player 是 weak ref, broadcaster 不延长 player 生命周期。
    func attachPlayer(_ player: AudioPlayerService) {
        self.player = player
    }

    /// 加载新歌词 — NowPlayingView.loadLyrics 完成后调。
    /// 切歌时即使 lyrics 是空数组也要调 (清空 + 停 timer)。
    func setLyrics(_ lyrics: [LyricLine], for songID: String?) {
        // 同首歌同样 lyrics 内容, 保留 currentLineIndex 但确保 timer 在跑
        // (避免 stale-while-revalidate refresh 时把已 track 的 index 抖回 0)。
        if currentSongID == songID && self.lyrics.count == lyrics.count && !lyrics.isEmpty {
            self.lyrics = lyrics
            // 双保险: 万一 timer 之前因为任何原因停了 (背景 task 调度异常等),
            // 这里重新拉起。
            if timer == nil { startTracking() }
            return
        }
        self.currentSongID = songID
        self.lyrics = lyrics
        self.currentLineIndex = 0
        if !lyrics.isEmpty {
            startTracking()
            // 加载完立刻 push 一次: 当前行可能不是 0 (中途 resume + cache hit)
            // 让 Live Activity 第一时间显示
            tickOnce()
        } else {
            stopTracking()
            // 歌词清空也要通知 Activity 把歌词区清掉 (退化为只显示 song info)
            Task {
                await LiveActivityManager.shared.updateLyrics(currentLine: nil, nextLine: nil)
            }
        }
    }

    /// 用户主动 stop / endActivity 时清。
    func reset() {
        currentSongID = nil
        lyrics = []
        currentLineIndex = 0
        stopTracking()
    }

    private func startTracking() {
        stopTracking()
        // GCD timer on main queue — main queue 的 dispatch source 不依赖
        // RunLoop mode, app 锁屏 / background (audio playing 时进程保持 active)
        // 时仍能正常 fire。tick handler 已在 main queue, 直接同步访问 main
        // actor 状态。
        let t = DispatchSource.makeTimerSource(queue: .main)
        // 100ms tick — 歌词行切换粒度本来就是几百毫秒级, 100ms 视觉无差别。
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in
            // GCD main queue handler 已在 main thread, 但 Swift 6 strict
            // concurrency 要求 @MainActor 隔离, 走 MainActor.assumeIsolated。
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        t.resume()
        timer = t
    }

    private func stopTracking() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let player, !lyrics.isEmpty else { return }
        let time = player.interpolatedTime()
        for (i, line) in lyrics.enumerated().reversed() {
            let lookahead: TimeInterval = line.isWordLevel ? 0 : Self.lineLevelLookahead
            if time + lookahead >= line.timestamp {
                if currentLineIndex != i {
                    currentLineIndex = i
                    pushLineToActivity()
                }
                return
            }
        }
    }

    /// 公开版本, 让 setLyrics 加载完立刻同步当前行 (不需要等下一个 timer tick)。
    private func tickOnce() {
        tick()
        // 如果 currentLineIndex 仍是 0 且行是 valid, 也 push 一次 (覆盖
        // 上一首歌可能残留的歌词)
        pushLineToActivity()
    }

    private func pushLineToActivity() {
        guard currentLineIndex < lyrics.count else { return }
        let current = lyrics[currentLineIndex].text
        let next = currentLineIndex + 1 < lyrics.count ? lyrics[currentLineIndex + 1].text : nil
        Task {
            await LiveActivityManager.shared.updateLyrics(currentLine: current, nextLine: next)
        }
    }
}
