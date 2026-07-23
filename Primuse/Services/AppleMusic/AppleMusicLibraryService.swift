import Foundation
import CryptoKit
import MusicKit
import PrimuseKit

/// 把 Apple Music user library (用户已收藏 / 已添加到资料库的歌) 拉进
/// 猿音 MusicLibrary, 跟 NAS / 云盘的歌一起出现在 Library 视图。
///
/// 系统侧由 `ApplicationMusicPlayer` 负责 DRM 流播放, 我们这里只做:
/// - 用 `MusicLibraryRequest<MusicKit.Song>()` 拉一次性 + 增量
/// - 把每首 MusicKit.Song 映射成 PrimuseKit.Song (sourceID 固定为
///   `appleMusicSystemSourceID`, filePath 是 Apple Music MusicItemID)
/// - 写入 MusicLibrary, 后续 SongRowView / AlbumDetailView / NowPlaying
///   都能直接显示这些歌, 跟本地歌平等
///
/// 不做 (Phase 2+):
/// - CloudKit 同步 (Apple Music 库每个设备独立拉, 避免 sync 冲突)
/// - 跨类型 Playlist (本地 + Apple Music 混入一个 Playlist)
/// - Apple Music 歌词显示 (需新 LyricsScrollView 适配 MusicKit.Lyrics)
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

        var songSetSignature: String {
            Set(songIDs).sorted().joined(separator: "\u{1F}")
        }
    }

    private enum UserPlaylistFetchResult: Sendable {
        case mirror(UserPlaylistMirror)
        case empty(id: String, name: String)
        case failed(id: String, name: String, error: String)
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
            state = .failed("Apple Music 未授权, 去 Settings → Apple Music 启用")
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
    func ensureCachePopulated() async {
        guard AppleMusicFeatureSettings.syncUserLibraryEnabled else { return }
        guard !library.disabledSourceIDs.contains(Self.systemSourceID) else { return }
        if !songCache.isEmpty { return }
        guard appleMusic.authState == .authorized else { return }
        if let existing = syncTask {
            await existing.value
            return
        }
        state = .syncing
        let generation = UUID()
        syncGeneration = generation
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.runSync(generation: generation)
        }
        syncTask = task
        scheduleSyncTimeout(generation: generation)
        await task.value
    }

    /// 用 PrimuseKit.Song 在系统侧起播 — filePath 字段实际是 MusicItemID。
    /// 缓存命中直接 play, miss 时走 catalog lookup 兜底 (冷启动场景)。
    ///
    /// `queueContext` 是调用方当前 Apple Music 播放上下文。传入混合队列中的
    /// 单首歌时，ApplicationMusicPlayer 只负责该 DRM 曲目，跨来源切歌仍由
    /// AudioPlayerService 管理；传入纯 Apple Music 歌单时则保留系统队列能力。
    func play(
        primuseSong song: PrimuseKit.Song,
        queueContext: [PrimuseKit.Song]? = nil
    ) async {
        // songCache 是 in-memory, 重启后空。空 cache → orderedQueueFromCache
        // 返回 [], ApplicationMusicPlayer 的 queue 只装当前歌, 用户点"播放全部"
        // 看到的 queue 只剩 1 首播完就停。先确保 cache 至少有 user library
        // 当前的全集再继续。已经在跑的 sync 会被 await 等到完成。
        await ensureCachePopulated()

        let amID = song.filePath
        var musicKitSong: MusicKit.Song? = songCache[amID]
        if musicKitSong == nil {
            // amID 以 "i." 开头的是 user library 内部 ID, 不能用
            // MusicCatalogResourceRequest 查 (那查的是公开 catalog id)。
            // 用 MusicLibraryRequest 才对; catalog id (纯数字) 才走 catalog
            // 分支兜底, 兼容用户从搜索结果加入 library 又同步过来的混合情况。
            let id = MusicItemID(rawValue: amID)
            do {
                if amID.hasPrefix("i.") {
                    var req = MusicLibraryRequest<MusicKit.Song>()
                    req.filter(matching: \.id, equalTo: id)
                    req.limit = 1
                    let resp = try await req.response()
                    musicKitSong = resp.items.first
                } else {
                    let req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: id)
                    let resp = try await req.response()
                    musicKitSong = resp.items.first
                }
                if let m = musicKitSong { songCache[amID] = m }
            } catch {
                plog("⚠️Apple Music lookup failed for \(amID): \(error.localizedDescription)")
                return
            }
        }
        guard let mk = musicKitSong else {
            plog("⚠️Apple Music 找不到曲目 \(amID)")
            return
        }
        // Prefer the exact queue selected in Primuse. Falling back to the full
        // Apple Music cache preserves the legacy direct-play behaviour for
        // callers that do not have a queue context.
        let contextualQueue: [MusicKit.Song]? = queueContext?.compactMap { contextSong -> MusicKit.Song? in
            guard contextSong.sourceID == Self.systemSourceID else { return nil }
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
        let startIndex = queue.firstIndex(where: { $0.id == mk.id }) ?? 0
        if queue.isEmpty {
            await appleMusic.play(mk)
        } else {
            await appleMusic.play(songs: queue, startAt: startIndex)
        }
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
    /// 在 cache 里按 title + artist 反查找到 user library 那份, 没命中就 fallback
    /// 返回原 song (功能降级但不崩)。
    func canonicalForNowPlaying(_ s: MusicKit.Song) -> MusicKit.Song {
        if songCache[s.id.rawValue] != nil { return s }   // 已经是 user library 版
        if let matched = songCache.values.first(where: { cached in
            cached.title == s.title && cached.artistName == s.artistName
        }) {
            return matched
        }
        return s
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
                    self.state = .failed("Apple Music 同步超时, 请检查 Music 权限或稍后重试")
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
            // MusicLibraryRequest 一次性拉 user library 内 Song。limit 设到
            // 上限 (默认 25, 调大到 100 一页), 后续翻页直到 nextBatch 为 nil。
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.limit = 100
            let response = try await request.response()
            markSyncProgress()
            var allMusicKitSongs: [MusicKit.Song] = []
            allMusicKitSongs.append(contentsOf: response.items)

            // 翻页接口在 MusicItemCollection 上 (不是 response 上)。直到
            // 当前 collection 没有 nextBatch 为止。
            var currentBatch = response.items
            while currentBatch.hasNextBatch {
                if Task.isCancelled { return }
                guard let next = try await currentBatch.nextBatch() else { break }
                allMusicKitSongs.append(contentsOf: next)
                currentBatch = next
                markSyncProgress()   // 每拉到一页就给看门狗续期, 大库不会被误判超时
            }

            if Task.isCancelled { return }
            plog("🎵 Apple Music library fetched: \(allMusicKitSongs.count) songs")
            guard syncGeneration == generation else { return }

            // 把 MusicKit.Song 缓存住, play 时直接喂给 ApplicationMusicPlayer
            // 不用走 catalog lookup。
            for s in allMusicKitSongs {
                songCache[s.id.rawValue] = s
            }
            let songs = allMusicKitSongs.map { Self.toPrimuseSong($0) }
            // 把这些歌加进 library, sourceIDs 限定 Apple Music, 让 addSongs
            // 自己处理删除 (Apple Music 删歌的 case 会被检测到)。
            library.addSongs(
                songs,
                affectedSourceIDs: [Self.systemSourceID],
                notifyRemovals: true
            )

            // 同步生成「Apple Music 资料库」镜像歌单 ── 让用户在资料库 →
            // 播放列表里直接看到这一坨同步过来的歌, 而不是被混进总库里找不见。
            library.ensurePlaylist(
                id: Self.systemPlaylistID,
                name: String(localized: "apple_music_library_playlist_name")
            )
            library.replacePlaylistSongs(
                playlistID: Self.systemPlaylistID,
                songIDs: songs.map(\.id)
            )

            // 临时诊断 ── 摸清同步过来的 cover URL 实际形态, 帮排查"歌没封面"。
            let withCover = songs.filter { $0.coverArtFileName != nil }.count
            let firstSample = songs.first.flatMap { $0.coverArtFileName }?.prefix(120) ?? "nil"
            plog("🎵 Apple Music covers: \(withCover)/\(songs.count) have URL, first='\(firstSample)'")

            // 拉用户在 Apple Music 里建的 playlists, 每个映射成独立的本地镜像歌单
            // (跟「Apple Music 资料库」全集并存)。tracks 走 .with([.tracks])
            // 延迟加载关系, 失败的 playlist 跳过不阻塞整体 sync。
            let syncedUserPlaylistCount = await syncUserPlaylists()
            guard syncGeneration == generation else { return }

            lastSyncAt = Date()
            state = .done(songCount: songs.count, at: lastSyncAt!)
            plog("🎵 Apple Music library synced: \(songs.count) songs, \(syncedUserPlaylistCount) playlists → playlist \(Self.systemPlaylistID)")
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

    /// 每个 user playlist 在 Primuse 里建独立的镜像歌单 ── ID 用 amID 派生固定,
    /// 多次 sync 不会重复创建; name 跟 Apple Music 那边对齐, 用户改名后下次 sync
    /// 会被刷新 (ensurePlaylist 已经处理 name 同步)。
    /// 实现: MusicLibraryRequest<Playlist> 拉用户全部歌单 (含分页), 每个用
    /// `.with([.tracks])` 把 tracks 拉过来, 转 PrimuseKit.Song 后 replace 进对应歌单。
    @discardableResult
    private func syncUserPlaylists() async -> Int {
        do {
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.limit = 100
            let response = try await request.response()
            markSyncProgress()
            var allPlaylists: [MusicKit.Playlist] = []
            allPlaylists.append(contentsOf: response.items)
            var currentBatch = response.items
            while currentBatch.hasNextBatch {
                if Task.isCancelled { return 0 }
                guard let next = try await currentBatch.nextBatch() else { break }
                allPlaylists.append(contentsOf: next)
                currentBatch = next
                markSyncProgress()
            }
            plog("🎵 Apple Music user playlists: \(allPlaylists.count)")

            var fetchedMirrors: [UserPlaylistMirror] = []
            var failedIDs = Set<String>()
            for amPlaylist in allPlaylists {
                if Task.isCancelled { return 0 }
                let result = await fetchUserPlaylistMirror(amPlaylist)
                markSyncProgress()   // 每处理完一个歌单 (含 .with([.tracks]) 往返) 续期
                switch result {
                case .mirror(let mirror):
                    fetchedMirrors.append(mirror)
                case .empty(let id, let name):
                    plog("🎵 AM playlist '\(name)' is empty, pruning local mirror \(id)")
                case .failed(let id, let name, let error):
                    failedIDs.insert(id)
                    plog("⚠️AM playlist '\(name)' fetch tracks failed: \(error)")
                }
            }

            let mirrorsToKeep = Self.resolveUserPlaylistMirrors(fetchedMirrors)
            for mirror in mirrorsToKeep {
                library.ensurePlaylist(id: mirror.id, name: mirror.name)
                library.replacePlaylistSongs(playlistID: mirror.id, songIDs: mirror.songIDs)
                plog("🎵 AM playlist '\(mirror.name)' → \(mirror.songIDs.count) songs")
            }

            let keepIDs = Set(mirrorsToKeep.map(\.id)).union(failedIDs)
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

    private func fetchUserPlaylistMirror(_ amPlaylist: MusicKit.Playlist) async -> UserPlaylistFetchResult {
        let pid = "\(Self.userPlaylistIDPrefix)\(amPlaylist.id.rawValue)"
        do {
            let detailed = try await amPlaylist.with([.tracks])
            let tracks = detailed.tracks ?? []
            let songIDs: [String] = tracks.compactMap { track in
                guard case let .song(s) = track else { return nil }
                // 顺手填 cache (有些用户歌单里的 song 可能不在 user library 全集)
                songCache[s.id.rawValue] = s
                return Self.toPrimuseSong(s).id
            }
            if songIDs.isEmpty {
                return .empty(id: pid, name: amPlaylist.name)
            }
            return .mirror(UserPlaylistMirror(
                id: pid,
                name: amPlaylist.name.trimmingCharacters(in: .whitespacesAndNewlines),
                songIDs: Self.uniqued(songIDs)
            ))
        } catch {
            return .failed(id: pid, name: amPlaylist.name, error: error.localizedDescription)
        }
    }

    private static func resolveUserPlaylistMirrors(_ mirrors: [UserPlaylistMirror]) -> [UserPlaylistMirror] {
        let groupedByName = Dictionary(grouping: mirrors) { normalizedPlaylistName($0.name) }
        var resolved: [UserPlaylistMirror] = []

        for group in groupedByName.values {
            let stableGroup = group.sorted { lhs, rhs in
                if lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedSame {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.id < rhs.id
            }

            var seenSongSets = Set<String>()
            var uniqueMirrors: [UserPlaylistMirror] = []
            for mirror in stableGroup {
                guard seenSongSets.insert(mirror.songSetSignature).inserted else {
                    plog("🎵 Skipping duplicate Apple Music playlist mirror '\(mirror.name)' (\(mirror.id))")
                    continue
                }
                uniqueMirrors.append(mirror)
            }

            if uniqueMirrors.count == 1, let only = uniqueMirrors.first {
                resolved.append(only)
            } else {
                for (index, mirror) in uniqueMirrors.enumerated() {
                    let displayName = index == 0 ? mirror.name : "\(mirror.name) (\(index + 1))"
                    resolved.append(UserPlaylistMirror(
                        id: mirror.id,
                        name: displayName,
                        songIDs: mirror.songIDs
                    ))
                }
            }
        }

        return resolved.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func normalizedPlaylistName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
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
        return PrimuseKit.Song(
            id: songID,
            title: s.title,
            albumTitle: s.albumTitle,
            artistName: s.artistName,
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
