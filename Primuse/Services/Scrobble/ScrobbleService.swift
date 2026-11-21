import Foundation
import PrimuseKit

/// Scrobble 总入口 — AudioPlayerService 在播放进度过阈值时调用,
/// 由本服务分发给所有启用的 provider, 失败的进队列后台重试。
@MainActor
@Observable
final class ScrobbleService {
    static let shared = ScrobbleService()

    private let defaults: UserDefaults
    private let providersOverride: (() -> [any ScrobbleProvider])?
    private let legacyQueueIsOfficial: () -> Bool?
    private let savedListenBrainzURL: () -> URL?
    private let spokenWordStore: SpokenWordStore
    private let songLookup: (String) -> Song?
    /// 当前正在播放的歌曲信息 (用于计入规则的触发判断)。
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
    private static let queueKey = "primuse.scrobble.queue.v2"
    private static let legacyQueueKey = "primuse.scrobble.queue.v1"
    private var importedLegacyTargets: Set<LegacyTarget> = []
    private static let queueLimit = 5_000
    private static let queueRetention: TimeInterval = 90 * 24 * 60 * 60
    private static let recentReportsKey = "primuse.scrobble.recentReports.v1"
    private static let recentReportsLimit = 12
    private(set) var recentReports: [RecentReport] = []
    /// 服务端明确拒绝过的凭据, provider → 凭据摘要。被拒的那份凭据不再拿来
    /// 请求, 听歌记录照常留在补报队列里, 换了 token / 重新登录或复核通过后再补。
    private static let rejectedCredentialsKey = "primuse.scrobble.rejectedCredentials.v1"
    private(set) var rejectedCredentials: [ScrobbleProviderID: String] = [:]
    /// 后台 retry task — settings 变化或网络恢复时启动。
    private var retryTask: Task<Void, Never>?
    private var retrySleep: Task<Void, Never>?
    private var retryGeneration = 0

    /// 一首音乐听够多少算听过 (`ListenCountRule`, 设置页可调)。有声内容照默认规则。
    private let listenCountRule: @MainActor () -> ListenCountRule

    private enum ListenBrainzDestination: Codable, Hashable {
        case server(String)
        case unresolved

        init(_ url: URL?) {
            if let url {
                self = .server(ScrobbleCredentialFingerprint.of(url.absoluteString))
            } else {
                self = .unresolved
            }
        }

        func matches(_ other: Self?) -> Bool {
            guard case .server = self else { return false }
            return self == other
        }
    }

    /// 失败队列条目 — track entry + 已尝试次数 + 哪些 provider 还没成功。
    private struct QueuedEntry: Codable {
        // Request completions only refer to queue rows in this process.
        let id = UUID()
        enum CodingKeys: String, CodingKey {
            case entry, pendingProviders, listenBrainzDestination, attempts, nextRetryAt, serverRetryAt
        }

        var listenBrainzDestination: ListenBrainzDestination?
        var entry: ScrobbleEntry
        /// 还需要发送给哪些 provider (成功一个移除一个, 全清空就丢出队列)。
        var pendingProviders: Set<ScrobbleProviderID>
        var attempts: Int
        /// 下次允许重试的时间 — 失败后指数退避, 避免持续打服务端。
        var nextRetryAt: TimeInterval
        /// Optional for backwards-compatible decoding of older queue records.
        var serverRetryAt: TimeInterval?
    }

    private struct LegacyTarget: Codable, Hashable {
        let songID: String
        let startedAt: Int64
        let provider: ScrobbleProviderID
    }

    private struct PersistedQueue: Codable {
        let entries: [QueuedEntry]
        // Kept with the imported entries until a subsequent launch sees the legacy key gone.
        let importedLegacyTargets: Set<LegacyTarget>?
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
        let listenBrainzDestination: ListenBrainzDestination?
        let startedAtMonotonic: TimeInterval
        var hasSentNowPlaying: Bool
        var hasScrobbled: Bool
        /// 这首按用户的计入规则算 (音乐); 有声内容、环境音照默认规则。
        let followsListenCountRule: Bool
        /// 真实累计收听时长 (秒) —— 每个 tick 加固定增量, 跟 song.currentTime 解耦,
        /// 这样 seek 到歌曲后段不会让一秒没听就触发 scrobble。新歌新建 session 自动归零。
        var listenedSeconds: TimeInterval = 0
    }

    private struct ProviderSnapshot {
        var listenBrainzDestination: ListenBrainzDestination?
        var ready: [any ScrobbleProvider] = []
        /// Enabled providers whose Keychain values could not be read. They are
        /// queue targets even though no provider instance can be built yet.
        var unavailable: Set<ScrobbleProviderID> = []
    }

    init(
        defaults: UserDefaults = .standard,
        providers: (() -> [any ScrobbleProvider])? = nil,
        legacyQueueIsOfficial: @escaping () -> Bool? = { ListenBrainzCredentialsStore.legacyQueueIsOfficial },
        savedListenBrainzURL: @escaping () -> URL? = { ListenBrainzCredentialsStore.savedBaseURL() },
        spokenWordStore: SpokenWordStore = .shared,
        songLookup: @escaping (String) -> Song? = {
            PlayHistoryStore.shared.classification.library?.song(id: $0)
        },
        listenCountRule: @escaping @MainActor () -> ListenCountRule = {
            ScrobbleSettingsStore.shared.listenCountRule
        }
    ) {
        self.defaults = defaults
        self.providersOverride = providers
        self.legacyQueueIsOfficial = legacyQueueIsOfficial
        self.savedListenBrainzURL = savedListenBrainzURL
        self.spokenWordStore = spokenWordStore
        self.songLookup = songLookup
        self.listenCountRule = listenCountRule
        loadQueue()
        loadRecentReports()
        loadRejectedCredentials()
        if !rejectedCredentials.isEmpty {
            Task { await self.recheckRejectedCredentials() }
        }
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
    /// A medley plays slices of songs; none of them is a listen to report.
    var isSuspended = false

    func handlePlaybackStarted(song: Song) {
        guard !isSuspended else {
            currentSong = nil
            currentSession = nil
            return
        }
        currentSong = song
        let entry = makeEntry(from: song)
        let reportable = canReport(entry)
        // session 总是建立 —— 它同时驱动服务端源(Subsonic)的 submission 阈值,
        // 后者独立于全局 scrobble 开关。全局 provider 的 nowPlaying/submit 仍各自
        // 在 active providers 为空时 no-op。
        let snapshot = reportable == true ? providerSnapshot() : ProviderSnapshot()
        currentSession = PlaySession(
            entry: entry,
            listenBrainzDestination: snapshot.listenBrainzDestination,
            startedAtMonotonic: Self.monotonicNow(),
            hasSentNowPlaying: false,
            hasScrobbled: false,
            followsListenCountRule: reportable != false
        )

        // 服务端源回报 "正在播放"(submission=false)。开关只管音乐,由 handler 按歌曲判断;
        // 非服务端源在 handler 内 no-op。
        serverScrobbleHandler?(song, false)

        guard reportable == true else { return }
        let settings = ScrobbleSettingsStore.shared
        guard settings.isEnabled, !settings.enabledProviders.isEmpty else { return }
        if settings.sendNowPlaying {
            currentSession?.hasSentNowPlaying = true
            sendNowPlayingAcrossProviders(entry: entry, snapshot: snapshot)
        }
    }

    /// AVPlayer may only discover a standalone music video's duration after
    /// playback has started. Refresh the active session so the listen count
    /// rule can still trigger for that first play.
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
            startedAt: old.startedAt,
            content: old.content
        )
        currentSession = session

        if var song = currentSong, song.id == songID {
            song.duration = duration
            currentSong = song
        }
    }

    /// 播放进度更新 (AudioPlayerService 每个 tick 触发) — 判断是否听够了计入规则。
    /// playedDelta: 距上次 tick 实际经过的收听时长 (real wallclock 增量, 不是
    /// song.currentTime)。service 内部累加, 避免用户 seek 到歌曲后段时一秒没听
    /// 就被当成已听够而误上报 (污染 Last.fm/ListenBrainz/Navidrome 播放次数)。
    func handleProgressTick(playedDelta: TimeInterval) {
        guard var session = currentSession, !session.hasScrobbled else { return }
        session.listenedSeconds += max(0, playedDelta)
        currentSession = session
        let rule = session.followsListenCountRule ? listenCountRule() : .default
        guard let threshold = rule.requiredListenSeconds(
            forDuration: Double(session.entry.durationSec ?? 0)
        ), session.listenedSeconds >= threshold else { return }

        session.hasScrobbled = true
        currentSession = session
        // 服务端源回报 "已播放"(submission=true) —— 计入 Navidrome 播放次数/历史。开关只管音乐,由 handler 判断。
        if let song = currentSong {
            serverScrobbleHandler?(song, true)
        }
        // 全局 provider(Last.fm/ListenBrainz)—— activeProviders 为空时自动 no-op。
        scrobbleAcrossProviders(entry: session.entry, listenBrainzDestination: session.listenBrainzDestination)
    }

    /// 切歌 / 用户手动停止 — 清 session, 不补 scrobble (没听够计入规则不该计入)。
    func handlePlaybackStopped() {
        currentSession = nil
        currentSong = nil
    }

    /// 当前队列长度 — Settings UI 显示。
    var pendingCount: Int { queue.count }

    /// 用户手动触发 retry (Settings UI 按钮)。
    func retryPendingNow() {
        // Manual retry may skip local backoff, never the provider's deadline.
        let now = Date().timeIntervalSince1970
        for i in queue.indices { queue[i].nextRetryAt = max(now, queue[i].serverRetryAt ?? 0) }
        saveQueue()
        retryGeneration &+= 1
        retrySleep?.cancel()
        scheduleRetry(reason: "user manual retry")
    }

    /// 完全清空失败队列 — 用户在 Settings 里点 "Clear pending"。
    func clearQueue() {
        queue.removeAll()
        saveQueue()
    }

    /// 当前保存的凭据是否被服务端拒绝过 —— 设置页据此显示「无效」。
    func hasRejectedCredential(for pid: ScrobbleProviderID) -> Bool {
        guard let rejected = rejectedCredentials[pid] else { return false }
        return credentialSnapshot().ready.contains { $0.id == pid && $0.credentialFingerprint == rejected }
    }

    /// 设置页手动验证的结论: 有效就解除拒绝并立刻补报存着的记录, 无效就记下。
    func noteCredentialValidation(for pid: ScrobbleProviderID, isValid: Bool, fingerprint: String? = nil) {
        guard let provider = credentialSnapshot().ready.first(where: { $0.id == pid }),
              fingerprint == nil || fingerprint == provider.credentialFingerprint else { return }
        if isValid {
            guard rejectedCredentials.removeValue(forKey: pid) != nil else { return }
            saveRejectedCredentials()
            plog("🎵 scrobble [\(pid.displayName)] credentials confirmed; resuming held listens")
            retryPendingNow()
        } else {
            recordCredentialRejection(provider)
        }
    }

    // MARK: - Internal: dispatch + queue

    /// Now Playing 同步发送 — 失败不入队 (now playing 是实时状态, 没必要补)。
    private func sendNowPlayingAcrossProviders(entry: ScrobbleEntry, snapshot: ProviderSnapshot) {
        guard canReport(entry) == true else { return }
        let providers = snapshot.ready
        if !snapshot.unavailable.isEmpty {
            plog("🎵 scrobble nowPlaying skipped for unavailable credentials: \(snapshot.unavailable.map(\.rawValue).sorted())")
        }
        guard !providers.isEmpty else { return }
        Task {
            guard canReport(entry) == true else { return }
            let rejected = await withTaskGroup(
                of: (any ScrobbleProvider)?.self,
                returning: [any ScrobbleProvider].self
            ) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            try await provider.sendNowPlaying(entry)
                        } catch {
                            plog("🎵 scrobble nowPlaying [\(provider.id.displayName)] failed: \(error.localizedDescription)")
                            if ScrobbleService.isCredentialRejection(error) { return provider }
                        }
                        return nil
                    }
                }
                var found: [any ScrobbleProvider] = []
                for await provider in group {
                    if let provider { found.append(provider) }
                }
                return found
            }
            for provider in rejected { recordCredentialRejection(provider) }
        }
    }

    /// Scrobble 提交。先同步持久化，再尝试网络；进程在请求期间被终止时，
    /// 下次启动仍能补报。语义是 at-least-once，provider 以 startedAt 去重。
    private func scrobbleAcrossProviders(entry: ScrobbleEntry, listenBrainzDestination: ListenBrainzDestination?) {
        guard canReport(entry) == true else { return }
        let snapshot = providerSnapshot()
        var providerIDs = Set(snapshot.ready.map(\.id)).union(snapshot.unavailable)
        if listenBrainzDestination == nil {
            providerIDs.remove(.listenBrainz)
        } else if !providerIDs.contains(.listenBrainz), case .server = listenBrainzDestination,
                  ScrobbleSettingsStore.shared.isEnabled, ScrobbleSettingsStore.shared.enabledProviders.contains(.listenBrainz),
                  let savedURL = savedListenBrainzURL(), listenBrainzDestination != ListenBrainzDestination(savedURL) {
            // The new server has no token yet, but this listen began with the previous server.
            providerIDs.insert(.listenBrainz)
        }
        guard !providerIDs.isEmpty else { return }
        let providers = snapshot.ready.filter {
            $0.id != .listenBrainz || listenBrainzDestination?.matches(snapshot.listenBrainzDestination) == true
        }
        let rowID = enqueue(entry: entry, providers: providerIDs,
                            listenBrainzDestination: providerIDs.contains(.listenBrainz) ? listenBrainzDestination : nil)

        // A temporarily unreadable Keychain must not turn an otherwise valid
        // listen into a no-op. The durable queue already knows how to retain an
        // enabled provider with no current instance and retry it with backoff.
        guard !providers.isEmpty else {
            scheduleRetry(reason: "credential unavailable")
            return
        }

        Task {
            guard canReport(entry) == true else {
                saveQueue()
                return
            }
            await withTaskGroup(of: (ScrobbleProviderID, Bool, Bool, TimeInterval?, (any ScrobbleProvider)?).self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            try await provider.submitListens([entry])
                            plog("🎵 scrobble [\(provider.id.displayName)] OK: \(entry.title)")
                            return (provider.id, true, true, nil, nil)
                        } catch let err as ScrobbleError where ScrobbleService.isCredentialRejection(err) {
                            // 凭据被拒: 记录留在队列里, 等凭据换了 / 复核通过再补。
                            plog("🎵 scrobble [\(provider.id.displayName)] failed (held): \(err.localizedDescription)")
                            return (provider.id, false, false, nil, provider)
                        } catch let err as ScrobbleError {
                            plog("🎵 scrobble [\(provider.id.displayName)] failed (\(err.isRetryable ? "queued" : "dropped")): \(err.localizedDescription)")
                            return (provider.id, !err.isRetryable, false, nil, nil)  // 不可重试 = 视作 "完成", 别留队列里
                        } catch {
                            plog("🎵 scrobble [\(provider.id.displayName)] failed (queued): \(error.localizedDescription)")
                            let delay = (error as? HTTPResponseFailure)?.retryAfter
                            return (provider.id, false, false, delay, nil)
                        }
                    }
                }
                for await (pid, done, didSubmit, serverDelay, rejected) in group {
                    if let serverDelay { self.recordServerRetry(rowID: rowID, delay: serverDelay) }
                    if let rejected { self.recordCredentialRejection(rejected) }
                    if didSubmit {
                        self.recordRecent(entry: entry, provider: pid)
                    }
                    if done {
                        self.markProviderCompleted(rowID: rowID, provider: pid)
                    }
                }
            }
            self.saveQueue()
            self.scheduleRetry(reason: "initial submission completed")
        }
    }

    private func recordServerRetry(rowID: UUID, delay: TimeInterval) {
        guard delay.isFinite, delay >= 0,
              let index = queue.firstIndex(where: { $0.id == rowID }) else { return }
        let deadline = Date().timeIntervalSince1970 + min(delay, ScrobbleCooldownStore.maximumDelay)
        queue[index].serverRetryAt = max(queue[index].serverRetryAt ?? 0, deadline)
        queue[index].nextRetryAt = max(queue[index].nextRetryAt, deadline)
    }

    private func enqueue(
        entry: ScrobbleEntry,
        providers: Set<ScrobbleProviderID>,
        listenBrainzDestination: ListenBrainzDestination?
    ) -> UUID {
        if let idx = queue.firstIndex(where: {
            $0.entry.songID == entry.songID && $0.entry.startedAt == entry.startedAt
                && $0.listenBrainzDestination == listenBrainzDestination
        }) {
            let id = queue[idx].id
            queue[idx].pendingProviders.formUnion(providers)
            saveQueue()
            return id
        }
        let item = QueuedEntry(listenBrainzDestination: listenBrainzDestination, entry: entry,
                               pendingProviders: providers, attempts: 0,
                               nextRetryAt: Date().timeIntervalSince1970 + 60)
        queue.append(item)
        saveQueue()
        return item.id
    }

    private func markProviderCompleted(rowID: UUID, provider: ScrobbleProviderID) {
        guard let index = queue.firstIndex(where: { $0.id == rowID }) else { return }
        queue[index].pendingProviders.remove(provider)
        if queue[index].pendingProviders.isEmpty {
            queue.remove(at: index)
        }
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
            guard !Task.isCancelled else { return }
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
                let sleeper = Task<Void, Never> { try? await Task.sleep(nanoseconds: nanoseconds) }
                retrySleep = sleeper
                await sleeper.value
                retrySleep = nil
                if Task.isCancelled { return }
                continue
            }

            // A callback for a cleared row must never update a replacement queued during the request.
            let dueIDs = dueIndices.map { queue[$0].id }
            resolveLegacyQueueDestinations()
            let snapshot = providerSnapshot()
            var available = snapshot.ready
            let generation = retryGeneration
            for id in dueIDs {
                guard generation == retryGeneration else { break }
                guard let idx = queue.firstIndex(where: { $0.id == id }) else { continue }
                let item = queue[idx]
                let eligible = canReport(item.entry)
                guard eligible == true else {
                    // An unresolved legacy listen is retained until its library
                    // becomes available; it must not default to music on launch.
                    if eligible == false { queue.remove(at: idx) }
                    else { queue[idx].nextRetryAt = now + 60 }
                    continue
                }
                let providers = available.filter { provider in
                    item.pendingProviders.contains(provider.id)
                        && (provider.id != .listenBrainz || item.listenBrainzDestination?.matches(snapshot.listenBrainzDestination) == true)
                }
                guard !providers.isEmpty else {
                    // 走到这里 isEnabled 必为 true (总开关已在循环顶部拦掉)。空集只
                    // 可能因为: pending provider 被显式从 enabledProviders 移除, 或
                    // 仍启用但暂缺凭据。只清掉「已不在 enabledProviders」的那些 ——
                    // 仍启用但缺凭据的保留在 pending (用户可能重新填 token 后再补)。
                    let enabled = ScrobbleSettingsStore.shared.enabledProviders
                    let removed = item.pendingProviders.subtracting(enabled)
                    queue[idx].pendingProviders.subtract(removed)
                    if !queue[idx].pendingProviders.isEmpty {
                        queue[idx].attempts += 1
                        let backoff = min(60.0 * 60, 60.0 * pow(2.0, Double(queue[idx].attempts - 1)))
                        queue[idx].nextRetryAt = Date().timeIntervalSince1970 + backoff
                    }
                    continue
                }

                var stillFailed: Set<ScrobbleProviderID> = []
                for (offset, provider) in providers.enumerated() {
                    guard generation == retryGeneration, canReport(item.entry) == true else {
                        stillFailed.formUnion(providers[offset...].map(\.id))
                        break
                    }
                    do {
                        try await provider.submitListens([item.entry])
                        plog("🎵 scrobble retry [\(provider.id.displayName)] OK")
                        recordRecent(entry: item.entry, provider: provider.id)
                    } catch let err as ScrobbleError where ScrobbleService.isCredentialRejection(err) {
                        plog("🎵 scrobble retry [\(provider.id.displayName)] held: \(err.localizedDescription)")
                        recordCredentialRejection(provider)
                        available.removeAll { $0.id == provider.id }
                        stillFailed.insert(provider.id)
                    } catch let err as ScrobbleError where !err.isRetryable {
                        plog("🎵 scrobble retry [\(provider.id.displayName)] dropped: \(err.localizedDescription)")
                    } catch {
                        if OperationCancellationPolicy.isCancellation(error) { saveQueue(); return }
                        if let delay = (error as? HTTPResponseFailure)?.retryAfter {
                            recordServerRetry(rowID: id, delay: delay)
                        }
                        stillFailed.insert(provider.id)
                    }
                }
                // await 后重新定位 —— 队列可能已被 clearQueue() 清空(找不到则丢弃
                // 本次结果)或被 enqueue 合并了新 pendingProviders(并集保留)。
                guard let writeIdx = queue.firstIndex(where: { $0.id == id }) else { continue }
                var current = queue[writeIdx]
                // 仅对「本轮已处理的 provider」做结论: 失败的留在 pending, 成功/
                // 丢弃的移除; 其余(如 await 期间被 enqueue 新加入的)原样保留。
                current.pendingProviders.subtract(providers.map(\.id))
                current.pendingProviders.formUnion(stillFailed)
                current.attempts += 1
                // 指数退避: 1, 2, 5, 15, 30, 60 分钟封顶
                let backoff = min(60.0 * 60, 60.0 * pow(2.0, Double(current.attempts - 1)))
                let delay = generation == retryGeneration ? backoff : 0
                current.nextRetryAt = max(Date().timeIntervalSince1970 + delay, current.serverRetryAt ?? 0)
                queue[writeIdx] = current
            }
            // 清掉 pendingProviders 为空的条目
            queue.removeAll(where: { $0.pendingProviders.isEmpty })
            saveQueue()
        }
    }

    // MARK: - Provider factory

    /// 能拿来发送的 provider。服务端拒绝过的凭据和 Keychain 暂不可读一样处理:
    /// 记录照常进补报队列, 只是不再拿这份凭据去请求。
    private func providerSnapshot() -> ProviderSnapshot {
        var snapshot = credentialSnapshot()
        if let provider = snapshot.ready.first(where: { $0.id == .listenBrainz }) {
            snapshot.listenBrainzDestination = ListenBrainzDestination(provider.serverURL)
            if snapshot.listenBrainzDestination == .unresolved {
                snapshot.ready.removeAll { $0.id == .listenBrainz }
                snapshot.unavailable.insert(.listenBrainz)
            }
        } else if snapshot.unavailable.contains(.listenBrainz) {
            snapshot.listenBrainzDestination = .unresolved
        }
        let rejected = snapshot.ready.filter { rejectedCredentials[$0.id] == $0.credentialFingerprint }
        guard !rejected.isEmpty else { return snapshot }
        snapshot.ready.removeAll { rejectedCredentials[$0.id] == $0.credentialFingerprint }
        snapshot.unavailable.formUnion(rejected.map(\.id))
        return snapshot
    }

    /// 当前启用 provider 的凭据快照。Keychain 暂不可读与明确未配置必须
    /// 分开：前者进入补报队列，后者不为新播放创建无法发送的队列项。
    private func credentialSnapshot() -> ProviderSnapshot {
        if let providersOverride { return ProviderSnapshot(ready: providersOverride()) }
        let settings = ScrobbleSettingsStore.shared
        guard settings.isEnabled else { return ProviderSnapshot() }
        var snapshot = ProviderSnapshot()
        for pid in settings.enabledProviders {
            switch pid {
            case .listenBrainz:
                switch ListenBrainzCredentialsStore.resolve() {
                case .ready(let credentials):
                    snapshot.ready.append(ListenBrainzProvider(userToken: credentials.token, baseURL: credentials.baseURL))
                case .unavailable:
                    snapshot.unavailable.insert(pid)
                case .notConfigured:
                    break
                }
            case .lastFm:
                switch LastFmCredentialsStore.resolveProviderCredentials() {
                case .ready(let apiKey, let apiSecret, let sessionKey):
                    snapshot.ready.append(LastFmProvider(
                        apiKey: apiKey,
                        apiSecret: apiSecret,
                        sessionKey: sessionKey
                    ))
                case .unavailable:
                    snapshot.unavailable.insert(pid)
                case .notConfigured:
                    break
                }
            }
        }
        return snapshot
    }

    private func makeEntry(from song: Song) -> ScrobbleEntry {
        ScrobbleEntry(
            songID: song.id,
            title: song.title,
            artist: song.artistName ?? "Unknown Artist",
            album: song.albumTitle,
            albumArtist: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: song.albumArtistName,
                trackArtistName: song.artistName
            ),
            durationSec: song.duration.isFinite && song.duration > 0
                ? song.duration.finiteInt()
                : nil,
            trackNumber: song.trackNumber,
            startedAt: Int64(Date().timeIntervalSince1970),
            content: .init(sourceID: song.sourceID, filePath: song.filePath,
                           genre: song.genre, serverLibraryID: song.serverLibraryID)
        )
    }

    /// nil means a legacy record has no reliable classification yet.
    private func canReport(_ entry: ScrobbleEntry) -> Bool? {
        guard ListeningHistorySpacePolicy.space(
            songID: entry.songID, sourceID: entry.content?.sourceID ?? "", spokenWordSongIDs: []
        ) == .music else { return false }
        if let song = songLookup(entry.songID) {
            return ListeningHistorySpacePolicy.space(
                songID: song.id, sourceID: song.sourceID, spokenWordSongIDs: []
            ) == .music && spokenWordStore.isMusic(song)
        }
        if let kind = spokenWordStore.overrides[entry.songID] {
            // 环境音不上报;关了「单独归类环境音」时它就是普通音乐。
            return kind == .music || (kind == .ambient && !spokenWordStore.separatesAmbient)
        }
        guard let content = entry.content else { return nil }
        return spokenWordStore.classificationSnapshot.kind(
            songID: entry.songID, sourceID: content.sourceID, filePath: content.filePath,
            genre: content.genre, serverLibraryID: content.serverLibraryID
        ) == .music
    }

    // MARK: - Persistence

    @discardableResult
    private func saveQueue() -> Bool {
        pruneQueue()
        let state = PersistedQueue(entries: queue, importedLegacyTargets: importedLegacyTargets.isEmpty ? nil : importedLegacyTargets)
        guard let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: Self.queueKey)
        return true
    }

    private func loadQueue() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Self.queueKey) {
            guard let state = try? decoder.decode(PersistedQueue.self, from: data) else { return }
            queue = state.entries
            importedLegacyTargets = state.importedLegacyTargets ?? []
        }

        // An older installation can produce a fresh v1 queue after a downgrade.
        if let legacy = defaults.data(forKey: Self.legacyQueueKey) {
            guard let rows = try? decoder.decode([QueuedEntry].self, from: legacy) else { return }
            var observed: Set<LegacyTarget> = []
            for var row in rows {
                row.pendingProviders = row.pendingProviders.filter { provider in
                    let target = LegacyTarget(songID: row.entry.songID, startedAt: row.entry.startedAt, provider: provider)
                    return observed.insert(target).inserted && !importedLegacyTargets.contains(target)
                }
                if !row.pendingProviders.isEmpty { queue.append(row) }
            }
            importedLegacyTargets = observed
            resolveLegacyQueueDestinations()
            // Persist the entries and import receipt together before retiring the copy readable by build 137.
            if saveQueue(), defaults.synchronize() {
                defaults.removeObject(forKey: Self.legacyQueueKey)
            }
        } else if !queue.isEmpty || !importedLegacyTargets.isEmpty {
            importedLegacyTargets.removeAll()
            resolveLegacyQueueDestinations()
            saveQueue()
        }
    }

    private func resolveLegacyQueueDestinations() {
        let unbound = queue.indices.filter {
            queue[$0].pendingProviders.contains(.listenBrainz) && queue[$0].listenBrainzDestination == nil
        }
        guard !unbound.isEmpty, let isOfficial = legacyQueueIsOfficial() else { return }
        let destination = isOfficial ? ListenBrainzDestination(ListenBrainzServerAddress.officialURL) : .unresolved
        for index in unbound { queue[index].listenBrainzDestination = destination }
    }

    /// Bounds offline growth and deterministically drops expired/oldest entries.
    /// Keeping the newest 5,000 listens covers prolonged offline use without
    /// allowing UserDefaults to grow without limit.
    private func pruneQueue(now: TimeInterval = Date().timeIntervalSince1970) {
        let cutoff = now - Self.queueRetention
        queue.removeAll {
            $0.pendingProviders.isEmpty || TimeInterval($0.entry.startedAt) < cutoff
                || canReport($0.entry) == false
        }
        if queue.count > Self.queueLimit {
            queue.sort {
                if $0.entry.startedAt != $1.entry.startedAt {
                    return $0.entry.startedAt < $1.entry.startedAt
                }
                return $0.entry.songID < $1.entry.songID
            }
            queue.removeFirst(queue.count - Self.queueLimit)
        }
        // 系统时钟往回拨后,记下的截止时间不能比服务端冷却的上限还远,否则手动重试也解不开。
        let ceiling = now + ScrobbleCooldownStore.maximumDelay
        for index in queue.indices {
            if let server = queue[index].serverRetryAt, server > ceiling { queue[index].serverRetryAt = ceiling }
            if queue[index].nextRetryAt > ceiling { queue[index].nextRetryAt = ceiling }
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
            defaults.set(data, forKey: Self.recentReportsKey)
        }
    }

    private func loadRecentReports() {
        if let data = defaults.data(forKey: Self.recentReportsKey),
           let decoded = try? JSONDecoder().decode([RecentReport].self, from: data) {
            recentReports = Array(decoded.prefix(Self.recentReportsLimit))
        }
    }

    // MARK: - Rejected credentials

    /// 服务端明确说凭据不对(token 被撤销、session 失效)。网络错、限流、5xx 不算。
    nonisolated static func isCredentialRejection(_ error: Error) -> Bool {
        if case .invalidCredentials? = error as? ScrobbleError { return true }
        return false
    }

    private func recordCredentialRejection(_ provider: any ScrobbleProvider) {
        let fingerprint = provider.credentialFingerprint
        guard rejectedCredentials[provider.id] != fingerprint,
              credentialSnapshot().ready.contains(where: { $0.id == provider.id && $0.credentialFingerprint == fingerprint })
        else { return }
        rejectedCredentials[provider.id] = fingerprint
        saveRejectedCredentials()
        plog("🎵 scrobble [\(provider.id.displayName)] credentials rejected; holding listens until they change")
    }

    /// 被拒的凭据每次启动复核一次: 服务端一时误拒、或用户在网站上恢复了授权,
    /// 复核通过就解除, 存着的记录接着补报。
    private func recheckRejectedCredentials() async {
        let rejected = credentialSnapshot().ready.filter {
            rejectedCredentials[$0.id] == $0.credentialFingerprint
        }
        for provider in rejected {
            guard await provider.validateCredentials() == true,
                  rejectedCredentials[provider.id] == provider.credentialFingerprint else { continue }
            noteCredentialValidation(for: provider.id, isValid: true, fingerprint: provider.credentialFingerprint)
        }
    }

    private func saveRejectedCredentials() {
        let stored = Dictionary(uniqueKeysWithValues: rejectedCredentials.map { ($0.key.rawValue, $0.value) })
        defaults.set(stored, forKey: Self.rejectedCredentialsKey)
    }

    private func loadRejectedCredentials() {
        let stored = defaults.dictionary(forKey: Self.rejectedCredentialsKey) as? [String: String] ?? [:]
        rejectedCredentials = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            ScrobbleProviderID(rawValue: key).map { ($0, value) }
        })
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
