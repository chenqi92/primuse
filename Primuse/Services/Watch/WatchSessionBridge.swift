// WatchConnectivity 在 macOS 上不可用, 整个文件 iOS-only。macOS 端的
// Mac app 没有 Watch 伴侣关系 ── Watch app 跟 Mac 桌面端不配对。
#if os(iOS)
import AVFoundation
import Foundation
import Observation
import UIKit
import SwiftUI
@preconcurrency import WatchConnectivity
import PrimuseKit

/// iPhone 端的 Apple Watch 桥。
///
/// 投递策略:
/// - **状态推送**走 `sendMessage` 优先, 在 simulator 间和真机上都是实时的;
///   `updateApplicationContext` 在 simulator 间投递经常滞后好几秒, 不能作为
///   主路径。Watch 不可达时降级到 applicationContext 留个最新快照, watch
///   下次唤醒时能拿到。
/// - **封面 JPEG** (200×200, ~25KB) 直接塞进 sendMessage 一起推。WCSession
///   sendMessage 限 ~65KB, 封面 + 字段一起塞得下, 不再走 transferUserInfo
///   排队 ── 之前那条路在 simulator 上延迟到秒级, 用户看到的就是 watch
///   永远不出封面。
/// - **当前歌词行**: 从 `MetadataAssetStore.lyrics(named:)` 读, 二分定位
///   当前 timestamp 对应行, 跟状态一起推。
/// - **专辑动态色**: 把 `ThemeService.accentColor` 拆成 RGB 推到 watch,
///   watch 端用作主色, 跟 iPhone 视觉一致。
/// - **控制指令** Watch → iPhone 仍是 sendMessage, 不可达降级到
///   transferUserInfo 队列投递。
@MainActor
final class WatchSessionBridge: NSObject {
    static let shared = WatchSessionBridge()

    private let session: WCSession?
    private weak var player: AudioPlayerService?
    private weak var library: MusicLibrary?
    private weak var theme: ThemeService?
    /// 推送是事件驱动的 ── 只在以下字段真正变化时才发, 不再 1Hz 推 currentTime
    /// (那会让 watch 乐观更新撞车 + iPhone 旧 anchor 导致进度跳变)。Watch 端
    /// 拿 sentCurrentTime + 100ms 外推自己跑时间。
    private var lastPushedSongID: String = ""
    private var lastPushedIsPlaying: Bool = false
    private var lastPushedIsLoading: Bool = false
    private var lastPushedIsLiveStream: Bool = false
    private var lastPushedTitle: String = ""
    private var lastPushedArtist: String = ""
    private var lastPushedLyric: String = ""
    /// Quantized RGB of the last delivered artwork accent. Cover extraction is
    /// asynchronous, so the color can change after the first state for a song.
    private var lastPushedAccentSignature: UInt32?
    /// 手表「更多」页与播放键用的其余状态(喜欢、播放方式、有声书快进快退、
    /// 下一句歌词、声音输出到哪)。任一项变了就再推一次。
    private var lastPushedExtras: WatchStateExtras?
    /// iPhone 现在的声音输出。读 currentRoute 要问一次音频会话, 不放进 0.5s 的
    /// tick 里反复读, 只在线路变化时刷新。
    private var cachedOutput = WatchOutputRoute(name: "", kind: "")
    private var routeChangeObserver: NSObjectProtocol?
    /// 最近一次 iPhone 音量变化的时刻 (手表转表冠、按音量键都算)。手表平时把音量控件藏着,
    /// 收到它才亮出来, 停下一会儿再淡出。手表 App 自己收不到表冠转动, 只能靠这边告诉它。
    private var lastVolumeChangeSignal: Date?
    private var volumeObservation: NSKeyValueObservation?
    /// 最近一次成功推送的封面 songID。换歌后 cover 推送一次就够。
    private var lastSentCoverSongID: String?
    /// 最近一次编码好的封面 JPEG + 其 songID。watch 不可达走 applicationContext
    /// (latest-only) 时, 用它给每条快照都补上封面 ── 否则后续不带 cover 的歌词
    /// 推送会把含 cover 的快照覆盖掉, watch 下次唤醒只剩占位渐变。
    private var lastCoverJPEG: Data?
    private var lastCoverJPEGSongID: String?
    /// 正在取封面的 songID。Apple Music 的封面要联网取, 期间每换一行歌词都会再
    /// 要一次封面, 同一首在取的时候不再另起一份。
    private var coverLoadingSongID: String?
    /// 最近播放列表 hash, 不变就不重发。
    private var lastLibraryHash: Int = 0
    private var lastQueueSnapshotRevision: Int?
    private var queueDeliveryRetryNotBefore: Date?
    private var queueDeliveryFailureCount = 0
    /// 排队投递的队列快照编号。新快照排进去时撤掉还没送出的旧快照,
    /// 撤掉那条的回调不算投递失败。
    private var queueTransferSequence = 0
    /// watch 一次启动会连发好几次 requestState (激活、可达性变化、页面出现),
    /// 合并成一次回应, 不然每次都把整份队列和封面重发一遍。
    private var stateRequestResponseTask: Task<Void, Never>?
    /// 当前歌曲的歌词缓存 (换歌时异步刷新, tick 从这里 sync 查找)。
    /// MetadataAssetStore.lyrics(named:) 是 actor-isolated 不能 sync 调,
    /// 所以预读到 bridge 自己的内存里。
    private var cachedLyricsForSongID: String?
    private var cachedLyrics: [LyricLine] = []
    private var stateTickerTask: Task<Void, Never>?

    private override init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }
        super.init()
        session?.delegate = self
        session?.activate()
        cachedOutput = Self.readOutputRoute()
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cachedOutput = Self.readOutputRoute()
                // 暂停时 ticker 挂着, 戴上或摘下耳机要在这里补推一次。
                self.pushIfMeaningfulChange()
            }
        }
        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.old, .new]
        ) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.noteOutputVolumeChange()
            }
        }
    }

    /// 音量在变: 立刻推一次, 不等 0.5 秒的 tick (暂停时 tick 还挂着)。连着转表冠时
    /// 0.3 秒最多推一次 ── 手表只要知道「还在调」, 不需要每一格的值。
    private func noteOutputVolumeChange() {
        // 手表 App 没开着就没人看, 按 iPhone 音量键时不必一直改后台上下文。
        guard session?.isReachable == true else { return }
        let now = Date()
        if let last = lastVolumeChangeSignal, now.timeIntervalSince(last) < 0.3 { return }
        lastVolumeChangeSignal = now
        pushIfMeaningfulChange()
    }

    /// App 启动时调用 ── 注入依赖；只有已安装 Watch app 时才保留 ticker。
    func attach(player: AudioPlayerService, library: MusicLibrary, theme: ThemeService) {
        self.player = player
        self.library = library
        self.theme = theme
        refreshStateTicker()
    }

    private func refreshStateTicker() {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            stateTickerTask?.cancel()
            stateTickerTask = nil
            lastLibraryHash = 0
            lastQueueSnapshotRevision = nil
            resetQueueDeliveryRetry()
            return
        }
        guard stateTickerTask == nil else { return }
        startStateTicker()
    }

    private func startStateTicker() {
        // 0.5s tick ── 状态推送 (歌词行 / 播放状态变化) 和 队列推送 各自
        // 跑一遍。两者都有 hash 去重, 没变化就不发; 都独立检测, 互不
        // 阻塞 (queue 变化但 state 没变也能被推到)。
        //
        // 只在播放/加载中才轮询: 暂停或空闲时歌词行和时间基准都不会自己
        // 变, ticker 挂起等播放状态变化 (见 `waitForPlaybackStateChange`),
        // 进入挂起前后各推一次, 不丢任何一次快照。
        stateTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                guard let player = self.player else { continue }
                self.pushIfMeaningfulChange()
                self.pushLibraryDigest()

                let shouldKeepTicking = WatchStateTickerPolicy.shouldRunTicker(
                    isPlaying: player.isPlaying,
                    isLoading: player.isLoading,
                    hasCurrentSong: player.currentSong != nil
                ) || self.hasPendingQueueDeliveryRetry
                guard !shouldKeepTicking else { continue }

                await self.waitForPlaybackStateChange()
                guard !Task.isCancelled else { return }
                // 恢复后立刻补一次, 不等下一个 0.5s。
                self.pushIfMeaningfulChange()
                self.pushLibraryDigest()
            }
        }
    }

    /// 队列投递失败后的退避重试仍然要靠 tick 驱动, 有待重试就别挂起。
    private var hasPendingQueueDeliveryRetry: Bool {
        guard let queueDeliveryRetryNotBefore else { return false }
        return Date() < queueDeliveryRetryNotBefore
    }

    /// 挂起 ticker, 直到播放状态 (播放/加载/换歌/seek) 或队列发生变化。
    ///
    /// `withObservationTracking` 是一次性的, 所以每次挂起都重新注册一次;
    /// 首次触发即返回, 由调用方的循环在下一次挂起时重新武装。任务被取消时
    /// `for await` 会立即结束, ticker 不会滞留。
    private func waitForPlaybackStateChange() async {
        guard let player else { return }
        let theme = self.theme
        let wakeUps = AsyncStream<Void> { continuation in
            withObservationTracking {
                _ = player.isPlaying
                _ = player.isLoading
                _ = player.currentSong?.id
                _ = player.currentTime
                // queueEntries 的任何改动 (含重排) 都会触发, 暂停时改队列
                // 也能把新快照推到 watch。
                _ = player.queueCount
                _ = player.shuffleEnabled
                _ = player.repeatMode
                // 在 iPhone 上点了喜欢, 手表上的心也要跟着变。
                _ = self.likeState(for: player.currentSong)
                // 封面主色是异步提取的: 暂停时换歌, 颜色可能比状态晚到,
                // 这里跟一下免得 watch 停在上一首的主色。
                _ = theme?.accentColor
            } onChange: {
                continuation.yield(())
            }
        }
        for await _ in wakeUps { break }
    }

    /// 检查"meaningful state" 是否变了 (排除 currentTime 这种自然流逝的字段)。
    /// 变了才推一次 ── 避免持续推送跟 watch 乐观更新撞车。
    private func pushIfMeaningfulChange(force: Bool = false) {
        guard let session, session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else { return }
        guard let player else { return }

        let song = player.currentSong
        let songID = song?.id ?? ""
        let isPlaying = player.isPlaying
        let isLoading = player.isLoading
        let isLiveStream = player.isLiveRadio
        let title = song?.title ?? ""
        let artist = song.flatMap { library?.artistDisplayName(for: $0) } ?? ""
        let lyric = isLiveStream ? "" : currentLyricLine(song: song, time: player.currentTime)
        let accentSignature = currentAccentSignature()
        let extras = currentExtras(song: song, time: player.currentTime)

        let songChanged = songID != lastPushedSongID
        let stateChanged = force
            || songChanged
            || isPlaying != lastPushedIsPlaying
            || isLoading != lastPushedIsLoading
            || isLiveStream != lastPushedIsLiveStream
            || title != lastPushedTitle
            || artist != lastPushedArtist
            || lyric != lastPushedLyric
            || accentSignature != lastPushedAccentSignature
            || extras != lastPushedExtras

        if !stateChanged { return }

        if songChanged {
            refreshLyricsCache(for: song)
        }

        lastPushedSongID = songID
        lastPushedIsPlaying = isPlaying
        lastPushedIsLoading = isLoading
        lastPushedIsLiveStream = isLiveStream
        lastPushedTitle = title
        lastPushedArtist = artist
        lastPushedLyric = lyric
        lastPushedAccentSignature = accentSignature
        lastPushedExtras = extras

        // 封面带不带取决于 watch 是否已经拿到这首的封面 ── 用
        // lastSentCoverSongID 而不是 songChanged 判断: watch 冷启动 / 重连后发
        // requestState 时 song 并没换 (songChanged=false), 但 watch 端是全新
        // 实例 (coverImage=nil), 此时必须补发封面。songChanged 只是其中一种
        // "需要封面" 的情形。注意 song?.id 是可选: 有歌时只有 id 跟上次成功
        // 投递的 cover songID 不同才补发, 无歌时 (nil) 不重复推空封面。
        let needCover = song != nil && song?.id != lastSentCoverSongID
        push(song: song, isPlaying: isPlaying, isLoading: isLoading,
             lyric: lyric, includeCover: needCover)
    }

    private func push(song: Song?, isPlaying: Bool, isLoading: Bool,
                      lyric: String, includeCover: Bool) {
        guard player != nil else { return }

        // 先发不带封面的状态: 文字 / 播放状态 / 歌词立刻到 watch, 不被封面
        // 磁盘读取 + 解码 + 缩放 + JPEG 编码 (可能数百毫秒) 阻塞。
        let payload = stateScalars(song: song, isPlaying: isPlaying,
                                   isLoading: isLoading, lyric: lyric)
        plog("⌚️ deliver payload reachable=\(session?.isReachable ?? false) (cover pending=\(includeCover))")
        deliver(payload)

        guard includeCover else { return }
        guard let song else {
            // 无歌 ── 直接补一条空封面状态让 watch 清掉旧封面。
            var clear = stateScalars(song: nil, isPlaying: isPlaying,
                                     isLoading: isLoading, lyric: lyric)
            clear["coverJPEG"] = Data()
            lastSentCoverSongID = nil
            lastCoverJPEG = nil
            lastCoverJPEGSongID = nil
            deliver(clear)
            return
        }

        // 封面整条链路 (磁盘 IO / UIImage 解码 / UIGraphicsImageRenderer 重绘 /
        // JPEG 编码) 放到 detached utility 队列, 别卡 main actor。完成后回 main
        // actor 用当时的 player 状态重新组装一条完整状态 (含封面) 再投递 ──
        // 复用现成 applyContext 路径, watch 不需要单独处理 "只含封面" 的消息。
        let songID = song.id
        guard coverLoadingSongID != songID else { return }
        coverLoadingSongID = songID
        let songTitle = song.title
        let coverRef = song.coverArtFileName
        Task.detached(priority: .utility) {
            let cover = await Self.coverJPEG(for: song)
            await MainActor.run {
                let bridge = Self.shared
                if bridge.coverLoadingSongID == songID { bridge.coverLoadingSongID = nil }
                // 期间用户切歌就丢弃这张封面, 避免把旧封面盖到新歌上。
                guard bridge.player?.currentSong?.id == songID else { return }
                guard let cover else {
                    plog("⌚️ no cover available for \(songTitle) (ref=\(coverRef ?? "nil"))")
                    return
                }
                var withCover = bridge.stateScalars(
                    song: bridge.player?.currentSong,
                    isPlaying: bridge.player?.isPlaying ?? false,
                    isLoading: bridge.player?.isLoading ?? false,
                    lyric: bridge.lastPushedLyric)
                withCover["coverJPEG"] = cover
                bridge.lastSentCoverSongID = songID
                bridge.lastCoverJPEG = cover
                bridge.lastCoverJPEGSongID = songID
                plog("⌚️ pushing cover \(cover.count)B for \(songTitle)")
                bridge.deliver(withCover)
            }
        }
    }

    /// 组装一条状态 payload 的标量字段 (不含封面)。push 的首发和封面就绪后的
    /// 补发都用它, 保证两条消息字段一致, watch 端 applyContext 不会因缺字段
    /// 回落默认值。
    private func stateScalars(song: Song?, isPlaying: Bool, isLoading: Bool,
                              lyric: String) -> [String: Any] {
        let (r, g, b) = currentAccentRGB()
        let extras = currentExtras(song: song, time: player?.currentTime ?? 0)
        // currentTimeAnchor 用 Date() (推送时刻), 不用 player 内部 anchor ──
        // player anchor 可能是几秒前的, 让 watch 外推得到未来时间, 跳变就来了。
        var payload: [String: Any] = [
            "type": "state",
            "songID": song?.id ?? "",
            "title": song?.title ?? "",
            "artist": song.flatMap { library?.artistDisplayName(for: $0) } ?? "",
            "album": song?.albumTitle ?? "",
            "isPlaying": isPlaying,
            "isLoading": isLoading,
            "isLiveStream": player?.isLiveRadio ?? false,
            "duration": player?.isLiveRadio == true ? 0 : (player?.duration ?? 0),
            "currentTime": player?.currentTime ?? 0,
            "currentTimeAnchor": Date().timeIntervalSince1970,
            "queueCount": player?.isLiveRadio == true ? 0 : (player?.queueCount ?? 0),
            "currentLyric": player?.isLiveRadio == true ? "" : lyric,
            "accentR": r, "accentG": g, "accentB": b,
        ]
        payload.merge(extras.payload) { _, new in new }
        return payload
    }

    /// 优先 sendMessage 即时投递; watch 不可达时退到 applicationContext。
    /// applicationContext 是系统覆盖式存储 (latest-only), 即便 watch 此刻
    /// 离线也能在下次启动时拿到最新快照, 但延迟几秒级。
    ///
    /// errorHandler 必须是 nonisolated `@Sendable` ── WCSession 在后台
    /// NSOperationQueue 调用它, 如果闭包继承了 main actor 隔离 (默认),
    /// Swift 6 严格并发会在那个 queue 触发 isolation check trap (崩溃)。
    private func deliver(_ payload: [String: Any]) {
        guard let session else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: Self.deliverErrorHandler)
        } else {
            // applicationContext 是 latest-only 覆盖式存储 ── 给每条快照都补上
            // 当前歌曲的封面, 否则后续不带 cover 的歌词推送会覆盖含 cover 的
            // 快照, watch 下次唤醒只剩占位渐变。仅当 payload 自己没带 cover、
            // 且 songID 跟缓存的封面匹配时补。
            var ctx = payload
            if ctx["coverJPEG"] == nil,
               let cover = lastCoverJPEG,
               let coverSongID = lastCoverJPEGSongID,
               (ctx["songID"] as? String) == coverSongID {
                ctx["coverJPEG"] = cover
            }
            do {
                try session.updateApplicationContext(ctx)
            } catch {
                plog("⌚️ updateApplicationContext failed: \(error)")
            }
        }
    }

    /// 静态 @Sendable 闭包 ── 不捕获 self / 任何 actor 状态, 安全地从
    /// 后台 queue 调用。
    nonisolated static let deliverErrorHandler: @Sendable (Error) -> Void = { error in
        // 从 background queue 跨回 main actor 再走 plog (plog 可能是 main-isolated)。
        Task { @MainActor in
            plog("⌚️ sendMessage failed: \(error.localizedDescription)")
        }
    }

    /// 把整个当前播放队列的简化数据推到 Watch, 跟 iPhone 端 NowPlayingView
    /// 看到的"播放列表"保持一致 (含顺序)。
    ///
    /// 投递通道: reachable 走 sendMessage 即时投递, 否则走 transferUserInfo
    /// 排队投递。两个通道的 payload 上限都约 65KB, 所以无论走哪条都先按累计
    /// 字节把队列截断到 55KB 安全线 (带 totalCount/truncated 标记), 避免超大
    /// 队列 payloadTooLarge 失败导致 watch 列表整页空白。单首条目大约 50-200
    /// 字节 (中文 UTF-8 偏长), 55KB 大约能塞 300-350 首。
    func pushLibraryDigest() {
        guard let session, session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else { return }
        guard let player else { return }
        if let retryNotBefore = queueDeliveryRetryNotBefore,
           Date() < retryNotBefore {
            return
        }

        let queueRevision = player.watchQueueSnapshotRevision
        guard lastLibraryHash == 0 || lastQueueSnapshotRevision != queueRevision else {
            return
        }

        // sendMessage 和 transferUserInfo 的 payload 上限都约 65KB ── 超大队列
        // (约 400 首以上) 走任一通道都会 payloadTooLarge 失败, 之前错误被吞,
        // watch 播放列表永远为空。这里按累计字节截断到安全上限, 带 totalCount /
        // truncated 标记, watch 端至少能显示前若干首而非整页空白。
        // (理想方案是分片 + watch 端拼装, 但拼装逻辑在 WatchPlayerStore, 不在
        //  本簇可编辑范围; 截断是当前可安全落地的退路。)
        let byteBudget = 55_000
        let perItemOverhead = 24  // 字典 / NSArray 元数据估算
        let snapshot = player.makeWatchQueueDigestSnapshot(
            byteBudget: byteBudget,
            perItemOverhead: perItemOverhead,
            artistConfiguration: library?.artistNameConfiguration ?? .defaultValue
        )
        if snapshot.digest == lastLibraryHash {
            // A duration/artwork-only Song mutation still advances the queue
            // revision. Mark it observed so the 0.5s ticker does not rebuild
            // the unchanged Watch projection forever.
            lastQueueSnapshotRevision = queueRevision
            return
        }

        let payload: [String: Any] = [
            "libraryKind": "queue",
            "songIDs": snapshot.songIDs,
            "titles": snapshot.titles,
            "artists": snapshot.artists,
            "totalCount": snapshot.totalCount,
            "truncated": snapshot.isTruncated,
        ]
        plog("⌚️ pushQueueDigest sent=\(snapshot.songIDs.count)/\(snapshot.totalCount) bytes~\(snapshot.estimatedPayloadBytes) truncated=\(snapshot.isTruncated) reachable=\(session.isReachable)")

        // 排队投递条条都会送到, 不像 applicationContext 只留最新: 还没送出的旧快照
        // 已经过时, 留着会晚于这次的新快照到达, 把 watch 上的列表盖回旧的。
        for transfer in session.outstandingUserInfoTransfers
        where transfer.userInfo["libraryKind"] as? String == "queue" {
            transfer.cancel()
        }
        queueTransferSequence &+= 1

        // 投递确认前不更新 lastLibraryHash ── sendMessage 失败时回滚 (置 0,
        // 下个 tick 重发), 否则失败的这版队列永远不会重发。
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil,
                                errorHandler: Self.libraryDigestErrorHandler)
            queueDeliveryRetryNotBefore = nil
        } else {
            // 不可达: 排队投递。watch 端 didReceiveUserInfo 同样能消化。
            // transferUserInfo 失败由 session(_:didFinish:error:) 统一回滚重试。
            var queued = payload
            queued["queueSequence"] = queueTransferSequence
            _ = session.transferUserInfo(queued)
        }
        lastLibraryHash = snapshot.digest
        lastQueueSnapshotRevision = queueRevision
    }

    private func recordQueueDeliveryFailure() {
        lastLibraryHash = 0
        queueDeliveryFailureCount = min(queueDeliveryFailureCount + 1, 6)
        let delaySeconds = min(60, 1 << min(queueDeliveryFailureCount, 5))
        queueDeliveryRetryNotBefore = Date().addingTimeInterval(
            TimeInterval(delaySeconds)
        )
    }

    private func resetQueueDeliveryRetry() {
        queueDeliveryFailureCount = 0
        queueDeliveryRetryNotBefore = nil
    }

    /// 队列推送失败时把 lastLibraryHash 清零, 让下个 0.5s tick 自动重发这版
    /// 队列。nonisolated `@Sendable` ── WCSession 在后台 queue 调用。
    nonisolated static let libraryDigestErrorHandler: @Sendable (Error) -> Void = { error in
        Task { @MainActor in
            plog("⌚️ pushQueueDigest sendMessage failed: \(error.localizedDescription) — will retry")
            WatchSessionBridge.shared.recordQueueDeliveryFailure()
        }
    }

    // MARK: - Helpers

    /// 拿当前 ThemeService 的 accent 拆成 RGB Double。读不到时退回默认深海青。
    private func currentAccentRGB() -> (Double, Double, Double) {
        let color = theme?.accentColor ?? ThemeService.defaultAccent
        // 手表只有深色界面:随外观变的主题色(「白色」「品红」)取深色那一档,
        // 不然手机在浅色外观时「白色」会按近黑推过去,黑底上看不见。
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func currentAccentSignature() -> UInt32 {
        let (r, g, b) = currentAccentRGB()
        func quantized(_ component: Double) -> UInt32 {
            UInt32((max(0, min(1, component)) * 255).rounded())
        }
        return (quantized(r) << 16) | (quantized(g) << 8) | quantized(b)
    }

    /// 手表上除歌名、进度以外的状态。电台只有切台, 有声内容换成快进快退,
    /// 喜欢的口径和锁屏那颗心一样(曲库里的歌和播客单集)。
    private func currentExtras(song: Song?, time: TimeInterval) -> WatchStateExtras {
        var extras = WatchStateExtras()
        if let renderer = player?.castingRenderer {
            extras.outputName = renderer.friendlyName
            extras.outputKind = "cast"
        } else {
            extras.outputName = cachedOutput.name
            extras.outputKind = cachedOutput.kind
        }
        extras.volumeChangedAt = lastVolumeChangeSignal?.timeIntervalSince1970 ?? 0
        guard let player, let song else { return extras }
        extras.canSwitchStation = player.canSwitchRadioStation
        guard !player.isLiveRadio else { return extras }
        // 倍速播放时手表按这个速度往前推进度, 表盘进度圈也按它算哪一刻放完。
        // 走系统播放器时倍速不生效 (会先退回 PCM 引擎), 按 1 倍报。
        if !player.isSystemAudioPlaybackActive {
            extras.playbackRate = Double(player.requestedPlaybackRate)
        }
        let like = likeState(for: song)
        extras.canLike = like.canLike
        extras.isLiked = like.isLiked
        if player.currentItemIsSpokenWord {
            extras.skipBackwardSeconds = player.spokenWordSkipBackwardSeconds
            extras.skipForwardSeconds = player.spokenWordSkipForwardSeconds
            extras.skipBackwardSymbol = player.spokenWordSkipBackwardSymbol
            extras.skipForwardSymbol = player.spokenWordSkipForwardSymbol
        } else {
            extras.offersPlaybackModes = true
            extras.playbackMode = PlaybackOrderMode(
                shuffleEnabled: player.shuffleEnabled,
                repeatMode: player.repeatMode
            ).rawValue
            // 和队列页那颗键一样: 不到两首时随机打不开。
            extras.allowsShuffle = player.queueCount >= 2
        }
        if song.id == cachedLyricsForSongID, !cachedLyrics.isEmpty {
            extras.hasLyrics = true
            extras.nextLyric = nextLyricLine(time: time)
        }
        return extras
    }

    private func likeState(for song: Song?) -> (canLike: Bool, isLiked: Bool) {
        guard let song, let player, !player.isLiveRadio else { return (false, false) }
        if PodcastPlaybackSong.isEpisode(song) {
            return (true, PodcastStore.shared.isLiked(episodeID: song.id))
        }
        guard let library, library.song(id: song.id) != nil else { return (false, false) }
        return (true, library.isLiked(songID: song.id))
    }

    /// 手表按的是「设成喜欢 / 取消」而不是「切换」: 重发一次不会又改回去。
    /// 带上手表当时看到的那首, 期间换了歌就不动。
    private func setLikedFromWatch(_ liked: Bool, songID: String?) {
        guard let player, let song = player.currentSong,
              songID == nil || songID == song.id else { return }
        let state = likeState(for: song)
        guard state.canLike, state.isLiked != liked else { return }
        if PodcastPlaybackSong.isEpisode(song) {
            player.toggleLikeForCurrentPodcastEpisode()
        } else {
            library?.setLiked(songID: song.id, isLiked: liked, propagatesServerMutation: true)
            player.republishNowPlayingSurfaces()
        }
    }

    /// 和队列页「播放方式」键同一套: 换到哪一种由两个开关决定, 随机要队列够两首。
    private func applyPlaybackModeFromWatch(_ mode: PlaybackOrderMode) {
        guard let player, !player.isLiveRadio, !player.currentItemIsSpokenWord else { return }
        if mode == .shuffle, player.queueCount < 2 { return }
        let target = mode.settings(from: player.repeatMode)
        if player.repeatMode != target.repeatMode { player.repeatMode = target.repeatMode }
        if player.shuffleEnabled != target.shuffleEnabled { player.shuffleEnabled = target.shuffleEnabled }
    }

    private static func readOutputRoute() -> WatchOutputRoute {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return WatchOutputRoute(name: "", kind: "")
        }
        let kind: String
        switch port.portType {
        case .builtInSpeaker, .builtInReceiver: kind = "iphone"
        case .headphones, .usbAudio, .lineOut: kind = "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: kind = "bluetooth"
        case .airPlay: kind = "airplay"
        case .carAudio: kind = "car"
        case .HDMI: kind = "display"
        default: kind = "other"
        }
        return WatchOutputRoute(name: port.portName, kind: kind)
    }

    /// 当前这句之后的下一句(手表歌词面板里淡显在下面)。
    private func nextLyricLine(time: TimeInterval) -> String {
        guard let index = cachedLyrics.firstIndex(where: { $0.timestamp > time }) else { return "" }
        return cachedLyrics[index].text
    }

    /// 从缓存的歌词数组里找当前 time 应该高亮的行。无歌词返回空字符串。
    /// 缓存由 `refreshLyricsCache` 在换歌时异步填充, 这里只 sync 查找。
    private func currentLyricLine(song: Song?, time: TimeInterval) -> String {
        guard let song, song.id == cachedLyricsForSongID, !cachedLyrics.isEmpty else {
            return ""
        }
        var lower = 0
        var upper = cachedLyrics.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cachedLyrics[middle].timestamp <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return "" }
        let line = cachedLyrics[lower - 1]
        let activeBackground = cachedLyrics
            .flatMap { $0.background ?? [] }
            .filter { LyricVoiceTimelinePolicy.isActive($0, at: time) }
        return ([line.text] + activeBackground.map(\.text)).joined(separator: "\n")
    }

    /// 换歌时调用 ── 异步把当前曲歌词读进 bridge 内部, 之后播放中的 0.5s
    /// tick 直接 sync 用。读 lyrics 文件 IO 走 detached Task 避开 main
    /// actor 阻塞。
    private func refreshLyricsCache(for song: Song?) {
        guard let song else {
            cachedLyricsForSongID = nil
            cachedLyrics = []
            return
        }
        let songID = song.id
        let ref = song.lyricsFileName
        Task.detached(priority: .utility) {
            let lines: [LyricLine] = await {
                guard let ref else { return [] }
                return await MetadataAssetStore.shared.lyrics(named: ref) ?? []
            }()
            await MainActor.run {
                // 期间用户又切歌就忽略本次结果。
                guard Self.shared.player?.currentSong?.id == songID else { return }
                Self.shared.cachedLyricsForSongID = songID
                Self.shared.cachedLyrics = lines
                // 歌词是异步读进来的, 暂停时 ticker 已挂起, 这里补推一次
                // (内部有 hash 去重, 行没变就不发)。
                Self.shared.pushIfMeaningfulChange()
            }
        }
    }

    /// 同步读封面 + 缩到 ~160×160 JPEG。
    ///
    /// 查找顺序:
    /// 1. songID-hashed 名 (新架构 cache 都存在这里, 命中率高)
    /// 2. song.coverArtFileName (旧 sidecar / 已知 ref)
    /// 3. Apple Music 的歌: 资料库歌的引用是 `musicKit://`, 上面两步都读不到,
    ///    走 CarPlay 同一条官方封面查找
    ///
    /// 输出大小目标 < 45KB 留余地给状态字段 ── sendMessage 总 payload 上限
    /// ~64KB, 之前 200×200 0.7 的封面单张就 50-60KB 直接超了。
    nonisolated private static func coverJPEG(for song: Song) async -> Data? {
        let store = MetadataAssetStore.shared
        var raw: Data?
        let hashedName = store.expectedCoverFileName(for: song.id)
        raw = store.readCoverData(named: hashedName)
        if raw == nil, let ref = song.coverArtFileName {
            raw = store.readCoverData(named: ref)
        }
        var image = raw.flatMap { UIImage(data: $0) }
        if image == nil, song.sourceID == AppleMusicLibraryIdentity.sourceID {
            image = await AppleMusicSongArtwork.image(
                for: song, pixelSize: 300, mirrorsIntoSongCache: false
            )
        }
        guard let img = image else { return nil }

        let target = CGSize(width: 160, height: 160)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        // 先试 0.6, 超 45KB 降到 0.4。watch 屏幕小, 0.4 视觉差异极小。
        if let d = scaled.jpegData(compressionQuality: 0.6), d.count <= 45_000 {
            return d
        }
        return scaled.jpegData(compressionQuality: 0.4)
    }
}

/// Sendable 命令载体 ── 把 WCSession 来的 `[String: Any]` 在 nonisolated
/// 上下文里立刻拆出标量字段。Swift 6 严格并发不允许跨 actor 传 Any。
struct WatchCommand: Sendable {
    let command: String
    let time: Double?
    let songID: String?
    let liked: Bool?
    let mode: String?

    init(_ message: [String: Any]) {
        command = message["command"] as? String ?? ""
        time = message["time"] as? Double
        songID = message["songID"] as? String
        liked = message["liked"] as? Bool
        mode = message["mode"] as? String
    }
}

/// iPhone 现在把声音放到哪: kind 给手表挑图标, name 是系统给的设备名。
struct WatchOutputRoute: Equatable {
    let name: String
    let kind: String
}

/// 推给手表的附加状态, 跟着每条状态消息一起走。旧版手表不认这些键, 照常显示。
struct WatchStateExtras: Equatable {
    var canLike = false
    var isLiked = false
    var offersPlaybackModes = false
    var playbackMode = PlaybackOrderMode.sequential.rawValue
    var allowsShuffle = false
    var skipBackwardSeconds = 0
    var skipForwardSeconds = 0
    var skipBackwardSymbol = ""
    var skipForwardSymbol = ""
    var canSwitchStation = false
    var hasLyrics = false
    var nextLyric = ""
    var outputName = ""
    var outputKind = ""
    var playbackRate = 1.0
    var volumeChangedAt: TimeInterval = 0

    var payload: [String: Any] {
        [
            "canLike": canLike,
            "isLiked": isLiked,
            "offersPlaybackModes": offersPlaybackModes,
            "playbackMode": playbackMode,
            "allowsShuffle": allowsShuffle,
            "skipBackwardSeconds": skipBackwardSeconds,
            "skipForwardSeconds": skipForwardSeconds,
            "skipBackwardSymbol": skipBackwardSymbol,
            "skipForwardSymbol": skipForwardSymbol,
            "canSwitchStation": canSwitchStation,
            "hasLyrics": hasLyrics,
            "nextLyric": nextLyric,
            "outputName": outputName,
            "outputKind": outputKind,
            "playbackRate": playbackRate,
            "volumeChangedAt": volumeChangedAt,
        ]
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            plog("⌚️ WCSession activate error: \(error)")
        } else {
            plog("⌚️ WCSession activated state=\(activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) reachable=\(session.isReachable)")
        }
        Task { @MainActor in
            Self.shared.refreshStateTicker()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            Self.shared.refreshStateTicker()
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// transferUserInfo 完成回调 ── 之前完全没实现, 队列走排队通道失败
    /// (payloadTooLarge 等) 时错误被彻底吞掉。这里捕获失败, 把队列推送的
    /// 去重 hash 清零, 让下个 tick 重发。
    nonisolated func session(_ session: WCSession,
                             didFinish userInfoTransfer: WCSessionUserInfoTransfer,
                             error: Error?) {
        let isQueue = userInfoTransfer.userInfo["libraryKind"] as? String == "queue"
        let sequence = userInfoTransfer.userInfo["queueSequence"] as? Int
        Task { @MainActor in
            guard isQueue else { return }
            // 被新快照撤掉的旧快照, 成败都不影响新的那条。
            guard sequence == nil || sequence == Self.shared.queueTransferSequence else { return }
            if let error {
                plog("⌚️ transferUserInfo didFinish error: \(error.localizedDescription) isQueue=true")
                Self.shared.recordQueueDeliveryFailure()
            } else {
                Self.shared.resetQueueDeliveryRetry()
            }
        }
    }

    /// Reachability 改变 (e.g. watch app 进入前台) ── 立刻推一份最新状态,
    /// 而不是等下一次 tick (播放中 0.5s, 暂停时 ticker 已挂起)。这能让
    /// watch 切回前台立刻看到当前曲目。
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            if session.isReachable {
                Self.shared.resetQueueDeliveryRetry()
            }
            Self.shared.pushIfMeaningfulChange(force: true)
            Self.shared.pushLibraryDigest()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            Self.shared.refreshStateTicker()
            Self.shared.pushIfMeaningfulChange(force: true)
            Self.shared.pushLibraryDigest()
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        let cmd = WatchCommand(message)
        Task { @MainActor in
            await Self.shared.handleCommand(cmd)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let cmd = WatchCommand(message)
        replyHandler(["ok": true])
        Task { @MainActor in
            await Self.shared.handleCommand(cmd)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // 防御 ── transferUserInfo 是排队投递, 一条命令可能在 watch 离线
        // 几小时后才到达 iPhone。控制类指令 (next/pause/seek/playSong) 此时
        // 执行只会让用户惊吓, 直接丢弃; 只接受幂等的 requestState (无副作用,
        // 拿当下最新状态)。Watch 端 send() 也已在不可达时丢弃控制命令,
        // 这里是防旧 build / 残留消息的二道防线。
        let cmd = WatchCommand(userInfo)
        guard WatchQueuedCommandPolicy.acceptsQueuedDelivery(command: cmd.command) else {
            plog("⌚️ drop stale userInfo cmd=\(cmd.command)")
            return
        }
        Task { @MainActor in
            await Self.shared.handleCommand(cmd)
        }
    }

    @MainActor
    private func handleCommand(_ cmd: WatchCommand) async {
        guard let player else { return }
        switch cmd.command {
        case "togglePlayPause":
            player.togglePlayPause()
        case "play":
            if !player.isPlaying { player.togglePlayPause() }
        case "pause":
            if player.isPlaying { player.pause() }
        case "next":
            // 电台收藏了不止一台时, 上一首 / 下一首就是换台(和锁屏一致)。
            guard !player.isLiveRadio || player.canSwitchRadioStation else { return }
            await player.next(caller: "watch")
        case "previous":
            guard !player.isLiveRadio || player.canSwitchRadioStation else { return }
            await player.previous()
        case "skipForward":
            guard player.currentItemIsSpokenWord, !player.isLiveRadio else { return }
            player.skipSpokenWordForward()
        case "skipBackward":
            guard player.currentItemIsSpokenWord, !player.isLiveRadio else { return }
            player.skipSpokenWordBackward()
        case "setLiked":
            guard let liked = cmd.liked else { return }
            setLikedFromWatch(liked, songID: cmd.songID)
        case "setPlaybackMode":
            guard let mode = cmd.mode.flatMap(PlaybackOrderMode.init(rawValue:)) else { return }
            applyPlaybackModeFromWatch(mode)
        case "seek":
            guard !player.isLiveRadio else { return }
            if let t = cmd.time { player.seek(to: t) }
        case "requestState":
            // watch 主动拉状态 (冷启动 / 重新可达 / 前台) ── 视为 watch 端
            // 缓存全失效: 清空封面去重戳强制补发封面, 清空 library hash 强制
            // 重发队列。否则正在播歌时打开 watch 只能看到占位渐变。
            // 0.3 秒内接连到的几次合成一次回应。
            guard stateRequestResponseTask == nil else { return }
            stateRequestResponseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                self.stateRequestResponseTask = nil
                self.lastSentCoverSongID = nil
                self.lastLibraryHash = 0
                self.pushIfMeaningfulChange(force: true)
                self.pushLibraryDigest()
            }
            return
        case "playSong":
            guard let id = cmd.songID, let library else { return }
            // 用户播放入口必须走 visible* API: 歌曲所属源在 watch 队列快照推送
            // 之后被停用时, 不能再让 iPhone 播放已停用源的歌曲。与 ContentView
            // 等其它外部播放入口口径一致。
            if let song = library.visibleSong(id: id) {
                await player.play(song: song, caller: "watch")
            } else {
                // 未命中 (源已停用 / 队列已变) ── 清掉去重 hash 强推一次最新
                // 队列, 让 watch 列表自我修正。注意推送的是 player.queue, 仅当
                // 队列变了才会过 hash 去重; 这里置 0 确保即便队列未变也会重发,
                // 把 watch 端可能残留的旧快照覆盖掉。
                lastLibraryHash = 0
                pushLibraryDigest()
            }
        default:
            plog("⌚️ unknown command: \(cmd.command)")
            return
        }
        // 控制类指令处理后立刻强推一次最新状态 (含新 currentTime, 让 watch
        // 校准外推基准), 不等 0.5s tick。
        pushIfMeaningfulChange(force: true)
    }
}
#endif
