import SwiftUI
import PrimuseKit

struct HomeView: View {
    var switchToSettingsTab: (() -> Void)?
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(CoverTintProvider.self) private var tintProvider

    private var hasContent: Bool { !library.visibleSongs.isEmpty }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        case 18..<22: return String(localized: "greeting_evening")
        default: return String(localized: "greeting_night")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    UpdateBanner()
                    if hasContent {
                        contentView
                    } else {
                        emptyView
                    }
                }
                .padding(.bottom, 100)
            }
            .navigationTitle("home_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
        }
    }

    // MARK: - Content

    // Section toggles. Hero is mandatory (always shown).
    @AppStorage("primuse.home.showStatsGlimpse") private var showStatsGlimpse: Bool = true
    @AppStorage("primuse.home.showForYou") private var showForYou: Bool = true
    @AppStorage("primuse.home.showTopArtists") private var showTopArtists: Bool = true
    @AppStorage("primuse.home.showRecentlyAdded") private var showRecentlyAdded: Bool = true
    @AppStorage("primuse.home.showContinueListening") private var showContinueListening: Bool = true

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            libraryHeroSection

            // Stats glimpse — shows up only after the user has been
            // listening for a bit. Tappable shortcut to the full
            // stats page.
            if showStatsGlimpse, let summary = statsGlimpse {
                statsGlimpseSection(summary)
            }

            // For You — local recommendation engine fed by
            // PlayHistoryStore. Hidden when no usable picks turn up
            // (e.g. brand-new install with zero history AND library
            // has no covered songs).
            if showForYou, !forYouPicks.isEmpty {
                forYouSection
            }

            // Top artists — replaces the alphabetical
            // library.artists.prefix(8). When PlayHistoryStore has
            // history we sort by play count; otherwise fall back to
            // alphabetical so the section isn't empty.
            if showTopArtists, !library.artists.isEmpty {
                artistsSection
            }

            // Recently added albums — kept untouched in this pass.
            if showRecentlyAdded, !library.albums.isEmpty {
                recentlyAddedAlbumsSection
            }

            // Continue listening — moved down + compacted. MiniPlayer
            // already covers "what was I just listening to", so the
            // home page only needs a quick re-entry list, not a hero
            // block.
            if showContinueListening, !recentSongs.isEmpty {
                continueListeningSection
            }
        }
        .task {
            refreshForYouPicks()
            // Kick off background tint extraction for the visible
            // cards. Idempotent — cached songs are skipped.
            tintProvider.prepare(forYouPicks)
            tintProvider.prepare(Array(recentSongs.prefix(15)))
        }
    }

    // MARK: - Stats Glimpse

    /// Quick "this week" summary card. Shown only when there's at
    /// least one play recorded in the last 7 days — empty stats
    /// would just look like clutter on a fresh install.
    private var statsGlimpse: PlayHistoryStore.Summary? {
        let summary = PlayHistoryStore.shared.summary(in: .week)
        return summary.totalPlays > 0 ? summary : nil
    }

    @ViewBuilder
    private func statsGlimpseSection(_ summary: PlayHistoryStore.Summary) -> some View {
        NavigationLink {
            ListeningStatsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("stats_title")
                        .font(.subheadline.weight(.semibold))
                    Text(String(
                        format: String(localized: "home_stats_glimpse_format"),
                        summary.totalPlays,
                        formattedDuration(summary.totalSec),
                        summary.activeDays
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    /// Compact "Xh Ym" / "Ym" formatter for the stats glimpse line.
    /// Uses DateComponentsFormatter so locale-correct strings come
    /// out for Chinese / English without extra plumbing.
    private func formattedDuration(_ totalSec: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = totalSec >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, totalSec)) ?? "—"
    }

    /// Soft gradient tinted background pulled from a song's cover.
    /// Falls back to ultra-thin material when the tint hasn't been
    /// extracted yet (or the cover failed to load) — gives every
    /// card a consistent shape without blocking on extraction.
    @ViewBuilder
    private func tintedCardBackground(for song: Song) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let tint = tintProvider.tint(forSongID: song.id) {
            shape.fill(LinearGradient(
                colors: [tint.opacity(0.22), tint.opacity(0.06)],
                startPoint: .top,
                endPoint: .bottom
            ))
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    // MARK: - Library Hero / Today's Pick

    /// 用户库里随机抽 4 首带封面的歌, 在 hero 右侧错落拼贴。每次进入页面
    /// 重新洗一组, 让 hero 有「在看自己音乐」的存在感。挑过封面的, 没封面
    /// 的歌跳过 (放占位太单调)。 Used as cold-start fallback when no
    /// `todaysPick` can be derived (e.g. zero playback history AND no
    /// covered library songs at all).
    @State private var heroCoverSongs: [Song] = []

    /// Daily-stable pick — yyyymmdd hash mod available pool. Stays
    /// the same all day so the user gets a "today's hero" feel
    /// without it shuffling on every refresh. Computed lazily from
    /// `forYouPicks` (which is itself a @State,driven by
    /// `refreshForYouPicks`); `recentSongs` is the cold-start
    /// fallback when forYou is empty.
    private var todaysPick: Song? {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        let stamp = (comps.year ?? 0) * 10000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
        let pool: [Song] = !forYouPicks.isEmpty ? forYouPicks
            : Array(recentSongs.filter { $0.coverArtFileName?.isEmpty == false }.prefix(20))
        guard !pool.isEmpty else { return nil }
        let idx = abs(stamp) % pool.count
        return pool[idx]
    }

    /// Hero 顶部:每天一首「今日精选」+ 大封面 + Play / Shuffle 按钮。
    /// 当没有任何可推荐内容时(冷启动 + 无封面歌曲),退回旧的 4 张封面拼贴
    /// 「一键开听整个资料库」版,保证空 library 也有可点击的入口。
    @ViewBuilder
    private var libraryHeroSection: some View {
        if let pick = todaysPick {
            todaysPickHero(pick: pick)
        } else {
            libraryMixHeroFallback
        }
    }

    @ViewBuilder
    private func todaysPickHero(pick: Song) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                CachedArtworkView(
                    coverRef: pick.coverArtFileName,
                    songID: pick.id,
                    size: 96, cornerRadius: 12,
                    sourceID: pick.sourceID,
                    filePath: pick.filePath
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text("home_todays_pick_title")
                        .font(.title3).fontWeight(.bold)
                        .lineLimit(1)
                    Text(pick.title)
                        .font(.subheadline).fontWeight(.medium)
                        .lineLimit(1)
                    Text(pick.artistName ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    playSong(pick)
                } label: {
                    Label("play", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())

                Button {
                    playLibrary(shuffled: true)
                } label: {
                    Label("shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(heroTintGradient(for: pick))
        }
        .padding(.horizontal, 16)
        .task(id: pick.id) {
            // Make sure the hero's tint gets extracted right away
            // even if it isn't part of the forYou row.
            tintProvider.prepare([pick])
        }
    }

    /// Hero background gradient: same per-song tint pattern as the
    /// list cards but stronger (Hero's bigger surface = bigger
    /// visual presence, can carry more saturation). Falls back to
    /// thinMaterial while extraction is pending.
    @ViewBuilder
    private func heroTintGradient(for song: Song) -> some View {
        if let tint = tintProvider.tint(forSongID: song.id) {
            LinearGradient(
                colors: [tint.opacity(0.32), tint.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Rectangle().fill(.thinMaterial)
        }
    }

    /// Cold-start: no songs eligible for the today's pick. Keep the
    /// old library-mix CTA so the user always has something to tap.
    private var libraryMixHeroFallback: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("home_library_mix_title")
                        .font(.title3)
                        .fontWeight(.bold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                heroCoverCollage
            }

            HStack(spacing: 10) {
                Button {
                    playLibrary(shuffled: true)
                } label: {
                    Label("shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())

                Button {
                    playLibrary(shuffled: false)
                } label: {
                    Label("play_all", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.thinMaterial)
        }
        .padding(.horizontal, 16)
        .task { refreshHeroCovers() }
    }

    /// 4 张封面错落叠放 — 用 ZStack 加旋转 + 偏移, 跟 Spotify Mix /
    /// Apple Music「For You」拼贴风格一致。封面来自最近添加 + 最近播放
    /// 的随机抽样, 每次 view 出现重洗一次。
    @ViewBuilder
    private var heroCoverCollage: some View {
        let size: CGFloat = 50
        let radius: CGFloat = 8
        ZStack {
            // 4 张依次叠, 角度 + 偏移让它们看起来散开
            ForEach(Array(heroCoverSongs.prefix(4).enumerated()), id: \.element.id) { index, song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: size,
                    cornerRadius: radius,
                    sourceID: song.sourceID,
                    filePath: song.filePath
                )
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .rotationEffect(.degrees(coverRotation(for: index)))
                .offset(coverOffset(for: index))
                .zIndex(Double(4 - index))
            }
            if heroCoverSongs.isEmpty {
                Image(systemName: "music.note.list")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110, height: 80)
    }

    private func coverRotation(for index: Int) -> Double {
        switch index {
        case 0: return -10
        case 1: return -3
        case 2: return 5
        case 3: return 12
        default: return 0
        }
    }

    private func coverOffset(for index: Int) -> CGSize {
        switch index {
        case 0: return CGSize(width: -28, height: 0)
        case 1: return CGSize(width: -10, height: -4)
        case 2: return CGSize(width: 10, height: 2)
        case 3: return CGSize(width: 28, height: 0)
        default: return .zero
        }
    }

    private func refreshHeroCovers() {
        // 优先最近播放, 不够再补最近添加, 都过滤出有 cover 的歌, 最后随机
        // 抽 4 首。每次 task 触发重洗 (即每次进首页)。
        let recent = library.recentlyPlayedSongs(limit: 30)
        let added = library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(60)
        var pool: [Song] = recent
        for song in added where !pool.contains(where: { $0.id == song.id }) {
            pool.append(song)
        }
        let withCover = pool.filter { $0.coverArtFileName?.isEmpty == false }
        heroCoverSongs = Array(withCover.shuffled().prefix(4))
    }

    // MARK: - For You

    /// Local recommendation engine output. Cached in @State so a body
    /// re-render (which fires whenever currentSong / library changes)
    /// doesn't reshuffle the picks under the user. Refreshed on .task
    /// when the home view re-mounts.
    @State private var forYouPicks: [Song] = []

    private var forYouSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home_for_you_title")
                .font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(forYouPicks, id: \.id) { song in
                        Button { playSong(song) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CachedArtworkView(
                                    coverRef: song.coverArtFileName,
                                    songID: song.id,
                                    size: 140, cornerRadius: 8,
                                    sourceID: song.sourceID,
                                    filePath: song.filePath
                                )
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                                Text(song.title).font(.caption).fontWeight(.medium).lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                                Text(song.artistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                            }
                            .padding(8)
                            .background(tintedCardBackground(for: song))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// Build the recommendation pool. Strategy:
    /// 1. Take top 5 most-played artists in the last 30 days.
    /// 2. For each, pick up to 2 of their songs the user *hasn't*
    ///    played in the last 30 days, with cover art available.
    /// 3. Cold start (no history yet, or not enough picks): top up
    ///    with random library songs that have covers and haven't
    ///    been played recently.
    /// All inputs come from `PlayHistoryStore` and `MusicLibrary` —
    /// no network calls.
    private func refreshForYouPicks() {
        let history = PlayHistoryStore.shared
        let topArtists = history.topArtists(in: .month, limit: 5)
        let recentlyPlayedIDs = Set(history.entries(in: .month).map(\.songID))

        var picks: [Song] = []
        var seen = Set<String>()
        let target = 12

        for ranked in topArtists {
            let candidates = library.visibleSongs
                .filter { song in
                    song.artistName == ranked.title
                        && !recentlyPlayedIDs.contains(song.id)
                        && song.coverArtFileName?.isEmpty == false
                }
                .shuffled()
            for song in candidates.prefix(2) where !seen.contains(song.id) {
                picks.append(song)
                seen.insert(song.id)
                if picks.count >= target { break }
            }
            if picks.count >= target { break }
        }

        if picks.count < 6 {
            // Cold-start / sparse-history fallback. Random covered
            // songs not played in the last 30 days — gives the user
            // something to explore even on day one.
            let extras = library.visibleSongs
                .filter {
                    !recentlyPlayedIDs.contains($0.id)
                        && $0.coverArtFileName?.isEmpty == false
                        && !seen.contains($0.id)
                }
                .shuffled()
            for song in extras {
                picks.append(song)
                seen.insert(song.id)
                if picks.count >= target { break }
            }
        }

        forYouPicks = picks
    }

    // MARK: - Continue Listening (formerly Recently Played)

    private var continueListeningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home_continue_listening")
                .font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            let songs = recentSongs
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(songs.prefix(15), id: \.id) { song in
                        Button { playSong(song) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CachedArtworkView(
                                    coverRef: song.coverArtFileName,
                                    songID: song.id,
                                    size: 100, cornerRadius: 8,
                                    sourceID: song.sourceID,
                                    filePath: song.filePath
                                )
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                Text(song.title).font(.caption).fontWeight(.medium).lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                                Text(song.artistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                            }
                            .padding(8)
                            .background(tintedCardBackground(for: song))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var recentSongs: [Song] {
        let recent = library.recentlyPlayedSongs(limit: 30)
        if !recent.isEmpty { return recent }
        return Array(library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(30))
    }

    // MARK: - Recently Added Albums

    private var recentlyAddedAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently_added").font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(library.recentlyAddedAlbums(limit: 10)) { album in
                        Button { playAlbum(album) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                let albumSong = library.songs(forAlbum: album.id).first
                                CachedArtworkView(
                                    coverRef: albumSong?.coverArtFileName,
                                    songID: albumSong?.id ?? "",
                                    size: 140, cornerRadius: 8,
                                    sourceID: albumSong?.sourceID,
                                    filePath: albumSong?.filePath
                                )
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                                Text(album.title).font(.caption).fontWeight(.medium).lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                                Text(album.artistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Top Artists

    /// Eight artists, ranked by recent listening — falls back to
    /// alphabetical library order when the user has no playback
    /// history yet (fresh install / no songs cleared the 30s
    /// scrobble threshold). Section title swaps between
    /// "frequently listened" and the generic "artists" depending
    /// which path produced the data.
    private var artistsSection: some View {
        let history = PlayHistoryStore.shared.topArtists(in: .month, limit: 8)
        let hasHistory = !history.isEmpty
        let displayed = topArtistsForHome(history: history)
        let titleKey: LocalizedStringKey = hasHistory ? "home_top_artists_title" : "tab_artists"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Custom concentric-rings glyph signals "this is
                // where your most-played artists live". SVG ships
                // with light/dark variants and bakes its own
                // gradients (multi-stop alpha rings, glow), so use
                // `.original` rendering — template mode would
                // flatten the gradient stack to a flat alpha mask.
                Image("TopArtistsGlyph")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                Text(titleKey).font(.title3).fontWeight(.bold)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(displayed) { artist in
                        NavigationLink(value: artist) {
                            VStack(spacing: 6) {
                                CachedArtworkView(artistID: artist.id, artistName: artist.name,
                                                  size: 80, cornerRadius: 40)
                                Text(artist.name).font(.caption).lineLimit(1).frame(width: 80)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// Map RankedItem (history) to the actual library Artist objects
    /// (NavigationLink needs the Artist value, not the ranked stub).
    /// Match by artist name. Top up with alphabetical leftovers when
    /// history doesn't fill the row.
    private func topArtistsForHome(history: [PlayHistoryStore.RankedItem]) -> [Artist] {
        guard !history.isEmpty else {
            return Array(library.artists.prefix(8))
        }
        let byName = Dictionary(library.artists.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Artist] = []
        var seen = Set<String>()
        for item in history {
            if let a = byName[item.title], !seen.contains(a.id) {
                result.append(a)
                seen.insert(a.id)
            }
        }
        if result.count < 8 {
            for a in library.artists where !seen.contains(a.id) {
                result.append(a)
                seen.insert(a.id)
                if result.count >= 8 { break }
            }
        }
        return result
    }



    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 24)
            // Custom illustration (vinyl + waveform + aurora glow)
            // replaces the previous SF Symbol. Image fills its own
            // square with a deep-navy / off-white background
            // depending on luminosity, so it carries its own canvas
            // — clip to a rounded rect so it doesn't bleed into the
            // page background.
            Image("EmptyStateNoSources")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            VStack(spacing: 8) {
                Text("welcome_title").font(.title2).fontWeight(.bold)
                Text("home_empty_desc").font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Button { switchToSettingsTab?() } label: {
                Label("manage_sources", systemImage: "externaldrive.badge.plus")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
            }.buttonStyle(.borderedProminent).padding(.horizontal, 40)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func playAlbum(_ album: Album) {
        // Get songs for the tapped album directly
        var queueSongs = library.songs(forAlbum: album.id)

        // Build queue: tapped album's songs first, then supplement
        if queueSongs.count < 20 {
            let existingIDs = Set(queueSongs.map(\.id))
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }.shuffled()
            queueSongs.append(contentsOf: extra)
        }
        queueSongs = queueSongs.filteredPlayable()
        // The playable filter may drop the album's first track (cloud
        // Phase A bare song). Pull `firstSong` from the filtered list so
        // we never hand the player an entry that isn't in its queue.
        guard let firstSong = queueSongs.first else { return }

        player.shuffleEnabled = false
        player.setQueue(queueSongs, startAt: 0)
        Task { await player.play(song: firstSong) }
    }

    private func playSong(_ song: Song) {
        plog("🏠 playSong TAPPED: '\(song.title)' id=\(song.id.prefix(12)) path=\(song.filePath)")

        // Build queue from recently played songs, supplemented by library
        var queueSongs = library.recentlyPlayedSongs(limit: 50)
        plog("🏠 recentlyPlayed queue: \(queueSongs.count) songs, first3=\(queueSongs.prefix(3).map(\.title))")

        // If tapped song isn't in recent list, prepend it
        if !queueSongs.contains(where: { $0.id == song.id }) {
            queueSongs.insert(song, at: 0)
            plog("🏠 song not in recent, prepended")
        }

        // Supplement with library songs if queue is too small
        if queueSongs.count < 20 {
            let existingIDs = Set(queueSongs.map(\.id))
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }
            queueSongs.append(contentsOf: extra)
        }

        // Drop non-playable entries so auto-advance can't land on a Phase A
        // bare song. The tapped song itself was already filtered to
        // playable by SongRowView's tap intercept; if it slipped through
        // (recently-played list with stale data) bail rather than crash
        // on an empty queue or play a song that isn't in the queue.
        queueSongs = queueSongs.filteredPlayable()
        guard let startIndex = queueSongs.firstIndex(where: { $0.id == song.id }) else {
            plog("🏠 tapped song dropped by playable filter — skipping")
            return
        }
        plog("🏠 setQueue: \(queueSongs.count) songs, startIndex=\(startIndex), songAtIndex='\(queueSongs[startIndex].title)'")
        player.shuffleEnabled = false
        player.setQueue(queueSongs, startAt: startIndex)
        let resolved = queueSongs[startIndex]
        plog("🏠 calling player.play(song: '\(resolved.title)')")
        Task { await player.play(song: resolved) }
    }

    private func playLibrary(shuffled: Bool) {
        // Skip cloud songs that haven't been backfilled yet — they have no
        // duration / cover / metadata and would land in the queue with a
        // blank progress bar. Once backfill catches up they become eligible.
        let candidates = library.visibleSongs.filteredPlayable()
        guard !candidates.isEmpty else { return }

        let queueSongs = shuffled ? candidates.shuffled() : candidates
        guard let firstSong = queueSongs.first else { return }

        player.shuffleEnabled = false
        player.setQueue(queueSongs, startAt: 0)
        Task { await player.play(song: firstSong) }
    }
}

