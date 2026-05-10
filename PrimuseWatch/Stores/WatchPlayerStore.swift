import Foundation
@preconcurrency import WatchConnectivity
import SwiftUI
import WidgetKit

/// Watch 端的播放状态镜像。
///
/// 通过 WatchConnectivity 跟 iPhone 端的 `WatchSessionBridge` 配对:
/// - 接收 `sendMessage` (包含状态字段 + 可选封面 JPEG)
/// - 接收 `applicationContext` (latest-only 快照, 不可达时的 fallback)
/// - 接收 `userInfo` (库列表 / 旧封面降级路径)
/// - 通过 `sendMessage` 发控制指令 (toggle / next / prev / seek / playSong)
@MainActor
@Observable
final class WatchPlayerStore: NSObject, WCSessionDelegate {
    var songID: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    var isLoading: Bool = false
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    /// 跟随 iPhone 推过来的 ThemeService accentColor; 默认品牌紫。
    var accent: Color = Color(red: 0.392, green: 0.318, blue: 0.976)
    var currentLyric: String = ""
    var queueCount: Int = 0
    var coverImage: UIImage?
    /// iPhone 是否在线 (paired + reachable)。不在线时 UI 显示提示。
    var isReachable: Bool = false
    /// 当前播放队列 ── iPhone 端推过来, 跟 iPhone 上"播放列表"一致。
    var queue: [WatchLibrarySong] = []

    /// 收到 context 时的本地基准时刻, 用来本地外推 currentTime (100ms 一刷)。
    private var sentTimeAnchor: TimeInterval = 0
    private var sentCurrentTime: TimeInterval = 0

    /// 用户最近一次主动 toggle play/pause 的时刻。1 秒内收到 iPhone 推过来
    /// 跟乐观值矛盾的 isPlaying 时暂不采纳 (大概率是命令到达 iPhone 之前
    /// 飞出的 stale 消息), 等命令处理完真实状态会盖过乐观值。
    private var lastUserToggleAt: Date = .distantPast
    /// 同理: 用户最近一次主动 seek 的时刻。1 秒内 iPhone 推过来的 currentTime
    /// 如果偏离乐观值 >2s 视为 stale, 忽略。
    private var lastUserSeekAt: Date = .distantPast

    private let session: WCSession?

    override init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }
        super.init()
        session?.delegate = self
        session?.activate()
        startTicker()
    }

    /// 100ms 外推 currentTime ── iPhone 端只在状态真变时才推, 中间的时间
    /// 流逝完全靠这里基于 sentTimeAnchor 计算。loading 期间 player 实际
    /// 不动, 所以也不外推 (避免显示比实际靠前)。
    private func startTicker() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                if self.isPlaying, !self.isLoading, self.duration > 0 {
                    let extrapolated = self.sentCurrentTime + Date().timeIntervalSince1970 - self.sentTimeAnchor
                    self.currentTime = min(self.duration, max(0, extrapolated))
                }
            }
        }
    }

    /// 进度条 0...1。duration 为 0 时返回 0 避免 NaN。
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var hasSong: Bool { !songID.isEmpty }

    // MARK: - Commands → iPhone

    /// 乐观更新 ── 点击立即翻转本地 isPlaying, 让按钮图标 / 进度外推
    /// 立刻响应。iPhone 处理完命令后会回推真实状态, 200ms 内对齐;
    /// 万一命令失败, 1 秒窗口期过后 iPhone 推送会自动校正。
    func togglePlayPause() {
        isPlaying.toggle()
        lastUserToggleAt = Date()
        if isPlaying {
            // 切到 "playing" 时校准外推基准, 否则 currentTime 会从 0 跳。
            sentCurrentTime = currentTime
            sentTimeAnchor = Date().timeIntervalSince1970
        }
        send(["command": "togglePlayPause"])
    }
    func next() { send(["command": "next"]) }
    func previous() { send(["command": "previous"]) }
    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), duration)
        lastUserSeekAt = Date()
        currentTime = clamped
        sentCurrentTime = clamped
        sentTimeAnchor = Date().timeIntervalSince1970
        send(["command": "seek", "time": clamped])
    }
    func requestCurrentState() { send(["command": "requestState"]) }
    func play(songID: String) { send(["command": "playSong", "songID": songID]) }

    private func send(_ message: [String: Any]) {
        guard let session, session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: Self.sendErrorHandler)
            return
        }
        // iPhone 不可达 ── 控制类指令必须实时, 排队几小时后才执行的暂停 /
        // 切歌 / 拖进度对用户是惊吓而非帮助; 这里直接丢弃, 重新接通后用户
        // 重新点一次按钮即可。
        // 只有 requestState 这种幂等查询安全排队, 因为它"任意时刻拉最新状态"
        // 总是有意义的, 而且会在双方重新可达时被自然替换。
        let cmd = message["command"] as? String ?? ""
        if cmd == "requestState" {
            session.transferUserInfo(message)
        } else {
            print("⌚️ drop \(cmd) — iPhone unreachable")
        }
    }

    /// 静态 @Sendable 闭包 ── WCSession 在后台 queue 调用 errorHandler,
    /// 不能捕获 main actor 隔离的 self / store 状态, 否则 Swift 6 会 trap。
    nonisolated static let sendErrorHandler: @Sendable (Error) -> Void = { error in
        print("⌚️ sendMessage error: \(error.localizedDescription)")
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            // 启动后立刻问 iPhone 拿一次最新状态。
            self.requestCurrentState()
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        // 即时投递路径。两种 payload 都可能走 sendMessage:
        //   - 状态 (含可选 cover): {"type": "state", ...}
        //   - 库列表: {"libraryKind": "recentlyPlayed", "songIDs": [...]}
        if let kind = message["libraryKind"] as? String {
            applyLibraryUserInfo(kind: kind, message: message)
            return
        }
        let snap = ContextSnapshot(message)
        let cover = message["coverJPEG"] as? Data
        Task { @MainActor in
            self.applyContext(snap, cover: cover)
        }
    }

    nonisolated private func applyLibraryUserInfo(kind: String, message: [String: Any]) {
        let ids = message["songIDs"] as? [String] ?? []
        let titles = message["titles"] as? [String] ?? []
        let artists = message["artists"] as? [String] ?? []
        let songs = zip(zip(ids, titles), artists).map { pair, artist in
            WatchLibrarySong(id: pair.0, title: pair.1, artist: artist)
        }
        Task { @MainActor in
            if kind == "queue" {
                self.queue = songs
            }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        // Fallback 路径 ── watch 不可达时 iPhone 改用 applicationContext 留快照。
        let snap = ContextSnapshot(applicationContext)
        let cover = applicationContext["coverJPEG"] as? Data
        Task { @MainActor in
            self.applyContext(snap, cover: cover)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // 库列表 fallback 投递, iPhone 不可达时走 transferUserInfo 队列。
        if let kind = userInfo["libraryKind"] as? String {
            applyLibraryUserInfo(kind: kind, message: userInfo)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            // 跟 iPhone 重新接通, 主动拉一次最新状态。
            if reachable { self.requestCurrentState() }
        }
    }

    @MainActor
    private func applyContext(_ snap: ContextSnapshot, cover: Data?) {
        let now = Date()
        let songChanged = snap.songID != songID
        // 换歌跨越乐观窗口 ── 用户操作前后是不同曲目, 一切重新跟随 iPhone。
        if songChanged {
            coverImage = nil
            lastUserToggleAt = .distantPast
            lastUserSeekAt = .distantPast
        }

        songID = snap.songID
        title = snap.title
        artist = snap.artist
        album = snap.album
        isLoading = snap.isLoading
        duration = snap.duration
        queueCount = snap.queueCount
        currentLyric = snap.currentLyric
        accent = Color(red: snap.accentR, green: snap.accentG, blue: snap.accentB)

        // isPlaying 在 toggle 窗口期内拒绝矛盾值 ── 等 iPhone 处理完命令
        // 真实状态自然推过来, 否则会 stale 消息覆盖乐观值后又被纠正, 看到
        // 按钮闪烁。
        let inToggleWindow = now.timeIntervalSince(lastUserToggleAt) < 1.0
        if !(inToggleWindow && snap.isPlaying != isPlaying) {
            isPlaying = snap.isPlaying
        }

        // currentTime 在 seek 窗口期内拒绝偏离乐观值 >2s 的推送 (stale)。
        let inSeekWindow = now.timeIntervalSince(lastUserSeekAt) < 1.0
        let timeDiff = abs(snap.currentTime - currentTime)
        if !(inSeekWindow && timeDiff > 2.0) {
            sentCurrentTime = snap.currentTime
            sentTimeAnchor = snap.currentTimeAnchor
            currentTime = snap.currentTime
        }

        if let cover {
            if cover.isEmpty {
                coverImage = nil
            } else if let img = UIImage(data: cover) {
                coverImage = img
            }
        }

        // 同步给表盘 Complication ── 写共享 UserDefaults + reload timeline。
        // reloadAllTimelines 在 watchOS 上有节流, 一秒内多次调用会自动合并。
        // 当 App Group 没在 dev portal 配好时, UserDefaults(suiteName:) 会
        // 返回 nil, write 内部静默失败, 不影响 watch app 主体功能。
        SharedNowPlayingState.write(
            songID: songID, title: title, artist: artist, isPlaying: isPlaying
        )
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// 简化的歌曲信息 ── 只够 Watch 列表显示和回点 iPhone 播放。
struct WatchLibrarySong: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
}

/// Sendable 状态快照 ── 把 WCSession 传过来的 `[String: Any]` 在 nonisolated
/// 上下文里立刻解包成具体类型, 再跨 actor 投递。Swift 6 严格并发下 [String:
/// Any] 不是 Sendable, 直接捕获会编译报错。
struct ContextSnapshot: Sendable {
    let songID: String
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let isLoading: Bool
    let duration: TimeInterval
    let currentTime: TimeInterval
    let currentTimeAnchor: TimeInterval
    let queueCount: Int
    let currentLyric: String
    let accentR: Double
    let accentG: Double
    let accentB: Double

    init(_ ctx: [String: Any]) {
        songID = ctx["songID"] as? String ?? ""
        title = ctx["title"] as? String ?? ""
        artist = ctx["artist"] as? String ?? ""
        album = ctx["album"] as? String ?? ""
        isPlaying = ctx["isPlaying"] as? Bool ?? false
        isLoading = ctx["isLoading"] as? Bool ?? false
        duration = ctx["duration"] as? Double ?? 0
        currentTime = ctx["currentTime"] as? Double ?? 0
        currentTimeAnchor = ctx["currentTimeAnchor"] as? Double ?? Date().timeIntervalSince1970
        queueCount = ctx["queueCount"] as? Int ?? 0
        currentLyric = ctx["currentLyric"] as? String ?? ""
        accentR = ctx["accentR"] as? Double ?? 0.392
        accentG = ctx["accentG"] as? Double ?? 0.318
        accentB = ctx["accentB"] as? Double ?? 0.976
    }
}
