import Foundation

/// Intent <-> 主 app 服务的解耦层。
///
/// 为什么需要这层:
/// - App Intents (Siri / Shortcuts / Lock Screen / Control Center) 在调用方
///   (Widget Extension / Shortcuts.app) 进程里需要拿到 intent 类型,所以 intent
///   声明要放在两个 target 都能 link 的位置。
/// - 实际播放器 (`AudioPlayerService`) / 库 (`MusicLibrary`) 都在主 app target,
///   widget extension 拿不到。
/// - 解法: intent 文件放在 PrimuseKit (主 app + widget 都依赖), `perform()` 里
///   只调本桥的闭包; 主 app 启动时把真正的实现注入进来。
/// - 用户在 widget / Control Center 触发 intent 时,凡是 conform 了
///   `AudioPlaybackIntent` 的,系统会把 `perform()` 路由到主 app 进程跑
///   (必要时唤醒 app),那时闭包已经被注入,行为正确。
@MainActor
public final class PrimuseIntentBridge {
    public static let shared = PrimuseIntentBridge()

    public var togglePlayPause: @MainActor () -> Void = {}
    /// Control Widget 的 toggle 走这个: 系统把"用户想要的下一帧状态"直接
    /// 给我们 (true = 想播放, false = 想暂停), 我们对齐到实际播放器即可。
    public var setPlaying: @MainActor (Bool) -> Void = { _ in }
    public var next: @MainActor () async -> Void = {}
    public var previous: @MainActor () async -> Void = {}
    /// Resumes the retained song or live station. Returns false when no
    /// resumable playback session exists.
    public var resumePlayback: @MainActor () async -> Bool = { false }
    /// 返回找到并已经开播的歌曲描述(用于 Siri 的回话),没找到时返回 nil。
    public var playSong: @MainActor (_ title: String, _ artist: String?) async -> String? = { _, _ in nil }
    public var playAlbum: @MainActor (_ title: String, _ artist: String?) async -> String? = { _, _ in nil }
    public var playArtist: @MainActor (_ name: String) async -> String? = { _ in nil }
    public var playGenre: @MainActor (_ name: String) async -> String? = { _ in nil }
    /// 返回播单名(用于回话),没找到 / 空播单返回 nil。
    public var playPlaylist: @MainActor (_ name: String) async -> String? = { _ in nil }
    public var playRadio: @MainActor (_ name: String) async -> String? = { _ in nil }
    public var playSongRadio: @MainActor () async -> String? = { nil }
    public var shuffleLibrary: @MainActor () async -> Void = {}
    public var setRepeatMode: @MainActor (RepeatMode) -> Void = { _ in }
    /// Applies a clamped playback speed and returns the effective value.
    public var setPlaybackSpeed: @MainActor (Double) -> Double = { _ in 1 }
    /// Scrapes the current song after the App Intent has obtained explicit
    /// confirmation. Returns a user-facing result, or nil when no song exists.
    public var scrapeCurrentSong: @MainActor () async -> String? = { nil }
    /// 把当前曲目切换到目标喜欢状态。`desired` 是用户想要的结果 (跟
    /// `setPlaying` 同一套语义) —— 锁屏 `Toggle` 会乐观地先把心填上再跑
    /// intent, 所以这里必须对齐到目标状态而不是无条件取反, 否则连点两次
    /// 会跟 UI 反相。当前没有曲目时什么都不做。
    public var setLiked: @MainActor (Bool) async -> Void = { _ in }

    private init() {}
}
