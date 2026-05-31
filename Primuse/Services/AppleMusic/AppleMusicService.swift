import Foundation
import MusicKit
import PrimuseKit

enum AppleMusicFeatureSettings {
    static let syncUserLibraryKey = "primuse.appleMusic.syncUserLibrary"
    static let catalogSearchEnabledKey = "primuse.appleMusic.catalogSearchEnabled"
    static let autoAddToSmartPlaylistsKey = "primuse.appleMusic.autoAddToSmartPlaylists"

    static var syncUserLibraryEnabled: Bool {
        bool(forKey: syncUserLibraryKey, defaultValue: true)
    }

    static var catalogSearchEnabled: Bool {
        bool(forKey: catalogSearchEnabledKey, defaultValue: true)
    }

    static var autoAddToSmartPlaylistsEnabled: Bool {
        bool(forKey: autoAddToSmartPlaylistsKey, defaultValue: false)
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

/// Apple Music 桥 ── 仅做"在搜索里多挂一组结果 + 调系统播放器开播"这件事,
/// 不试图把 Apple Music 歌混进 MusicLibrary。原因:
/// - Apple Music 是 DRM 流, 必须经 `ApplicationMusicPlayer` 才能播,我们自己
///   的 `AudioPlayerService` 走 AVAudioEngine 不能解。两个 player 各管各
///   的,共享的只有"用户在猿音 UI 里选了一首 Apple Music 歌就跳到系统侧
///   开播"这一刻。
/// - 把 Apple Music 歌持久化进库会让 CloudKit 同步逻辑、本地缓存策略、
///   metadata backfill 都得理解一种新 song type, 改动面巨大。
///
/// 当前能力:
/// 1. 申请 Apple Music 授权 (用户可在 Settings → Apple Music 入口里点)
/// 2. 用户搜索时同步查询 Apple Music catalog,搜歌结果回填给 UI
/// 3. 点 Apple Music 那条结果 → `ApplicationMusicPlayer.shared` 开播
///
/// 用户没订阅 Apple Music 时, `ApplicationMusicPlayer.play()` 会抛 error
/// (`MusicSubscriptionError.privilegesNotGranted`), 我们把它转成
/// `lastPlaybackError` 让 UI 提示用户去订阅。
@MainActor
@Observable
final class AppleMusicService {
    enum AuthState: Sendable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    private(set) var authState: AuthState = .notDetermined
    private(set) var searchResults: [MusicKit.Song] = []
    private(set) var isSearching = false
    /// 最近一次播放调用如果失败 (未订阅 / 国家不可用 / 网络),把错误信息
    /// 暴露给 UI 弹 banner。成功后被清空。
    private(set) var lastPlaybackError: String?
    /// 最近一次搜索的错误信息 — UI 可以用它给用户解释 "为什么 Apple
    /// Music 段没结果"。nil 表示搜索成功 / 还没搜索过。
    private(set) var lastSearchError: String?
    /// 最近一次成功搜索拿到的命中数 — 用来区分 "搜索失败" 和 "结果就是 0"。
    private(set) var lastSearchHitCount: Int = -1
    /// 当前正在 Apple Music 侧播放的歌 — UI 用来在 mini player / NowPlayingAccessory
    /// 显示。Apple Music 是 ApplicationMusicPlayer 系统侧播放, 跟我们自己的
    /// AudioPlayerService.currentSong 是两套, 但 AudioPlayerService 会做镜像把这
    /// 个值同步到自己的 currentSong, 让 NowPlayingView 复用同一个 player。
    private(set) var nowPlayingSong: MusicKit.Song?
    /// Apple Music 是否正在播放 (从 ApplicationMusicPlayer.playbackStatus 转过来)。
    private(set) var isAppleMusicPlaying: Bool = false
    /// ApplicationMusicPlayer.playbackTime 镜像 ── AudioPlayerService 通过观察这个
    /// 把进度条接到 Apple Music。0.5s polling 一次, NowPlayingView 的 interpolatedTime
    /// 在两次采样之间线性外推, 体验跟本地播放一致。
    private(set) var currentPlaybackTime: TimeInterval = 0
    /// 当前曲目时长 ── 从 nowPlayingSong.duration 派生, 跟 playbackTime 同源更新。
    private(set) var currentDuration: TimeInterval = 0
    /// queue.entries 的 PrimuseKit.Song 投影, 给 NowPlayingView 的队列视图用。
    /// 投影在 polling 时做一次, 避免每个观察方各自计算。
    private(set) var queueSongs: [PrimuseKit.Song] = []
    /// repeat / shuffle 状态投影 ── 映射成 PrimuseKit.RepeatMode 让 NowPlayingView
    /// 的循环按钮 / 随机按钮可以直接读 + 写。
    private(set) var repeatModeMirror: PrimuseKit.RepeatMode = .off
    private(set) var shuffleEnabledMirror: Bool = false

    private var searchTask: Task<Void, Never>?
    private var playbackStatusObservation: Task<Void, Never>?

    init() {
        self.authState = Self.mapStatus(MusicAuthorization.currentStatus)
        plog("AppleMusicService init: authState=\(String(describing: self.authState))")
    }

    /// 入口走的是系统弹的授权对话框,首次调有动效, 后续调直接返回现状态。
    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        self.authState = Self.mapStatus(status)
        plog("Apple Music auth status: \(String(describing: status))")
    }

    /// 触发对 Apple Music catalog 的搜索。200ms debounce 跟 SearchView 自己的
    /// debounce 错开 (这边再叠 200ms 防止用户连击触发多次 catalog 调用)。
    /// 未授权时直接清结果,不试着 silently request 授权 (避免无端弹窗)。
    func search(query: String) {
        guard AppleMusicFeatureSettings.catalogSearchEnabled else {
            clearCatalogSearchResults()
            return
        }

        // 用户可能在外部 (iOS Settings) 修改了授权状态, 重读一次以保持同步。
        // 比 init 时只读一次更可靠 — 用户首次启动 → 去设置授权 → 回 app 搜索
        // 这条路径下 authState 不会陷在 notDetermined。
        let live = Self.mapStatus(MusicAuthorization.currentStatus)
        if live != authState {
            plog("Apple Music authState refresh: \(String(describing: self.authState)) → \(String(describing: live))")
            authState = live
        }

        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard authState == .authorized else {
            searchResults = []
            lastSearchError = nil
            lastSearchHitCount = -1
            plog("Apple Music search skipped: not authorized (\(String(describing: self.authState)))")
            return
        }
        guard !trimmed.isEmpty else {
            searchResults = []
            lastSearchError = nil
            lastSearchHitCount = -1
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(term: trimmed)
        }
    }

    func clearCatalogSearchResults() {
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        isSearching = false
        lastSearchError = nil
        lastSearchHitCount = -1
    }

    private func runSearch(term: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
            request.limit = 25
            let response = try await request.response()
            if !Task.isCancelled {
                self.searchResults = Array(response.songs)
                self.lastSearchError = nil
                self.lastSearchHitCount = response.songs.count
                plog("Apple Music search '\(term)' → \(response.songs.count) results")
            }
        } catch is CancellationError {
            // user 继续打字,旧 query 失效,沉默丢弃
        } catch {
            plog("⚠️Apple Music search failed for '\(term)': \(error.localizedDescription)")
            if !Task.isCancelled {
                self.searchResults = []
                self.lastSearchError = error.localizedDescription
                self.lastSearchHitCount = -1
            }
        }
    }

    /// 调系统的 ApplicationMusicPlayer 开播。播放本身完全在系统侧,我们自己
    /// 的 AudioPlayerService 不参与, 跟我们当前播放的 NAS / 云盘歌互不干扰
    /// (但同一时间只能有一个 audio session active, 系统会自动让 Apple Music
    /// 暂停 / 抢占我们的)。
    ///
    /// 之前历史上有过点 row 必闪退的情况, 两个根因:
    /// 1. Info.plist 缺 `NSAppleMusicUsageDescription` → 调 MusicKit 会被 OS
    ///    直接 SIGABORT, 不走 catch。已通过 project.yml 把权限说明加回来。
    /// 2. 用户没有 Apple Music 订阅 / 区域不支持时, ApplicationMusicPlayer
    ///    的 queue 设置 + play() 在某些 iOS 版本会触发底层 assert。这里先
    ///    用 `MusicSubscription.current` 探一下能力, 不能播就直接给 UI 报
    ///    错而不是冒险调 player。
    /// 把整段 queue 推给 ApplicationMusicPlayer ── 让用户点资料库里某首歌时
     /// 自动把后续歌曲串成播放上下文, 支持 mini player / 大播放器的下一首/上一首
     /// 按钮; 否则单首 queue 下 skipToNext 实际等同 stop, 体验是"控件没反应"。
     /// startAt 越界自动 clamp 到 0。
     func play(songs: [MusicKit.Song], startAt index: Int) async {
         guard !songs.isEmpty else { return }
         let safeIndex = max(0, min(index, songs.count - 1))
         let starting = songs[safeIndex]
         // caller (AudioPlayerService.playAppleMusicSong) 已经把猿音自己的
         // engine 停掉了, 这里直接接管 audio session。
         let player = ApplicationMusicPlayer.shared
         nowPlayingSong = starting
         isAppleMusicPlaying = true
         observePlaybackStatusIfNeeded()
         do {
             player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: starting)
             try await player.play()
         } catch {
             let ns = error as NSError
             let isSpuriousMPError2 = ns.domain == "MPMusicPlayerControllerErrorDomain" && ns.code == 2
             if isSpuriousMPError2 {
                 plog("Apple Music play threw spurious MPError 2, ignoring (audio likely playing)")
             } else {
                 plog("⚠️Apple Music play(queue) failed: \(error.localizedDescription)")
                 lastPlaybackError = error.localizedDescription
                 isAppleMusicPlaying = false
             }
         }
     }

     /// 下一首 / 上一首 ── 走 ApplicationMusicPlayer 自带 queue 操作。
     /// 单首 queue 时 skipToNextEntry 等同 stop, 所以 caller 应通过 play(songs:)
     /// 把上下文塞够再调用。
     func skipToNextAppleMusic() {
         Task { @MainActor in
             do {
                 try await ApplicationMusicPlayer.shared.skipToNextEntry()
             } catch {
                 plog("⚠️Apple Music skipNext failed: \(error.localizedDescription)")
             }
         }
     }

     func skipToPreviousAppleMusic() {
         Task { @MainActor in
             do {
                 try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
             } catch {
                 plog("⚠️Apple Music skipPrev failed: \(error.localizedDescription)")
             }
         }
     }

     func play(_ song: MusicKit.Song) async {
        lastPlaybackError = nil
        // 让猿音自家播放器先停掉, audio session 让给 ApplicationMusicPlayer。
        // 否则: 本地正在播 → 用户点 Apple Music row → ApplicationMusicPlayer 接管
        // audio session, 但 AudioPlayerService.currentSong 还在, mini player
        // 一直显示本地歌, 看不出切换了 (Apple Music 才是当前的实际播放)。
        NotificationCenter.default.post(name: .primuseAppleMusicWillPlay, object: nil)

        // 订阅探测 — 没订阅 / 不支持时直接 bail, 避免触发 player 的边界 case。
        do {
            let subscription = try await MusicSubscription.current
            guard subscription.canPlayCatalogContent else {
                lastPlaybackError = subscription.canBecomeSubscriber
                    ? String(localized: "apple_music_needs_subscription")
                    : String(localized: "apple_music_unavailable")
                return
            }
        } catch {
            plog("⚠️Apple Music subscription check failed: \(error.localizedDescription)")
            lastPlaybackError = error.localizedDescription
            return
        }

        let player = ApplicationMusicPlayer.shared
        // 乐观先把 nowPlayingSong 设上 — MusicKit 的 play() 在 iOS 26 上经常误抛
        // MPMusicPlayerControllerErrorDomain error 2 (即便音频实际已经开始播),
        // 不能等 try 成功才设, 否则 UI 永远不显示 mini player。
        nowPlayingSong = song
        isAppleMusicPlaying = true
        observePlaybackStatusIfNeeded()
        do {
            player.queue = ApplicationMusicPlayer.Queue(for: [song])
            try await player.play()
        } catch {
            // MusicKit 已知 quirk: error 2 (`MPMusicPlayerControllerErrorDomain
            // error 2`) 经常在播放实际成功的情况下被抛, 不当 failure 处理。
            // 其他 error 才暴露给 UI。
            let ns = error as NSError
            let isSpuriousMPError2 = ns.domain == "MPMusicPlayerControllerErrorDomain" && ns.code == 2
            if isSpuriousMPError2 {
                plog("Apple Music play threw spurious MPError 2, ignoring (audio likely playing)")
            } else {
                plog("⚠️Apple Music play failed: \(error.localizedDescription)")
                lastPlaybackError = error.localizedDescription
                // 不清 nowPlayingSong — 让 mini player 保留, 用户能看到自己点了
                // 哪首歌, 并通过 lastPlaybackError UI 看到错误原因。否则用户
                // 体验是 "点了没反应" + 没 mini player + 看不到任何错误。
                isAppleMusicPlaying = false
            }
        }
    }

    /// 暂停 / 恢复 Apple Music 系统侧播放。Mini player 控制转发用。
    func togglePlayPauseAppleMusic() {
        if ApplicationMusicPlayer.shared.state.playbackStatus == .playing {
            ApplicationMusicPlayer.shared.pause()
            isAppleMusicPlaying = false
        } else {
            Task { @MainActor [weak self] in
                // Task 内重新取 shared 引用, 避免 Swift 6 报 non-Sendable 跨边界。
                do { try await ApplicationMusicPlayer.shared.play() } catch {
                    plog("⚠️Apple Music resume failed: \(error.localizedDescription)")
                }
                self?.isAppleMusicPlaying = ApplicationMusicPlayer.shared.state.playbackStatus == .playing
            }
        }
    }

    /// 下一首 — 当前实现一首一首播 (queue 只塞一首歌), 所以 skip 实际等同 stop。
    /// 后续可以扩展成顺播多首。
    func stopAppleMusic() {
        ApplicationMusicPlayer.shared.stop()
        nowPlayingSong = nil
        isAppleMusicPlaying = false
    }

    /// 监听 ApplicationMusicPlayer.state, 把 playbackStatus / playbackTime / queue
     /// / repeatMode / shuffleMode 同步到本类的镜像字段。AudioPlayerService 通过
     /// @Observable 自动拿到这些变化, 投影成自己的 currentTime / queue / repeat
     /// 等让 NowPlayingView 复用同一份 UI。
     ///
     /// 0.5s polling ── ApplicationMusicPlayer 是 Combine ObservableObject 但跨
     /// actor 订阅麻烦, polling 简单可靠; NowPlayingView 的 interpolatedTime 在两次
     /// 采样间做线性外推, 进度条不会卡。
     private func observePlaybackStatusIfNeeded() {
         guard playbackStatusObservation == nil else { return }
         playbackStatusObservation = Task { [weak self] in
             while !Task.isCancelled {
                 try? await Task.sleep(for: .milliseconds(500))
                 guard let self else { return }
                 await self.tickAppleMusicState()
             }
         }
     }

     private func tickAppleMusicState() async {
         let player = ApplicationMusicPlayer.shared
         let nowPlaying = player.state.playbackStatus == .playing
         if isAppleMusicPlaying != nowPlaying {
             isAppleMusicPlaying = nowPlaying
         }
         // queue.currentEntry 反映用户在 queue 里走到哪 — 不限于初次 play, 也包括
         // 自动跳下一首 / skipToNextEntry。entry.item 在 user library / catalog 都
         // 是 .song case。其它类型 (musicVideo 等) 我们 user library 拉的时候 filter
         // 过, 这里默认走 .song 分支。
         if let entry = player.queue.currentEntry {
             switch entry.item {
             case .song(let s):
                 // ApplicationMusicPlayer 返回的常常是 catalog Song (数字 id),
                 // 反查 cache 拿 user library 版本 (i.* id), 保证下游 CachedArtworkView
                 // / catalogURL 等按 id 查 cache 的逻辑能命中。
                 let canonical = AppServices.shared.appleMusicLibrary.canonicalForNowPlaying(s)
                 if nowPlayingSong?.id != canonical.id {
                     nowPlayingSong = canonical
                 }
                 currentDuration = canonical.duration ?? s.duration ?? 0
             default:
                 break
             }
         }
         let pt = player.playbackTime
         // 浮点数微抖动也会触发 @Observable 通知, 0.05s 以内不动 cuts 掉低频闪烁。
         if abs(pt - currentPlaybackTime) > 0.05 {
             currentPlaybackTime = pt
         }
         // queueSongs: 把 entry list 投影成 PrimuseKit.Song, 给 NowPlayingView 的
         // 队列视图直接渲染。entry.id 不稳定时 fallback 不更新。
         let snapshot = player.queue.entries.compactMap { entry -> MusicKit.Song? in
             if case .song(let s) = entry.item { return s }
             return nil
         }
         let projected = snapshot.map { AppleMusicLibraryService.toPrimuseSong($0) }
         if projected.map(\.id) != queueSongs.map(\.id) {
             queueSongs = projected
         }
         // repeat / shuffle 镜像
         let r = Self.mapRepeat(player.state.repeatMode)
         if r != repeatModeMirror { repeatModeMirror = r }
         let sh = (player.state.shuffleMode == .songs)
         if sh != shuffleEnabledMirror { shuffleEnabledMirror = sh }
     }

     /// 跳到指定时间 ── 直接赋值 playbackTime。系统 player 0.2s 内响应,
     /// AudioPlayerService.seek 调过来不需要 await。
     func seekAppleMusic(to time: TimeInterval) {
         ApplicationMusicPlayer.shared.playbackTime = max(0, time)
         currentPlaybackTime = max(0, time)
     }

     func setAppleMusicRepeat(_ mode: PrimuseKit.RepeatMode) {
         let mk: MusicKit.MusicPlayer.RepeatMode
         switch mode {
         case .off: mk = MusicKit.MusicPlayer.RepeatMode.none
         case .all: mk = .all
         case .one: mk = .one
         }
         ApplicationMusicPlayer.shared.state.repeatMode = mk
         repeatModeMirror = mode
     }

     func setAppleMusicShuffle(_ enabled: Bool) {
         ApplicationMusicPlayer.shared.state.shuffleMode = enabled ? .songs : .off
         shuffleEnabledMirror = enabled
     }

     private static func mapRepeat(_ mk: MusicKit.MusicPlayer.RepeatMode?) -> PrimuseKit.RepeatMode {
         switch mk {
         case .one: return .one
         case .all: return .all
         default: return .off
         }
     }

    private static func mapStatus(_ status: MusicAuthorization.Status) -> AuthState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
