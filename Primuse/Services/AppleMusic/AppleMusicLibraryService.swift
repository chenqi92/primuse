import Foundation
import CryptoKit
import MusicKit
import PrimuseKit
#if os(iOS)
import MediaPlayer
#endif
#if os(macOS)
import iTunesLibrary
#endif

/// 把 Apple Music user library (用户已收藏 / 已添加到资料库的歌) 拉进
/// 猿音 MusicLibrary, 跟 NAS / 云盘的歌一起出现在 Library 视图。
///
/// 系统侧由 `ApplicationMusicPlayer` 负责 DRM 流播放, 我们这里只做:
/// - iOS 用 `MusicLibraryRequest`, macOS 用 Apple Music API 分页拉完整云资料库
/// - 把每首 MusicKit.Song 映射成 PrimuseKit.Song (sourceID 固定为
///   `appleMusicSystemSourceID`, filePath 是 Apple Music MusicItemID)
/// - 写入 MusicLibrary, 后续 SongRowView / AlbumDetailView / NowPlaying
///   都能直接显示这些歌, 跟本地歌平等
///
/// 不做 (Phase 2+):
/// - CloudKit 同步 (Apple Music 库每个设备独立拉, 避免 sync 冲突)
/// - 跨类型 Playlist (本地 + Apple Music 混入一个 Playlist)
/// - Apple Music 官方歌词读取（MusicKit 目前只公开 `hasLyrics`, 不公开正文）
@MainActor
@Observable
final class AppleMusicLibraryService {
    /// Apple Music 那个虚拟 source 的固定 ID — 全猿音里 hard-code 这个值,
    /// 不走 UUID, 让 song.sourceID 一致, 多次启动 / 重装也能 match 上。
    nonisolated static let systemSourceID = AppleMusicLibraryIdentity.sourceID

    /// 「Apple Music 资料库」镜像歌单的固定 ID。每次 sync 完整覆盖,
    /// UI 上按这个 id 识别后 *禁用从歌单移除单首歌* — 不能反向 push 到
    /// Apple Music 删收藏, 移除一首本地视图意味着下次 sync 又回来,
    /// 体验上是"删了又出现"的 bug, 索性禁用。
    nonisolated static let systemPlaylistID = AppleMusicLibraryIdentity.systemPlaylistID

    /// 用户在 Apple Music 自建的 playlist 镜像 ID 前缀, 后面接 amID。
    /// 跟「Apple Music 资料库」全集镜像并存, 同样受 sync 覆盖保护。
    nonisolated static let userPlaylistIDPrefix = AppleMusicLibraryIdentity.userPlaylistIDPrefix

    /// 是否任意 Apple Music 镜像歌单 (全集 / 用户自建)。给 UI 用来决定要不要
    /// 禁删 / 禁移除单曲。
    nonisolated static func isAppleMusicMirrorPlaylist(_ playlistID: String) -> Bool {
        AppleMusicLibraryIdentity.isMirrorPlaylist(playlistID)
    }

    private struct UserPlaylistMirror: Sendable {
        let id: String
        let name: String
        let songIDs: [String]
        let coverArtReference: String?
    }

    private enum UserPlaylistFetchResult: Sendable {
        case mirror(UserPlaylistMirror)
        case empty(id: String, name: String, coverArtReference: String?)
        /// Apple Music 报告有曲目但本地一首都没匹配上 (全是视频 / 下架曲目 /
        /// canonicalization 失败)。保留已有镜像原样, 也不新建空歌单 —— 这是
        /// "取不到", 不是"歌单空了"。直接当 empty 会让一次不完整的 fetch 把整个
        /// 歌单清光。
        case unresolved(
            id: String,
            name: String,
            reportedTrackCount: Int,
            coverArtReference: String?
        )
        case failed(id: String, name: String, coverArtReference: String?, error: String)
    }

    /// macOS 会优先读云端资料库；云端权限不可用时仍保留 Music.app 的本机歌曲，
    /// 但必须把降级原因带回 UI，不能把“仅同步到 2 首本机歌”误报成完整成功。
    private struct LibrarySongFetchResult {
        let songs: [MusicKit.Song]
        let fallbackWarning: String?
        let syncMode: AppleMusicLibrarySyncMode
    }

    enum SyncState: Sendable {
        case idle
        case syncing
        case done(songCount: Int, at: Date)
        case failed(String)
    }

    private(set) var state: SyncState = .idle
    /// 最近一次完成扫描的时间, 用于 UI 显示。
    private(set) var lastSyncAt: Date?

    private let library: MusicLibrary
    private let appleMusic: AppleMusicService
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = UUID()
    /// 进度看门狗用的时间戳 ── 每收到一页 user library / 处理完一个歌单就续期。
    /// 看门狗只在「连续 stallTimeout 秒没有任何进度」时才判超时, 而不是给整个 sync
    /// 一个固定总时限。大库 (几千首 + 几十个歌单, 多次网络往返) 只要还在持续推进就
    /// 不会被误杀; 真正卡死 (网络挂起) 才会触发, 避免大库用户陷入永久"同步超时"循环。
    private var lastSyncProgressAt: Date = .distantPast
    /// 单步无进度的容忍窗口。一页 / 一个歌单的网络往返远小于这个值, 只有真卡住才会超。
    private static let syncStallTimeout: TimeInterval = 30
    /// in-memory cache: PrimuseKit.Song.filePath (= MusicItemID.rawValue)
    /// → MusicKit.Song. sync 时填, play 时查 — 让 player.play(primuseSong)
    /// 不用每次再发 catalog lookup。冷启动后 cache 空, miss 时回退到
    /// MusicCatalogResourceRequest 拉一次。
    private var songCache: [String: MusicKit.Song] = [:]
    /// Distinguishes a completed (possibly empty) library snapshot from a
    /// one-off cold artwork lookup that happened to insert a single item.
    private var hasCompletedLibrarySnapshot = false
    /// Canonical user-library entries only. `songCache` may also contain
    /// catalog-only tracks discovered through a playlist; using that mixed map
    /// for identity resolution can accidentally prefer the transient catalog
    /// object over its stable `i.*` library counterpart.
    private var canonicalLibrarySongCache: [String: MusicKit.Song] = [:]
    /// MusicKit artwork objects cannot be reconstructed from their persisted
    /// `musicKit://` URL. Keep the official playlist artwork beside the song
    /// cache so the shared playlist resolver can render it with ArtworkImage.
    private var playlistArtworkCache: [String: MusicKit.Artwork] = [:]
    /// Music.app rows that the platform media library independently resolves
    /// to readable, non-cloud, non-DRM assets. MusicKit may identify these rows
    /// with a library ID, signed decimal persistent ID, or hexadecimal ID.
    private var subscriptionIndependentLocalFileIDs: Set<String> = []
    /// Direct single-song playback can resolve a MusicKit row before the first
    /// full sync. Load device provenance separately so that cold playback does
    /// not classify an imported item with an empty trust set.
    private var hasLoadedLocalFileProvenance = false

    init(library: MusicLibrary, appleMusic: AppleMusicService) {
        self.library = library
        self.appleMusic = appleMusic
    }

    /// 启动一次完整拉取。不持有任何分页 cursor — Apple Music user library 量
    /// 不大 (大部分用户几百到几千首), 一次性拉全。失败时 state=.failed, UI
    /// 显示错误并允许重试。
    func sync() {
        guard AppleMusicFeatureSettings.syncUserLibraryEnabled else {
            cancel()
            return
        }
        guard !library.disabledSourceIDs.contains(Self.systemSourceID) else {
            cancel()
            return
        }
        guard syncTask == nil else { return }
        guard appleMusic.authState == .authorized else {
            state = .failed(String(localized: "apple_music_library_not_authorized"))
            return
        }
        state = .syncing
        let generation = UUID()
        syncGeneration = generation
        syncTask = Task { [weak self] in
            await self?.runSync(generation: generation)
        }
        scheduleSyncTimeout(generation: generation)
    }

    /// play 入口用 ── songCache 空 (重启或刚装) 时同步等一次完整 sync, 让
    /// ApplicationMusicPlayer queue 能装上 user library 全集; 已经在跑的 sync
    /// 任务会被 await 直接复用, 不会重复触发。
    private func playbackRequestCanContinue(_ requestID: UUID) -> Bool {
        AppleMusicLibraryPlaybackGatePolicy.canContinue(
            requestIsPending: appleMusic.isPlaybackRequestPending(requestID),
            isCancelled: Task.isCancelled,
            syncEnabled: AppleMusicFeatureSettings.syncUserLibraryEnabled,
            sourceEnabled: !library.disabledSourceIDs.contains(Self.systemSourceID),
            isAuthorized: appleMusic.authState == .authorized
        )
    }

    private func failUnavailablePlaybackRequestIfCurrent(_ requestID: UUID) {
        guard appleMusic.isPlaybackRequestPending(requestID),
              !Task.isCancelled else { return }
        appleMusic.failPlaybackRequest(
            requestID,
            message: String(localized: "playback_error_apple_music_generic")
        )
    }

    /// Waiting on `Task.value` does not return promptly when only the waiter is
    /// cancelled. Poll the shared generation instead so superseded playback
    /// requests leave within one tick while the reusable library sync continues.
    private func waitForSyncCompletion(
        generation: UUID,
        requestID: UUID
    ) async -> Bool {
        while syncGeneration == generation, syncTask != nil {
            guard playbackRequestCanContinue(requestID) else { return false }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return playbackRequestCanContinue(requestID)
    }

    private func ensureCachePopulated(for requestID: UUID) async -> Bool {
        guard playbackRequestCanContinue(requestID) else { return false }
        if syncTask != nil {
            let existingGeneration = syncGeneration
            guard await waitForSyncCompletion(
                generation: existingGeneration,
                requestID: requestID
            ) else { return false }
            if hasCompletedLibrarySnapshot { return true }
        }
        if hasCompletedLibrarySnapshot { return true }
        guard playbackRequestCanContinue(requestID) else { return false }
        state = .syncing
        let generation = UUID()
        syncGeneration = generation
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.runSync(generation: generation)
        }
        syncTask = task
        scheduleSyncTimeout(generation: generation)
        return await waitForSyncCompletion(
            generation: generation,
            requestID: requestID
        )
    }

    /// 用 PrimuseKit.Song 在系统侧起播 — filePath 字段实际是 MusicItemID。
    /// 缓存命中直接 play, miss 时走 catalog lookup 兜底 (冷启动场景)。
    ///
    /// `queueContext` 是调用方当前 Apple Music 播放上下文。传入混合队列中的
    /// 单首歌时，ApplicationMusicPlayer 只负责该 DRM 曲目，跨来源切歌仍由
    /// AudioPlayerService 管理；传入纯 Apple Music 歌单时则保留系统队列能力。
    func play(
        primuseSong song: PrimuseKit.Song,
        queueContext: [PrimuseKit.Song]? = nil,
        requestID: UUID
    ) async {
        await ensureLocalFileProvenanceLoaded()
        guard playbackRequestCanContinue(requestID) else {
            failUnavailablePlaybackRequestIfCurrent(requestID)
            return
        }
        let appleMusicQueueContext = queueContext?.filter {
            $0.sourceID == Self.systemSourceID
        }
        let requiresCompleteLibrarySnapshot = AppleMusicPlaybackCachePolicy
            .requiresCompleteLibrarySnapshot(
                hasQueueContext: queueContext != nil,
                appleMusicItemCount: appleMusicQueueContext?.count ?? 0
            )

        // A full Apple Music queue needs a complete cache to preserve its
        // ordering. Primuse-managed playback passes exactly one DRM item, so
        // resolve that item first instead of blocking on an unrelated large
        // library sync during cold launch.
        if requiresCompleteLibrarySnapshot {
            guard await ensureCachePopulated(for: requestID) else {
                failUnavailablePlaybackRequestIfCurrent(requestID)
                return
            }
        }

        let amID = song.filePath
        var resolvedMusicKitSong = await musicKitSong(amID: amID)
        if resolvedMusicKitSong == nil, !requiresCompleteLibrarySnapshot {
            // A direct user-library lookup can miss while MusicKit is still
            // hydrating its cold cache. Reuse the shared full sync as a
            // fallback, then retry the requested item without changing the
            // visible Primuse queue.
            guard await ensureCachePopulated(for: requestID) else {
                failUnavailablePlaybackRequestIfCurrent(requestID)
                return
            }
            if let cachedMusicKitSong = songCache[amID] {
                resolvedMusicKitSong = cachedMusicKitSong
            } else {
                resolvedMusicKitSong = await musicKitSong(amID: amID)
            }
        }
        guard playbackRequestCanContinue(requestID) else {
            failUnavailablePlaybackRequestIfCurrent(requestID)
            return
        }
        guard let mk = resolvedMusicKitSong else {
            plog("⚠️Apple Music 找不到曲目 \(amID)")
            appleMusic.failPlaybackRequest(
                requestID,
                message: String(localized: "playback_error_apple_music_generic")
            )
            return
        }
        // Prefer the exact queue selected in Primuse. Falling back to the full
        // Apple Music cache preserves the legacy direct-play behaviour for
        // callers that do not have a queue context.
        let contextualQueue: [MusicKit.Song]? = appleMusicQueueContext?.compactMap { contextSong in
            return songCache[contextSong.filePath]
        }
        let queue: [MusicKit.Song]
        if let contextualQueue,
           !contextualQueue.isEmpty,
           contextualQueue.contains(where: { $0.id == mk.id }) {
            queue = contextualQueue
        } else {
            queue = orderedQueueFromCache()
        }
        let startingSource = playbackSource(for: mk)
        let queuedSources = queue.map(playbackSource(for:))
        let plan = AppleMusicSystemQueuePolicy.plan(
            startingItemID: mk.id.rawValue,
            startingSource: startingSource,
            queuedItemIDs: queue.map { $0.id.rawValue },
            queuedSources: queuedSources
        )
        let systemQueue: [MusicKit.Song]
        let startIndex: Int
        if let plan {
            systemQueue = plan.retainedIndices.map { queue[$0] }
            startIndex = plan.startIndex
        } else {
            // A cold/direct play can race cache population or receive a stale
            // queue context that does not contain the requested item. Keep the
            // requested row itself instead of starting an unrelated cached song.
            systemQueue = [mk]
            startIndex = 0
        }
        guard playbackRequestCanContinue(requestID) else {
            failUnavailablePlaybackRequestIfCurrent(requestID)
            return
        }
        await appleMusic.playUserLibrary(
            songs: systemQueue,
            startAt: startIndex,
            source: startingSource,
            expectedDuration: song.duration,
            requestID: requestID,
            requestCanContinue: { [weak self] in
                self?.playbackRequestCanContinue(requestID) == true
            }
        )
    }

    /// 取 songCache 的稳定排序 ── 用 libraryAddedDate 倒序 (新加的在前),
    /// fallback 用 title。保证两次调用得到同样的 queue 顺序, skipToPrev/Next
    /// 行为可预期。
    private func orderedQueueFromCache() -> [MusicKit.Song] {
        songCache.values.sorted { a, b in
            switch (a.libraryAddedDate, b.libraryAddedDate) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title < b.title
            }
        }
    }

    /// 查这首歌在 Apple Music 上**是否有歌词** (only 一个 bool 信号)。
    /// Apple MusicKit 公开 API 不暴露歌词内容 (`Song.hasLyrics` 是 Bool, 没有
    /// `.lyrics` 文本字段, time-synced lyrics 更是完全闭源)。UI 用这个返回值
    /// 决定要不要显示 "在 Apple Music 中看歌词" 按钮 — 真要看歌词只能跳到
    /// Apple Music App。
    func fetchHasLyrics(forFilePath amID: String) async -> Bool {
        let id = MusicItemID(rawValue: amID)
        let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: id)
        do {
            let resp = try await request.response()
            return resp.items.first?.hasLyrics ?? false
        } catch {
            plog("⚠️Apple Music hasLyrics check failed for \(amID): \(error.localizedDescription)")
            return false
        }
    }

    func cancel() {
        syncGeneration = UUID()
        syncTask?.cancel()
        syncTask = nil
        state = .idle
    }

    /// 给 UI 层 (CachedArtworkView) 用 ── 拿到 MusicKit.Song 后通过 ArtworkImage
    /// 渲染封面 (Apple Music user library 的 artwork.url 是 musicKit:// scheme,
    /// 必须走 framework 解码)。cache miss 返回 nil, view 显示 placeholder, 用户
    /// 触发 play(primuseSong:) 后 cache 会被填上。
    func cachedMusicKitSong(amID: String) -> MusicKit.Song? {
        songCache[amID]
    }

    func cachedMusicKitPlaylistArtwork(playlistID: String) -> MusicKit.Artwork? {
        playlistArtworkCache[playlistID]
    }

    /// Resolves one MusicKit item without waiting for a full-library sync.
    /// CloudKit can restore Primuse's lightweight Song rows before the in-memory
    /// MusicKit cache exists; artwork views use this method to fill that cold
    /// cache and render the official artwork instead of a gray placeholder.
    func musicKitSong(amID: String) async -> MusicKit.Song? {
        if let cached = songCache[amID] { return cached }
        guard appleMusic.authState == .authorized else { return nil }

        let id = MusicItemID(rawValue: amID)
        do {
            let resolved: MusicKit.Song?
            if AppleMusicItemLookupPolicy.shouldUseUserLibrary(
                itemID: amID,
                confirmedLocalFileIDs: subscriptionIndependentLocalFileIDs
            ) {
                var request = MusicLibraryRequest<MusicKit.Song>()
                request.filter(matching: \.id, equalTo: id)
                request.limit = 1
                resolved = try await request.response().items.first
            } else {
                let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: id)
                resolved = try await request.response().items.first
            }
            if let resolved {
                songCache[amID] = resolved
                if AppleMusicItemLookupPolicy.shouldUseUserLibrary(
                    itemID: amID,
                    confirmedLocalFileIDs: subscriptionIndependentLocalFileIDs
                ) {
                    canonicalLibrarySongCache[amID] = resolved
                }
            }
            return resolved
        } catch {
            plog("⚠️Apple Music lookup failed for \(amID): \(error.localizedDescription)")
            return nil
        }
    }

    /// 拿当前歌在 Apple Music app 里的 URL ── 给 NowPlayingView 提供"在
    /// Apple Music 中打开 / 看歌词"按钮的跳转目标。
    ///
    /// user library 拉回来的 Song 的 `.url` 字段通常是 nil (没暴露公开
    /// catalog URL), 所以走 3 级 fallback:
    ///  1. song.url (catalog Song 才有)
    ///  2. 用 title + artist 拼 Apple Music app 的 search URL ── `music://` scheme
    ///     iOS 会直接拉起 Apple Music app 跳到搜索页, 用户能看到自家歌词
    func catalogURL(for song: PrimuseKit.Song) -> URL? {
        guard song.sourceID == Self.systemSourceID else { return nil }
        if let direct = songCache[song.filePath]?.url { return direct }
        // Fallback: 拼 search URL 用 music:// scheme 直接打开 Apple Music app
        let title = song.title
        let artist = song.artistName ?? ""
        let term = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              !encoded.isEmpty else { return nil }
        return URL(string: "music://music.apple.com/search?term=\(encoded)")
    }

    /// 拉这首 Apple Music 歌的官方歌词 ── **当前永远返回 nil**。
    ///
    /// 不是没写实现, 是 Apple 在 MusicKit Swift API 里**没有把 lyrics 暴露给
    /// 第三方 app**: Song 的 PartialMusicAsyncProperty 只支持
    /// .albums / .artists / .composers / .genres / .musicVideos / .station /
    /// .audioVariants, 编译期就拿不到 .lyrics keypath (MusicKit JS web 端才有
    /// lyrics endpoint)。
    ///
    /// 留这个入口 + 文件末尾的 TTMLLyricsParser 是基础设施 ── 等 Apple 之后开放
    /// (或我们能拿到私有 entitlement), 把这函数的实现填回去就 work, NowPlayingView
    /// 不用动。
    ///
    /// 当前 UI 走的路径: 这里 return nil → NowPlayingView setLyrics([]) → 显示
    /// emptyLyricsView 的"在 Apple Music 中查看歌词"按钮跳转 Apple Music app。
    func fetchLyrics(forAmID amID: String) async throws -> [LyricLine]? {
        _ = amID   // 抑制 unused warning
        return nil
    }

    /// 把 ApplicationMusicPlayer 返回的 Song 规范化到 user library 版本。
    /// ApplicationMusicPlayer.queue.currentEntry.item 给的常常是 catalog Song
    /// (id 是纯数字), 跟我们 sync 拉回来的 user library Song (id `i.*`) 不一样,
    /// 直接用会让下游所有按 id 做 cache lookup 的代码 miss (封面 / 跳转 URL)。
    /// 优先使用 MusicKit playParameters 里的 catalog/library ID 交叉映射；字段
    /// 不完整时再用标准化标题、歌手、专辑和时长做保守匹配。匹配不唯一时宁可
    /// 返回原 song，也不把歌词关联到另一首同名歌曲。
    func canonicalForNowPlaying(_ s: MusicKit.Song) -> MusicKit.Song {
        if let exact = canonicalLibrarySongCache[s.id.rawValue] { return exact }
        let candidates = canonicalLibrarySongCache.values.map(Self.trackIdentity)
        guard let canonicalID = AppleMusicTrackIdentityResolver.canonicalID(
            for: Self.trackIdentity(s),
            in: candidates
        ) else { return s }
        return canonicalLibrarySongCache[canonicalID] ?? s
    }

    /// Canonical Primuse projection used by the player and scrape actions.
    /// Returning the current MusicLibrary row preserves locally-added fields
    /// such as `lyricsFileName` instead of rebuilding a bare MusicKit value.
    func canonicalPrimuseSong(for s: MusicKit.Song) -> PrimuseKit.Song {
        let projected = Self.toPrimuseSong(canonicalForNowPlaying(s))
        return library.song(id: projected.id) ?? canonicalLibrarySong(for: projected)
    }

    /// Defense-in-depth for callers that only have a projected Primuse song
    /// (for example a scrape button tapped during a MusicKit queue transition).
    func canonicalLibrarySong(for song: PrimuseKit.Song) -> PrimuseKit.Song {
        guard song.sourceID == Self.systemSourceID else { return song }
        if let exact = library.song(id: song.id), exact.sourceID == Self.systemSourceID {
            return exact
        }
        let librarySongs = library.songs.filter { $0.sourceID == Self.systemSourceID }
        let candidates = librarySongs.map(Self.trackIdentity)
        guard let canonicalID = AppleMusicTrackIdentityResolver.canonicalID(
            for: Self.trackIdentity(song),
            in: candidates
        ) else { return song }
        return library.song(id: canonicalID) ?? song
    }

    private nonisolated static func trackIdentity(_ song: MusicKit.Song) -> AppleMusicTrackIdentity {
        AppleMusicTrackIdentity(
            itemID: song.id.rawValue,
            alternateIDs: alternateMusicItemIDs(for: song),
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            duration: song.duration
        )
    }

    /// MusicKit exposes `PlayParameters` only as Codable. A library row with a
    /// catalog/global ID is still subscription-backed; only a row whose stable
    /// identifiers also match a readable, non-cloud, non-DRM platform media
    /// item may play without `canPlayCatalogContent`.
    private func playbackSource(
        for song: MusicKit.Song
    ) -> AppleMusicPlaybackSource {
        let identifiers = Self.musicItemIdentifiers(for: song)
        let matchedLocalFileIDs = identifiers.all.intersection(
            subscriptionIndependentLocalFileIDs
        )
        let hasConfirmedLocalFile = AppleMusicLocalFileProvenancePolicy.confirmsLibrarySong(
            itemID: song.id.rawValue,
            playParameterIDs: identifiers.genericPlayParameterIDs,
            persistentIDs: identifiers.persistentIDs,
            confirmedLibraryIDs: identifiers.confirmedLibraryIDs,
            confirmedLocalFileIDs: matchedLocalFileIDs
        )
        let source = AppleMusicPlaybackSourceResolver.resolve(
            itemID: song.id.rawValue,
            explicitCatalogIDs: identifiers.explicitCatalogIDs,
            genericPlayParameterIDs: identifiers.genericPlayParameterIDs,
            confirmedLibraryIDs: identifiers.confirmedLibraryIDs,
            confirmedLocalFileIDs: hasConfirmedLocalFile ? matchedLocalFileIDs : []
        )
        let libraryFlag = identifiers.declaresLibraryItem.map(String.init) ?? "missing"
        let hasSongKind = identifiers.mediaKinds.contains {
            $0.caseInsensitiveCompare("song") == .orderedSame
        }
        plog(
            "🎵 Apple Music route: idType=\(Self.diagnosticIDType(song.id.rawValue)) "
                + "playParameters=\(song.playParameters != nil) "
                + "catalogID=\(!identifiers.explicitCatalogIDs.isEmpty) "
                + "persistentID=\(!identifiers.persistentIDs.isEmpty) "
                + "localPersistentMatch=\(!matchedLocalFileIDs.isEmpty) "
                + "libraryFlag=\(libraryFlag) "
                + "kindSong=\(hasSongKind) "
                + "source=\(source)"
        )
        return source
    }

    private nonisolated static func diagnosticIDType(_ value: String) -> String {
        if value.hasPrefix("i.") { return "library" }
        if Int64(value) != nil || UInt64(value) != nil { return "decimal" }
        if !value.isEmpty, value.count <= 16, value.allSatisfy(\.isHexDigit) { return "hex" }
        return "opaque"
    }

    private nonisolated static func trackIdentity(_ song: PrimuseKit.Song) -> AppleMusicTrackIdentity {
        AppleMusicTrackIdentity(
            itemID: song.id,
            alternateIDs: [song.filePath],
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            duration: song.duration > 0 ? song.duration : nil
        )
    }

    /// `PlayParameters` intentionally exposes no Swift properties, but is
    /// Codable. Apple includes both the playable/catalog ID and (for library
    /// items) the library ID in that payload, so decode only the documented ID
    /// shaped keys and ignore reporting/account fields.
    private nonisolated static func alternateMusicItemIDs(for song: MusicKit.Song) -> Set<String> {
        musicItemIdentifiers(for: song).all
    }

    private nonisolated struct MusicItemIdentifiers {
        var all: Set<String>
        var explicitCatalogIDs: Set<String> = []
        var genericPlayParameterIDs: Set<String> = []
        var persistentIDs: Set<String> = []
        var mediaKinds: Set<String> = []
        var declaresLibraryItem: Bool?
        /// Library identities observed in successfully decoded PlayParameters.
        /// The raw Song.id is deliberately not inserted here: it is the value
        /// being verified, not independent evidence that playback is local.
        var confirmedLibraryIDs: Set<String> = []
    }

    private nonisolated static func musicItemIdentifiers(
        for song: MusicKit.Song
    ) -> MusicItemIdentifiers {
        var result = MusicItemIdentifiers(all: [song.id.rawValue])
        if let playParameters = song.playParameters,
           let data = try? JSONEncoder().encode(playParameters),
           let object = try? JSONSerialization.jsonObject(with: data) {
            collectMusicItemIDs(from: object, into: &result)
        }
        if let url = song.url,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] where item.name.lowercased() == "i" {
                if let value = item.value, !value.isEmpty {
                    result.all.insert(value)
                    result.explicitCatalogIDs.insert(value)
                }
            }
        }
        return result
    }

    private nonisolated static func collectMusicItemIDs(
        from object: Any,
        into result: inout MusicItemIdentifiers
    ) {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let normalizedKey = key.lowercased().filter(\.isLetter)
                if normalizedKey == "islibrary", let isLibrary = value as? Bool {
                    result.declaresLibraryItem = (result.declaresLibraryItem ?? true) && isLibrary
                } else if normalizedKey == "kind", let kind = value as? String {
                    result.mediaKinds.insert(kind)
                } else if normalizedKey == "musickitpersistentid",
                          let persistentID = identifierString(from: value) {
                    result.all.insert(persistentID)
                    result.persistentIDs.insert(persistentID)
                } else if ["id", "catalogid", "globalid", "libraryid"].contains(normalizedKey),
                          let id = identifierString(from: value) {
                    result.all.insert(id)
                    if normalizedKey == "catalogid" || normalizedKey == "globalid" {
                        result.explicitCatalogIDs.insert(id)
                    } else if normalizedKey == "id" {
                        result.genericPlayParameterIDs.insert(id)
                        if id.hasPrefix("i.") {
                            result.confirmedLibraryIDs.insert(id)
                        }
                    } else if normalizedKey == "libraryid", id.hasPrefix("i.") {
                        result.confirmedLibraryIDs.insert(id)
                    }
                } else {
                    collectMusicItemIDs(from: value, into: &result)
                }
            }
        } else if let array = object as? [Any] {
            for value in array { collectMusicItemIDs(from: value, into: &result) }
        }
    }

    private nonisolated static func identifierString(from value: Any) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if value is Bool { return nil }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    /// 标记同步又往前走了一步 (拉到一页 / 处理完一个歌单) ── 给看门狗续期。
    /// 必须在 @MainActor 上调用 (本类整体 @MainActor 隔离, runSync 也是), 直接写。
    private func markSyncProgress() {
        lastSyncProgressAt = Date()
    }

    /// 进度看门狗: 不给整个 sync 一个固定总时限 (大库会被误杀), 而是每隔一小段轮询,
    /// 只要 `lastSyncProgressAt` 还在持续刷新就一直等; 连续 `syncStallTimeout` 秒没有
    /// 任何进度才判定卡死, cancel 并置 .failed。这样几千首 + 几十个歌单的大库只要还在
    /// 推进就不会超时, 真正网络挂起才会触发。
    private func scheduleSyncTimeout(generation: UUID) {
        // 开始计时基准 ── 让首页请求也有完整的 stall 窗口。
        markSyncProgress()
        Task { [weak self] in
            // 轮询粒度: 1s 检查一次。看门狗在以下三种情况退出: sync 已结束 (generation
            // 变了 / syncTask 清空)、或连续 stall 满 syncStallTimeout 判超时。
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                let timedOut: Bool = await MainActor.run { [weak self] in
                    guard let self,
                          self.syncGeneration == generation,
                          self.syncTask != nil else {
                        // sync 已经收尾, 看门狗用完即弃。
                        return false
                    }
                    guard Date().timeIntervalSince(self.lastSyncProgressAt) >= Self.syncStallTimeout else {
                        return false
                    }
                    self.syncTask?.cancel()
                    self.syncTask = nil
                    self.syncGeneration = UUID()
                    self.state = .failed(String(localized: "apple_music_library_sync_timeout"))
                    plog("⚠️Apple Music library sync timeout (stalled \(Int(Self.syncStallTimeout))s)")
                    return true
                }
                if timedOut { return }
                // sync 已结束 (generation 变更 / syncTask 清空) 时退出, 不再空转。
                let stillRunning = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.syncGeneration == generation && self.syncTask != nil
                }
                if !stillRunning { return }
            }
        }
    }

    private func runSync(generation: UUID) async {
        defer {
            if syncGeneration == generation {
                syncTask = nil
            }
        }
        do {
            await refreshSubscriptionIndependentLocalFileIDs()
            let fetchResult = try await fetchLibrarySongs()
            let allMusicKitSongs = fetchResult.songs

            if Task.isCancelled { return }
            plog("🎵 Apple Music library fetched: \(allMusicKitSongs.count) songs")
            guard syncGeneration == generation else { return }

            // 把 MusicKit.Song 缓存住, play 时直接喂给 ApplicationMusicPlayer
            // 不用走 catalog lookup。
            // This is a full snapshot, so replace rather than append. Otherwise
            // tracks removed from Apple Music (including the two stale local
            // rows seen on macOS) remain playable in the in-memory queue.
            let fetchedSongCache = Dictionary(
                uniqueKeysWithValues: allMusicKitSongs.map { ($0.id.rawValue, $0) }
            )
            if fetchResult.syncMode == .authoritative {
                songCache = fetchedSongCache
                canonicalLibrarySongCache = fetchedSongCache
            } else {
                // A local-only fallback is incomplete. Keep any canonical
                // cloud entries already known in this process and merely add
                // the locally available items.
                songCache.merge(fetchedSongCache) { _, incoming in incoming }
                canonicalLibrarySongCache.merge(fetchedSongCache) { _, incoming in incoming }
            }
            hasCompletedLibrarySnapshot = true
            let songs = allMusicKitSongs.map { Self.toPrimuseSong($0) }
            // 把这些歌加进 library, sourceIDs 限定 Apple Music, 让 addSongs
            // 自己处理删除 (Apple Music 删歌的 case 会被检测到)。
            library.addSongs(
                songs,
                affectedSourceIDs: [Self.systemSourceID],
                notifyRemovals: fetchResult.syncMode.shouldPruneMissingSongs,
                pruneMissingSongs: fetchResult.syncMode.shouldPruneMissingSongs
            )

            // 同步生成「Apple Music 资料库」镜像歌单 ── 让用户在资料库 →
            // 播放列表里直接看到这一坨同步过来的歌, 而不是被混进总库里找不见。
            library.ensurePlaylist(
                id: Self.systemPlaylistID,
                name: String(localized: "apple_music_library_playlist_name")
            )
            if fetchResult.syncMode.shouldReplaceMirrorPlaylist {
                library.replaceMirrorPlaylistSongs(
                    playlistID: Self.systemPlaylistID,
                    songIDs: songs.map(\.id),
                    coverArtPath: nil
                )
            } else {
                var mergedIDs = library.rawSongIDs(forPlaylist: Self.systemPlaylistID)
                var seenIDs = Set(mergedIDs)
                mergedIDs.append(contentsOf: songs.map(\.id).filter { seenIDs.insert($0).inserted })
                library.replaceMirrorPlaylistSongs(
                    playlistID: Self.systemPlaylistID,
                    songIDs: mergedIDs,
                    coverArtPath: nil
                )
            }

            // 临时诊断 ── 摸清同步过来的 cover URL 实际形态, 帮排查"歌没封面"。
            let withCover = songs.filter { $0.coverArtFileName != nil }.count
            let firstSample = songs.first.flatMap { $0.coverArtFileName }?.prefix(120) ?? "nil"
            plog("🎵 Apple Music covers: \(withCover)/\(songs.count) have URL, first='\(firstSample)'")

            // 拉用户在 Apple Music 里建的 playlists, 每个映射成独立的本地镜像歌单
            // (跟「Apple Music 资料库」全集并存)。tracks 走 .with([.tracks])
            // 延迟加载关系, 失败的 playlist 跳过不阻塞整体 sync。
            let syncedUserPlaylistCount = fetchResult.syncMode == .authoritative
                ? await syncUserPlaylists()
                : 0
            guard syncGeneration == generation else { return }

            lastSyncAt = Date()
            if let warning = fetchResult.fallbackWarning {
                state = .failed(warning)
                plog("⚠️Apple Music library partially synced: \(songs.count) local songs preserved; \(warning)")
            } else {
                state = .done(songCount: songs.count, at: lastSyncAt!)
                plog("🎵 Apple Music library synced: \(songs.count) songs, \(syncedUserPlaylistCount) playlists → playlist \(Self.systemPlaylistID)")
            }
        } catch is CancellationError {
            if syncGeneration == generation {
                state = .idle
            }
        } catch {
            plog("⚠️Apple Music library sync failed: \(error.localizedDescription)")
            if syncGeneration == generation {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Refreshes trusted local-file provenance before every MusicKit snapshot.
    /// Failure is intentionally fail-closed: no row may bypass the catalog
    /// preflight unless the current process can re-confirm its local file.
    private func ensureLocalFileProvenanceLoaded() async {
        guard !hasLoadedLocalFileProvenance else { return }
        await refreshSubscriptionIndependentLocalFileIDs()
    }

    private func refreshSubscriptionIndependentLocalFileIDs() async {
        #if os(iOS)
        let result = Self.loadSubscriptionIndependentLocalFileIDs()
        subscriptionIndependentLocalFileIDs = result.ids
        hasLoadedLocalFileProvenance = result.isAuthorized
        plog(
            "🎵 Apple Music local-file provenance: total=\(result.totalCount) "
                + "eligible=\(result.eligibleCount) cloud=\(result.cloudCount) "
                + "protected=\(result.protectedCount) noAsset=\(result.noAssetCount) "
                + "authorization=\(result.authorization)"
        )
        #elseif os(macOS)
        let result = await Task.detached(priority: .utility) {
            Self.loadSubscriptionIndependentLocalFileIDs()
        }.value
        if let error = result.error {
            subscriptionIndependentLocalFileIDs.removeAll()
            plog("⚠️Apple Music local-file provenance unavailable: \(error)")
        } else {
            subscriptionIndependentLocalFileIDs = result.ids
            plog("🎵 Apple Music local-file provenance: \(result.itemCount) readable non-DRM songs")
        }
        hasLoadedLocalFileProvenance = true
        #else
        subscriptionIndependentLocalFileIDs.removeAll()
        hasLoadedLocalFileProvenance = true
        #endif
    }

    #if os(iOS)
    private nonisolated static func loadSubscriptionIndependentLocalFileIDs() -> (
        ids: Set<String>,
        totalCount: Int,
        eligibleCount: Int,
        cloudCount: Int,
        protectedCount: Int,
        noAssetCount: Int,
        authorization: String,
        isAuthorized: Bool
    ) {
        let authorizationStatus = MPMediaLibrary.authorizationStatus()
        guard authorizationStatus == .authorized else {
            return ([], 0, 0, 0, 0, 0, String(describing: authorizationStatus), false)
        }

        let items = MPMediaQuery.songs().items ?? []
        var confirmedIDs = Set<String>()
        var eligibleCount = 0
        var cloudCount = 0
        var protectedCount = 0
        var noAssetCount = 0
        for item in items {
            let hasAssetURL = item.assetURL != nil
            if item.isCloudItem { cloudCount += 1 }
            if item.hasProtectedAsset { protectedCount += 1 }
            if !hasAssetURL { noAssetCount += 1 }
            guard AppleMusicLocalMediaEligibility.isSubscriptionIndependent(
                mediaTypeContainsMusic: item.mediaType.contains(.music),
                hasAssetURL: hasAssetURL,
                isCloudItem: item.isCloudItem,
                hasProtectedAsset: item.hasProtectedAsset
            ) else {
                continue
            }
            eligibleCount += 1
            confirmedIDs.formUnion(
                AppleMusicLocalFileIdentity.playbackIdentifiers(
                    forPersistentID: item.persistentID
                )
            )
        }
        return (
            confirmedIDs,
            items.count,
            eligibleCount,
            cloudCount,
            protectedCount,
            noAssetCount,
            String(describing: authorizationStatus),
            true
        )
    }
    #endif

    #if os(macOS)
    private nonisolated static func loadSubscriptionIndependentLocalFileIDs() -> (
        ids: Set<String>,
        itemCount: Int,
        error: String?
    ) {
        do {
            let localLibrary = try ITLibrary(apiVersion: "1.1", options: .lazyLoadData)
            var confirmedIDs = Set<String>()
            var confirmedItemCount = 0
            for item in localLibrary.allMediaItems {
                guard item.mediaKind == .kindSong,
                      item.locationType == .file,
                      !item.isDRMProtected,
                      let location = item.location,
                      location.isFileURL,
                      location.pathExtension.lowercased() != "m4p",
                      FileManager.default.isReadableFile(atPath: location.path) else {
                    continue
                }
                confirmedItemCount += 1
                confirmedIDs.formUnion(
                    AppleMusicLocalFileIdentity.playbackIdentifiers(
                        forPersistentID: item.persistentID.uint64Value
                    )
                )
            }
            return (confirmedIDs, confirmedItemCount, nil)
        } catch {
            return ([], 0, error.localizedDescription)
        }
    }
    #endif

    /// macOS 的 `MusicLibraryRequest` 读取 Music.app 保存在本机的资料库副本。
    /// 用户未打开「同步资料库」时它只会返回本机导入的几首歌，即使同一 Apple
    /// Account 的云端资料库还有很多歌曲。macOS 因此直接请求 Apple Music user
    /// library API；云端失败或意外返回空结果时只合并本机副本，不允许它缩减
    /// 已持久化的云端资料库。iOS 的本机副本会跟系统「同步资料库」一致，继续
    /// 使用系统请求以避免改变现有稳定路径。
    private func fetchLibrarySongs() async throws -> LibrarySongFetchResult {
        #if os(macOS)
        do {
            let cloudSongs: [MusicKit.Song] = try await fetchCloudLibraryItems(endpoint: .songs)
            if !cloudSongs.isEmpty {
                plog("🎵 Apple Music cloud library fetched: \(cloudSongs.count) songs")
                return LibrarySongFetchResult(
                    songs: cloudSongs,
                    fallbackWarning: nil,
                    syncMode: .authoritative
                )
            }
            plog("⚠️Apple Music cloud library is empty; preserving the existing library and merging the local Music library")
            let localSongs = try await fetchDeviceLibrarySongs()
            let warning = String(
                format: String(localized: "apple_music_cloud_library_unavailable_format"),
                "—",
                localSongs.count
            )
            return LibrarySongFetchResult(
                songs: localSongs,
                fallbackWarning: warning,
                syncMode: .partialFallback
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MusicDataRequest.Error {
            let responseBody = String(data: error.originalResponse.data, encoding: .utf8) ?? "<non-UTF8>"
            plog("⚠️Apple Music cloud API failed status=\(error.status) code=\(error.code) title='\(error.title)' detail='\(error.detailText)' body=\(responseBody.prefix(1000)); falling back to local Music library")
            let localSongs = try await fetchDeviceLibrarySongs()
            let warning = String(
                format: String(localized: "apple_music_cloud_library_unavailable_format"),
                String(describing: error.code),
                localSongs.count
            )
            return LibrarySongFetchResult(
                songs: localSongs,
                fallbackWarning: warning,
                syncMode: .partialFallback
            )
        } catch {
            plog("⚠️Apple Music cloud API failed: \(String(reflecting: error)); falling back to local Music library")
            let localSongs = try await fetchDeviceLibrarySongs()
            let warning = String(
                format: String(localized: "apple_music_cloud_library_unavailable_format"),
                "—",
                localSongs.count
            )
            return LibrarySongFetchResult(
                songs: localSongs,
                fallbackWarning: warning,
                syncMode: .partialFallback
            )
        }
        #else
        return LibrarySongFetchResult(
            songs: try await fetchDeviceLibrarySongs(),
            fallbackWarning: nil,
            syncMode: .authoritative
        )
        #endif
    }

    private func fetchDeviceLibrarySongs() async throws -> [MusicKit.Song] {
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.limit = 100
        request.includeOnlyDownloadedContent = false
        let response = try await request.response()
        markSyncProgress()
        var songs = Array(response.items)
        var currentBatch = response.items
        while currentBatch.hasNextBatch {
            try Task.checkCancellation()
            guard let next = try await currentBatch.nextBatch() else { break }
            songs.append(contentsOf: next)
            currentBatch = next
            markSyncProgress()
        }
        return Self.uniquedMusicItems(songs)
    }

    /// Loads a complete Apple Music API collection with MusicKit-managed
    /// developer and music-user tokens. Pagination URLs are validated by
    /// PrimuseKit before another authenticated request is issued.
    private func fetchCloudLibraryItems<Item>(
        endpoint: AppleMusicLibraryAPI.Endpoint
    ) async throws -> [Item] where Item: MusicKit.MusicItem & Decodable {
        var nextURL: URL? = AppleMusicLibraryAPI.initialURL(for: endpoint)
        var visitedURLs = Set<String>()
        var items: [Item] = []

        while let pageURL = nextURL {
            try Task.checkCancellation()
            guard visitedURLs.insert(pageURL.absoluteString).inserted else {
                throw AppleMusicLibraryAPI.PaginationError.invalidNextURL(pageURL.absoluteString)
            }

            var urlRequest = URLRequest(url: pageURL)
            urlRequest.timeoutInterval = Self.syncStallTimeout
            let response = try await MusicDataRequest(urlRequest: urlRequest).response()
            let page = try JSONDecoder().decode(MusicItemCollection<Item>.self, from: response.data)
            items.append(contentsOf: page)
            nextURL = try AppleMusicLibraryAPI.nextPageURL(from: response.data, endpoint: endpoint)
            markSyncProgress()
        }
        return Self.uniquedMusicItems(items)
    }

    /// 每个 user playlist 在 Primuse 里建独立的镜像歌单 ── ID 用 amID 派生固定,
    /// 多次 sync 不会重复创建; name 跟 Apple Music 那边对齐, 用户改名后下次 sync
    /// 会被刷新 (ensurePlaylist 已经处理 name 同步)。
    /// 实现: 按平台拉用户全部歌单 (含分页), 每个用
    /// `.with([.tracks])` 把 tracks 拉过来, 转 PrimuseKit.Song 后 replace 进对应歌单。
    @discardableResult
    private func syncUserPlaylists() async -> Int {
        do {
            let allPlaylists = try await fetchLibraryPlaylists()
            plog("🎵 Apple Music user playlists: \(allPlaylists.count)")

            var fetchedMirrors: [UserPlaylistMirror] = []
            var failedIDs = Set<String>()
            for amPlaylist in allPlaylists {
                if Task.isCancelled { return 0 }
                let result = await fetchUserPlaylistMirror(amPlaylist)
                if Task.isCancelled { return 0 }
                markSyncProgress()   // 每处理完一个歌单 (含 .with([.tracks]) 往返) 续期
                switch result {
                case .mirror(let mirror):
                    fetchedMirrors.append(mirror)
                case .empty(let id, let name, let coverArtReference):
                    fetchedMirrors.append(UserPlaylistMirror(
                        id: id,
                        name: Self.safePlaylistName(name),
                        songIDs: [],
                        coverArtReference: coverArtReference
                    ))
                    plog("🎵 AM playlist '\(name)' is empty, preserving local mirror \(id)")
                case .unresolved(let id, let name, let count, let coverArtReference):
                    // 保住已有镜像 (如果存在), 别让 prune 当作"服务端已删"清掉。
                    if library.playlist(id: id) != nil {
                        failedIDs.insert(id)
                        library.updateMirrorPlaylistArtwork(
                            playlistID: id,
                            coverArtPath: coverArtReference,
                            forceRefresh: coverArtReference != nil
                        )
                    }
                    plog("""
                        ⚠️ AM playlist '\(name)' has \(count) track(s) on Apple Music but none \
                        resolved locally — keeping the existing mirror
                        """)
                case .failed(let id, let name, let coverArtReference, let error):
                    failedIDs.insert(id)
                    if library.playlist(id: id) != nil, let coverArtReference {
                        library.updateMirrorPlaylistArtwork(
                            playlistID: id,
                            coverArtPath: coverArtReference,
                            forceRefresh: true
                        )
                    }
                    plog("⚠️AM playlist '\(name)' fetch tracks failed: \(error)")
                }
            }

            let mirrorsToKeep = Self.resolveUserPlaylistMirrors(fetchedMirrors)
            for mirror in mirrorsToKeep {
                library.ensurePlaylist(id: mirror.id, name: mirror.name)
                library.replaceMirrorPlaylistSongs(
                    playlistID: mirror.id,
                    songIDs: mirror.songIDs,
                    coverArtPath: mirror.coverArtReference
                )
                plog("🎵 AM playlist '\(mirror.name)' → \(mirror.songIDs.count) songs")
            }

            let keepIDs = Set(mirrorsToKeep.map(\.id)).union(failedIDs)
            playlistArtworkCache = playlistArtworkCache.filter { keepIDs.contains($0.key) }
            library.prunePlaylists(
                withIDPrefix: Self.userPlaylistIDPrefix,
                keepingIDs: keepIDs
            )
            return mirrorsToKeep.count
        } catch is CancellationError {
            // ignore
            return 0
        } catch {
            plog("⚠️Apple Music playlist sync failed: \(error.localizedDescription)")
            return 0
        }
    }

    private func fetchLibraryPlaylists() async throws -> [MusicKit.Playlist] {
        #if os(macOS)
        return try await fetchCloudLibraryItems(endpoint: .playlists)
        #else
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.limit = 100
        let response = try await request.response()
        markSyncProgress()
        var playlists = Array(response.items)
        var currentBatch = response.items
        while currentBatch.hasNextBatch {
            try Task.checkCancellation()
            guard let next = try await currentBatch.nextBatch() else { break }
            playlists.append(contentsOf: next)
            currentBatch = next
            markSyncProgress()
        }
        return Self.uniquedMusicItems(playlists)
        #endif
    }

    private func fetchUserPlaylistMirror(_ amPlaylist: MusicKit.Playlist) async -> UserPlaylistFetchResult {
        let pid = "\(Self.userPlaylistIDPrefix)\(amPlaylist.id.rawValue)"
        let displayName = Self.safePlaylistName(amPlaylist.name)
        let summaryArtwork = amPlaylist.artwork
        if let summaryArtwork {
            playlistArtworkCache[pid] = summaryArtwork
        } else {
            playlistArtworkCache[pid] = nil
        }
        let summaryCoverReference = summaryArtwork?
            .url(width: 1024, height: 1024)?
            .absoluteString
        do {
            let detailed = try await amPlaylist.with([.tracks])
            let detailedArtwork = detailed.artwork ?? summaryArtwork
            if let detailedArtwork {
                playlistArtworkCache[pid] = detailedArtwork
            }
            let coverArtReference = detailedArtwork?
                .url(width: 1024, height: 1024)?
                .absoluteString
                ?? summaryCoverReference
            var currentBatch = detailed.tracks ?? []
            var tracks = Array(currentBatch)
            while currentBatch.hasNextBatch {
                try Task.checkCancellation()
                guard let next = try await currentBatch.nextBatch() else { break }
                tracks.append(contentsOf: next)
                currentBatch = next
                markSyncProgress()
            }
            let projectedSongIDs: [String] = tracks.compactMap { track in
                guard case let .song(s) = track else { return nil }
                // 顺手填 cache (有些用户歌单里的 song 可能不在 user library 全集)
                songCache[s.id.rawValue] = s
                // Playlist relationships may expose catalog songs even when
                // the same track exists as an `i.*` user-library item. Store
                // the relationship with the canonical ID so the mirrored
                // playlist continues to reference the persisted library row.
                return Self.toPrimuseSong(canonicalForNowPlaying(s)).id
            }
            // `replaceMirrorPlaylistSongs` 会丢弃曲库中不存在的 ID；先按同一条规则
            // 判断实际可写入的歌曲，避免“全是下架/未入库曲目”被误当成成功镜像，
            // 随后把已有歌单覆盖成空。
            let songIDs = Self.uniqued(projectedSongIDs).filter {
                library.song(id: $0)?.sourceID == Self.systemSourceID
            }
            // Apple Music 报告有曲目但本地一首都没匹配上 —— 可能全是视频、下架曲目、
            // 或 canonicalization 失败。这是"取不到", 不是"歌单空了", 保留已有镜像。
            if songIDs.isEmpty, tracks.isEmpty == false {
                return .unresolved(
                    id: pid,
                    name: displayName,
                    reportedTrackCount: tracks.count,
                    coverArtReference: coverArtReference
                )
            }
            if songIDs.isEmpty {
                return .empty(
                    id: pid,
                    name: displayName,
                    coverArtReference: coverArtReference
                )
            }
            return .mirror(UserPlaylistMirror(
                id: pid,
                name: displayName,
                songIDs: songIDs,
                coverArtReference: coverArtReference
            ))
        } catch {
            return .failed(
                id: pid,
                name: displayName,
                coverArtReference: summaryCoverReference,
                error: error.localizedDescription
            )
        }
    }

    private static func resolveUserPlaylistMirrors(_ mirrors: [UserPlaylistMirror]) -> [UserPlaylistMirror] {
        mirrors.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func safePlaylistName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "library_folder_apple_music_unnamed_playlist")
            : trimmed
    }

    private static func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func uniquedMusicItems<Item: MusicKit.MusicItem>(_ items: [Item]) -> [Item] {
        var seen = Set<MusicItemID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// MusicKit.Song → PrimuseKit.Song 映射。
    /// - songID 用 sha256(sourceID + AppleMusicID) — 跟 NAS 歌的 id 算法一致,
    ///   保证全局唯一且稳定 (同一首 Apple Music 歌每次 sync 都得到同一个 id)。
    /// - fileFormat: Apple Music 走系统 player, 实际格式由 ApplicationMusicPlayer
    ///   决定, 我们填 `.aac` 占位 (大部分 Apple Music 是 AAC)。
    nonisolated static func toPrimuseSong(_ s: MusicKit.Song) -> PrimuseKit.Song {
        let sourceID = Self.systemSourceID
        let amID = s.id.rawValue
        let songID = hashSongID(sourceID: sourceID, path: amID)
        let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: s.albums?.first?.artistName,
            trackArtistName: s.artistName
        )
        return PrimuseKit.Song(
            id: songID,
            title: s.title,
            albumTitle: s.albumTitle,
            artistName: s.artistName,
            albumArtistName: albumArtist,
            trackNumber: s.trackNumber,
            discNumber: s.discNumber,
            duration: s.duration ?? 0,
            fileFormat: .aac,
            filePath: amID,
            sourceID: sourceID,
            fileSize: 0,
            bitRate: nil,
            sampleRate: nil,
            bitDepth: nil,
            genre: s.genreNames.first,
            year: s.releaseDate.flatMap {
                Calendar.current.component(.year, from: $0)
            },
            lastModified: nil,
            dateAdded: s.libraryAddedDate ?? Date(),
            // Apple Music 的封面是动态 CDN URL (mzstatic.com), 没有本地文件;
            // CachedArtworkView 会识别 coverRef 里带 :// 走 URL 加载分支
            // (见 CachedArtworkView.swift Case 1)。600×600 在大屏 / mini /
            // accessory 都够清晰。
            coverArtFileName: s.artwork?.url(width: 600, height: 600)?.absoluteString,
            lyricsFileName: nil
        )
    }

    /// 跟项目里其他 scanner 一样的 song.id 算法 — sha256(sourceID:path) 前 16 字节 hex。
    nonisolated private static func hashSongID(sourceID: String, path: String) -> String {
        let hash = SHA256.hash(data: Data("\(sourceID):\(path)".utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// W3C TTML 子集 ── Apple Music 歌词只用了
///   <p begin="HH:MM:SS.fff" end="...">行文本</p>
///   <p begin="..."><span begin="...">字</span><span begin="...">字</span></p>
/// 复杂 styling / ruby / agent 角色全部 ignore, 不影响时间轴歌词渲染。
/// 字级 syllable 的 end 在 TTML 里常常缺失, 用下一字 start 推; 末字给 0.5s 缓冲。
private final class TTMLLyricsParser: NSObject, XMLParserDelegate {
    private var lines: [LyricLine] = []
    private var currentLineBegin: TimeInterval = 0
    private var currentText = ""
    private var currentSyllables: [LyricSyllable] = []
    private var currentSpanBegin: TimeInterval = 0
    private var currentSpanText = ""
    private var insideP = false
    private var insideSpan = false

    static func parse(_ ttml: String) -> [LyricLine] {
        guard let data = ttml.data(using: .utf8) else { return [] }
        let delegate = TTMLLyricsParser()
        let xml = XMLParser(data: data)
        xml.delegate = delegate
        xml.parse()
        return delegate.lines.sorted { $0.timestamp < $1.timestamp }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = Self.localName(qName ?? elementName)
        switch name {
        case "p":
            insideP = true
            currentText = ""
            currentSyllables = []
            currentLineBegin = attributeDict["begin"].map(Self.parseTimestamp) ?? 0
        case "span":
            guard insideP else { return }
            insideSpan = true
            currentSpanText = ""
            currentSpanBegin = attributeDict["begin"].map(Self.parseTimestamp) ?? currentLineBegin
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideSpan {
            currentSpanText += string
        } else if insideP {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.localName(qName ?? elementName)
        switch name {
        case "span":
            guard insideSpan else { return }
            let text = currentSpanText.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                currentSyllables.append(LyricSyllable(
                    text: text,
                    start: currentSpanBegin,
                    end: currentSpanBegin   // 末位先填 begin, 下面 normalize 时改成下一字 start
                ))
                currentText += text
            }
            insideSpan = false
        case "p":
            guard insideP else { return }
            let line = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                let normalized = normalizeSyllableEnds(currentSyllables)
                lines.append(LyricLine(
                    timestamp: currentLineBegin,
                    text: line,
                    syllables: normalized.isEmpty ? nil : normalized
                ))
            }
            insideP = false
            currentText = ""
            currentSyllables = []
        default:
            break
        }
    }

    private func normalizeSyllableEnds(_ syllables: [LyricSyllable]) -> [LyricSyllable] {
        guard !syllables.isEmpty else { return [] }
        guard syllables.count > 1 else {
            let only = syllables[0]
            return [LyricSyllable(text: only.text, start: only.start, end: only.start + 0.5)]
        }
        var result: [LyricSyllable] = []
        for i in 0..<syllables.count - 1 {
            result.append(LyricSyllable(
                text: syllables[i].text,
                start: syllables[i].start,
                end: syllables[i + 1].start
            ))
        }
        let last = syllables[syllables.count - 1]
        result.append(LyricSyllable(text: last.text, start: last.start, end: last.start + 0.5))
        return result
    }

    /// 剥 XML namespace 前缀, "tt:p" → "p"。
    private static func localName(_ qName: String) -> String {
        if let colon = qName.firstIndex(of: ":") {
            return String(qName[qName.index(after: colon)...]).lowercased()
        }
        return qName.lowercased()
    }

    /// TTML 时间戳: "HH:MM:SS.fff" / "MM:SS.fff" / "SS.fff" / "1.5s" / "1500ms"。
    static func parseTimestamp(_ s: String) -> TimeInterval {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("ms"), let v = Double(trimmed.dropLast(2)) { return v / 1000 }
        if trimmed.hasSuffix("s"), let v = Double(trimmed.dropLast()) { return v }
        var seconds: Double = 0
        for part in trimmed.split(separator: ":") {
            seconds = seconds * 60 + (Double(part) ?? 0)
        }
        return seconds
    }
}
