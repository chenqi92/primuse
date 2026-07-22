import Foundation
import PrimuseKit

/// Scrobble 总入口 — AudioPlayerService 在播放进度过阈值时调用,
/// 由本服务分发给所有启用的 provider, 失败的进队列后台重试。
@MainActor
@Observable
final class ScrobbleService {
    static let shared = ScrobbleService()

    /// 当前正在播放的歌曲信息 (用于 50%/4min 触发判断)。
    /// AudioPlayerService 切歌时会 reset。
    private var currentSession: PlaySession?
    /// 当前播放的 Song —— 服务端源(Subsonic/Navidrome)回报要按源路由, 需要
    /// song.sourceID + filePath, 而 ScrobbleEntry 不带这些。
    private var currentSong: Song?

    /// 服务端曲库源回报钩子。由 AudioPlayerService 在启动时接上 SourceManager:
    /// `(song, submission) -> 调 sourceManager.reportServerScrobble`。非服务端
    /// 源自动 no-op。独立于全局 Last.fm/ListenBrainz 开关 —— Navidrome 自己也
    /// 要记播放次数。
    var serverScrobbleHandler: ((_ song: Song, _ submission: Bool) -> Void)?
    /// 失败队列, 持久化到 UserDefaults。
    private var queue: [QueuedEntry] = []
    private static let queueKey = "primuse.scrobble.queue.v1"
    private static let recentReportsKey = "primuse.scrobble.recentReports.v1"
    private static let recentReportsLimit = 12
    private(set) var recentReports: [RecentReport] = []
    /// 后台 retry task — settings 变化或网络恢复时启动。
    private var retryTask: Task<Void, Never>?

    /// Last.fm 50%/240s 规则 — 听到这个进度才计入 history。
    private static let listenedThresholdRatio: Double = 0.5
    private static let listenedThresholdSeconds: Double = 240
    /// 太短的歌不 scrobble (< 30s) — 协议规范。
    private static let minTrackDurationSec: Double = 30

    /// 失败队列条目 — track entry + 已尝试次数 + 哪些 provider 还没成功。
    private struct QueuedEntry: Codable {
        var entry: ScrobbleEntry
        /// 还需要发送给哪些 provider (成功一个移除一个, 全清空就丢出队列)。
        var pendingProviders: Set<ScrobbleProviderID>
        var attempts: Int
        /// 下次允许重试的时间 — 失败后指数退避, 避免持续打服务端。
        var nextRetryAt: TimeInterval
    }

    struct RecentReport: Codable, Identifiable, Equatable, Sendable {
        let entry: ScrobbleEntry
        let provider: ScrobbleProviderID
        let submittedAt: Date

        var id: String {
            "\(provider.rawValue)-\(entry.songID)-\(entry.startedAt)-\(Int(submittedAt.timeIntervalSince1970))"
        }
    }

    /// 当前播放的会话状态, 决定何时触发 scrobble。
    private struct PlaySession {
        var entry: ScrobbleEntry
        let startedAtMonotonic: TimeInterval
        var hasSentNowPlaying: Bool
        var hasScrobbled: Bool
        /// 真实累计收听时长 (秒) —— 每个 tick 加固定增量, 跟 song.currentTime 解耦,
        /// 这样 seek 到歌曲后段不会让一秒没听就触发 scrobble。新歌新建 session 自动归零。
        var listenedSeconds: TimeInterval = 0
    }

    private init() {
        loadQueue()
        loadRecentReports()
        // Settings 变化 (启用 provider 切换) 时尝试 flush 队列。
        NotificationCenter.default.addObserver(
            forName: .scrobbleSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRetry(reason: "settings changed") }
        }
        // 上次会话遗留的待补报条目 —— 启动即调度, 否则要等下一次 settings 变化 /
        // 新失败 / 用户手动 retry 才会动 (离线听歌后重启 app 的典型场景)。
        if !queue.isEmpty { scheduleRetry(reason: "launch") }
    }

    // MARK: - Public API (AudioPlayerService 调用)

    /// 用户开始播放新歌 — 创建 session, 同步发 nowPlaying。
    func handlePlaybackStarted(song: Song) {
        currentSong = song
        let entry = makeEntry(from: song)
        // session 总是建立 —— 它同时驱动服务端源(Subsonic)的 submission 阈值,
        // 后者独立于全局 scrobble 开关。全局 provider 的 nowPlaying/submit 仍各自
        // 在 active providers 为空时 no-op。
        currentSession = PlaySession(
            entry: entry,
            startedAtMonotonic: Self.monotonicNow(),
            hasSentNowPlaying: false,
            hasScrobbled: false
        )

        // 服务端源回报 "正在播放"(submission=false)。非服务端源在 handler 内 no-op。
        serverScrobbleHandler?(song, false)

        let settings = ScrobbleSettingsStore.shared
        guard settings.isEnabled, !settings.enabledProviders.isEmpty else { return }
        if settings.sendNowPlaying {
            currentSession?.hasSentNowPlaying = true
            sendNowPlayingAcrossProviders(entry: entry)
        }
    }

    /// AVPlayer may only discover a standalone music video's duration after
    /// playback has started. Refresh the active session so the normal
    /// 50%/240s threshold can still trigger for that first play.
    func handlePlaybackDurationResolved(songID: String, duration: TimeInterval) {
        guard duration.isFinite, duration > 0,
              var session = currentSession,
              session.entry.songID == songID else { return }

        let durationSec = duration.finiteInt()
        guard durationSec > 0, session.entry.durationSec != durationSec else { return }

        let old = session.entry
        session.entry = ScrobbleEntry(
            songID: old.songID,
            title: old.title,
            artist: old.artist,
            album: old.album,
            albumArtist: old.albumArtist,
            durationSec: durationSec,
            trackNumber: old.trackNumber,
            startedAt: old.startedAt
        )
        currentSession = session

        if var song = currentSong, song.id == songID {
            song.duration = duration
            currentSong = song
        }
    }

    /// 播放进度更新 (AudioPlayerService 每个 tick 触发) — 判断是否到 scrobble 阈值。
    /// playedDelta: 距上次 tick 实际经过的收听时长 (real wallclock 增量, 不是
    /// song.currentTime)。service 内部累加, 避免用户 seek 到歌曲后段时一秒没听
    /// 就被当成已收听 50% 而误上报 (污染 Last.fm/ListenBrainz/Navidrome 播放次数)。
    func handleProgressTick(playedDelta: TimeInterval) {
        guard var session = currentSession, !session.hasScrobbled else { return }
        session.listenedSeconds += max(0, playedDelta)
        currentSession = session
        let durationSec = Double(session.entry.durationSec ?? 0)
        guard durationSec >= Self.minTrackDurationSec else { return }
        let half = durationSec * Self.listenedThresholdRatio
        let threshold = min(half, Self.listenedThresholdSeconds)
        guard session.listenedSeconds >= threshold else { return }

        session.hasScrobbled = true
        currentSession = session
        // 服务端源回报 "已播放"(submission=true) —— 计入 Navidrome 播放次数/历史。
        if let song = currentSong {
            serverScrobbleHandler?(song, true)
        }
        // 全局 provider(Last.fm/ListenBrainz)—— activeProviders 为空时自动 no-op。
        scrobbleAcrossProviders(entry: session.entry)
    }

    /// 切歌 / 用户手动停止 — 清 session, 不补 scrobble (因为听不够 50% 不该计入)。
    func handlePlaybackStopped() {
        currentSession = nil
        currentSong = nil
    }

    /// 当前队列长度 — Settings UI 显示。
    var pendingCount: Int { queue.count }

    /// 用户手动触发 retry (Settings UI 按钮)。
    func retryPendingNow() {
        // 把所有条目 nextRetryAt 拉到现在, 然后立即触发 retry loop。
        let now = Date().timeIntervalSince1970
        for i in queue.indices { queue[i].nextRetryAt = now }
        scheduleRetry(reason: "user manual retry")
    }

    /// 完全清空失败队列 — 用户在 Settings 里点 "Clear pending"。
    func clearQueue() {
        queue.removeAll()
        saveQueue()
    }

    // MARK: - Internal: dispatch + queue

    /// Now Playing 同步发送 — 失败不入队 (now playing 是实时状态, 没必要补)。
    private func sendNowPlayingAcrossProviders(entry: ScrobbleEntry) {
        let providers = activeProviders()
        guard !providers.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            try await provider.sendNowPlaying(entry)
                        } catch {
                            plog("🎵 scrobble nowPlaying [\(provider.id.displayName)] failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// Scrobble 提交 — 每个 provider 单独 try, 失败的进队列后续重试。
    private func scrobbleAcrossProviders(entry: ScrobbleEntry) {
        let providers = activeProviders()
        guard !providers.isEmpty else { return }
        Task {
            var failed: Set<ScrobbleProviderID> = []
            var submitted: [ScrobbleProviderID] = []
            await withTaskGroup(of: (ScrobbleProviderID, Bool, Bool).self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            try await provider.submitListens([entry])
                            plog("🎵 scrobble [\(provider.id.displayName)] OK: \(entry.title)")
                            return (provider.id, true, true)
                        } catch let err as ScrobbleError {
                            plog("🎵 scrobble [\(provider.id.displayName)] failed (\(err.isRetryable ? "queued" : "dropped")): \(err.localizedDescription)")
                            return (provider.id, !err.isRetryable, false)  // 不可重试 = 视作 "完成", 别留队列里
                        } catch {
                            plog("🎵 scrobble [\(provider.id.displayName)] failed (queued): \(error.localizedDescription)")
                            return (provider.id, false, false)
                        }
                    }
                }
                for await (pid, done, didSubmit) in group {
                    if !done { failed.insert(pid) }
                    if didSubmit { submitted.append(pid) }
                }
            }
            await MainActor.run {
                for provider in submitted {
                    self.recordRecent(entry: entry, provider: provider)
                }
                if !failed.isEmpty { self.enqueue(entry: entry, providers: failed) }
            }
        }
    }

    private func enqueue(entry: ScrobbleEntry, providers: Set<ScrobbleProviderID>) {
        // 同 song + 同 startedAt 的去重 (理论不会重复 scrobble 同一条, 但保险)。
        if let idx = queue.firstIndex(where: {
            $0.entry.songID == entry.songID && $0.entry.startedAt == entry.startedAt
        }) {
            queue[idx].pendingProviders.formUnion(providers)
        } else {
            queue.append(QueuedEntry(
                entry: entry,
                pendingProviders: providers,
                attempts: 1,
                nextRetryAt: Date().timeIntervalSince1970 + 60  // 1 min 后首次重试
            ))
        }
        saveQueue()
        scheduleRetry(reason: "new failure enqueued")
    }

    /// 后台重试循环 — 周期扫描队列, 把到时间的条目重新发, 全部成功就出队。
    /// 不并发跑多个循环, 单 task 处理。
    private func scheduleRetry(reason: String) {
        guard retryTask == nil || retryTask?.isCancelled == true else { return }
        guard !queue.isEmpty else { return }
        // 总开关关闭时不调度 —— retryLoop 会立刻退出, 否则 "drain after loop
        // exit" 会无限重启空转。用户重新打开会发 scrobbleSettingsChanged 触发。
        guard ScrobbleSettingsStore.shared.isEnabled else { return }
        retryTask = Task { [weak self] in
            await self?.retryLoop()
            await MainActor.run {
                self?.retryTask = nil
                // retryLoop 退出与置 nil 之间有挂起点, 此窗口内 enqueue 调
                // scheduleRetry 会被 `retryTask == nil` 守卫跳过 —— 置 nil 后
                // 再检查一次, 队列非空就补调度, 消除该竞态。
                if let self, !self.queue.isEmpty {
                    self.scheduleRetry(reason: "drain after loop exit")
                }
            }
        }
        plog("🎵 scrobble retry scheduled: \(reason), queue=\(queue.count)")
    }

    private func retryLoop() async {
        while !queue.isEmpty {
            // 总开关临时关闭 —— 直接退出循环、保留整个队列, 等用户重新打开
            // (会再发 scrobbleSettingsChanged → scheduleRetry)。绝不能借此把
            // pendingProviders 清空, 否则「暂时关掉 scrobble 再打开」会丢光待补报。
            guard ScrobbleSettingsStore.shared.isEnabled else { return }
            let now = Date().timeIntervalSince1970
            let dueIndices = queue.indices.filter { queue[$0].nextRetryAt <= now }
            if dueIndices.isEmpty {
                // 等到下一个 due 时间, 最长睡 60s 一次让 cancel 能生效
                let nextWake = (queue.map(\.nextRetryAt).min() ?? now) - now
                let sleep = max(5, min(60, nextWake))
                let nanoseconds = (sleep * 1_000_000_000).finiteUInt64(or: 5_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled { return }
                continue
            }

            // 用条目身份(songID+startedAt)做快照, 不持有跨 await 的数组索引 ——
            // await 期间 clearQueue() 可能清空队列、enqueue 可能合并新 pending,
            // 索引会失效。每次写回前用 firstIndex 重新定位。
            let dueKeys: [(songID: String, startedAt: Int64)] = dueIndices.map {
                (queue[$0].entry.songID, queue[$0].entry.startedAt)
            }
            for key in dueKeys {
                guard let idx = queue.firstIndex(where: {
                    $0.entry.songID == key.songID && $0.entry.startedAt == key.startedAt
                }) else { continue }  // 条目在 await 期间被清空/出队
                let item = queue[idx]
                let providers = activeProviders().filter { item.pendingProviders.contains($0.id) }
                guard !providers.isEmpty else {
                    // 走到这里 isEnabled 必为 true (总开关已在循环顶部拦掉)。空集只
                    // 可能因为: pending provider 被显式从 enabledProviders 移除, 或
                    // 仍启用但暂缺凭据。只清掉「已不在 enabledProviders」的那些 ——
                    // 仍启用但缺凭据的保留在 pending (用户可能重新填 token 后再补)。
                    let enabled = ScrobbleSettingsStore.shared.enabledProviders
                    let removed = item.pendingProviders.subtracting(enabled)
                    if let writeIdx = queue.firstIndex(where: {
                        $0.entry.songID == key.songID && $0.entry.startedAt == key.startedAt
                    }) {
                        queue[writeIdx].pendingProviders.subtract(removed)
                        // 仍有 pending (启用但缺凭据) —— 推进退避, 否则该条目永远
                        // "到期" 会让 retryLoop 空转打满 CPU。
                        if !queue[writeIdx].pendingProviders.isEmpty {
                            queue[writeIdx].attempts += 1
                            let backoff = min(60.0 * 60, 60.0 * pow(2.0, Double(queue[writeIdx].attempts - 1)))
                            queue[writeIdx].nextRetryAt = Date().timeIntervalSince1970 + backoff
                        }
                    }
                    continue
                }

                var stillFailed: Set<ScrobbleProviderID> = []
                for provider in providers {
                    do {
                        try await provider.submitListens([item.entry])
                        plog("🎵 scrobble retry [\(provider.id.displayName)] OK")
                        recordRecent(entry: item.entry, provider: provider.id)
                    } catch let err as ScrobbleError where !err.isRetryable {
                        plog("🎵 scrobble retry [\(provider.id.displayName)] dropped: \(err.localizedDescription)")
                    } catch {
                        stillFailed.insert(provider.id)
                    }
                }
                // await 后重新定位 —— 队列可能已被 clearQueue() 清空(找不到则丢弃
                // 本次结果)或被 enqueue 合并了新 pendingProviders(并集保留)。
                guard let writeIdx = queue.firstIndex(where: {
                    $0.entry.songID == key.songID && $0.entry.startedAt == key.startedAt
                }) else { continue }
                var current = queue[writeIdx]
                // 仅对「本轮已处理的 provider」做结论: 失败的留在 pending, 成功/
                // 丢弃的移除; 其余(如 await 期间被 enqueue 新加入的)原样保留。
                current.pendingProviders.subtract(providers.map(\.id))
                current.pendingProviders.formUnion(stillFailed)
                current.attempts += 1
                // 指数退避: 1, 2, 5, 15, 30, 60 分钟封顶
                let backoff = min(60.0 * 60, 60.0 * pow(2.0, Double(current.attempts - 1)))
                current.nextRetryAt = Date().timeIntervalSince1970 + backoff
                queue[writeIdx] = current
            }
            // 清掉 pendingProviders 为空的条目
            queue.removeAll(where: { $0.pendingProviders.isEmpty })
            saveQueue()
        }
    }

    // MARK: - Provider factory

    /// 当前启用 + 已配置 token 的 provider 实例集合。
    /// 每次重新生成 (token 变化 / settings 变化都生效)。
    private func activeProviders() -> [any ScrobbleProvider] {
        let settings = ScrobbleSettingsStore.shared
        guard settings.isEnabled else { return [] }
        var result: [any ScrobbleProvider] = []
        for pid in settings.enabledProviders {
            switch pid {
            case .listenBrainz:
                if let token = KeychainService.getPassword(for: pid.keychainAccount), !token.isEmpty {
                    result.append(ListenBrainzProvider(userToken: token))
                }
            case .lastFm:
                // 三件套都齐了才能 sign + 发请求。effective getter 自动
                // 在「用户自己粘的 key」和「app 内置 default」之间挑。
                let apiKey = LastFmCredentialsStore.effectiveAPIKey()
                let apiSecret = LastFmCredentialsStore.effectiveAPISecret()
                let sessionKey = LastFmCredentialsStore.loadSessionKey()
                if !apiKey.isEmpty, !apiSecret.isEmpty, !sessionKey.isEmpty {
                    result.append(LastFmProvider(
                        apiKey: apiKey,
                        apiSecret: apiSecret,
                        sessionKey: sessionKey
                    ))
                }
            }
        }
        return result
    }

    private func makeEntry(from song: Song) -> ScrobbleEntry {
        ScrobbleEntry(
            songID: song.id,
            title: song.title,
            artist: song.artistName ?? "Unknown Artist",
            album: song.albumTitle,
            albumArtist: nil,
            durationSec: song.duration.isFinite && song.duration > 0
                ? song.duration.finiteInt()
                : nil,
            trackNumber: song.trackNumber,
            startedAt: Int64(Date().timeIntervalSince1970)
        )
    }

    // MARK: - Persistence

    private func saveQueue() {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        }
    }

    private func loadQueue() {
        if let data = UserDefaults.standard.data(forKey: Self.queueKey),
           let decoded = try? JSONDecoder().decode([QueuedEntry].self, from: data) {
            queue = decoded
        }
    }

    private func recordRecent(entry: ScrobbleEntry, provider: ScrobbleProviderID) {
        recentReports.removeAll {
            $0.entry.songID == entry.songID
                && $0.entry.startedAt == entry.startedAt
                && $0.provider == provider
        }
        recentReports.insert(RecentReport(entry: entry, provider: provider, submittedAt: Date()), at: 0)
        if recentReports.count > Self.recentReportsLimit {
            recentReports.removeLast(recentReports.count - Self.recentReportsLimit)
        }
        saveRecentReports()
    }

    private func saveRecentReports() {
        if let data = try? JSONEncoder().encode(recentReports) {
            UserDefaults.standard.set(data, forKey: Self.recentReportsKey)
        }
    }

    private func loadRecentReports() {
        if let data = UserDefaults.standard.data(forKey: Self.recentReportsKey),
           let decoded = try? JSONDecoder().decode([RecentReport].self, from: data) {
            recentReports = Array(decoded.prefix(Self.recentReportsLimit))
        }
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
