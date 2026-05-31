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
    private var lastPushedLyric: String = ""
    /// 最近一次成功推送的封面 songID。换歌后 cover 推送一次就够。
    private var lastSentCoverSongID: String?
    /// 最近播放列表 hash, 不变就不重发。
    private var lastLibraryHash: Int = 0
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

    /// App 启动时调用 ── 注入依赖, 启动 1Hz 状态推送。
    func attach(player: AudioPlayerService, library: MusicLibrary, theme: ThemeService) {
        self.player = player
        self.library = library
        self.theme = theme
        startStateTicker()
    }

    private func startStateTicker() {
        stateTickerTask?.cancel()
        // 0.5s tick ── 状态推送 (歌词行 / 播放状态变化) 和 队列推送 各自
        // 跑一遍。两者都有 hash 去重, 没变化就不发; 都独立检测, 互不
        // 阻塞 (queue 变化但 state 没变也能被推到)。
        stateTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
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
        let lyric = currentLyricLine(song: song, time: player.currentTime)

        let songChanged = songID != lastPushedSongID
        let stateChanged = force
            || songChanged
            || isPlaying != lastPushedIsPlaying
            || isLoading != lastPushedIsLoading
            || lyric != lastPushedLyric

        if !stateChanged { return }

        if songChanged {
            refreshLyricsCache(for: song)
        }

        lastPushedSongID = songID
        lastPushedIsPlaying = isPlaying
        lastPushedIsLoading = isLoading
        lastPushedLyric = lyric

        push(song: song, isPlaying: isPlaying, isLoading: isLoading,
             lyric: lyric, includeCover: songChanged)
    }

    private func push(song: Song?, isPlaying: Bool, isLoading: Bool,
                      lyric: String, includeCover: Bool) {
        guard let player else { return }
        let (r, g, b) = currentAccentRGB()

        // currentTimeAnchor 用 Date() (推送时刻), 不用 player 内部 anchor ──
        // player anchor 可能是几秒前的, 让 watch 外推得到未来时间, 跳变就来了。
        var payload: [String: Any] = [
            "type": "state",
            "songID": song?.id ?? "",
            "title": song?.title ?? "",
            "artist": song?.artistName ?? "",
            "album": song?.albumTitle ?? "",
            "isPlaying": isPlaying,
            "isLoading": isLoading,
            "duration": player.duration,
            "currentTime": player.currentTime,
            "currentTimeAnchor": Date().timeIntervalSince1970,
            "queueCount": player.queue.count,
            "currentLyric": lyric,
            "accentR": r, "accentG": g, "accentB": b,
        ]

        if includeCover {
            if let song {
                if let cover = Self.coverJPEG(for: song) {
                    payload["coverJPEG"] = cover
                    lastSentCoverSongID = song.id
                    plog("⌚️ pushing state w/ cover \(cover.count)B for \(song.title)")
                } else {
                    plog("⌚️ no cover available for \(song.title) (ref=\(song.coverArtFileName ?? "nil"))")
                }
            } else {
                payload["coverJPEG"] = Data()
                lastSentCoverSongID = nil
            }
        }

        let totalSize = payload.values.compactMap { ($0 as? Data)?.count }.reduce(0, +)
        plog("⌚️ deliver payload reachable=\(session?.isReachable ?? false) dataBytes=\(totalSize)")
        deliver(payload)
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
            do {
                try session.updateApplicationContext(payload)
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
    /// 看到的"播放列表"保持一致 (含顺序 + 全部条目)。
    ///
    /// 投递通道根据 payload 大小自适应:
    /// - 估算 < 55KB: 走 sendMessage 即时投递 (reachable 时)
    /// - 否则: 走 transferUserInfo 排队投递, 几秒延迟可接受
    /// 单首条目大约 50-200 字节 (中文 UTF-8 偏长), 一首平均 ~150B, 55KB 大约
    /// 能塞 350 首; 更长的队列自动降级。
    func pushLibraryDigest() {
        guard let session, session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else { return }
        guard let player else { return }

        let songs = player.queue
        let ids = songs.map(\.id)
        let titles = songs.map(\.title)
        let artists = songs.map { $0.artistName ?? "" }

        var hasher = Hasher()
        for id in ids { hasher.combine(id) }
        let h = hasher.finalize()
        if h == lastLibraryHash { return }
        lastLibraryHash = h

        let payload: [String: Any] = [
            "libraryKind": "queue",
            "songIDs": ids,
            "titles": titles,
            "artists": artists,
        ]
        let estimatedBytes = ids.reduce(0) { $0 + $1.utf8.count }
            + titles.reduce(0) { $0 + $1.utf8.count }
            + artists.reduce(0) { $0 + $1.utf8.count }
            + songs.count * 24  // 字典开销 / NSArray 元数据估算
        plog("⌚️ pushQueueDigest count=\(songs.count) bytes~\(estimatedBytes) reachable=\(session.isReachable)")

        if session.isReachable && estimatedBytes < 55_000 {
            session.sendMessage(payload, replyHandler: nil, errorHandler: Self.deliverErrorHandler)
        } else {
            // 大队列或不可达: 排队投递。watch 端 didReceiveUserInfo 同样能消化。
            _ = session.transferUserInfo(payload)
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

    /// 从缓存的歌词数组里找当前 time 应该高亮的行。无歌词返回空字符串。
    /// 缓存由 `refreshLyricsCache` 在换歌时异步填充, 这里只 sync 查找。
    private func currentLyricLine(song: Song?, time: TimeInterval) -> String {
        guard let song, song.id == cachedLyricsForSongID, !cachedLyrics.isEmpty else {
            return ""
        }
        var lastIdx = 0
        for (i, line) in cachedLyrics.enumerated() {
            if line.timestamp <= time { lastIdx = i } else { break }
        }
        return cachedLyrics[lastIdx].text
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
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// Reachability 改变 (e.g. watch app 进入前台) ── 立刻推一份最新状态,
    /// 而不是等下一次 1Hz tick。这能让 watch 切回前台立刻看到当前曲目。
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
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
        guard cmd.command == "requestState" else {
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
            await player.next(caller: "watch")
        case "previous":
            await player.previous()
        case "seek":
            if let t = cmd.time { player.seek(to: t) }
        case "requestState":
            lastLibraryHash = 0
            pushIfMeaningfulChange(force: true)
            pushLibraryDigest()
            return
        case "playSong":
            guard let id = cmd.songID, let library else { return }
            if let song = library.songs.first(where: { $0.id == id }) {
                await player.play(song: song, caller: "watch")
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
