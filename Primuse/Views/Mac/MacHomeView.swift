#if os(macOS)
import SwiftUI
import AppKit
import PrimuseKit

@MainActor
private final class MacHomeRefreshCoordinator {
    var debounceTask: Task<Void, Never>?
    var computeTask: Task<Void, Never>?

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
    let onRevisionChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: library.searchRevision) { _, _ in onRevisionChange() }
    }
}

/// 1.6 重设计后的 macOS 首页 — Hero (AmbientBackdrop + 封面马赛克 + 欢迎语) →
/// 库健康度 / 源状态 双卡 → 4 节点 pipeline → 最近添加专辑 → 最近播放 → 艺术家。
struct MacHomeView: View {
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
    @Environment(MusicIntelligenceService.self) private var intelligence
    @AppStorage("primuse.home.showRadio") private var showRadio = true
    @AppStorage("primuse.ai.recommendationScene.v1")
    private var recommendationSceneRawValue = AIRecommendationScene.automatic.rawValue
    @State private var selectedRadioID: String?
    @State private var pendingInsecureStation: RadioStation?
    @State private var aiRecommendation = AIRecommendationViewModel()
    @State private var recommendationHistoryRevision = 0
    @State private var recommendationClockRevision = 0

    // 派生聚合缓存 —— mosaicSongs(全库 sort)、heroStats(全库 reduce)、三个 ratio
    // (各一次全库 filter) 都很重。首页同时观察 scanStates(每扫一个文件就变)和
    // backfill 计数, 扫描/回填期间这些属性高频变化, 每次 body 求值都把全库遍历
    // 在主线程重跑一遍 → 万首级曲库下首页卡顿。把结果缓存到 @State, 仅在库内容
    // (searchRevision)或播放历史变化时重算一次, 跟 iOS HomeView / MacSimilarSongsPopover
    // 一致。
    @State private var derived = DerivedSnapshot()
    @State private var hasPreparedDerivedSnapshot = false
    @State private var activeSection: HomeSectionDestination?
    // 合并 searchRevision 风暴 —— MusicLibrary 在扫描的每个 upsert 批次都 bump
    // searchRevision, 不去抖会触发几十次全库重算。cancel + 重启计时, 只在最后
    // 一次 revision 落定后重算。
    @State private var refreshCoordinator = MacHomeRefreshCoordinator()
    private static let derivedRefreshDebounce: Duration = .milliseconds(300)

    private struct DerivedSnapshot: Sendable {
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

    private var hasContent: Bool { derived.songCount > 0 }

    private var homePresentationState: DeferredContentPresentationState {
        DeferredContentPresentationPolicy.resolve(
            isPrepared: hasPreparedDerivedSnapshot,
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
            MacHomeLibraryRevisionObserver {
                scheduleDerivedRefresh()
            }
        }
        .task {
            refreshDerivedIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in
            recommendationHistoryRevision &+= 1
            refreshDerived()
        }
        .onReceive(
            Timer.publish(every: 15 * 60, on: .main, in: .common).autoconnect()
        ) { _ in
            recommendationClockRevision &+= 1
        }
        .onChange(of: intelligence.settingsStore.recommendationsEnabled) { _, _ in
            refreshDerived()
        }
        .onDisappear {
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

    @ViewBuilder
    private func resolvedDashboardContent(hasContent: Bool) -> some View {
        heroSection
        if showRadio,
           player.isLiveRadio,
           let currentStation = player.currentRadioStation {
            radioNowPlayingStrip(currentStation)
        }

        if hasContent {
            statsRow
            if intelligence.shouldShowRemoteRecommendations,
               !derived.recommendationResults.isEmpty {
                recommendationSection
            }
            pipelineSection
            recentlyAddedSection
            recentlyPlayedSection
            if showRadio, !radioStationsStore.stations.isEmpty {
                radioSpotlightSection
            }
            if !derived.artists.isEmpty {
                artistsSection
            }
        } else {
            emptyState
            if showRadio, !radioStationsStore.stations.isEmpty {
                radioSpotlightSection
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
                .frame(height: 296)
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
    private func scheduleDerivedRefresh() {
        refreshCoordinator.debounceTask?.cancel()
        refreshCoordinator.debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.derivedRefreshDebounce)
            guard !Task.isCancelled else { return }
            refreshDerived()
        }
    }

    /// 首次出现时如果缓存还没填(songCount 与当前 visibleSongs 不一致)就算一次,
    /// 避免每次回到首页都重跑全库。
    private func refreshDerivedIfNeeded() {
        if !hasPreparedDerivedSnapshot || derived.songCount != library.visibleSongs.count {
            refreshDerived()
        }
    }

    /// 全库聚合的唯一计算入口。主线程只拍 COW 快照，遍历、分组和排序都在
    /// utility task 中执行，避免刷新落在窗口滚动/导航帧上。
    private func refreshDerived() {
        let songs = library.visibleSongs
        let albums = library.visibleAlbums
        let artists = library.visibleArtists
        let recentlyPlayed = library.recentlyPlayedSongs(limit: 100)
        let recommendationInput = MusicDiscoveryEngine.recommendationInput(in: library)

        refreshCoordinator.computeTask?.cancel()
        refreshCoordinator.computeTask = Task { @MainActor in
            let snapshot = await Task.detached(priority: .utility) {
                Self.makeDerivedSnapshot(
                    songs: songs,
                    albums: albums,
                    artists: artists,
                    recentlyPlayed: recentlyPlayed,
                    recommendationInput: recommendationInput
                )
            }.value
            guard !Task.isCancelled else { return }
            derived = snapshot
            hasPreparedDerivedSnapshot = true
        }
    }

    private nonisolated static func makeDerivedSnapshot(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        recentlyPlayed: [Song],
        recommendationInput: MusicDiscoveryEngine.RecommendationInput
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
        snapshot.recentlyAddedAlbums = albums.sorted {
            (latestDateByAlbum[$0.id] ?? .distantPast) > (latestDateByAlbum[$1.id] ?? .distantPast)
        }

        var mosaicPool = recentlyPlayed
        var seenIDs = Set(mosaicPool.map(\.id))
        for song in sortedByAdded.prefix(40) where seenIDs.insert(song.id).inserted {
            mosaicPool.append(song)
        }
        let covered = mosaicPool.filter { $0.coverArtFileName?.isEmpty == false }
        snapshot.mosaicSongs = Array((covered.isEmpty ? mosaicPool : covered).prefix(6))
        snapshot.recommendationResults = MusicDiscoveryEngine.dailyRecommendations(
            from: recommendationInput,
            limit: 12
        )
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
    /// 1.6 重设计后用它替代静态 "猿音", 把首页从"应用展示页"变成"用户专属仪表盘"。
    private var heroNarrative: String {
        let count = derived.songCount
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
        let albums = derived.albumCount
        let artists = derived.artistCount
        let totalSec = derived.totalDurationSec
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
        ZStack {
            // 1. 卡片底色 — 暗色模式必须明显高于窗口 bg, 否则跟背景融在一起。设计里 hero
            //    是一张清晰可见的卡。先铺 bgElev, 再叠 AmbientBackdrop 给暖色调。
            Button(action: openLibrarySongs) {
                RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                    .fill(PMColor.bgElev)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("tab_songs"))
            .accessibilityHint(Text("library_browse"))
            .accessibilityIdentifier("macHomeLibraryHeroOpenSongs")

            // 2. Hero 的 ambient 用固定 brand 暖色, 不跟 theme.accentColor 走 — 设计稿
            //    里 hero 一直是温暖的 pink/cream 调, 跟当前播放歌曲色相无关。
            //    AmbientBackdrop 内部用 blur + offset 把色圈推到 Hero 边界外, 不依靠
            //    内部 clipShape (drawingGroup 栅格化会让 clip 失效), 改在最外层 ZStack
            //    统一裁剪。
            AmbientBackdrop(
                accent: PMColor.brand,
                darkAccent: PMColor.brand.opacity(0.55),
                strength: 0.72
            )
            .allowsHitTesting(false)

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
            .padding(.horizontal, PMSpace.xxl)
            .padding(.vertical, PMSpace.l24)
        }
        .frame(height: 296)
        // 3. 整张 Hero 强制裁剪到圆角矩形 — AmbientBackdrop 的 blur 圈会越界, 必须在
        //    最外层统一切, 否则暖色会"漏"到 Hero 上下方区域。
        .clipShape(RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous))
        // 4. 边框 + 收紧的浮动阴影 (radius 18→8, 防止 shadow 把卡片边缘的暖色又扩散
        //    回外面)。
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
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

            radioStationGrid
        }
        .onChange(of: player.currentRadioStation?.id) { _, stationID in
            guard let stationID,
                  radioStationsStore.stations.contains(where: { $0.id == stationID }) else { return }
            selectedRadioID = stationID
        }
    }

    /// 电台改成固定宽度的卡片网格。原来是一张 `maxWidth: .infinity` 的横幅，
    /// 内容只占左边一小块，窗口越宽右边空出的渐变越大。网格跟下面的
    /// 「资料库健康度 / 音乐源状态」一致：卡宽固定，宽窗口自动多排几列。
    private var radioStationGrid: some View {
        LazyVGrid(
            // 下限给到 200 —— 电台名普遍比歌名长(常带频率/地区后缀)，
            // 再窄就只能显示三四个字加省略号了。
            columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: PMSpace.m14)],
            alignment: .leading,
            spacing: PMSpace.m14
        ) {
            ForEach(radioStationsStore.stations.prefix(4)) { station in
                radioStationTile(station)
            }
        }
    }

    private func radioStationTile(_ station: RadioStation) -> some View {
        let isCurrent = player.currentRadioStation?.id == station.id
        let isPlaying = isCurrent && (player.isPlaying || player.isLoading)

        return Button {
            selectedRadioID = station.id
            toggleRadio(station)
        } label: {
            VStack(alignment: .leading, spacing: PMSpace.s10) {
                RadioStationArtworkContent(station: station, decodeSize: 260)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        radioTileBadge(isPlaying: isPlaying)
                            .padding(PMSpace.s)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(PMFont.cardTitleS)
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)

                    Text(isCurrent
                         ? (player.radioMetadataTitle ?? station.playbackSubtitle)
                         : station.playbackSubtitle)
                        .font(PMFont.caption)
                        .foregroundStyle(isCurrent ? PMColor.brand : PMColor.textMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(PMSpace.s10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pmCard(cornerRadius: PMRadius.l14)
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l14, style: .continuous)
                .strokeBorder(isCurrent ? PMColor.brand.opacity(0.55) : .clear, lineWidth: 1)
        }
    }

    /// 只有真在播才亮红点 LIVE —— 无条件亮着的话，没播放时卡片也在说
    /// "正在直播"，跟底部播放条自相矛盾。
    @ViewBuilder
    private func radioTileBadge(isPlaying: Bool) -> some View {
        HStack(spacing: 5) {
            if isPlaying {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("LIVE")
            } else {
                Image(systemName: "radio")
                    .font(.system(size: 9, weight: .semibold))
                Text("radio_title")
            }
        }
        .font(.system(size: 9.5, weight: .bold))
        .tracking(0.8)
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.38), in: Capsule())
    }

    private func toggleRadio(_ station: RadioStation) {
        if let url = station.url,
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

    private var mosaicSongs: [Song] { derived.mosaicSongs }

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
                    metric(value: derived.songCount, label: "tab_songs")
                    metric(value: derived.albumCount, label: "tab_albums")
                    metric(value: derived.artistCount, label: "tab_artists")
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

    // MARK: - Scene recommendations

    private var recommendationScene: AIRecommendationScene {
        AIRecommendationScene(rawValue: recommendationSceneRawValue) ?? .automatic
    }

    private var displayedRecommendationResults: [MusicDiscoveryResult] {
        let byID = Dictionary(
            derived.recommendationResults.map { ($0.song.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return aiRecommendation
            .orderedSongs(from: derived.recommendationResults.map(\.song))
            .compactMap { byID[$0.id] }
    }

    private var recommendationRefreshKey: String {
        return [
            recommendationSceneRawValue,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
            String(recommendationHistoryRevision),
            String(recommendationClockRevision),
            derived.recommendationResults.map(\.song.id).joined(separator: "|"),
        ].joined(separator: "#")
    }

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ai_recommendation_home_title")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(PMColor.text)
                    if let summary = aiRecommendation.summaryText {
                        Text(summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(PMColor.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    if case .loading = aiRecommendation.feedback {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: recommendationStatusIcon)
                    }
                    Text(aiRecommendation.statusText)
                        .lineLimit(1)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(recommendationStatusColor)
            }

            HStack(spacing: 7) {
                ForEach(AIRecommendationScene.allCases, id: \.self) { scene in
                    Button {
                        recommendationSceneRawValue = scene.rawValue
                    } label: {
                        Text(scene.localizedName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(
                                recommendationScene == scene ? Color.white : PMColor.textMuted
                            )
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                recommendationScene == scene ? PMColor.brand : PMColor.glassBtn,
                                in: Capsule()
                            )
                            .overlay {
                                if recommendationScene != scene {
                                    Capsule().strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        recommendationScene == scene ? .isSelected : []
                    )
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(displayedRecommendationResults) { result in
                        Button { playSong(result.song) } label: {
                            recommendationCard(result)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .padding(.vertical, 2)
                .animation(.snappy(duration: 0.28), value: aiRecommendation.orderedSongIDs)
            }
        }
        .task(id: recommendationRefreshKey) {
            await aiRecommendation.refresh(
                scene: recommendationScene,
                candidates: derived.recommendationResults.map(\.song),
                using: intelligence
            )
        }
    }

    private func recommendationCard(_ result: MusicDiscoveryResult) -> some View {
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
                if let reason = aiRecommendation.reason(for: song.id) {
                    Label(reason, systemImage: "sparkles")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                        .lineLimit(2)
                } else {
                    Text(String(
                        localized: String.LocalizationValue(
                            result.primaryReason.localizationKey
                        )
                    ))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                }
                Text(song.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(
                    library.artistDisplayName(for: song)
                        ?? String(localized: "unknown_artist")
                )
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
        .overlay(alignment: .leading) {
            if aiRecommendation.reason(for: song.id) != nil {
                RoundedRectangle(cornerRadius: 2)
                    .fill(PMColor.brand)
                    .frame(width: 3)
                    .padding(.vertical, 10)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var recommendationStatusIcon: String {
        switch aiRecommendation.feedback {
        case .success: "sparkles"
        case .needsConsent: "hand.raised.fill"
        case .localFallback: "arrow.uturn.backward.circle"
        case .idle: "music.note.list"
        case .loading: "sparkles"
        }
    }

    private var recommendationStatusColor: Color {
        switch aiRecommendation.feedback {
        case .success: PMColor.brand
        case .needsConsent, .localFallback: PMColor.warn
        case .idle, .loading: PMColor.textFaint
        }
    }

    // MARK: - Recently added (6-col 140pt grid)

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "recently_added",
                          subtitle: "home_recently_added_subtitle",
                          destination: .recentlyAdded)

            LazyVGrid(
                columns: Array(repeating: GridItem(.adaptive(minimum: 130, maximum: 160),
                                                    spacing: PMSpace.m16, alignment: .top),
                               count: 1),
                alignment: .leading,
                spacing: PMSpace.l
            ) {
                ForEach(derived.recentlyAddedAlbums.prefix(12)) { album in
                    Button { playAlbum(album) } label: {
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
        derived.recentSongs
    }

    // MARK: - Artists (horizontal scroll)

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "tab_artists",
                          subtitle: "home_artists_subtitle",
                          destination: .artists)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PMSpace.l) {
                    ForEach(derived.artists.prefix(14)) { artist in
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
                    withAnimation(.snappy(duration: 0.22)) {
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
        }
    }

    private func recentlyAddedAllView(onBack: @escaping () -> Void) -> some View {
        let albums = derived.recentlyAddedAlbums

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                homeCollectionHeader(
                    eyebrow: "library_title",
                    title: "recently_added",
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
        let songs = derived.recentSongs

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
                detail: "\(derived.artists.count) \(String(localized: "artists_count"))",
                onBack: onBack
            )
            .padding(.vertical, 24)

            Rectangle()
                .fill(PMColor.divider)
                .frame(height: 0.5)

            ArtistListView(artists: derived.artists)
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
        withAnimation(.snappy(duration: 0.22)) {
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

    private var coverRatio: Double { ratio(count: derived.coverCount) }
    private var lyricsRatio: Double { ratio(count: derived.lyricsCount) }
    private var playableRatio: Double { ratio(count: derived.playableCount) }

    private func ratio(count: Int) -> Double {
        guard derived.songCount > 0 else { return 0 }
        return Double(count) / Double(derived.songCount)
    }

    // MARK: - Actions

    private func playAlbum(_ album: Album) {
        var queue = library.songs(forAlbum: album.id)
        if queue.count < 20 {
            let existingIDs = Set(queue.map(\.id))
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }.shuffled()
            queue.append(contentsOf: extra)
        }
        queue = queue.filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        var queue = library.recentlyPlayedSongs(limit: 50)
        if !queue.contains(where: { $0.id == song.id }) { queue.insert(song, at: 0) }
        if queue.count < 20 {
            let existingIDs = Set(queue.map(\.id))
            queue.append(contentsOf: library.visibleSongs.filter { !existingIDs.contains($0.id) })
        }
        queue = queue.filteredPlayable()
        guard let startIndex = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: startIndex)
        SiriMediaInteractionDonor.donate(song: queue[startIndex])
        Task { await player.play(song: queue[startIndex]) }
    }

    private func playLibrary(shuffled: Bool) {
        let candidates = library.visibleSongs.filteredPlayable()
        guard !candidates.isEmpty else { return }
        let queue = shuffled ? candidates.shuffled() : candidates
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
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
            node("externaldrive.fill", "Sources",
                 statusText: "\(enabledSourcesCount) \(Lz("online"))",
                 isActive: !sourcesStore.sources.isEmpty)
            connector(isActive: !activeScans.isEmpty || hasContent)
            node("arrow.triangle.2.circlepath", "Scan",
                 statusText: activeScans.isEmpty ? Lz("No Scan") : "\(activeScans.count) \(Lz("in progress"))",
                 isActive: !activeScans.isEmpty || hasContent)
            connector(isActive: hasContent)
            node("tag.fill", "Metadata",
                 statusText: scraperService.isScraping
                    ? "\(scraperService.processedCount)/\(scraperService.totalCount) \(Lz("in progress"))"
                    : (backfill.remainingCount(forSource: nil) == 0
                        ? Lz("Done")
                        : "\(backfill.remainingCount(forSource: nil)) \(Lz("pending backfill"))"),
                 isActive: hasContent || scraperService.isScraping)
            connector(isActive: player.currentSong != nil)
            node("play.fill", "Listen",
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

    private func node(_ icon: String, _ title: String, statusText: String, isActive: Bool) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 52, height: 52)
                .background(isActive ? PMColor.brand.opacity(0.18) : PMColor.brand.opacity(0.10),
                            in: .rect(cornerRadius: 12, style: .continuous))
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
#endif
