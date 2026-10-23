import MusicKit
import PrimuseKit
import SwiftUI

/// 搜索里点开的 Apple Music 艺人:目录里的照片、热门歌曲和专辑。全部来自目录、不进曲库;
/// 歌曲和搜索结果一样走托管队列播放,专辑打开目录专辑页(`AppleMusicCatalogAlbumIdentity`)。
struct AppleMusicCatalogArtistView: View {
    let artist: AppleMusicCatalogArtistHit
    var onMacInlineBack: (() -> Void)? = nil

    @Environment(AudioPlayerService.self) private var player
    @State private var topSongs: [MusicKit.Song] = []
    @State private var albums: [MusicKit.Album] = []
    @State private var phase: Phase = .loading

    private enum Phase { case loading, loaded, failed }

    private static let topSongLimit = 20
    private static let albumLimit = 30

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                switch phase {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                case .failed:
                    Label("apple_music_catalog_artist_unavailable", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                case .loaded:
                    if !topSongs.isEmpty { topSongsSection }
                    if !albums.isEmpty { albumsSection }
                }
            }
            .padding(.bottom, 24)
        }
        .task(id: artist.id) { await load() }
        #if os(iOS)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .minimalNavigationDetail()
        #endif
    }

    // MARK: 页头

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            AsyncImage(url: artist.artworkURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .pmFadeTransition(motion: .contentAppear)
                } else {
                    Circle().fill(Color.secondary.opacity(0.15))
                        .overlay {
                            Image(systemName: "music.mic")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) { AppleMusicCatalogBadge(size: 24) }

            VStack(alignment: .leading, spacing: 6) {
                Label("search_section_apple_music", systemImage: "applelogo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: artist.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    playButton(shuffled: false)
                    playButton(shuffled: true)
                }
                .disabled(topSongs.isEmpty)
            }
            Spacer(minLength: 0)
            #if os(macOS)
            if let onMacInlineBack {
                MacNavigationBackButton(
                    accessibilityIdentifier: "appleMusicArtistInlineBack",
                    action: onMacInlineBack
                )
            }
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func playButton(shuffled: Bool) -> some View {
        Button {
            play(startingAt: 0, shuffled: shuffled)
        } label: {
            Label(shuffled ? "shuffle" : "play_all", systemImage: shuffled ? "shuffle" : "play.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    // MARK: 热门歌曲

    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("apple_music_catalog_top_songs")
            ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                Button {
                    play(startingAt: index, shuffled: false)
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: song.artwork?.url(width: 88, height: 88)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                                    .pmFadeTransition(motion: .contentAppear)
                            } else {
                                Color.secondary.opacity(0.15)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: song.title).font(.subheadline).lineLimit(1)
                            Text(verbatim: song.albumTitle ?? song.artistName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let duration = song.duration {
                            Text(verbatim: Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 专辑

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("tab_albums")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums, id: \.id) { album in
                        NavigationLink(
                            value: AppServices.shared.appleMusicLibrary.catalogAlbum(for: album)
                        ) {
                            AppleMusicCatalogAlbumCard(album: album, width: 140)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
        .padding(.top, 8)
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }

    // MARK: 载入与播放

    private func load() async {
        phase = .loading
        do {
            let request = MusicCatalogResourceRequest<MusicKit.Artist>(
                matching: \.id,
                equalTo: MusicItemID(artist.id)
            )
            guard let found = try await request.response().items.first else {
                phase = .failed
                return
            }
            let detailed = try await found.with([.topSongs, .albums])
            guard !Task.isCancelled else { return }
            topSongs = Array((detailed.topSongs.map { Array($0) } ?? []).prefix(Self.topSongLimit))
            albums = Array((detailed.albums.map { Array($0) } ?? []).prefix(Self.albumLimit))
            phase = topSongs.isEmpty && albums.isEmpty ? .failed : .loaded
        } catch is CancellationError {
            // 页面已经离开。
        } catch {
            guard !Task.isCancelled else { return }
            plog("⚠️Apple Music artist page failed for '\(artist.name)': \(error.localizedDescription)")
            phase = .failed
        }
    }

    private func play(startingAt index: Int, shuffled: Bool) {
        let queue = AppServices.shared.appleMusicLibrary.registerCatalogSongs(topSongs)
        guard queue.indices.contains(index) else { return }
        if shuffled {
            player.shuffleEnabled = true
            let order = player.shufflePlayOrder(queue)
            Task { await player.play(queue: order, startingAt: 0) }
        } else {
            Task { await player.play(queue: queue, startingAt: index) }
        }
    }
}

/// Apple Music 目录内容的角标:红底白色苹果标,贴在封面右下角,与曲库内容区分开。
struct AppleMusicCatalogBadge: View {
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: "applelogo")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.98, green: 0.14, blue: 0.23), in: .rect(cornerRadius: size * 0.22))
            .padding(size * 0.25)
            .accessibilityLabel(Text("search_section_apple_music"))
    }
}

/// 搜索结果与目录艺人页里的一张 Apple Music 专辑卡片。
struct AppleMusicCatalogAlbumCard: View {
    let album: MusicKit.Album
    var width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: album.artwork?.url(width: 300, height: 300)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .pmFadeTransition(motion: .contentAppear)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) { AppleMusicCatalogBadge(size: 18) }
            Text(verbatim: album.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(verbatim: [
                album.artistName,
                album.releaseDate.map { String(Calendar.current.component(.year, from: $0)) },
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 搜索结果里的一位 Apple Music 艺人:圆形照片加角标。
struct AppleMusicCatalogArtistCard: View {
    let artist: AppleMusicCatalogArtistHit
    var width: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            AsyncImage(url: artist.artworkURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .pmFadeTransition(motion: .contentAppear)
                } else {
                    Circle().fill(Color.secondary.opacity(0.15))
                        .overlay {
                            Image(systemName: "music.mic").foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: width, height: width)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) { AppleMusicCatalogBadge(size: 18) }
            Text(verbatim: artist.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(width: width)
    }
}

extension AppleMusicCatalogArtistHit {
    init(_ artist: MusicKit.Artist) {
        self.init(
            id: artist.id.rawValue,
            name: artist.name,
            artworkURL: artist.artwork?.url(width: 400, height: 400)
        )
    }
}
