#if os(tvOS)
import PrimuseKit
import SwiftUI

// MARK: - 「播客」页

/// 在 Apple TV 上点开一档节目的来源:已订阅的(按 id),或者从热门榜、搜索里点进来、还没订的。
enum TVPodcastShowSource: Hashable {
    case show(String)
    case directory(PodcastDirectoryShow)
}

/// 「播客」页上整页弹出的两种页面。
enum TVPodcastPresentation: Identifiable, Hashable {
    case show(TVPodcastShowSource)
    case discover

    var id: String {
        switch self {
        case .show(.show(let id)): "show:\(id)"
        case .show(.directory(let show)): "directory:\(show.id)"
        case .discover: "discover"
        }
    }
}

/// tvOS「播客」一级页。和手机同一套订阅(iCloud 同步过来)与收听进度:
/// 「继续收听」大卡 →「最新单集」一排 →「我的节目」封面网格。一档都没订时整页换成发现:
/// 搜索入口和热门榜。电视上只在线听,不下载。
struct TVPodcastsView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}
    /// 节目页、发现页这些整页弹层在不在:TVRoot 据此停掉播放快捷键、压住焦点换页。
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    @State private var presented: TVPodcastPresentation?
    @State private var opensPlayerAfterDismissal = false

    private var podcasts: PodcastStore { PodcastStore.shared }
    // 播客封面是方的:一行五张,和电台台标同一把尺子。
    private let gridMetrics = TVBrowseGridMetrics.radio

    var body: some View {
        GeometryReader { geo in
            let cell = gridMetrics.cellWidth(pageWidth: geo.size.width)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34) {
                    header
                    if !podcasts.isLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 420)
                    } else if podcasts.shows.isEmpty {
                        welcome(cell: cell)
                        regionHiddenNote
                    } else {
                        continueListening
                        latestEpisodes
                        showsSection(cell: cell)
                        regionHiddenNote
                    }
                }
                .padding(.horizontal, TVSpace.pageH - 14)
                .padding(.top, TVSpace.pageTop + 8)
                .padding(.bottom, TVSpace.pageBottom)
            }
            .focusSection()
        }
        .background(TVColor.bg)
        .fullScreenCover(item: $presented, onDismiss: finishDismissal) { presentation in
            Group {
                switch presentation {
                case .show(let source):
                    TVPodcastShowDetailView(source: source) { opensPlayerAfterDismissal = true }
                case .discover:
                    TVPodcastDiscoverView { opensPlayerAfterDismissal = true }
                }
            }
            .environment(store)
        }
        .onChange(of: presented != nil) { _, active in onModalActivityChanged(active) }
        .onDisappear {
            if presented != nil { onModalActivityChanged(false) }
        }
        .task {
            podcasts.loadIfNeeded()
            podcasts.refreshAllIfDue()
            #if DEBUG
            await TVPodcastDebug.prepare(
                podcasts,
                present: { presented = $0 },
                play: { play($0, continuing: $1) }
            )
            #endif
        }
        .accessibilityIdentifier("tv.podcasts.page")
    }

    /// 当前店面不显示的订阅(别的设备同步来的手填地址、换店面前订的)。说一句,免得以为同步丢了。
    @ViewBuilder
    private var regionHiddenNote: some View {
        let count = podcasts.regionHiddenShowCount
        if count > 0 {
            Text(String(format: String(localized: "podcast_region_hidden_note %lld"), count))
                .tvFont(.caption)
                .foregroundStyle(TVColor.textFaint)
                .padding(.horizontal, 14)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(String(localized: "listening_space_podcast"))
                .tvFont(.pageTitle)
                .foregroundStyle(TVColor.text)
            if !podcasts.shows.isEmpty {
                Text(verbatim: "\(podcasts.shows.count) " + String(localized: "podcast_shows_count"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
            }
            Spacer(minLength: 24)
            if !podcasts.refreshingShowIDs.isEmpty {
                Text(String(localized: "podcast_refreshing"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
            }
            if !podcasts.shows.isEmpty {
                TVPillButton(title: String(localized: "podcast_refresh_all"), systemImage: "arrow.clockwise") {
                    Task { await podcasts.refreshAll() }
                }
                .disabled(!podcasts.refreshingShowIDs.isEmpty)
            }
            TVPillButton(title: String(localized: "podcast_discover"), systemImage: "magnifyingglass", style: .solid) {
                presented = .discover
            }
        }
        .padding(.horizontal, 14)
        .focusSection()
    }

    // MARK: 一档都没订

    private func welcome(cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "podcast_welcome_title"))
                .tvFont(.sectionTitle)
                .foregroundStyle(TVColor.text)
            Text(String(localized: "podcast_welcome_message"))
                .tvFont(.body)
                .foregroundStyle(TVColor.textMuted)
                .frame(maxWidth: 1100, alignment: .leading)
            TVPodcastChartGrid(genreID: nil, cell: cell, metrics: gridMetrics) { show in
                presented = .show(.directory(show))
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
    }

    // MARK: 订阅了以后

    @ViewBuilder
    private var continueListening: some View {
        let items = podcasts.inProgressEpisodes(limit: 12)
        if !items.isEmpty {
            TVRow(label: String(localized: "podcast_continue_listening")) {
                ForEach(items, id: \.episode.id) { item in
                    TVPodcastContinueCard(episode: item.episode, show: item.show) {
                        play(item.episode, continuing: [])
                    }
                    .contextMenu { episodeMenu(item.episode, continuing: []) }
                }
            }
        }
    }

    @ViewBuilder
    private var latestEpisodes: some View {
        let latest = podcasts.latestEpisodes(limit: 20)
        if latest.isEmpty {
            Text(String(localized: "podcast_all_caught_up"))
                .tvFont(.body)
                .foregroundStyle(TVColor.textFaint)
                .padding(.horizontal, 14)
        } else {
            TVRow(label: String(localized: "podcast_latest_episodes")) {
                ForEach(Array(latest.enumerated()), id: \.element.id) { index, episode in
                    let continuing = Array(latest.dropFirst(index + 1))
                    TVPodcastEpisodeCard(episode: episode, show: podcasts.show(id: episode.showID)) {
                        play(episode, continuing: continuing)
                    }
                    .contextMenu { episodeMenu(episode, continuing: continuing) }
                }
            }
        }
    }

    private func showsSection(cell: CGFloat) -> some View {
        // 最近出了新单集的排前面。
        let shows = podcasts.shows.sorted {
            ($0.latestEpisodeAt ?? .distantPast) > ($1.latestEpisodeAt ?? .distantPast)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "podcast_my_shows"))
                .tvFont(.sectionTitle)
                .foregroundStyle(TVColor.text)
                .padding(.horizontal, 14)
            LazyVGrid(columns: gridMetrics.gridItems(cell: cell), alignment: .leading, spacing: gridMetrics.gap) {
                ForEach(shows) { show in
                    TVPodcastShowCard(show: show, width: cell) {
                        presented = .show(.show(show.id))
                    }
                    .contextMenu { showMenu(show) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 20)
        }
    }

    // MARK: 菜单与动作

    @ViewBuilder
    private func episodeMenu(_ episode: PodcastEpisode, continuing: [PodcastEpisode]) -> some View {
        Button { play(episode, continuing: continuing) } label: {
            Label(String(localized: "podcast_play"), systemImage: "play.fill")
        }
        let finished = podcasts.state(for: episode).isFinished
        Button { podcasts.setPlayed(!finished, episode: episode) } label: {
            Label(
                String(localized: finished ? "podcast_mark_unplayed" : "podcast_mark_played"),
                systemImage: finished ? "circle" : "checkmark.circle"
            )
        }
        Button { presented = .show(.show(episode.showID)) } label: {
            Label(String(localized: "podcast_go_to_show"), systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    @ViewBuilder
    private func showMenu(_ show: PodcastShow) -> some View {
        Button { Task { await podcasts.refresh(showID: show.id) } } label: {
            Label(String(localized: "refresh"), systemImage: "arrow.clockwise")
        }
        Button { podcasts.markAllPlayed(showID: show.id) } label: {
            Label(String(localized: "podcast_mark_all_played"), systemImage: "checkmark.circle")
        }
        Button(role: .destructive) { podcasts.unsubscribe(show.id) } label: {
            Label(String(localized: "podcast_unsubscribe"), systemImage: "minus.circle")
        }
    }

    private func play(_ episode: PodcastEpisode, continuing: [PodcastEpisode]) {
        store.playPodcast(episode, continuing: continuing)
        openPlayer()
    }

    private func finishDismissal() {
        onModalActivityChanged(false)
        if opensPlayerAfterDismissal {
            opensPlayerAfterDismissal = false
            openPlayer()
        }
    }
}

// MARK: - 封面与进度

/// 节目或单集的封面:单集没有自己的就用节目的。走封面管线(缩到显示尺寸、落盘缓存),
/// 不用 AsyncImage:不少节目的封面是 3000×3000,整张解码一排卡片就是上百兆。
/// 缓存键按图片地址算,同一张图(一档节目的各集常共用)只取一次。
struct TVPodcastArtwork: View {
    let url: URL?
    let side: CGFloat
    var radius: CGFloat = TVRadius.cover

    var body: some View {
        let reference = url?.absoluteString
        TVArtworkView(
            coverKey: "",
            artist: "",
            album: "",
            songID: reference.map { "podcast-art:" + PodcastIdentity.digest($0) } ?? "",
            coverRef: reference,
            tint: TVColor.podcastSpace,
            tint2: TVColor.bgDeep,
            glyph: "♪",
            size: side,
            radius: radius
        )
    }
}

struct TVPodcastProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(TVColor.divider)
                Capsule().fill(TVColor.podcastSpace)
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

@MainActor
private enum TVPodcastText {
    /// 「星期二 · 48 分钟」;听到一半的换成剩余时间,听完的说已播放。
    static func meta(_ episode: PodcastEpisode, state: PodcastEpisodeState) -> String {
        var parts: [String] = []
        if let date = PodcastFormat.date(episode.publishedAt) { parts.append(date) }
        if state.isFinished {
            parts.append(String(localized: "podcast_played"))
        } else if let position = state.position, let total = episode.duration, total > position, position > 0 {
            parts.append(PodcastFormat.remaining(total - position))
        } else if let duration = PodcastFormat.duration(episode.duration) {
            parts.append(duration)
        }
        return parts.joined(separator: " · ")
    }

    static func fraction(_ episode: PodcastEpisode, state: PodcastEpisodeState) -> Double? {
        guard !state.isFinished, let position = state.position, position > 0,
              let total = episode.duration, total > 0 else { return nil }
        return position / total
    }
}

// MARK: - 卡片

/// 「继续收听」的大卡:封面、节目名、这一集、剩余时长、进度和「继续」。
struct TVPodcastContinueCard: View {
    let episode: PodcastEpisode
    let show: PodcastShow
    var action: () -> Void

    var body: some View {
        let state = PodcastStore.shared.state(for: episode)
        TVFocusButton(radius: TVRadius.card, scale: 1.04, lift: 8, action: action) { focused in
            HStack(alignment: .center, spacing: 28) {
                TVPodcastArtwork(url: episode.artworkURL ?? show.artworkURL, side: 220)
                VStack(alignment: .leading, spacing: 10) {
                    Text(show.title).tvFont(.caption, weight: .semibold)
                        .foregroundStyle(TVColor.podcastSpace)
                        .lineLimit(1)
                    Text(episode.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    if let fraction = TVPodcastText.fraction(episode, state: state) {
                        TVPodcastProgressBar(fraction: fraction)
                    }
                    HStack(spacing: 16) {
                        Label(String(localized: "podcast_continue"), systemImage: "play.fill")
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(focused ? TVColor.onBrand : TVColor.podcastSpace)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(
                                focused ? AnyShapeStyle(TVColor.podcastSpace)
                                        : AnyShapeStyle(TVColor.podcastSpace.opacity(0.14)),
                                in: Capsule()
                            )
                        Text(TVPodcastText.meta(episode, state: state)).tvFont(.meta)
                            .foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                }
                .frame(width: 440, height: 220, alignment: .leading)
            }
            .padding(22)
            .background(focused ? TVColor.surfaceStrong : TVColor.card,
                        in: RoundedRectangle(cornerRadius: TVRadius.card, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「最新单集」里的一集:封面、节目名、标题、日期与时长。
struct TVPodcastEpisodeCard: View {
    let episode: PodcastEpisode
    let show: PodcastShow?
    var width: CGFloat = 280
    var action: () -> Void

    var body: some View {
        let state = PodcastStore.shared.state(for: episode)
        TVFocusButton(ring: false, action: action) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVPodcastArtwork(url: episode.artworkURL ?? show?.artworkURL, side: width)
                    .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = TVPodcastText.fraction(episode, state: state) {
                        TVPodcastProgressBar(fraction: fraction)
                            .padding(.bottom, 4)
                    }
                    if let show {
                        Text(show.title).tvFont(.meta, weight: .semibold)
                            .foregroundStyle(TVColor.podcastSpace)
                            .lineLimit(1)
                    }
                    Text(episode.title).tvFont(.rowTitle, weight: .semibold)
                        .foregroundStyle(state.isFinished ? TVColor.textFaint : TVColor.text)
                        .lineLimit(2, reservesSpace: true)
                    Text(TVPodcastText.meta(episode, state: state)).tvFont(.meta)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                .padding(.top, 14).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「我的节目」里的一档:封面、名字、新单集数或主播。
struct TVPodcastShowCard: View {
    let show: PodcastShow
    let width: CGFloat
    var action: () -> Void

    var body: some View {
        let newCount = PodcastStore.shared.newEpisodeCount(showID: show.id)
        TVFocusButton(ring: false, action: action) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVPodcastArtwork(url: show.artworkURL, side: width)
                    .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(show.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2, reservesSpace: true)
                    if newCount > 0 {
                        Text(String(format: String(localized: "podcast_new_episodes_count %lld"), newCount))
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(TVColor.podcastSpace)
                            .lineLimit(1)
                    } else {
                        Text(show.author ?? " ").tvFont(.caption)
                            .foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 14).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 目录(热门榜、搜索结果)里的一档节目;订过的标出来。
struct TVPodcastDirectoryCard: View {
    let show: PodcastDirectoryShow
    let width: CGFloat
    var rank: Int?
    var action: () -> Void

    var body: some View {
        let subscribed = PodcastStore.shared.subscribedShow(directoryID: show.id) != nil
        TVFocusButton(ring: false, action: action) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVPodcastArtwork(url: show.artworkURL, side: width)
                    .overlay(alignment: .topLeading) {
                        if let rank {
                            Text(verbatim: "\(rank)")
                                .tvFont(.caption, weight: .bold, design: .rounded)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(10)
                        }
                    }
                    .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(show.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2, reservesSpace: true)
                    if subscribed {
                        Label(String(localized: "podcast_subscribed"), systemImage: "checkmark")
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(TVColor.podcastSpace)
                            .lineLimit(1)
                    } else {
                        Text(show.author ?? " ").tvFont(.caption)
                            .foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 14).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 热门榜

/// Apple 播客目录的热门榜(按这台设备的店面地区)。`genreID` 为空是总榜。
struct TVPodcastChartGrid: View {
    let genreID: Int?
    let cell: CGFloat
    let metrics: TVBrowseGridMetrics
    var open: (PodcastDirectoryShow) -> Void

    @State private var shows: [PodcastDirectoryShow] = []
    @State private var failed = false
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && shows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if failed && shows.isEmpty {
                TVPillButton(title: String(localized: "podcast_retry"), systemImage: "arrow.clockwise") {
                    Task { await load() }
                }
                .padding(.vertical, 40)
            } else {
                LazyVGrid(columns: metrics.gridItems(cell: cell), alignment: .leading, spacing: metrics.gap) {
                    ForEach(Array(shows.enumerated()), id: \.element.id) { index, show in
                        TVPodcastDirectoryCard(show: show, width: cell, rank: index + 1) { open(show) }
                            .contextMenu { TVPodcastSubscribeMenu(show: show) }
                    }
                }
                .padding(.vertical, 20)
            }
        }
        // 店面取到(或换了)以后按新地区重取:别一直挂着按手机地区猜的那份榜单。
        .task(id: "\(genreID ?? 0)|\(PodcastAvailabilityService.shared.policy.directoryCountry)") { await load() }
    }

    private func load() async {
        isLoading = true
        failed = false
        defer { isLoading = false }
        do {
            let loaded = try await PodcastDirectoryService.shared.chart(genreID: genreID)
            guard !Task.isCancelled else { return }
            shows = loaded
        } catch {
            guard !Task.isCancelled else { return }
            plog("🎙️ TV podcast chart failed: \(error.localizedDescription)")
            failed = true
        }
    }
}

/// 目录卡片的长按菜单:不进节目页直接订。
struct TVPodcastSubscribeMenu: View {
    let show: PodcastDirectoryShow

    var body: some View {
        if PodcastStore.shared.subscribedShow(directoryID: show.id) == nil {
            Button {
                Task {
                    do {
                        _ = try await PodcastStore.shared.subscribe(directoryShow: show)
                    } catch {
                        plog("🎙️ TV podcast subscribe failed: \(error.localizedDescription)")
                    }
                }
            } label: {
                Label(String(localized: "podcast_subscribe"), systemImage: "plus")
            }
        }
    }
}

// MARK: - 发现

/// 发现:搜索框 + 分类胶囊 + 热门榜。点一档进节目页,能先听再订。
/// 电视上不提供手填 RSS 地址和 OPML(遥控器输入不现实;中国大陆店面本来也不给)。
struct TVPodcastDiscoverView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var openPlayer: () -> Void = {}

    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var results: [PodcastDirectoryShow] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var genreID: Int?
    @State private var presentedShow: PodcastDirectoryShow?
    @State private var opensPlayerAfterDismissal = false
    @FocusState private var fieldFocused: Bool

    private let gridMetrics = TVBrowseGridMetrics.radio

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.podcastSpace, tint2: TVColor.bgDeep, strength: 0.45)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            GeometryReader { geo in
                let cell = gridMetrics.cellWidth(pageWidth: geo.size.width)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(String(localized: "podcast_discover"))
                            .tvFont(.pageTitle)
                            .foregroundStyle(TVColor.text)
                            .padding(.horizontal, 14)
                        searchBar
                        if !submittedQuery.isEmpty {
                            searchResults(cell: cell)
                        } else {
                            genreChips
                            VStack(alignment: .leading, spacing: 4) {
                                Text(genreTitle)
                                    .tvFont(.sectionTitle)
                                    .foregroundStyle(TVColor.text)
                                TVPodcastChartGrid(genreID: genreID, cell: cell, metrics: gridMetrics) { show in
                                    presentedShow = show
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                    .padding(.horizontal, TVSpace.pageH - 14)
                    .padding(.top, TVSpace.pageTop + 24)
                    .padding(.bottom, TVSpace.pageBottom)
                }
                .focusSection()
            }
        }
        .fullScreenCover(item: $presentedShow, onDismiss: finishDismissal) { show in
            TVPodcastShowDetailView(source: .directory(show)) { opensPlayerAfterDismissal = true }
                .environment(store)
        }
        .onExitCommand {
            if !submittedQuery.isEmpty {
                clearSearch()
            } else {
                dismiss()
            }
        }
        .accessibilityIdentifier("tv.podcasts.discover")
    }

    private var genreTitle: String {
        genreID.map { String(localized: String.LocalizationValue(PodcastFormat.genreKey($0))) }
            ?? String(localized: "podcast_top_charts")
    }

    private var searchBar: some View {
        HStack(spacing: 18) {
            TVTextFieldBox {
                TextField("", text: $query)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .onSubmit(search)
                    .accessibilityLabel(Text(String(localized: "podcast_search_prompt")))
            }
            TVPillButton(title: String(localized: "podcast_search_prompt"), systemImage: "magnifyingglass", style: .solid, action: search)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !submittedQuery.isEmpty {
                TVPillButton(title: String(localized: "podcast_top_charts"), systemImage: "chart.bar.fill", action: clearSearch)
            }
        }
        .padding(.horizontal, 14)
        .focusSection()
    }

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                TVPillButton(title: String(localized: "podcast_top_charts"), systemImage: "chart.bar.fill", isSelected: genreID == nil) {
                    genreID = nil
                }
                ForEach(PodcastDirectory.genreIDs, id: \.self) { id in
                    TVPillButton(
                        title: String(localized: String.LocalizationValue(PodcastFormat.genreKey(id))),
                        systemImage: "number",
                        isSelected: genreID == id
                    ) {
                        genreID = id
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
        .focusSection()
    }

    @ViewBuilder
    private func searchResults(cell: CGFloat) -> some View {
        if isSearching && results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if searchFailed && results.isEmpty {
            TVEmptyState(
                icon: "exclamationmark.triangle",
                title: String(localized: "podcast_search_failed"),
                subtitle: "",
                actionTitle: String(localized: "podcast_retry"),
                actionIcon: "arrow.clockwise",
                action: search
            )
            .frame(maxWidth: .infinity, minHeight: 420)
        } else if results.isEmpty {
            TVEmptyState(icon: "magnifyingglass", title: String(localized: "podcast_no_matching_episodes"), subtitle: "")
                .frame(maxWidth: .infinity, minHeight: 420)
        } else {
            LazyVGrid(columns: gridMetrics.gridItems(cell: cell), alignment: .leading, spacing: gridMetrics.gap) {
                ForEach(results) { show in
                    TVPodcastDirectoryCard(show: show, width: cell) { presentedShow = show }
                        .contextMenu { TVPodcastSubscribeMenu(show: show) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 20)
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        submittedQuery = term
        isSearching = true
        searchFailed = false
        results = []
        Task {
            defer { if submittedQuery == term { isSearching = false } }
            do {
                let found = try await PodcastDirectoryService.shared.search(term)
                guard submittedQuery == term else { return }
                results = found
            } catch {
                guard submittedQuery == term else { return }
                plog("🎙️ TV podcast search failed: \(error.localizedDescription)")
                searchFailed = true
            }
        }
    }

    private func clearSearch() {
        submittedQuery = ""
        results = []
        searchFailed = false
        isSearching = false
    }

    private func finishDismissal() {
        guard opensPlayerAfterDismissal else { return }
        opensPlayerAfterDismissal = false
        openPlayer()
        dismiss()
    }
}

// MARK: - 节目页

/// 一档节目:左边封面、名字、简介和播放/订阅,右边单集列表。没订也能先进来听。
/// 点一集从这一集放起,之后按收听顺序接着放(连续播放开着时)。
struct TVPodcastShowDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: TVPodcastShowSource
    var openPlayer: () -> Void = {}

    @State private var showID: String?
    @State private var loadError: String?
    @State private var confirmsUnsubscribe = false
    @State private var isSubscribing = false

    private var podcasts: PodcastStore { PodcastStore.shared }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.podcastSpace, tint2: TVColor.bgDeep, strength: 0.55)
            TVColor.bg.opacity(0.34).ignoresSafeArea()
            if let showID, let show = podcasts.show(id: showID) {
                content(show)
            } else if let loadError {
                TVEmptyState(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "podcast_load_failed"),
                    subtitle: loadError,
                    actionTitle: String(localized: "podcast_retry"),
                    actionIcon: "arrow.clockwise"
                ) {
                    Task { await load() }
                }
                .tvPanel()
                .frame(maxWidth: 900)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .onExitCommand { dismiss() }
        .confirmationDialog(
            String(localized: "podcast_unsubscribe_confirm_title"),
            isPresented: $confirmsUnsubscribe,
            titleVisibility: .visible
        ) {
            Button(String(localized: "podcast_unsubscribe"), role: .destructive) {
                if let showID { podcasts.unsubscribe(showID) }
                dismiss()
            }
        } message: {
            Text(String(localized: "podcast_unsubscribe_confirm_message"))
        }
        .accessibilityIdentifier("tv.podcasts.show")
    }

    private func load() async {
        loadError = nil
        do {
            switch source {
            case .show(let id):
                podcasts.loadIfNeeded()
                showID = id
            case .directory(let directoryShow):
                if let subscribed = podcasts.subscribedShow(directoryID: directoryShow.id) {
                    showID = subscribed.id
                } else {
                    showID = try await podcasts.preview(directoryShow: directoryShow).id
                }
            }
        } catch PodcastNetwork.Failure.insecureHTTP(let endpoint) {
            let approved = await TVServerCertificateTrustStore.shared.requestInsecureHTTPTrust(
                endpoint: endpoint,
                purpose: .podcast
            )
            if approved {
                SSLTrustStore.shared.allowInsecureHTTP(domain: endpoint)
                await load()
            } else {
                loadError = PodcastNetwork.Failure.insecureHTTP(host: endpoint).localizedDescription
            }
        } catch is PodcastFeedError {
            loadError = String(localized: "podcast_error_not_a_feed")
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func content(_ show: PodcastShow) -> some View {
        let all = podcasts.episodes(forShowID: show.id)
        let ordered = PodcastEpisodeListPolicy.ordered(all, order: show.effectiveEpisodeOrder)
        return HStack(alignment: .top, spacing: 72) {
            header(show, episodes: all)
                .frame(width: 520, alignment: .leading)
                .focusSection()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    TVEyebrow(text: String(format: String(localized: "podcast_episode_count %lld"), all.count))
                        .padding(.bottom, 6)
                    if ordered.isEmpty {
                        Text(String(localized: "podcast_no_episodes"))
                            .tvFont(.body)
                            .foregroundStyle(TVColor.textFaint)
                    }
                    ForEach(ordered) { episode in
                        episodeRow(episode, show: show, all: all)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .focusSection()
        }
        .padding(.horizontal, 100)
        .padding(.vertical, 72)
    }

    private func header(_ show: PodcastShow, episodes: [PodcastEpisode]) -> some View {
        let subscribed = podcasts.isSubscribed(show.id)
        let target = PodcastEpisodeListPolicy.resumeTarget(in: episodes, isSerial: show.isSerial, state: podcasts.state(for:))
        return VStack(alignment: .leading, spacing: 20) {
            TVPodcastArtwork(url: show.artworkURL, side: 300)
            Text(show.title)
                .tvFont(.pageTitle)
                .foregroundStyle(TVColor.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let author = show.author, !author.isEmpty {
                Text(author).tvFont(.body).foregroundStyle(TVColor.podcastSpace).lineLimit(2)
            }
            if let meta = metaLine(show, count: episodes.count) {
                Text(meta).tvFont(.caption).foregroundStyle(TVColor.textFaint).lineLimit(2)
            }
            if let summary = PodcastShowNotes.plainSummary(show.summary, limit: 600) {
                Text(summary).tvFont(.caption).foregroundStyle(TVColor.textMuted).lineLimit(5)
            }
            HStack(spacing: 16) {
                if let target {
                    TVPillButton(title: playTitle(target, show: show), systemImage: "play.fill", style: .solid) {
                        play(target, all: episodes)
                    }
                }
                if subscribed {
                    TVPillButton(title: String(localized: "podcast_subscribed"), systemImage: "checkmark") {
                        confirmsUnsubscribe = true
                    }
                } else {
                    TVPillButton(title: String(localized: "podcast_subscribe"), systemImage: "plus", style: target == nil ? .solid : .glass) {
                        isSubscribing = true
                        if let adopted = podcasts.adopt(previewID: show.id) { showID = adopted.id }
                        isSubscribing = false
                    }
                    .disabled(isSubscribing)
                }
            }
            if let failure = podcasts.refreshFailures[show.id] {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
            }
            Spacer(minLength: 0)
        }
    }

    private func metaLine(_ show: PodcastShow, count: Int) -> String? {
        var parts: [String] = []
        if let category = show.categories.first { parts.append(PodcastFormat.category(category)) }
        if count > 0 { parts.append(String(format: String(localized: "podcast_episode_count %lld"), count)) }
        if let latest = PodcastFormat.date(show.latestEpisodeAt) {
            parts.append(String(format: String(localized: "podcast_updated_format"), latest))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func playTitle(_ target: PodcastEpisode, show: PodcastShow) -> String {
        if podcasts.state(for: target).isInProgress { return String(localized: "podcast_continue") }
        return String(localized: show.isSerial ? "podcast_play_from_start" : "podcast_play_latest")
    }

    private func episodeRow(_ episode: PodcastEpisode, show: PodcastShow, all: [PodcastEpisode]) -> some View {
        let state = podcasts.state(for: episode)
        let isCurrent = store.currentPodcastEpisodeID == episode.id
        return TVFocusButton(radius: 16, scale: 1.02, lift: 0, ring: false, action: { play(episode, all: all) }) { focused in
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        if let date = PodcastFormat.date(episode.publishedAt) {
                            Text(date).tvFont(.meta).foregroundStyle(TVColor.textFaint)
                        }
                        if let badge = badge(episode) {
                            Text(badge).tvFont(.meta, weight: .semibold)
                                .foregroundStyle(TVColor.podcastSpace)
                        }
                    }
                    Text(episode.title).tvFont(.rowTitle, weight: .semibold)
                        .foregroundStyle(state.isFinished && !isCurrent ? TVColor.textFaint : TVColor.text)
                        .lineLimit(2)
                    if let summary = episode.subtitle.flatMap({ PodcastShowNotes.plainSummary($0, limit: 160) })
                        ?? PodcastShowNotes.plainSummary(episode.showNotes, limit: 160) {
                        Text(summary).tvFont(.meta)
                            .foregroundStyle(TVColor.textMuted)
                            .lineLimit(1)
                    }
                    if let fraction = TVPodcastText.fraction(episode, state: state) {
                        TVPodcastProgressBar(fraction: fraction)
                            .frame(maxWidth: 360)
                    }
                }
                Spacer(minLength: 12)
                if isCurrent {
                    Image(systemName: store.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(TVColor.podcastSpace)
                } else if state.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(TVColor.podcastSpace)
                        .accessibilityLabel(Text(String(localized: "podcast_played")))
                }
                if let duration = durationText(episode, state: state) {
                    Text(duration)
                        .tvFont(.meta, design: .monospaced)
                        .foregroundStyle(TVColor.textFaint)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(minHeight: 96)
            .background(focused ? TVColor.surfaceStrong : TVColor.card,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button { play(episode, all: all) } label: {
                Label(String(localized: "podcast_play"), systemImage: "play.fill")
            }
            Button { podcasts.setPlayed(!state.isFinished, episode: episode) } label: {
                Label(
                    String(localized: state.isFinished ? "podcast_mark_unplayed" : "podcast_mark_played"),
                    systemImage: state.isFinished ? "circle" : "checkmark.circle"
                )
            }
            if podcasts.isSubscribed(show.id), !state.isFinished {
                Button { podcasts.markOlderPlayed(than: episode) } label: {
                    Label(String(localized: "podcast_mark_older_played"), systemImage: "checkmark.circle.badge.questionmark")
                }
            }
        }
    }

    /// 「预告」「番外」「第 2 季第 3 集」;集号跟发布顺序对不上的节目不显示集号。
    private func badge(_ episode: PodcastEpisode) -> String? {
        switch episode.kind {
        case .trailer: return String(localized: "podcast_kind_trailer")
        case .bonus: return String(localized: "podcast_kind_bonus")
        case .full:
            guard let number = episode.number, podcasts.showsEpisodeNumbers(forShowID: episode.showID) else { return nil }
            if let season = episode.season {
                return String(format: String(localized: "podcast_season_episode_format"), season, number)
            }
            return String(format: String(localized: "podcast_episode_number_format"), number)
        }
    }

    private func durationText(_ episode: PodcastEpisode, state: PodcastEpisodeState) -> String? {
        if let position = state.position, let total = episode.duration, total > position, position > 0, !state.isFinished {
            return PodcastFormat.remaining(total - position)
        }
        return PodcastFormat.duration(episode.duration)
    }

    private func play(_ episode: PodcastEpisode, all: [PodcastEpisode]) {
        let continuing = Array(
            PodcastEpisodeListPolicy.continuation(from: episode.id, in: all, state: podcasts.state(for:)).dropFirst()
        )
        store.playPodcast(episode, continuing: continuing)
        openPlayer()
        dismiss()
    }
}

// MARK: - 播放页右栏

/// 播客单集(没有章节时)播放页的右栏:节目说明,下面是接下来要放的几集,点一集从它放起。
struct TVPodcastNowPlayingColumn: View {
    @Environment(TVStore.self) private var store
    var onInteraction: () -> Void = {}

    var body: some View {
        let notes = store.currentPodcastEpisodeID
            .flatMap { PodcastStore.shared.episode(id: $0)?.episode }
            .flatMap { PodcastShowNotes.plainSummary($0.showNotes ?? $0.subtitle, limit: 1_600) }
        let upNext = Array(store.podcastUpNext.prefix(4))
        VStack(alignment: .leading, spacing: 18) {
            TVEyebrow(text: String(localized: "podcast_show_notes"))
            if let notes {
                Text(notes)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(upNext.isEmpty ? 18 : 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(String(localized: "podcast_no_episodes"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
            }
            if !upNext.isEmpty {
                TVEyebrow(text: String(localized: "up_next"))
                    .padding(.top, 12)
                ForEach(Array(upNext.enumerated()), id: \.element.id) { index, episode in
                    TVFocusButton(radius: 14, scale: 1.02, lift: 0, ring: false, action: {
                        onInteraction()
                        store.playPodcastUpNext(at: index)
                    }) { focused in
                        HStack(spacing: 18) {
                            TVPodcastArtwork(
                                url: episode.artworkURL ?? PodcastStore.shared.show(id: episode.showID)?.artworkURL,
                                side: 64,
                                radius: 8
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(episode.title).tvFont(.caption, weight: .semibold)
                                    .foregroundStyle(TVColor.text)
                                    .lineLimit(1)
                                Text(TVPodcastText.meta(episode, state: PodcastStore.shared.state(for: episode)))
                                    .tvFont(.meta)
                                    .foregroundStyle(TVColor.textFaint)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(focused ? TVColor.surfaceStrong : TVColor.card,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .focusSection()
    }
}

// MARK: - 取证钩子

#if DEBUG
/// `PRIMUSE_DEBUG_PODCAST_SEED=<feed 地址,逗号分隔>` 没订阅时先订上;
/// `PRIMUSE_DEBUG_PODCAST_PROGRESS=1` 给最新一集记一个听到一半的位置;
/// `TV_SCREEN=podcastShow|podcastDiscover|podcastPlay` 直接打开节目页 / 发现页 / 播放这一档最新的一集,
/// `PRIMUSE_DEBUG_PODCAST_SHOW=<节目名的一段>` 选哪一档。
@MainActor
enum TVPodcastDebug {
    private static var prepared = false

    static func prepare(
        _ podcasts: PodcastStore,
        present: (TVPodcastPresentation) -> Void,
        play: (PodcastEpisode, [PodcastEpisode]) -> Void
    ) async {
        guard !prepared else { return }
        prepared = true
        let env = ProcessInfo.processInfo.environment
        for _ in 0..<100 where !podcasts.isLoaded {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let feeds = (env["PRIMUSE_DEBUG_PODCAST_SEED"] ?? "")
            .split(separator: ",")
            .compactMap { PodcastFeedURL.normalized(String($0)) }
        for url in feeds where podcasts.isSubscribed(feedURL: url) == nil {
            do {
                let show = try await podcasts.subscribe(feedURL: url)
                plog("🧪 TV debug: subscribed podcast '\(show.title)'")
            } catch {
                plog("🧪 TV debug: podcast seed failed \(url.host ?? "?"): \(error.localizedDescription)")
            }
        }
        if env["PRIMUSE_DEBUG_PODCAST_PROGRESS"] == "1",
           let episode = podcasts.latestEpisodes(limit: 1).first {
            let duration = episode.duration ?? 3_600
            SpokenWordStore.shared.rememberPosition(duration * 0.35, duration: duration, forSongID: episode.id)
        }
        plog("🧪 TV debug: podcast seed done shows=\(podcasts.shows.count)")
        switch TVDebugLaunch.screen {
        case "podcastShow":
            let needle = env["PRIMUSE_DEBUG_PODCAST_SHOW"] ?? ""
            let show = podcasts.shows.first { !needle.isEmpty && $0.title.localizedCaseInsensitiveContains(needle) }
                ?? podcasts.shows.first
            if let show { present(.show(.show(show.id))) }
        case "podcastDiscover":
            present(.discover)
        case "podcastPlay":
            let needle = env["PRIMUSE_DEBUG_PODCAST_SHOW"] ?? ""
            let show = podcasts.shows.first { !needle.isEmpty && $0.title.localizedCaseInsensitiveContains(needle) }
            let episodes = show.map { podcasts.episodes(forShowID: $0.id) }
                ?? podcasts.latestEpisodes(limit: 6, includeFinished: true)
            if let episode = episodes.first {
                play(episode, Array(episodes.dropFirst().prefix(5)))
            }
        default:
            break
        }
    }
}
#endif
#endif
