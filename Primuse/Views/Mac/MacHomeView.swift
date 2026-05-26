#if os(macOS)
import SwiftUI
import PrimuseKit

/// 1.6 重设计后的 macOS 首页 — Hero (AmbientBackdrop + 封面马赛克 + 欢迎语) →
/// 库健康度 / 源状态 双卡 → 4 节点 pipeline → 最近添加专辑 → 最近播放 → 艺术家。
struct MacHomeView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(ThemeService.self) private var theme
    @Environment(AppUpdateChecker.self) private var updateChecker

    private var hasContent: Bool { !library.visibleSongs.isEmpty }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: PMSpace.xl) {
                if updateChecker.availableUpdate != nil {
                    updateBanner
                }

                heroSection

                if hasContent {
                    statsRow
                    pipelineSection
                    recentlyAddedSection
                    recentlyPlayedSection
                    if !library.visibleArtists.isEmpty {
                        artistsSection
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.top, PMSpace.xl)
            .padding(.bottom, 104)
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    // MARK: - Update banner

    private var updateBanner: some View {
        HStack(spacing: PMSpace.m) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PMColor.brand)

            VStack(alignment: .leading, spacing: 1) {
                if let v = updateChecker.availableUpdate?.version {
                    Text(String(format: String(localized: "update_banner_title_format"), v))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                }
                Text("update_banner_subtitle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                updateChecker.openAppStore()
            } label: {
                Text("update_banner_action")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(PMColor.brand, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                updateChecker.snooze()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("later"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .pmCard(cornerRadius: PMRadius.m10)
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
        let count = library.visibleSongs.count
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
        let albums = library.visibleAlbums.count
        let artists = library.visibleArtists.count
        let totalSec = library.visibleSongs.reduce(0.0) { $0 + max(0, $1.duration) }
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
            AmbientBackdrop(
                accent: theme.accentColor,
                darkAccent: theme.darkAccent,
                strength: 0.85
            )
            .clipShape(RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous))

            HStack(alignment: .center, spacing: PMSpace.xl) {
                coverMosaic
                    .frame(width: 200, height: 200)

                VStack(alignment: .leading, spacing: PMSpace.m16) {
                    Text(verbatim: greeting)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))

                    Text(verbatim: heroNarrative)
                        .font(.system(size: 36, weight: .bold))
                        .tracking(-0.6)
                        .lineSpacing(2)
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(verbatim: heroStats)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: 600, alignment: .leading)

                    HStack(spacing: PMSpace.s10) {
                        Button { playLibrary(shuffled: false) } label: {
                            Label("play_all", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(PMColor.brand, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasContent)
                        .shadow(color: PMColor.brand.opacity(0.4), radius: 8, y: 3)

                        Button { playLibrary(shuffled: true) } label: {
                            Label("shuffle", systemImage: "shuffle")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(Color.white.opacity(0.18), in: Capsule())
                                .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasContent)
                    }
                    .padding(.top, PMSpace.xs)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PMSpace.xxl)
            .padding(.vertical, PMSpace.xl)
        }
        .frame(height: 264)
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
            } else if mosaicSongs.count == 1, let song = mosaicSongs.first {
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    cornerRadius: PMRadius.l,
                    sourceID: song.sourceID, filePath: song.filePath
                )
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                    spacing: 6
                ) {
                    ForEach(Array(mosaicSongs.prefix(6).enumerated()), id: \.element.id) { _, song in
                        CachedArtworkView(
                            coverRef: song.coverArtFileName, songID: song.id,
                            cornerRadius: PMRadius.m,
                            sourceID: song.sourceID, filePath: song.filePath
                        )
                        .aspectRatio(1, contentMode: .fit)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            }
        }
    }

    private var mosaicSongs: [Song] {
        let recent = library.recentlyPlayedSongs(limit: 12)
        let added = library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(40)
        var pool = recent
        for song in added where !pool.contains(where: { $0.id == song.id }) {
            pool.append(song)
        }
        let covered = pool.filter { $0.coverArtFileName?.isEmpty == false }
        return Array((covered.isEmpty ? pool : covered).prefix(6))
    }

    // MARK: - Stats row (库健康度 + 源状态)

    private var statsRow: some View {
        HStack(alignment: .top, spacing: PMSpace.m16) {
            libraryHealthCard
            sourceStatusCard
        }
    }

    private var libraryHealthCard: some View {
        homeCard(title: "home_health_title", spec: "LIB-09") {
            VStack(alignment: .leading, spacing: PMSpace.m) {
                HStack(spacing: PMSpace.m) {
                    metric(value: library.visibleSongs.count, label: "tab_songs")
                    metric(value: library.visibleAlbums.count, label: "tab_albums")
                    metric(value: library.visibleArtists.count, label: "tab_artists")
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
        homeCard(title: "home_sources_title", spec: "SRC · LIB-14") {
            VStack(alignment: .leading, spacing: PMSpace.m) {
                HStack(spacing: PMSpace.m) {
                    metric(value: enabledSourcesCount, label: "home_enabled_sources")
                    metric(value: activeScans.count, label: "home_active_scans")
                    metric(value: backfill.remainingCount(forSource: nil), label: "home_pending_details")
                }
                Rectangle().fill(PMColor.divider).frame(height: 0.5).padding(.vertical, 2)
                if let scan = activeScans.first {
                    VStack(alignment: .leading, spacing: 6) {
                        scanProgressBar(scan)
                        Text(scan.currentFile.isEmpty ? String(localized: "scan_in_progress") : scan.currentFile)
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textFaint)
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(PMColor.ok)
                        Text("home_no_scans")
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                    }
                }
            }
        }
    }

    private func homeCard<C: View>(title: LocalizedStringKey, spec: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: PMSpace.m14) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.3)
                Spacer()
                Text(spec)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
            }
            content()
        }
        .padding(PMSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PMColor.divider)
                Capsule().fill(PMColor.brand).frame(width: geo.size.width * pct)
            }
        }
        .frame(height: 5)
    }

    // MARK: - Pipeline

    private var pipelineSection: some View {
        HStack(spacing: PMSpace.s8) {
            pipelineNode("externaldrive.fill", "Sources",
                         statusText: "\(enabledSourcesCount) 在线",
                         isActive: !sourcesStore.sources.isEmpty)
            pipelineConnector(isActive: !activeScans.isEmpty || hasContent)
            pipelineNode("arrow.triangle.2.circlepath", "Scan",
                         statusText: activeScans.isEmpty ? "无扫描" : "\(activeScans.count) 进行中",
                         isActive: !activeScans.isEmpty || hasContent)
            pipelineConnector(isActive: hasContent)
            pipelineNode("tag.fill", "Metadata",
                         statusText: backfill.remainingCount(forSource: nil) == 0
                             ? "已完成"
                             : "\(backfill.remainingCount(forSource: nil)) 待回填",
                         isActive: hasContent)
            pipelineConnector(isActive: player.currentSong != nil)
            pipelineNode("play.fill", "Listen",
                         statusText: player.currentSong?.title ?? "未播放",
                         isActive: player.currentSong != nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .pmCard(cornerRadius: PMRadius.l)
    }

    private func pipelineNode(_ icon: String, _ title: String,
                              statusText: String, isActive: Bool) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 38, height: 38)
                .background(
                    (isActive ? PMColor.brand.opacity(0.16) : PMColor.glassBtn),
                    in: .rect(cornerRadius: PMRadius.m10)
                )
            Text(verbatim: title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text(statusText)
                .font(.system(size: 10.5))
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

    // MARK: - Recently added (6-col 140pt grid)

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "recently_added",
                          subtitle: "home_recently_added_subtitle",
                          showAll: false)

            LazyVGrid(
                columns: Array(repeating: GridItem(.adaptive(minimum: 130, maximum: 160),
                                                    spacing: PMSpace.m16, alignment: .top),
                               count: 1),
                alignment: .leading,
                spacing: PMSpace.l
            ) {
                ForEach(library.recentlyAddedAlbums(limit: 12)) { album in
                    Button { playAlbum(album) } label: {
                        albumCard(album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func albumCard(_ album: Album) -> some View {
        let song = library.songs(forAlbum: album.id).first
        return VStack(alignment: .leading, spacing: 8) {
            CachedArtworkView(
                coverRef: song?.coverArtFileName,
                songID: song?.id ?? "",
                cornerRadius: PMRadius.m,
                sourceID: song?.sourceID,
                filePath: song?.filePath
            )
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
                          showAll: false)

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
                filePath: song.filePath
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(song.artistName ?? "")
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
        let recent = library.recentlyPlayedSongs(limit: 18)
        if !recent.isEmpty { return recent }
        return Array(library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(18))
    }

    // MARK: - Artists (horizontal scroll)

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            sectionHeader(title: "tab_artists",
                          subtitle: "home_artists_subtitle",
                          showAll: false)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PMSpace.l) {
                    ForEach(library.visibleArtists.prefix(14)) { artist in
                        NavigationLink(value: artist) {
                            artistChip(artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func artistChip(_ artist: Artist) -> some View {
        VStack(spacing: 8) {
            CachedArtworkView(
                artistID: artist.id,
                artistName: artist.name,
                size: 92,
                cornerRadius: 46
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            Text(artist.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text("\(library.songs(forArtist: artist.id).count)")
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
        }
        .frame(width: 100)
    }

    // MARK: - Section header

    private func sectionHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey?, showAll: Bool = false) -> some View {
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
            if showAll {
                Text("home_section_view_all")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.brand)
            }
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

    private var enabledSourcesCount: Int { sourcesStore.sources.filter(\.isEnabled).count }

    private var coverRatio: Double { ratio(count: library.visibleSongs.filter { $0.coverArtFileName?.isEmpty == false }.count) }
    private var lyricsRatio: Double { ratio(count: library.visibleSongs.filter { $0.lyricsFileName?.isEmpty == false }.count) }
    private var playableRatio: Double { ratio(count: library.visibleSongs.filter(\.isPlayable).count) }

    private func ratio(count: Int) -> Double {
        guard !library.visibleSongs.isEmpty else { return 0 }
        return Double(count) / Double(library.visibleSongs.count)
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
#endif
