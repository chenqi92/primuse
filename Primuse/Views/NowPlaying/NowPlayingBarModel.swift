#if os(iOS)
import PrimuseKit
import SwiftUI

/// 外壳里正在播放那一条的功能契约。
///
/// 三种画法(标签栏附件迷你条、通栏停靠条 `DockedPlayerBar`、悬浮胶囊 `FloatingCapsulePlayerBar`,
/// 见 `SkinShell.NowPlayingBar`)只收它:标题、副标题、封面、是否在播、是否加载中、进度,
/// 以及点按、播放 / 暂停、上一首 / 下一首、快进、打开队列这些动作,都从这里取。播放逻辑只有一份,
/// 实现只负责画法。点按、左右滑切歌与无障碍动作仍由共用的 `MiniPlayerSwipeContent` 承担。
///
/// 数据都是按需读取的计算属性:谁读谁订阅。进度只在进度线 / 进度环那一小块视图里读,
/// 每半秒一次的刷新不会牵连歌名、封面和整条播放条,更不会让外壳重算。
@MainActor
struct NowPlayingBarModel {
    /// 封面视图要的那几样。
    struct Artwork {
        let coverRef: String?
        let songID: String
        let sourceID: String?
        let filePath: String?
        let fileFormat: AudioFormat?
        let revisionToken: Int
    }

    private let player: AudioPlayerService
    private let library: MusicLibrary
    /// 点按整条:打开播放页。
    let onTap: () -> Void
    /// 打开播放队列。
    let onOpenQueue: () -> Void

    init(
        player: AudioPlayerService,
        library: MusicLibrary,
        onTap: @escaping () -> Void,
        onOpenQueue: @escaping () -> Void = {}
    ) {
        self.player = player
        self.library = library
        self.onTap = onTap
        self.onOpenQueue = onOpenQueue
    }

    // MARK: - 数据

    /// 正在播的歌的 id,用来给换歌做过渡。
    var songID: String? { player.currentSong?.id }

    /// 第一行:歌名;有声书是书名。
    var title: String {
        isSpokenWordBook ? SpokenWordPlayerText.bookTitle(player) : (player.currentSong?.title ?? "")
    }

    /// 正在播的那一首。有声书的书封按它取图。
    var currentSong: Song? { player.currentSong }

    /// 第二行:出错时是原因,否则是艺术家。
    var subtitle: NowPlayingBarSubtitle? {
        NowPlayingBarPresentationPolicy.subtitle(
            playbackError: player.lastPlaybackError,
            artistName: player.currentSong.flatMap { library.artistDisplayName(for: $0) }
        )
    }

    var artwork: Artwork {
        let song = player.currentSong
        return Artwork(
            coverRef: song?.coverArtFileName,
            songID: song?.id ?? "",
            sourceID: song?.sourceID,
            filePath: song?.filePath,
            fileFormat: song?.fileFormat,
            revisionToken: player.coverRevision
        )
    }

    /// 真的在出声(播放键画成暂停)。
    var isPlaying: Bool { player.isPlaybackActive }
    var isLoading: Bool { player.isLoading }
    var isLiveRadio: Bool { player.isLiveRadio }
    /// 直播电台能不能切到下一台。
    var canSwitchRadioStation: Bool { player.canSwitchRadioStation }
    /// 正在听的是音乐、电台还是有声,播放条用它的颜色标出来。
    var listeningSpace: ListeningSpace? { player.currentListeningSpace }
    /// 在听有声书(直播电台不算):封面换成竖的书封,标题是书名,第二行是章节进度;
    /// 播放键前放「后退」,不给下一条目 —— 下一条是另一集甚至另一本,播放条上误触代价太大。
    var isSpokenWordBook: Bool { player.currentItemIsSpokenWord && !player.isLiveRadio }
    var spokenWordSkipBackwardSymbol: String { player.spokenWordSkipBackwardSymbol }

    /// 有声书第二行:「第 12 章 · 本章还剩约 18 分钟」。随播放时钟变,只在画这一行的小视图里读。
    var spokenWordPartLine: String {
        [
            SpokenWordPlayerText.partPosition(player.spokenWordNowPlayingSummary),
            SpokenWordPlayerText.partRemaining(player),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// 可用的总时长(未知时 0)。
    var duration: Double { NowPlayingBarPresentationPolicy.duration(player.duration) }

    /// 播放进度,0...1;直播电台没有进度。
    var progress: Double {
        NowPlayingBarPresentationPolicy.progress(
            elapsed: player.currentTime,
            duration: player.duration,
            isLiveRadio: player.isLiveRadio
        )
    }

    /// 整条的朗读标签。第二行只在画出来时才念。
    /// 有声书在书名后面再念正在听的章节。
    func accessibilityLabel(includesSubtitle: Bool) -> String {
        var spokenTitle = title
        if isSpokenWordBook, let part = SpokenWordPlayerText.partTitle(player) {
            spokenTitle = [title, part].filter { !$0.isEmpty }.joined(separator: ": ")
        }
        return NowPlayingBarPresentationPolicy.accessibilityLabel(
            nowPlaying: String(localized: "now_playing"),
            title: spokenTitle,
            subtitle: includesSubtitle ? subtitle : nil
        )
    }

    // MARK: - 动作

    func togglePlayPause() {
        player.togglePlayPause()
    }

    @discardableResult
    func next() async -> Bool {
        await player.next()
    }

    @discardableResult
    func previous() async -> Bool {
        await player.previous()
    }

    func skipSpokenWordBackward() {
        player.skipSpokenWordBackward()
    }
}
#endif
