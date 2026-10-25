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
    var isLiveStream: Bool = false
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    /// 跟随 iPhone 推过来的 ThemeService accentColor; 默认深海青。
    var accent: Color = Color(red: 0.078, green: 0.490, blue: 0.541)
    var currentLyric: String = ""
    var queueCount: Int = 0
    var coverImage: UIImage?
    /// iPhone 是否在线 (paired + reachable)。不在线时 UI 显示提示。
    var isReachable: Bool = false
    /// 当前播放队列 ── iPhone 端推过来, 跟 iPhone 上"播放列表"一致。
    var queue: [WatchLibrarySong] = []
    /// iPhone 端队列的真实总长度。超大队列被 WatchSessionBridge 按字节截断后,
    /// `queue` 只含前若干首, 这里保留完整数目供 UI 提示。未截断时等于 queue.count。
    var queueTotalCount: Int = 0
    /// iPhone 端队列是否因超过 payload 上限被截断 (只推了前若干首)。
    var queueTruncated: Bool = false

    // MARK: 「更多」页与播放键

    /// 这首能不能标喜欢 (曲库里的歌、播客单集), 和锁屏那颗心同一口径。
    var canLike: Bool = false
    var isLiked: Bool = false
    /// 音乐才有播放方式; 电台和有声内容没有。
    var offersPlaybackModes: Bool = false
    var playbackMode: WatchPlaybackMode = .sequential
    /// 队列不到两首时随机打不开, 轮换时跳过。
    var allowsShuffle: Bool = false
    /// 有声内容的快进快退秒数; 0 表示是音乐, 显示上一首 / 下一首。
    var skipBackwardSeconds: Int = 0
    var skipForwardSeconds: Int = 0
    var skipBackwardSymbol: String = "gobackward.15"
    var skipForwardSymbol: String = "goforward.30"
    /// 电台收藏不止一台时, 上一首 / 下一首就是换台。
    var canSwitchStation: Bool = false
    /// 这首有没有歌词 (间奏时 currentLyric 也是空的, 靠它区分)。
    var hasLyrics: Bool = false
    var nextLyric: String = ""
    /// iPhone 现在把声音放到哪。kind: iphone / headphones / bluetooth / airplay / car / display / cast / other。
    var outputName: String = ""
    var outputKind: String = ""
    /// 主色够亮时播放键上的图标改用深色, 不然白色主题下白底白字。
    var accentIsLight: Bool = false

    var usesSkipIntervals: Bool { skipBackwardSeconds > 0 && skipForwardSeconds > 0 }
    /// 上一首 / 下一首两颗键在不在: 音乐和有声内容都在, 电台只有能换台时在。
    var showsSideTransport: Bool { !isLiveStream || canSwitchStation }

    /// 队列被截断时的提示文案 (例如「仅显示前 300 首, 共 412 首」), 未截断返回 nil。
    /// UI 可直接绑定此属性在列表顶部给出说明, 避免用户误以为队列只有这么多。
    var queueTruncationNotice: String? {
        guard queueTruncated else { return nil }
        return WatchString("ext.watch.queue.truncationNotice", queue.count, queueTotalCount)
    }

    /// 收到 context 时的本地基准时刻, 用来本地外推 currentTime (100ms 一刷)。
    private var sentTimeAnchor: TimeInterval = 0
    private var sentCurrentTime: TimeInterval = 0
    /// iPhone 那边的实际倍速 (有声书常开 1.5、2 倍), 外推进度按它走。
    private var playbackRate: Double = 1

    /// 用户最近一次主动 toggle play/pause 的时刻。1 秒内收到 iPhone 推过来
    /// 跟乐观值矛盾的 isPlaying 时暂不采纳 (大概率是命令到达 iPhone 之前
    /// 飞出的 stale 消息), 等命令处理完真实状态会盖过乐观值。
    private var lastUserToggleAt: Date = .distantPast
    /// 同理: 用户最近一次主动 seek 的时刻。1 秒内 iPhone 推过来的 currentTime
    /// 如果偏离乐观值 >2s 视为 stale, 忽略。
    private var lastUserSeekAt: Date = .distantPast
    /// 喜欢和播放方式同样先改本地, 窗口期内不让在途的旧状态改回去。
    private var lastUserLikeAt: Date = .distantPast
    private var lastUserModeAt: Date = .distantPast
    #if DEBUG
    /// 截图用的演示数据 (启动环境变量 PRIMUSE_WATCH_DEMO), 开着时不让真实连接状态覆盖。
    private(set) var isDemo = false
    /// PRIMUSE_WATCH_DEMO_SCREEN: 启动后直接打开的那一页 (queue / options / seek)。
    private(set) var demoScreen = ""
    #endif

    /// 上次写给 Complication 的曲目与播放状态 ── 表盘跟歌词无关, 进度圈自己走。
    /// 缓存它, 仅当其中任一字段变化时才 write + reload timeline, 避免播放有歌词的歌
    /// 时每隔几秒的歌词行推送都触发一次 reload, 耗尽 watchOS 每日刷新预算。
    private var lastComplicationKey: ComplicationKey?
    /// 上次写给表盘的「这首从哪一刻开始放」(播放中) 或「停在第几秒」(暂停)。
    /// 表盘的进度圈自己走, 只有拖了进度、偏差超过几秒才需要重写。
    private var lastComplicationPosition: TimeInterval?

    private let session: WCSession?

    override init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }
        super.init()
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let demo = environment["PRIMUSE_WATCH_DEMO"] {
            demoScreen = environment["PRIMUSE_WATCH_DEMO_SCREEN"] ?? ""
            applyDemo(demo)
            startTicker()
            return
        }
        #endif
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
                if self.isPlaying, !self.isLoading {
                    let extrapolated = self.sentCurrentTime
                        + (Date().timeIntervalSince1970 - self.sentTimeAnchor) * self.playbackRate
                    self.currentTime = self.isLiveStream
                        ? max(0, extrapolated)
                        : min(self.duration, max(0, extrapolated))
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
        guard canSendRealtimeCommand else {
            requestCurrentState()
            return
        }
        let previousPlaying = isPlaying
        let previousLoading = isLoading
        let previousCurrentTime = currentTime
        let previousSentTime = sentCurrentTime
        let previousAnchor = sentTimeAnchor
        if isLiveStream {
            let wasConnected = isPlaying || isLoading
            isPlaying = !wasConnected
            isLoading = false
        } else {
            isPlaying.toggle()
        }
        lastUserToggleAt = Date()
        if isPlaying {
            // 切到 "playing" 时校准外推基准, 否则 currentTime 会从 0 跳。
            sentCurrentTime = currentTime
            sentTimeAnchor = Date().timeIntervalSince1970
        }
        send(["command": "togglePlayPause"]) { [weak self] in
            guard let self else { return }
            self.isPlaying = previousPlaying
            self.isLoading = previousLoading
            self.currentTime = previousCurrentTime
            self.sentCurrentTime = previousSentTime
            self.sentTimeAnchor = previousAnchor
        }
    }
    func next() {
        guard showsSideTransport else { return }
        send(["command": "next"])
    }
    func previous() {
        guard showsSideTransport else { return }
        send(["command": "previous"])
    }
    func seek(to time: TimeInterval) {
        guard !isLiveStream else { return }
        guard canSendRealtimeCommand else {
            requestCurrentState()
            return
        }
        let rollback = moveOptimistically(to: time)
        send(["command": "seek", "time": currentTime], rollback: rollback)
    }

    /// 有声内容的快退 / 快进。iPhone 按同一套规则落点, 回推后对齐。
    func skipBackward() { skip(by: -skipBackwardSeconds, command: "skipBackward") }
    func skipForward() { skip(by: skipForwardSeconds, command: "skipForward") }

    private func skip(by seconds: Int, command: String) {
        guard usesSkipIntervals, !isLiveStream else { return }
        guard canSendRealtimeCommand else {
            requestCurrentState()
            return
        }
        let rollback = moveOptimistically(to: currentTime + TimeInterval(seconds))
        send(["command": command], rollback: rollback)
    }

    /// 先把本地进度挪过去, 返回发送失败时的还原。
    private func moveOptimistically(to time: TimeInterval) -> @MainActor @Sendable () -> Void {
        let previousTime = currentTime
        let previousSentTime = sentCurrentTime
        let previousAnchor = sentTimeAnchor
        let clamped = min(max(0, time), duration)
        lastUserSeekAt = Date()
        currentTime = clamped
        sentCurrentTime = clamped
        sentTimeAnchor = Date().timeIntervalSince1970
        return { [weak self] in
            guard let self else { return }
            self.currentTime = previousTime
            self.sentCurrentTime = previousSentTime
            self.sentTimeAnchor = previousAnchor
        }
    }

    /// 发「设成喜欢 / 取消」而不是「切换」, 重发也不会改回去; 带上 songID, 期间换歌 iPhone 就不动。
    func setLiked(_ liked: Bool) {
        guard canLike else { return }
        guard canSendRealtimeCommand else {
            requestCurrentState()
            return
        }
        let previous = isLiked
        isLiked = liked
        lastUserLikeAt = Date()
        send(["command": "setLiked", "liked": liked, "songID": songID]) { [weak self] in
            self?.isLiked = previous
        }
    }

    /// 和 iPhone 队列页「播放方式」键一样轮换: 顺序 → 列表循环 → 单曲循环 → 随机。
    func cyclePlaybackMode() {
        guard offersPlaybackModes else { return }
        guard canSendRealtimeCommand else {
            requestCurrentState()
            return
        }
        let previous = playbackMode
        let target = playbackMode.next(allowsShuffle: allowsShuffle)
        playbackMode = target
        lastUserModeAt = Date()
        send(["command": "setPlaybackMode", "mode": target.rawValue]) { [weak self] in
            self?.playbackMode = previous
        }
    }
    func requestCurrentState() { send(["command": "requestState"]) }
    func play(songID: String) { send(["command": "playSong", "songID": songID]) }

    private var canSendRealtimeCommand: Bool {
        guard let session else { return false }
        return session.activationState == .activated && session.isReachable
    }

    private func send(
        _ message: [String: Any],
        rollback: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let session, session.activationState == .activated else {
            rollback?()
            return
        }
        if session.isReachable {
            session.sendMessage(
                message,
                replyHandler: nil,
                errorHandler: Self.makeSendErrorHandler(store: self, rollback: rollback)
            )
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
            rollback?()
            print("⌚️ drop \(cmd) — iPhone unreachable")
        }
    }

    /// WCSession 会在后台 queue 调用 errorHandler。handler 本体必须在
    /// nonisolated 上下文形成, 再显式切回 MainActor 访问 store 状态。
    nonisolated private static func makeSendErrorHandler(
        store: WatchPlayerStore,
        rollback: (@MainActor @Sendable () -> Void)?
    ) -> @Sendable (Error) -> Void {
        { [weak store] error in
            print("⌚️ sendMessage error: \(error.localizedDescription)")
            Task { @MainActor in
                rollback?()
                store?.requestCurrentState()
            }
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.setReachable(reachable)
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
        // Wave B 的截断退路: 超大队列被按字节截断后, iPhone 端带上完整总数与
        // truncated 标记。缺省 (旧 payload / 未截断) 时 total 落到收到的条数。
        let total = message["totalCount"] as? Int ?? songs.count
        let truncated = message["truncated"] as? Bool ?? false
        Task { @MainActor in
            if kind == "queue" {
                self.queue = songs
                self.queueTotalCount = total
                self.queueTruncated = truncated
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
            self.setReachable(reachable)
            // 跟 iPhone 重新接通, 主动拉一次最新状态。
            if reachable { self.requestCurrentState() }
        }
    }

    private func setReachable(_ reachable: Bool) {
        #if DEBUG
        if isDemo { return }
        #endif
        isReachable = reachable
    }

    @MainActor
    private func applyContext(_ snap: ContextSnapshot, cover: Data?) {
        #if DEBUG
        if isDemo { return }
        #endif
        let now = Date()
        let songChanged = snap.songID != songID
        // 换歌跨越乐观窗口 ── 用户操作前后是不同曲目, 一切重新跟随 iPhone。
        if songChanged {
            coverImage = nil
            lastUserToggleAt = .distantPast
            lastUserSeekAt = .distantPast
            lastUserLikeAt = .distantPast
            lastUserModeAt = .distantPast
        }

        songID = snap.songID
        title = snap.title
        artist = snap.artist
        album = snap.album
        isLoading = snap.isLoading
        isLiveStream = snap.isLiveStream
        duration = snap.duration
        queueCount = snap.queueCount
        currentLyric = snap.currentLyric
        nextLyric = snap.nextLyric
        hasLyrics = snap.hasLyrics
        accent = Color(red: snap.accentR, green: snap.accentG, blue: snap.accentB)
        accentIsLight = Self.isLight(r: snap.accentR, g: snap.accentG, b: snap.accentB)
        canLike = snap.canLike
        offersPlaybackModes = snap.offersPlaybackModes
        allowsShuffle = snap.allowsShuffle
        skipBackwardSeconds = snap.skipBackwardSeconds
        skipForwardSeconds = snap.skipForwardSeconds
        if !snap.skipBackwardSymbol.isEmpty { skipBackwardSymbol = snap.skipBackwardSymbol }
        if !snap.skipForwardSymbol.isEmpty { skipForwardSymbol = snap.skipForwardSymbol }
        canSwitchStation = snap.canSwitchStation
        outputName = snap.outputName
        outputKind = snap.outputKind
        playbackRate = snap.playbackRate

        // 喜欢偶尔要等 iPhone 曲库就绪才落地, 窗口放宽到 1.5 秒。
        if !(now.timeIntervalSince(lastUserLikeAt) < 1.5 && snap.isLiked != isLiked) {
            isLiked = snap.isLiked
        }
        let snapMode = WatchPlaybackMode(rawValue: snap.playbackMode) ?? .sequential
        if !(now.timeIntervalSince(lastUserModeAt) < 1.5 && snapMode != playbackMode) {
            playbackMode = snapMode
        }

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

        var coverChanged = false
        if let cover {
            if cover.isEmpty {
                coverImage = nil
                coverChanged = true
            } else if let img = UIImage(data: cover) {
                coverImage = img
                coverChanged = true
            }
        }

        // 同步给表盘 Complication ── 写共享 UserDefaults + reload timeline。
        // 只在表盘显示的东西变了才写 + reload (曲目、播放状态、时长、封面, 以及拖进度
        // 造成的位置跳变); 歌词等无关字段的频繁推送不触发, 避免耗尽 watchOS 每日刷新预算。
        // reloadTimelines(ofKind:) 只刷本 Complication, 比 reloadAllTimelines 范围更小。
        // 当 App Group 没在 dev portal 配好时, UserDefaults(suiteName:) 会
        // 返回 nil, write 内部静默失败, 不影响 watch app 主体功能。
        let complicationKey = ComplicationKey(
            songID: songID, title: title, artist: artist,
            isPlaying: isPlaying, isLiveStream: isLiveStream,
            durationSeconds: Int(duration.rounded()),
            rateThousandths: Int((playbackRate * 1000).rounded())
        )
        // 播放中比的是「这首从哪一刻开始放」, 倍速下要按倍速折回墙钟, 不然每次推送都像跳了进度。
        let position = isPlaying
            ? Date().timeIntervalSince1970 - currentTime / playbackRate
            : currentTime
        let positionJumped = lastComplicationPosition.map { abs($0 - position) > 3 } ?? true
        if coverChanged {
            SharedNowPlayingState.writeCover(cover, songID: songID)
        }
        if complicationKey != lastComplicationKey || positionJumped || coverChanged {
            lastComplicationKey = complicationKey
            lastComplicationPosition = position
            SharedNowPlayingState.write(
                songID: songID, title: title, artist: artist,
                isPlaying: isPlaying, isLiveStream: isLiveStream,
                duration: duration, elapsed: currentTime, playbackRate: playbackRate,
                accent: (snap.accentR, snap.accentG, snap.accentB)
            )
            WidgetCenter.shared.reloadTimelines(ofKind: SharedNowPlayingState.widgetKind)
        }
    }

    /// Complication 关心的字段 ── 用来去重重复推送, 只有它变了才刷新表盘。
    private struct ComplicationKey: Equatable {
        let songID: String
        let title: String
        let artist: String
        let isPlaying: Bool
        let isLiveStream: Bool
        let durationSeconds: Int
        let rateThousandths: Int
    }

    /// 相对亮度超过 0.6 就算浅色 (sRGB 近似, 够用来挑图标颜色)。
    static func isLight(r: Double, g: Double, b: Double) -> Bool {
        0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6
    }

    /// 声音输出到哪的图标。AirPods 一类按系统给的设备名再细分。
    var outputSymbol: String {
        let name = outputName.lowercased()
        switch outputKind {
        case "iphone": return "iphone"
        case "headphones": return "headphones"
        case "bluetooth":
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("beats") { return "beats.headphones" }
            return "headphones"
        case "airplay": return name.contains("homepod") ? "homepod.fill" : "airplayaudio"
        case "car": return "car.fill"
        case "display": return "tv"
        case "cast": return "tv.and.hifispeaker.fill"
        default: return "speaker.wave.2.fill"
        }
    }

    /// iPhone 自己的扬声器显示成「iPhone」, 其余用系统给的设备名。
    var outputDisplayName: String {
        if outputKind == "iphone" || outputName.isEmpty { return "iPhone" }
        return outputName
    }
}

/// iPhone 队列页「播放方式」那四种, 原始值与 PrimuseKit `PlaybackOrderMode` 一致
/// (手表不编 PrimuseKit, 这里照抄一份轮换顺序)。
enum WatchPlaybackMode: String, CaseIterable, Sendable {
    case sequential
    case repeatAll
    case repeatOne
    case shuffle

    func next(allowsShuffle: Bool) -> WatchPlaybackMode {
        let order = Self.allCases
        var index = order.firstIndex(of: self) ?? 0
        repeat {
            index = (index + 1) % order.count
        } while order[index] == .shuffle && !allowsShuffle
        return order[index]
    }

    var symbolName: String {
        switch self {
        case .sequential: "list.number"
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        case .shuffle: "shuffle"
        }
    }

    var titleKey: String {
        switch self {
        case .sequential: "ext.watch.mode.sequential"
        case .repeatAll: "ext.watch.mode.repeatAll"
        case .repeatOne: "ext.watch.mode.repeatOne"
        case .shuffle: "ext.watch.mode.shuffle"
        }
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
    let isLiveStream: Bool
    let duration: TimeInterval
    let currentTime: TimeInterval
    let currentTimeAnchor: TimeInterval
    let queueCount: Int
    let currentLyric: String
    let accentR: Double
    let accentG: Double
    let accentB: Double
    let canLike: Bool
    let isLiked: Bool
    let offersPlaybackModes: Bool
    let playbackMode: String
    let allowsShuffle: Bool
    let skipBackwardSeconds: Int
    let skipForwardSeconds: Int
    let skipBackwardSymbol: String
    let skipForwardSymbol: String
    let canSwitchStation: Bool
    let hasLyrics: Bool
    let nextLyric: String
    let outputName: String
    let outputKind: String
    let playbackRate: Double

    init(_ ctx: [String: Any]) {
        songID = ctx["songID"] as? String ?? ""
        title = ctx["title"] as? String ?? ""
        artist = ctx["artist"] as? String ?? ""
        album = ctx["album"] as? String ?? ""
        isPlaying = ctx["isPlaying"] as? Bool ?? false
        isLoading = ctx["isLoading"] as? Bool ?? false
        isLiveStream = ctx["isLiveStream"] as? Bool ?? false
        duration = ctx["duration"] as? Double ?? 0
        currentTime = ctx["currentTime"] as? Double ?? 0
        currentTimeAnchor = ctx["currentTimeAnchor"] as? Double ?? Date().timeIntervalSince1970
        queueCount = ctx["queueCount"] as? Int ?? 0
        currentLyric = ctx["currentLyric"] as? String ?? ""
        accentR = ctx["accentR"] as? Double ?? 0.078
        accentG = ctx["accentG"] as? Double ?? 0.490
        accentB = ctx["accentB"] as? Double ?? 0.541
        // 以下是后加的键, 旧版 iPhone 不带时按「没有这项」处理。
        canLike = ctx["canLike"] as? Bool ?? false
        isLiked = ctx["isLiked"] as? Bool ?? false
        offersPlaybackModes = ctx["offersPlaybackModes"] as? Bool ?? false
        playbackMode = ctx["playbackMode"] as? String ?? ""
        allowsShuffle = ctx["allowsShuffle"] as? Bool ?? false
        skipBackwardSeconds = ctx["skipBackwardSeconds"] as? Int ?? 0
        skipForwardSeconds = ctx["skipForwardSeconds"] as? Int ?? 0
        skipBackwardSymbol = ctx["skipBackwardSymbol"] as? String ?? ""
        skipForwardSymbol = ctx["skipForwardSymbol"] as? String ?? ""
        canSwitchStation = ctx["canSwitchStation"] as? Bool ?? false
        // 旧版 iPhone 不报这项: 有当前行就当作有歌词。
        hasLyrics = ctx["hasLyrics"] as? Bool ?? !currentLyric.isEmpty
        nextLyric = ctx["nextLyric"] as? String ?? ""
        outputName = ctx["outputName"] as? String ?? ""
        outputKind = ctx["outputKind"] as? String ?? ""
        let rate = ctx["playbackRate"] as? Double ?? 1
        playbackRate = rate.isFinite && rate > 0 ? rate : 1
    }
}

#if DEBUG
extension WatchPlayerStore {
    /// 截图用的演示状态: PRIMUSE_WATCH_DEMO = music / lyrics / lyricsLong / audiobook / radio / offline / empty。
    /// 不连 iPhone, 不发任何命令以外的消息 (按键照常走 send, 模拟器里没有配对的 iPhone 就丢掉)。
    fileprivate func applyDemo(_ kind: String) {
        isDemo = true
        isReachable = kind != "offline"
        guard kind != "empty", kind != "offline" else { return }

        songID = "demo-current"
        isPlaying = true
        accent = Color(red: 0.86, green: 0.36, blue: 0.42)
        outputKind = "bluetooth"
        outputName = "AirPods Pro"
        queue = (1...14).map { index in
            WatchLibrarySong(
                id: index == 4 ? "demo-current" : "demo-\(index)",
                title: index == 4 ? "Midnight City Lights" : "Demo Track \(index)",
                artist: "Demo Artist"
            )
        }
        queueTotalCount = queue.count

        switch kind {
        case "audiobook":
            title = "Chapter 3: The Long Road Home"
            artist = "Demo Narrator"
            duration = 3_725
            sentCurrentTime = 1_284
            skipBackwardSeconds = 15
            skipForwardSeconds = 30
            skipBackwardSymbol = "gobackward.15"
            skipForwardSymbol = "goforward.30"
            canLike = false
        case "radio":
            title = "Demo FM 101.7"
            artist = ""
            isLiveStream = true
            canSwitchStation = true
            sentCurrentTime = 312
        default:
            title = "Midnight City Lights"
            artist = "Demo Artist"
            duration = 241
            sentCurrentTime = 87
            canLike = true
            isLiked = true
            offersPlaybackModes = true
            playbackMode = .repeatAll
            allowsShuffle = true
            hasLyrics = true
            currentLyric = kind == "lyricsLong"
                ? "Every street light hums along with the song we never wrote, and every window on the avenue answers with a chorus only the night can hear"
                : "Every street light hums along with the song we never wrote"
            nextLyric = "And the city keeps the time for us"
            if kind == "lyrics" || kind == "lyricsLong" {
                UserDefaults.standard.set(true, forKey: "watch.nowPlaying.showsLyrics")
            } else {
                UserDefaults.standard.removeObject(forKey: "watch.nowPlaying.showsLyrics")
            }
        }
        currentTime = sentCurrentTime
        sentTimeAnchor = Date().timeIntervalSince1970
        coverImage = Self.demoCover(accent: accent)
    }

    private static func demoCover(accent: Color) -> UIImage? {
        let renderer = ImageRenderer(content:
            ZStack {
                LinearGradient(
                    colors: [accent, Color(red: 0.18, green: 0.12, blue: 0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 60, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 160, height: 160)
        )
        renderer.scale = 2
        return renderer.uiImage
    }
}
#endif
