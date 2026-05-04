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
    /// 失败队列, 持久化到 UserDefaults。
    private var queue: [QueuedEntry] = []
    private static let queueKey = "primuse.scrobble.queue.v1"
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

    /// 当前播放的会话状态, 决定何时触发 scrobble。
    private struct PlaySession {
        let entry: ScrobbleEntry
        let startedAtMonotonic: TimeInterval
        var hasSentNowPlaying: Bool
        var hasScrobbled: Bool
    }

    private init() {
        loadQueue()
        // Settings 变化 (启用 provider 切换) 时尝试 flush 队列。
        NotificationCenter.default.addObserver(
            forName: .scrobbleSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRetry(reason: "settings changed") }
        }
    }

    // MARK: - Public API (AudioPlayerService 调用)

    /// 用户开始播放新歌 — 创建 session, 同步发 nowPlaying。
    func handlePlaybackStarted(song: Song) {
        let settings = ScrobbleSettingsStore.shared
        guard settings.isEnabled, !settings.enabledProviders.isEmpty else {
            currentSession = nil
            return
        }
        let entry = makeEntry(from: song)
        currentSession = PlaySession(
            entry: entry,
            startedAtMonotonic: Self.monotonicNow(),
            hasSentNowPlaying: false,
            hasScrobbled: false
        )
        if settings.sendNowPlaying {
            currentSession?.hasSentNowPlaying = true
            sendNowPlayingAcrossProviders(entry: entry)
        }
    }

    /// 播放进度更新 (AudioPlayerService 每秒级触发) — 判断是否到 scrobble 阈值。
    /// elapsed: 用户实际听了多久 (real wallclock, 不是 song.currentTime, 避免
    /// seek/jump 让累计虚高)。
    func handleProgressTick(elapsed: TimeInterval) {
        guard var session = currentSession, !session.hasScrobbled else { return }
        let durationSec = Double(session.entry.durationSec ?? 0)
        guard durationSec >= Self.minTrackDurationSec else { return }
        let half = durationSec * Self.listenedThresholdRatio
        let threshold = min(half, Self.listenedThresholdSeconds)
        guard elapsed >= threshold else { return }

        session.hasScrobbled = true
        currentSession = session
        scrobbleAcrossProviders(entry: session.entry)
    }

    /// 切歌 / 用户手动停止 — 清 session, 不补 scrobble (因为听不够 50% 不该计入)。
    func handlePlaybackStopped() {
        currentSession = nil
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
            await withTaskGroup(of: (ScrobbleProviderID, Bool).self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            try await provider.submitListens([entry])
                            plog("🎵 scrobble [\(provider.id.displayName)] OK: \(entry.title)")
                            return (provider.id, true)
                        } catch let err as ScrobbleError {
                            plog("🎵 scrobble [\(provider.id.displayName)] failed (\(err.isRetryable ? "queued" : "dropped")): \(err.localizedDescription)")
                            return (provider.id, !err.isRetryable)  // 不可重试 = 视作 "完成", 别留队列里
                        } catch {
                            plog("🎵 scrobble [\(provider.id.displayName)] failed (queued): \(error.localizedDescription)")
                            return (provider.id, false)
                        }
                    }
                }
                for await (pid, done) in group {
                    if !done { failed.insert(pid) }
                }
            }
            await MainActor.run {
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
        retryTask = Task { [weak self] in
            await self?.retryLoop()
            await MainActor.run { self?.retryTask = nil }
        }
        plog("🎵 scrobble retry scheduled: \(reason), queue=\(queue.count)")
    }

    private func retryLoop() async {
        while !queue.isEmpty {
            let now = Date().timeIntervalSince1970
            let dueIndices = queue.indices.filter { queue[$0].nextRetryAt <= now }
            if dueIndices.isEmpty {
                // 等到下一个 due 时间, 最长睡 60s 一次让 cancel 能生效
                let nextWake = (queue.map(\.nextRetryAt).min() ?? now) - now
                let sleep = max(5, min(60, nextWake))
                try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
                if Task.isCancelled { return }
                continue
            }

            for idx in dueIndices {
                guard idx < queue.count else { continue }
                var item = queue[idx]
                let providers = activeProviders().filter { item.pendingProviders.contains($0.id) }
                guard !providers.isEmpty else {
                    // 用户禁用了相关 provider, 把这些 pending 清掉
                    item.pendingProviders = []
                    queue[idx] = item
                    continue
                }

                var stillFailed: Set<ScrobbleProviderID> = []
                for provider in providers {
                    do {
                        try await provider.submitListens([item.entry])
                        plog("🎵 scrobble retry [\(provider.id.displayName)] OK")
                    } catch let err as ScrobbleError where !err.isRetryable {
                        plog("🎵 scrobble retry [\(provider.id.displayName)] dropped: \(err.localizedDescription)")
                    } catch {
                        stillFailed.insert(provider.id)
                    }
                }
                item.pendingProviders = stillFailed
                item.attempts += 1
                // 指数退避: 1, 2, 5, 15, 30, 60 分钟封顶
                let backoff = min(60.0 * 60, 60.0 * pow(2.0, Double(item.attempts - 1)))
                item.nextRetryAt = Date().timeIntervalSince1970 + backoff
                queue[idx] = item
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
                // Last.fm 三件套都齐了才能 sign + 发请求。任何一个缺都跳过,
                // 让 settings UI 提示用户去补。
                let apiKey = LastFmCredentialsStore.loadAPIKey()
                let apiSecret = LastFmCredentialsStore.loadAPISecret()
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
            durationSec: song.duration > 0 ? Int(song.duration) : nil,
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

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
