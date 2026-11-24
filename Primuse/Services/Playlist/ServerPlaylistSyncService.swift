import Foundation
import PrimuseKit

/// 把服务端曲库源上的用户歌单同步成本地镜像歌单。
///
/// 与 m3u8 导入不同, 这里不需要文件名 / 标题模糊匹配: 服务端曲库连接器把
/// 服务端原生 item ID 编进 `Song.filePath`(`/songs/<id>.<suffix>` 或
/// `/items/<id>.<ext>`), 所以歌单曲目能按 ID 精确命中。
///
/// 镜像语义(与 Apple Music 资料库镜像一致): 歌单 ID 由 sourceID + 服务端歌单
/// ID 派生；扫描读取服务端内容，简介和加歌操作回写后以服务端回读结果更新镜像。
@MainActor
enum ServerPlaylistSyncService {
    typealias SyncResult = ServerPlaylistMirror.SyncResult

    /// 扫描完成后调用。任何失败都只记日志 —— 歌单同步是曲库扫描的附加步骤,
    /// 不该让已经成功的扫描显示为失败。
    @discardableResult
    static func sync(
        source: MusicSource,
        sourceManager: SourceManager,
        library: MusicLibrary,
        applyFence: ServerMirrorApplyFence = { true }
    ) async -> SyncResult {
        var result = SyncResult()
        guard source.type.isServerLibrary else { return result }
        let context = "Server playlists source=\(LogRedactionPolicy.digest(source.id)) type=\(source.type.rawValue)"
        plog("\(context) stage=fetch result=started enabled=\(source.isEnabled)")

        let snapshot: ServerPlaylistSnapshot?
        // 整源对照等第一张带曲目的歌单读回来才建: 源上没有歌单就不必为几十万首建一份。
        let applier = ServerPlaylistMirror.ProgressiveApplier(source: source, library: library)
        defer { applier.finish() }
        guard !Task.isCancelled, applyFence() else { return result }
        do {
            // 进度回调只在这次读取期间被调用, 读完就不再持有闸门。
            snapshot = try await withoutActuallyEscaping(applyFence) { fence in
                try await sourceManager.fetchServerPlaylists(for: source) { @MainActor playlist in
                    guard !Task.isCancelled, fence() else { return }
                    applier.enqueue(playlist)
                }
            }
        } catch is CancellationError {
            plog("\(context) stage=fetch result=cancelled")
            return result
        } catch {
            plog("\(context) stage=fetch result=failed \(LogRedactionPolicy.errorSummary(error))")
            return result
        }
        // 逐张落地到此为止: 整源对照先放掉, 收尾只为歌单引用到的曲目再对一遍。
        applier.finish()
        // nil = 该源类型没有歌单能力, 不要动本地任何东西。
        guard let snapshot else {
            plog("\(context) stage=apply result=skipped reason=unsupported")
            return result
        }
        guard !Task.isCancelled, applyFence() else {
            plog("\(context) stage=apply result=skipped reason=stale-scan")
            return result
        }
        // 对照在主线程外算; 算的这一会儿源可能被停用或被新一轮扫描接手, 回来再过一次闸。
        let prepared = await ServerPlaylistMirror.prepareOffMain(
            snapshot: snapshot,
            source: source,
            library: library
        )
        // 落地会改一批歌单、牵动首页和歌单页：算好时正赶上交互（滑动、播放页转场），等停稳再落。
        await UserScrollActivityMonitor.shared.waitUntilSettled()
        guard !Task.isCancelled, applyFence() else {
            plog("\(context) stage=apply result=skipped reason=stale-scan")
            return result
        }

        result = ServerPlaylistMirror.apply(prepared, snapshot: snapshot, source: source, library: library,
                                            readRevision: applier.readRevision)
        return result
    }
}

/// 现有「添加到歌单」入口可写入同源歌单，也可以恢复本机隐藏的成员。
@MainActor
enum ServerPlaylistAppendService {
    /// 这批歌可以加进去的服务端镜像歌单。歌必须全部来自同一个支持追加的源。
    static func targets(
        for songs: [Song],
        library: MusicLibrary,
        sourcesStore: SourcesStore
    ) -> [Playlist] {
        guard let source = source(for: songs, sourcesStore: sourcesStore) else { return [] }
        let selected = Set(songs.map(\.id))
        return library.playlists.filter { playlist in
            guard ServerPlaylistWritebackPolicy.serverPlaylistID(fromMirrorPlaylistID: playlist.id, sourceID: source.id) != nil
            else { return false }
            return !ServerPlaylistMirror.readOnlyPlaylistIDs.contains(playlist.id)
                || selected.isSubset(of: library.locallyRemovedMirrorSongs(in: playlist.id))
        }
    }

    /// 这个源上当前账户能加歌的服务端歌单(镜像)。
    static func writablePlaylists(sourceID: String, library: MusicLibrary) -> [Playlist] {
        library.playlists.filter {
            ServerPlaylistWritebackPolicy.serverPlaylistID(
                fromMirrorPlaylistID: $0.id,
                sourceID: sourceID
            ) != nil && !ServerPlaylistMirror.readOnlyPlaylistIDs.contains($0.id)
        }
    }

    static func source(for songs: [Song], sourcesStore: SourcesStore) -> MusicSource? {
        guard let sourceID = songs.first?.sourceID,
              songs.allSatisfy({ $0.sourceID == sourceID }),
              let source = sourcesStore.source(id: sourceID),
              source.isEnabled, !source.isDeleted,
              ServerPlaylistWritebackPolicy.supports(source.type) else { return nil }
        return source
    }

    /// 返回因为对不上服务端曲目而没加进去的首数。
    @discardableResult
    static func append(
        _ songs: [Song],
        toMirrorPlaylist playlistID: String,
        library: MusicLibrary,
        sourcesStore: SourcesStore,
        sourceManager: SourceManager
    ) async throws -> Int {
        guard let source = source(for: songs, sourcesStore: sourcesStore),
              let serverPlaylistID = ServerPlaylistWritebackPolicy.serverPlaylistID(
                  fromMirrorPlaylistID: playlistID,
                  sourceID: source.id
              ) else { throw CancellationError() }
        let selected = Set(songs.map(\.id))
        let hidden = library.locallyRemovedMirrorSongs(in: playlistID).intersection(selected)
        // Restore from the latest raw mirror, including its original ordering.
        // A song since removed on the server goes through the normal append path.
        let restorable = hidden.isEmpty ? [] : hidden.intersection(library.rawSongIDs(forPlaylist: playlistID))
        let toAppend = songs.filter { !restorable.contains($0.id) }
        if toAppend.isEmpty {
            try library.setMirrorSongs(hidden, hidden: false, in: playlistID)
            return 0
        }
        let (refreshed, skippedCount) = try await sourceManager.appendSongs(
            toAppend,
            toServerPlaylist: serverPlaylistID,
            source: source
        )
        try library.setMirrorSongs(hidden, hidden: false, in: playlistID)
        ServerPlaylistMirror.applyAppended(refreshed, source: source, library: library)
        plog("Server playlists source=\(LogRedactionPolicy.digest(source.id)) playlist=\(LogRedactionPolicy.digest(refreshed.id)) stage=append result=complete tracks=\(songs.count - skippedCount) skipped=\(skippedCount)")
        return skippedCount
    }
}

@MainActor
enum ServerPlaylistRemovalService {
    static func source(for playlistID: String, sourcesStore: SourcesStore) -> MusicSource? {
        guard ServerPlaylistIdentity.isMirrorPlaylist(playlistID) else { return nil }
        return sourcesStore.sources.first {
            $0.isEnabled && !$0.isDeleted && $0.type.isSubsonicFamily &&
                ServerPlaylistWritebackPolicy.serverPlaylistID(fromMirrorPlaylistID: playlistID, sourceID: $0.id) != nil
        }
    }

    /// Returns true when the server explicitly denied the edit and it applies only on this device.
    static func remove(_ songs: [Song], from playlistID: String, library: MusicLibrary,
                       sourcesStore: SourcesStore, sourceManager: SourceManager) async throws -> Bool {
        guard let source = source(for: playlistID, sourcesStore: sourcesStore),
              let id = ServerPlaylistWritebackPolicy.serverPlaylistID(fromMirrorPlaylistID: playlistID, sourceID: source.id)
        else { throw CancellationError() }
        switch try await sourceManager.removeSongs(songs, fromServerPlaylist: id, source: source) {
        case .updated(let refreshed):
            ServerPlaylistMirror.applyAppended(refreshed, source: source, library: library)
            return false
        case .readOnly(let current):
            // Earlier batches may already have completed. Only hide surviving remote members.
            ServerPlaylistMirror.applyAppended(current, source: source, library: library)
            let remaining = Set(library.rawSongIDs(forPlaylist: playlistID))
            try library.setMirrorSongs(remaining.intersection(songs.map(\.id)), hidden: true, in: playlistID)
            return true
        }
    }
}

/// 服务器歌单换先后写回服务器(#449): 拖动排序与置顶都走这里, 目前只有 Subsonic 系。
/// 本机先按新先后显示, 服务器确认后用回读的明细落地; 没写成就换回原来的先后并说明原因,
/// 服务器上的歌单在别处刚改过时不写, 换成服务器上最新的内容。
@MainActor
enum ServerPlaylistReorderService {
    struct Request {
        fileprivate let playlistID: String
        fileprivate let serverPlaylistID: String
        fileprivate let source: MusicSource
        fileprivate let listedOrder: [String]
        fileprivate let previous: [String]
        fileprivate let shown: [String]
    }

    /// 正在写回的镜像歌单。上一次还没写完时不接下一次, 免得两次按各自读到的明细互相覆盖。
    private static var inFlight = Set<String>()

    /// 能换先后的服务器歌单所属的源。智能歌单、别人的歌单(最近一次同步判为只读)不给入口。
    static func source(for playlistID: String, sourcesStore: SourcesStore) -> MusicSource? {
        guard !ServerPlaylistMirror.readOnlyPlaylistIDs.contains(playlistID) else { return nil }
        return ServerPlaylistRemovalService.source(for: playlistID, sourcesStore: sourcesStore)
    }

    /// 先在本机按新先后显示。`listedOrder` 是面板里列出来的成员(歌与置灰占位)的新先后,
    /// 没列出来的原位不动。先后没变、或上一次还在写时返回 nil, 什么都不做。
    static func begin(playlistID: String, listedOrder: [String], library: MusicLibrary,
                      sourcesStore: SourcesStore) -> Request? {
        guard let source = source(for: playlistID, sourcesStore: sourcesStore),
              let serverPlaylistID = ServerPlaylistWritebackPolicy.serverPlaylistID(
                fromMirrorPlaylistID: playlistID, sourceID: source.id
              ) else { return nil }
        let previous = library.rawSongIDs(forPlaylist: playlistID)
        let shown = PlaylistMemberOrderPolicy.reordered(previous, listedOrder: listedOrder)
        guard shown != previous, !inFlight.contains(playlistID),
              library.reorderMirrorPlaylistSongs(playlistID: playlistID, from: previous, to: shown) else { return nil }
        inFlight.insert(playlistID)
        return Request(playlistID: playlistID, serverPlaylistID: serverPlaylistID, source: source,
                       listedOrder: listedOrder, previous: previous, shown: shown)
    }

    /// 写服务器。没写成时抛错, 本机已换回原来的先后(或换成了服务器上最新的内容)。
    static func commit(_ request: Request, library: MusicLibrary, sourceManager: SourceManager) async throws {
        defer { inFlight.remove(request.playlistID) }
        var settled = false
        func settle(_ playlist: ServerPlaylist) {
            ServerPlaylistMirror.applyAppended(playlist, source: request.source, library: library)
            settled = true
        }
        let context = "Server playlists source=\(LogRedactionPolicy.digest(request.source.id)) playlist=\(LogRedactionPolicy.digest(request.serverPlaylistID)) stage=reorder"
        do {
            let current = try await sourceManager.serverPlaylistForReordering(
                id: request.serverPlaylistID, source: request.source
            )
            let positions = await ServerPlaylistMirror.memberIDsByPosition(
                of: current, source: request.source, library: library, preferring: Set(request.previous)
            )
            try Task.checkCancellation()
            // 本机排序依据的那份和服务器眼下的不是同一批(含重复项的次数)时不整份重写: 别处刚加的歌
            // 会被冲掉。换成服务器上最新的内容, 让用户照着它重新排。
            guard ServerPlaylistReorderPolicy.serverMatchesMirror(
                serverTrackIDs: current.trackIDs,
                serverMemberIDs: positions,
                recorded: ServerPlaylistMirror.appliedTrackMultiset(for: request.playlistID),
                mirrorMemberIDs: request.previous
            ) else {
                plog("\(context) result=changed tracks=\(current.trackIDs.count)")
                settle(current)
                throw ServerPlaylistReorderError.changedOnServer
            }
            guard let order = ServerPlaylistReorderPolicy.reorderedPositions(
                memberIDs: positions, listedOrder: request.listedOrder
            ) else {
                settle(current)
                return
            }
            let ordered = order.map { current.trackIDs[$0] }
            switch try await sourceManager.reorderServerPlaylist(
                id: request.serverPlaylistID, expectedTrackIDs: current.trackIDs,
                orderedTrackIDs: ordered, source: request.source
            ) {
            case .updated(let refreshed):
                settle(refreshed)
                plog("\(context) result=complete tracks=\(refreshed.trackIDs.count)")
            case .readOnly(let latest):
                plog("\(context) result=read-only")
                settle(latest)
                throw ServerPlaylistReorderError.readOnly
            case .changed(let latest):
                plog("\(context) result=changed tracks=\(latest.trackIDs.count)")
                settle(latest)
                throw ServerPlaylistReorderError.changedOnServer
            }
        } catch {
            if !settled {
                library.reorderMirrorPlaylistSongs(playlistID: request.playlistID, from: request.shown, to: request.previous)
            }
            throw error
        }
    }
}

/// 歌单里的一首, 换到目标服务器上之后的样子。
struct ServerPlaylistCopyEntry: Identifiable, Sendable {
    let id: Int
    let title: String
    let artist: String?
    /// 服务器上的同一首(原本就是这台服务器的歌时是它自己)。
    let match: Song?
    /// 只够得上「可能是」的那一首, 默认不写。
    let probable: Song?
}

/// 一个歌单要复制过去的样子。
struct ServerPlaylistCopyPlan: Identifiable, Sendable {
    let playlistID: String
    let name: String
    let entries: [ServerPlaylistCopyEntry]

    var id: String { playlistID }
    var matchedCount: Int { entries.filter { $0.match != nil }.count }
    var probableCount: Int { entries.filter { $0.match == nil && $0.probable != nil }.count }
    var missingCount: Int { entries.filter { $0.match == nil && $0.probable == nil }.count }

    /// 要写进去的歌, 按歌单顺序去重。
    func songs(includingProbable: Bool) -> [Song] {
        var seen = Set<String>()
        return entries
            .compactMap { $0.match ?? (includingProbable ? $0.probable : nil) }
            .filter { seen.insert($0.id).inserted }
    }
}

struct ServerPlaylistCopyResult: Sendable {
    let serverPlaylistName: String
    /// 写完后服务端歌单里一共多少首。
    let trackCount: Int
    /// 对不上服务端曲目 id、没加进去的首数。
    let skippedCount: Int
    let created: Bool
}

/// 把歌单复制到一台音乐服务器上(Apple Music 的歌单放进 Navidrome 之类)。服务端歌单只能放
/// 服务器自己曲库里的歌, 所以每首先换成那台服务器上的同一首(和「导入歌单」同一套规则),
/// 换不到的只列出来。写到同名的服务端歌单里, 没有就新建; 只往里加, 重复复制只补新歌。
@MainActor
enum ServerPlaylistCopyService {
    /// 能写歌单的服务器源。
    static func targetSources(sourcesStore: SourcesStore) -> [MusicSource] {
        sourcesStore.sources.filter {
            $0.isEnabled && !$0.isDeleted && ServerPlaylistWritebackPolicy.supports($0.type)
        }
    }

    /// 歌单本身就是这台服务器上的歌单时, 复制回去没有意义。
    static func canCopy(playlistID: String, to source: MusicSource) -> Bool {
        !playlistID.hasPrefix(ServerPlaylistIdentity.playlistIDPrefix(sourceID: source.id))
    }

    static func hasTarget(for playlistID: String, sourcesStore: SourcesStore) -> Bool {
        targetSources(sourcesStore: sourcesStore).contains { canCopy(playlistID: playlistID, to: $0) }
    }

    /// 这个名字的歌单默认写到哪里: 同名、能写的服务端歌单优先, 没有就新建。
    static func destination(
        forName name: String,
        target: MusicSource,
        library: MusicLibrary
    ) -> ServerPlaylistCopyPolicy.Destination {
        ServerPlaylistCopyPolicy.destination(
            playlistName: name,
            writablePlaylists: ServerPlaylistAppendService.writablePlaylists(sourceID: target.id, library: library)
                .map { PlaylistImportMergePolicy.Target(id: $0.id, name: $0.name, updatedAt: $0.updatedAt) },
            canCreate: ServerPlaylistWritebackPolicy.supportsCreating(target.type)
        )
    }

    private enum Row: Sendable {
        case song(Song)
        case pending(PlaylistPendingEntry)
    }

    private struct Input: Sendable {
        let playlistID: String
        let name: String
        let rows: [Row]
    }

    /// 每个歌单的每一首对到目标服务器的曲库上。建索引要把服务器那边整份归一化, 在后台做。
    static func plans(
        for playlistIDs: [String],
        target: MusicSource,
        library: MusicLibrary
    ) async -> [ServerPlaylistCopyPlan] {
        let inputs = playlistIDs.compactMap { id -> Input? in
            guard let playlist = library.playlist(id: id), canCopy(playlistID: id, to: target) else { return nil }
            let rows = library.entries(forPlaylist: id).map { entry -> Row in
                switch entry {
                case .song(let song): .song(song)
                case .pending(let pending): .pending(pending)
                }
            }
            return Input(playlistID: id, name: playlist.name, rows: rows)
        }
        let targetID = target.id
        let keyCache = library.playlistEntryMatchKeyCache
        let targetSongs: [Song]
        if let reader = P2cCatalogAccess.reader(for: library),
           let candidates = await Self.catalogTargetCandidates(inputs, targetID: targetID, reader: reader) {
            targetSongs = candidates
        } else {
            targetSongs = library.visibleSongs.filter { $0.sourceID == targetID }
        }
        return await Task.detached(priority: .userInitiated) {
            Self.makePlans(inputs, targetID: targetID, targetSongs: targetSongs, keyCache: keyCache)
        }.value
    }

    /// 曲库目录可读时(P2c):目标源里只取与这些条目同歌名主体的可见歌。匹配器只在同歌名主体的桶里找,
    /// 拿这份候选建的匹配器与拿整个目标源建的给出同样的结果。读失败时 nil,调用方改走内存。
    private static func catalogTargetCandidates(
        _ inputs: [Input], targetID: String, reader: LibraryCatalogReader
    ) async -> [Song]? {
        var titles = Set<String>()
        for input in inputs {
            for row in input.rows {
                switch row {
                case .song(let song):
                    guard song.sourceID != targetID else { continue }
                    titles.insert(ExternalTrackMatchPolicy.normalizedCoreTitle(song.title))
                case .pending(let pending):
                    titles.insert(ExternalTrackMatchPolicy.normalizedCoreTitle(pending.matchSubject.title))
                }
            }
        }
        do {
            return try await reader.songs(
                matchingCoreTitles: titles, scope: LibrarySongScope(sourceID: targetID)
            )
        } catch {
            if !(error is CancellationError) {
                plog("Server playlist copy target=\(LogRedactionPolicy.digest(targetID)) catalog candidates failed, using in-memory library: \(error.localizedDescription)")
            }
            return nil
        }
    }

    nonisolated private static func makePlans(
        _ inputs: [Input],
        targetID: String,
        targetSongs: [Song],
        keyCache: PlaylistEntryMatchKeyCache
    ) -> [ServerPlaylistCopyPlan] {
        let matcher = PlaylistEntryMatcher(songs: targetSongs, keyCache: keyCache)
        return inputs.map { input in
            let entries = input.rows.enumerated().map { offset, row -> ServerPlaylistCopyEntry in
                switch row {
                case .song(let song):
                    if song.sourceID == targetID {
                        return ServerPlaylistCopyEntry(
                            id: offset, title: song.title, artist: song.artistName, match: song, probable: nil
                        )
                    }
                    let result = matcher.match(PlaylistEntryMatcher.subject(of: song))
                    return ServerPlaylistCopyEntry(
                        id: offset, title: song.title, artist: song.artistName,
                        match: result.best, probable: result.best == nil ? result.probable.first : nil
                    )
                case .pending(let pending):
                    let result = matcher.match(pending.matchSubject)
                    return ServerPlaylistCopyEntry(
                        id: offset, title: pending.title,
                        artist: pending.artists.isEmpty ? nil : pending.artistLine,
                        match: result.best, probable: result.best == nil ? result.probable.first : nil
                    )
                }
            }
            return ServerPlaylistCopyPlan(playlistID: input.playlistID, name: input.name, entries: entries)
        }
    }

    /// 先写服务端, 再用服务端回读的明细刷新镜像。没有能写的歌时返回 nil, 什么都不做。
    static func copy(
        _ plan: ServerPlaylistCopyPlan,
        named name: String,
        to destination: ServerPlaylistCopyPolicy.Destination,
        includingProbable: Bool,
        target: MusicSource,
        library: MusicLibrary,
        sourceManager: SourceManager
    ) async throws -> ServerPlaylistCopyResult? {
        let songs = plan.songs(includingProbable: includingProbable)
        guard !songs.isEmpty else { return nil }
        let serverPlaylistID: String
        let created: Bool
        switch destination {
        case .append(let mirrorPlaylistID):
            guard let id = ServerPlaylistWritebackPolicy.serverPlaylistID(
                fromMirrorPlaylistID: mirrorPlaylistID,
                sourceID: target.id
            ) else { throw CancellationError() }
            serverPlaylistID = id
            created = false
        case .create:
            let playlist = try await sourceManager.createServerPlaylist(named: name, source: target)
            ServerPlaylistMirror.applyCreated(playlist, source: target, library: library)
            serverPlaylistID = playlist.id
            created = true
        case .needsServerPlaylist:
            throw ServerPlaylistAppendError.creationUnsupported
        }
        let (refreshed, skippedCount) = try await sourceManager.appendSongs(
            songs,
            toServerPlaylist: serverPlaylistID,
            source: target
        )
        ServerPlaylistMirror.applyAppended(refreshed, source: target, library: library)
        plog("Server playlists source=\(LogRedactionPolicy.digest(target.id)) playlist=\(LogRedactionPolicy.digest(refreshed.id)) stage=copy result=complete created=\(created) tracks=\(songs.count - skippedCount) skipped=\(skippedCount) missing=\(plan.missingCount)")
        return ServerPlaylistCopyResult(
            serverPlaylistName: refreshed.name.isEmpty ? name : refreshed.name,
            trackCount: refreshed.trackIDs.count,
            skippedCount: skippedCount,
            created: created
        )
    }
}

@MainActor
protocol ServerFavoriteManaging: AnyObject {
    func fetchServerFavorites(for source: MusicSource) async throws -> ServerFavoriteSnapshot?
    func fetchServerFavorites(sourceID: String) async throws -> ServerFavoriteSnapshot?
    func setServerFavorite(
        for song: Song,
        source: MusicSource,
        isFavorite: Bool
    ) async throws -> ServerFavoriteSnapshot?
}

extension SourceManager: ServerFavoriteManaging {}

@MainActor
protocol ServerFavoriteSourcesProviding: AnyObject {
    func source(id: String) -> MusicSource?
}

extension SourcesStore: ServerFavoriteSourcesProviding {}

@MainActor
protocol ServerFavoriteLibraryManaging: AnyObject {
    var songs: [Song] { get }
    func isLiked(songID: String) -> Bool
    func likedSongIDs(fromSourceID sourceID: String) -> [String]
    func setLiked(songID: String, isLiked: Bool, propagatesServerMutation: Bool)
    func replaceLikedSongs(fromSourceID sourceID: String, with authoritativeSongIDs: [String])
    func presentServerFavoriteError(_ message: String)
    func admitCollectionOnlySongs(_ incoming: [Song], sourceID: String, indexMaintenance: LibraryMaintenanceDisposition)
    func releaseUnreferencedCollectionOnlySongs(sourceID: String)
}

extension ServerFavoriteLibraryManaging {
    func likedSongIDs(fromSourceID sourceID: String) -> [String] {
        Array(songs.lazy.filter { $0.sourceID == sourceID && self.isLiked(songID: $0.id) }.map(\.id))
    }
    func admitCollectionOnlySongs(_ incoming: [Song], sourceID: String, indexMaintenance: LibraryMaintenanceDisposition) {}
    func releaseUnreferencedCollectionOnlySongs(sourceID: String) {}
}

extension MusicLibrary: ServerFavoriteLibraryManaging {}

@MainActor
protocol ServerFavoriteSurfacePublishing: AnyObject {
    func republishNowPlayingSurfaces()
}

extension AudioPlayerService: ServerFavoriteSurfacePublishing {}

/// Keeps Primuse's liked playlist and supported server favorite annotations in
/// one state. UI changes are optimistic, but mutations are serialized per
/// source and confirmed by an authoritative refresh. A rejected or ambiguous
/// write is reconciled from the server when possible and otherwise rolled back
/// to the last state that was authoritatively confirmed.
@MainActor
final class ServerFavoriteSyncService {
    private struct PendingMutation {
        let song: Song
        let source: MusicSource
        let sourceScopeFingerprint: String
        let itemID: String
        let sourceType: MusicSourceType
        let previous: Bool
        let desired: Bool
    }

    private struct ScopedConfirmedStates {
        let sourceScopeFingerprint: String
        var valuesBySongID: [String: Bool]
    }

    private let sourceManager: any ServerFavoriteManaging
    private let sourcesStore: any ServerFavoriteSourcesProviding
    private let library: any ServerFavoriteLibraryManaging
    private weak var player: (any ServerFavoriteSurfacePublishing)?
    private var pendingMutations: [String: [String: PendingMutation]] = [:]
    private var mutationTasks: [String: Task<Void, Never>] = [:]
    private var mutationRevisions: [String: UInt64] = [:]
    /// Last state confirmed by a mutation response or recovery read. Each
    /// bucket is bound to one complete account/security scope and spans a
    /// rapid sequence for one song, so stale work cannot roll back a new
    /// account to another optimistic UI value.
    private var confirmedStates: [String: ScopedConfirmedStates] = [:]

    init(
        sourceManager: any ServerFavoriteManaging,
        sourcesStore: any ServerFavoriteSourcesProviding,
        library: any ServerFavoriteLibraryManaging,
        player: any ServerFavoriteSurfacePublishing
    ) {
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
        self.library = library
        self.player = player
    }

    func localLikedStateDidChange(song: Song, previous: Bool, desired: Bool) {
        mutationRevisions[song.sourceID, default: 0] &+= 1
        guard let source = sourcesStore.source(id: song.sourceID),
              ServerFavoriteWritebackPolicy.supports(source.type) else { return }
        guard source.isEnabled, !source.isDeleted else {
            failImmediately(
                song: song,
                previous: previous,
                desired: desired,
                error: SourceError.fileNotFound("Source not found for favorite update")
            )
            return
        }
        guard let itemID = ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: song.filePath,
            sourceType: source.type
        ) else {
            failImmediately(
                song: song,
                previous: previous,
                desired: desired,
                error: SourceError.fileNotFound(String(localized: "server_favorite_missing_song_id"))
            )
            return
        }

        let sourceScopeFingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        if confirmedState(
            sourceID: song.sourceID,
            sourceScopeFingerprint: sourceScopeFingerprint,
            songID: song.id
        ) == nil {
            setConfirmedState(
                previous,
                sourceID: song.sourceID,
                sourceScopeFingerprint: sourceScopeFingerprint,
                songID: song.id
            )
        }

        var sourceMutations = pendingMutations[song.sourceID] ?? [:]
        sourceMutations[song.id] = PendingMutation(
            song: song,
            source: source,
            sourceScopeFingerprint: sourceScopeFingerprint,
            itemID: itemID,
            sourceType: source.type,
            previous: previous,
            desired: desired
        )
        pendingMutations[song.sourceID] = sourceMutations

        guard mutationTasks[song.sourceID] == nil else { return }
        let sourceID = song.sourceID
        mutationTasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainMutations(sourceID: sourceID)
            self.mutationTasks[sourceID] = nil
        }
    }

    func refresh(
        source: MusicSource,
        applyFence: ServerMirrorApplyFence = { true }
    ) async {
        guard ServerFavoriteWritebackPolicy.supports(source.type),
              source.isEnabled, !source.isDeleted else { return }
        guard mutationTasks[source.id] == nil else { return }
        let sourceScopeFingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        guard sourceScopeIsCurrent(
            sourceID: source.id,
            expectedFingerprint: sourceScopeFingerprint
        ) else { return }
        let mutationRevision = mutationRevisions[source.id, default: 0]
        do {
            guard let snapshot = try await sourceManager.fetchServerFavorites(for: source) else { return }
            guard applyFence(),
                  mutationTasks[source.id] == nil,
                  sourceScopeIsCurrent(
                      sourceID: source.id,
                      expectedFingerprint: sourceScopeFingerprint
                  ),
                  mutationRevisions[source.id, default: 0] == mutationRevision else { return }
            guard await reconcile(snapshot, sourceID: source.id, sourceType: source.type, applyFence: {
                applyFence() && self.mutationTasks[source.id] == nil
                    && self.sourceScopeIsCurrent(sourceID: source.id, expectedFingerprint: sourceScopeFingerprint)
                    && self.mutationRevisions[source.id, default: 0] == mutationRevision
            }) else { return }
            clearConfirmedStates(
                sourceID: source.id,
                sourceScopeFingerprint: sourceScopeFingerprint
            )
        } catch is CancellationError {
            return
        } catch {
            plog("Server favorites source=\(LogRedactionPolicy.digest(source.id)) result=failed \(LogRedactionPolicy.errorSummary(error))")
        }
    }

    func waitForPendingMutations(sourceID: String) async {
        while let task = mutationTasks[sourceID] {
            await task.value
        }
    }

    private func drainMutations(sourceID: String) async {
        while let mutation = takeNextMutation(sourceID: sourceID) {
            guard mutationScopeIsCurrent(mutation) else {
                discardStaleMutationState(mutation, sourceID: sourceID)
                continue
            }
            do {
                guard let snapshot = try await sourceManager.setServerFavorite(
                    for: mutation.song,
                    source: mutation.source,
                    isFavorite: mutation.desired
                ) else {
                    throw SourceError.connectionFailed(String(localized: "server_favorite_unsupported"))
                }
                guard mutationScopeIsCurrent(mutation) else {
                    discardStaleMutationState(mutation, sourceID: sourceID)
                    continue
                }
                try await accept(snapshot, for: mutation, sourceID: sourceID)
            } catch is CancellationError {
                if !hasPendingMutation(sourceID: sourceID, songID: mutation.song.id) {
                    if mutationScopeIsCurrent(mutation) {
                        rollbackToConfirmedState(mutation, sourceID: sourceID)
                    } else {
                        discardStaleMutationState(mutation, sourceID: sourceID)
                    }
                }
            } catch {
                await recover(mutation, error: error, sourceID: sourceID)
            }
        }
    }

    private func recover(
        _ mutation: PendingMutation,
        error: Error,
        sourceID: String
    ) async {
        guard mutationScopeIsCurrent(mutation) else {
            discardStaleMutationState(mutation, sourceID: sourceID)
            return
        }
        let recoveredSnapshot = try? await sourceManager.fetchServerFavorites(
            for: mutation.source
        )
        guard mutationScopeIsCurrent(mutation) else {
            discardStaleMutationState(mutation, sourceID: sourceID)
            return
        }
        if let snapshot = recoveredSnapshot {
            let serverValue = snapshot.itemIDs.contains(mutation.itemID)
            setConfirmedState(
                serverValue,
                sourceID: sourceID,
                sourceScopeFingerprint: mutation.sourceScopeFingerprint,
                songID: mutation.song.id
            )

            if hasPendingMutation(sourceID: sourceID, songID: mutation.song.id) {
                return
            }
            if hasPendingMutations(sourceID: sourceID) {
                library.setLiked(
                    songID: mutation.song.id,
                    isLiked: serverValue,
                    propagatesServerMutation: false
                )
                clearConfirmedState(
                    sourceID: sourceID,
                    sourceScopeFingerprint: mutation.sourceScopeFingerprint,
                    songID: mutation.song.id
                )
            } else {
                let revision = mutationRevisions[sourceID, default: 0]
                guard await reconcile(snapshot, sourceID: sourceID, sourceType: mutation.sourceType, applyFence: {
                    self.mutationScopeIsCurrent(mutation)
                        && self.mutationRevisions[sourceID, default: 0] == revision
                }) else { return }
                clearConfirmedStates(
                    sourceID: sourceID,
                    sourceScopeFingerprint: mutation.sourceScopeFingerprint
                )
            }
            player?.republishNowPlayingSurfaces()
            if serverValue == mutation.desired {
                return
            }
        } else if hasPendingMutation(sourceID: sourceID, songID: mutation.song.id) {
            return
        } else {
            rollbackToConfirmedState(mutation, sourceID: sourceID)
        }

        presentFailure(error)
    }

    private func accept(
        _ snapshot: ServerFavoriteSnapshot,
        for mutation: PendingMutation,
        sourceID: String
    ) async throws {
        let serverValue = snapshot.itemIDs.contains(mutation.itemID)
        guard serverValue == mutation.desired else {
            throw SourceError.connectionFailed(String(localized: "server_favorite_refresh_mismatch"))
        }
        setConfirmedState(
            serverValue,
            sourceID: sourceID,
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            songID: mutation.song.id
        )

        if hasPendingMutation(sourceID: sourceID, songID: mutation.song.id) {
            return
        }
        if hasPendingMutations(sourceID: sourceID) {
            library.setLiked(
                songID: mutation.song.id,
                isLiked: serverValue,
                propagatesServerMutation: false
            )
            clearConfirmedState(
                sourceID: sourceID,
                sourceScopeFingerprint: mutation.sourceScopeFingerprint,
                songID: mutation.song.id
            )
        } else {
            let revision = mutationRevisions[sourceID, default: 0]
            guard await reconcile(snapshot, sourceID: sourceID, sourceType: mutation.sourceType, applyFence: {
                self.mutationScopeIsCurrent(mutation)
                    && self.mutationRevisions[sourceID, default: 0] == revision
            }) else { return }
            clearConfirmedStates(
                sourceID: sourceID,
                sourceScopeFingerprint: mutation.sourceScopeFingerprint
            )
        }
        player?.republishNowPlayingSurfaces()
    }

    private func rollbackToConfirmedState(_ mutation: PendingMutation, sourceID: String) {
        guard mutationScopeIsCurrent(mutation) else {
            discardStaleMutationState(mutation, sourceID: sourceID)
            return
        }
        let confirmed = confirmedState(
            sourceID: sourceID,
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            songID: mutation.song.id
        )
            ?? mutation.previous
        let shouldRollback = library.isLiked(songID: mutation.song.id) == mutation.desired
        if shouldRollback {
            library.setLiked(
                songID: mutation.song.id,
                isLiked: confirmed,
                propagatesServerMutation: false
            )
        }
        clearConfirmedState(
            sourceID: sourceID,
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            songID: mutation.song.id
        )
        if shouldRollback {
            player?.republishNowPlayingSurfaces()
        }
    }

    private func reconcile(
        _ snapshot: ServerFavoriteSnapshot,
        sourceID: String,
        sourceType: MusicSourceType,
        applyFence: () -> Bool
    ) async -> Bool {
        // 曲库里没有的收藏(插件的在线收藏)先作为仅歌单的歌入库, 下面才对得上号。
        let admitted = snapshot.itemIDs.compactMap { snapshot.playableSongs[$0] }
        library.admitCollectionOnlySongs(
            admitted,
            sourceID: sourceID,
            indexMaintenance: .immediate
        )
        if let musicLibrary = library as? MusicLibrary, let reader = P2cCatalogAccess.reader(for: musicLibrary) {
            // 曲库目录可读时(P2c)只读这个源的身份投影。刚入库的仅歌单歌目录可能还没跟上,
            // 它们排在库尾,按同一规则补在目录结果后面(先到的算数不变)。
            let requested = Set(snapshot.itemIDs)
            do {
                var matches = try await reader.firstSongIDs(sourceID: sourceID, wanting: requested) { path in
                    ServerFavoriteWritebackPolicy.songID(fromConnectorPath: path, sourceType: sourceType)
                }
                for song in admitted where song.sourceID == sourceID {
                    guard let itemID = ServerFavoriteWritebackPolicy.songID(
                            fromConnectorPath: song.filePath, sourceType: sourceType
                          ), requested.contains(itemID), matches[itemID] == nil else { continue }
                    matches[itemID] = song.id
                }
                let prepared = snapshot.itemIDs.compactMap { matches[$0] }
                guard !Task.isCancelled, applyFence() else { return false }
                return applyReconciled(snapshot, sourceID: sourceID, serverLikes: prepared)
            } catch is CancellationError {
                return false
            } catch {
                plog("Server favorites source=\(LogRedactionPolicy.digest(sourceID)) catalog match failed, using in-memory library: \(error.localizedDescription)")
            }
        }
        let songs = library.songs
        let worker = Task.detached(priority: .utility) { () -> [String]? in
            let requested = Set(snapshot.itemIDs)
            var matches: [String: String] = [:]
            for index in songs.indices {
                if index.isMultiple(of: 1024), Task.isCancelled { return nil }
                if matches.count == requested.count { break }
                guard songs[index].sourceID == sourceID else { continue }
                guard let itemID = ServerFavoriteWritebackPolicy.songID(
                        fromConnectorPath: songs[index].filePath, sourceType: sourceType
                      ), requested.contains(itemID), matches[itemID] == nil else { continue }
                matches[itemID] = songs[index].id
            }
            return snapshot.itemIDs.compactMap { matches[$0] }
        }
        let prepared = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard let prepared, !Task.isCancelled, applyFence() else { return false }
        return applyReconciled(snapshot, sourceID: sourceID, serverLikes: prepared)
    }

    private func applyReconciled(_ snapshot: ServerFavoriteSnapshot, sourceID: String, serverLikes: [String]) -> Bool {
        let currentLikes = library.likedSongIDs(fromSourceID: sourceID)
        let likedBefore = Set(currentLikes)
        // 清单不完整时只加不撤：被跳过的那几条里可能就有本机已喜欢的歌。
        let retainedLikes = snapshot.isComplete ? [] : currentLikes
        let likedAfter = Set(retainedLikes + serverLikes)
        // 「服务器上收藏了 N 首、本机对上 M 首」: 用户说两边对不上时先看这一行。
        plog("Server favorites source=\(LogRedactionPolicy.digest(sourceID)) result=reconciled server=\(snapshot.itemIDs.count) matched=\(serverLikes.count) added=\(likedAfter.subtracting(likedBefore).count) removed=\(likedBefore.subtracting(likedAfter).count) complete=\(snapshot.isComplete)")
        library.replaceLikedSongs(
            fromSourceID: sourceID,
            with: retainedLikes + serverLikes
        )
        library.releaseUnreferencedCollectionOnlySongs(sourceID: sourceID)
        return true
    }

    private func takeNextMutation(sourceID: String) -> PendingMutation? {
        guard var sourceMutations = pendingMutations[sourceID],
              let songID = sourceMutations.keys.first,
              let mutation = sourceMutations.removeValue(forKey: songID) else { return nil }
        if sourceMutations.isEmpty {
            pendingMutations.removeValue(forKey: sourceID)
        } else {
            pendingMutations[sourceID] = sourceMutations
        }
        return mutation
    }

    private func hasPendingMutations(sourceID: String) -> Bool {
        pendingMutations[sourceID]?.isEmpty == false
    }

    private func hasPendingMutation(sourceID: String, songID: String) -> Bool {
        pendingMutations[sourceID]?[songID] != nil
    }

    private func mutationScopeIsCurrent(_ mutation: PendingMutation) -> Bool {
        sourceScopeIsCurrent(
            sourceID: mutation.song.sourceID,
            expectedFingerprint: mutation.sourceScopeFingerprint
        )
    }

    private func sourceScopeIsCurrent(
        sourceID: String,
        expectedFingerprint: String
    ) -> Bool {
        guard let current = sourcesStore.source(id: sourceID),
              current.isEnabled,
              !current.isDeleted else { return false }
        return MusicSourceSecurityRevision.scopedFingerprint(for: current)
            == expectedFingerprint
    }

    private func discardStaleMutationState(_ mutation: PendingMutation, sourceID: String) {
        clearConfirmedState(
            sourceID: sourceID,
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            songID: mutation.song.id
        )
    }

    private func confirmedState(
        sourceID: String,
        sourceScopeFingerprint: String,
        songID: String
    ) -> Bool? {
        guard let sourceStates = confirmedStates[sourceID],
              sourceStates.sourceScopeFingerprint == sourceScopeFingerprint else { return nil }
        return sourceStates.valuesBySongID[songID]
    }

    private func setConfirmedState(
        _ value: Bool,
        sourceID: String,
        sourceScopeFingerprint: String,
        songID: String
    ) {
        var sourceStates: ScopedConfirmedStates
        if let existing = confirmedStates[sourceID],
           existing.sourceScopeFingerprint == sourceScopeFingerprint {
            sourceStates = existing
        } else {
            sourceStates = ScopedConfirmedStates(
                sourceScopeFingerprint: sourceScopeFingerprint,
                valuesBySongID: [:]
            )
        }
        sourceStates.valuesBySongID[songID] = value
        confirmedStates[sourceID] = sourceStates
    }

    private func clearConfirmedState(
        sourceID: String,
        sourceScopeFingerprint: String,
        songID: String
    ) {
        guard var sourceStates = confirmedStates[sourceID],
              sourceStates.sourceScopeFingerprint == sourceScopeFingerprint else { return }
        sourceStates.valuesBySongID.removeValue(forKey: songID)
        if sourceStates.valuesBySongID.isEmpty {
            confirmedStates.removeValue(forKey: sourceID)
        } else {
            confirmedStates[sourceID] = sourceStates
        }
    }

    private func clearConfirmedStates(
        sourceID: String,
        sourceScopeFingerprint: String
    ) {
        guard confirmedStates[sourceID]?.sourceScopeFingerprint == sourceScopeFingerprint else {
            return
        }
        confirmedStates.removeValue(forKey: sourceID)
    }

    private func failImmediately(
        song: Song,
        previous: Bool,
        desired: Bool,
        error: Error
    ) {
        guard library.isLiked(songID: song.id) == desired else { return }
        library.setLiked(
            songID: song.id,
            isLiked: previous,
            propagatesServerMutation: false
        )
        player?.republishNowPlayingSurfaces()
        presentFailure(error)
    }

    private func presentFailure(_ error: Error) {
        library.presentServerFavoriteError(String(
            format: String(localized: "server_favorite_update_failed_message"),
            error.localizedDescription
        ))
    }
}

/// 把服务端镜像(歌单 /「喜欢」/ 电台)的刷新从曲库扫描里拆出来。
///
/// 这三样原本只在 `ScanService` 的扫描收尾里跑, 而扫描只在曲库真的变了、目录探针
/// (`ServerCatalogAutoRefreshPolicy`) 判定需要重扫时才会自动发生 —— 用户在服务器上
/// 只新建了一个歌单、没加歌, 就一直看不到(#142)。
///
/// 曲库没变也该能看到服务器上新建的歌单, 所以这里按源单独刷一次: 冷启动一次,
/// 回到前台且过了冷却再一次。只发歌单 / 收藏 / 电台这几个小请求, 不遍历曲库,
/// 也不改任何扫描状态。
@MainActor
final class ServerMirrorRefreshCoordinator {
    /// 一次刷新要按歌单逐个拉明细, 比目录探针的一个请求贵, 冷却也给得更长。
    static let cooldown: TimeInterval = 30 * 60
    /// 与目录探针一样避开首屏: 启动这几秒的网络留给正在播的那首歌。
    private let launchDelay: Duration

    private let sourcesStore: SourcesStore
    private let sourceManager: SourceManager
    private let library: MusicLibrary
    private let scanService: ScanService
    private let refreshMirrors: (MusicSource, ServerMirrorApplyFence) async -> Void

    /// 发起时间, 不是成功时间: 连不上的服务器也要按冷却退避, 否则每次切回前台
    /// 都要在超时上等一轮。
    private var lastRefreshStartedAt: [String: Date] = [:]
    private var runningTask: Task<Void, Never>?
    private var didScheduleColdLaunch = false

    init(
        sourcesStore: SourcesStore,
        sourceManager: SourceManager,
        library: MusicLibrary,
        scanService: ScanService,
        launchDelay: Duration = .seconds(6),
        refreshMirrors: @escaping (MusicSource, ServerMirrorApplyFence) async -> Void
    ) {
        self.sourcesStore = sourcesStore
        self.sourceManager = sourceManager
        self.library = library
        self.scanService = scanService
        self.launchDelay = launchDelay
        self.refreshMirrors = refreshMirrors
    }

    func startColdLaunchRefresh() {
        guard !didScheduleColdLaunch else { return }
        didScheduleColdLaunch = true
        start(after: launchDelay)
    }

    func applicationDidBecomeActive() {
        // 冷启动那一轮还没排上就别插队, 它自己会跑。
        guard didScheduleColdLaunch else { return }
        start(after: .zero)
    }

    private func start(after delay: Duration) {
        guard runningTask == nil else { return }
        runningTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self else { return }
            // 清干净再返回: 漏掉一次就再也没有下一轮了。
            defer { self.runningTask = nil }
            guard !Task.isCancelled else { return }
            // 库还在准备时 `library.songs` 是空的, 服务端歌单会被整份判成
            // "一首都对不上"而不建 —— 等发布完再对。
            await self.library.whenReady()
            await self.refreshDueSources()
        }
    }

    private func refreshDueSources() async {
        for source in sourcesStore.sources {
            guard !Task.isCancelled else { return }
            guard isDue(source, now: Date()) else { continue }
            // 用户正在滑动、播放页正在展开收起、封面和歌词正在互换时，等停稳再开始这个源（最多 15 秒）。
            // 只是开着播放页不算：照常刷新，不取消已经开始的那一轮。
            await UserScrollActivityMonitor.shared.waitUntilSettled()
            let now = Date()
            guard !Task.isCancelled, isDue(source, now: now) else { continue }
            lastRefreshStartedAt[source.id] = now

            // 刷新期间源被停用 / 删除 / 改了凭据, 或者扫描接手了这个源, 拿回来的
            // 快照就不该再落地 —— 与扫描收尾用的是同一道闸。
            let scopeFingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
            let sourceID = source.id
            let applyFence: ServerMirrorApplyFence = { [weak self] in
                guard let self, !Task.isCancelled,
                      let current = self.sourcesStore.source(id: sourceID),
                      current.isEnabled,
                      !current.isDeleted,
                      MusicSourceSecurityRevision.scopedFingerprint(for: current) == scopeFingerprint,
                      self.scanService.scanStates[sourceID]?.isScanning != true else { return false }
                return true
            }
            guard applyFence() else { continue }
            await refreshMirrors(source, applyFence)
        }
    }

    private func isDue(_ source: MusicSource, now: Date) -> Bool {
        guard source.type.isServerLibrary, source.isEnabled, !source.isDeleted else { return false }
        // 还没扫过的源本地没有歌可对, 歌单只会被判成"对不上"而不建。等它先扫一次。
        guard source.lastScannedAt != nil || source.songCount > 0 else { return false }
        // 扫描收尾会做同一件事, 别和它抢。
        guard scanService.scanStates[source.id]?.isScanning != true else { return false }
        // 当前网络路径下这个源的每个地址都探测失败过, 现在去连只会白等一轮超时。
        guard !sourceManager.unreachablePlaybackSourceIDs.contains(source.id) else { return false }
        guard let last = lastRefreshStartedAt[source.id] else { return true }
        return now.timeIntervalSince(last) >= Self.cooldown
    }
}

@MainActor
enum PlaylistDescriptionService {
    static func serverSource(for playlist: Playlist, sourcesStore: SourcesStore) -> MusicSource? {
        sourcesStore.sources.first { source in
            source.isEnabled && !source.isDeleted
                && PlaylistDescriptionPolicy.supportsServerWriteback(source.type)
                && ServerPlaylistWritebackPolicy.serverPlaylistID(
                    fromMirrorPlaylistID: playlist.id, sourceID: source.id
                ) != nil
        }
    }

    static func canEdit(_ playlist: Playlist, sourcesStore: SourcesStore) -> Bool {
        guard !playlist.isDeleted else { return false }
        if !MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id) { return MusicLibrary.allowsRename(playlist) }
        return serverSource(for: playlist, sourcesStore: sourcesStore) != nil
            && !ServerPlaylistMirror.readOnlyPlaylistIDs.contains(playlist.id)
    }

    static func save(
        _ description: String, playlist: Playlist, library: MusicLibrary,
        sourcesStore: SourcesStore, sourceManager: SourceManager
    ) async throws {
        guard canEdit(playlist, sourcesStore: sourcesStore) else { throw ServerPlaylistAppendError.readOnly }
        if MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id) {
            guard let source = serverSource(for: playlist, sourcesStore: sourcesStore),
                  let id = ServerPlaylistWritebackPolicy.serverPlaylistID(
                    fromMirrorPlaylistID: playlist.id, sourceID: source.id
                  ) else { throw ServerPlaylistAppendError.readOnly }
            let refreshed = try await sourceManager.updateServerPlaylistDescription(
                id: id, description: description, source: source
            )
            ServerPlaylistMirror.applyAppended(refreshed, source: source, library: library)
        } else {
            guard library.updatePlaylistDescription(id: playlist.id, description: description) else {
                throw CancellationError()
            }
        }
    }
}
