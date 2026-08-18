#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 歌单 — 4 列磁贴网格(对应 tvos.jsx 的 TVPlaylistsArtboard)。
struct TVPlaylistsView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}

    private let cols = 4
    private let gap: CGFloat = 36

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            GeometryReader { geo in
                let contentW = geo.size.width - TVSpace.pageH * 2
                let cell = (contentW - gap * CGFloat(cols - 1)) / CGFloat(cols)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        VStack(alignment: .leading, spacing: 6) {
                            TVEyebrow(text: PMString("ext.tv.playlists.eyebrow"))
                            Text(PMString("ext.tv.playlists.title", store.playlists.count))
                                .font(TVFont.pageTitle).foregroundStyle(TVColor.text)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: cols),
                                  alignment: .leading, spacing: gap) {
                            ForEach(store.playlists) { p in
                                TVPlaylistCard(playlist: p, width: cell, action: openPlayer)
                            }
                        }
                    }
                    .tvPage()
                }
            }
        }
    }
}

/// 歌单磁贴 — 智能歌单右上角标、我喜欢的整块爱心覆层。
struct TVPlaylistCard: View {
    @Environment(TVStore.self) private var store
    let playlist: TVPlaylist
    var width: CGFloat = 300
    var action: () -> Void = {}

    var body: some View {
        let h = width * 0.8
        TVFocusButton(radius: TVRadius.card, scale: 1.08, lift: 12,
                      action: { playTapped() }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    TVPlaylistArtworkView(playlist: playlist, size: width, height: h)
                    if playlist.kind == .smart {
                        VStack {
                            HStack {
                                Spacer()
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles").font(.system(size: 13))
                                    Text(PMString("ext.tv.playlists.smart")).font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.5), in: Capsule())
                            }
                            Spacer()
                        }
                        .padding(12)
                    }
                    if playlist.kind == .liked {
                        LinearGradient(colors: [TVColor.brand.opacity(0.8), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "heart.fill").font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .frame(width: width, height: h)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(TVColor.text).lineLimit(1)
                    Text(PMString("ext.tv.songsCount", playlist.count)).font(.system(size: 16))
                        .foregroundStyle(TVColor.textFaint)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    /// 点击歌单卡片:播放歌单**自身**的曲目(我喜欢的 / 普通歌单),而不是封面取材的那张专辑。
    /// 智能歌单在 tvOS 上尚未求值(无真实歌曲),点击不做任何事,避免静默打开空播放页。
    private func playTapped() {
        // 智能歌单 / 空歌单:无可播放内容,play(playlist:) 返回 false,忽略点击
        //(不退化为播专辑、不打开空播放页),续播队列即该歌单全部曲目。
        guard store.play(playlist: playlist) else { return }
        action()
    }
}

/// tvOS consumes the same deterministic PrimuseKit plan as the phone and Mac,
/// but resolves each entry with its target-specific cache/client loader.
private struct TVPlaylistArtworkView: View {
    @Environment(TVStore.self) private var store
    let playlist: TVPlaylist
    let size: CGFloat
    let height: CGFloat

    @State private var image: UIImage?
    @State private var reloadRevision = 0

    private var overrideResolution: LibraryArtworkOverrideResolution {
        store.library.artworkOverrideResolution(
            for: LibraryArtworkOwner(kind: .playlist, id: playlist.id),
            eligibleSongs: store.library.songs(forPlaylist: playlist.id)
        )
    }

    private var overrideIdentity: String {
        switch overrideResolution {
        case .automatic: return "automatic"
        case .selectedSong(let songID): return "song:\(songID)"
        case .uploaded(let contentID): return "upload:\(contentID)"
        }
    }

    private var loadIdentity: String {
        "\(playlist.artworkSignature)#\(overrideIdentity)#\(store.library.artworkOverrideRevision)#\(reloadRevision)"
    }

    var body: some View {
        ZStack {
            TVMusicPlaceholder(
                tint: TVColor.brand,
                tint2: .black,
                kind: .playlist,
                size: size,
                height: height
            )
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: height)
                    .clipped()
            }
        }
        .frame(width: size, height: height)
        .task(id: loadIdentity) {
            let identity = loadIdentity
            image = nil
            switch overrideResolution {
            case .uploaded(let contentID):
                if let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID),
                   let customImage = UIImage(data: data) {
                    guard !Task.isCancelled, loadIdentity == identity else { return }
                    image = customImage
                    return
                }
            case .selectedSong(let songID):
                if let song = store.library.song(id: songID) {
                    let client = store.fnMusicClient(for: song.sourceID)
                    if let data = await TVArtworkLoader.shared.songCover(
                        songID: song.id,
                        coverRef: song.coverArtFileName,
                        fnMusicSourceID: song.sourceID,
                        fnMusicClient: client
                    ), let selectedImage = UIImage(data: data) {
                        guard !Task.isCancelled, loadIdentity == identity else { return }
                        image = selectedImage
                        return
                    }
                }
            case .automatic:
                break
            }
            let corePlan = PlaylistArtworkResolutionPlan(
                signature: playlist.artworkSignature,
                candidates: playlist.artworkCandidates.map {
                    PlaylistArtworkCandidate(
                        kind: $0.kind,
                        id: $0.id,
                        songID: $0.songID,
                        artworkReference: $0.coverRef
                    )
                }
            )
            let resolved: PlaylistArtworkResolution<UIImage>? = await PlaylistArtworkResolver
                .resolve(plan: corePlan) { candidate -> UIImage? in
                guard let songID = candidate.songID else { return nil }
                let sourceID = playlist.artworkCandidates
                    .first(where: { $0.id == candidate.id })?
                    .sourceID
                let client = sourceID.flatMap { store.fnMusicClient(for: $0) }
                guard let data = await TVArtworkLoader.shared.songCover(
                    songID: songID,
                    coverRef: candidate.artworkReference,
                    fnMusicSourceID: sourceID,
                    fnMusicClient: client
                ) else { return nil }
                return UIImage(data: data)
            }
            guard !Task.isCancelled, loadIdentity == identity else { return }
            image = resolved?.value
            if image == nil {
                try? await Task.sleep(
                    nanoseconds: UInt64(TVArtworkLoader.negativeCacheTTL * 1_000_000_000)
                )
                guard !Task.isCancelled, loadIdentity == identity, image == nil else { return }
                reloadRevision &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard notificationAffectsPlaylist(note) else { return }
            reloadRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            guard notificationAffectsPlaylist(note) else { return }
            reloadRevision &+= 1
        }
    }

    private func notificationAffectsPlaylist(_ note: Notification) -> Bool {
        if note.userInfo?["all"] as? Bool == true { return true }
        let songIDs = Set(playlist.artworkCandidates.map(\.songID))
        if let songID = note.object as? String, songIDs.contains(songID) { return true }
        if let songID = note.userInfo?["songID"] as? String, songIDs.contains(songID) {
            return true
        }
        if let changed = note.userInfo?["songIDs"] as? [String],
           changed.contains(where: songIDs.contains) {
            return true
        }
        let references = Set(playlist.artworkCandidates.compactMap(\.coverRef))
        if let tokens = note.userInfo?["tokens"] as? [String],
           tokens.contains(where: { references.contains($0) || overrideIdentity.contains($0) }) {
            return true
        }
        return false
    }
}
#endif
