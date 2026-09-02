import Foundation
import MusicKit
import PrimuseKit

enum AppleMusicFeatureSettings {
    static let syncUserLibraryKey = AppleMusicLibraryPreferences.syncUserLibraryKey
    static let catalogSearchEnabledKey = "primuse.appleMusic.catalogSearchEnabled"
    static let autoAddToSmartPlaylistsKey = "primuse.appleMusic.autoAddToSmartPlaylists"

    static var syncUserLibraryEnabled: Bool {
        AppleMusicLibraryPreferences.syncUserLibraryEnabled
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
    enum PlaybackPhase: Equatable, Sendable {
        case pending
        case started
        case failed(String)
    }

    struct PlaybackRequestState: Equatable, Sendable {
        let id: UUID
        var phase: PlaybackPhase
    }

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
    /// Primuse song ID projected directly from MusicKit's raw current entry.
    /// When it differs from the canonical library projection,
    /// AudioPlayerService uses it once to rescue metadata cached by older
    /// builds under the transient catalog-derived ID.
    private(set) var nowPlayingRawSongID: String?
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
    /// Every observable playback field belongs to this request. Callers and
    /// mirrors must match both its ID and phase before consuming a result.
    private(set) var playbackRequestState: PlaybackRequestState?
    var activePlaybackRequestID: UUID? { playbackRequestState?.id }

    private var searchTask: Task<Void, Never>?
    private var catalogPlaybackTask: Task<Void, Never>?
    private var playbackStatusObservation: Task<Void, Never>?
    /// Fired once when an Apple Music track that was observed playing reaches
    /// a terminal boundary. AudioPlayerService uses this to advance its queue.
    @ObservationIgnored var onPlaybackEnded: ((UUID) -> Void)?
    /// Direct catalog playback reaches this service without passing through
    /// AudioPlayerService.play(song:). Await the shared ownership handoff so a
    /// remote renderer is stopped before MusicKit starts local audio.
    @ObservationIgnored var preparePlaybackHandoff: (@MainActor (UUID) async -> Bool)?
    @ObservationIgnored private var hasObservedActivePlayback = false
    @ObservationIgnored private var wasPausedByUser = false
    @ObservationIgnored private var playbackCommandGeneration: UInt64 = 0
    @ObservationIgnored private var isPlaybackInterrupted = false
    @ObservationIgnored private var lastObservedPlaybackTime: TimeInterval?
    @ObservationIgnored private var furthestObservedPlaybackTime: TimeInterval = 0
    @ObservationIgnored private var nearEndStallSampleCount = 0
    private static let playbackEndStallSampleThreshold = 6
    /// 上个 tick 的 queue 轻量指纹 (entry id 列表) ── 只有指纹变化才重做
    /// 全量 SHA256 + Song 结构体投影, 避免每 0.5s 对几千首 queue 烧主线程。
    private var lastQueueSignature: [String] = []
    private let playbackSettings: PlaybackSettingsStore

    init(playbackSettings: PlaybackSettingsStore) {
        self.playbackSettings = playbackSettings
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
            guard !Task.isCancelled,
                  AppleMusicFeatureSettings.catalogSearchEnabled,
                  let self else { return }
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
        guard AppleMusicFeatureSettings.catalogSearchEnabled else {
            clearCatalogSearchResults()
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
            request.limit = 25
            let response = try await request.response()
            if !Task.isCancelled, AppleMusicFeatureSettings.catalogSearchEnabled {
                self.searchResults = Array(response.songs)
                self.lastSearchError = nil
                self.lastSearchHitCount = response.songs.count
                plog("Apple Music search '\(term)' → \(response.songs.count) results")
            }
        } catch is CancellationError {
            // user 继续打字,旧 query 失效,沉默丢弃
        } catch {
            plog("⚠️Apple Music search failed for '\(term)': \(error.localizedDescription)")
            if !Task.isCancelled, AppleMusicFeatureSettings.catalogSearchEnabled {
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
    /// 播放前置 ── 清掉上次失败残留的 lastPlaybackError。目录结果以及资料库里
    /// 仍带 catalog ID 的订阅歌曲保留原有能力检查，避免无订阅时触发 MusicKit
    /// 底层 assert；只有确认不带 catalog 身份的导入/本地资料库歌曲才绕过。
    private func ensurePlayablePreflight(
        for source: AppleMusicPlaybackSource,
        requestID: UUID
    ) async -> Bool {
        guard isPlaybackRequestPending(requestID), !Task.isCancelled else { return false }
        guard AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(for: source) else {
            return true
        }

        do {
            let subscription = try await MusicSubscription.current
            guard isPlaybackRequestPending(requestID), !Task.isCancelled else { return false }
            guard subscription.canPlayCatalogContent else {
                let message = subscription.canBecomeSubscriber
                    ? String(localized: "apple_music_needs_subscription")
                    : String(localized: "apple_music_unavailable")
                failPlaybackRequest(requestID, message: message)
                return false
            }
            return true
        } catch {
            guard isPlaybackRequestPending(requestID), !Task.isCancelled else { return false }
            plog("⚠️Apple Music subscription check failed: \(error.localizedDescription)")
            failPlaybackRequest(requestID, message: error.localizedDescription)
            return false
        }
    }

    private enum QueueStartFailure: Error {
        case preparing(any Error)
        case playing(any Error)

        var underlyingError: any Error {
            switch self {
            case .preparing(let error), .playing(let error): error
            }
        }

        var failedWhilePlaying: Bool {
            if case .playing = self { return true }
            return false
        }

        var stage: String {
            failedWhilePlaying ? "play" : "prepare"
        }
    }

    private func startPreparedQueue(
        songs: [MusicKit.Song],
        startingAt starting: MusicKit.Song,
        commandGeneration: UInt64,
        requestID: UUID
    ) async throws {
        ApplicationMusicPlayer.shared.queue = ApplicationMusicPlayer.Queue(
            for: songs,
            startingAt: starting
        )
        do {
            // Apple documents this as the step that resolves and buffers the
            // starting entry. Calling play() directly leaves macOS with an
            // unresolved queue and surfaces an opaque MP error instead.
            // Reacquire `shared` at each suspension point: MusicKit's player
            // is not Sendable, so retaining it across await would violate
            // Swift 6 actor isolation even though this service is MainActor.
            try await ApplicationMusicPlayer.shared.prepareToPlay()
        } catch {
            throw QueueStartFailure.preparing(error)
        }

        guard isPlaybackRequestPending(requestID),
              playbackCommandGeneration == commandGeneration,
              !wasPausedByUser,
              !Task.isCancelled else {
            throw CancellationError()
        }

        do {
            try await ApplicationMusicPlayer.shared.play()
        } catch {
            throw QueueStartFailure.playing(error)
        }
    }

    /// Starts the exact Primuse queue first, then retries only the selected song
    /// when MusicKit rejects a multi-item system queue. This preserves normal
    /// next/previous behavior whenever the queue is valid without letting one
    /// stale library entry make the selected playable song silent.
    private func startPreparedQueueWithSingleItemFallback(
        songs: [MusicKit.Song],
        startingAt starting: MusicKit.Song,
        commandGeneration: UInt64,
        requestID: UUID
    ) async throws {
        do {
            try await startPreparedQueue(
                songs: songs,
                startingAt: starting,
                commandGeneration: commandGeneration,
                requestID: requestID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as QueueStartFailure {
            let nsError = failure.underlyingError as NSError
            if AppleMusicQueueRecoveryPolicy.shouldTreatAsStarted(
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                failedWhilePlaying: failure.failedWhilePlaying
            ) {
                plog("Apple Music play reported MP error 2 after play(); keeping the active playback projection")
                return
            }

            guard AppleMusicQueueRecoveryPolicy.shouldRetryWithStartingItemOnly(
                errorDomain: nsError.domain,
                queueItemCount: songs.count
            ) else {
                throw failure
            }
            guard isPlaybackRequestPending(requestID),
                  playbackCommandGeneration == commandGeneration,
                  !wasPausedByUser,
                  !Task.isCancelled else {
                throw CancellationError()
            }

            plog(
                "Apple Music \(failure.stage) failed for \(songs.count)-item queue "
                    + "(domain=\(nsError.domain), code=\(nsError.code)); retrying selected item only"
            )
            ApplicationMusicPlayer.shared.stop()
            do {
                try await startPreparedQueue(
                    songs: [starting],
                    startingAt: starting,
                    commandGeneration: commandGeneration,
                    requestID: requestID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let retryFailure as QueueStartFailure {
                let retryError = retryFailure.underlyingError as NSError
                if AppleMusicQueueRecoveryPolicy.shouldTreatAsStarted(
                    errorDomain: retryError.domain,
                    errorCode: retryError.code,
                    failedWhilePlaying: retryFailure.failedWhilePlaying
                ) {
                    plog("Apple Music single-item play reported MP error 2 after play(); keeping playback")
                    return
                }
                throw retryFailure
            }
        }
    }

    private func userFacingPlaybackError(_ error: any Error) -> String {
        let underlying: any Error
        if let failure = error as? QueueStartFailure {
            underlying = failure.underlyingError
        } else {
            underlying = error
        }
        let nsError = underlying as NSError
        if nsError.domain == AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain {
            return String(localized: "playback_error_apple_music_generic")
        }
        return underlying.localizedDescription
    }

    private func logQueueStartFailure(_ error: any Error, context: String) {
        let failure = error as? QueueStartFailure
        let underlying = failure?.underlyingError ?? error
        let nsError = underlying as NSError
        plog(
            "⚠️Apple Music \(context) failed at \(failure?.stage ?? "unknown") "
                + "(domain=\(nsError.domain), code=\(nsError.code)): \(nsError.localizedDescription)"
        )
    }

     /// 把整段 queue 推给 ApplicationMusicPlayer ── 让用户点资料库里某首歌时
     /// 自动把后续歌曲串成播放上下文, 支持 mini player / 大播放器的下一首/上一首
     /// 按钮; 否则单首 queue 下 skipToNext 实际等同 stop, 体验是"控件没反应"。
     /// startAt 越界自动 clamp 到 0。
     func playUserLibrary(
        songs: [MusicKit.Song],
        startAt index: Int,
        source: AppleMusicPlaybackSource,
        expectedDuration: TimeInterval,
        requestID: UUID,
        requestCanContinue: () -> Bool
     ) async {
         let commandGeneration = playbackCommandGeneration
         guard !songs.isEmpty,
               isPlaybackRequestPending(requestID),
               !wasPausedByUser,
               !Task.isCancelled else { return }
         guard requestCanContinue() else {
             failPlaybackRequest(
                requestID,
                message: String(localized: "playback_error_apple_music_generic")
             )
             return
         }
         let safeIndex = max(0, min(index, songs.count - 1))
         let starting = songs[safeIndex]
         // 不能把所有 MusicLibraryRequest 结果都当成本地文件：订阅过期后，
         // catalog 歌曲仍可能残留在资料库。caller 已根据 play parameters 区分
         // 两者；本地导入绕过，catalog-backed 资料库歌曲继续走防崩预检。
         guard await ensurePlayablePreflight(for: source, requestID: requestID) else {
             return
         }
         guard isPlaybackRequestPending(requestID),
               playbackCommandGeneration == commandGeneration,
               !wasPausedByUser,
               !Task.isCancelled else { return }
         guard requestCanContinue() else {
             failPlaybackRequest(
                requestID,
                message: String(localized: "playback_error_apple_music_generic")
             )
             return
         }
         // caller (AudioPlayerService.playAppleMusicSong) 已经把猿音自己的
         // engine 停掉了, 这里直接接管 audio session。
         let player = ApplicationMusicPlayer.shared
#if os(iOS)
         player.transition = configuredTransition()
#endif
         nowPlayingSong = starting
         let fallbackDuration = expectedDuration.isFinite && expectedDuration > 0
             ? expectedDuration
             : 0
         currentDuration = starting.duration ?? fallbackDuration
         isAppleMusicPlaying = true
         resetPlaybackEndObservation()
         observePlaybackStatusIfNeeded(requestID: requestID)
         do {
             try await startPreparedQueueWithSingleItemFallback(
                songs: songs,
                startingAt: starting,
                commandGeneration: commandGeneration,
                requestID: requestID
             )
             guard isPlaybackRequestPending(requestID),
                   playbackCommandGeneration == commandGeneration,
                   !wasPausedByUser,
                   !Task.isCancelled else {
                 quiesceStalePlaybackIfNeeded(requestID: requestID)
                 return
             }
             guard requestCanContinue() else {
                 player.stop()
                 failPlaybackRequest(
                    requestID,
                    message: String(localized: "playback_error_apple_music_generic")
                 )
                 isAppleMusicPlaying = false
                 resetPlaybackEndObservation()
                 return
             }
             markPlaybackStarted(requestID)
         } catch is CancellationError {
             quiesceStalePlaybackIfNeeded(requestID: requestID)
         } catch {
             guard isPlaybackRequestPending(requestID),
                   playbackCommandGeneration == commandGeneration,
                   !wasPausedByUser,
                   !Task.isCancelled else {
                 quiesceStalePlaybackIfNeeded(requestID: requestID)
                 return
             }
             guard requestCanContinue() else {
                 player.stop()
                 failPlaybackRequest(
                    requestID,
                    message: String(localized: "playback_error_apple_music_generic")
                 )
                 isAppleMusicPlaying = false
                 resetPlaybackEndObservation()
                 return
             }
             logQueueStartFailure(error, context: "library queue")
             failPlaybackRequest(requestID, message: userFacingPlaybackError(error))
             isAppleMusicPlaying = false
             resetPlaybackEndObservation()
         }
     }

     /// 下一首 / 上一首 ── 走 ApplicationMusicPlayer 自带 queue 操作。
     /// 单首 queue 时 skipToNextEntry 等同 stop, 所以 caller 应通过
     /// playUserLibrary(songs:startAt:) 把上下文塞够再调用。
     @discardableResult
     func skipToNextAppleMusic() async -> Bool {
         guard let requestID = activePlaybackRequestID else { return false }
         do {
             try await ApplicationMusicPlayer.shared.skipToNextEntry()
             return true
         } catch {
             guard isPlaybackRequestActive(requestID), !Task.isCancelled else { return false }
             plog("⚠️Apple Music skipNext failed: \(error.localizedDescription)")
             return false
         }
     }

     @discardableResult
     func skipToPreviousAppleMusic() async -> Bool {
         guard let requestID = activePlaybackRequestID else { return false }
         do {
             try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
             return true
         } catch {
             guard isPlaybackRequestActive(requestID), !Task.isCancelled else { return false }
             plog("⚠️Apple Music skipPrev failed: \(error.localizedDescription)")
             return false
         }
     }

    func play(_ song: MusicKit.Song) async {
        let requestID = beginPlaybackRequest()
        // 让猿音自家播放器先停掉, audio session 让给 ApplicationMusicPlayer。
        // 否则: 本地正在播 → 用户点 Apple Music row → ApplicationMusicPlayer 接管
        // audio session, 但 AudioPlayerService.currentSong 还在, mini player
        // 一直显示本地歌, 看不出切换了 (Apple Music 才是当前的实际播放)。
        NotificationCenter.default.post(name: .primuseAppleMusicWillPlay, object: requestID)

        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            if let preparePlaybackHandoff = self.preparePlaybackHandoff {
                guard await preparePlaybackHandoff(requestID),
                      self.isPlaybackRequestPending(requestID),
                      !Task.isCancelled else { return }
            }
            await self.performCatalogPlay(song, requestID: requestID)
        }
        catalogPlaybackTask = operation
        await operation.value
        if isPlaybackRequestActive(requestID) {
            catalogPlaybackTask = nil
        }
    }

    private func performCatalogPlay(_ song: MusicKit.Song, requestID: UUID) async {
        let commandGeneration = playbackCommandGeneration
        guard !wasPausedByUser else { return }
        // 订阅探测 + 清上次错误 ── 没订阅 / 不支持时直接 bail, 避免触发 player
        // 的边界 case。
        guard await ensurePlayablePreflight(for: .catalog, requestID: requestID) else {
            return
        }
        guard isPlaybackRequestPending(requestID),
              playbackCommandGeneration == commandGeneration,
              !wasPausedByUser,
              !Task.isCancelled else { return }

        let player = ApplicationMusicPlayer.shared
#if os(iOS)
        player.transition = configuredTransition()
#endif
        // 乐观先把 nowPlayingSong 设上 — MusicKit 的 play() 在 iOS 26 上经常误抛
        // MPMusicPlayerControllerErrorDomain error 2 (即便音频实际已经开始播),
        // 不能等 try 成功才设, 否则 UI 永远不显示 mini player。
        nowPlayingSong = song
        currentDuration = song.duration ?? 0
        isAppleMusicPlaying = true
        resetPlaybackEndObservation()
        observePlaybackStatusIfNeeded(requestID: requestID)
        do {
            try await startPreparedQueueWithSingleItemFallback(
                songs: [song],
                startingAt: song,
                commandGeneration: commandGeneration,
                requestID: requestID
            )
            guard isPlaybackRequestPending(requestID),
                  playbackCommandGeneration == commandGeneration,
                  !wasPausedByUser,
                  !Task.isCancelled else {
                quiesceStalePlaybackIfNeeded(requestID: requestID)
                return
            }
            markPlaybackStarted(requestID)
        } catch is CancellationError {
            quiesceStalePlaybackIfNeeded(requestID: requestID)
        } catch {
            guard isPlaybackRequestPending(requestID),
                  playbackCommandGeneration == commandGeneration,
                  !wasPausedByUser,
                  !Task.isCancelled else {
                quiesceStalePlaybackIfNeeded(requestID: requestID)
                return
            }
            logQueueStartFailure(error, context: "catalog item")
            failPlaybackRequest(requestID, message: userFacingPlaybackError(error))
            // 不清 nowPlayingSong — 让 mini player 保留, 用户能看到自己点了
            // 哪首歌, 并通过 lastPlaybackError UI 看到错误原因。否则用户
            // 体验是 "点了没反应" + 没 mini player + 看不到任何错误。
            isAppleMusicPlaying = false
            resetPlaybackEndObservation()
        }
    }

#if os(iOS)
    /// MusicKit currently exposes only none/fixed crossfade on iOS. Smart
    /// boundary analysis requires decoded PCM, which DRM catalog streams do not
    /// expose, so Apple Music intentionally honors the duration as a fixed fade.
    private func configuredTransition() -> MusicKit.MusicPlayer.Transition {
        let settings = playbackSettings.snapshot()
        if settings.outputMode == .effects, settings.crossfadeEnabled {
            return .crossfade(duration: settings.crossfadeDuration)
        }
        return .none
    }
#endif

    /// Explicit commands stay idempotent when Lock Screen sends Play or Pause
    /// after MusicKit's state changed independently of Primuse's last mirror.
    @discardableResult
    func pauseAppleMusic() -> Bool {
        guard activePlaybackRequestID != nil else { return false }
        playbackCommandGeneration &+= 1
        if ApplicationMusicPlayer.shared.state.playbackStatus == .playing {
            ApplicationMusicPlayer.shared.pause()
        }
        isAppleMusicPlaying = false
        wasPausedByUser = true
        return true
    }

    @discardableResult
    func resumeAppleMusic() -> Bool {
        guard let requestID = activePlaybackRequestID else { return false }
        playbackCommandGeneration &+= 1
        let commandGeneration = playbackCommandGeneration
        if ApplicationMusicPlayer.shared.state.playbackStatus == .playing {
            isAppleMusicPlaying = true
            wasPausedByUser = false
            isPlaybackInterrupted = false
            return true
        }
        wasPausedByUser = false
        isPlaybackInterrupted = false
        Task { @MainActor [weak self] in
            guard let self,
                  self.isPlaybackRequestActive(requestID),
                  self.playbackCommandGeneration == commandGeneration,
                  !self.wasPausedByUser else { return }
            // Task 内重新取 shared 引用, 避免 Swift 6 报 non-Sendable 跨边界。
            do { try await ApplicationMusicPlayer.shared.play() } catch {
                guard self.isPlaybackRequestActive(requestID),
                      self.playbackCommandGeneration == commandGeneration,
                      !self.wasPausedByUser,
                      !Task.isCancelled else {
                    self.quiesceStalePlaybackIfNeeded(requestID: requestID)
                    return
                }
                plog("⚠️Apple Music resume failed: \(error.localizedDescription)")
            }
            guard self.isPlaybackRequestActive(requestID),
                  self.playbackCommandGeneration == commandGeneration,
                  !self.wasPausedByUser,
                  !Task.isCancelled else {
                self.quiesceStalePlaybackIfNeeded(requestID: requestID)
                return
            }
            self.isAppleMusicPlaying = ApplicationMusicPlayer.shared.state.playbackStatus == .playing
        }
        return true
    }

    /// Mini-player toggle delegates to the same explicit operations used by
    /// remote Play and Pause commands.
    func togglePlayPauseAppleMusic() {
        if ApplicationMusicPlayer.shared.state.playbackStatus == .playing {
            _ = pauseAppleMusic()
        } else {
            _ = resumeAppleMusic()
        }
    }

    /// 下一首 — 当前实现一首一首播 (queue 只塞一首歌), 所以 skip 实际等同 stop。
    /// 后续可以扩展成顺播多首。
    func stopAppleMusic() {
        playbackCommandGeneration &+= 1
        catalogPlaybackTask?.cancel()
        catalogPlaybackTask = nil
        playbackRequestState = nil
        resetPublishedPlaybackState()
    }

    private func resetPublishedPlaybackState() {
        // 先取消 polling, 否则 stop() 不清空 queue, 下个 tick 会从残留的
        // queue.currentEntry 把 nowPlayingSong 复活, mini player 关不掉。
        playbackStatusObservation?.cancel()
        playbackStatusObservation = nil
        resetPlaybackEndObservation()
        ApplicationMusicPlayer.shared.stop()
        nowPlayingSong = nil
        nowPlayingRawSongID = nil
        isAppleMusicPlaying = false
        currentPlaybackTime = 0
        currentDuration = 0
        queueSongs = []
        lastQueueSignature = []
        lastPlaybackError = nil
    }

    /// 监听 ApplicationMusicPlayer.state, 把 playbackStatus / playbackTime / queue
     /// / repeatMode / shuffleMode 同步到本类的镜像字段。AudioPlayerService 通过
     /// @Observable 自动拿到这些变化, 投影成自己的 currentTime / queue / repeat
     /// 等让 NowPlayingView 复用同一份 UI。
     ///
     /// 0.5s polling ── ApplicationMusicPlayer 是 Combine ObservableObject 但跨
     /// actor 订阅麻烦, polling 简单可靠; NowPlayingView 的 interpolatedTime 在两次
     /// 采样间做线性外推, 进度条不会卡。
     private func observePlaybackStatusIfNeeded(requestID: UUID) {
         guard isPlaybackRequestActive(requestID), playbackStatusObservation == nil else { return }
         playbackStatusObservation = Task { [weak self] in
             while !Task.isCancelled {
                 try? await Task.sleep(for: .milliseconds(500))
                 guard let self,
                       self.isPlaybackRequestActive(requestID),
                       !Task.isCancelled else { return }
                 await self.tickAppleMusicState(requestID: requestID)
             }
         }
     }

     private func tickAppleMusicState(requestID: UUID) async {
         guard isPlaybackRequestActive(requestID),
               playbackPhase(for: requestID) == .started,
               !Task.isCancelled else { return }
         let player = ApplicationMusicPlayer.shared
         let status = player.state.playbackStatus
         let playbackTime = player.playbackTime
         let nowPlaying = status == .playing

         // Refresh duration before evaluating the end state. MusicKit can
         // publish the first useful duration and the terminal status in
         // adjacent polling ticks.
         if status != .stopped,
            let entry = player.queue.currentEntry,
            case .song(let song) = entry.item {
             let canonical = AppServices.shared.appleMusicLibrary.canonicalForNowPlaying(song)
             currentDuration = canonical.duration ?? song.duration ?? currentDuration
         }

         if nowPlaying {
             hasObservedActivePlayback = true
             // A real backwards jump while still playing is a seek/restart,
             // not a natural-end time reset. Start the watchdog window over.
             if let previous = lastObservedPlaybackTime,
                playbackTime < previous - 1 {
                 furthestObservedPlaybackTime = playbackTime
                 nearEndStallSampleCount = 0
             } else {
                 furthestObservedPlaybackTime = max(furthestObservedPlaybackTime, playbackTime)
             }

             let madeProgress = lastObservedPlaybackTime.map {
                 playbackTime > $0 + 0.05
             } ?? true
             let nearEnd = AppleMusicPlaybackEndPolicy.isNearEnd(
                 duration: currentDuration,
                 playbackTime: playbackTime,
                 furthestObservedTime: furthestObservedPlaybackTime
             )
             if nearEnd && !madeProgress {
                 nearEndStallSampleCount += 1
             } else {
                 nearEndStallSampleCount = 0
             }
         }
         lastObservedPlaybackTime = playbackTime

         let nearEnd = AppleMusicPlaybackEndPolicy.isNearEnd(
             duration: currentDuration,
             playbackTime: playbackTime,
             furthestObservedTime: furthestObservedPlaybackTime
         )
         let endedAfterPlaying = AppleMusicPlaybackEndPolicy.shouldAdvance(
             hasObservedActivePlayback: hasObservedActivePlayback,
             isStopped: status == .stopped,
             isPaused: status == .paused,
             wasPausedByUser: wasPausedByUser,
             isPlaybackInterrupted: isPlaybackInterrupted,
             isNearEnd: nearEnd,
             stalledNearEndSampleCount: nearEndStallSampleCount,
             stallSampleThreshold: Self.playbackEndStallSampleThreshold
         )
         if isAppleMusicPlaying != nowPlaying {
             isAppleMusicPlaying = nowPlaying
         }
         // player 已 stop (用户点停止 / queue 自然播完) 时, 不再从残留 queue 回填
         // nowPlayingSong ── 否则 stopAppleMusic() 清掉的值会被复活, mini player
         // 关不掉。stopped 直接收摊本 tick。
         if endedAfterPlaying {
             plog("⏭️ Apple Music track end detected status=\(String(describing: status)) time=\(playbackTime) furthest=\(furthestObservedPlaybackTime) duration=\(currentDuration) stalledSamples=\(nearEndStallSampleCount)")
             resetPlaybackEndObservation()
             guard isPlaybackRequestActive(requestID),
                   playbackPhase(for: requestID) == .started else { return }
             onPlaybackEnded?(requestID)
             return
         }
         if status == .stopped {
             resetPlaybackEndObservation()
             return
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
                 let rawSongID = AppleMusicLibraryService.toPrimuseSong(s).id
                 if nowPlayingRawSongID != rawSongID {
                     nowPlayingRawSongID = rawSongID
                 }
                 if nowPlayingSong?.id != canonical.id {
                     nowPlayingSong = canonical
                 }
                 currentDuration = canonical.duration ?? s.duration ?? currentDuration
             default:
                 break
             }
         }
         let pt = playbackTime
         // 浮点数微抖动也会触发 @Observable 通知, 0.05s 以内不动 cuts 掉低频闪烁。
         if abs(pt - currentPlaybackTime) > 0.05 {
             currentPlaybackTime = pt
         }
         // queueSongs: 把 entry list 投影成 PrimuseKit.Song, 给 NowPlayingView 的
         // 队列视图直接渲染。先用轻量指纹 (entry.id 列表) 判断 queue 有没有变,
         // 没变就跳过 ── 否则每 0.5s 对几千首 queue 做 SHA256 + 结构体构造, 持续
         // 烧主线程。指纹变化时才做一次全量投影。
         let signature = player.queue.entries.map(\.id)
         if signature != lastQueueSignature {
             lastQueueSignature = signature
             let snapshot = player.queue.entries.compactMap { entry -> MusicKit.Song? in
                 if case .song(let s) = entry.item { return s }
                 return nil
             }
             let libraryService = AppServices.shared.appleMusicLibrary
             let projected = snapshot.map { libraryService.canonicalPrimuseSong(for: $0) }
             if projected.map(\.id) != queueSongs.map(\.id) {
                 queueSongs = projected
             }
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

     /// Audio-session interruptions are not natural track endings. Keep the
     /// near-end watchdog suppressed until MusicKit's clock actually resumes.
     func markPlaybackInterrupted() {
         playbackCommandGeneration &+= 1
         isPlaybackInterrupted = true
         wasPausedByUser = true
         nearEndStallSampleCount = 0
     }

     /// Starts a request generation synchronously, before AudioPlayerService
     /// installs its mirror. Every asynchronous lookup, preflight and playback
     /// result must still match this ID before it can publish state.
     @discardableResult
     func beginPlaybackRequest(id requestID: UUID = UUID()) -> UUID {
         playbackCommandGeneration &+= 1
         catalogPlaybackTask?.cancel()
         catalogPlaybackTask = nil
         playbackStatusObservation?.cancel()
         playbackStatusObservation = nil
         // Publish the new owner before resetting observable fields so a
         // suspended mirror from the previous request rejects those changes.
         playbackRequestState = PlaybackRequestState(id: requestID, phase: .pending)
         ApplicationMusicPlayer.shared.stop()
         resetPlaybackEndObservation()
         nowPlayingSong = nil
         nowPlayingRawSongID = nil
         isAppleMusicPlaying = false
         currentPlaybackTime = 0
         currentDuration = 0
         queueSongs = []
         lastQueueSignature = []
         lastPlaybackError = nil
         return requestID
     }

     func isPlaybackRequestActive(_ requestID: UUID) -> Bool {
         PlaybackRequestGenerationPolicy.shouldApplyResult(
             requestID: requestID,
             activeRequestID: activePlaybackRequestID,
             isCancelled: false
         )
     }

     func isPlaybackStartAuthorized(_ requestID: UUID) -> Bool {
         isPlaybackRequestActive(requestID) && !wasPausedByUser
     }

     private func quiesceStalePlaybackIfNeeded(requestID: UUID) {
         guard isPlaybackRequestActive(requestID),
               wasPausedByUser || isPlaybackInterrupted else { return }
         ApplicationMusicPlayer.shared.pause()
         isAppleMusicPlaying = false
     }

     func isPlaybackRequestPending(_ requestID: UUID) -> Bool {
         isPlaybackRequestActive(requestID)
             && playbackRequestState?.phase == .pending
     }

     func playbackPhase(for requestID: UUID) -> PlaybackPhase? {
         guard playbackRequestState?.id == requestID else { return nil }
         return playbackRequestState?.phase
     }

     func failPlaybackRequest(_ requestID: UUID, message: String) {
         guard isPlaybackRequestPending(requestID) else { return }
         playbackStatusObservation?.cancel()
         playbackStatusObservation = nil
         ApplicationMusicPlayer.shared.stop()
         playbackRequestState = PlaybackRequestState(
             id: requestID,
             phase: .failed(message)
         )
         lastPlaybackError = message
         isAppleMusicPlaying = false
         currentPlaybackTime = 0
     }

     private func markPlaybackStarted(_ requestID: UUID) {
         guard isPlaybackRequestPending(requestID) else { return }
         playbackRequestState = PlaybackRequestState(id: requestID, phase: .started)
         lastPlaybackError = nil
     }

     func cancelPlaybackRequest(_ requestID: UUID) {
         guard isPlaybackRequestActive(requestID) else { return }
         catalogPlaybackTask?.cancel()
         catalogPlaybackTask = nil
         playbackRequestState = nil
         resetPublishedPlaybackState()
     }

     /// Mixed-source queues are advanced by Primuse, not MusicKit. Reset the
     /// system player's modes so its one-item DRM queue ends exactly once;
     /// Primuse's own repeat and shuffle state remains untouched.
     func prepareForPrimuseManagedQueue() {
         ApplicationMusicPlayer.shared.state.repeatMode = MusicKit.MusicPlayer.RepeatMode.none
         ApplicationMusicPlayer.shared.state.shuffleMode = .off
         repeatModeMirror = .off
         shuffleEnabledMirror = false
     }

     private func resetPlaybackEndObservation() {
         hasObservedActivePlayback = false
         wasPausedByUser = false
         isPlaybackInterrupted = false
         lastObservedPlaybackTime = nil
         furthestObservedPlaybackTime = 0
         nearEndStallSampleCount = 0
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
