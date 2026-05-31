import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import PrimuseKit
import SFBAudioEngine
#if os(iOS)
import UIKit
import WidgetKit
#elseif os(macOS)
import AppKit
import WidgetKit
#endif

/// Mutable counter that can be captured by @Sendable closures (e.g. Timer callbacks wrapped in Task).
private final class StepCounter: @unchecked Sendable {
    var value = 0
}

/// Sendable wrapper for AsyncThrowingStream.Iterator to safely transfer across isolation boundaries.
///
/// **Safety contract:** The iterator is accessed sequentially — never concurrently:
/// 1. Created on MainActor in one of the `play*` methods.
/// 2. First buffer awaited on MainActor (still single-threaded).
/// 3. Ownership is then transferred exclusively to a single `decodingTask` via capture.
/// 4. No other code path calls `next()` on the same instance.
///
/// If this invariant changes (e.g. multiple consumers), replace `@unchecked Sendable`
/// with an actor wrapper or protect `iterator` with `os_unfair_lock`.
private final class BufferIteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<AVAudioPCMBuffer, Error>.AsyncIterator

    init(_ iterator: AsyncThrowingStream<AVAudioPCMBuffer, Error>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> AVAudioPCMBuffer? {
        try await iterator.next()
    }
}

/// Sendable carrier for AVAudioPCMBuffer across task boundaries.
/// AVAudioPCMBuffer is a reference type marked non-Sendable by AVFoundation,
/// but we only ever read it after the producing task completes, so the box is
/// safe in practice.
private struct PCMBufferBox: @unchecked Sendable {
    let value: AVAudioPCMBuffer?
}

/// Mutable handoff state for one gapless boundary. The audio scheduling
/// callback and decoder task both touch it, but all mutations are routed
/// back through `AudioPlayerService` on MainActor.
private final class GaplessTransitionState: @unchecked Sendable {
    let queueGeneration: Int
    var prepared: GaplessPreparedTrack?
    var didBoundaryFire = false
    var shouldCancelPreparation = false
    var isFullyScheduled = false
    var didFail = false

    init(queueGeneration: Int) {
        self.queueGeneration = queueGeneration
    }
}

private struct GaplessPreparedTrack: @unchecked Sendable {
    let song: Song
    let url: URL
    let decoderKind: AudioPlayerService.DecoderKind
    let followingTransition: GaplessTransitionState
}

/// One slot in the play queue. Wraps a `Song` with a per-slot UUID so
/// the queue can hold the same song multiple times without ID
/// collisions in SwiftUI ForEach. The id stays put across metadata
/// backfill (`syncSongMetadata` only mutates `song`), so list rows
/// don't lose their identity when the embedded song's tags get
/// rewritten by a later scan.
struct QueueEntry: Sendable, Identifiable {
    let id: UUID
    var song: Song

    init(song: Song, id: UUID = UUID()) {
        self.id = id
        self.song = song
    }
}

@MainActor
@Observable
final class AudioPlayerService {
    let audioEngine: AudioEngine
    let equalizerService: EqualizerService
    let audioEffectsService: AudioEffectsService
    private let sourceManager: SourceManager?
    private let library: MusicLibrary?

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    /// 「歌播完了但 queue 没下一首」的状态 —— Apple Music / Spotify 风格的
    /// "已播完待重播"。currentSong / queue / currentIndex 全保留, 只是
    /// 引擎停了 + currentTime = 0 + isPlaying = false。用户点 play 会从头
    /// 重放当前曲。这个状态存在的意义: 别让 currentSong 变 nil ——
    /// 否则 NowPlayingView / 刮削 sheet / mini player 全是空白屏 (因为
    /// 它们都靠 currentSong 渲染)。
    ///
    /// 触发: handleTrackEnd .off + nextSongInQueue() == nil
    /// 退出: play(song:) / stop() / resume() (resume 会把当前歌重新 play)
    private(set) var isAtTrackEnd = false
    /// `currentTimeAnchor` 在 didSet 里自动同步 wall-clock，配合 `interpolatedTime(at:)`
    /// 在 0.5s 引擎采样间隙内做线性外推，让 60Hz 字级歌词动画无抖。
    private(set) var currentTime: TimeInterval = 0 {
        didSet { currentTimeAnchor = Date() }
    }
    private(set) var duration: TimeInterval = 0
    private(set) var isLoading = false
    private(set) var lastPlaybackError: String?

    private(set) var currentTimeAnchor: Date = Date()

    /// 在 `currentTime` 与下一次 0.5s 采样之间做线性外推，每次 currentTime
    /// 真实更新（didSet 重置 anchor）就跟引擎报告时间校准一次,不会累积漂移。
    func interpolatedTime(at date: Date = Date()) -> TimeInterval {
        guard isPlaying, !isLoading else { return currentTime }
        let elapsed = max(0, date.timeIntervalSince(currentTimeAnchor))
        // 单次外推不超过 1s——异常情况（后台/中断）出现大间隙时不要漂太远
        let safeElapsed = min(elapsed, 1.0)
        let extrapolated = currentTime + safeElapsed
        if duration > 0 { return min(extrapolated, duration) }
        return extrapolated
    }

    /// Stored backing for the queue. Each entry pairs a Song with a
    /// stable UUID — see `QueueEntry`. Mutate via `setQueue`,
    /// `clearQueue`, `moveQueueItems`, or `syncSongMetadata`; do NOT
    /// hand-edit from outside.
    private(set) var queueEntries: [QueueEntry] = []
    /// Backward-compatible read-only view over the queue's songs.
    /// Internal callers and observers keep using `player.queue` —
    /// the @Observable macro tracks reads through `queueEntries`,
    /// so SwiftUI re-renders correctly when entries change.
    var queue: [Song] { queueEntries.map(\.song) }
    var currentIndex: Int = 0
    var shuffleEnabled = false {
        didSet {
            // mirror task 同步 Apple Music shuffle 时跳过 — 不要再写回 AM
            // 触发 polling 抖动。本地播放时正常重建 shuffle order。
            if isMirroringFromAppleMusic { return }
            if isAppleMusicMode {
                AppServices.shared.appleMusic.setAppleMusicShuffle(shuffleEnabled)
                return
            }
            queueGeneration += 1
            rebuildShuffleOrder()
        }
    }
    var repeatMode: RepeatMode = .off {
        didSet {
            if isMirroringFromAppleMusic { return }
            if isAppleMusicMode {
                AppServices.shared.appleMusic.setAppleMusicRepeat(repeatMode)
            }
        }
    }

    /// 当前 currentSong 是不是 Apple Music 来源 ── 一切跨 player 路由 (next /
    /// previous / seek / togglePlayPause / 进度 / queue / repeat / shuffle) 都
    /// 通过这个 flag 走系统侧 ApplicationMusicPlayer, 让 NowPlayingView 一份
    /// 实现两套播放器通吃。
    var isAppleMusicMode: Bool {
        currentSong?.sourceID == AppleMusicLibraryService.systemSourceID
    }

    /// mirror task 写自己字段时设为 true, 让 didSet 跳过"再写回 Apple Music"
    /// 的副作用, 避免 mirror → setRepeat/setShuffle → polling → mirror 的回环。
    private var isMirroringFromAppleMusic = false

    // MARK: - DLNA Casting (推到外部 Renderer)

    /// 当前正在投屏的 RemoteRenderer。nil = 本机播放。
    /// 跟 isAppleMusicMode 一样作为路由开关: togglePlayPause / next / previous /
    /// seek 检测到 isCastingMode 后走 RemoteRendererController 而不是 audioEngine。
    private(set) var castingRenderer: RemoteRenderer?

    /// 跟当前 castingRenderer 对应的 SOAP controller。生命周期跟 castingRenderer 绑定。
    private var castingController: RemoteRendererController?

    /// 1Hz 轮询 GetPositionInfo + GetTransportInfo 同步进度 / 播放状态。
    private var castingPositionTask: Task<Void, Never>?

    var isCastingMode: Bool { castingRenderer != nil }
    private var appleMusicMirrorTask: Task<Void, Never>?

    // MARK: - Shuffle Order
    private var shuffledIndices: [Int] = []
    private var shufflePosition: Int = 0
    /// Pre-computed next round used by repeat-all wrap-around. Generated
    /// when the current round nears its end so `nextSongInQueue` (used
    /// by prefetch) and `advanceToNextIndex` (the actual advance) agree
    /// on what plays next at the boundary. Cleared on any structural
    /// change to `queue` / shuffle state.
    private var pendingNextShuffleIndices: [Int]?
    /// Invalidates prepared gapless transitions when queue order changes.
    private var queueGeneration = 0

    // MARK: - Decoder Tracking (for seek)
    /// Tracks which decoder pipeline produced the currently-playing audio
    /// stream so seek/crossfade/recovery can reproduce the exact same path.
    /// `cloudStream` means SFBAudio decoding from a `CloudPlaybackSource`
    /// `InputSource` (Range-fetch + sparse cache). Seeking that path
    /// requires building a NEW `InputSource` — feeding the
    /// `primuse-stream://` URL to SFB's URL-based opener fails because
    /// the scheme isn't registered with the file system.
    fileprivate enum DecoderKind: Sendable, Equatable { case native, streaming, httpStream, cloudStream, assetReader }
    private var activeDecoderKind: DecoderKind = .native

    // MARK: - Sleep Timer
    private(set) var sleepTimerEndDate: Date?
    private var sleepTimerTask: Task<Void, Never>?
    /// "曲终停止" 模式: 持有当前歌曲的 id, 一旦切到下一首 (或 currentSong
    /// 变 nil) 立即 pause。比固定分钟数更智能 ── 不会在曲子中间硬切。
    private(set) var sleepStopAfterSongID: String?
    var isSleepTimerActive: Bool { sleepTimerEndDate != nil || sleepStopAfterSongID != nil }

    private var displayLink: Timer?
    private let nativeDecoder = NativeAudioDecoder()

    /// 一次性 hint: 搜索页点歌词命中结果时填入, NowPlayingView 加载好歌词后
    /// 用这串文本 fuzzy match 找到对应 LyricLine.timestamp 并 seek。命中后
    /// NowPlayingView 调 `clearPendingLyricsJump()` 清空。
    /// userInfo: (songID, snippet)。songID 防止匹配到错首歌 (用户快速切歌)。
    private(set) var pendingLyricsJump: (songID: String, snippet: String)?

    func requestLyricsJump(songID: String, snippet: String) {
        pendingLyricsJump = (songID, snippet)
    }

    func clearPendingLyricsJump() {
        pendingLyricsJump = nil
    }
    private let assetReaderDecoder = AssetReaderDecoder()
    private let streamingDecoder = StreamingDownloadDecoder()
    private var decodingTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var gaplessPreparationTask: Task<Void, Never>?
    private var gaplessFollowupTask: Task<Void, Never>?
    private var crossfadeDecodingTask: Task<Void, Never>?
    private var crossfadeTimer: Timer?
    private var crossfadeTriggered = false
    /// crossfade 进行中 —— 用来让 startTimeUpdater 跳过 currentTime 更新。
    /// crossfade 期间 audioEngine.currentTime 还是旧曲的 primary node 时间,
    /// 但 UI 已经切到新曲, 这两值对不上, 直接刷会让进度条乱跳。crossfade
    /// 完成 swap 后 isCrossfading 清零, currentTime 跟随新 primary node。
    private var isCrossfading = false
    private var playID: UUID?

    private var errorDismissTask: Task<Void, Never>?
    private var shouldResumeAfterInterruption = false
    private var needsPlaybackRecovery = false
    private var pendingRecoveryTime: TimeInterval = 0

    /// 最近一段时间 gapless boundary 触发的时间戳, 用于侦测 partial-cache
    /// 引起的死循环 (boundary 反复在几秒内连续触发, 队列里 1-2 首坏歌
    /// 互相切来切去)。窗口外的记录会被丢掉。
    private var recentBoundaryTimes: [Date] = []
    private static let boundaryStormWindow: TimeInterval = 10
    private static let boundaryStormThreshold = 4

    /// Seconds of buffered audio we let drain before forcibly advancing
    /// after a mid-stream decode error. Without this cap, the ~100 buffers
    /// already scheduled to the playerNode play out for ~20s before
    /// `autoAdvanceAfterFailure` fires — looks like the player is frozen
    /// (most painfully on CarPlay where the user has no other UI to fall
    /// back to). 3s is enough that the user hears "this song stuttered"
    /// rather than a sudden cut, but short enough to feel responsive.
    private static let midStreamErrorGrace: TimeInterval = 3
    private static let firstBufferTimeoutSeconds = 35
    private static let remoteFallbackFirstBufferTimeoutSeconds = 20
    private static let dlnaSourceID = "dlna"

    let playbackSettings: PlaybackSettingsStore

    init(sourceManager: SourceManager? = nil, library: MusicLibrary? = nil, playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore()) {
        self.sourceManager = sourceManager
        self.library = library
        self.playbackSettings = playbackSettings
        audioEngine = AudioEngine()
        equalizerService = EqualizerService(audioEngine: audioEngine)
        audioEffectsService = AudioEffectsService(audioEngine: audioEngine, settingsStore: playbackSettings)
        applySpatialAudioSettings()
        applyPlaybackRate()
        observeSpatialAudioSettings()
        observePlaybackRate()

        // Defer heavy system registrations to avoid blocking first frame
        Task { @MainActor [weak self] in
            AudioSessionManager.shared.configureForPlayback()
            self?.setupRemoteCommands()
            self?.setupAudioSessionCallbacks()
        }

        // Apple Music 路径 (SearchView 直接点 catalog row) 不走我们的 play(song:),
        // 用 notification 解耦让 player 主动让出 audio session + 清 currentSong,
        // 这样 mini player 才能切到 AppleMusicAccessory。
        NotificationCenter.default.addObserver(
            forName: .primuseAppleMusicWillPlay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.yieldToAppleMusic()
            }
        }
    }

    /// 让出 audio session 给 Apple Music 系统播放器 — 停掉所有内部播放状态。
    ///
    /// 关键: 必须先 bump playID 让正在 in-flight 的 SFB `dataPlayedBack`
    /// completion handler 看到 guard 失败直接 return。否则我们调
    /// `stopPlayback()` 时, SFB lastBuffer 被认为 "完整播放完" → 触发
    /// `handleTrackEnd()` → 自动跳到队列下一首本地歌 → mini player 又切
    /// 回本地, 用户体感是"Apple Music 一闪而过又变回本地播放"。
    ///
    /// **不再清空 currentSong** ── mirror task 会从 appleMusic.nowPlayingSong
    /// 翻译过来设上, 让 NowPlayingView 复用同一份实现; 仅本地引擎和 time
    /// updater 停掉。
    private func yieldToAppleMusic() {
        // 关键 — 先 bump playID, 让旧 callback 的 guard playID == id 全 fail。
        playID = UUID()
        decodingTask?.cancel(); decodingTask = nil
        cancelGaplessTasks()
        crossfadeDecodingTask?.cancel(); crossfadeDecodingTask = nil
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        stopTimeUpdater()
        currentTime = 0
        duration = 0
        isLoading = true
        isPlaying = false
        startAppleMusicMirror()
        plog("⏸ yielded audio session to Apple Music (playID bumped)")
    }

    func applySpatialAudioSettings() {
        let settings = playbackSettings.snapshot()
        audioEngine.configureSpatialAudio(
            enabled: settings.spatialAudioEnabled,
            headTrackingEnabled: settings.spatialHeadTrackingEnabled
        )
    }

    /// 同步当前 playbackRate 到 engine. 设置变化或新歌开播都会调它。
    func applyPlaybackRate() {
        audioEngine.applyPlaybackRate(playbackSettings.playbackRate)
    }

    /// 如果用户启用了「输出采样率匹配」, 把 AVAudioSession 硬件 SR hint 切到
    /// 当前歌的采样率, 避免 CoreAudio 自动重采样。仅 iOS 真机生效。
    func applyOutputSampleRateMatching(for song: Song) {
        guard playbackSettings.matchOutputSampleRate,
              let sr = song.sampleRate, sr > 0 else { return }
        #if os(iOS)
        AudioSessionManager.shared.setPreferredSampleRate(Double(sr))
        #endif
    }

    private func observeSpatialAudioSettings() {
        withObservationTracking {
            _ = playbackSettings.spatialAudioEnabled
            _ = playbackSettings.spatialHeadTrackingEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySpatialAudioSettings()
                self.observeSpatialAudioSettings()
            }
        }
    }

    /// 单独跟踪 playbackRate, 别和 spatial observer 合并 — 不然改速度时会
    /// 顺带触发 spatial node 的 sourceMode / renderingAlgorithm 重设, 在
    /// engine 运行中可能导致音频 glitch / player 卡顿。
    private func observePlaybackRate() {
        withObservationTracking {
            _ = playbackSettings.playbackRate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPlaybackRate()
                self.observePlaybackRate()
            }
        }
    }

    private func setupAudioSessionCallbacks() {
        let manager = AudioSessionManager.shared

        manager.onInterruptionBegan = { [weak self] in
            guard let self, self.currentSong != nil else { return }
            let wasPlaying = self.isPlaying
            self.syncPlaybackProgressFromEngine()
            self.pendingRecoveryTime = self.currentTime
            self.needsPlaybackRecovery = wasPlaying
            self.shouldResumeAfterInterruption = wasPlaying

            guard wasPlaying else { return }
            // Sync UI to paused state — the engine was already stopped by the system.
            self.isPlaying = false
            self.stopTimeUpdater()
            self.updateNowPlayingInfo()
            self.updatePlaybackState()
        }

        manager.onInterruptionEndedShouldResume = { [weak self] in
            guard let self, !self.isPlaying, self.currentSong != nil else { return }
            self.resume()
        }

        manager.onConfigurationChange = { [weak self] in
            guard let self, self.currentSong != nil else { return }
            let shouldAutoResume = self.isPlaying || self.shouldResumeAfterInterruption
            self.syncPlaybackProgressFromEngine()
            self.pendingRecoveryTime = self.currentTime
            self.needsPlaybackRecovery = self.needsPlaybackRecovery || shouldAutoResume

            guard shouldAutoResume else { return }
            // Engine was stopped due to config change — restart it if possible, and
            // rebuild the player pipeline on the next resume/play if buffers were lost.
            self.audioEngine.restartIfNeeded()
        }
    }

    private func clearPendingPlaybackRecovery() {
        shouldResumeAfterInterruption = false
        needsPlaybackRecovery = false
        pendingRecoveryTime = 0
    }

    private func syncPlaybackProgressFromEngine() {
        guard let engineTime = audioEngine.currentTime, engineTime.isFinite else { return }
        currentTime = max(0, engineTime)
    }

    private func showPlaybackError(_ message: String) {
        lastPlaybackError = message
        errorDismissTask?.cancel()
        errorDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self.lastPlaybackError = nil
        }
    }

    private func awaitFirstBuffer(
        from iteratorBox: BufferIteratorBox,
        timeoutSeconds: Int
    ) async throws -> AVAudioPCMBuffer? {
        let box: PCMBufferBox = try await withThrowingTaskGroup(of: PCMBufferBox.self) { group in
            group.addTask {
                let buffer = try await iteratorBox.next()
                return PCMBufferBox(value: buffer)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return PCMBufferBox(value: nil)
                }
                throw CancellationError()
            }
            let first = try await group.next() ?? PCMBufferBox(value: nil)
            group.cancelAll()
            return first
        }
        return box.value
    }

    private func isNetworkTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNetworkTimeout(underlying)
        }
        return false
    }

    // MARK: - Playback Control

    func play(song: Song, caller: String = #fileID, callerLine: Int = #line) async {
        // Invalidate any pending operations immediately
        let id = UUID()
        playID = id
        clearPendingPlaybackRecovery()
        let callerFile = (caller as NSString).lastPathComponent
        plog("▶️ play(song: \(song.title)) playID=\(id.uuidString.prefix(8)) FROM=\(callerFile):\(callerLine)")

        // Apple Music 歌走系统侧 ApplicationMusicPlayer (DRM 流不能经
        // AVAudioEngine 解), 跨 player 切换 — 先停我们自己的播放器再让
        // AppleMusicService 接手, audio session 系统自动 hand-off。
        if song.sourceID == AppleMusicLibraryService.systemSourceID {
            await playAppleMusicSong(song)
            return
        }

        // Cast 模式 ── 走 RemoteRendererController 推到远端 renderer, 不动
        // 本地 audioEngine。next/previous 走到这里时同样路由。
        if castingController != nil {
            await castSong(song)
            return
        }

        // 上一首是 Apple Music → 切到本地: 先停 mirror task 并让系统侧停掉,
        // 避免 mirror 继续把 currentSong 改回 Apple Music 那首。
        if isAppleMusicMode {
            stopAppleMusicMirror()
            AppServices.shared.appleMusic.stopAppleMusic()
        }

        // 切到新歌前主动触发上一首的 streaming session finalize, 让它有机会
        // 把 .partial 转成 final (如果缺口在 50MB 自动补齐阈值内)。
        if let prev = currentSong, prev.id != song.id {
            sourceManager?.finalizeStreamingSession(for: prev)
        }

        // Stop current playback
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        stopTimeUpdater()

        // Show new song in UI immediately (before download)
        currentSong = song
        currentTime = 0
        duration = song.duration.sanitizedDuration
        isLoading = true
        isPlaying = false
        isAtTrackEnd = false
        plog("▶️ currentSong set to: \(song.title)")

        do {
            let url = try await resolvedURL(for: song)
            // Check if another play was initiated while downloading
            guard playID == id else { return }
            await playFromURL(song: song, url: url, playID: id)
        } catch {
            guard playID == id else { return }
            plog("Playback URL resolution error: \(error)")
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            await autoAdvanceAfterFailure()
        }
    }

    /// Apple Music 歌路由 — 把猿音自家播放器停掉, 让 AppleMusicLibraryService
    /// 通过 ApplicationMusicPlayer 接手 DRM 流播放。currentSong **保留**为这首
    /// Apple Music 歌, 让 NowPlayingView / MiniPlayer 复用同一份实现; mirror
    /// task 会持续把 ApplicationMusicPlayer 的状态同步到 self 的字段。
    private func playAppleMusicSong(_ song: Song) async {
        // 停猿音自家 engine, audio session 让给 ApplicationMusicPlayer。
        decodingTask?.cancel(); decodingTask = nil
        cancelGaplessTasks()
        crossfadeDecodingTask?.cancel(); crossfadeDecodingTask = nil
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        stopTimeUpdater()
        currentSong = song
        currentTime = 0
        duration = song.duration
        isLoading = true
        isPlaying = false
        startAppleMusicMirror()
        let appleMusicLibrary = AppServices.shared.appleMusicLibrary

        // 4s 兜底必须先注册。Apple Music user-library sync 在缺 entitlement
        // 或系统账户服务异常时可能卡住；如果把 timeout 放在 await 之后,
        // UI 会永远停在 isLoading=true。
        Task { @MainActor [weak self, songID = song.id] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  self.currentSong?.id == songID,
                  self.isLoading else { return }
            appleMusicLibrary.cancel()
            self.isLoading = false
            let am = AppServices.shared.appleMusic
            if !am.isAppleMusicPlaying, am.currentPlaybackTime == 0 {
                self.lastPlaybackError = am.lastPlaybackError
                    ?? String(localized: "playback_error_apple_music_generic")
            }
        }

        // 不阻塞 play(song:) 调用方。成功后 AppleMusicService 的 mirror 会把
        // nowPlaying / progress 同步回来；失败或卡住由上面的 timeout 收口。
        Task {
            await appleMusicLibrary.play(primuseSong: song)
        }
    }

    /// 启动 Apple Music 状态镜像 ── observation tracking 监听 appleMusic 的
     /// nowPlayingSong / isAppleMusicPlaying / currentPlaybackTime 等字段,
     /// 每次变化把值 mirror 到 self 的 currentSong / isPlaying / currentTime 等。
     /// 切回本地播放或 stop 时取消。
     private func startAppleMusicMirror() {
         appleMusicMirrorTask?.cancel()
         let am = AppServices.shared.appleMusic
         appleMusicMirrorTask = Task { @MainActor [weak self] in
             while !Task.isCancelled {
                 await self?.awaitNextAppleMusicChange(am: am)
                 self?.mirrorAppleMusicState()
             }
         }
         // 首次进 Apple Music 模式时主动 mirror 一次, 不用等下一个 polling tick。
         mirrorAppleMusicState()
     }

     /// 注意必须 @MainActor 隔离 ── withObservationTracking 的 read 阶段
     /// 要跟它访问的 Observable 在同一 actor (这里是 appleMusic 即 @MainActor)。
     /// 之前写成 nonisolated + MainActor.assumeIsolated 在 Task 任意线程上
     /// 触发了 precondition trap → 启动 Apple Music 播放秒闪退 (见 PR / 日志)。
     private func awaitNextAppleMusicChange(am: AppleMusicService) async {
         await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
             withObservationTracking {
                 _ = am.nowPlayingSong?.id
                 _ = am.isAppleMusicPlaying
                 _ = am.currentPlaybackTime
                 _ = am.currentDuration
                 _ = am.queueSongs.count
                 _ = am.repeatModeMirror
                 _ = am.shuffleEnabledMirror
             } onChange: {
                 cont.resume()
             }
         }
     }

     private func stopAppleMusicMirror() {
         appleMusicMirrorTask?.cancel()
         appleMusicMirrorTask = nil
     }

     private func mirrorAppleMusicState() {
         // 用 appleMusic.nowPlayingSong 而不是 self.isAppleMusicMode 做 guard ──
         // 初次从 catalog 路径切到 Apple Music 时 currentSong 可能还是旧的本地
         // 歌, 等 mirror 第一次写入新值之后 isAppleMusicMode 才变 true。
         let am = AppServices.shared.appleMusic
         guard let nps = am.nowPlayingSong else { return }
         isMirroringFromAppleMusic = true
         defer { isMirroringFromAppleMusic = false }

         // currentSong: 自动跳下一首时 nowPlayingSong 会变, 同步过来。
         let pSong = AppleMusicLibraryService.toPrimuseSong(nps)
         if pSong.id != currentSong?.id {
             currentSong = pSong
         }
         isPlaying = am.isAppleMusicPlaying
         // 首次播 (isLoading=true) 收到 playing 状态才清 isLoading,
         // 避免 polling 命中前 UI 一直显示 spinner。
         if am.isAppleMusicPlaying || am.currentPlaybackTime > 0 {
             isLoading = false
         }
         currentTime = am.currentPlaybackTime
         if am.currentDuration > 0 { duration = am.currentDuration }
         // queue 镜像 ── 转成 QueueEntry, 让 NowPlayingView 队列视图直接渲染。
         let newIDs = am.queueSongs.map(\.id)
         if newIDs != queueEntries.map(\.song.id) {
             queueEntries = am.queueSongs.map { QueueEntry(song: $0) }
         }
         if repeatMode != am.repeatModeMirror { repeatMode = am.repeatModeMirror }
         if shuffleEnabled != am.shuffleEnabledMirror { shuffleEnabled = am.shuffleEnabledMirror }
     }

    func play(song: Song, from url: URL) async {
        let id = UUID()
        playID = id
        clearPendingPlaybackRecovery()
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        audioEngine.stopPlayback()
        stopTimeUpdater()
        await playFromURL(song: song, url: url, playID: id)
    }

    private func playFromURL(song: Song, url: URL, playID id: UUID) async {
        plog("▶️ playFromURL(song: \(song.title)) playID=\(id.uuidString.prefix(8))")
        plog("▶️   URL: \(url.absoluteString.prefix(120))")
        plog("▶️   scheme=\(url.scheme ?? "nil") isFileURL=\(url.isFileURL) ext=\(url.pathExtension) format=\(song.fileFormat) duration=\(song.duration)")
        currentSong = song
        duration = song.duration.sanitizedDuration
        isLoading = true
        isPlaying = false
        audioEngine.sampleTimeOffset = 0
        crossfadeTriggered = false; isCrossfading = false
        activeDecoderKind = .native
        applyOutputSampleRateMatching(for: song)
        applyPlaybackRate()

        let isRemoteURL = url.scheme == "http" || url.scheme == "https"
        let isCloudStream = url.scheme == SourceManager.cloudStreamingScheme

        guard isRemoteURL || isCloudStream || nativeDecoder.canDecode(url: url) else {
            plog("Unsupported format: \(url.pathExtension)")
            isLoading = false
            await autoAdvanceAfterFailure()
            return
        }

        do {
            _ = AudioSessionManager.shared.activatePlaybackSession()
            try audioEngine.setUp()
            applySpatialAudioSettings()
            audioEffectsService.applySettings()
            guard let outputFormat = audioEngine.outputFormat else {
                throw AudioDecoderError.decodingFailed("Audio engine not ready")
            }

            try audioEngine.start()

            // Reset volume immediately; apply ReplayGain asynchronously after playback starts
            audioEngine.resetPlayerVolume()

            // Cloud streaming: instead of downloading the whole file, build
            // an SFBInputSource whose reads go through HTTP Range +
            // sparse-on-disk cache. SFBAudioEngine reads from it like any
            // file and we get instant playback.
            let stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>
            if isRemoteURL {
                if let inputSource = await makeHTTPStreamingInputSource(for: song, url: url) {
                    plog("▶️ Decoder: HTTPRangePlaybackSource (reason: scheme=\(url.scheme ?? "?"), range-based HTTP streaming) cache=\(playbackSettings.audioCacheEnabled) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    activeDecoderKind = .httpStream
                    stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: makeResolveLengthCallback(for: song))
                } else if isDLNACast(song), assetReaderDecoder.canDecode(url: url) {
                    // DLNA control points often push CGI/progressive URLs
                    // with no Content-Length. Full-download fallback waits
                    // for EOF before decoding, which leaves the sender stuck
                    // on loading. Let AVFoundation open the remote asset
                    // progressively before trying the legacy full download.
                    plog("▶️ Decoder: AVAssetReader (reason: DLNA URL has no range/fileSize, progressive remote fallback) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                    return
                } else {
                    // Fallback for legacy rows / arbitrary URLs where fileSize is
                    // unknown. This preserves compatibility but still logs clearly
                    // that startup waits for a full download.
                    plog("▶️ Decoder: StreamingDownloadDecoder (reason: HTTP range unavailable or fileSize unknown, full-download fallback) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                    await playWithStreamingDownload(song: song, url: url, outputFormat: outputFormat, playID: id, cacheURL: cacheURL)
                    return
                }
            } else if isCloudStream, let manager = sourceManager,
               let inputSource = try? await manager.makeStreamingInputSource(
                   for: song,
                   cacheEnabled: playbackSettings.audioCacheEnabled
               ) {
                // 解码器选型: 自定义 cloudStreamingScheme (primuse-stream://)
                // 走 CloudPlaybackSource。它包装一层 SFBInputSource, SFB read
                // 时按需走 HTTP Range fetch, 配合 sparse cache 实现"边下边播"。
                // 适合云盘 (Baidu / Aliyun / OneDrive / Dropbox) 的 dlink
                // 流式播放 ── 这些场景下不能像 NAS 那样直接给 SFBAudioEngine
                // 一个稳定的 HTTPS URL。
                plog("▶️ Decoder: CloudPlaybackSource (reason: scheme=primuse-stream, range-based streaming) cache=\(playbackSettings.audioCacheEnabled) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                activeDecoderKind = .cloudStream
                stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: makeResolveLengthCallback(for: song))
            } else {
                // Local file path (or fallback when streaming setup failed)
                let reason = isCloudStream
                    ? "primuse-stream URL but inputSource setup failed, fallback to file path"
                    : "local file path (file:// scheme)"
                plog("▶️ Decoder: NativeDecoder (reason: \(reason)) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                stream = nativeDecoder.decode(from: url, outputFormat: outputFormat, onResolveSourceLength: makeResolveLengthCallback(for: song))
            }
            let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

            // Await first buffer — ensures we have audio data before calling play()
            // Wrapped in a 35s timeout race so a hung cloud fetch (revoked
            // dlink that never errors out, account-banned network stall)
            // doesn't leave the play button spinning forever. The
            // CloudPlaybackSource serve has its own 30s per-chunk timeout
            // — this one is the outer safety net.
            let firstBuffer: AVAudioPCMBuffer
            do {
                guard let buffer = try await awaitFirstBuffer(
                    from: iteratorBox,
                    timeoutSeconds: Self.firstBufferTimeoutSeconds
                ) else {
                    // Empty stream — skip to next
                    guard playID == id else { return }
                    isLoading = false
                    await autoAdvanceAfterFailure()
                    return
                }
                guard playID == id else { return }
                firstBuffer = buffer
            } catch is CancellationError {
                guard !Task.isCancelled, playID == id else { return }
                plog("⚠️ '\(song.title)' first-buffer timeout (35s) — likely cloud fetch stalled")
                showPlaybackError(String(localized: "playback_error_connection"))
                isLoading = false
                await autoAdvanceAfterFailure()
                return
            } catch {
                // Native decode failed on first buffer — try fallback decoder.
                // Cloud-stream URLs can't be opened by the FFmpeg fallback,
                // so let the caller surface the error instead.
                guard !Task.isCancelled, playID == id else { return }
                plog("⚠️ Native decode failed for '\(song.title)': \(error.localizedDescription)")
                if activeDecoderKind == .httpStream {
                    if isDLNACast(song), assetReaderDecoder.canDecode(url: url) {
                        plog("↳ HTTP range decode failed before first buffer; trying DLNA progressive AssetReader fallback")
                        await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                    } else {
                        plog("↳ HTTP range decode failed before first buffer; falling back to full download")
                        let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                        await playWithStreamingDownload(song: song, url: url, outputFormat: outputFormat, playID: id, cacheURL: cacheURL)
                    }
                } else if !isCloudStream {
                    await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                } else {
                    isLoading = false
                }
                return
            }

            // Schedule first buffer BEFORE play — playerNode has data ready
            plog("▶️ NativeDecoder firstBuffer: frames=\(firstBuffer.frameLength) format=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount)")
            plog("▶️ Engine state: outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount) mainVol=\(audioEngine.volume)")
            plog("▶️ Engine diagnostics: \(audioEngine.diagnosticInfo())")
            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()
            plog("▶️ After play(): \(audioEngine.diagnosticInfo())")

            // Fetch duration asynchronously if not already known.
            // Skip for cloud-stream URLs — fileInfo opens via SFBAudioEngine
            // by URL, which doesn't understand the custom scheme. Duration
            // for cloud songs is filled in by MetadataBackfillService.
            if duration <= 0, !isCloudStream, activeDecoderKind != .httpStream {
                Task {
                    if let info = try? await nativeDecoder.fileInfo(for: url) {
                        guard self.playID == id else { return }
                        self.duration = info.duration.sanitizedDuration
                        self.updateNowPlayingInfo()
                    }
                }
            }

            // NOW transition state — audio is actually playing
            isPlaying = true
            isLoading = false
            clearPendingPlaybackRecovery()
            library?.recordPlayback(of: song.id)
            ScrobbleService.shared.handlePlaybackStarted(song: song); PlayHistoryStore.shared.beginSession(song: song)
            startTimeUpdater()
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Apply ReplayGain in background (don't block playback start).
            // Streaming URLs use persisted library tags; local files may
            // fall back to reading embedded tags from disk.
            let settings = playbackSettings.snapshot()
            if settings.replayGainEnabled {
                let decoderKind = activeDecoderKind
                Task { [id] in
                    await self.applyReplayGain(
                        for: song,
                        url: url,
                        mode: settings.replayGainMode,
                        allowFileRead: decoderKind != .cloudStream && decoderKind != .httpStream
                    )
                    guard self.playID == id else { return }
                }
            }

            // Background-cache file for offline playback (if enabled).
            // Cloud streaming already writes to the same cache file as
            // it goes — duplicating via cacheInBackground would just
            // race two writers on the same path.
            if playbackSettings.audioCacheEnabled, !isCloudStream, activeDecoderKind != .httpStream, !isDLNACast(song) {
                sourceManager?.cacheInBackground(song: song, cacheEnabled: playbackSettings.audioCacheEnabled)
            }

            // Prefetch next song
            prefetchNextSong()

            // Decode remaining buffers in background task (hold-last for completion callback)
            decodingTask = Task { [id, iteratorBox] in
                var lastBuffer: AVAudioPCMBuffer?
                var scheduledCount = 0
                var midStreamError = false

                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }

                        if let prev = lastBuffer {
                            self.audioEngine.scheduleBuffer(prev)
                            scheduledCount += 1
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    guard !Task.isCancelled, self.playID == id else { return }
                    midStreamError = true
                    plog("⚠️ Decode error mid-stream for '\(song.title)' (scheduled \(scheduledCount) buffers): \(error.localizedDescription)")
                    self.showPlaybackError(String(localized: "playback_error_decode"))
                    if scheduledCount < 3 {
                        // Too little decoded to be worth playing — bail now.
                        // Helper handles repeat-one (stop, don't loop broken
                        // file), shuffle correctness, and stop-when-no-next.
                        await self.autoAdvanceAfterFailure()
                        return
                    }
                }

                guard !Task.isCancelled, self.playID == id else { return }
                if midStreamError {
                    // Cap the post-error grace period at `midStreamErrorGrace`.
                    // Without the cap, ~100 already-scheduled buffers would
                    // play out for ~20s before `autoAdvanceAfterFailure`
                    // fires (via the lastBuffer's `dataPlayedBack`
                    // completion). On CarPlay that looked like the player
                    // was frozen — no progress, no skip, until the buffer
                    // queue finally drained. Spawn a short timer Task that
                    // hard-cuts the audio engine and advances; whichever
                    // event happens first wins.
                    Task { @MainActor [id] in
                        try? await Task.sleep(for: .seconds(Self.midStreamErrorGrace))
                        guard self.playID == id else { return }
                        plog("🛑 mid-stream grace elapsed; stopping engine and advancing")
                        self.audioEngine.stopPlayback()
                        await self.autoAdvanceAfterFailure()
                    }
                } else if let finalBuffer = lastBuffer {
                    // Natural EOF — schedule with track-end completion.
                    await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ Playback error for '\(song.title)': \(error.localizedDescription)")
            showPlaybackError(String(localized: "playback_error_decode"))
            isLoading = false
            // Auto-skip on decode failure (or stop under repeat-one
            // instead of looping a broken file).
            await autoAdvanceAfterFailure()
        }
    }

    /// Full-download fallback for remote URLs whose length is unknown or
    /// whose server rejects Range reads. Handles self-signed HTTPS
    /// certificates that AVAssetReader cannot.
    private func playWithStreamingDownload(
        song: Song, url: URL, outputFormat: AVAudioFormat,
        playID id: UUID, cacheURL: URL?
    ) async {
        let stream = streamingDecoder.decode(from: url, outputFormat: outputFormat, cacheFileURL: cacheURL, fileExtension: song.fileFormat.rawValue)
        let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: Self.remoteFallbackFirstBufferTimeoutSeconds
            ) else {
                guard playID == id else { return }
                plog("⚠️ StreamingDownload: empty stream for '\(song.title)'")
                isLoading = false
                await autoAdvanceAfterFailure()
                return
            }
            guard playID == id else { return }

            plog("🌊 StreamingDownload firstBuffer: frames=\(firstBuffer.frameLength) sr=\(firstBuffer.format.sampleRate)")
            plog("🌊 Engine diagnostics before play: \(audioEngine.diagnosticInfo())")
            activeDecoderKind = .streaming
            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()
            plog("🌊 Engine diagnostics after play: \(audioEngine.diagnosticInfo())")

            // Fetch duration asynchronously if needed。SFBAudioDecoder 只支持
            // file:// URL,远程 HTTP/HTTPS URL 走到这条路径会抛 NSException
            // (NSAssertionHandler) 整 app SIGABRT,`try?` 接不住 ObjC 异常。
            // 远程流的 duration 由 streamingDownloadDecoder 自己解出来,这里跳过。
            if duration <= 0 && url.isFileURL {
                Task {
                    if let info = try? await self.nativeDecoder.fileInfo(for: url) {
                        guard self.playID == id else { return }
                        self.duration = info.duration.sanitizedDuration
                        self.updateNowPlayingInfo()
                    }
                }
            }

            // Transition state — audio is playing
            isPlaying = true
            isLoading = false
            clearPendingPlaybackRecovery()
            library?.recordPlayback(of: song.id)
            ScrobbleService.shared.handlePlaybackStarted(song: song); PlayHistoryStore.shared.beginSession(song: song)
            startTimeUpdater()
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Prefetch next song while current one plays
            prefetchNextSong()

            // Decode remaining buffers
            decodingTask = Task { [id, iteratorBox] in
                var lastBuffer: AVAudioPCMBuffer?
                var scheduledCount = 0
                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }
                        if let prev = lastBuffer {
                            self.audioEngine.scheduleBuffer(prev)
                            scheduledCount += 1
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled, self.playID == id {
                        plog("⚠️ StreamingDownload decode error (scheduled \(scheduledCount) buffers): \(error.localizedDescription)")
                        if scheduledCount < 3 {
                            self.showPlaybackError(String(localized: "playback_error_decode"))
                            // Helper handles stop()/next()/repeat-one
                            // semantics — don't pre-stop here, otherwise
                            // we'd race the next()-→play() restart.
                            await self.autoAdvanceAfterFailure()
                            return
                        }
                    }
                }
                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == id else { return }
                    await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                }
            }
        } catch is CancellationError {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ StreamingDownload first-buffer timeout for '\(song.title)' after \(Self.remoteFallbackFirstBufferTimeoutSeconds)s")
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            await autoAdvanceAfterFailure()
        } catch {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ StreamingDownload failed for '\(song.title)': \(error.localizedDescription)")
            if isNetworkTimeout(error) {
                showPlaybackError(String(localized: "playback_error_connection"))
                isLoading = false
                await autoAdvanceAfterFailure()
                return
            }
            // Fallback to AssetReader decoder (for non-SSL failures)
            plog("↳ Trying AssetReader fallback...")
            await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
        }
    }

    /// Prefetch the next song in the queue to local cache for instant playback.
    /// Decode any URL produced by `resolvedURL`, transparently handling
    /// the `primuse-stream://` custom scheme by building a fresh
    /// `CloudPlaybackSource` InputSource. Crossfade/gapless/seek paths all
    /// go through here so they stay correct when the source is a cloud
    /// streaming song.
    /// Build the duration-rewrite callback for a song. Every decode
    /// path (fresh play, crossfade prefetch, seek) routes through this
    /// so the first time SFB sees the full stream we capture the real
    /// PCM frame count and rewrite the library — backfill's
    /// 256KB-head estimate (especially for raw MP3) is replaced by
    /// the authoritative value, and the row's displayed time is
    /// correct from then on.
    private func makeResolveLengthCallback(for song: Song) -> @Sendable (TimeInterval) -> Void {
        let songID = song.id
        let songTitle = song.title
        let storedDuration = song.duration
        let fileSize = song.fileSize
        let bitRate = song.bitRate
        let fileFormat = song.fileFormat
        return { [weak self] resolved in
            guard resolved > 0 else { return }
            if Self.isLikelyTruncatedCloudDuration(
                resolved: resolved,
                stored: storedDuration,
                fileSize: fileSize,
                bitRateKbps: bitRate,
                format: fileFormat
            ) {
                plog(String(format: "⚠️ Ignoring implausible SFB duration for '%@': %.1fs (stored %.1fs, size=%lldKB) — likely partial cloud read",
                            songTitle, resolved, storedDuration, fileSize / 1024))
                return
            }
            // Skip rewrite when the parser/backfill already had it
            // right (within 5%) — avoids library churn + UI thrash
            // for songs with a clean LAME header or m4a `mvhd`.
            let needsRewrite = storedDuration <= 0
                || abs(storedDuration - resolved) / max(resolved, 1) > 0.05
            guard needsRewrite else { return }
            Task { @MainActor [weak self] in
                guard let self, let library = self.library else { return }
                guard var existing = library.songs.first(where: { $0.id == songID }) else { return }
                existing.duration = resolved
                library.replaceSong(existing)
                plog(String(format: "🎵 SFB resolved real duration for '%@': %.1fs (was %.1fs) — rewrote library", songTitle, resolved, storedDuration))
            }
        }
    }

    nonisolated private static func isLikelyTruncatedCloudDuration(
        resolved: TimeInterval,
        stored: TimeInterval,
        fileSize: Int64,
        bitRateKbps: Int?,
        format: AudioFormat
    ) -> Bool {
        if stored > 30, resolved < stored * 0.5 {
            return true
        }

        guard format == .mp3, fileSize > 512 * 1024 else {
            return false
        }
        let effectiveBitRate = max(bitRateKbps ?? 0, 192)
        let estimatedFromFileSize = Double(fileSize) / (Double(effectiveBitRate) * 125.0)
        return estimatedFromFileSize > 30 && resolved < estimatedFromFileSize * 0.5
    }

    private func decodeStream(
        for song: Song,
        url: URL,
        outputFormat: AVAudioFormat
    ) async -> AsyncThrowingStream<AVAudioPCMBuffer, Error>? {
        let onResolveLength = makeResolveLengthCallback(for: song)

        if url.scheme == SourceManager.cloudStreamingScheme {
            // Prefer fully-cached file if available (skips streaming overhead).
            if let cached = sourceManager?.cachedURL(for: song) {
                return nativeDecoder.decode(from: cached, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
            }
            guard let manager = sourceManager,
                  let inputSource = try? await manager.makeStreamingInputSource(
                      for: song,
                      cacheEnabled: playbackSettings.audioCacheEnabled
                  ) else {
                return nil
            }
            return nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
        }
        if url.scheme == "http" || url.scheme == "https" {
            if let cached = sourceManager?.cachedURL(for: song) {
                return nativeDecoder.decode(from: cached, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
            }
            if let inputSource = await makeHTTPStreamingInputSource(for: song, url: url) {
                return nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
            }
            return streamingDecoder.decode(from: url, outputFormat: outputFormat, cacheFileURL: nil, fileExtension: song.fileFormat.rawValue)
        }
        return nativeDecoder.decode(from: url, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
    }

    private func makeHTTPStreamingInputSource(for song: Song, url: URL) async -> InputSource? {
        guard song.fileSize > 0,
              url.scheme == "http" || url.scheme == "https" else { return nil }

        let cacheEnabled = playbackSettings.audioCacheEnabled
        let cacheURL: URL
        let cacheRelativePath: String?
        if cacheEnabled, let sourceManager {
            cacheURL = sourceManager.cacheURL(for: song)
            let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
            cacheRelativePath = "\(song.sourceID)/\(sanitized)"
            await AudioCacheManager.shared.evictIfNeeded(reserveBytes: song.fileSize)
        } else {
            cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("primuse-http-\(song.id)")
            cacheRelativePath = nil
        }

        return CloudPlaybackSource.makeHTTPInputSource(
            song: song,
            url: url,
            totalLength: song.fileSize,
            cacheURL: cacheURL,
            persistOnComplete: cacheEnabled && sourceManager != nil,
            cacheRelativePath: cacheRelativePath
        )
    }

    private func decoderKind(for song: Song, url: URL) -> DecoderKind {
        if url.scheme == SourceManager.cloudStreamingScheme { return .cloudStream }
        if url.scheme == "http" || url.scheme == "https" {
            return song.fileSize > 0 ? .httpStream : .streaming
        }
        return .native
    }

    private func prefetchNextSong() {
        prefetchTask?.cancel()
        // Prefetch 接下来几首,而不是只 1 首 —— 用户连续 next 切歌时
        // (4-5s/次), 单首 prefetch chain 来不及, 第 2、3 首切到时 partial
        // 还是空, SFB 现拉 1MB chunk 卡 2-3s。数量由 ST-01 设置页控制。
        let nextSongs = nextSongsInQueue(count: playbackSettings.prewarmQueueCount)
        guard !nextSongs.isEmpty else { return }

        prefetchTask = Task {
            for song in nextSongs {
                if Task.isCancelled { return }
                if song.id == currentSong?.id { continue }
                if sourceManager?.cachedURL(for: song) != nil { continue }
                plog("⏩ Prefetching next song: \(song.title)")
                sourceManager?.cacheInBackground(song: song, cacheEnabled: playbackSettings.audioCacheEnabled)
            }
        }
    }

    /// 返回 queue 接下来 N 首 (考虑 shuffle / repeat all)。N 首之间不重复。
    /// 用于 prefetch chain — 让用户连续 next 时也能命中 prewarm。
    private func nextSongsInQueue(count: Int) -> [Song] {
        guard !queue.isEmpty, count > 0 else { return [] }
        if repeatMode == .one { return [] }

        var result: [Song] = []
        var seenIDs = Set<String>()
        if let cur = currentSong { seenIDs.insert(cur.id) }

        if shuffleEnabled {
            var localPending: [Int]? = nil
            for offset in 1...count {
                let pos = shufflePosition + offset
                let song: Song?
                if pos < shuffledIndices.count {
                    song = queue[shuffledIndices[pos]]
                } else if repeatMode == .all {
                    let pending = localPending ?? pendingNextShuffleIndices ?? buildPendingNextRound()
                    if pendingNextShuffleIndices == nil { pendingNextShuffleIndices = pending }
                    localPending = pending
                    let pos2 = pos - shuffledIndices.count
                    song = pos2 < pending.count ? queue[pending[pos2]] : nil
                } else {
                    song = nil
                }
                if let s = song, !seenIDs.contains(s.id) {
                    result.append(s)
                    seenIDs.insert(s.id)
                }
            }
        } else {
            for offset in 1...count {
                let raw = currentIndex + offset
                let idx: Int?
                if raw < queue.count {
                    idx = raw
                } else if repeatMode == .all {
                    idx = raw % queue.count
                } else {
                    idx = nil
                }
                if let i = idx, !seenIDs.contains(queue[i].id) {
                    result.append(queue[i])
                    seenIDs.insert(queue[i].id)
                }
            }
        }
        return result
    }

    /// Fallback playback using AVAssetReader when native decoder fails.
    private func playWithFallbackDecoder(song: Song, url: URL, outputFormat: AVAudioFormat, playID id: UUID) async {
        guard playID == id else { return }
        guard assetReaderDecoder.canDecode(url: url) else {
            plog("⚠️ No decoder available for '\(song.title)'")
            showPlaybackError(String(localized: "playback_error_format"))
            isLoading = false
            await autoAdvanceAfterFailure()
            return
        }

        plog("↳ AVAssetReader fallback for '\(song.title)' url=\(url.scheme ?? "")://... ext=\(url.pathExtension)")

        let fallbackStream = assetReaderDecoder.decode(from: url, outputFormat: outputFormat)
        let iteratorBox = BufferIteratorBox(fallbackStream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: Self.remoteFallbackFirstBufferTimeoutSeconds
            ) else {
                guard playID == id else { return }
                isLoading = false
                await autoAdvanceAfterFailure()
                return
            }
            guard playID == id else { return }

            plog("↳ AssetReader firstBuffer: frames=\(firstBuffer.frameLength) format=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount)")
            activeDecoderKind = .assetReader
            // Check if buffer has actual audio data (not all zeros)
            if let channelData = firstBuffer.floatChannelData?[0] {
                let frameCount = Int(firstBuffer.frameLength)
                var maxSample: Float = 0
                for i in 0..<min(frameCount, 1000) {
                    maxSample = max(maxSample, abs(channelData[i]))
                }
                plog("↳ AssetReader firstBuffer maxSample=\(maxSample) (0 = silence/broken)")
            }
            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()

            // Fetch duration asynchronously
            if duration <= 0 {
                Task {
                    if let info = await self.assetReaderDecoder.fileInfo(for: url) {
                        guard self.playID == id else { return }
                        self.duration = info.duration.sanitizedDuration
                        self.updateNowPlayingInfo()
                    }
                }
            }

            // Transition state after audio starts
            isPlaying = true
            isLoading = false
            clearPendingPlaybackRecovery()
            library?.recordPlayback(of: song.id)
            ScrobbleService.shared.handlePlaybackStarted(song: song); PlayHistoryStore.shared.beginSession(song: song)
            startTimeUpdater()
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Apply ReplayGain in background (don't block playback start)
            let settings = playbackSettings.snapshot()
            if settings.replayGainEnabled, url.isFileURL {
                Task { [id] in
                    await self.applyReplayGain(for: song, url: url, mode: settings.replayGainMode)
                    guard self.playID == id else { return }
                }
            }

            // Background-cache file for offline playback
            if !isDLNACast(song) {
                sourceManager?.cacheInBackground(song: song, cacheEnabled: playbackSettings.audioCacheEnabled)
            }

            // Decode remaining buffers with track-end detection
            decodingTask = Task { [id, iteratorBox] in
                var lastBuffer: AVAudioPCMBuffer?

                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }

                        if let prev = lastBuffer {
                            self.audioEngine.scheduleBuffer(prev)
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled {
                        plog("⚠️ AssetReader fallback decode error: \(error.localizedDescription)")
                    }
                }

                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == id else { return }
                    await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                }
            }
        } catch is CancellationError {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ AssetReader fallback first-buffer timeout for '\(song.title)' after \(Self.remoteFallbackFirstBufferTimeoutSeconds)s")
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            await autoAdvanceAfterFailure()
        } catch {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ AssetReader fallback also failed: \(error.localizedDescription)")
            isLoading = false
            await autoAdvanceAfterFailure()
        }
    }

    private func scheduleDecodedFinalBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) async {
        guard shouldAttemptGapless(settings: playbackSettings.snapshot()),
              nextSongInQueue() != nil else {
            scheduleLastBuffer(buffer, playID: id)
            return
        }

        let transition = GaplessTransitionState(queueGeneration: queueGeneration)
        audioEngine.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self, transition] _ in
            // .dataPlayedBack 在 playerNode.reset() / stopPlayback() 时也会
            // 同步 fire (任何 yield / 新 play / 主动切歌都会触发), id 是闭包
            // 捕获的旧 playID, 移到 guard 内才不会在 log 里产生误导事件。
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                plog("🔔 gapless boundary fired playID=\(id.uuidString.prefix(8))")
                await self.handleGaplessBoundary(transition: transition, playID: id)
            }
        }

        startGaplessPreparation(playID: id, transition: transition)
    }

    private func shouldAttemptGapless(settings: PlaybackSettings) -> Bool {
        guard settings.gaplessEnabled,
              !settings.crossfadeEnabled,
              repeatMode != .one else { return false }

        switch activeDecoderKind {
        case .native, .httpStream, .cloudStream:
            return true
        case .streaming, .assetReader:
            return false
        }
    }

    /// Schedule the final buffer of a track with the appropriate completion callback
    /// for track-end detection, respecting gapless and crossfade settings.
    private func scheduleLastBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        let settings = playbackSettings.snapshot()
        plog("📍 scheduleLastBuffer for playID=\(id.uuidString.prefix(8)) frames=\(buffer.frameLength)")

        // Standard and crossfade modes both use completion callback for track-end detection
        audioEngine.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                plog("🔔 lastBuffer dataPlayedBack fired playID=\(id.uuidString.prefix(8))")
                // In crossfade mode, only handle track end if crossfade wasn't triggered
                if settings.crossfadeEnabled && self.crossfadeTriggered { return }
                await self.handleTrackEnd()
            }
        }
    }

    /// Schedule the last decoded buffer when the stream errored mid-way.
    /// Lets the buffered audio drain so the user still hears something, but
    /// fires `autoAdvanceAfterFailure` on completion instead of
    /// `handleTrackEnd` — so repeat-one stops on a broken song instead of
    /// looping it, and the play-count isn't bumped for an aborted track.
    private func scheduleLastBufferAsFailure(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        audioEngine.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                await self.autoAdvanceAfterFailure()
            }
        }
    }

    private func cancelGaplessTasks() {
        gaplessPreparationTask?.cancel()
        gaplessPreparationTask = nil
        gaplessFollowupTask?.cancel()
        gaplessFollowupTask = nil
    }

    func pause() {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.togglePlayPauseAppleMusic()
            return
        }
        shouldResumeAfterInterruption = false
        syncPlaybackProgressFromEngine()
        audioEngine.pause()
        isPlaying = false
        stopTimeUpdater()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func resume() {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.togglePlayPauseAppleMusic()
            return
        }
        guard !isLoading, let song = currentSong else { return }
        // 「已播完待重播」: 引擎已经 stopPlayback, 不能 resume —— 那是 no-op。
        // 直接重新 play 当前曲 (从 0 开始)。这是 Apple Music 锁屏在歌
        // 播完之后再点 play 的行为。
        if isAtTrackEnd {
            isAtTrackEnd = false
            Task { await play(song: song) }
            return
        }
        if needsPlaybackRecovery {
            seek(to: pendingRecoveryTime, startPlaying: true, isRecovery: true)
            return
        }
        _ = AudioSessionManager.shared.activatePlaybackSession()
        audioEngine.resume()
        syncPlaybackProgressFromEngine()
        isPlaying = true
        shouldResumeAfterInterruption = false
        startTimeUpdater()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    // MARK: - Casting (DLNA Controller 路径)

    /// 开始投屏到远端 renderer ── 本地立刻停, 把当前歌推过去续播 (从当前
    /// 进度起 seek)。后续 togglePlayPause / next / previous / seek 全部路由到
    /// RemoteRendererController。Apple Music DRM 歌无法投屏, 调用前 caller 应
    /// 自己 disable 按钮。
    func startCasting(to renderer: RemoteRenderer) async {
        guard !isAppleMusicMode else {
            plog("⚠️ Cast: Apple Music DRM songs cannot be cast, ignored")
            return
        }
        let resumeSong = currentSong
        let resumeTime = currentTime
        let wasPlaying = isPlaying

        // 1. 本地停 (audioEngine + decoding task), audio session 让出去
        decodingTask?.cancel(); decodingTask = nil
        cancelGaplessTasks()
        crossfadeDecodingTask?.cancel(); crossfadeDecodingTask = nil
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        stopTimeUpdater()
        isPlaying = false

        // 2. 切换 cast 状态 + 启动 controller
        castingRenderer = renderer
        castingController = RemoteRendererController(renderer: renderer)
        plog("📡 Cast: started → \(renderer.friendlyName)")

        // 3. 推当前歌到 renderer + seek 到 resumeTime + 自动 play
        if let song = resumeSong {
            await castSong(song, startAt: resumeTime, autoPlay: wasPlaying)
        }
        // 4. 启动 1Hz 状态轮询
        startCastingPolling()
    }

    /// 停投屏 ── controller stop + 本地从同一首歌当前进度续播 (用户期望)。
    /// 如果 controller 已经断 / 出错, 也强制清状态。
    func stopCasting() async {
        castingPositionTask?.cancel(); castingPositionTask = nil
        let controller = castingController
        let resumeSong = currentSong
        let resumeTime = currentTime
        castingRenderer = nil
        castingController = nil

        if let controller {
            try? await controller.stop()
        }
        plog("📡 Cast: stopped, resuming local from \(resumeTime)s")

        if let song = resumeSong {
            await play(song: song)
            if resumeTime > 1 {
                // play 完成后再 seek; 给一点 buffer 时间
                try? await Task.sleep(for: .milliseconds(300))
                seek(to: resumeTime, startPlaying: false)
            }
        }
    }

    /// cast 模式下播指定歌 ── 解析 URL → 推 SetAVTransportURI → Play → 可选 Seek。
    /// 失败不抛错, 只 log + 保持 cast 状态让用户能手动重试。
    private func castSong(_ song: Song, startAt seconds: TimeInterval = 0, autoPlay: Bool = true) async {
        guard let controller = castingController else { return }
        currentSong = song
        currentTime = seconds
        duration = song.duration.sanitizedDuration
        do {
            let uri = try await resolveCastURI(for: song)
            try await controller.setAVTransportURI(uri: uri.absoluteString,
                                                    title: song.title,
                                                    artist: song.artistName)
            if autoPlay {
                try await controller.play()
                isPlaying = true
            }
            if seconds > 0 {
                try? await Task.sleep(for: .milliseconds(200))
                try? await controller.seek(toSeconds: seconds)
            }
            plog("📡 Cast: '\(song.title)' → \(controller.renderer.friendlyName)")
        } catch {
            plog("⚠️ Cast playback failed for '\(song.title)': \(error.localizedDescription)")
            isPlaying = false
        }
    }

    /// 给 renderer 拿一个它能 HTTP GET 的 URL:
    /// - file:// (本地 / cached): 注册到 DLNAMediaServer, 返回 http://<iphone>:49160/<token>/...
    /// - https / http (NAS / Cloud HTTP source): 直接给, renderer 拉 (前提同 LAN 或公网可达)
    /// - primuse-stream:// (range-fetch cloud): 当前不支持 cast, 抛错让 caller 提示用户先离线下载
    private func resolveCastURI(for song: Song) async throws -> URL {
        let url = try await resolvedURL(for: song)
        if url.isFileURL {
            let name = (song.title.isEmpty ? "track" : song.title) + "." + (url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
            return try DLNAMediaServer.shared.registerFile(localURL: url, suggestedName: name)
        }
        if url.scheme == "http" || url.scheme == "https" {
            return url
        }
        throw NSError(domain: "Primuse.DLNA", code: -10,
                      userInfo: [NSLocalizedDescriptionKey: "Source \"\(song.title)\" needs offline download before casting (scheme=\(url.scheme ?? "?"))"])
    }

    private func startCastingPolling() {
        castingPositionTask?.cancel()
        castingPositionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let controller = self.castingController else { break }
                do {
                    let pos = try await controller.getPositionInfo()
                    if pos.currentTime >= 0 { self.currentTime = pos.currentTime }
                    if pos.duration > 0 { self.duration = pos.duration }
                    let state = try await controller.getTransportInfo()
                    self.isPlaying = (state == "PLAYING")
                } catch {
                    // 轮询失败 (renderer 断网 / 关机) 不立刻退出 cast, 给 3 次重试机会
                    plog("⚠️ Cast polling error: \(error.localizedDescription)")
                }
            }
        }
    }

    func togglePlayPause() {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.togglePlayPauseAppleMusic()
            return
        }
        if isCastingMode, let controller = castingController {
            Task { [isPlaying] in
                do {
                    if isPlaying {
                        try await controller.pause()
                    } else {
                        try await controller.play()
                    }
                } catch {
                    plog("⚠️ Cast togglePlayPause failed: \(error.localizedDescription)")
                }
            }
            return
        }
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.stopAppleMusic()
            stopAppleMusicMirror()
            currentSong = nil
            currentTime = 0
            duration = 0
            isPlaying = false
            isLoading = false
            queueEntries = []
            return
        }
        // 主动结束当前 streaming session (切走 / 用户点停止时), 让 .partial
        // 有机会转 final。
        if let cur = currentSong {
            sourceManager?.finalizeStreamingSession(for: cur)
        }
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTriggered = false; isCrossfading = false
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        audioEngine.resetPlayerVolume()
        isPlaying = false
        isAtTrackEnd = false
        currentSong = nil
        currentTime = 0
        duration = 0
        clearPendingPlaybackRecovery()
        stopTimeUpdater()
        ScrobbleService.shared.handlePlaybackStopped(); PlayHistoryStore.shared.endSession()
        // Clear NowPlaying info so Dynamic Island / Lock Screen also clears
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updatePlaybackState()
    }

    /// 跟 stop() 的差别: 保留 currentSong / queue / currentIndex / duration,
    /// 只清引擎 + 标 isAtTrackEnd = true。给 handleTrackEnd .off 用 ——
    /// 用户搜出来一首歌 (queue 只有一首) 播完时不要把 UI 一下子全清掉
    /// (sheet 白屏 / mini player 闪一下消失)。用户再点 play 可以从头重放
    /// (resume() 检测到 isAtTrackEnd 会走 play(song:) 重新解码)。
    private func stopAtTrackEnd() {
        // 自然播完一首歌, 触发 finalize —— 这是 .partial → final 最关键的
        // 时机, 用户期望「听完一整首」就该是完整缓存。
        if let cur = currentSong {
            sourceManager?.finalizeStreamingSession(for: cur)
        }
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTriggered = false; isCrossfading = false
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        audioEngine.resetPlayerVolume()
        isPlaying = false
        isAtTrackEnd = true
        currentTime = 0
        clearPendingPlaybackRecovery()
        stopTimeUpdater()
        ScrobbleService.shared.handlePlaybackStopped(); PlayHistoryStore.shared.endSession()
        // 锁屏 / Dynamic Island 显示「停在 0:00」状态, 不清空 ——
        // 这样用户从锁屏点 play 也能直接重放当前曲。
        updateNowPlayingInfo()
        updatePlaybackState()
        plog("⏹️ stopAtTrackEnd() currentSong preserved=\(currentSong?.title ?? "nil")")
    }

    func next(caller: String = #fileID, callerLine: Int = #line) async {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.skipToNextAppleMusic()
            return
        }
        guard !queue.isEmpty else { return }
        let callerFile = (caller as NSString).lastPathComponent
        plog("⏭️ next() called FROM=\(callerFile):\(callerLine) currentIndex=\(currentIndex) queueCount=\(queue.count)")
        advanceToNextIndex()
        // 跳过相邻同 title+artist 的"重复歌曲" —— NAS 上同一首歌有多个版本
        // (mp3 + flac, 不同目录) scan 后是不同 song.id, 但用户看就是同一首,
        // 自动 next 跳到 "下一首是自己" 体验很怪。最多跳 1 次, 防止整个
        // queue 全是同一首时死循环。
        if let cur = currentSong, queue.count > 2 {
            let candidate = queue[currentIndex]
            if candidate.title == cur.title && candidate.artistName == cur.artistName {
                plog("⏭️ next: skipping duplicate '\(candidate.title)' (same title+artist as current)")
                advanceToNextIndex()
            }
        }
        await play(song: queue[currentIndex])
    }

    func previous() async {
        if isAppleMusicMode {
            // 跟本地行为一致 ── 播放进度过 3s 时倒回开头, 否则跳上一首。
            if currentTime > 3 {
                AppServices.shared.appleMusic.seekAppleMusic(to: 0)
            } else {
                AppServices.shared.appleMusic.skipToPreviousAppleMusic()
            }
            return
        }
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if shuffleEnabled {
            shufflePosition = max(0, shufflePosition - 1)
            currentIndex = shuffledIndices.isEmpty ? 0 : shuffledIndices[shufflePosition]
        } else {
            currentIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        }
        await play(song: queue[currentIndex])
    }

    private var seekTimeOffset: TimeInterval = 0

    func seek(to time: TimeInterval, startPlaying: Bool? = nil, isRecovery: Bool = false) {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.seekAppleMusic(to: TimeInterval.sanitized(time))
            return
        }
        if isCastingMode, let controller = castingController {
            let target = TimeInterval.sanitized(time)
            currentTime = target
            Task {
                do { try await controller.seek(toSeconds: target) } catch {
                    plog("⚠️ Cast seek failed: \(error.localizedDescription)")
                }
            }
            return
        }
        let requestedTime = TimeInterval.sanitized(time)
        let safeDuration = duration.sanitizedDuration
        let targetTime = safeDuration > 0 ? min(requestedTime, safeDuration) : requestedTime
        currentTime = targetTime
        isLoading = true
        // 用户拖进度条 = 重新介入这首歌, 退出 "已播完" 状态
        isAtTrackEnd = false
        updateNowPlayingInfo()

        guard let song = currentSong else { isLoading = false; return }
        let savedDuration = duration
        let shouldStartPlaying = startPlaying ?? isPlaying

        // Invalidate old playID BEFORE stopPlayback() so any pending completion
        // callbacks (triggered by AVAudioPlayerNode.stop()) will fail
        // their guard check and won't trigger handleTrackEnd() → next().
        let id = UUID()
        playID = id

        // Stop only the playerNode, not the full pipeline — preserve Live Activity,
        // currentSong, and other state that stop() would tear down.
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        audioEngine.stopPlayback()
        stopTimeUpdater()

        // Restore state that stopPlayback clears
        currentSong = song
        currentTime = targetTime
        duration = savedDuration

        Task {
            do {
                let url = try await resolvedURL(for: song)
                guard playID == id else { return }
                _ = AudioSessionManager.shared.activatePlaybackSession()
                try audioEngine.setUp()
                applySpatialAudioSettings()
                guard let outputFormat = audioEngine.outputFormat else { return }
                try audioEngine.start()

                let settings = playbackSettings.snapshot()
                if settings.replayGainEnabled {
                    await applyReplayGain(
                        for: song,
                        url: url,
                        mode: settings.replayGainMode,
                        allowFileRead: activeDecoderKind != .cloudStream && activeDecoderKind != .httpStream
                    )
                }

                // Use the same decoder that was used for initial playback.
                // For streaming, require the cached local file — can't seek in remote streams.
                let seekURL: URL
                if activeDecoderKind == .streaming {
                    guard let cached = sourceManager?.cachedURL(for: song) else {
                        plog("⚠️ Seek: streaming song not cached yet, seek not available")
                        isLoading = false
                        if isRecovery {
                            clearPendingPlaybackRecovery()
                            await play(song: song)
                        }
                        return
                    }
                    seekURL = cached
                } else {
                    seekURL = url
                }
                let stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>
                let onResolveLength = makeResolveLengthCallback(for: song)
                switch activeDecoderKind {
                case .native, .streaming:
                    stream = nativeDecoder.decode(from: seekURL, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                case .httpStream:
                    if let cached = sourceManager?.cachedURL(for: song) {
                        stream = nativeDecoder.decode(from: cached, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                    } else if let inputSource = await makeHTTPStreamingInputSource(for: song, url: url) {
                        stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                    } else {
                        plog("⚠️ Seek: failed to build HTTP streaming InputSource")
                        isLoading = false
                        return
                    }
                case .cloudStream:
                    // Build a fresh InputSource for the seek session. The
                    // sparse cache file from the prior session is reused
                    // (SFB reads will hit local for any byte range we've
                    // already fetched, fall through to network for the
                    // rest). If the song has since been fully downloaded
                    // and renamed to the canonical path, prefer that.
                    if let cached = sourceManager?.cachedURL(for: song) {
                        stream = nativeDecoder.decode(from: cached, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                    } else if let manager = sourceManager,
                              let inputSource = try? await manager.makeStreamingInputSource(
                                  for: song,
                                  cacheEnabled: playbackSettings.audioCacheEnabled
                              ) {
                        stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                    } else {
                        plog("⚠️ Seek: failed to build cloud streaming InputSource")
                        isLoading = false
                        return
                    }
                case .assetReader:
                    stream = assetReaderDecoder.decode(from: seekURL, outputFormat: outputFormat)
                }
                let seekSamplePosition = targetTime * outputFormat.sampleRate
                guard seekSamplePosition.isFinite else {
                    self.isLoading = false
                    self.updateNowPlayingInfo()
                    self.updatePlaybackState()
                    return
                }
                let seekSamples = Int64(seekSamplePosition.rounded(.down))
                var samplesSkipped: Int64 = 0

                // Set sample time offset so currentTime calculation accounts for seek position
                audioEngine.sampleTimeOffset = -seekSamples

                // Skip buffers until seek position, then schedule first playable buffer before play()
                let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())
                var firstPlayableBuffer: AVAudioPCMBuffer?

                while let buffer = try await iteratorBox.next() {
                    guard playID == id else { return }
                    let bufferSamples = Int64(buffer.frameLength)
                    if samplesSkipped + bufferSamples <= seekSamples {
                        samplesSkipped += bufferSamples
                        continue
                    }
                    firstPlayableBuffer = buffer
                    break
                }

                guard let firstBuffer = firstPlayableBuffer else {
                    isLoading = false
                    return
                }
                guard playID == id else { return }

                audioEngine.scheduleBuffer(firstBuffer)
                if shouldStartPlaying { audioEngine.play() }

                isLoading = false
                if shouldStartPlaying {
                    isPlaying = true
                    startTimeUpdater()
                } else {
                    isPlaying = false
                }
                if isRecovery { clearPendingPlaybackRecovery() }
                updateNowPlayingInfo()
                updatePlaybackState()

                // Decode remaining buffers with track-end detection
                decodingTask = Task { [id, iteratorBox] in
                    var lastBuffer: AVAudioPCMBuffer?

                    do {
                        while let buffer = try await iteratorBox.next() {
                            guard !Task.isCancelled, self.playID == id else { return }

                            if let prev = lastBuffer {
                                self.audioEngine.scheduleBuffer(prev)
                            }
                            lastBuffer = buffer
                        }
                    } catch {
                        if !Task.isCancelled { plog("Seek decode error: \(error)") }
                    }

                    if let finalBuffer = lastBuffer {
                        guard !Task.isCancelled, self.playID == id else { return }
                        await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                    }
                }
            } catch {
                plog("Seek error: \(error)")
                isLoading = false
                updateNowPlayingInfo()
                updatePlaybackState()
            }
        }
    }

    func handleAppWillResignActive() {
        syncPlaybackProgressFromEngine()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func handleAppDidBecomeActive() {
        if shouldResumeAfterInterruption, !isPlaying, currentSong != nil {
            resume()
            return
        }

        if needsPlaybackRecovery {
            currentTime = max(0, pendingRecoveryTime)
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }

        syncPlaybackProgressFromEngine()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func setQueue(_ songs: [Song], startAt index: Int = 0) {
        queueGeneration += 1
        queueEntries = songs.map { QueueEntry(song: $0) }
        currentIndex = min(index, songs.count - 1)
        // Drop any pre-built next round — the queue itself changed, so
        // prior shuffle plans (and their indices into the old queue)
        // are stale and would index out-of-bounds on wrap.
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    /// Append songs to the end of the current queue without interrupting the
    /// current track. Used by macOS list-level "add all to queue" actions.
    func appendToQueue(_ songs: [Song]) {
        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else { return }
        queueGeneration += 1
        queueEntries.append(contentsOf: playable.map { QueueEntry(song: $0) })
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    /// Insert songs immediately after the current queue position. If there is
    /// no queue yet, this behaves like `setQueue`.
    func insertNextInQueue(_ songs: [Song]) {
        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else { return }
        guard !queueEntries.isEmpty else {
            setQueue(playable, startAt: 0)
            return
        }
        let insertionIndex = min(currentIndex + 1, queueEntries.count)
        queueGeneration += 1
        queueEntries.insert(contentsOf: playable.map { QueueEntry(song: $0) }, at: insertionIndex)
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    /// 删掉队列前 `count` 首歌, 同时把 `currentIndex` 往前平移 (不让它跑负)。
    /// MacQueuePanel 的 "清掉已播放" 按钮直接调这个 ── 之前是把 player.queue
    /// 当 var 用, 但 queue 现在是 computed。
    func removeQueuePrefix(count: Int) {
        guard count > 0 else { return }
        let toRemove = min(count, queueEntries.count)
        queueGeneration += 1
        queueEntries.removeFirst(toRemove)
        currentIndex = max(0, currentIndex - toRemove)
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    /// Wipe the queue. Replaces the legacy `player.queue = []` setter,
    /// which is no longer accessible since `queue` is now computed.
    func clearQueue() {
        queueGeneration += 1
        cancelGaplessTasks()
        queueEntries = []
        currentIndex = 0
        pendingNextShuffleIndices = nil
        shuffledIndices = []
        shufflePosition = 0
    }

    /// Move queue rows. Used by the QueueView reorder handle. Beyond
    /// the obvious `move`, this also invalidates any pending shuffle
    /// plan and rebuilds the shuffle order — `shuffledIndices` stores
    /// raw queue offsets, so a manual reorder makes those offsets
    /// point at the wrong songs unless we regenerate them.
    func moveQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        queueGeneration += 1
        queueEntries.move(fromOffsets: source, toOffset: destination)
        pendingNextShuffleIndices = nil
        if shuffleEnabled {
            rebuildShuffleOrder()
        }
    }

    func syncSongMetadata(_ updatedSong: Song) {
        if currentSong?.id == updatedSong.id {
            currentSong = updatedSong
            let updatedDuration = updatedSong.duration.sanitizedDuration
            if updatedDuration > 0 {
                duration = updatedDuration
            }
            updateNowPlayingInfo()
            updatePlaybackState()
        }
        // Keep the per-row UUID stable — mutate only `song` so SwiftUI
        // doesn't see a row disappear/reappear when metadata backfill
        // rewrites tags mid-listening.
        if let queueIndex = queueEntries.firstIndex(where: { $0.song.id == updatedSong.id }) {
            queueEntries[queueIndex].song = updatedSong
        }
    }

    // MARK: - Gapless Playback

    private func startGaplessPreparation(playID id: UUID, transition: GaplessTransitionState) {
        gaplessPreparationTask?.cancel()
        gaplessPreparationTask = Task { [id, transition] in
            await self.prepareGaplessNextTrack(playID: id, transition: transition)
        }
    }

    private func handleGaplessBoundary(
        transition: GaplessTransitionState,
        playID id: UUID
    ) async {
        transition.didBoundaryFire = true

        // 防御性兜底: 10 秒内 boundary 触发 ≥4 次 = 队列里有 partial/坏掉
        // 的歌反复切歌, 强制 pause 并 cancel 后续准备, 避免占满
        // CPU + 不停下载 + UI 像是 loading 卡死的体感。
        let now = Date()
        recentBoundaryTimes.append(now)
        recentBoundaryTimes.removeAll { now.timeIntervalSince($0) > Self.boundaryStormWindow }
        if recentBoundaryTimes.count >= Self.boundaryStormThreshold {
            plog("⚠️ gapless boundary storm: \(recentBoundaryTimes.count) 次 / \(Int(Self.boundaryStormWindow))s — 暂停播放, 队列里可能有不完整的缓存文件")
            recentBoundaryTimes.removeAll()
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            pause()
            return
        }

        // Sanity check: 当前歌还远没听完就 fire boundary, 说明上游有问题
        // (CloudPlaybackSource 短读 / decoder 误判 EOF / MP3 帧元数据偏差),
        // 直接切歌会让用户体感是"歌没播完就跳了"。这里重建当前歌曲的
        // decoder pipeline, 从当前进度前一点继续拉数据; 如果仍失败,
        // seek 路径会停在当前曲而不是静默跳到下一首。
        if duration > 30, currentTime < duration - 5, !isLoading {
            plog("⚠️ premature gapless boundary suppressed: currentTime=\(String(format: "%.1f", currentTime))s duration=\(String(format: "%.1f", duration))s playID=\(id.uuidString.prefix(8))")
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            showPlaybackError(String(localized: "playback_error_connection"))
            let recoveryTime = max(0, currentTime - 2)
            seek(to: recoveryTime, startPlaying: true, isRecovery: true)
            return
        }

        let settings = playbackSettings.snapshot()

        // The user can switch Crossfade on after the gapless final buffer
        // has already been scheduled. In that race, the crossfade path owns
        // the transition and will swap nodes; do not also advance here.
        if settings.crossfadeEnabled, crossfadeTriggered {
            transition.shouldCancelPreparation = true
            gaplessPreparationTask?.cancel()
            gaplessPreparationTask = nil
            return
        }

        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            sleepStopAfterSongID = nil
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            stopAtTrackEnd()
            return
        }

        guard shouldAttemptGapless(settings: settings),
              queueGeneration == transition.queueGeneration,
              let prepared = transition.prepared,
              nextSongInQueue()?.id == prepared.song.id else {
            transition.shouldCancelPreparation = true
            gaplessPreparationTask?.cancel()
            gaplessPreparationTask = nil
            await handleTrackEnd()
            return
        }

        activateGaplessTrack(prepared, completedTransition: transition, playID: id)
    }

    private func activateGaplessTrack(
        _ prepared: GaplessPreparedTrack,
        completedTransition: GaplessTransitionState,
        playID id: UUID
    ) {
        guard playID == id else { return }

        if let previous = currentSong {
            sourceManager?.finalizeStreamingSession(for: previous)
        }

        audioEngine.markTrackBoundary()
        advanceToNextIndex()
        currentSong = prepared.song
        duration = prepared.song.duration.sanitizedDuration
        currentTime = 0
        isLoading = false
        isPlaying = true
        isAtTrackEnd = false
        crossfadeTriggered = false
        isCrossfading = false
        activeDecoderKind = prepared.decoderKind
        library?.recordPlayback(of: prepared.song.id)
        ScrobbleService.shared.handlePlaybackStarted(song: prepared.song)
        PlayHistoryStore.shared.beginSession(song: prepared.song)

        let settings = playbackSettings.snapshot()
        if settings.replayGainEnabled {
            Task { [id] in
                await self.applyReplayGain(
                    for: prepared.song,
                    url: prepared.url,
                    mode: settings.replayGainMode,
                    allowFileRead: prepared.decoderKind != .cloudStream && prepared.decoderKind != .httpStream
                )
                guard self.playID == id else { return }
            }
        } else {
            audioEngine.resetPlayerVolume()
        }

        if duration <= 0,
           prepared.decoderKind != .cloudStream,
           prepared.decoderKind != .httpStream {
            Task { [id] in
                if let info = try? await self.nativeDecoder.fileInfo(for: prepared.url) {
                    guard self.playID == id, self.currentSong?.id == prepared.song.id else { return }
                    self.duration = info.duration.sanitizedDuration
                    self.updateNowPlayingInfo()
                }
            }
        }

        startTimeUpdater()
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
        prefetchNextSong()
        startGaplessFollowupPreparation(
            playID: id,
            after: completedTransition,
            followingTransition: prepared.followingTransition
        )
    }

    private func startGaplessFollowupPreparation(
        playID id: UUID,
        after completedTransition: GaplessTransitionState,
        followingTransition: GaplessTransitionState
    ) {
        gaplessFollowupTask?.cancel()
        gaplessFollowupTask = Task { [id, completedTransition, followingTransition] in
            while !Task.isCancelled {
                guard self.playID == id,
                      self.queueGeneration == completedTransition.queueGeneration,
                      !completedTransition.shouldCancelPreparation,
                      !completedTransition.didFail else { return }
                if completedTransition.isFullyScheduled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }

            guard !Task.isCancelled,
                  self.playID == id,
                  self.queueGeneration == followingTransition.queueGeneration else { return }
            self.startGaplessPreparation(playID: id, transition: followingTransition)
        }
    }

    private func prepareGaplessNextTrack(
        playID id: UUID,
        transition: GaplessTransitionState
    ) async {
        guard playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              shouldAttemptGapless(settings: playbackSettings.snapshot()),
              let nextSong = nextSongInQueue() else { return }

        var nextURL: URL
        var nextDecoderKind: DecoderKind
        do {
            nextURL = try await resolvedURL(for: nextSong)
            nextDecoderKind = decoderKind(for: nextSong, url: nextURL)
        } catch {
            plog("Gapless prepare URL error: \(error.localizedDescription)")
            return
        }

        guard playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              nextDecoderKind == .native || nextDecoderKind == .httpStream || nextDecoderKind == .cloudStream,
              nextDecoderKind != .native || nativeDecoder.canDecode(url: nextURL),
              let outputFormat = audioEngine.outputFormat else { return }

        guard let stream = await decodeStream(for: nextSong, url: nextURL, outputFormat: outputFormat) else {
            return
        }

        let followingTransition = GaplessTransitionState(queueGeneration: queueGeneration)
        var lastBuffer: AVAudioPCMBuffer?
        var didMarkPrepared = false

        func markPreparedIfNeeded() {
            guard !didMarkPrepared else { return }
            didMarkPrepared = true
            transition.prepared = GaplessPreparedTrack(
                song: nextSong,
                url: nextURL,
                decoderKind: nextDecoderKind,
                followingTransition: followingTransition
            )
            plog("🔄 gapless prepared next track '\(nextSong.title)'")
        }

        do {
            for try await buffer in stream {
                guard !Task.isCancelled,
                      playID == id,
                      queueGeneration == transition.queueGeneration,
                      !transition.shouldCancelPreparation else { return }

                if let prev = lastBuffer {
                    audioEngine.scheduleBuffer(prev)
                    markPreparedIfNeeded()
                }
                lastBuffer = buffer
            }
        } catch {
            guard !Task.isCancelled,
                  playID == id,
                  queueGeneration == transition.queueGeneration,
                  !transition.shouldCancelPreparation else { return }
            transition.didFail = true
            plog("Gapless prepare decode error: \(error.localizedDescription)")
            if let tailBuffer = lastBuffer {
                audioEngine.scheduleBuffer(
                    tailBuffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playID == id else { return }
                        await self.autoAdvanceAfterFailure()
                    }
                }
                markPreparedIfNeeded()
                transition.isFullyScheduled = true
            }
            return
        }

        guard !Task.isCancelled,
              playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              let finalBuffer = lastBuffer else { return }

        audioEngine.scheduleBuffer(
            finalBuffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self, followingTransition] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                plog("🔔 gapless boundary fired (prepared) playID=\(id.uuidString.prefix(8))")
                await self.handleGaplessBoundary(transition: followingTransition, playID: id)
            }
        }
        markPreparedIfNeeded()
        transition.isFullyScheduled = true
    }

    // MARK: - Crossfade

    private func checkCrossfade() {
        let settings = playbackSettings.snapshot()
        guard settings.crossfadeEnabled, !crossfadeTriggered else { return }
        guard duration > 0, currentTime >= duration - settings.crossfadeDuration else { return }
        // Skip under repeat-one — `nextSongInQueue()` returns the
        // current song there, which would crossfade-to-self. Pre-fix
        // `currentIndex < queue.count - 1` was always false in the
        // single-song repeat-one case so crossfade was never enabled;
        // preserve that.
        guard repeatMode != .one, nextSongInQueue() != nil else { return }

        crossfadeTriggered = true
        Task { await startCrossfade(duration: settings.crossfadeDuration) }
    }

    private func startCrossfade(duration crossfadeDuration: Double) async {
        guard let nextSong = nextSongInQueue() else {
            crossfadeTriggered = false; isCrossfading = false
            return
        }

        do {
            let nextURL = try await resolvedURL(for: nextSong)
            let nextDecoderKind = decoderKind(for: nextSong, url: nextURL)
            guard nativeDecoder.canDecode(url: nextURL),
                  let outputFormat = audioEngine.outputFormat else {
                crossfadeTriggered = false; isCrossfading = false
                return
            }

            // crossfade 一开始就把 UI 切到下一首 —— 用户听到的主音是 next
            // 在淡入接管, 看到的应该跟着是 next。之前要等 ramp 跑完才切,
            // 出现「下一首歌的声音出来了但播放器还显示上一首」的不一致。
            // 期间 currentTime 暂停更新 (isCrossfading=true), 直到 swap
            // 完成跟随新 primary node。
            isCrossfading = true
            advanceToNextIndex()
            currentSong = nextSong
            currentTime = 0
            duration = nextSong.duration.sanitizedDuration
            library?.recordPlayback(of: nextSong.id)
            ScrobbleService.shared.handlePlaybackStarted(song: nextSong)
            PlayHistoryStore.shared.beginSession(song: nextSong)
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Note: ReplayGain for crossfade node would need per-node volume tracking
            // For now, apply after swap

            // Decode into crossfade node — schedule first buffer before play
            guard let stream = await decodeStream(for: nextSong, url: nextURL, outputFormat: outputFormat) else {
                crossfadeTriggered = false; isCrossfading = false
                return
            }
            let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

            guard let firstBuffer = try await iteratorBox.next() else { return }
            audioEngine.scheduleCrossfadeBuffer(firstBuffer)
            audioEngine.playCrossfadeNode()

            crossfadeDecodingTask = Task { [iteratorBox] in
                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled else { return }
                        self.audioEngine.scheduleCrossfadeBuffer(buffer)
                    }
                } catch {
                    if !Task.isCancelled { plog("Crossfade decode error: \(error)") }
                }
            }

            // Start volume ramp using MainActor-isolated timer
            await MainActor.run {
                startCrossfadeRamp(
                    duration: crossfadeDuration,
                    nextSong: nextSong,
                    nextURL: nextURL,
                    nextDecoderKind: nextDecoderKind
                )
            }
        } catch {
            plog("Crossfade start error: \(error)")
            crossfadeTriggered = false; isCrossfading = false
        }
    }

    private func startCrossfadeRamp(
        duration: Double,
        nextSong: Song,
        nextURL: URL,
        nextDecoderKind: DecoderKind
    ) {
        let totalSteps = max(1, Int(duration / 0.05))
        let stepCounter = StepCounter()
        let rampPlayID = playID

        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == rampPlayID else {
                    self?.crossfadeTimer?.invalidate()
                    self?.crossfadeTimer = nil
                    return
                }
                stepCounter.value += 1
                let progress = Float(stepCounter.value) / Float(totalSteps)

                if progress >= 1.0 {
                    self.crossfadeTimer?.invalidate()
                    self.crossfadeTimer = nil
                    self.completeCrossfade(nextSong: nextSong, nextURL: nextURL, nextDecoderKind: nextDecoderKind)
                } else {
                    // Equal-power crossfade curve: maintains perceived loudness
                    // through the transition (no "dip" in the middle like linear)
                    let angle = Double(progress) * .pi / 2
                    self.audioEngine.setCrossfadeVolumes(
                        primary: Float(cos(angle)),
                        crossfade: Float(sin(angle))
                    )
                }
            }
        }
    }

    private func completeCrossfade(nextSong: Song, nextURL: URL, nextDecoderKind: DecoderKind) {
        // Stop old decoding
        decodingTask?.cancel()
        decodingTask = nil

        // Swap nodes
        audioEngine.swapPlayerNodes()
        audioEngine.sampleTimeOffset = 0

        // Transfer crossfade decoding task to main
        decodingTask = crossfadeDecodingTask
        crossfadeDecodingTask = nil

        // 注意: currentSong / queue index / scrobble session 已经在
        // startCrossfade 早期设置好了, 不在这里重复 (重复会让 ScrobbleService
        // 误以为又开了一首新歌, 重新计时)。
        let newID = UUID()
        playID = newID
        activeDecoderKind = nextDecoderKind
        crossfadeTriggered = false; isCrossfading = false
        isCrossfading = false
        plog("🔄 completeCrossfade: swap done, currentSong=\(nextSong.title)")

        // Apply ReplayGain (now on the swapped primary node)
        let settings = playbackSettings.snapshot()
        if settings.replayGainEnabled {
            Task {
                await applyReplayGain(
                    for: nextSong,
                    url: nextURL,
                    mode: settings.replayGainMode,
                    allowFileRead: nextDecoderKind != .cloudStream && nextDecoderKind != .httpStream
                )
            }
        }

        if nextDecoderKind != .cloudStream,
           nextDecoderKind != .httpStream,
           nextDecoderKind != .streaming {
            Task {
                if let info = try? await nativeDecoder.fileInfo(for: nextURL) {
                    self.duration = info.duration
                }
            }
        }

        updateNowPlayingInfo()
        updatePlaybackState()
    }

    // MARK: - ReplayGain

    private struct ReplayGainValues {
        var gain: Double?
        var peak: Double?

        var hasValue: Bool {
            gain != nil || peak != nil
        }
    }

    private func applyReplayGain(
        for song: Song,
        url: URL,
        mode: ReplayGainMode,
        allowFileRead: Bool = true
    ) async {
        let storedValues = replayGainValues(from: song, mode: mode)
        if storedValues.hasValue {
            audioEngine.applyReplayGain(gain: storedValues.gain, peak: storedValues.peak)
            return
        }

        guard allowFileRead else {
            audioEngine.applyReplayGain(gain: nil, peak: nil)
            return
        }

        let metadata = await FileMetadataReader.read(from: url)
        let values = replayGainValues(from: metadata, mode: mode)
        audioEngine.applyReplayGain(gain: values.gain, peak: values.peak)
    }

    private func replayGainValues(from song: Song, mode: ReplayGainMode) -> ReplayGainValues {
        switch mode {
        case .track:
            return ReplayGainValues(
                gain: song.replayGainTrackGain,
                peak: song.replayGainTrackPeak
            )
        case .album:
            return ReplayGainValues(
                gain: song.replayGainAlbumGain ?? song.replayGainTrackGain,
                peak: song.replayGainAlbumPeak ?? song.replayGainTrackPeak
            )
        }
    }

    private func replayGainValues(from metadata: FileMetadataReader.Metadata, mode: ReplayGainMode) -> ReplayGainValues {
        switch mode {
        case .track:
            return ReplayGainValues(
                gain: metadata.replayGainTrackGain,
                peak: metadata.replayGainTrackPeak
            )
        case .album:
            return ReplayGainValues(
                gain: metadata.replayGainAlbumGain ?? metadata.replayGainTrackGain,
                peak: metadata.replayGainAlbumPeak ?? metadata.replayGainTrackPeak
            )
        }
    }

    // MARK: - Time Updates

    private func startTimeUpdater() {
        stopTimeUpdater()
        displayLink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // crossfade 期间 audioEngine 报的还是旧曲 primary node 时间,
                // 但 UI 已经切到新曲, 直接刷会让进度条乱跳。等 swap 完成
                // (isCrossfading=false) 再继续。
                if self.isCrossfading { return }
                if let time = self.audioEngine.currentTime {
                    self.currentTime = time.sanitizedDuration

                    // Safety net: if currentTime exceeds duration, the completion callback
                    // may have failed to fire — force track advancement.
                    if self.duration > 0, self.currentTime >= self.duration + 1.0, !self.isLoading {
                        plog("⚠️ Safety net: currentTime (\(self.currentTime)) exceeded duration (\(self.duration)), forcing track end")
                        self.stopTimeUpdater()
                        await self.handleTrackEnd()
                        return
                    }

                    // Scrobble 进度判断 — 50% 或 4 分钟阈值由 service 内部决定。
                    // 传 currentTime (已听到这个时间点), seek 后该首歌 elapsed 视为
                    // 实际的当前 currentTime, Last.fm 协议本身允许这种近似。
                    ScrobbleService.shared.handleProgressTick(elapsed: self.currentTime); PlayHistoryStore.shared.tick(elapsed: self.currentTime)
                }
                // Check if crossfade should start
                self.checkCrossfade()
            }
        }
    }

    private func stopTimeUpdater() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Track End

    private func handleTrackEnd() async {
        plog("⏭️ handleTrackEnd() currentSong=\(currentSong?.title ?? "nil") playID=\(playID?.uuidString.prefix(8) ?? "nil")")
        // 曲终停止 sleep 模式 ── 锁定的歌刚播完, 暂停而不是 advance。
        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            sleepStopAfterSongID = nil
            stopAtTrackEnd()  // 进 "已播完但保留 currentSong" 状态, 跟用户手动暂停一致
            return
        }
        switch repeatMode {
        case .one:
            if let song = currentSong { await play(song: song) }
        case .all:
            await next()
        case .off:
            // Under shuffle, currentIndex is the queue index of the
            // currently-playing song, not the shufflePosition — so
            // comparing it to queue.count - 1 frequently passed (the
            // last shuffled song often isn't the last in original
            // order) and auto-advance kept generating fresh shuffle
            // rounds even though the user picked repeat-off.
            if nextSongInQueue() != nil {
                await next()
            } else {
                // 没下一首 —— 进 "已播完" 状态而不是 stop() 全清。
                // 否则 currentSong 一旦为 nil, 上层各种 sheet (刮削 /
                // SongInfo / AddToPlaylist) 内容是空的就白屏, mini
                // player 也闪一下消失体验很差。
                stopAtTrackEnd()
            }
        }
    }

    // MARK: - Helpers

    /// Run after a non-recoverable playback failure (unsupported format,
    /// empty stream, decode error, URL resolve fail, fallback
    /// exhausted, mid-stream decode crash). Centralises the "what
    /// happens after failure" rule so every error path stays
    /// consistent:
    /// - Under `repeatMode == .one`, `nextSongInQueue()` returns the
    ///   current song. Calling `next()` from there would either loop the
    ///   broken file forever (single-song queue) or jump to a different
    ///   track and silently violate repeat-one (multi-song queue). So
    ///   we stop and let the user see the error toast that the caller
    ///   already raised.
    /// - Otherwise advance if there's a real successor; if not (last
    ///   track failed, repeat-off), stop so the player exits the
    ///   half-broken loading/streaming state cleanly instead of
    ///   leaving the engine wedged with currentSong still set.
    private func autoAdvanceAfterFailure() async {
        if isDLNACast(currentSong) {
            stop()
            return
        }
        if repeatMode == .one {
            stop()
            return
        }
        if nextSongInQueue() != nil {
            await next()
        } else {
            stop()
        }
    }

    private func isDLNACast(_ song: Song?) -> Bool {
        song?.sourceID == Self.dlnaSourceID
    }

    private func nextSongInQueue() -> Song? {
        guard !queue.isEmpty else { return nil }

        if repeatMode == .one { return currentSong }

        if shuffleEnabled {
            let nextPos = shufflePosition + 1
            if nextPos < shuffledIndices.count {
                return queue[shuffledIndices[nextPos]]
            } else if repeatMode == .all {
                // Wrap: read the pre-generated next round (lazily built
                // here so the prefetch path and the real advance path
                // pick the SAME song — without this they'd disagree
                // because `advanceToNextIndex` reshuffles fresh and
                // we'd prewarm a completely different track).
                let pending = pendingNextShuffleIndices ?? buildPendingNextRound()
                if pendingNextShuffleIndices == nil { pendingNextShuffleIndices = pending }
                guard let firstIdx = pending.first else { return queue.first }
                return queue[firstIdx]
            } else {
                return nil
            }
        }

        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            return queue[nextIndex]
        } else if repeatMode == .all {
            return queue[0]
        }
        return nil
    }

    private func advanceToNextIndex() {
        if shuffleEnabled {
            let nextPos = shufflePosition + 1
            if nextPos < shuffledIndices.count {
                shufflePosition = nextPos
                currentIndex = shuffledIndices[shufflePosition]
            } else {
                // End of round. Adopt the pre-generated next round
                // (built earlier by `nextSongInQueue` for prefetch) so
                // the actual track played matches what was prewarmed.
                let pending = pendingNextShuffleIndices ?? buildPendingNextRound()
                pendingNextShuffleIndices = nil
                shuffledIndices = pending
                shufflePosition = 0
                currentIndex = shuffledIndices.isEmpty ? 0 : shuffledIndices[0]
            }
        } else {
            currentIndex = (currentIndex + 1) % queue.count
        }
    }

    private func rebuildShuffleOrder() {
        guard !queue.isEmpty else { shuffledIndices = []; pendingNextShuffleIndices = nil; return }
        shuffledIndices = Array(0..<queue.count).shuffled()
        shufflePosition = 0
        pendingNextShuffleIndices = nil
        // Place current index at position 0 so current song stays first
        // when shuffle is toggled mid-playback (we don't want to jump
        // off the current track). Wrap-around uses a different builder.
        if let pos = shuffledIndices.firstIndex(of: currentIndex) {
            shuffledIndices.swapAt(0, pos)
        }
    }

    /// Build (but don't install) the next round's shuffle order. Used
    /// by both prefetch and the actual wrap so they pick the same first
    /// song. Avoids placing the just-finished track at position 0 to
    /// stop repeat-all from feeling like repeat-one at the boundary.
    private func buildPendingNextRound() -> [Int] {
        guard !queue.isEmpty else { return [] }
        var order = Array(0..<queue.count).shuffled()
        if queue.count > 1, order.first == currentIndex {
            let otherPos = Int.random(in: 1..<order.count)
            order.swapAt(0, otherPos)
        }
        return order
    }

    // MARK: - URL Resolution

    private func resolvedURL(for song: Song) async throws -> URL {
        if let sourceManager {
            do {
                let url = try await sourceManager.resolveURL(for: song)
                plog("🔗 resolvedURL for '\(song.title)': \(url.isFileURL ? "LOCAL" : url.scheme?.uppercased() ?? "?") → \(url.absoluteString.prefix(120))")
                return url
            } catch {
                plog("🔗 resolveURL failed for '\(song.title)': \(error), filePath=\(song.filePath.prefix(80))")
                if song.filePath.hasPrefix("/") {
                    return URL(fileURLWithPath: song.filePath)
                }
                throw error
            }
        }
        if let remoteURL = URL(string: song.filePath), remoteURL.scheme != nil {
            plog("🔗 resolvedURL for '\(song.title)': direct remote → \(remoteURL.absoluteString.prefix(80))")
            return remoteURL
        }
        plog("🔗 resolvedURL for '\(song.title)': file path → \(song.filePath.prefix(80))")
        return URL(fileURLWithPath: song.filePath)
    }

    // MARK: - Now Playing Info

    /// Tracks which cover we last loaded to avoid redundant disk reads
    private var lastArtworkFileName: String?

    /// 单调递增的封面刷新 token。当刮削回写完成、cache 失效但 coverArtFileName
    /// 字符串可能没变（hash deterministic）时, view 上的 onChange(coverRef) 不会
    /// 触发 reload, @State image 卡在旧 UIImage。CachedArtworkView 监听这个
    /// token, 任意 bump 都能强制三个封面位重新走 loadImage。
    private(set) var coverRevision: Int = 0

    func bumpCoverRevision() {
        coverRevision &+= 1
    }

    private func updateNowPlayingInfo() {
        guard currentSong != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let elapsedTime = max(0, min(currentTime, duration > 0 ? duration : currentTime))

        // Create fresh info but preserve existing artwork
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentSong?.title ?? ""
        info[MPMediaItemPropertyArtist] = currentSong?.artistName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentSong?.albumTitle ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Carry over existing artwork (set separately by updateNowPlayingArtworkIfNeeded)
        if let existingArtwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existingArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Call ONLY when song changes — loads cover art and sets MPMediaItemPropertyArtwork
    private func updateNowPlayingArtworkIfNeeded() {
        let songID = currentSong?.id
        guard songID != lastArtworkFileName else { return }
        lastArtworkFileName = songID

        // Immediately clear stale artwork from previous song so Dynamic Island
        // doesn't keep showing the old cover while loading the new one.
        var nowInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowInfo[MPMediaItemPropertyArtwork] = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowInfo

        guard let songID else { return }
        let coverRef = currentSong?.coverArtFileName
        let capturedSourceID = currentSong?.sourceID
        let capturedFilePath = currentSong?.filePath
        let capturedSourceManager = sourceManager

        Task.detached(priority: .userInitiated) { [weak self] in
            guard self != nil else { return }
            let store = MetadataAssetStore.shared

            // Tier 1: songID-based cache (透明处理 content-addressed redirect)
            var loadedImage: PlatformImage?
            let hashedName = store.expectedCoverFileName(for: songID)
            if let data = store.readCoverData(named: hashedName) {
                loadedImage = PlatformImage(data: data)
            }

            // Tier 2: legacy filename (local hashed filename, no "/" or "://")
            if loadedImage == nil, let coverRef, !coverRef.isEmpty,
               !coverRef.contains("/"), !coverRef.contains("://") {
                if let data = store.readCoverData(named: coverRef) {
                    loadedImage = PlatformImage(data: data)
                }
            }

            // Tier 3: source fetch — URL reference or sidecar path
            if loadedImage == nil, let coverRef, !coverRef.isEmpty {
                var fetchedData: Data?
                // Full URL (media server API)
                if coverRef.contains("://"), let url = URL(string: coverRef) {
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 10
                    let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                    fetchedData = try? await session.data(from: url).0
                }
                // Sidecar path on source (contains "/" but no "://")
                else if coverRef.contains("/"), let sourceID = capturedSourceID,
                        let sourceManager = capturedSourceManager {
                    if let imageURL = await sourceManager.imageURL(for: coverRef, sourceID: sourceID) {
                        let config = URLSessionConfiguration.default
                        config.timeoutIntervalForRequest = 10
                        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                        fetchedData = try? await session.data(from: imageURL).0
                    }
                }
                if let data = fetchedData {
                    // Cache for next time
                    await store.cacheCover(data, forSongID: songID)
                    loadedImage = PlatformImage(data: data)
                }
            }

            // Tier 4: embedded cover extraction from locally cached audio file
            if loadedImage == nil, let sourceID = capturedSourceID, let filePath = capturedFilePath,
               let sourceManager = capturedSourceManager {
                let dummySong = Song(id: "", title: "", fileFormat: .mp3, filePath: filePath,
                                     sourceID: sourceID, fileSize: 0, dateAdded: Date())
                if let cachedURL = await sourceManager.cachedURL(for: dummySong) {
                    let metadata = await FileMetadataReader.read(from: cachedURL)
                    if let coverData = metadata.coverArtData {
                        await store.cacheCover(coverData, forSongID: songID)
                        loadedImage = PlatformImage(data: coverData)
                    }
                }
            }

            // Guard: make sure we're still on the same song before updating NowPlaying
            await MainActor.run { [weak self] in
                guard let self, self.currentSong?.id == songID else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                if let image = loadedImage {
                    info[MPMediaItemPropertyArtwork] = Self.makeArtwork(from: image)
                } else {
                    info[MPMediaItemPropertyArtwork] = nil
                }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    /// Force refresh NowPlaying artwork (e.g. after scraping updated the cover file).
    /// Resets lastArtworkFileName so the guard check passes.
    func forceRefreshNowPlayingArtwork() {
        lastArtworkFileName = nil
        bumpCoverRevision()
        updateNowPlayingArtworkIfNeeded()
    }

    func updateNowPlayingArtwork(_ image: PlatformImage) {
        lastArtworkFileName = currentSong?.coverArtFileName
        let artwork = Self.makeArtwork(from: image)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Creates MPMediaItemArtwork with a non-isolated requestHandler closure.
    /// Must be nonisolated so the closure doesn't inherit @MainActor isolation —
    /// MediaPlayer calls the handler on a background dispatch queue.
    nonisolated private static func makeArtwork(from image: PlatformImage) -> MPMediaItemArtwork {
        let safeImage = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in safeImage }
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in
            plog("🎛️ MediaRemote nextTrackCommand fired")
            Task { await self?.next() }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            plog("🎛️ MediaRemote previousTrackCommand fired")
            Task { await self?.previous() }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime); return .success
        }
    }

    // MARK: - Sleep Timer

    func scheduleSleep(minutes: Int) {
        cancelSleep()
        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = endDate
        sleepTimerTask = Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self.pause()
            self.sleepTimerEndDate = nil
        }
    }

    /// 曲终停止 ── 锁定当前曲目, 等它播完 (currentSong 变化或变 nil) 时
    /// 自动暂停。如果 currentSong 是空的就什么也不做。
    func scheduleSleepAtTrackEnd() {
        cancelSleep()
        sleepStopAfterSongID = currentSong?.id
    }

    func cancelSleep() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
        sleepStopAfterSongID = nil
    }

    /// 在 player 切歌路径里 (next / 队列自动推进) 调一次 ── 如果"曲终停止"
    /// 已激活并且当前曲目就是 sleep 锁定的那首, 暂停播放并清除 sleep state。
    /// 不在 sleep 模式时是 no-op。
    func handleSongTransitionForSleep(previousSongID: String?) {
        guard let lockedID = sleepStopAfterSongID, previousSongID == lockedID else { return }
        pause()
        sleepStopAfterSongID = nil
    }

    // MARK: - Shared Playback State

    /// Tracks the last songID for which we wrote a widget cover, to avoid redundant writes.
    private var lastWidgetCoverSongID: String?
    /// Coalesces repeated WidgetKit reload requests with identical content.
    private var lastWidgetTimelineSignature: String?

    /// macOS Widget Sync 设置页里 "立即更新" 按钮直接调这个。包装一下 private
     /// 的 updatePlaybackState, 让 mac 设置面板可以强制刷一遍 widget 状态而无需
     /// 把整个内部方法暴露成 public。
    func publishWidgetStateForMacWidgetSync() {
        updatePlaybackState()
    }

    private func updatePlaybackState() {
        guard WidgetSettings.syncEnabled(),
              WidgetSettings.widgetEnabled(PrimuseConstants.widgetNowPlayingEnabledKey) else {
            PlaybackState.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        var coverName: String?
        var recentAlbumsChanged = false
        let recentAlbumsEnabled = WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey)

        if let song = currentSong {
            let sharedCoverName = "widget_cover.png"
            let needsSharedCoverRefresh = song.id != lastWidgetCoverSongID || !sharedWidgetCoverExists(named: sharedCoverName)

            if needsSharedCoverRefresh {
                if let writtenCoverName = writeWidgetCover(song: song, fileName: sharedCoverName) {
                    coverName = writtenCoverName
                    lastWidgetCoverSongID = song.id
                } else if sharedWidgetCoverExists(named: sharedCoverName) {
                    coverName = sharedCoverName
                    lastWidgetCoverSongID = song.id
                } else {
                    lastWidgetCoverSongID = nil
                }

                if recentAlbumsEnabled, let albumEntry = makeRecentAlbumEntry(for: song) {
                    if let albumCoverName = albumEntry.coverImageName,
                       !sharedWidgetCoverExists(named: albumCoverName) {
                        _ = writeWidgetCover(song: song, fileName: albumCoverName, size: 200)
                    }
                    RecentAlbumsStore.record(albumEntry)
                    recentAlbumsChanged = true
                }
            } else {
                coverName = sharedCoverName
            }
            if !recentAlbumsEnabled {
                RecentAlbumsStore.clear()
                recentAlbumsChanged = true
            }
        } else {
            lastWidgetCoverSongID = nil
        }

        let state = PlaybackState(
            currentSongID: currentSong?.id,
            songTitle: currentSong?.title,
            artistName: currentSong?.artistName,
            albumTitle: currentSong?.albumTitle,
            fileFormat: currentSong.map { $0.fileFormat.displayName },
            coverImageName: coverName,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            queueSongIDs: queue.map(\.id)
        )
        state.save()

        let timelineSignature = widgetTimelineSignature(for: state)
        if recentAlbumsChanged || timelineSignature != lastWidgetTimelineSignature {
            lastWidgetTimelineSignature = timelineSignature
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Writes a cover image to the App Group shared container for Widget rendering.
    /// Returns the filename if successful.
    ///
    /// 仅 iOS 实现 ── macOS 上 WidgetKit 的桌面 widget 通过另外的 MacWidgetSync
    /// 通道渲染, 不走 App Group cover.png 这条路。
    @discardableResult
    private func writeWidgetCover(song: Song, fileName: String, size: CGFloat = 300) -> String? {
        #if os(iOS)
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }

        let store = MetadataAssetStore.shared

        // Try songID-based cache first (透明处理 content-addressed redirect)
        var coverData: Data?
        let hashedName = store.expectedCoverFileName(for: song.id)
        coverData = store.readCoverData(named: hashedName)

        // Fallback: legacy local filename
        if coverData == nil, let ref = song.coverArtFileName, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            coverData = store.readCoverData(named: ref)
        }

        guard let data = coverData, let originalImage = UIImage(data: data) else {
            return nil
        }

        let targetSize = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            let sourceAspect = originalImage.size.width / originalImage.size.height
            let drawRect: CGRect
            if sourceAspect > 1 {
                let scaledWidth = targetSize.height * sourceAspect
                let xOffset = (targetSize.width - scaledWidth) / 2
                drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: targetSize.height)
            } else {
                let scaledHeight = targetSize.width / sourceAspect
                let yOffset = (targetSize.height - scaledHeight) / 2
                drawRect = CGRect(x: 0, y: yOffset, width: targetSize.width, height: scaledHeight)
            }
            originalImage.draw(in: drawRect)
        }

        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.8) else { return nil }

        let destinationURL = containerURL.appendingPathComponent(fileName)

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func sharedWidgetCoverExists(named fileName: String) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else {
            return false
        }
        return FileManager.default.fileExists(atPath: containerURL.appendingPathComponent(fileName).path)
    }

    private func makeRecentAlbumEntry(for song: Song) -> RecentAlbumEntry? {
        guard let rawAlbumTitle = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAlbumTitle.isEmpty else {
            return nil
        }

        let artistName = song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let albumKey = stableWidgetAlbumKey(for: song, albumTitle: rawAlbumTitle, artistName: artistName)
        let coverImageName = "widget_album_\(albumKey).jpg"

        return RecentAlbumEntry(
            id: albumKey,
            title: rawAlbumTitle,
            artistName: artistName,
            coverImageName: coverImageName
        )
    }

    private func stableWidgetAlbumKey(for song: Song, albumTitle: String, artistName: String) -> String {
        let baseKey = song.albumID ?? "\(song.sourceID)|\(albumTitle.lowercased())|\(artistName.lowercased())"
        let digest = SHA256.hash(data: Data(baseKey.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func widgetTimelineSignature(for state: PlaybackState) -> String {
        [
            state.currentSongID ?? "",
            state.songTitle ?? "",
            state.artistName ?? "",
            state.albumTitle ?? "",
            state.coverImageName ?? "",
            state.isPlaying ? "1" : "0",
            String(Int(state.currentTime.rounded())),
            String(Int(state.duration.rounded()))
        ].joined(separator: "|")
    }
}
