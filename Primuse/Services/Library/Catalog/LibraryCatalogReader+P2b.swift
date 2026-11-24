import Foundation
import Observation
import PrimuseKit

/// 整库播放请求(播放全部、随机全部、从这首开始、Spotlight 点歌接整库)在目录上的描述。
/// 拼成的列表是 `leadingIDs` + 范围里库内顺序的歌(去掉 `excludedIDs`),与原来交给
/// `play(queueIDs:)` 的那张 id 列表逐项相同;过滤、打乱、截窗口沿用 `LargeQueueRequestPlanner`。
struct CatalogLibraryQueueRequest: Sendable {
    /// 排在整库前面的歌(点的那首、最近播放),按给定先后。
    var leadingIDs: [String] = []
    /// 起点在拼成的列表里的位置(同 `play(queueIDs:startingAt:)`)。
    var startIndex: Int = 0
    var order: LargeQueueRequestOrder = .asGiven
    /// 整库那一段的类别:`[.music]` 是 `musicSongs`,nil 是全部可见内容(`visibleSongs`)。
    var kinds: Set<LibraryCatalogContentKind>? = [.music]
    /// 整库那一段去掉的歌:不喜欢的(#193)、已经排在前面的。小集合。
    var excludedIDs: Set<String> = []
    /// 同 `play(queueIDs:playableOnly:)`。
    var playableOnly: Bool = true
    /// `leadingIDs` 的第一首必须还在可见曲库里,不在就什么也不放(Spotlight / 快捷操作点歌)。
    var requiresFirstLeadingSong = false
}

/// `planLibraryQueue` 的结果。
enum CatalogLibraryQueuePlan: Sendable {
    case prepared(PreparedQueueRequest<Song>, requestedCount: Int)
    /// 拼成的列表里一首能放的都没有。
    case empty(requestedCount: Int)
    /// `requiresFirstLeadingSong` 而那首已经不在可见曲库里。
    case missingFirstLeadingSong
}

/// P2b(播放器、队列、随机、续接、首页)要的目录查询。只用目录的公开接口,全部在主线程外执行。
extension LibraryCatalogReader {
    /// 按 id 批量取成字典(超过 `LibraryScale.maxMaterializedRows` 的分批取)。结果以 `ids` 为界:
    /// 队列窗口、恢复的会话、续接的一批。
    func songsByID(
        _ ids: some Collection<String>,
        visibility: LibraryCatalogVisibility,
        playableOnly: Bool = false
    ) async throws -> [String: Song] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let scope = LibrarySongScope(includesDisabledSources: visibility.includesDisabledSources, playableOnly: playableOnly)
        return try await read { catalog in
            try Self.songsByID(unique, scope: scope, in: catalog)
        }
    }

    static func songsByID(_ unique: [String], scope: LibrarySongScope, in catalog: LibraryCatalog) throws -> [String: Song] {
        var result: [String: Song] = [:]
        result.reserveCapacity(unique.count)
        var start = 0
        while start < unique.count {
            let end = min(unique.count, start + LibraryScale.maxMaterializedRows)
            for song in try catalog.songs(ids: Array(unique[start..<end]), scope: scope) where result[song.id] == nil {
                result[song.id] = song
            }
            start = end
        }
        return result
    }

    /// 按 id 顺序取,保持输入顺序(重复的照样重复),不在的跳过。`ids` 超过上限时分批。
    func orderedSongs(
        ids: [String],
        visibility: LibraryCatalogVisibility,
        playableOnly: Bool = false
    ) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        let byID = try await songsByID(ids, visibility: visibility, playableOnly: playableOnly)
        return ids.compactMap { byID[$0] }
    }

    /// 整库播放请求:在目录上拼出 id 列表,交给 `LargeQueueRequestPlanner` 过滤、旋转或打乱、截窗口,
    /// 只把装进播放器的那一窗(至多 `QueueWindowPolicy.windowLimit` 首)物化。
    ///
    /// 与 `play(queueIDs:)` 的内存路径逐项对应:
    /// - `includes`:可见且(需要时)可播 —— 整库那一段由范围本身保证;前面那几首、随机连播会带进来的
    ///   那几首按 id 在目录里查一次(都是小集合);
    /// - `resolve`:可见曲库里按 id 取;
    /// - 随机:不加权时同 `shuffle()`;按抽歌偏好加权(#332)时每首的权重在流式遍历时算好,
    ///   只记与默认权重不同的那些(播放过的歌、常听歌手的歌)。
    ///
    /// 界限:续接(`QueueContinuation`)按 id 存整张请求,所以这里仍有一份整库规模的 id 数组,
    /// 与原来的 `musicSongIDsExcludingDisliked` 同阶;Kit 的续接改存行号(PLAN §4.5)之后才去得掉。
    func planLibraryQueue(
        _ request: CatalogLibraryQueueRequest,
        weighting: ShuffleWeighting?,
        linkGraph: ShuffleLinkGraph,
        linkNeighborIDs: [String]
    ) async throws -> CatalogLibraryQueuePlan {
        try await read { catalog in
            try Self.planLibraryQueue(
                request, weighting: weighting, linkGraph: linkGraph, linkNeighborIDs: linkNeighborIDs, in: catalog
            )
        }
    }

    private static func planLibraryQueue(
        _ request: CatalogLibraryQueueRequest,
        weighting: ShuffleWeighting?,
        linkGraph: ShuffleLinkGraph,
        linkNeighborIDs: [String],
        in catalog: LibraryCatalog
    ) throws -> CatalogLibraryQueuePlan {
        let visible = LibrarySongScope(includesDisabledSources: false)
        let includable = LibrarySongScope(includesDisabledSources: false, playableOnly: request.playableOnly)

        // 前面那几首:可见(不论能不能放)用来判断「点的那首还在不在」,可放用来过滤。
        let leading = request.leadingIDs
        let leadingVisible = try songsByID(Array(Set(leading)), scope: visible, in: catalog)
        if request.requiresFirstLeadingSong {
            guard let first = leading.first, leadingVisible[first] != nil else { return .missingFirstLeadingSong }
        }
        var leadingVerdict: [String: Bool] = [:]
        for id in leading where leadingVerdict[id] == nil {
            let song = leadingVisible[id]
            leadingVerdict[id] = song != nil && (!request.playableOnly || song?.isPlayable == true)
        }

        // 随机连播(#335)会带进来、又不在列表里的歌:只可能是这些邻居,事先按同一个条件查好。
        let neighborSet = Set(linkNeighborIDs)
        let includableNeighbors = neighborSet.isEmpty
            ? []
            : Set(try songsByID(Array(neighborSet), scope: includable, in: catalog).keys)

        // 整库那一段,库内顺序。
        var scope = includable
        scope.kinds = request.kinds
        let excluded = request.excludedIDs
        var ids = leading
        var weights: [String: Double] = [:]
        if let weighting {
            var resolver = ShuffleArtistKeyResolver()
            let fallback = weighting.defaultWeight
            for id in leading where weights[id] == nil {
                let weight = weighting.weight(of: leadingVisible[id], resolver: &resolver)
                if weight != fallback { weights[id] = weight }
            }
            try catalog.forEachSong(scope) { _, song in
                guard !excluded.contains(song.id) else { return true }
                ids.append(song.id)
                let weight = weighting.weight(of: song, resolver: &resolver)
                if weight != fallback, weights[song.id] == nil { weights[song.id] = weight }
                return true
            }
        } else {
            try catalog.forEachSongIdentity(scope) { _, id, _ in
                if !excluded.contains(id) { ids.append(id) }
                return true
            }
        }
        let requestedCount = ids.count
        guard !ids.isEmpty else { return .empty(requestedCount: 0) }

        let planned = LargeQueueRequestPlanner.plan(
            ids: ids,
            startIndex: request.startIndex,
            order: request.order,
            includes: { id in
                if let verdict = leadingVerdict[id] { return verdict }
                if neighborSet.contains(id) { return includableNeighbors.contains(id) }
                return true
            },
            resolve: { id -> String? in id },
            linkGraph: linkGraph,
            shuffleInPlace: { list in
                if let weighting {
                    list = weighting.shuffled(ids: list, sparseWeights: weights)
                } else {
                    list.shuffle()
                }
            }
        )
        ids = []
        weights = [:]
        guard let planned else { return .empty(requestedCount: requestedCount) }

        // 只物化装进播放器的那一窗;找不到的跳过,起点按 planner 的规则落在其后第一首。
        let window = planned.items
        let resolved = try songsByID(Array(Set(window)), scope: visible, in: catalog)
        var songs: [Song] = []
        songs.reserveCapacity(window.count)
        var selected: Int?
        for (offset, id) in window.enumerated() {
            guard let song = resolved[id] else { continue }
            if selected == nil, offset >= planned.selectedIndex { selected = songs.count }
            songs.append(song)
        }
        guard !songs.isEmpty else { return .empty(requestedCount: requestedCount) }
        return .prepared(
            PreparedQueueRequest(
                items: songs,
                selectedIndex: selected ?? songs.count - 1,
                continuation: planned.continuation
            ),
            requestedCount: requestedCount
        )
    }

    /// 沉浸播放页的封面墙样本,与 `ImmersivePlayerView.refreshGallerySongs` 的内存路径同一套取法:
    /// 整库(含停用源)按库内顺序,从当前这首的 id 算出的起点按固定步长跳着看,收有封面的;
    /// 不够时从头按顺序补(最多看前两万首)。只物化落点上的歌,至多几千首,分批取。
    func immersiveGallerySample(limit maxCount: Int, currentID: String?) async throws -> [Song] {
        try await read { catalog in
            let rowids = try catalog.rowList(.everything).rowids
            let total = rowids.count
            guard total > 0, maxCount > 0 else { return [] }
            let limit = min(maxCount, total)
            let seedText = currentID ?? "primuse"
            let seed = seedText.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
            let rawStride = max(1, total / max(limit, 1))
            let step = rawStride.isMultiple(of: 2) ? rawStride + 1 : rawStride
            let maxAttempts = min(total * 2, limit * 400)
            func hasCover(_ song: Song) -> Bool {
                !(song.coverArtFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            var selected: [Song] = []
            var seen = Set<String>()
            var cursor = seed % total
            var attempts = 0
            while selected.count < limit && attempts < maxAttempts {
                // 先把接下来一段落点算出来一起取,再按原来的先后逐个看。
                var positions: [Int32] = []
                var probe = cursor
                var probeAttempts = attempts
                while positions.count < 256 && probeAttempts < maxAttempts {
                    positions.append(rowids[probe % total])
                    probe += step + probeAttempts % 7
                    probeAttempts += 1
                }
                let songs = try catalog.songs(rowids: positions)
                // 取的过程中有行被删时对不上位置:按取到的逐个算一次尝试(只差在这种竞态上)。
                for song in songs {
                    if song.id != currentID, hasCover(song), seen.insert(song.id).inserted {
                        selected.append(song)
                    }
                    cursor += step + attempts % 7
                    attempts += 1
                    if selected.count >= limit { break }
                }
                if songs.count < positions.count {
                    for _ in songs.count..<positions.count where attempts < maxAttempts && selected.count < limit {
                        cursor += step + attempts % 7
                        attempts += 1
                    }
                }
            }
            if selected.count < limit {
                let prefix = rowids.prefix(20_000)
                var start = prefix.startIndex
                fill: while start < prefix.endIndex {
                    let end = min(prefix.endIndex, start + 1_000)
                    for song in try catalog.songs(rowids: prefix[start..<end])
                    where song.id != currentID && hasCover(song) && seen.insert(song.id).inserted {
                        selected.append(song)
                        if selected.count == limit { break fill }
                    }
                    start = end
                }
            }
            return selected
        }
    }

    /// 首页、Mac 队列面板、主屏快捷操作要的几个计数(只问「有没有」与签名里的数)。
    func playbackSurfaceCounts() async throws -> PlaybackSurfaceCatalogCounts {
        try await read { catalog in
            PlaybackSurfaceCatalogCounts(
                visibleSongs: try catalog.songCount(.visible),
                music: try catalog.songCount(.visibleMusic),
                hasPlayableVisibleSong: try catalog.containsSongs(LibrarySongScope(playableOnly: true)),
                albums: try catalog.albumKeys(visibleOnly: true).count,
                artists: try catalog.artistKeys(visibleOnly: true).count
            )
        }
    }
}

/// `playbackSurfaceCounts()` 的结果。
struct PlaybackSurfaceCatalogCounts: Sendable, Equatable {
    /// `visibleSongs.count`
    var visibleSongs = 0
    /// `musicSongs.count`
    var music = 0
    /// `visibleSongs.contains(where: \.isPlayable)`
    var hasPlayableVisibleSong = false
    /// `visibleAlbums.count`
    var albums = 0
    /// `visibleArtists.count`
    var artists = 0
}

/// 目录读到的计数,给只问「有没有歌」「几首」的视图读(P2 过渡:目录不能读、还没读到时
/// 调用方照旧读内存模型)。按目录变化防抖后在主线程外重读;每个目录一份。
@MainActor
@Observable
final class PlaybackSurfaceCountsModel {
    private(set) var counts: PlaybackSurfaceCatalogCounts?

    @ObservationIgnored private weak var host: LibraryCatalogHost?
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    private static var models: [ObjectIdentifier: PlaybackSurfaceCountsModel] = [:]

    /// 这个库的计数模型;库不带目录时为 nil。第一次取时开始跟踪目录变化。
    static func shared(for library: MusicLibrary) -> PlaybackSurfaceCountsModel? {
        guard let host = library.catalogHost else { return nil }
        let key = ObjectIdentifier(host)
        if let model = models[key] { return model }
        let model = PlaybackSurfaceCountsModel(host: host)
        models[key] = model
        return model
    }

    /// 目录可读且已经读到时的计数;否则 nil(调用方读内存模型)。登记对目录可读状态与计数的观察。
    static func counts(for library: MusicLibrary) -> PlaybackSurfaceCatalogCounts? {
        guard let model = shared(for: library), let host = library.catalogHost, host.revisions.isReadable else {
            return nil
        }
        return model.counts
    }

    private init(host: LibraryCatalogHost) {
        self.host = host
        listenerID = host.revisions.addListener { [weak self] change in
            guard let self else { return false }
            if change.changesMembership || change.invalidatesEverything || !change.updatedRowids.isEmpty {
                self.scheduleReload(after: .milliseconds(300))
            }
            return true
        }
        scheduleReload(after: .zero)
    }

    private func scheduleReload(after delay: Duration) {
        reloadTask?.cancel()
        generation &+= 1
        let generation = generation
        reloadTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let reader = self?.host?.reader else { return }
            let next: PlaybackSurfaceCatalogCounts
            do {
                next = try await reader.playbackSurfaceCounts()
            } catch {
                // 目录还不能读:变成可读时 `setReadable` 会发一次「全部失效」,到时再读。
                return
            }
            guard let self, generation == self.generation else { return }
            if self.counts != next { self.counts = next }
        }
    }
}

/// 视图里只问「几首」「有没有」的地方用:目录可读且已经读到计数时读目录,否则照旧读内存模型
/// (P2 过渡)。在视图里读会登记对目录可读状态与计数的观察。
extension PlaybackSurfaceCountsModel {
    /// `musicSongs.count`
    static func musicSongCount(in library: MusicLibrary) -> Int {
        counts(for: library)?.music ?? library.musicSongs.count
    }

    /// `visibleSongs.count`
    static func visibleSongCount(in library: MusicLibrary) -> Int {
        counts(for: library)?.visibleSongs ?? library.visibleSongs.count
    }

    /// `visibleAlbums.count`
    static func visibleAlbumCount(in library: MusicLibrary) -> Int {
        counts(for: library)?.albums ?? library.visibleAlbums.count
    }

    /// `visibleArtists.count`
    static func visibleArtistCount(in library: MusicLibrary) -> Int {
        counts(for: library)?.artists ?? library.visibleArtists.count
    }

    /// `visibleSongs.contains(where: \.isPlayable)`
    static func hasPlayableVisibleSong(in library: MusicLibrary) -> Bool {
        counts(for: library)?.hasPlayableVisibleSong ?? library.visibleSongs.contains(where: \.isPlayable)
    }
}
