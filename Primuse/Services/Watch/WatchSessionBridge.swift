// WatchConnectivity 在 macOS 上不可用, 整个文件 iOS-only。macOS 端的
// Mac app 没有 Watch 伴侣关系 ── Watch app 跟 Mac 桌面端不配对。
#if os(iOS)
import Foundation
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
    /// 最近一次成功推送的封面 songID。换歌后 cover 推送一次就够。
    private var lastSentCoverSongID: String?
    /// 最近一次编码好的封面 JPEG + 其 songID。watch 不可达走 applicationContext
    /// (latest-only) 时, 用它给每条快照都补上封面 ── 否则后续不带 cover 的歌词
    /// 推送会把含 cover 的快照覆盖掉, watch 下次唤醒只剩占位渐变。
    private var lastCoverJPEG: Data?
    private var lastCoverJPEGSongID: String?
    /// 最近播放列表 hash, 不变就不重发。
    private var lastLibraryHash: Int = 0
    private var lastQueueSnapshotRevision: Int?
    private var queueDeliveryRetryNotBefore: Date?
    private var queueDeliveryFailureCount = 0
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
        stateTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.pushIfMeaningfulChange()
                self.pushLibraryDigest()
            }
        }
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
        let songTitle = song.title
        let coverRef = song.coverArtFileName
        Task.detached(priority: .utility) {
            let cover = Self.coverJPEG(for: song)
            await MainActor.run {
                let bridge = Self.shared
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
        // currentTimeAnchor 用 Date() (推送时刻), 不用 player 内部 anchor ──
        // player anchor 可能是几秒前的, 让 watch 外推得到未来时间, 跳变就来了。
        return [
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

        // 投递确认前不更新 lastLibraryHash ── sendMessage 失败时回滚 (置 0,
        // 下个 tick 重发), 否则失败的这版队列永远不会重发。
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil,
                                errorHandler: Self.libraryDigestErrorHandler)
            queueDeliveryRetryNotBefore = nil
        } else {
            // 不可达: 排队投递。watch 端 didReceiveUserInfo 同样能消化。
            // transferUserInfo 失败由 session(_:didFinish:error:) 统一回滚重试。
            _ = session.transferUserInfo(payload)
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
        let ui = UIColor(color)
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

    /// 换歌时调用 ── 异步把当前曲歌词读进 bridge 内部, 之后 1Hz tick 直接
    /// sync 用。读 lyrics 文件 IO 走 detached Task 避开 main actor 阻塞。
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
            }
        }
    }

    /// 同步读封面 + 缩到 ~160×160 JPEG。
    ///
    /// 查找顺序:
    /// 1. songID-hashed 名 (新架构 cache 都存在这里, 命中率高)
    /// 2. song.coverArtFileName (旧 sidecar / 已知 ref)
    ///
    /// 输出大小目标 < 45KB 留余地给状态字段 ── sendMessage 总 payload 上限
    /// ~64KB, 之前 200×200 0.7 的封面单张就 50-60KB 直接超了。
    nonisolated private static func coverJPEG(for song: Song) -> Data? {
        let store = MetadataAssetStore.shared
        var raw: Data?
        let hashedName = store.expectedCoverFileName(for: song.id)
        raw = store.readCoverData(named: hashedName)
        if raw == nil, let ref = song.coverArtFileName {
            raw = store.readCoverData(named: ref)
        }
        guard let data = raw, let img = UIImage(data: data) else { return nil }

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

    init(_ message: [String: Any]) {
        command = message["command"] as? String ?? ""
        time = message["time"] as? Double
        songID = message["songID"] as? String
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
        Task { @MainActor in
            guard isQueue else { return }
            if let error {
                plog("⌚️ transferUserInfo didFinish error: \(error.localizedDescription) isQueue=true")
                Self.shared.recordQueueDeliveryFailure()
            } else {
                Self.shared.resetQueueDeliveryRetry()
            }
        }
    }

    /// Reachability 改变 (e.g. watch app 进入前台) ── 立刻推一份最新状态,
    /// 而不是等下一次 1Hz tick。这能让 watch 切回前台立刻看到当前曲目。
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
            guard !player.isLiveRadio else { return }
            await player.next(caller: "watch")
        case "previous":
            guard !player.isLiveRadio else { return }
            await player.previous()
        case "seek":
            guard !player.isLiveRadio else { return }
            if let t = cmd.time { player.seek(to: t) }
        case "requestState":
            // watch 主动拉状态 (冷启动 / 重新可达 / 前台) ── 视为 watch 端
            // 缓存全失效: 清空封面去重戳强制补发封面, 清空 library hash 强制
            // 重发队列。否则正在播歌时打开 watch 只能看到占位渐变。
            lastSentCoverSongID = nil
            lastLibraryHash = 0
            pushIfMeaningfulChange(force: true)
            pushLibraryDigest()
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
