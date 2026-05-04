import SwiftUI
import PrimuseKit

struct HomeView: View {
    var switchToSettingsTab: (() -> Void)?
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

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

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            libraryHeroSection

            // Recently played
            recentlyPlayedSection

            // Recently added albums
            if !library.albums.isEmpty {
                recentlyAddedAlbumsSection
            }

            // Artists
            if !library.artists.isEmpty {
                artistsSection
            }
        }
    }

    // MARK: - Library Hero

    /// 用户库里随机抽 4 首带封面的歌, 在 hero 右侧错落拼贴。每次进入页面
    /// 重新洗一组, 让 hero 有「在看自己音乐」的存在感。挑过封面的, 没封面
    /// 的歌跳过 (放占位太单调)。
    @State private var heroCoverSongs: [Song] = []

    /// 顶部欢迎区 —— 左侧 问候 + 标题 + 操作按钮, 右侧错落叠 4 张封面 (从
    /// 库里抽), 背景用 thinMaterial 跟系统融合。比纯按钮丰富, 又比之前的
    /// 大渐变卡片低调。「随机播放」突出 (主色填色胶囊), 「播放全部」次要
    /// (描边)。
    private var libraryHeroSection: some View {
        VStack(spacing: 14) {
            // 顶部一行: 左标题 + 右封面拼贴。两边对齐 .center, 高度由
            // 内容决定。
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

            // 按钮单独一行, 占满宽度, 不被封面挤变形
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

    // MARK: - Recently Played

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently_played")
                .font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            let songs = recentSongs
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    // Display in pairs (two rows per column) for compact layout
                    ForEach(Array(stride(from: 0, to: songs.count, by: 2)), id: \.self) { i in
                        VStack(spacing: 8) {
                            Button { playSong(songs[i]) } label: {
                                RecentPlayCard(song: songs[i])
                            }
                            .buttonStyle(.plain)

                            if i + 1 < songs.count {
                                Button { playSong(songs[i + 1]) } label: {
                                    RecentPlayCard(song: songs[i + 1])
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 200)
                    }
                }
                .padding(.horizontal, 16)
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

    // MARK: - Artists

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("tab_artists").font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(library.artists.prefix(8)) { artist in
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



    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)
            Image(systemName: "music.note.list").font(.system(size: 56)).foregroundStyle(.tertiary)
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

// MARK: - Recent Play Card

struct RecentPlayCard: View {
    let song: Song
    var body: some View {
        HStack(spacing: 10) {
            CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 48, cornerRadius: 6, sourceID: song.sourceID, filePath: song.filePath)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.caption).fontWeight(.medium).lineLimit(1)
                Text(song.artistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
