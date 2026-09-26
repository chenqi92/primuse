import Foundation

public enum PrimuseRadioIntentOutcome: Sendable, Equatable {
    case playing(name: String)
    case notFound
    case sourceDisabled
    case unavailable
}

/// 按名字点歌的结果。区分这几种情况是有意的:原先它们全都回同一句
/// "No matching song in your library.",用户空着歌名跑一次快捷指令、或者在
/// 资料库还没装载完时被 Siri 唤起,都会被告知"库里没有这首歌",无从下手。
public enum PrimuseSongIntentOutcome: Sendable, Equatable {
    /// 已开播,描述用于 Siri 回话。
    case playing(description: String)
    /// 没给歌名(参数留空或只有空白)。
    case missingTitle
    /// 资料库还在装载 —— 不能断言库里没有。
    case libraryNotReady
    /// 资料库是空的。
    case libraryEmpty
    /// 库里确实没有匹配的歌。
    case notFound
    /// 没有注入实现:app 还没完成接线,或 intent 落在了拿不到播放器的进程里。
    case unavailable
}

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
    /// Spoken word's replacements for previous / next: back and forward by
    /// the listener's skip intervals.
    public var skipBackward: @MainActor () -> Void = {}
    public var skipForward: @MainActor () -> Void = {}
    /// Continues a book (`SpokenWordBook.id`) from where it was left off.
    /// False when the book is no longer in the library.
    public var resumeSpokenWordBook: @MainActor (_ bookID: String) async -> Bool = { _ in false }
    /// Resumes the retained song or live station. Returns false when no
    /// resumable playback session exists.
    public var resumePlayback: @MainActor () async -> Bool = { false }
    /// 按歌名(可选艺术家)点歌。结果区分"没给歌名""库还没装载""确实没有",
    /// 未注入时是 `.unavailable` —— 不能把这些都说成"库里没有这首歌"。
    public var playSong: @MainActor (_ title: String, _ artist: String?) async -> PrimuseSongIntentOutcome = { _, _ in .unavailable }
    public var playAlbum: @MainActor (_ title: String, _ artist: String?) async -> String? = { _, _ in nil }
    public var playArtist: @MainActor (_ name: String) async -> String? = { _ in nil }
    public var playGenre: @MainActor (_ name: String) async -> String? = { _ in nil }
    /// 返回播单名(用于回话),没找到 / 空播单返回 nil。
    public var playPlaylist: @MainActor (_ name: String) async -> String? = { _ in nil }
    public var playRadio: @MainActor (_ name: String) async -> String? = { _ in nil }
    /// App Entity 已解析出稳定电台 ID 后走这里；结果区分来源停用与流不可用，
    /// 避免 App Shortcut 在冷启动或来源状态变化后仍返回虚假的成功。
    public var playRadioStation: @MainActor (_ id: String) async -> PrimuseRadioIntentOutcome = {
        _ in .notFound
    }
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
