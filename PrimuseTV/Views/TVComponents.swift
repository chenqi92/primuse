#if os(tvOS)
import SwiftUI

// MARK: - 横向区块(Apple Music tvOS shelf 风)

struct TVRow<Content: View>: View {
    let label: String
    var sub: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                if let sub { Text(sub).font(.system(size: 16)).foregroundStyle(TVColor.textFaint) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) { content() }
                    // 焦点态卡片会上抬 12pt + 放大 ~7pt,纵向留 30pt 才不会把顶/底描边
                    // 裁掉(之前 16pt 不够,顶部选中框线看不见)。
                    .padding(.vertical, 30)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - 专辑卡片

struct TVAlbumCard: View {
    let album: TVAlbum
    var width: CGFloat = 200
    var titleOverride: String? = nil
    var subtitleOverride: String? = nil
    var action: () -> Void = {}
    @Environment(TVStore.self) private var store

    var body: some View {
        TVFocusButton(radius: TVRadius.cover, scale: 1.10, lift: 10,
                      action: { store.play(album: album); action() }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                TVArtworkView(album: album, size: width)
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleOverride ?? album.title)
                        .font(.system(size: width >= 220 ? 22 : 17, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(subtitleOverride ?? album.artist)
                        .font(.system(size: width >= 220 ? 16 : 13))
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - 歌曲卡片(用所属专辑封面)

struct TVSongCard: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var width: CGFloat = 200
    var action: () -> Void = {}

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(radius: TVRadius.cover, scale: 1.10, lift: 10,
                      action: { store.play(song); action() }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: width)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(song.artist).font(.system(size: 13))
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - 艺术家卡片(圆形)

struct TVArtistCard: View {
    let artist: TVArtist
    var size: CGFloat = 180
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: size / 2 + 8, scale: 1.08, lift: 10, action: action) { _ in
            VStack(spacing: 12) {
                TVCoverArt(tint: artist.tint, tint2: artist.tint2, glyph: artist.glyph,
                           size: size, radius: size / 2)
                Text(artist.name).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1).frame(width: size + 20)
            }
        }
    }
}

// MARK: - 空态

struct TVEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String = "在 iPhone / Mac 上同步曲库后,这里会显示你的音乐"
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 80)).foregroundStyle(.white.opacity(0.4))
            Text(title).font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center).frame(maxWidth: 720)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 胶囊按钮(播放 / 随机 / 喜欢)

struct TVPillButton: View {
    enum Style { case solid, glass }
    let title: String
    let systemImage: String
    var style: Style = .glass
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.04, lift: 6, action: action) { _ in
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 22, weight: .semibold))
                Text(title).font(.system(size: style == .solid ? 26 : 24,
                                         weight: style == .solid ? .bold : .medium))
            }
            .padding(.horizontal, style == .solid ? 44 : 32)
            .padding(.vertical, 18)
            .foregroundStyle(style == .solid ? Color(hex: "#1f1c19") : .white)
            .background(style == .solid ? AnyShapeStyle(.white)
                                        : AnyShapeStyle(Color.white.opacity(0.18)))
        }
    }
}
#endif
