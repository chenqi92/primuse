#if os(tvOS)
import Foundation
import MusicKit
import PrimuseKit

/// Apple TV 上的 Apple Music 播放。
///
/// Apple Music 是 DRM 流:既读不到字节,也不能经 iPhone 中继转发,只有 MusicKit 的
/// `ApplicationMusicPlayer` 能播,而且它会独占音频会话。所以这里只负责三件事 ——
/// 授权、起播、把系统播放器的状态按固定节奏回灌出去;音频会话的交接由调用方
/// (`TVPlaybackCoordinator`)在移交前先停掉 `TVAudioEngine` 完成。
@MainActor
final class TVAppleMusicPlayer {
    /// 起播过程中的失败原因,已经是可以直接显示给用户的一句话。
    enum StartFailure: Error, Equatable {
        case notAuthorized(AppleMusicTVPlaybackPolicy.Readiness)
        case itemNotFound
        case playbackFailed(String)
    }

    /// 回灌给引擎的一拍状态。
    struct Tick: Equatable {
        let currentTime: TimeInterval
        let duration: TimeInterval?
        let isPlaying: Bool
        /// 系统播放器已经放完了整个队列 —— 调用方据此推进自己的播放队列。
        let didFinish: Bool
    }

    /// 与 `TVAudioEngine` 的周期观察器同频。逐字歌词靠引擎的墙钟外推按帧推进,
    /// 这里不需要更密。
    private static let mirrorInterval: Duration = .milliseconds(250)

    private var mirrorTask: Task<Void, Never>?
    private(set) var activeItemID: String?

    var authorizationState: AppleMusicAuthorizationState {
        Self.map(MusicAuthorization.currentStatus)
    }

    // MARK: 起播

    /// 起播一首歌。返回后调用方应开始消费 `startMirroring` 推来的状态。
    func play(
        itemID: String,
        startAt: TimeInterval,
        autoPlay: Bool
    ) async throws -> TimeInterval {
        let song = try await resolveSong(itemID: itemID)
        try await ensureReady(for: song)

        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [song], startingAt: song)
        do {
            try await player.prepareToPlay()
            if startAt > 0 { player.playbackTime = startAt }
            if autoPlay { try await player.play() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StartFailure.playbackFailed(error.localizedDescription)
        }
        activeItemID = itemID
        return song.duration ?? 0
    }

    /// 整张专辑入队播放。
    func playAlbum(id: String, autoPlay: Bool) async throws -> TimeInterval {
        let request = MusicCatalogResourceRequest<MusicKit.Album>(
            matching: \.id, equalTo: MusicItemID(rawValue: id)
        )
        guard let album = try await request.response().items.first else {
            throw StartFailure.itemNotFound
        }
        let tracks = try await Self.songs(in: album.with([.tracks]).tracks)
        return try await playSongs(tracks, autoPlay: autoPlay)
    }

    /// 播放某位艺术家的热门曲目。
    func playArtistTopSongs(id: String, autoPlay: Bool) async throws -> TimeInterval {
        let request = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id, equalTo: MusicItemID(rawValue: id)
        )
        guard let artist = try await request.response().items.first else {
            throw StartFailure.itemNotFound
        }
        let songs = try await artist.with([.topSongs]).topSongs ?? []
        return try await playSongs(Array(songs), autoPlay: autoPlay)
    }

    /// 播放用户自己的 Apple Music 歌单。
    func playLibraryPlaylist(id: String, autoPlay: Bool) async throws -> TimeInterval {
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(rawValue: id))
        request.limit = 1
        guard let playlist = try await request.response().items.first else {
            throw StartFailure.itemNotFound
        }
        let tracks = try await Self.songs(in: playlist.with([.tracks]).tracks)
        return try await playSongs(tracks, autoPlay: autoPlay)
    }

    /// 把一串曲目交给系统播放器。返回首曲时长,供引擎先把进度条画对。
    private func playSongs(_ songs: [MusicKit.Song], autoPlay: Bool) async throws -> TimeInterval {
        guard let first = songs.first else { throw StartFailure.itemNotFound }
        try await ensureReady(for: first)
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
        do {
            try await player.prepareToPlay()
            if autoPlay { try await player.play() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StartFailure.playbackFailed(error.localizedDescription)
        }
        activeItemID = first.id.rawValue
        return first.duration ?? 0
    }

    /// 关系集合可能分页,要全部取完再入队,否则只播到第一页就结束。
    private static func songs(
        in tracks: MusicItemCollection<MusicKit.Track>?
    ) async throws -> [MusicKit.Song] {
        guard var batch = tracks else { return [] }
        var collected = Array(batch)
        while batch.hasNextBatch {
            try Task.checkCancellation()
            guard let next = try await batch.nextBatch() else { break }
            collected.append(contentsOf: next)
            batch = next
        }
        return collected.compactMap { track in
            if case .song(let song) = track { return song }
            return nil
        }
    }

    private func resolveSong(itemID: String) async throws -> MusicKit.Song {
        let id = MusicItemID(rawValue: itemID)
        let song: MusicKit.Song?
        if AppleMusicTVPlaybackPolicy.usesUserLibraryLookup(itemID: itemID) {
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            song = try await request.response().items.first
        } else {
            let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: id)
            song = try await request.response().items.first
        }
        guard let song else { throw StartFailure.itemNotFound }
        return song
    }

    /// 授权 + 订阅前置检查。没问过就地发起授权请求,免得让用户自己去设置里找。
    private func ensureReady(for song: MusicKit.Song) async throws {
        let playbackSource = AppleMusicPlaybackSourceResolver.resolve(
            itemID: song.id.rawValue,
            explicitCatalogIDs: [],
            genericPlayParameterIDs: [],
            confirmedLibraryIDs: []
        )
        var authorization = authorizationState
        if authorization == .notDetermined {
            authorization = Self.map(await MusicAuthorization.request())
        }
        let canPlayCatalog = await Self.canPlayCatalogContent()
        let readiness = AppleMusicTVPlaybackPolicy.readiness(
            authorization: authorization,
            canPlayCatalogContent: canPlayCatalog,
            playbackSource: playbackSource
        )
        guard readiness == .ready else { throw StartFailure.notAuthorized(readiness) }
    }

    /// 与 iPhone 端同一种问法:一次性读当前订阅状态,不要挂在
    /// `subscriptionUpdates` 那条无限流上等第一拍。
    private static func canPlayCatalogContent() async -> Bool {
        (try? await MusicSubscription.current)?.canPlayCatalogContent ?? false
    }

    // MARK: 传输控制

    func pause() {
        ApplicationMusicPlayer.shared.pause()
    }

    func resume() async {
        try? await ApplicationMusicPlayer.shared.play()
    }

    func seek(to seconds: TimeInterval) {
        ApplicationMusicPlayer.shared.playbackTime = max(0, seconds)
    }

    func stop() {
        mirrorTask?.cancel()
        mirrorTask = nil
        activeItemID = nil
        let player = ApplicationMusicPlayer.shared
        player.stop()
        player.queue = ApplicationMusicPlayer.Queue()
    }

    // MARK: 状态回灌

    /// 周期性地把系统播放器的状态交给 `onTick`,直到被取消或队列放完。
    func startMirroring(onTick: @escaping @MainActor (Tick) -> Void) {
        mirrorTask?.cancel()
        mirrorTask = Task { @MainActor [weak self] in
            var sawPlayback = false
            while !Task.isCancelled {
                guard let self, self.activeItemID != nil else { return }
                let player = ApplicationMusicPlayer.shared
                let isPlaying = player.state.playbackStatus == .playing
                let time = player.playbackTime
                if isPlaying || time > 0 { sawPlayback = true }
                // 只有确实播过之后停下、且时间归零,才算整条队列放完。
                // 起播前的 stopped + time==0 是初始状态,不能当成结束。
                let didFinish = sawPlayback
                    && player.state.playbackStatus == .stopped
                    && player.queue.currentEntry == nil
                // 时长在起播时就拿到了,这里不再从队列条目里二次读取 ——
                // 队列条目的 item 类型会随 MusicKit 版本增删 case,没必要为一个
                // 已知值去依赖它。
                onTick(
                    Tick(
                        currentTime: time,
                        duration: nil,
                        isPlaying: isPlaying,
                        didFinish: didFinish
                    )
                )
                if didFinish { return }
                try? await Task.sleep(for: Self.mirrorInterval)
            }
        }
    }

    func stopMirroring() {
        mirrorTask?.cancel()
        mirrorTask = nil
    }

    private static func map(_ status: MusicAuthorization.Status) -> AppleMusicAuthorizationState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
#endif
