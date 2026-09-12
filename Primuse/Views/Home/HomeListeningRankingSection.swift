import SwiftUI
import PrimuseKit

struct HomeListeningRankingSection: View {
    @Environment(HomeDiscoveryModel.self) private var model
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(LibraryReviewPreferences.enabledKey) private var reviewsEnabled = false
    @State private var period: HomeListeningPeriod = .week
    @State private var category: HomeListeningCategory = .songs
    @State private var ranks: [HomeListeningRank] = []
    @State private var isLoading = true
    @State private var showsExpandedRanking = false
    @State private var preparedRequest: Request?

    private struct Request: Equatable {
        let revision: Int
        let period: HomeListeningPeriod
        let category: HomeListeningCategory
        let calendar: Calendar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    heading
                    Spacer(minLength: 12)
                    periodPicker.frame(width: 190)
                }
                VStack(alignment: .leading, spacing: 10) { heading; periodPicker }
            }

            categoryPicker

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .background(rowSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if !ranks.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(visibleRanks.enumerated()), id: \.element.id) { position, rank in
                        rankRow(rank, position: position)
                    }
                }

                if ranks.count > 5 {
                    Button {
                        withAnimation(.snappy) {
                            showsExpandedRanking.toggle()
                        }
                    } label: {
                        Label(
                            showsExpandedRanking
                                ? HomeDiscoveryText.string("collapse_ranking")
                                : HomeDiscoveryText.string("expand_top_20"),
                            systemImage: showsExpandedRanking ? "chevron.up" : "chevron.down"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("home.rankingExpand")
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.secondary)
                    Text(HomeDiscoveryText.string("empty_ranking")).font(.headline)
                    Text(HomeDiscoveryText.string("ranking_hint"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(rowSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Text(HomeDiscoveryText.string(category == .folders ? "folder_ranking_scope" : "ranking_scope"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .task(id: Request(revision: model.revision, period: period, category: category, calendar: ListeningCalendar.current)) {
            await refresh()
        }
        .onChange(of: period) { _, _ in showsExpandedRanking = false }
        .onChange(of: category) { _, _ in showsExpandedRanking = false }
    }

    private var visibleRanks: ArraySlice<HomeListeningRank> {
        ranks.prefix(showsExpandedRanking ? 20 : 5)
    }

    private var heading: some View {
        Text(HomeDiscoveryText.string("ranking"))
            .font(.title2.bold()).fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.listeningRanking")
    }

    private var periodPicker: some View {
        Picker("stats_range", selection: $period) {
            ForEach(HomeListeningPeriod.allCases, id: \.self) { period in
                Text(LocalizedStringKey("stats_range_" + period.rawValue)).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("home.rankingPeriod")
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeListeningCategory.allCases, id: \.self) { item in
                    Button { category = item } label: {
                        Text(categoryTitle(item))
                            .font(.caption.weight(category == item ? .semibold : .regular))
                            .padding(.horizontal, 12).frame(minHeight: 30)
                            .foregroundStyle(category == item ? Color.accentColor : Color.secondary)
                            .background(category == item ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(category == item ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                    .accessibilityIdentifier("home.rankingCategory." + item.rawValue)
                }
            }
        }
    }

    private func categoryTitle(_ category: HomeListeningCategory) -> String {
        category == .folders ? HomeDiscoveryText.string("folders")
            : NSLocalizedString("stats_rank_" + category.rawValue, comment: "")
    }

    private func rankRow(_ rank: HomeListeningRank, position: Int) -> some View {
        Group {
            if let folderID = rank.folderID {
                NavigationLink { HomeFolderBrowser(nodeID: folderID) } label: { rankLabel(rank, position: position) }
            } else if category == .songs {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        HomeDiscoveryPlayback.play(
                            ids: ranks.flatMap(\.songIDs), startingAt: rank.songIDs.first,
                            library: library, player: player
                        )
                    } label: { rankLabel(rank, position: position) }
                    .disabled(!canPlay(rank))

                    if reviewsEnabled, let song = firstSong(in: rank) {
                        HStack {
                            Spacer(minLength: 70)
                            compactRatingPicker(for: song)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 7)
                    }
                }
            } else {
                NavigationLink {
                    HomeRankedSongsView(title: rank.title, songIDs: rank.songIDs)
                } label: { rankLabel(rank, position: position) }
                .disabled(!canPlay(rank))
            }
        }
        .buttonStyle(.plain)
        .background(rowSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .contextMenu {
            Button("play", systemImage: "play.fill") { play(rank) }
                .disabled(!canPlay(rank))
        }
    }

    private func rankLabel(_ rank: HomeListeningRank, position: Int) -> some View {
        HStack(spacing: 11) {
            Text("\(position + 1)").font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(position == 0 ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            if let song = firstSong(in: rank) {
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id, size: 40, cornerRadius: 7,
                    sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat
                )
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(rankTitle(rank))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if !rank.subtitle.isEmpty {
                    Text(rank.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.09))
                    Capsule().fill(Color.accentColor.opacity(position == 0 ? 1 : 0.55))
                        .frame(width: geometry.size.width * CGFloat(rank.playCount) / CGFloat(max(1, ranks.first?.playCount ?? 1)))
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: "\(rank.playCount)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())

                Text(
                    Duration.seconds(rank.listenedSeconds).formatted(
                        .units(allowed: [.hours, .minutes], width: .abbreviated)
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(position + 1), \(rankTitle(rank)), \(String(format: HomeDiscoveryText.string("play_count"), rank.playCount))")
    }

    private func firstSong(in rank: HomeListeningRank) -> Song? {
        rank.songIDs.first.flatMap { model.songsByID[$0] }
    }

    private func compactRatingPicker(for song: Song) -> some View {
        LibraryReviewRatingPicker(
            rating: library.libraryReview(for: .song(song.id))?.rating,
            foregroundStyle: .yellow,
            symbolSize: 10,
            buttonSize: 18
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

    private var rowSurface: Color {
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
