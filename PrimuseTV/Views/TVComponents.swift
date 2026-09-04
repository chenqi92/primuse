#if os(tvOS)
import SwiftUI
import PrimuseKit
import UIKit

// MARK: - 横向区块(Apple Music tvOS shelf 风)

struct TVRow<Content: View>: View {
    let label: String
    var sub: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).font(.system(size: 28, weight: .bold)).foregroundStyle(TVColor.text)
                if let sub { Text(sub).font(.system(size: 16)).foregroundStyle(TVColor.textFaint) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) { content() }
                    // 焦点态卡片会上抬 12pt + 放大 ~10pt(scale 1.10),纵向留 30pt、横向留 20pt
                    // 才不会把首/末张卡的左右描边裁掉(之前 4pt 不够,第一张卡左边线被裁)。
                    .padding(.vertical, 30)
                    .padding(.horizontal, 20)
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
                        .foregroundStyle(TVColor.text).lineLimit(1)
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
    var reason: String? = nil
    var action: () -> Void = {}

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(radius: TVRadius.cover, scale: 1.10, lift: 10,
                      action: { store.play(song); action() }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: width)
                VStack(alignment: .leading, spacing: 3) {
                    if let reason, !reason.isEmpty {
                        Label(reason, systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TVColor.brand)
                            .lineLimit(1)
                    }
                    Text(song.title).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(TVColor.text).lineLimit(1)
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

// MARK: - 电台卡片

struct TVRadioStationCard: View {
    @Environment(TVStore.self) private var store
    let station: RadioStation
    var width: CGFloat = 220
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: TVRadius.cover, scale: 1.10, lift: 10,
                      action: {
                          TVSiriMediaInteractionDonor.donate(station: station)
                          store.play(station)
                          action()
                      }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                TVRadioArtworkView(station: station, size: width, radius: TVRadius.cover)
                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(TVColor.text)
                        .lineLimit(1)
                    Text(station.playbackSubtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                .padding(.top, 12)
                .padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

struct TVRadioArtworkView: View {
    let station: RadioStation
    let size: CGFloat
    var radius: CGFloat = TVRadius.cover

    @State private var logo: UIImage?

    private var logoIdentity: Int { station.logoData?.hashValue ?? 0 }

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFill()
            } else {
                TVRadioPlaceholderArtwork()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(TVColor.cardBorder, lineWidth: 1)
        }
        .task(id: logoIdentity) {
            let identity = logoIdentity
            guard let data = station.logoData else {
                logo = nil
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value
            guard !Task.isCancelled, identity == logoIdentity else { return }
            logo = decoded
        }
    }
}

private struct TVRadioPlaceholderArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height), 1)

            ZStack {
                TVColor.brandSecondary

                LinearGradient(
                    colors: [TVColor.brand.opacity(0.84), TVColor.brand.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .stroke(.white.opacity(0.10), lineWidth: max(1, side * 0.008))
                    .frame(width: side * 0.82, height: side * 0.82)

                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: max(1, side * 0.009))
                    .frame(width: side * 0.58, height: side * 0.58)

                Image(systemName: "radio.fill")
                    .font(.system(size: side * 0.31, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .foregroundStyle(TVColor.text).lineLimit(1).frame(width: size + 20)
            }
        }
        .accessibilityLabel(Text(artist.name))
        .accessibilityValue(Text(PMString("ext.tv.search.artistMeta", artist.songCount)))
    }
}

// MARK: - 空态

struct TVEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String = PMString("ext.tv.components.emptySubtitle")
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 80)).foregroundStyle(TVColor.textGhost)
            Text(title).font(.system(size: 32, weight: .bold)).foregroundStyle(TVColor.text)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 20)).foregroundStyle(TVColor.textMuted)
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
    var isSelected = false
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.04, lift: 6, action: action) { _ in
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 22, weight: .semibold))
                Text(title).font(style == .solid ? TVFont.sectionTitle : TVFont.button)
            }
            .padding(.horizontal, style == .solid ? 44 : 32)
            .padding(.vertical, 18)
            .foregroundStyle(style == .solid ? TVColor.onBrand : TVColor.text)
            .background(style == .solid ? AnyShapeStyle(TVColor.brand)
                                        : AnyShapeStyle(TVColor.surfaceStrong))
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
