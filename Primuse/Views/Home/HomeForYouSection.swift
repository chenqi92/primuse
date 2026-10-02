import SwiftUI
import PrimuseKit

/// 首页「为你推荐」的智能重排(iPhone/iPad 首页与 Mac 首页共用一份)。
///
/// 候选永远是本地算好的:歌曲来自本地每日推荐,整张专辑来自 `AlbumRecommender`
/// (情景推荐那几张之后的);智能服务只重排、写一句理由,和资料库「智能推荐」走同一套
/// `/v1/recommendations`。同一份候选只问一次:结果在 `MusicIntelligenceService` 里
/// 缓存 6 小时,失败的也要隔半小时才再问,首页来回出现不会反复发请求。智能服务不可用、
/// 还在出结果、没开,或服务端还不认专辑时,照旧显示本地推荐与本地挑的专辑。
@MainActor
@Observable
final class HomeForYouAIFeed {
    static let shared = HomeForYouAIFeed()

    let recommendation = AIRecommendationViewModel()
    /// 当前结果对应的请求;候选或设置一变就不再拿旧结果排新候选。
    private(set) var resultKey: String?
    @ObservationIgnored private var lastAttempt: (key: String, at: Date)?

    nonisolated static let retryInterval: TimeInterval = 30 * 60
    /// 与资料库「智能推荐」、电视首页同一个场景选择。
    nonisolated static let sceneKey = "primuse.ai.recommendationScene.v1"

    static func requestKey(
        candidateIDs: [String],
        albumKeys: [String],
        unit: AIRecommendationUnit,
        albumsReady: Bool,
        intelligence: MusicIntelligenceService
    ) -> String {
        [
            UserDefaults.standard.string(forKey: sceneKey) ?? AIRecommendationScene.automatic.rawValue,
            unit.rawValue,
            albumsReady ? "albums" : "albumsPending",
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
            candidateIDs.joined(separator: "|"),
            albumKeys.joined(separator: "|"),
        ].joined(separator: "#")
    }

    /// 整张专辑的候选,交给智能服务时带上专辑自己的流派。
    static func albumCandidates(
        _ albums: [AlbumRecommendation],
        library: MusicLibrary
    ) -> [AIRecommendationAlbumCandidate] {
        albums.map { $0.intelligenceCandidate(genre: library.visibleAlbum(id: $0.albumID)?.genre) }
    }

    /// 智能推荐此刻能不能用(开了、授权了、有服务可问)。
    static func isAvailable(_ intelligence: MusicIntelligenceService) -> Bool {
        #if DEBUG
        if debugForcesResults { return true }
        #endif
        return intelligence.isPersonalizedRecommendationsConfigured
    }

    #if DEBUG
    /// 截图钩子 `PRIMUSE_DEBUG_FOR_YOU_AI=1`:不问服务,把候选倒过来当作智能结果,
    /// 专辑候选里倒数两张当作它挑的专辑。
    nonisolated static var debugForcesResults: Bool {
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_FOR_YOU_AI"] == "1"
    }
    #endif

    func refresh(
        key: String,
        candidates: [Song],
        unit: AIRecommendationUnit,
        albumCandidates: [AIRecommendationAlbumCandidate],
        intelligence: MusicIntelligenceService
    ) async {
        guard Self.isAvailable(intelligence),
              !candidates.isEmpty || !albumCandidates.isEmpty,
              resultKey != key else { return }
        if let lastAttempt, lastAttempt.key == key,
           Date().timeIntervalSince(lastAttempt.at) < Self.retryInterval {
            return
        }
        lastAttempt = (key, Date())
        #if DEBUG
        if Self.debugForcesResults {
            let songs = Array(candidates.reversed()).enumerated().map { index, song in
                AIRecommendationSelection(songID: song.id, reason: "Debug reason \(index + 1)")
            }
            let albums = unit.includesAlbums
                ? albumCandidates.reversed().prefix(unit.albumSlotCount).map {
                    AIRecommendationSelection(albumKey: $0.albumKey, reason: "Debug album reason")
                }
                : []
            recommendation.debugApply(songs + albums)
            resultKey = key
            return
        }
        #endif
        let scene = AIRecommendationScene(
            rawValue: UserDefaults.standard.string(forKey: Self.sceneKey) ?? ""
        ) ?? .automatic
        // 只要专辑时也照样带上歌曲候选:还不认专辑的服务端缺了歌曲候选会拒绝整个请求,
        // 认专辑的服务端在只要专辑时不看歌曲。
        let succeeded = await recommendation.refresh(
            scene: scene,
            candidates: candidates,
            using: intelligence,
            maximumResults: max(1, candidates.count),
            minimumResults: min(10, max(1, candidates.count)),
            unit: unit,
            albumCandidates: albumCandidates
        )
        if Task.isCancelled {
            // 首页被换走打断的不算问过,回来时再问。
            lastAttempt = nil
            return
        }
        if succeeded { resultKey = key }
    }

    /// 智能结果此刻能不能用来排这一份候选。
    func isShowingIntelligentOrder(key: String, isAvailable: Bool) -> Bool {
        isAvailable && resultKey == key && !recommendation.isStreaming
            && (!recommendation.orderedSongIDs.isEmpty || !recommendation.orderedAlbumKeys.isEmpty)
    }

    /// 智能服务排好的在前,它没挑中的本地推荐接在后面,这一排的长度不变。
    func orderedResults(
        _ local: [MusicDiscoveryResult],
        key: String,
        isAvailable: Bool
    ) -> [MusicDiscoveryResult] {
        guard isShowingIntelligentOrder(key: key, isAvailable: isAvailable) else { return local }
        let byID = Dictionary(local.map { ($0.song.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var ordered: [MusicDiscoveryResult] = []
        for id in recommendation.orderedSongIDs {
            guard let result = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(result)
        }
        ordered.append(contentsOf: local.filter { !seen.contains($0.song.id) })
        return ordered
    }

    /// 智能服务挑的整张专辑(服务端还不认专辑时为空,专辑位由本地结果补上)。
    func intelligentAlbumKeys(key: String, isAvailable: Bool) -> [String] {
        guard isShowingIntelligentOrder(key: key, isAvailable: isAvailable) else { return [] }
        return recommendation.orderedAlbumKeys
    }

    func reason(for songID: String, key: String, isAvailable: Bool) -> String? {
        guard isShowingIntelligentOrder(key: key, isAvailable: isAvailable) else { return nil }
        return recommendation.reason(for: songID)
    }

    func albumReason(for albumKey: String, key: String, isAvailable: Bool) -> String? {
        guard isShowingIntelligentOrder(key: key, isAvailable: isAvailable) else { return nil }
        return recommendation.albumReason(for: albumKey)
    }
}

/// 专辑候选什么时候要重算:要不要专辑变了,或曲库变了(服务自己会合并、复用索引)。
struct AlbumPoolRefreshKey: Hashable {
    let includesAlbums: Bool
    let libraryRevision: Int
}

/// 「为你推荐」这一刻要显示的东西:按推荐单位排好的卡片,以及取卡片内容用的索引。
@MainActor
struct HomeForYouPresentation {
    let key: String
    let isAvailable: Bool
    let isIntelligent: Bool
    let unit: AIRecommendationUnit
    let entries: [AIRecommendationFeedEntry]
    let songs: [MusicDiscoveryResult]
    let songsByID: [String: MusicDiscoveryResult]
    let albumsByID: [String: AlbumRecommendation]
    let albumCandidates: [AIRecommendationAlbumCandidate]
    /// 要专辑时,等本地专辑推荐算出来再去问智能服务,免得冷启动时先问一次只有歌曲的。
    let isReadyToAsk: Bool

    init(
        results: [MusicDiscoveryResult],
        unit: AIRecommendationUnit,
        excludesCurrentAlbumPick: Bool,
        library: MusicLibrary,
        intelligence: MusicIntelligenceService,
        feed: HomeForYouAIFeed
    ) {
        let albumPool = unit.includesAlbums
            ? AlbumRecommendationService.shared.forYouAlbumCandidates(
                excludingCurrentPick: excludesCurrentAlbumPick
            ).filter { library.visibleAlbum(id: $0.albumID) != nil }
            : []
        let albumCandidates = HomeForYouAIFeed.albumCandidates(albumPool, library: library)
        let albumsReady = !unit.includesAlbums
            || AlbumRecommendationService.shared.recommendations != nil
        let key = HomeForYouAIFeed.requestKey(
            candidateIDs: results.map(\.song.id),
            albumKeys: albumCandidates.map(\.albumKey),
            unit: unit,
            albumsReady: albumsReady,
            intelligence: intelligence
        )
        isReadyToAsk = albumsReady
        let isAvailable = HomeForYouAIFeed.isAvailable(intelligence)
        let songs = feed.orderedResults(results, key: key, isAvailable: isAvailable)
        self.key = key
        self.isAvailable = isAvailable
        self.isIntelligent = feed.isShowingIntelligentOrder(key: key, isAvailable: isAvailable)
        self.unit = unit
        self.songs = songs
        self.albumCandidates = albumCandidates
        songsByID = Dictionary(songs.map { ($0.song.id, $0) }, uniquingKeysWith: { first, _ in first })
        albumsByID = Dictionary(albumPool.map { ($0.albumID, $0) }, uniquingKeysWith: { first, _ in first })
        entries = AIRecommendationFeedComposer.compose(
            unit: unit,
            intelligentAlbumKeys: feed.intelligentAlbumKeys(key: key, isAvailable: isAvailable),
            localAlbumKeys: albumPool.map(\.albumID),
            songIDs: songs.map(\.song.id)
        )
    }

    /// 点歌曲时的队列:这一排里的歌,按显示的顺序。
    var playableSongs: [Song] { songs.map(\.song).filteredPlayable() }
}

/// 首页「为你推荐」区块(iPhone / iPad)。本地每日推荐是底;按「推荐单位」开头放整张专辑卡
/// (混合:两张),智能推荐可用时由它重排、挑专辑,标题旁标「智能」,卡片上写它给的理由。
/// 下方在条件合适时放一次开启智能推荐的指引卡。
struct HomeForYouSection: View {
    let results: [MusicDiscoveryResult]
    let style: HomeSectionLayoutStyle
    let listLimit: Int
    let usesPadMetrics: Bool
    let editorMode: Bool
    let cardSurface: Color

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(MusicIntelligenceService.self) private var intelligence
    @AppStorage(AIRecommendationUnit.storageKey)
    private var unitRawValue = AIRecommendationUnit.defaultUnit.rawValue
    @AppStorage(AlbumRecommendationService.homeVisibilityKey) private var showsAlbumPick = true
    @State private var openedAlbum: Album?

    private var feed: HomeForYouAIFeed { .shared }

    var body: some View {
        let unit = AIRecommendationUnit.stored(unitRawValue)
        let presentation = HomeForYouPresentation(
            results: results,
            unit: unit,
            excludesCurrentAlbumPick: showsAlbumPick,
            library: library,
            intelligence: intelligence,
            feed: feed
        )
        VStack(alignment: .leading, spacing: 10) {
            header(isIntelligent: presentation.isIntelligent)
                .padding(.horizontal, 20)

            if style == .list {
                VStack(spacing: 8) {
                    ForEach(presentation.entries.prefix(listLimit)) { entry in
                        listEntry(entry, presentation)
                    }
                }
                .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(presentation.entries) { entry in
                            cardEntry(entry, presentation)
                        }
                    }
                    .padding(.horizontal, 20)
                    .scrollTargetLayout()
                }
                .pmStopsAtVerticalBar()
                .scrollTargetBehavior(.viewAligned)
            }

            if !editorMode {
                HomeIntelligenceHintCard(surface: cardSurface)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        }
        .pmAnimation(.contentAppear, value: presentation.isIntelligent)
        .navigationDestination(item: $openedAlbum) { album in
            AlbumDetailView(album: album)
        }
        .task(id: AlbumPoolRefreshKey(includesAlbums: unit.includesAlbums, libraryRevision: library.searchRevision)) {
            // 情景推荐那一块关着时没人替这里算专辑候选;算过的五分钟内直接复用。
            if unit.includesAlbums { AlbumRecommendationService.shared.refresh(library: library) }
        }
        .task(id: presentation.key) {
            guard !editorMode, presentation.isReadyToAsk else { return }
            await feed.refresh(
                key: presentation.key,
                candidates: results.map(\.song),
                unit: unit,
                albumCandidates: presentation.albumCandidates,
                intelligence: intelligence
            )
        }
    }

    private func header(isIntelligent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("home_for_you_title")
                .font(.title3)
                .fontWeight(.bold)
            if isIntelligent {
                HomeIntelligenceBadge()
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("home.forYou.title")
    }

    // MARK: Entries

    @ViewBuilder
    private func cardEntry(_ entry: AIRecommendationFeedEntry, _ presentation: HomeForYouPresentation) -> some View {
        switch entry {
        case .song(let songID):
            if let result = presentation.songsByID[songID] {
                Button { play(result.song, in: presentation) } label: {
                    songCard(result, reason: feed.reason(
                        for: songID, key: presentation.key, isAvailable: presentation.isAvailable
                    ))
                }
                .buttonStyle(.pmPressable)
            }
        case .album(let albumKey):
            if let pick = presentation.albumsByID[albumKey],
               let album = library.visibleAlbum(id: albumKey) {
                Button { playAlbum(albumKey) } label: {
                    albumCard(pick, album: album, reason: albumReason(pick, presentation))
                }
                .buttonStyle(.pmPressable)
                .contextMenu { albumMenu(pick, album: album) }
                .accessibilityIdentifier("home.forYou.album")
            }
        }
    }

    @ViewBuilder
    private func listEntry(_ entry: AIRecommendationFeedEntry, _ presentation: HomeForYouPresentation) -> some View {
        switch entry {
        case .song(let songID):
            if let result = presentation.songsByID[songID] {
                Button { play(result.song, in: presentation) } label: {
                    listRow(result, reason: feed.reason(
                        for: songID, key: presentation.key, isAvailable: presentation.isAvailable
                    ))
                }
                .buttonStyle(.pmPressable)
            }
        case .album(let albumKey):
            if let pick = presentation.albumsByID[albumKey],
               let album = library.visibleAlbum(id: albumKey) {
                Button { playAlbum(albumKey) } label: {
                    albumListRow(pick, album: album, reason: albumReason(pick, presentation))
                }
                .buttonStyle(.pmPressable)
                .contextMenu { albumMenu(pick, album: album) }
            }
        }
    }

    /// 智能服务挑的写它的理由;本地补上的写本地推荐的理由。
    private func albumReason(
        _ pick: AlbumRecommendation,
        _ presentation: HomeForYouPresentation
    ) -> (text: String, isIntelligent: Bool) {
        if let reason = feed.albumReason(
            for: pick.albumID, key: presentation.key, isAvailable: presentation.isAvailable
        ), !reason.isEmpty {
            return (reason, true)
        }
        return (pick.reason.text, false)
    }

    // MARK: Song cards

    private func songCard(_ result: MusicDiscoveryResult, reason: String?) -> some View {
        let song = result.song
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                reasonLine(result, reason: reason, lineLimit: 2)

                Text(song.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Label("play", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: artworkSide,
                cornerRadius: 13,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
        }
        .padding(14)
        .frame(width: cardWidth, height: cardHeight)
        .background(cardBackground(forSongID: song.id))
    }

    /// 列表档只保留一条推荐理由 —— 竖排里理由一多就把标题挤成两行,
    /// 反而不如横排卡片好读。
    private func listRow(_ result: MusicDiscoveryResult, reason: String?) -> some View {
        let song = result.song
        return HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 54,
                cornerRadius: 9,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 3) {
                reasonLine(result, reason: reason, lineLimit: 1)
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardSurface)
        }
        .contentShape(Rectangle())
    }

    /// 智能服务写的理由优先;没有时是本地推荐自己的理由标签。
    @ViewBuilder
    private func reasonLine(_ result: MusicDiscoveryResult, reason: String?, lineLimit: Int) -> some View {
        if let reason, !reason.isEmpty {
            intelligentReason(reason, lineLimit: lineLimit)
        } else {
            DiscoveryReasonsView(reasons: result.reasons, maxCount: 1)
        }
    }

    private func intelligentReason(_ reason: String, lineLimit: Int) -> some View {
        Label {
            Text(verbatim: reason)
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tint)
        .lineLimit(lineLimit)
    }

    // MARK: Album cards

    /// 整张专辑卡:和歌曲卡同样大小,封面右下角压一个「整张」的叠层记号;点一下按原曲序整张播放。
    private func albumCard(
        _ pick: AlbumRecommendation,
        album: Album,
        reason: (text: String, isIntelligent: Bool)
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                albumReasonLine(reason, lineLimit: 2)

                Text(pick.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(albumSubtitle(pick))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Label("album_pick_play", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AlbumArtworkView(album: album, size: artworkSide, cornerRadius: 13)
                .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "square.stack.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                        .accessibilityHidden(true)
                }
        }
        .padding(14)
        .frame(width: cardWidth, height: cardHeight)
        .background(cardBackground(forSongID: pick.artworkSongID ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("album_pick_play"))
    }

    private func albumListRow(
        _ pick: AlbumRecommendation,
        album: Album,
        reason: (text: String, isIntelligent: Bool)
    ) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(album: album, size: 54, cornerRadius: 9)

            VStack(alignment: .leading, spacing: 3) {
                albumReasonLine(reason, lineLimit: 1)
                Text(pick.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(albumSubtitle(pick))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardSurface)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func albumReasonLine(_ reason: (text: String, isIntelligent: Bool), lineLimit: Int) -> some View {
        if reason.isIntelligent {
            intelligentReason(reason.text, lineLimit: lineLimit)
        } else {
            Label {
                Text(verbatim: reason.text)
            } icon: {
                Image(systemName: "square.stack")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
        }
    }

    /// 「艺人 · 12 首」
    private func albumSubtitle(_ pick: AlbumRecommendation) -> String {
        let tracks = String(format: String(localized: "album_pick_tracks %lld"), pick.trackCount)
        return pick.artistName.isEmpty ? tracks : "\(pick.artistName) · \(tracks)"
    }

    @ViewBuilder
    private func albumMenu(_ pick: AlbumRecommendation, album: Album) -> some View {
        Button {
            playAlbum(pick.albumID)
        } label: {
            Label("album_pick_play", systemImage: "play.fill")
        }
        Button {
            player.insertNextInQueue(albumSongs(pick.albumID))
        } label: {
            Label("album_pick_play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            player.appendToQueue(albumSongs(pick.albumID))
        } label: {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button {
            openedAlbum = album
        } label: {
            Label("go_to_album", systemImage: "square.stack")
        }
        Divider()
        Button(role: .destructive) {
            pmWithAnimation(.contentAppear) {
                AlbumRecommendationService.shared.dismiss(albumID: pick.albumID)
            }
        } label: {
            Label("album_pick_dismiss", systemImage: "hand.thumbsdown")
        }
    }

    // MARK: Layout & playback

    private var cardWidth: CGFloat { usesPadMetrics ? 372 : 316 }
    private var cardHeight: CGFloat { usesPadMetrics ? 176 : 164 }
    private var artworkSide: CGFloat { usesPadMetrics ? 136 : 124 }

    @ViewBuilder
    private func cardBackground(forSongID songID: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if let tint = tintProvider.tint(forSongID: songID) {
            shape.fill(
                LinearGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            // Repeated live Material blurs create off-screen render passes
            // while the horizontal row moves. A stable system surface keeps
            // the same card hierarchy until the batched tint result arrives.
            shape.fill(cardSurface)
        }
    }

    /// 点哪一首就从哪一首开始,把这一排的歌(按显示的顺序)排成队列。
    private func play(_ song: Song, in presentation: HomeForYouPresentation) {
        let queue = presentation.playableSongs
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        SiriMediaInteractionDonor.donate(song: queue[index])
        Task { await player.play(queue: queue, startingAt: index) }
    }

    /// 整张播放:按碟号、轨号(CUE 分轨按 CUE 里的轨号)的原曲序排队,随机先关掉。
    private func playAlbum(_ albumID: String) {
        let songs = albumSongs(albumID)
        guard !songs.isEmpty else { return }
        player.shuffleEnabled = false
        Task { await player.play(queue: songs, startingAt: 0) }
    }

    private func albumSongs(_ albumID: String) -> [Song] {
        AlbumRecommendationService.shared.songsInTrackOrder(albumID: albumID, library: library)
    }
}

/// 标题旁的「智能」小字:这一排此刻由智能服务排序。
struct HomeIntelligenceBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .imageScale(.small)
            Text("home_for_you_ai_badge")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .accessibilityIdentifier("home.forYou.aiBadge")
    }
}

/// 「为你推荐」下方开启智能推荐的指引卡。只出现一次:开启、关掉或去了解更多之后都不再出现;
/// 服务商、模型这些设置不放在首页,「了解更多」直接去「设置 › 智能功能」。
struct HomeIntelligenceHintCard: View {
    let surface: Color

    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(MusicLibrary.self) private var library
    @AppStorage(AIHomeHintPolicy.dismissedKey) private var dismissed = false

    private var isVisible: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_FORCE_AI_HINT"] == "1", !dismissed {
            return true
        }
        #endif
        return AIHomeHintPolicy.shouldShow(
            dismissed: dismissed,
            exposesRemoteConfiguration: intelligence.shouldExposeRemoteConfiguration,
            relaySupportedOnDevice: PrimuseAIRelayClient.isSupportedOnCurrentDevice,
            relayEnabled: intelligence.settingsStore.primuseRelayEnabled,
            recommendationsAvailable: intelligence.isPersonalizedRecommendationsConfigured,
            musicSongCount: library.musicSongs.count
        )
    }

    var body: some View {
        if isVisible {
            card
                .transition(.opacity)
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("ai_home_hint_title")
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("ai_home_hint_detail")
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(action: enable) {
                        Text("ai_home_hint_enable")
                            .font(buttonFont)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("home.aiHint.enable")

                    Button(action: learnMore) {
                        Text("ai_home_hint_learn_more")
                            .font(buttonFont)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityIdentifier("home.aiHint.learnMore")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.snappy(duration: 0.25)) { dismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ai_home_hint_dismiss"))
            .accessibilityIdentifier("home.aiHint.dismiss")
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.aiHint")
    }

    /// 打开内置 AI、语义搜索、场景推荐和它们需要的授权;存不进去就带去设置页。
    private func enable() {
        do {
            try intelligence.enableBuiltInIntelligence()
        } catch {
            SettingsNavigation.shared.open("intelligence.relay")
        }
        withAnimation(.snappy(duration: 0.25)) { dismissed = true }
    }

    private func learnMore() {
        dismissed = true
        SettingsNavigation.shared.open("intelligence.relay")
    }

    #if os(macOS)
    private var titleFont: Font { .system(size: 13, weight: .semibold) }
    private var detailFont: Font { .system(size: 11.5) }
    private var buttonFont: Font { .system(size: 12, weight: .semibold) }
    #else
    private var titleFont: Font { .subheadline.weight(.semibold) }
    private var detailFont: Font { .caption }
    private var buttonFont: Font { .subheadline.weight(.semibold) }
    #endif
}

#if os(macOS)
/// Mac 首页的「为你推荐」:与 iPhone 首页同一份本地候选、同一份推荐单位与智能重排。
struct MacHomeForYouSection: View {
    let results: [MusicDiscoveryResult]

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicIntelligenceService.self) private var intelligence
    @AppStorage(AIRecommendationUnit.storageKey)
    private var unitRawValue = AIRecommendationUnit.defaultUnit.rawValue
    @AppStorage(AlbumRecommendationService.homeVisibilityKey) private var showsAlbumPick = true

    private var feed: HomeForYouAIFeed { .shared }

    var body: some View {
        let unit = AIRecommendationUnit.stored(unitRawValue)
        let presentation = HomeForYouPresentation(
            results: results,
            unit: unit,
            excludesCurrentAlbumPick: showsAlbumPick,
            library: library,
            intelligence: intelligence,
            feed: feed
        )
        VStack(alignment: .leading, spacing: PMSpace.m) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ai_recommendation_home_title")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(PMColor.text)
                if presentation.isIntelligent {
                    HomeIntelligenceBadge()
                        .transition(.opacity)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(presentation.entries) { entry in
                        entryCard(entry, presentation)
                    }
                }
                .padding(.vertical, 2)
            }

            HomeIntelligenceHintCard(surface: PMColor.bgElev)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .pmAnimation(.contentAppear, value: presentation.isIntelligent)
        .task(id: AlbumPoolRefreshKey(includesAlbums: unit.includesAlbums, libraryRevision: library.searchRevision)) {
            if unit.includesAlbums { AlbumRecommendationService.shared.refresh(library: library) }
        }
        .task(id: presentation.key) {
            guard presentation.isReadyToAsk else { return }
            await feed.refresh(
                key: presentation.key,
                candidates: results.map(\.song),
                unit: unit,
                albumCandidates: presentation.albumCandidates,
                intelligence: intelligence
            )
        }
    }

    @ViewBuilder
    private func entryCard(_ entry: AIRecommendationFeedEntry, _ presentation: HomeForYouPresentation) -> some View {
        switch entry {
        case .song(let songID):
            if let result = presentation.songsByID[songID] {
                Button { play(result.song, in: presentation) } label: {
                    songCard(result, reason: feed.reason(
                        for: songID, key: presentation.key, isAvailable: presentation.isAvailable
                    ))
                }
                .buttonStyle(.plain)
            }
        case .album(let albumKey):
            if let pick = presentation.albumsByID[albumKey],
               let album = library.visibleAlbum(id: albumKey) {
                albumCard(pick, album: album, presentation: presentation)
            }
        }
    }

    private func songCard(_ result: MusicDiscoveryResult, reason: String?) -> some View {
        let song = result.song
        return HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 78,
                cornerRadius: PMRadius.m,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            VStack(alignment: .leading, spacing: 4) {
                if let reason, !reason.isEmpty {
                    intelligentReason(reason)
                } else {
                    Text(String(localized: String.LocalizationValue(result.primaryReason.localizationKey)))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                }
                Text(song.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Label("play", systemImage: "play.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 292, height: 100)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    /// 整张专辑卡:封面进专辑页,卡片本身按原曲序整张播放。
    private func albumCard(
        _ pick: AlbumRecommendation,
        album: Album,
        presentation: HomeForYouPresentation
    ) -> some View {
        let aiReason = feed.albumReason(
            for: pick.albumID, key: presentation.key, isAvailable: presentation.isAvailable
        )
        return HStack(spacing: 12) {
            NavigationLink(value: album) {
                AlbumArtworkView(album: album, size: 78, cornerRadius: PMRadius.m)
            }
            .buttonStyle(.plain)
            .help(Text("go_to_album"))

            Button { playAlbum(pick.albumID) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let aiReason, !aiReason.isEmpty {
                        intelligentReason(aiReason)
                    } else {
                        Label {
                            Text(verbatim: pick.reason.text)
                        } icon: {
                            Image(systemName: "square.stack")
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                    }
                    Text(verbatim: pick.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(verbatim: albumSubtitle(pick))
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Label("album_pick_play", systemImage: "play.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 292, height: 100)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .contextMenu {
            Button { playAlbum(pick.albumID) } label: {
                Label("album_pick_play", systemImage: "play.fill")
            }
            Button {
                player.insertNextInQueue(albumSongs(pick.albumID))
            } label: {
                Label("album_pick_play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                player.appendToQueue(albumSongs(pick.albumID))
            } label: {
                Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Divider()
            Button {
                pmWithAnimation(.contentAppear) {
                    AlbumRecommendationService.shared.dismiss(albumID: pick.albumID)
                }
            } label: {
                Label("album_pick_dismiss", systemImage: "hand.thumbsdown")
            }
        }
        .accessibilityIdentifier("macHome.forYou.album")
    }

    private func intelligentReason(_ reason: String) -> some View {
        Label {
            Text(verbatim: reason)
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(PMColor.brand)
        .lineLimit(1)
    }

    private func albumSubtitle(_ pick: AlbumRecommendation) -> String {
        let tracks = String(format: String(localized: "album_pick_tracks %lld"), pick.trackCount)
        return pick.artistName.isEmpty ? tracks : "\(pick.artistName) · \(tracks)"
    }

    /// 点哪一首就从哪一首开始,把这一排的歌(按显示的顺序)排成队列。
    private func play(_ song: Song, in presentation: HomeForYouPresentation) {
        let queue = presentation.playableSongs
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        SiriMediaInteractionDonor.donate(song: queue[index])
        Task { await player.play(queue: queue, startingAt: index) }
    }

    /// 整张播放:按碟号、轨号(CUE 分轨按 CUE 里的轨号)的原曲序排队,随机先关掉。
    private func playAlbum(_ albumID: String) {
        let songs = albumSongs(albumID)
        guard !songs.isEmpty else { return }
        player.shuffleEnabled = false
        Task { await player.play(queue: songs, startingAt: 0) }
    }

    private func albumSongs(_ albumID: String) -> [Song] {
        AlbumRecommendationService.shared.songsInTrackOrder(albumID: albumID, library: library)
    }
}
#endif
