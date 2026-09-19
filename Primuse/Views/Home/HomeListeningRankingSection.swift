import SwiftUI
import PrimuseKit

struct HomeListeningRankingSection: View {
    @Environment(HomeDiscoveryModel.self) private var model
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.pmHeightClass) private var heightClass
    @AppStorage(LibraryReviewPreferences.enabledKey) private var reviewsEnabled = false
    @State private var period: HomeListeningPeriod = .week
    @State private var category: HomeListeningCategory = .songs
    @State private var ranks: [HomeListeningRank] = []
    /// `ranks` 算的是哪一张榜。切换分类后新榜要等后台算完才到，这段时间屏幕上
    /// 还是旧榜 —— 封面形状、点了播什么都得跟着旧榜走，不能跟着刚选中的分类走。
    @State private var rankedCategory: HomeListeningCategory = .songs
    @State private var rankedPeriod: HomeListeningPeriod = .week
    @State private var isLoading = true
    @State private var showsExpandedRanking = false
    @AppStorage(HomeSectionLayoutConfiguration.storageKey) private var layoutRawValue = ""

    private var layout: HomeSectionLayoutConfiguration {
        HomeSectionLayoutConfiguration.decode(layoutRawValue)
    }

    /// 列表：展开后列到第几名，调到 5 及以下就不再提供展开（展开反而比收起还少，
    /// 那个按钮就没有意义了）。横排：货架铺到第几名。可在界面编辑里调整。
    private var expandedRankLimit: Int {
        layout.itemCount(for: .listeningRanking)
            ?? HomeSectionLayoutPolicy.defaultItemCount(for: .listeningRanking)
    }
    @State private var preparedRequest: Request?

    private struct Request: Equatable {
        let revision: Int
        let period: HomeListeningPeriod
        let category: HomeListeningCategory
        let calendar: Calendar
    }

    /// 横向放得下「领奖台在左、名次榜在右」：iPad，以及所有横屏的手机。
    private var usesSideBySideBoard: Bool {
        sizeClass == .regular || heightClass.isCompact
    }

    private var usesPadMetrics: Bool {
        sizeClass == .regular && !heightClass.isCompact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                heading
                Spacer(minLength: 8)
                periodMenu
            }
            .padding(.horizontal, 20)

            categoryPicker

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .background(cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 20)
                    // 骨架、榜单、空态共处一个 VStack,交叉淡入会让两块同时占位
                    // 把下面的说明文字顶开,所以走「旧的直接走、新的淡进来」。
                    .pmAppearFade(.contentAppear)
            } else if !ranks.isEmpty {
                Group {
                    if layout.style(for: .listeningRanking) == .carousel {
                        shelf
                    } else {
                        board.padding(.horizontal, 20)
                    }
                }
                .pmAppearFade(.contentAppear)
                // 换榜时整块重建：领奖台的入场只在新榜站上来时走一次，
                // 播放记录更新引起的原地刷新不重播。淡入挂在 id 里面才会跟着重播。
                .id(BoardIdentity(period: rankedPeriod, category: rankedCategory))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "trophy").font(.title2).foregroundStyle(.secondary)
                    Text(HomeDiscoveryText.string("empty_ranking")).font(.headline)
                    Text(HomeDiscoveryText.string("ranking_hint"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .pmAppearFade(.contentAppear)
            }

            Text(HomeDiscoveryText.string(category == .folders ? "folder_ranking_scope" : "ranking_scope"))
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
        }
        .task(id: Request(revision: model.revision, period: period, category: category, calendar: ListeningCalendar.current)) {
            await refresh()
        }
        .onChange(of: period) { _, _ in showsExpandedRanking = false }
        .onChange(of: category) { _, _ in showsExpandedRanking = false }
    }

    private struct BoardIdentity: Hashable {
        let period: HomeListeningPeriod
        let category: HomeListeningCategory
    }

    // MARK: - 顶栏

    private var heading: some View {
        Text(HomeDiscoveryText.string("ranking"))
            .font(.title3.bold()).fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.listeningRanking")
    }

    /// 时间范围收进标题右侧的一个小菜单。首页别的区块都没有分段控件，
    /// 这里横着摆一条会让这一块读起来像设置页。
    private var periodMenu: some View {
        Menu {
            Picker("stats_range", selection: $period) {
                ForEach(HomeListeningPeriod.allCases, id: \.self) { period in
                    Text(LocalizedStringKey("stats_range_" + period.rawValue)).tag(period)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey("stats_range_" + period.rawValue))
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(cardSurface, in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel(Text("stats_range"))
        .accessibilityValue(Text(LocalizedStringKey("stats_range_" + period.rawValue)))
        .accessibilityIdentifier("home.rankingPeriod")
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeListeningCategory.allCases, id: \.self) { item in
                    Button { category = item } label: {
                        // 选中与否字重不变：字重一变胶囊宽度跟着变，整排会抖一下。
                        Text(categoryTitle(item))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(minHeight: 32)
                            .foregroundStyle(category == item ? Color.accentColor : Color.secondary)
                            .background(
                                category == item ? Color.accentColor.opacity(0.15) : cardSurface,
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                    .accessibilityIdentifier("home.rankingCategory." + item.rawValue)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func categoryTitle(_ category: HomeListeningCategory) -> String {
        category == .folders ? HomeDiscoveryText.string("folders")
            : NSLocalizedString("stats_rank_" + category.rawValue, comment: "")
    }

    // MARK: - 列表：领奖台 + 名次榜

    private var visibleRanks: ArraySlice<HomeListeningRank> {
        ranks.prefix(
            HomeListeningRankBoardPolicy.visibleCount(
                total: ranks.count, expandedLimit: expandedRankLimit, isExpanded: showsExpandedRanking
            )
        )
    }

    private var offersExpansion: Bool {
        HomeListeningRankBoardPolicy.offersExpansion(total: ranks.count, expandedLimit: expandedRankLimit)
    }

    private var board: some View {
        let podiumCount = min(visibleRanks.count, HomeListeningRankBoardPolicy.podiumSize)
        let rows = Array(visibleRanks.enumerated().dropFirst(HomeListeningRankBoardPolicy.podiumSize))
        let showsCard = !rows.isEmpty || offersExpansion
        // 横竖屏之间只换排布、不换子树：名次行和领奖台上都挂着长按菜单，
        // 旋转时把菜单的宿主换掉是记录在案的崩溃形态。
        let arrangement = usesSideBySideBoard
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 14))
        return arrangement {
            ListeningRankPodium(count: podiumCount) { place in
                podiumColumn(ranks[place], place: place)
            }
            .frame(maxWidth: usesSideBySideBoard && showsCard ? 360 : .infinity)

            if showsCard {
                rankCard(rows)
            }
        }
    }

    private var podiumMetrics: ListeningRankPodiumMetrics {
        heightClass.isCompact ? .compactHeight : ListeningRankPodiumMetrics()
    }

    private func podiumColumn(_ rank: HomeListeningRank, place: Int) -> some View {
        ListeningRankPodiumColumn(place: place, tintSong: artworkSong(for: rank), metrics: podiumMetrics) {
            VStack(spacing: 4) {
                rankAction(rank) {
                    ListeningRankPodiumHeadline(
                        place: place, title: rankTitle(rank), subtitle: rank.subtitle,
                        playCount: rank.playCount, trend: rank.trend, metrics: podiumMetrics
                    ) { size in
                        rankArtwork(rank, size: size, cornerRadius: place == 0 ? 12 : 10)
                    }
                }
                .buttonStyle(.pmPressable)
                .contextMenu { rankMenu(rank) }

                if rankedCategory == .songs, reviewsEnabled, let song = artworkSong(for: rank) {
                    compactRatingPicker(for: song, symbolSize: 9, buttonSize: 17)
                }
            }
        }
    }

    private func rankCard(_ rows: [(offset: Int, element: HomeListeningRank)]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.element.id) { position, rank in
                if position != rows.first?.offset {
                    Divider().padding(.leading, 53)
                }
                rankRow(rank, position: position)
            }

            if offersExpansion {
                if !rows.isEmpty { Divider() }
                Button {
                    pmWithAnimation(.list) {
                        showsExpandedRanking.toggle()
                    }
                } label: {
                    Label(
                        showsExpandedRanking
                            ? HomeDiscoveryText.string("collapse_ranking")
                            : String(
                                format: HomeDiscoveryText.string("expand_top_n"),
                                expandedRankLimit
                            ),
                        systemImage: showsExpandedRanking ? "chevron.up" : "chevron.down"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.rankingExpand")
            }
        }
        .background(cardSurface)
        // 名次行的占比底色是直角的，靠卡片的圆角把四个角裁掉。
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func rankRow(_ rank: HomeListeningRank, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rankAction(rank) {
                ListeningRankRowLabel(
                    position: position, title: rankTitle(rank), subtitle: rank.subtitle,
                    playCount: rank.playCount, listenedSeconds: rank.listenedSeconds,
                    trend: rank.trend,
                    share: HomeListeningRankBoardPolicy.share(
                        playCount: rank.playCount, leaderPlayCount: ranks.first?.playCount ?? 0
                    )
                ) {
                    rankArtwork(rank, size: 42, cornerRadius: 8)
                }
            }
            .buttonStyle(.plain)

            if rankedCategory == .songs, reviewsEnabled, let song = artworkSong(for: rank) {
                HStack {
                    Spacer(minLength: 70)
                    compactRatingPicker(for: song)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }
        }
        .contextMenu { rankMenu(rank) }
    }

    // MARK: - 横排：大数字货架

    private var shelf: some View {
        let count = HomeListeningRankBoardPolicy.shelfCount(total: ranks.count, expandedLimit: expandedRankLimit)
        let artworkSize: CGFloat = usesPadMetrics ? 128 : heightClass.value(108, compact: 84)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(Array(ranks.prefix(count).enumerated()), id: \.element.id) { position, rank in
                    rankAction(rank) {
                        ListeningRankShelfCard(
                            position: position, title: rankTitle(rank), subtitle: rank.subtitle,
                            playCount: rank.playCount, trend: rank.trend, artworkSize: artworkSize
                        ) { size in
                            rankArtwork(rank, size: size, cornerRadius: 11)
                        }
                    }
                    .buttonStyle(.pmPressable)
                    .contextMenu { rankMenu(rank) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 共用

    /// 点一名上榜项目会发生什么：目录进目录，歌曲从这一首起播整张榜，
    /// 艺人和专辑进它们上榜的那些歌。
    @ViewBuilder
    private func rankAction<Content: View>(
        _ rank: HomeListeningRank, @ViewBuilder label: () -> Content
    ) -> some View {
        if let folderID = rank.folderID {
            NavigationLink { HomeFolderBrowser(nodeID: folderID) } label: { label() }
        } else if rankedCategory == .songs {
            Button {
                HomeDiscoveryPlayback.play(
                    ids: ranks.flatMap(\.songIDs), startingAt: rank.songIDs.first,
                    library: library, player: player
                )
            } label: { label() }
            .disabled(!canPlay(rank))
        } else {
            NavigationLink {
                HomeRankedSongsView(title: rank.title, songIDs: rank.songIDs)
            } label: { label() }
            .disabled(!canPlay(rank))
        }
    }

    @ViewBuilder
    private func rankMenu(_ rank: HomeListeningRank) -> some View {
        Button("play", systemImage: "play.fill") { play(rank) }
            .disabled(!canPlay(rank))
    }

    @ViewBuilder
    private func rankArtwork(_ rank: HomeListeningRank, size: CGFloat, cornerRadius: CGFloat) -> some View {
        if let folderID = rank.folderID, let node = model.index?.node(withID: folderID) {
            HomeFolderArtwork(node: node, size: size)
        } else {
            ListeningRankArtwork(
                song: artworkSong(for: rank), size: size,
                isArtist: rankedCategory == .artists, cornerRadius: cornerRadius
            )
        }
    }

    /// 这一名的门面：组里听得最多的那首；它已经不在库里时退到还在的第一首。
    private func artworkSong(for rank: HomeListeningRank) -> Song? {
        if let id = rank.artworkSongID, let song = model.songsByID[id] { return song }
        for id in rank.songIDs {
            if let song = model.songsByID[id] { return song }
        }
        return nil
    }

    private func compactRatingPicker(
        for song: Song, symbolSize: CGFloat = 10, buttonSize: CGFloat = 18
    ) -> some View {
        LibraryReviewRatingPicker(
            rating: library.libraryReview(for: .song(song.id))?.rating,
            foregroundStyle: .yellow,
            symbolSize: symbolSize,
            buttonSize: buttonSize
        ) { rating in
            let review = library.libraryReview(for: .song(song.id))
            library.updateLibraryReview(
                for: .song(song.id),
                rating: rating == review?.rating ? nil : rating,
                comment: review?.comment ?? ""
            )
        }
    }

    private func rankTitle(_ rank: HomeListeningRank) -> String {
        if let id = rank.folderID, let node = model.index?.node(withID: id) {
            return HomeDiscoveryText.folderTitle(node)
        }
        return rank.title
    }

    private func play(_ rank: HomeListeningRank) {
        let ids = rank.folderID.map { model.songs(in: $0).map(\.id) } ?? rank.songIDs
        HomeDiscoveryPlayback.play(ids: ids, library: library, player: player)
    }

    private func canPlay(_ rank: HomeListeningRank) -> Bool {
        !rank.songIDs.compactMap { library.unobservedVisibleSong(id: $0) }.filteredPlayable().isEmpty
    }

    private var cardSurface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func refresh() async {
        let request = Request(revision: model.revision, period: period, category: category, calendar: ListeningCalendar.current)
        // Lazy-stack reappearance must not collapse a loaded card to its
        // spinner height and repeatedly move it across the visible boundary.
        guard preparedRequest != request else { return }
        isLoading = ranks.isEmpty
        let events = PlayHistoryStore.shared.entries.map(\.listeningEvent)
        let songs = model.songsByID
        let folders = model.index
        let period = period
        let category = category
        let task = Task.detached(priority: .utility) {
            HomeListeningRanking.ranks(events: events, songs: songs, folders: folders, period: period, category: category, calendar: request.calendar)
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { return }
        ranks = result
        rankedCategory = category
        rankedPeriod = period
        isLoading = false
        preparedRequest = request
    }
}

private struct HomeRankedSongsView: View {
    let title: String
    let songIDs: [String]
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    #if os(iOS)
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    #endif

    private var legacyBottomClearance: CGFloat {
        #if os(iOS)
        appNavigationMode == .minimal
            ? 0
            : BottomChromeClearancePolicy.clearance(
                legacyOverlayActive: legacyBottomChromeOverlayActive,
                legacy: 90,
                baseline: 0
            )
        #else
        90
        #endif
    }

    var body: some View {
        List {
            ForEach(songIDs, id: \.self) { id in
                if let song = library.unobservedVisibleSong(id: id) {
                    SongRowView(song: song, isPlaying: player.currentSong?.id == id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            HomeDiscoveryPlayback.play(ids: songIDs, startingAt: id, library: library, player: player)
                        }
                }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .minimalNavigationDetail()
        #endif
        .safeAreaInset(edge: .bottom, spacing: legacyBottomClearance == 0 ? 0 : nil) {
            Color.clear.frame(height: legacyBottomClearance)
        }
    }
}
