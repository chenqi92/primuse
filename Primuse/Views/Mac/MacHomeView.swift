#if os(macOS)
import SwiftUI
import AppKit
import PrimuseKit

@MainActor
private final class MacHomeRefreshCoordinator {
    var debounceTask: Task<Void, Never>?
    /// 正在算的那一轮。算完才清空; 期间来的刷新请求不打断它, 等它放出结果后再补算。
    var computeTask: Task<Void, Never>?
    /// 上一次真正做完整库重算的时刻, 给资料库版本驱动的刷新做节流。
    var lastRefreshAt: Date?

    func cancelAll() {
        debounceTask?.cancel()
        computeTask?.cancel()
        debounceTask = nil
        computeTask = nil
    }
}

/// Keep the rapidly changing revision in a tiny observation scope. Attaching
/// the onChange directly to MacHomeView invalidated its entire dashboard tree
/// for every scan/backfill batch, even while the expensive snapshot itself was
/// debounced.
private struct MacHomeLibraryRevisionObserver: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(ScanService.self) private var scanService
    let onRevisionChange: () -> Void
    let onScanFinished: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: library.searchRevision) { _, _ in onRevisionChange() }
            // 歌单版本也在首页快照的签名里(推荐要用), 只听歌曲版本的话歌单一变签名就对不上, 却没人补算。
            .onChange(of: library.playlistCollectionRevision) { _, _ in onRevisionChange() }
            .onChange(of: scanService.scanningSourceIDs.isEmpty) { _, idle in
                if idle { onScanFinished() }
            }
    }
}

/// 1.6 重设计后的 macOS 首页 — Hero (AmbientBackdrop + 封面马赛克 + 欢迎语) →
/// 库健康度 / 源状态 双卡 → 4 节点 pipeline → 最近添加专辑 → 最近播放 → 艺术家。
struct MacHomeView: View {
    let model: Model
    let openLibrarySongs: () -> Void
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ThemeService.self) private var theme
    @Environment(AppUpdateChecker.self) private var updateChecker
    @Environment(RadioStationsStore.self) private var radioStationsStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("primuse.home.showRadio") private var showRadio = true
    @AppStorage("primuse.home.showRecentlyAdded") private var showRecentlyAdded = true
    @AppStorage("primuse.home.showPodcasts") private var showPodcasts = false
    @AppStorage(AlbumRecommendationService.homeVisibilityKey) private var showAlbumPick = true
    // 与 iPhone、iPad 首页同名的区块开关;资料库健康度、处理管线、书这三块只有 Mac 有自己的开关。
    // 主卡下面各块的先后在 设置 › 外观 › 首页 里拖动调整。
    @AppStorage(MacHomeSectionLayout.orderKey) private var sectionOrderRawValue = ""
    @AppStorage(MacHomeSectionLayout.showsOverviewKey) private var showOverview = true
    @AppStorage(MacHomeSectionLayout.showsPipelineKey) private var showPipeline = true
    @AppStorage(MacHomeSectionLayout.showsBooksKey) private var showBooks = true
    @AppStorage("primuse.home.showContinueSpaces") private var showContinueSpaces = true
    @AppStorage(ListeningIntentService.homeVisibilityKey) private var showStartListening = true
    /// 「开始听」的排布与张数,与 iPhone、iPad 首页编辑同一份配置,在 设置 › 外观 › 首页 里调。
    @AppStorage(HomeSectionLayoutConfiguration.storageKey) private var homeSectionLayoutRawValue = ""
    @AppStorage("primuse.home.showForYou") private var showForYou = true
    @AppStorage("primuse.home.showContinueListening") private var showContinueListening = true
    @AppStorage("primuse.home.showTopArtists") private var showTopArtists = true
    @State private var pendingInsecureStation: RadioStation?

    // 派生聚合缓存 —— mosaicSongs(全库 sort)、heroStats(全库 reduce)、三个 ratio
    // (各一次全库 filter) 都很重。首页同时观察 scanStates(每扫一个文件就变)和
    // backfill 计数, 扫描/回填期间这些属性高频变化, 每次 body 求值都把全库遍历
    // 在主线程重跑一遍 → 万首级曲库下首页卡顿。把结果缓存到 @State, 仅在库内容
    // (searchRevision)或播放历史变化时重算一次, 跟 iOS HomeView / MacSimilarSongsPopover
    // 一致。
    @State private var isHomeVisible = false
    /// 场景此刻在不在前台。刷新路径读这一份而不是 `scenePhase`: 异步任务里读到的
    /// `scenePhase` 是任务创建那一刻的值, 首页若在窗口进入前台之前出现, 首次加载会被跳过。
    @State private var isSceneActive = false
    @State private var activeSection: HomeSectionDestination?
    // 合并 searchRevision 风暴 —— MusicLibrary 在扫描的每个 upsert 批次都 bump
    // searchRevision, 不去抖会触发几十次全库重算。cancel + 重启计时, 只在最后
    // 一次 revision 落定后重算。
    @State private var refreshCoordinator = MacHomeRefreshCoordinator()

    @MainActor
    @Observable
    final class Model {
        fileprivate var snapshot = DerivedSnapshot()
        var isPrepared = false
        @ObservationIgnored var signature: DerivedSignature?
        @ObservationIgnored var recommendationSignature: DerivedSignature?

        func needsRefresh(for signature: DerivedSignature) -> Bool {
            !isPrepared || self.signature != signature || recommendationSignature != signature
        }
    }

    struct DerivedSignature: Equatable {
        let libraryRevision: Int
        let playlistRevision: Int
        let historyRevision: Int
        let recentSongIDs: [String]
        let day: Date
        let localeIdentifier: String

        /// 只是曲库或歌单内容变了 —— 这类补算在扫描期间可以放宽间隔。
        func differsOnlyInLibraryContent(from other: DerivedSignature) -> Bool {
            historyRevision == other.historyRevision
                && recentSongIDs == other.recentSongIDs
                && day == other.day
                && localeIdentifier == other.localeIdentifier
        }
    }

    fileprivate struct DerivedSnapshot: Sendable {
        var mosaicSongs: [Song] = []
        var recentSongs: [Song] = []
        var recommendationResults: [MusicDiscoveryResult] = []
        var recentlyAddedAlbums: [Album] = []
        var artists: [Artist] = []
        var albumArtworkSongs: [String: Song] = [:]
        var totalDurationSec: Double = 0
        var coverCount: Int = 0
        var lyricsCount: Int = 0
        var playableCount: Int = 0
        var songCount: Int = 0
        var albumCount: Int = 0
        var artistCount: Int = 0
    }

    private var hasContent: Bool { model.snapshot.songCount > 0 }

    private var homePresentationState: DeferredContentPresentationState {
        DeferredContentPresentationPolicy.resolve(
            isPrepared: model.isPrepared,
            hasContent: hasContent
        )
    }

    @ViewBuilder
    var body: some View {
        Group {
            if let activeSection {
                sectionDestination(activeSection)
            } else {
                dashboard
            }
        }
        .background(PMColor.bg.ignoresSafeArea())
        .background {
            MacHomeLibraryRevisionObserver(
                onRevisionChange: { scheduleDerivedRefresh(libraryDriven: true) },
                // 扫描期间排着的那次按扫描档在等; 扫完按正常档重排。
                onScanFinished: { scheduleDerivedRefresh() }
            )
        }
        .task {
            isHomeVisible = true
            await Task.yield()
            if model.isPrepared {
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled else { return }
            refreshDerivedIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in
            scheduleDerivedRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseListeningStatsDidChange)) { _ in
            scheduleDerivedRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            scheduleDerivedRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            scheduleDerivedRefresh()
        }
        .onAppear {
            isSceneActive = scenePhase == .active
        }
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = phase == .active
            if phase == .active {
                scheduleDerivedRefresh()
            } else {
                refreshCoordinator.cancelAll()
            }
        }
        .onDisappear {
            isHomeVisible = false
            refreshCoordinator.cancelAll()
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { pendingInsecureStation != nil },
            set: { if !$0 { pendingInsecureStation = nil } }
        )) {
            Button("cancel", role: .cancel) { pendingInsecureStation = nil }
            Button("insecure_http_continue", role: .destructive) {
                guard let station = pendingInsecureStation,
                      let url = station.url,
                      let trustTarget = TrustedHTTPTransport.trustTarget(for: url) else { return }
                SSLTrustStore.shared.allowInsecureHTTP(domain: trustTarget)
                pendingInsecureStation = nil
                performRadioToggle(station)
            }
        } message: {
            Text(String(
                format: String(localized: "insecure_http_warning_message %@"),
                pendingInsecureStation?.url.flatMap(TrustedHTTPTransport.trustTarget(for:)) ?? ""
            ))
        }
    }

    private var dashboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: PMSpace.xxl) {
                if updateChecker.availableUpdate != nil {
                    updateBanner
                }

                switch homePresentationState {
                case .loading:
                    homeLoadingSkeleton
                        .pmAppearFade(.contentAppear)
                case .content:
                    resolvedDashboardContent(hasContent: true)
                case .empty:
                    resolvedDashboardContent(hasContent: false)
                }
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.top, PMSpace.l24)
            .padding(.bottom, 104)
        }
    }

    /// Mac 首页宽:网格按宽度分列、张数凑满整行;横排只铺一行。
    private var startListeningArrangement: StartListeningShelf.Arrangement {
        let layout = HomeSectionLayoutConfiguration.decode(homeSectionLayoutRawValue)
        let limit = layout.itemCount(for: .startListening)
            ?? HomeSectionLayoutPolicy.defaultItemCount(for: .startListening)
        return layout.style(for: .startListening) == .carousel
            ? .carousel(rows: 1, limit: limit)
            : .grid(limit: limit)
    }

    @ViewBuilder
    private func resolvedDashboardContent(hasContent: Bool) -> some View {
        // 每个区块自己淡入: 骨架换内容、推荐/电台这些异步算完才出现的区块都只动透明度。
        // 成对分支不做交叉淡入 —— 过渡期间新旧两块会同时占着这个 VStack 的位置。
        heroOrAlbumPick
        if showRadio,
           player.isLiveRadio,
           let currentStation = player.currentRadioStation {
            radioNowPlayingStrip(currentStation)
                .pmAppearFade(.contentAppear)
        }
        if !hasContent {
            emptyState
                .pmAppearFade(.contentAppear)
        }
        ForEach(MacHomeSectionLayout.decodeOrder(sectionOrderRawValue)) { section in
            dashboardSection(section, hasContent: hasContent)
        }
    }

    /// 主卡下面的一块。曲库还空着时只画电台、书、播客这些不靠曲库的。
    @ViewBuilder
    private func dashboardSection(_ section: MacHomeSection, hasContent: Bool) -> some View {
        switch section {
        case .overview:
            if hasContent, showOverview {
                statsRow
                    .pmAppearFade(.contentAppear)
            }
        case .pipeline:
            if hasContent, showPipeline {
                pipelineSection
                    .pmAppearFade(.contentAppear)
            }
        case .startListening:
            if hasContent, showStartListening {
                StartListeningShelf(
                    arrangement: startListeningArrangement,
                    horizontalInset: 0,
                    onOpenAll: { openSection(.allIntents) },
                    onOpenSongs: { openSection(.intentSongs($0, fromAllIntents: false)) }
                )
                .pmAppearFade(.contentAppear)
            }
        case .forYou:
            if hasContent, showForYou, !model.snapshot.recommendationResults.isEmpty {
                recommendationSection
                    .pmAppearFade(.contentAppear)
            }
        case .recentlyAdded:
            if hasContent, showRecentlyAdded, !model.snapshot.recentlyAddedAlbums.isEmpty {
                recentlyAddedSection
                    .pmAppearFade(.contentAppear)
            }
        case .recentlyPlayed:
            if hasContent, showContinueListening {
                recentlyPlayedSection
                    .pmAppearFade(.contentAppear)
            }
        case .radio:
            if showRadio, !radioStationsStore.stations.isEmpty {
                radioSpotlightSection
                    .pmAppearFade(.contentAppear)
            }
        case .books:
            if showBooks {
                MacHomeBooksStrip()
            }
        case .podcasts:
            if showPodcasts {
                MacHomePodcastsStrip()
            }
        case .topArtists:
            if hasContent, showTopArtists, !model.snapshot.artists.isEmpty {
                artistsSection
                    .pmAppearFade(.contentAppear)
            }
        }
    }

    private var homeLoadingSkeleton: some View {
        LoadingSkeletonGroup {
            VStack(alignment: .leading, spacing: PMSpace.xxl) {
                ZStack {
                    RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                        .fill(PMColor.bgElev)

                    HStack(spacing: 36) {
                        homeSkeletonBlock(
                            width: 240,
                            height: 240,
                            cornerRadius: PMRadius.xl
                        )

                        VStack(alignment: .leading, spacing: 14) {
                            homeSkeletonBlock(width: 82, height: 12)
                            homeSkeletonBlock(height: 42, cornerRadius: PMRadius.m)
                                .frame(maxWidth: 510, alignment: .leading)
                            homeSkeletonBlock(height: 16)
                                .frame(maxWidth: 390, alignment: .leading)
                            HStack(spacing: PMSpace.s10) {
                                homeSkeletonBlock(width: 152, height: 38, cornerRadius: PMRadius.pill)
                                homeSkeletonBlock(width: 122, height: 38, cornerRadius: PMRadius.pill)
                            }
                            .padding(.top, 8)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PMSpace.xxl)
                    .padding(.vertical, PMSpace.l24)
                }
                .frame(height: MacHomeHeroMetrics.height)
                .clipShape(RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 220, maximum: 360), spacing: PMSpace.m16),
                    ],
                    spacing: PMSpace.m16
                ) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: PMSpace.m14) {
                            homeSkeletonBlock(
                                width: 42,
                                height: 42,
                                cornerRadius: PMRadius.m10
                            )
                            VStack(alignment: .leading, spacing: PMSpace.s8) {
                                homeSkeletonBlock(width: 76 + CGFloat(index * 14), height: 12)
                                homeSkeletonBlock(width: 128, height: 20)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(PMSpace.l)
                        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l14))
                        .overlay {
                            RoundedRectangle(cornerRadius: PMRadius.l14, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: PMSpace.m16) {
                    homeSkeletonBlock(width: 148, height: 20)

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 180, maximum: 240), spacing: PMSpace.m16),
                        ],
                        spacing: PMSpace.m16
                    ) {
                        ForEach(0..<5, id: \.self) { index in
                            VStack(alignment: .leading, spacing: PMSpace.s8) {
                                homeSkeletonBlock(height: 122, cornerRadius: PMRadius.m10)
                                    .frame(maxWidth: .infinity)
                                homeSkeletonBlock(
                                    width: 104 + CGFloat((index % 3) * 18),
                                    height: 13
                                )
                                homeSkeletonBlock(width: 72, height: 10)
                            }
                            .padding(PMSpace.s10)
                            .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l))
                            .overlay {
                                RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                            }
                        }
                    }
                }
            }
        }
    }

    private func homeSkeletonBlock(
        width: CGFloat? = nil,
        height: CGFloat,
        cornerRadius: CGFloat = PMRadius.s
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(PMColor.glassBtn)
            .frame(width: width, height: height)
    }

    /// 合并 searchRevision 风暴: cancel 上一次再重启计时, 只有最后一次 revision
    /// 落定后才真正重算。
    /// `libraryDriven`: 由资料库版本触发。只有这一类在扫描期间放宽间隔,
    /// 播放记录、日期、语言这些用户看得见的变化照常。
    private func scheduleDerivedRefresh(libraryDriven: Bool = false) {
        guard isSceneActive, isHomeVisible else { return }
        // 同 iOS HomeView: 去抖只能合并密集到达的版本变化, 而扫描/回填的发布
        // 间隔比去抖窗口长, 所以还要一道最小重算间隔才能真正合并。
        // 还在骨架上时不节流: 节流是为了少重算已经摆出来的内容, 不该让用户对着骨架多等十几秒。
        let elapsed = refreshCoordinator.lastRefreshAt.map { Date().timeIntervalSince($0) }
        let delay = model.isPrepared
            ? LibraryDerivedRefreshPolicy.delay(
                sinceLastRefresh: elapsed,
                libraryIsScanning: libraryDriven && !scanService.scanningSourceIDs.isEmpty
            )
            : 0
        refreshCoordinator.debounceTask?.cancel()
        refreshCoordinator.debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            refreshDerivedIfNeeded()
        }
    }

    private var derivedSignature: DerivedSignature {
        DerivedSignature(
            libraryRevision: library.searchRevision,
            playlistRevision: library.playlistCollectionRevision,
            historyRevision: PlayHistoryStore.shared.revision,
            recentSongIDs: library.recentPlaybackSongIDsForSync,
            day: Calendar.current.startOfDay(for: Date()),
            localeIdentifier: Locale.current.identifier
        )
    }

    /// A route change destroys this view; the window retains the snapshot.
    /// Revisions also catch edits made away from Home without changing counts.
    private func refreshDerivedIfNeeded() {
        guard isSceneActive, isHomeVisible else { return }
        let signature = derivedSignature
        guard model.needsRefresh(for: signature) else { return }
        // 正在算的那一轮不打断: 它算完会先把结果摆出来, 再按最新的版本补算。
        // 打断重来的话, 扫描期间版本一直在变, 可能一轮也算不完, 首页就一直停在骨架上。
        guard refreshCoordinator.computeTask == nil else { return }
        refreshCoordinator.lastRefreshAt = Date()
        refreshDerived(signature: signature)
    }

    /// Deduplication happens before recommendation inputs traverse the library.
    /// The remaining aggregates run off actor while the cached page stays visible.
    private func refreshDerived(signature: DerivedSignature) {
        if showAlbumPick { AlbumRecommendationService.shared.refresh(library: library) }
        // 首页的计数、最近播放和封面马赛克都只算音乐: 有声内容按书在自己那一栏,
        // 一部几百集的评书不该把「最近播放」和歌曲总数撑满。
        let songs = library.musicSongs
        let albums = library.visibleAlbums
        let artists = library.visibleArtists
        let spokenWordSongIDs = library.spokenWordSongIDs
        let recentlyPlayed = library.recentlyPlayedSongs(limit: 100)
            .filter { !spokenWordSongIDs.contains($0.id) }
        let recommendationSnapshot = MusicDiscoveryEngine.recommendationSnapshot(in: library)

        refreshCoordinator.computeTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                Self.makeDerivedSnapshot(
                    songs: songs,
                    albums: albums,
                    artists: artists,
                    recentlyPlayed: recentlyPlayed
                )
            }
            var snapshot = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            // 只有离开首页/退到后台(cancelAll)才算作废。算的过程中资料库、歌单又变了的结果照样摆出来,
            // 签名记成它真正对应的那一版, 收尾时发现对不上就补算 —— 丢掉它的话骨架会一直等下去。
            guard !Task.isCancelled else { return }
            snapshot.recommendationResults = model.snapshot.recommendationResults.compactMap { result in
                library.unobservedVisibleSong(id: result.song.id).map {
                    MusicDiscoveryResult(song: $0, score: result.score, reasons: result.reasons)
                }
            }
            model.snapshot = snapshot
            model.isPrepared = true
            model.signature = signature

            let recommendationWorker = Task.detached(priority: .utility) {
                MusicDiscoveryEngine.dailyRecommendations(
                    from: recommendationSnapshot.makeInput(),
                    limit: 12,
                    isCancelled: { Task.isCancelled }
                )
            }
            let recommendations = await withTaskCancellationHandler {
                await recommendationWorker.value
            } onCancel: {
                recommendationWorker.cancel()
            }
            guard !Task.isCancelled else { return }
            model.snapshot.recommendationResults = recommendations
            model.recommendationSignature = signature
            refreshCoordinator.computeTask = nil

            let current = derivedSignature
            if current != signature {
                scheduleDerivedRefresh(libraryDriven: current.differsOnlyInLibraryContent(from: signature))
            }
        }
    }

    private nonisolated static func makeDerivedSnapshot(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        recentlyPlayed: [Song]
    ) -> DerivedSnapshot {
        var snapshot = DerivedSnapshot()
        snapshot.songCount = songs.count
        snapshot.albumCount = albums.count
        snapshot.artistCount = artists.count
        snapshot.artists = artists
        var totalSec = 0.0
        var coverCount = 0
        var lyricsCount = 0
        var playableCount = 0
        var songsByAlbum: [String: [Song]] = [:]
        for song in songs {
            totalSec += max(0, song.duration)
            if song.coverArtFileName?.isEmpty == false { coverCount += 1 }
            if song.lyricsFileName?.isEmpty == false { lyricsCount += 1 }
            if song.isPlayable { playableCount += 1 }
            if let albumID = song.albumID { songsByAlbum[albumID, default: []].append(song) }
        }
        snapshot.totalDurationSec = totalSec
        snapshot.coverCount = coverCount
        snapshot.lyricsCount = lyricsCount
        snapshot.playableCount = playableCount
        snapshot.albumArtworkSongs = songsByAlbum.mapValues { albumSongs in
            albumSongs.first { $0.coverArtFileName?.isEmpty == false } ?? albumSongs[0]
        }

        let sortedByAdded = songs.sorted { $0.dateAdded > $1.dateAdded }
        snapshot.recentSongs = recentlyPlayed.isEmpty ? sortedByAdded : recentlyPlayed
        let latestDateByAlbum = songsByAlbum.mapValues { albumSongs in
            albumSongs.lazy.map(\.dateAdded).max() ?? .distantPast
        }
        snapshot.recentlyAddedAlbums = RecentlyAddedAlbumPolicy.sorted(
            albums: albums, latestDates: latestDateByAlbum
        )

        var mosaicPool = recentlyPlayed
        var seenIDs = Set(mosaicPool.map(\.id))
        for song in sortedByAdded.prefix(40) where seenIDs.insert(song.id).inserted {
            mosaicPool.append(song)
        }
        let covered = mosaicPool.filter { $0.coverArtFileName?.isEmpty == false }
        snapshot.mosaicSongs = Array((covered.isEmpty ? mosaicPool : covered).prefix(6))
        return snapshot
    }

    // MARK: - Update banner

    private var updateBanner: some View {
        HStack(spacing: PMSpace.m) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 22)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let v = updateChecker.availableUpdate?.version {
                    Text(String(format: String(localized: "update_banner_title_format"), v))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                }
                Text("update_banner_subtitle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            ZStack {
                Text("update_banner_action")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(PMColor.brand, in: Capsule())
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
            }
            .overlay {
                MacWindowSafeClickArea {
                    updateChecker.openAppStore()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text("update_banner_action"))
            }
            .shadow(color: PMColor.brand.opacity(0.35), radius: 6, y: 2)

            ZStack {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .overlay {
                MacWindowSafeClickArea {
                    updateChecker.snooze()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text("later"))
            }
            .help(Text("later"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            // 设计稿 update banner 是带轻微 brand 暖色调的卡片, 不能像普通 pmCard
            // 那样几乎贴底色 — 用 bgElev 实色 + 6% brand tint 拉对比。
            RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                .fill(PMColor.bgElev)
            RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                .fill(PMColor.brand.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                .strokeBorder(PMColor.brand.opacity(0.28), lineWidth: 0.5)
        }
    }

    // MARK: - Hero

    /// 主卡:有情景推荐专辑时换成推荐(与 iPhone、电视首页同源),否则仍是曲库叙事。
    @ViewBuilder
    private var heroOrAlbumPick: some View {
        let picks = AlbumRecommendationService.shared
        if showAlbumPick, hasContent,
           let pick = picks.currentPick,
           let album = library.visibleAlbum(id: pick.albumID),
           let moment = picks.moment {
            MacHomeAlbumPickHero(
                pick: pick,
                album: album,
                moment: moment,
                canShowAnother: picks.canShowAnother,
                onPlay: { playAlbumPick(pick.albumID) },
                onPlayNext: { player.insertNextInQueue(picks.songsInTrackOrder(albumID: pick.albumID, library: library)) },
                onAddToQueue: { player.appendToQueue(picks.songsInTrackOrder(albumID: pick.albumID, library: library)) },
                onAnother: { pmWithAnimation(.contentAppear) { picks.showAnother() } },
                onDismiss: { pmWithAnimation(.contentAppear) { picks.dismiss(albumID: pick.albumID) } },
                onShuffleLibrary: { playLibrary(shuffled: true) },
                resume: { resumeShelf($0) }
            )
            .pmAppearFade(.contentAppear)
        } else {
            heroSection
                .pmAppearFade(.contentAppear)
        }
    }

    /// 主卡里的「接着听」: 有声书、播客、电台各最多一张, 最新的在前, 正在播的那类不出现,
    /// 哪类都没有可接着听的就整块不画。音乐的「接着上次」在「开始听」里, 主卡本身也是音乐。
    private func resumeShelf(_ placement: MacHomeResumePlacement) -> some View {
        MacHomeResumeShelf(
            placement: placement,
            isEnabled: showContinueSpaces,
            onTuneIn: { station in tuneIn(station) }
        )
    }

    /// 整张播放:按碟号、轨号的原曲序排队,随机先关掉。
    private func playAlbumPick(_ albumID: String) {
        let songs = AlbumRecommendationService.shared.songsInTrackOrder(albumID: albumID, library: library)
        guard !songs.isEmpty else { return }
        player.shuffleEnabled = false
        Task { await player.play(queue: songs, startingAt: 0) }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        case 18..<22: return String(localized: "greeting_evening")
        default: return String(localized: "greeting_night")
        }
    }

    /// "今晚, 你的资料库里藏着 11,248 个故事" 这样的动态叙事。
    /// 1.6 重设计后用它替代静态 "Primuse", 把首页从"应用展示页"变成"用户专属仪表盘"。
    private var heroNarrative: String {
        let count = model.snapshot.songCount
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        let key: String
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  key = "home_hero_narrative_morning"
        case 12..<18: key = "home_hero_narrative_afternoon"
        case 18..<22: key = "home_hero_narrative_evening"
        default:      key = "home_hero_narrative_night"
        }
        return String(format: String(localized: String.LocalizationValue(key)), formatted)
    }

    /// "来自 8 个源 · 842 张专辑 · 312 位艺术家 · 总时长 47 天 18 小时"
    private var heroStats: String {
        let sources = sourcesStore.sources.filter(\.isEnabled).count
        let albums = model.snapshot.albumCount
        let artists = model.snapshot.artistCount
        let totalSec = model.snapshot.totalDurationSec
        let days = Int(totalSec / 86400)
        let hours = Int((totalSec.truncatingRemainder(dividingBy: 86400)) / 3600)
        if days > 0 {
            return String(format: String(localized: "home_hero_stats_with_days"),
                          sources, albums, artists, days, hours)
        } else {
            return String(format: String(localized: "home_hero_stats_hours_only"),
                          sources, albums, artists, hours)
        }
    }

    private var heroSection: some View {
        MacHomeHeroCard(resume: { resumeShelf($0) }) {
            // 卡片底色 — 暗色模式必须明显高于窗口 bg, 否则跟背景融在一起。
            // 整张卡空白处点一下进歌曲列表。
            Button(action: openLibrarySongs) {
                Rectangle().fill(PMColor.bgElev)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("tab_songs"))
            .accessibilityHint(Text("library_browse"))
            .accessibilityIdentifier("macHomeLibraryHeroOpenSongs")
        } content: {
            HStack(alignment: .center, spacing: 36) {
                coverMosaic
                    .frame(width: 240, height: 240)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: greeting)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .allowsHitTesting(false)

                    Text(verbatim: heroNarrative)
                        .font(.system(size: 40, weight: .bold))
                        .tracking(-0.8)
                        .lineSpacing(2)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)

                    Text(verbatim: heroStats)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: 660, alignment: .leading)
                        .allowsHitTesting(false)

                    HStack(spacing: PMSpace.s10) {
                        Button { playLibrary(shuffled: true) } label: {
                            Label("shuffle_all", systemImage: "shuffle")
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 11)
                                .background(PMColor.brand, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasContent)
                        .shadow(color: PMColor.brand.opacity(0.45), radius: 10, y: 4)

                        Button { playLibrary(shuffled: false) } label: {
                            Label("play_all", systemImage: "play.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 11)
                                .background(Color.white.opacity(0.18), in: Capsule())
                                .overlay { Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 0.5) }
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasContent)
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Playing radio is contextual, so promote only the active station beneath
    /// the hero instead of letting the complete station library dominate the
    /// top of Home. The full shelf remains lower with the other recent content.
    private func radioNowPlayingStrip(_ station: RadioStation) -> some View {
        let isActive = player.isPlaying || player.isLoading

        return HStack(spacing: PMSpace.m14) {
            Button {
                NotificationCenter.default.post(name: .primuseSelectRadio, object: nil)
            } label: {
                HStack(spacing: PMSpace.m14) {
                    RadioStationArtworkContent(station: station, decodeSize: 54)
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isActive ? Color.red : PMColor.textFaint)
                                .frame(width: 6, height: 6)
                            Text("radio_live")
                                .font(.system(size: 10.5, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(isActive ? PMColor.brand : PMColor.textMuted)
                        }

                        Text(station.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                            .lineLimit(1)

                        Text(player.radioMetadataTitle ?? station.playbackSubtitle)
                            .font(PMFont.caption)
                            .foregroundStyle(PMColor.textMuted)
                            .lineLimit(1)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Spacer(minLength: PMSpace.m)

            Button {
                NotificationCenter.default.post(name: .primuseSelectRadio, object: nil)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 30, height: 30)
                    .background(PMColor.glassBtn, in: Circle())
            }
            .buttonStyle(.plain)
            .help(Text("home_section_view_all"))
            .accessibilityLabel(Text("home_section_view_all"))

            Button {
                toggleRadio(station)
            } label: {
                Image(systemName: isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(PMColor.brand, in: Circle())
            }
            .buttonStyle(.plain)
            .help(Text(isActive ? "pause" : "play"))
            .accessibilityLabel(Text(isActive ? "pause" : "play"))
        }
        .padding(PMSpace.m14)
        .pmCard(cornerRadius: PMRadius.l14)
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l14, style: .continuous)
                .strokeBorder(PMColor.brand.opacity(0.35), lineWidth: 1)
        }
    }

    private var radioSpotlightSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.s10) {
            HStack {
                Text("radio_title")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                // 切侧栏的「电台」项，而不是 push 一个带返回键的新页面 ——
                // 侧栏已经有这个目的地了，push 会让同一个页面有两条路径、
                // 两种退出方式(返回键 vs 点侧栏)。
                Button("home_section_view_all") {
                    NotificationCenter.default.post(name: .primuseSelectRadio, object: nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PMColor.brand)
            }

            // 跟 iPhone 首页同一条电台条: 最近听过的在前, 右键有「电台信息」。
            RadioStationStrip(horizontalInset: 0)
        }
    }

    private func toggleRadio(_ station: RadioStation) {
        // `.pls` 包装先放行:它拆出来的真实流主机由播放器在起播时再问。
        if !RadioImportParser.isPlaylistWrapper(station.streamURL),
           let url = station.url,
           TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            pendingInsecureStation = station
            return
        }
        performRadioToggle(station)
    }

    private func performRadioToggle(_ station: RadioStation) {
        if player.currentRadioStation?.id == station.id,
           player.isPlaying || player.isLoading {
            player.pause()
        } else {
            SiriMediaInteractionDonor.donate(station: station)
            Task { await player.play(station: station, within: radioStationsStore.stations) }
        }
    }

    /// 「接着听」的电台卡: 调回那个台。它正在播时卡片本来就不出现, 所以这里
    /// 不做暂停, 只负责起播 (包括明文 HTTP 的确认)。
    private func tuneIn(_ station: RadioStation) {
        if player.currentRadioStation?.id == station.id,
           player.isPlaying || player.isLoading {
            return
        }
        toggleRadio(station)
    }

    private var coverMosaic: some View {
        Group {
            if mosaicSongs.isEmpty {
                RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.42))
                    }
            } else if mosaicLayout.columns == 1, let song = mosaicLayout.songs.first {
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    cornerRadius: PMRadius.l,
                    sourceID: song.sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
            } else {
                // 设计稿的封面马赛克是"散落叠放"的: 每张按固定角度轻微倾斜 + 上下错位,
                // 不是横平竖直的网格。这里复刻 home.jsx CoverMosaic 的 transforms。
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                   count: mosaicLayout.columns),
                    spacing: 8
                ) {
                    ForEach(Array(mosaicLayout.songs.enumerated()), id: \.element.id) { idx, song in
                        CachedArtworkView(
                            coverRef: song.coverArtFileName, songID: song.id,
                            cornerRadius: PMRadius.m,
                            sourceID: song.sourceID, filePath: song.filePath,
                            fileFormat: song.fileFormat
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                        .rotationEffect(.degrees(Self.mosaicTilt[idx % Self.mosaicTilt.count]))
                        .offset(y: Self.mosaicYOffset[idx % Self.mosaicYOffset.count])
                    }
                }
                // 留点内边距, 让倾斜出界的封面角不被 hero 圆角裁掉。
                .padding(6)
            }
        }
    }

    /// home.jsx CoverMosaic 的散落参数: 每张封面的旋转角度 (度) 与垂直错位 (pt)。
    private static let mosaicTilt: [Double] = [-4, 2, -1, 4, -3, 1]
    private static let mosaicYOffset: [CGFloat] = [-6, 0, 4, -4, 2, 0]

    /// 把候选封面收敛成"整行铺满"的网格: ≥6 张走 3×2, 4–5 张走 2×2, 其余只展示
    /// 单张大封面。这样马赛克始终是横平竖直的完整矩形, 不会出现落单的半行。
    private var mosaicLayout: (songs: [Song], columns: Int) {
        let pool = mosaicSongs
        if pool.count >= 6 { return (Array(pool.prefix(6)), 3) }
        if pool.count >= 4 { return (Array(pool.prefix(4)), 2) }
        return (Array(pool.prefix(1)), 1)
    }

    private var mosaicSongs: [Song] { model.snapshot.mosaicSongs }

    // MARK: - Stats row (库健康度 + 源状态)

    private var statsRow: some View {
        HStack(alignment: .top, spacing: PMSpace.m16) {
            libraryHealthCard
            sourceStatusCard
        }
        // 两张卡用 equal-height: HStack 默认会拉到两边最高的那张, 但 homeCard 内部
        // VStack 自然高度小的那张就会留白。fixedSize 关掉自动收缩, 让 HStack 强制
        // 两边 .frame(maxHeight: .infinity), 这样卡片背景填满, 不会出现"音乐源卡
        // 比库健康度卡矮一截"。
        .fixedSize(horizontal: false, vertical: true)
    }

    private var libraryHealthCard: some View {
        homeCard(title: "home_health_title", spec: "LIB-09") {
            VStack(alignment: .leading, spacing: PMSpace.m) {
                HStack(spacing: PMSpace.m) {
                    metric(value: model.snapshot.songCount, label: "tab_songs")
                    metric(value: model.snapshot.albumCount, label: "tab_albums")
                    metric(value: model.snapshot.artistCount, label: "tab_artists")
                }
                Rectangle().fill(PMColor.divider).frame(height: 0.5).padding(.vertical, 2)
                // 设计稿: 封面绿 / 歌词红 / 可播放蓝 (跟"健康"语义不同维度区分)。
                healthBar("home_cover_art", value: coverRatio, color: PMColor.ok)
                healthBar("home_lyrics", value: lyricsRatio, color: PMColor.bad)
                healthBar("home_playable", value: playableRatio,
                          color: Color(red: 0.4, green: 0.7, blue: 0.95))
            }
        }
    }

    private var sourceStatusCard: some View {
        MacHomeSourceStatusCard()
    }

    /// 当前正在扫描的源 (含其 sourceID 对应的 MusicSource) —— scanStates 的 key 才是
    /// sourceID, .values 拿不到, 所以这里遍历配对。
    private var activeScanEntry: (source: MusicSource, state: ScanService.ScanState)? {
        for (id, state) in scanService.scanStates where state.isScanning || state.canResume {
            if let src = sourcesStore.sources.first(where: { $0.id == id }) {
                return (src, state)
            }
        }
        return nil
    }

    /// 设计稿的「源任务」进度块: 源名 · 阶段 + 当前文件 + 带百分比的进度条。
    private func sourceTaskBox(title: String, phase: String, detail: String,
                               progress: Double, indeterminate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(PMColor.brand).frame(width: 6, height: 6)
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: "· \(phase)")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                if indeterminate {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    taskProgressBar(progress)
                    Text(verbatim: "\((min(max(progress, 0), 1) * 100).finiteInt())%")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(PMColor.bgDeep.opacity(0.35), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func homeCard<C: View>(title: LocalizedStringKey, spec: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: PMSpace.m14) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.3)
                Spacer()
                let visibleSpec = PMTextWithoutDesignCodes(spec)
                if !visibleSpec.isEmpty {
                    Text(verbatim: visibleSpec)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            content()
            // 用一个透明 Spacer 把内容顶到顶部, 让 .frame(maxHeight: .infinity) 真
            // 把卡片拉到行高。source 卡内容短的时候就靠它把高度撑到跟健康度卡相同。
            Spacer(minLength: 0)
        }
        .padding(PMSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pmCard(cornerRadius: PMRadius.l)
    }

    private func metric(value: Int, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value, format: .number)
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .tracking(-0.5)
                .foregroundStyle(PMColor.text)
                .contentTransition(.numericText())
                .pmAnimation(.control, value: value)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func healthBar(_ title: LocalizedStringKey, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.text)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(PMColor.textMuted)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PMColor.divider)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 6)
        }
    }

    private func scanProgressBar(_ scan: ScanService.ScanState) -> some View {
        let pct = scan.totalCount > 0 ? min(scan.progress, 1) : 0
        return taskProgressBar(pct)
    }

    private func taskProgressBar(_ pct: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PMColor.divider)
                Capsule().fill(PMColor.brand).frame(width: geo.size.width * min(max(pct, 0), 1))
            }
        }
        .frame(height: 5)
    }

    // MARK: - Pipeline

    private var pipelineSection: some View {
        MacHomePipelineSection(hasContent: hasContent)
    }

    private func pipelineNode(_ icon: String, _ title: String,
                              statusText: String, isActive: Bool) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 52, height: 52)
                .background(
                    (isActive ? PMColor.brand.opacity(0.18) : PMColor.brand.opacity(0.10)),
                    in: .rect(cornerRadius: 12, style: .continuous)
                )
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func pipelineConnector(isActive: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? PMColor.text.opacity(0.6) : PMColor.textFaint.opacity(0.4))
            .padding(.horizontal, 6)
    }

    // MARK: - Recommendations

    /// macOS 首页与 iOS 一样以本地每日推荐为底;智能推荐可用时由它重排并写理由。
    private var recommendationSection: some View {
        MacHomeForYouSection(results: model.snapshot.recommendationResults)
    }

    // MARK: - Recently added (6-col 140pt grid)

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: LocalizedStringKey(HomeDiscoveryText.string("recent_albums")),
                          subtitle: "home_recently_added_subtitle",
                          destination: .recentlyAdded)

            LazyVGrid(
                columns: Array(repeating: GridItem(.adaptive(minimum: 130, maximum: 160),
                                                    spacing: PMSpace.m16, alignment: .top),
                               count: 1),
                alignment: .leading,
                spacing: PMSpace.l
            ) {
                ForEach(model.snapshot.recentlyAddedAlbums.prefix(12)) { album in
                    NavigationLink(value: album) {
                        albumCard(album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func albumCard(_ album: Album) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(album: album, cornerRadius: PMRadius.m)
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

            Text(album.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            if let artist = album.artistName {
                Text(artist)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Text("\(album.songCount) \(String(localized: "songs_count"))")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
        }
    }

    // MARK: - Recently played (4-col compact grid)

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "recently_played",
                          subtitle: "home_recently_played_subtitle",
                          destination: .recentlyPlayed)

            LazyVGrid(
                columns: Array(repeating: GridItem(.adaptive(minimum: 260, maximum: 320),
                                                    spacing: PMSpace.m, alignment: .top),
                               count: 1),
                alignment: .leading,
                spacing: PMSpace.m
            ) {
                ForEach(recentSongs.prefix(8)) { song in
                    Button { playSong(song) } label: {
                        recentSongRow(song)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func recentSongRow(_ song: Song) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 42, cornerRadius: PMRadius.s,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(library.artistDisplayName(for: song) ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(8)
        .background(PMColor.rowHover, in: .rect(cornerRadius: PMRadius.m))
    }

    private var recentSongs: [Song] {
        model.snapshot.recentSongs
    }

    // MARK: - Artists (horizontal scroll)

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "tab_artists",
                          subtitle: "home_artists_subtitle",
                          destination: .artists)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PMSpace.l) {
                    ForEach(model.snapshot.artists.prefix(14)) { artist in
                        NavigationLink(value: artist) {
                            artistChip(artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            // 系统"总是显示滚动条"设置下 showsIndicators 不生效, 直接在底层
            // NSScrollView 上强制隐藏横向滚动条。
            .pmForceHideScrollers()
            // 鼠标按住可拖动滚动 — SwiftUI 横向 ScrollView 默认只响应触控板/滚轮,
            // 这个 modifier 在底层 NSScrollView 上加 pan gesture, 鼠标拖也能滚。
            .pmEnableHorizontalDragScroll()
        }
    }

    private func artistChip(_ artist: Artist) -> some View {
        VStack(spacing: 8) {
            ArtistArtworkView(
                artist: artist,
                size: 92,
                cornerRadius: 46
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            Text(artist.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text("\(artist.songCount)")
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
        }
        .frame(width: 100)
    }

    // MARK: - Section header

    private enum HomeSectionDestination {
        case recentlyAdded
        case recentlyPlayed
        case artists
        /// 「开始听」的「全部意图」整页。
        case allIntents
        /// 某个意图的「查看歌曲」;从「全部意图」进来的返回到那一页。
        case intentSongs(ListeningIntent, fromAllIntents: Bool)
    }

    private func openSection(_ destination: HomeSectionDestination) {
        pmWithAnimation(.list) {
            activeSection = destination
        }
    }

    private func sectionHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey?, destination: HomeSectionDestination? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(PMColor.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
            }
            Spacer()
            if let destination {
                Button {
                    pmWithAnimation(.list) {
                        activeSection = destination
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("home_section_view_all")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("home_section_view_all"))
            }
        }
    }

    @ViewBuilder
    private func sectionDestination(_ destination: HomeSectionDestination) -> some View {
        switch destination {
        case .recentlyAdded:
            recentlyAddedAllView(onBack: closeSection)
        case .recentlyPlayed:
            recentlyPlayedAllView(onBack: closeSection)
        case .artists:
            artistsAllView(onBack: closeSection)
        case .allIntents:
            ListeningIntentsPage(
                onBack: closeSection,
                onOpenSongs: { openSection(.intentSongs($0, fromAllIntents: true)) }
            )
            .background(PMColor.bg.ignoresSafeArea())
        case .intentSongs(let intent, let fromAllIntents):
            ListeningIntentSongsView(
                intent: intent,
                onBack: {
                    if fromAllIntents { openSection(.allIntents) } else { closeSection() }
                }
            )
            .background(PMColor.bg.ignoresSafeArea())
        }
    }

    private func recentlyAddedAllView(onBack: @escaping () -> Void) -> some View {
        let albums = model.snapshot.recentlyAddedAlbums

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                homeCollectionHeader(
                    eyebrow: "library_title",
                    title: LocalizedStringKey(HomeDiscoveryText.string("recent_albums")),
                    detail: "\(albums.count) \(String(localized: "albums_count"))",
                    onBack: onBack
                )

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 5),
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            albumCard(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
            }
            .padding(.top, 24)
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }

    private func recentlyPlayedAllView(onBack: @escaping () -> Void) -> some View {
        let songs = model.snapshot.recentSongs

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                homeCollectionHeader(
                    eyebrow: "library_title",
                    title: "recently_played",
                    detail: "\(songs.count) \(String(localized: "songs_count"))",
                    onBack: onBack
                )

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: PMSpace.m, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: PMSpace.m
                ) {
                    ForEach(songs) { song in
                        Button { playSong(song) } label: {
                            recentSongRow(song)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
            }
            .padding(.top, 24)
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }

    private func artistsAllView(onBack: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            homeCollectionHeader(
                eyebrow: "library_title",
                title: "tab_artists",
                detail: "\(model.snapshot.artists.count) \(String(localized: "artists_count"))",
                onBack: onBack
            )
            .padding(.vertical, 24)

            Rectangle()
                .fill(PMColor.divider)
                .frame(height: 0.5)

            ArtistListView(artists: model.snapshot.artists)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }

    private func homeCollectionHeader(
        eyebrow: LocalizedStringKey,
        title: LocalizedStringKey,
        detail: String,
        onBack: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            Spacer(minLength: 16)
            MacNavigationBackButton(
                accessibilityIdentifier: "homeSectionInlineBack",
                action: onBack
            )
        }
        .padding(.horizontal, PMSpace.xxxl)
    }

    private func closeSection() {
        pmWithAnimation(.list) {
            activeSection = nil
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: PMSpace.l) {
            Spacer().frame(height: 60)
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(PMColor.textFaint)
            Text("welcome_title")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text("welcome_desc")
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
            Text("home_empty_mac_hint")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived

    private var activeScans: [ScanService.ScanState] {
        scanService.scanStates.values.filter { $0.isScanning || $0.canResume }
    }

    /// "扫描中" = 文件扫描任务 + 正在进行的元数据刮削 (扫描标签)。
    private var activeTaskCount: Int {
        activeScans.count
            + (scraperService.isScraping ? 1 : 0)
            + ((backfill.isRunning || backfill.hasPendingWork) ? 1 : 0)
    }

    /// 刮削进行中的状态文案: "已处理/总数 · 当前歌曲" (当前曲名拿得到才拼)。
    private var scrapingStatusText: String {
        let counts = "\(scraperService.processedCount)/\(scraperService.totalCount)"
        let title = scraperService.currentSongTitle
        return title.isEmpty ? counts : "\(counts) · \(title)"
    }

    private var enabledSourcesCount: Int { sourcesStore.sources.filter(\.isEnabled).count }

    private var coverRatio: Double { ratio(count: model.snapshot.coverCount) }
    private var lyricsRatio: Double { ratio(count: model.snapshot.lyricsCount) }
    private var playableRatio: Double { ratio(count: model.snapshot.playableCount) }

    private func ratio(count: Int) -> Double {
        guard model.snapshot.songCount > 0 else { return 0 }
        return Double(count) / Double(model.snapshot.songCount)
    }

    // MARK: - Actions

    private func playSong(_ song: Song) {
        let spokenWordSongIDs = library.spokenWordSongIDs
        var queue = library.recentlyPlayedSongs(limit: 50)
            .filter { !spokenWordSongIDs.contains($0.id) }
        if !queue.contains(where: { $0.id == song.id }) { queue.insert(song, at: 0) }
        if queue.count < 20 {
            // The rest of the library goes in as IDs and is resolved off the
            // main actor a window at a time.
            let existingIDs = Set(queue.map(\.id))
            let leading = queue.filteredPlayable().map(\.id)
            guard let startIndex = leading.firstIndex(of: song.id) else { return }
            var ids = leading
            ids.reserveCapacity(leading.count + library.musicSongs.count)
            for candidate in library.musicSongs where !existingIDs.contains(candidate.id) {
                ids.append(candidate.id)
            }
            player.shuffleEnabled = false
            SiriMediaInteractionDonor.donate(song: song)
            Task { await player.play(queueIDs: ids, startingAt: startIndex) }
            return
        }
        queue = queue.filteredPlayable()
        guard let startIndex = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        SiriMediaInteractionDonor.donate(song: queue[startIndex])
        Task { await player.play(queue: queue, startingAt: startIndex) }
    }

    private func playLibrary(shuffled: Bool) {
        // 整库播放不含不喜欢的歌(#193)。
        let ids = library.musicSongIDsExcludingDisliked
        guard !ids.isEmpty else { return }
        player.shuffleEnabled = false
        Task { await player.play(queueIDs: ids, order: shuffled ? .shuffled : .asGiven) }
    }
}

/// Scan/backfill progress changes far more often than the rest of the home
/// dashboard. Keeping this card in its own View limits those invalidations to
/// one small subtree.
private struct MacHomeSourceStatusCard: View {
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService

    var body: some View {
        card(title: "Source Status", spec: "SRC-* · LIB-14/15") {
            VStack(alignment: .leading, spacing: PMSpace.m) {
                HStack(spacing: PMSpace.m) {
                    metric(value: enabledSourcesCount, label: "home_enabled_sources")
                    metric(value: activeTaskCount, label: "home_active_scans")
                    metric(value: backfill.remainingCount(forSource: nil), label: "home_pending_details")
                }
                Rectangle().fill(PMColor.divider).frame(height: 0.5).padding(.vertical, 2)
                activityBody
            }
        }
    }

    @ViewBuilder
    private var activityBody: some View {
        if let entry = activeScanEntry {
            taskBox(
                title: entry.source.name,
                phase: entry.state.isScanning ? Lz("Reading files") : Lz("Resume pending"),
                detail: entry.state.currentFile,
                progress: entry.state.totalCount > 0 ? min(entry.state.progress, 1) : 0,
                indeterminate: entry.state.totalCount == 0
            )
        } else if backfill.isRunning || backfill.statusCount > 0 {
            let processed = backfill.processedCount
            let total = processed + backfill.statusCount
            let remainingDetail = String(
                format: String(localized: "backfill_remaining"),
                backfill.statusCount
            )
            let retryCount = backfill.deferredRetryCount(forSource: nil)
            let detail = retryCount > 0
                ? remainingDetail + " · " + String(
                    format: String(localized: "backfill_retry_count_format"),
                    retryCount
                )
                : remainingDetail
            let phase = switch backfill.activityState {
            case .running: Lz("Reading tags")
            case .retrying: String(localized: "backfill_retry_in_progress")
            case .waitingForWiFi: String(localized: "backfill_waiting_for_wifi")
            case .retryPending: String(localized: "backfill_retry_pending")
            case .pending, .idle: String(localized: "home_pending_details")
            }
            taskBox(
                title: Lz("Metadata backfill"),
                phase: phase,
                detail: detail,
                progress: total > 0 ? Double(processed) / Double(total) : 0,
                indeterminate: (backfill.activityState == .running || backfill.activityState == .retrying)
                    && total == 0
            )
        } else if scraperService.isScraping {
            taskBox(
                title: Lz("Metadata scraping"),
                phase: Lz("Covers / Lyrics"),
                detail: scraperService.currentSongTitle,
                progress: scraperService.progress,
                indeterminate: scraperService.totalCount == 0
            )
        } else if backfill.failedCount > 0 {
            Button { backfill.retryFailed() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(PMColor.bad)
                    Text(String(format: String(localized: "backfill_retry_failed"), backfill.failedCount))
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textMuted)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(PMColor.ok)
                Text("home_no_scans")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
            }
        }
    }

    private var activeScanEntry: (source: MusicSource, state: ScanService.ScanState)? {
        for (id, state) in scanService.scanStates where state.isScanning || state.canResume {
            if let source = sourcesStore.sources.first(where: { $0.id == id }) {
                return (source, state)
            }
        }
        return nil
    }

    private var activeTaskCount: Int {
        scanService.scanStates.values.filter { $0.isScanning || $0.canResume }.count
            + (scraperService.isScraping ? 1 : 0)
            + ((backfill.isRunning || backfill.hasPendingWork) ? 1 : 0)
    }

    private var enabledSourcesCount: Int { sourcesStore.sources.filter(\.isEnabled).count }

    private func taskBox(
        title: String,
        phase: String,
        detail: String,
        progress: Double,
        indeterminate: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(PMColor.brand).frame(width: 6, height: 6)
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: "· \(phase)")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                if indeterminate {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    progressBar(progress)
                    Text(verbatim: "\((min(max(progress, 0), 1) * 100).finiteInt())%")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(PMColor.bgDeep.opacity(0.35), in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }
    }

    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(PMColor.divider)
                Capsule().fill(PMColor.brand)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 5)
    }

    private func metric(value: Int, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value, format: .number)
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .tracking(-0.5)
                .foregroundStyle(PMColor.text)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<C: View>(
        title: LocalizedStringKey,
        spec: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: PMSpace.m14) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).tracking(-0.3)
                Spacer()
                let visibleSpec = PMTextWithoutDesignCodes(spec)
                if !visibleSpec.isEmpty {
                    Text(verbatim: visibleSpec)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(PMSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pmCard(cornerRadius: PMRadius.l)
    }
}

/// Pipeline status changes with scan progress and playback state. Isolating it
/// prevents those changes from rebuilding the artwork grids above and below it.
private struct MacHomePipelineSection: View {
    let hasContent: Bool
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService

    var body: some View {
        HStack(spacing: PMSpace.s8) {
            node("externaldrive.fill", "home_pipeline_sources",
                 statusText: "\(enabledSourcesCount) \(Lz("online"))",
                 isActive: !sourcesStore.sources.isEmpty)
            connector(isActive: !activeScans.isEmpty || hasContent)
            node("arrow.triangle.2.circlepath", "home_pipeline_scan",
                 statusText: activeScans.isEmpty ? Lz("No Scan") : "\(activeScans.count) \(Lz("in progress"))",
                 isActive: !activeScans.isEmpty || hasContent)
            connector(isActive: hasContent)
            node("tag.fill", "home_pipeline_metadata",
                 statusText: scraperService.isScraping
                    ? "\(scraperService.processedCount)/\(scraperService.totalCount) \(Lz("in progress"))"
                    : (backfill.remainingCount(forSource: nil) == 0
                        ? Lz("Done")
                        : "\(backfill.remainingCount(forSource: nil)) \(Lz("pending backfill"))"),
                 isActive: hasContent || scraperService.isScraping)
            connector(isActive: player.currentSong != nil)
            node("play.fill", "home_pipeline_listen",
                 statusText: player.currentSong?.title ?? Lz("Not Playing"),
                 isActive: player.currentSong != nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .pmCard(cornerRadius: PMRadius.l)
    }

    private var activeScans: [ScanService.ScanState] {
        scanService.scanStates.values.filter { $0.isScanning || $0.canResume }
    }

    private var enabledSourcesCount: Int { sourcesStore.sources.filter(\.isEnabled).count }

    private func node(_ icon: String, _ title: LocalizedStringKey, statusText: String, isActive: Bool) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 52, height: 52)
                .background(isActive ? PMColor.brand.opacity(0.18) : PMColor.brand.opacity(0.10),
                            in: .rect(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func connector(isActive: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? PMColor.text.opacity(0.6) : PMColor.textFaint.opacity(0.4))
            .padding(.horizontal, 6)
    }
}

private struct MacWindowSafeClickArea: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = WindowSafeNSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performClick)
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1, height: proposal.height ?? 1)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performClick() {
            action()
        }
    }
}

private final class WindowSafeNSButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// MARK: - Continue listening (inside the hero card)

/// 主卡里的「接着听」: 有声书、播客、电台各最多一张, 最新的在前, 正在播的那类不出现。
/// 单独成一个视图: 它要盯播放器、电台库和听书位置, 这些都比首页其余部分变得勤,
/// 放在这里只重算这一小块。
///
/// 主卡宽时排在卡内右侧一列, 窄时排在主内容下面一行。卡底是深色的暖色背板,
/// 这一块按深色外观画, 各类的颜色取亮的那一版。
private struct MacHomeResumeShelf: View {
    let placement: MacHomeResumePlacement
    let isEnabled: Bool
    let onTuneIn: (RadioStation) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(RadioStationsStore.self) private var radioStationsStore

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private enum Card: Identifiable {
        case radio(RadioStation, lastPlayedAt: Date)
        case book(SpokenWordBook, songs: [Song])
        case podcast(PodcastEpisode, PodcastShow)

        var id: ListeningSpace {
            switch self {
            case .radio: return .radio
            case .book: return .spokenWord
            case .podcast: return .podcast
            }
        }
    }

    /// 窄排法下一张的理想宽度: 一行放不下就两张一行, 再放不下一张一行。
    private static var bandTileWidth: CGFloat { 220 }

    var body: some View {
        let cards = isEnabled ? resumeCards : []
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: PMSpace.s8) {
                Text("home_continue_spaces_title")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.leading, 2)
                switch placement {
                case .column(let width):
                    ForEach(cards) { tile(for: $0) }
                        .frame(width: width)
                case .band:
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: PMSpace.s10) {
                            ForEach(cards) { bandTile($0) }
                        }
                        if cards.count > 2 {
                            // 两张一行; 落单的最后一张占满整行, 不缩在左半边。
                            VStack(spacing: PMSpace.s8) {
                                ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { start in
                                    HStack(spacing: PMSpace.s10) {
                                        ForEach(cards[start..<min(start + 2, cards.count)]) { bandTile($0) }
                                    }
                                }
                            }
                        }
                        VStack(spacing: PMSpace.s8) {
                            ForEach(cards) { tile(for: $0) }
                        }
                    }
                }
            }
            .environment(\.colorScheme, .dark)
            .pmAppearFade(.contentAppear)
        }
    }

    /// 理想宽度定成 `bandTileWidth`: `ViewThatFits` 按它判断一行放不放得下, 放得下时再平分整行。
    private func bandTile(_ card: Card) -> some View {
        tile(for: card)
            .frame(minWidth: 0, idealWidth: Self.bandTileWidth, maxWidth: .infinity)
    }

    private var resumeCards: [Card] {
        #if DEBUG
        if let cards = debugResumeCards { return cards }
        #endif
        var candidates: [ListeningResumeCandidate] = []
        var cardsBySpace: [ListeningSpace: Card] = [:]

        // 电台: 最后收听的那个台。
        if let station = radioStationsStore.stations
            .filter({ $0.lastPlayedAt != nil })
            .max(by: { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }),
           let lastPlayedAt = station.lastPlayedAt {
            candidates.append(ListeningResumeCandidate(space: .radio, lastListenedAt: lastPlayedAt))
            cardsBySpace[.radio] = .radio(station, lastPlayedAt: lastPlayedAt)
        }

        // 有声: 最近在听、还没听完的那本 (书架排序已把它排在最前); 归档的书不算。
        if !library.spokenWordSongs.isEmpty {
            _ = store.revision
            let items = library.spokenWordSongs.map { SpokenWordBookSupport.item(for: $0, store: store) }
            let archived = store.archivedBookIDs
            if let book = SpokenWordBookGrouping.books(from: items)
                .first(where: { $0.isInProgress && !archived.contains($0.id) }),
               let lastListenedAt = book.lastListenedAt {
                let songsByID = Dictionary(
                    library.spokenWordSongs.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let songs = book.items.compactMap { songsByID[$0.id] }
                if !songs.isEmpty {
                    candidates.append(ListeningResumeCandidate(space: .spokenWord, lastListenedAt: lastListenedAt))
                    cardsBySpace[.spokenWord] = .book(book, songs: songs)
                }
            }
        }

        // 播客: 最近听到一半的那一集。
        if let recent = PodcastStore.shared.mostRecentInProgress {
            candidates.append(ListeningResumeCandidate(space: .podcast, lastListenedAt: recent.updatedAt))
            cardsBySpace[.podcast] = .podcast(recent.episode, recent.show)
        }

        return ListeningResumePolicy.cards(
            from: candidates,
            playingSpace: MacListeningSpaceStyle.playingSpace(of: player),
            now: Date()
        )
        .compactMap { cardsBySpace[$0.space] }
    }

    #if DEBUG
    /// 截图钩子 `PRIMUSE_DEBUG_RESUME_CARDS=podcast,radio,book`: 按列出的顺序摆演示卡片,
    /// 不看播放记录 —— 编译机上的测试曲库没有可接着听的东西。
    private var debugResumeCards: [Card]? {
        guard let raw = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_RESUME_CARDS"],
              !raw.isEmpty else { return nil }
        let song = library.musicSongs.first
        return raw.split(separator: ",").compactMap { name -> Card? in
            switch name.trimmingCharacters(in: .whitespaces) {
            case "radio":
                let station = RadioStation(id: "debug-radio", name: "Jazz FM 102.2", streamURL: "https://example.invalid/jazz")
                return .radio(station, lastPlayedAt: Date().addingTimeInterval(-2 * 3600))
            case "book":
                guard let song else { return nil }
                let item = SpokenWordBookItem(
                    id: song.id, title: "第三章", albumTitle: "三体 II：黑暗森林", artist: "刘慈欣",
                    duration: 3600, position: 1500, positionUpdatedAt: Date()
                )
                return SpokenWordBookGrouping.books(from: [item]).first.map { .book($0, songs: [song]) }
            case "podcast":
                guard let feed = URL(string: "https://example.invalid/feed"),
                      let enclosure = URL(string: "https://example.invalid/episode.mp3") else { return nil }
                let show = PodcastShow(id: "debug-show", feedURL: feed, title: "The Daily", subscribedAt: Date())
                let episode = PodcastEpisode(
                    id: "debug-episode", showID: show.id, guid: "debug-episode",
                    title: "The Firestorm Over a Rape Allegation at a Boarding School",
                    duration: 1800, enclosureURL: enclosure, firstSeenAt: Date()
                )
                return .podcast(episode, show)
            default:
                return nil
            }
        }
    }
    #endif

    @ViewBuilder
    private func tile(for card: Card) -> some View {
        let size = MacHomeResumeTileMetrics.artworkSize
        switch card {
        case .radio(let station, let lastPlayedAt):
            MacHomeResumeTile(
                space: .radio,
                title: station.name,
                subtitle: radioDetail(station, lastPlayedAt: lastPlayedAt),
                progress: nil,
                action: { onTuneIn(station) }
            ) {
                RadioStationArtworkContent(station: station, decodeSize: size)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous))
            }
        case .book(let book, let songs):
            let cover = songs.first { $0.id == book.resumeItemID } ?? songs[0]
            MacHomeResumeTile(
                space: .spokenWord,
                title: book.title,
                subtitle: MacHomeBookText.detail(book),
                progress: book.fractionComplete,
                action: {
                    SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
                }
            ) {
                // 书的形状, 高度顶满封面槽、在方槽里居中, 标题跟别的卡对齐。
                SpokenWordBookCover(
                    song: cover,
                    width: SpokenWordCoverLayout.width(forHeight: size),
                    cornerRadius: PMRadius.xs
                )
                .frame(width: size, height: size)
            }
        case .podcast(let episode, let show):
            let position = store.position(forSongID: episode.id)?.position ?? 0
            let total = episode.duration ?? 0
            MacHomeResumeTile(
                space: .podcast,
                title: episode.title,
                subtitle: podcastDetail(show: show, position: position, total: total),
                progress: total > 0 ? min(1, position / total) : nil,
                action: {
                    PodcastPlaybackLauncher.play(episode, player: player) { _ in
                        NotificationCenter.default.post(name: .primuseSelectSpokenWord, object: LibrarySection.podcasts)
                    }
                }
            ) {
                PodcastArtwork(episode: episode, show: show, size: size, cornerRadius: PMRadius.m)
            }
        }
    }

    /// 电台第二行: 上次听是什么时候, 有分组时带上分组。
    private func radioDetail(_ station: RadioStation, lastPlayedAt: Date) -> String {
        let group = [station.folderName, station.tagNames?.first, station.sourceName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return [lastPlayedAt.formatted(.relative(presentation: .named)), group]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// 播客第二行: 节目名 + 这一集还剩多久。
    private func podcastDetail(show: PodcastShow, position: Double, total: Double) -> String {
        var parts = [show.title]
        if total > 0, position > 0, total - position > 0 {
            parts.append(String(
                format: String(localized: "spoken_word_remaining_format"),
                ChapterTimeFormatter.string(from: total - position)
            ))
        }
        return parts.joined(separator: " · ")
    }
}

private enum MacHomeResumeTileMetrics {
    static let artworkSize: CGFloat = 44
    static let playButtonSize: CGFloat = 30
}

/// 「接着听」里的一张: 封面、类别、标题和一行说明, 右边一颗播放钮, 有进度时外面一圈进度环。
/// 画在主卡的深色背板上: 半透明白底、悬停提亮, 播放钮悬停时染上这一类的颜色。
private struct MacHomeResumeTile<Artwork: View>: View {
    let space: ListeningSpace
    let title: String
    let subtitle: String
    let progress: Double?
    let action: () -> Void
    @ViewBuilder let artwork: Artwork

    @State private var isHovered = false

    var body: some View {
        let tint = MacListeningSpaceStyle.color(for: space)
        let shape = RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
        Button(action: action) {
            HStack(spacing: PMSpace.s10) {
                artwork
                    .frame(width: MacHomeResumeTileMetrics.artworkSize, height: MacHomeResumeTileMetrics.artworkSize)
                VStack(alignment: .leading, spacing: 2) {
                    // 类别: 图标染这一类的颜色, 字用白色 —— 彩色小字在暖色背板上看不清。
                    HStack(spacing: 4) {
                        Image(systemName: space.systemImage)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                        Text(space.titleKey)
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .lineLimit(1)
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                playGlyph(tint: tint)
            }
            .padding(.vertical, PMSpace.s8)
            .padding(.leading, PMSpace.s8)
            .padding(.trailing, PMSpace.s10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(isHovered ? 0.15 : 0.08), in: shape)
            .overlay { shape.strokeBorder(Color.white.opacity(isHovered ? 0.2 : 0.1), lineWidth: 0.5) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            pmWithAnimation(.hover) { isHovered = hovering }
        }
        .help(Text("home_continue_spaces_hint"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("home_continue_spaces_hint"))
    }

    private func playGlyph(tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(isHovered ? tint : Color.white.opacity(0.16))
                .padding(3)
            if let progress {
                Circle()
                    .inset(by: 1)
                    .stroke(Color.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .inset(by: 1)
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "play.fill")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 1)
        }
        .frame(width: MacHomeResumeTileMetrics.playButtonSize, height: MacHomeResumeTileMetrics.playButtonSize)
        .accessibilityHidden(true)
    }
}

// MARK: - Books in progress

/// 「在听的书」: 还没听完的书, 封面下面一条进度。点封面从上次的位置接着听。
private struct MacHomeBooksStrip: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    /// 书架或书的右键菜单里挑过「在首页显示」的书;挑过就放挑中的,没挑过只列在听的书。
    @AppStorage(HomeSpotlightSelection.booksStorageKey) private var selectionRawValue = ""
    @AppStorage("spokenWord.shelf.order") private var shelfOrderRawValue = ""

    private var store: SpokenWordStore { SpokenWordStore.shared }

    var body: some View {
        let selection = HomeSpotlightSelection.decode(selectionRawValue)
        let entries = selection.isAutomatic ? inProgressBooks : pickedBooks(selection)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: PMSpace.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(LocalizedStringKey(selection.isAutomatic ? "home_books_in_progress_title" : "home_section_audiobooks"))
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(PMColor.text)
                    Spacer()
                    // 切到侧栏的「有声」项, 不 push 第二条路径 (同电台)。
                    Button {
                        NotificationCenter.default.post(name: .primuseSelectSpokenWord, object: nil)
                    } label: {
                        HStack(spacing: 3) {
                            Text("home_section_view_all")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PMColor.brand)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: PMSpace.m16) {
                        ForEach(entries) { entry in
                            bookTile(entry.book, songs: entry.songs)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .pmAppearFade(.contentAppear)
        }
    }

    private struct Entry: Identifiable {
        let book: SpokenWordBook
        let songs: [Song]
        var id: String { book.id }
    }

    private var inProgressBooks: [Entry] {
        Array(entries(for: allBooks.filter(\.isInProgress)).prefix(20))
    }

    /// 挑中的书,按挑选页定的排序;没挑的顺序时跟书架拖出来的顺序。
    private func pickedBooks(_ selection: HomeSpotlightSelection) -> [Entry] {
        let books = allBooks
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shelfOrdered = SpokenWordShelfOrder.orderedIDs(
            books.map(\.id),
            preferred: SpokenWordShelfOrder.decode(shelfOrderRawValue)
        ).compactMap { byID[$0] }
        let picked = selection.resolve(
            shelfOrdered,
            limit: HomeSectionLayoutPolicy.defaultItemCount(for: .audiobooks) * 2,
            id: \.id,
            name: \.title,
            lastListenedAt: \.lastListenedAt
        )
        return entries(for: picked)
    }

    /// 首页上的书:归档的不在其中。
    private var allBooks: [SpokenWordBook] {
        guard !library.spokenWordSongs.isEmpty else { return [] }
        _ = store.revision
        let items = library.spokenWordSongs.map { SpokenWordBookSupport.item(for: $0, store: store) }
        let archived = store.archivedBookIDs
        return SpokenWordBookGrouping.books(from: items).filter { !archived.contains($0.id) }
    }

    private func entries(for books: [SpokenWordBook]) -> [Entry] {
        guard !books.isEmpty else { return [] }
        let songsByID = Dictionary(
            library.spokenWordSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return books.compactMap { book -> Entry? in
            let songs = book.items.compactMap { songsByID[$0.id] }
            return songs.isEmpty ? nil : Entry(book: book, songs: songs)
        }
    }

    private func bookTile(_ book: SpokenWordBook, songs: [Song]) -> some View {
        let cover = songs.first { $0.id == book.resumeItemID } ?? songs[0]
        let isPlaying = songs.contains { $0.id == player.currentSong?.id }
        let tint = MacListeningSpaceStyle.color(for: .spokenWord)
        return Button {
            SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CachedArtworkView(
                    coverRef: cover.coverArtFileName, songID: cover.id,
                    size: 132, cornerRadius: PMRadius.m10,
                    sourceID: cover.sourceID, filePath: cover.filePath,
                    fileFormat: cover.fileFormat
                )
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                        .strokeBorder(isPlaying ? tint : .clear, lineWidth: 1.5)
                }
                MacBookProgressBar(fraction: book.fractionComplete, tint: tint)
                Text(verbatim: book.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: MacHomeBookText.detail(book))
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            .frame(width: 132, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pmHoverLift()
        .help(Text("spoken_word_continue"))
    }
}

/// 书的听书进度细条。首页「在听的书」与有声书页共用。
struct MacBookProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(PMColor.dividerStrong)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

private enum MacHomeBookText {
    /// 书的第二行: 在听的那一章 (多章时) + 还剩多久。
    static func detail(_ book: SpokenWordBook) -> String {
        var parts: [String] = []
        if book.chapterCount > 1, let item = book.resumeItem {
            parts.append(item.title)
        }
        if let remaining = book.remainingDuration, remaining > 0 {
            parts.append(String(
                format: String(localized: "spoken_word_remaining_format"),
                ChapterTimeFormatter.string(from: remaining)
            ))
        }
        if parts.isEmpty, let author = book.author {
            parts.append(author)
        }
        return parts.joined(separator: " · ")
    }
}
#endif
