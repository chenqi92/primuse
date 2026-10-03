#if os(macOS)
import SwiftUI
import PrimuseKit

/// 资料库三个主视图 (Songs / Albums / Artists) 共用的顶部 header — 大封面 +
/// AmbientBackdrop + 标题 + 副标题 + 主操作按钮 (播放/随机/更多)。
struct MacLibraryHeader: View {
    var eyebrow: LocalizedStringKey
    var title: String
    var subtitle: String
    var iconSystemName: String = "music.note"
    var coverSong: Song? = nil
    var coverAlbum: Album? = nil
    var coverPlaylist: Playlist? = nil
    var coverArtist: Artist? = nil
    var accent: Color = PMColor.brand
    var darkAccent: Color = PMColor.brand.opacity(0.6)
    var onBack: (() -> Void)? = nil
    var backAccessibilityIdentifier = "macLibraryHeaderBack"
    var onPlay: () -> Void = {}
    var onShuffle: () -> Void = {}
    var onMore: () -> Void = {}
    var moreMenu: AnyView? = nil
    var makeMoreMenu: (() -> AnyView)? = nil
    var showsMoreButton = true
    /// 有值时「随机播放」后多一颗心（专辑、艺人页）。
    var favorite: LibraryDetailFavoriteToggle? = nil
    /// 专辑、艺人页的简介摘录，放在副标题和按钮之间；有内容时头部跟着长高。
    var synopsis: AnyView? = nil
    /// 底图用这张专辑 / 这位艺人的封面虚化铺满，像影片介绍页的海报底图；
    /// 关掉（歌单、风格等）照旧是固定色的氛围底。
    var artworkBackdrop = false

    @State private var showMoreMenu = false

    private var coverSide: CGFloat { artworkBackdrop ? 196 : 160 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            coverArt
                .frame(width: coverSide, height: coverSide)

            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.72))

                Text(verbatim: title)
                    .font(.system(size: 44, weight: .bold))
                    .tracking(-0.8)
                    .lineSpacing(0)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(verbatim: subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                if let synopsis {
                    synopsis
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.top, 6)
                }

                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                            Text("play")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        // 头部窄(三栏的艺人页、窄窗口)时不能被挤成一字一行。
                        .fixedSize()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(PMColor.brand, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.pmPressable)
                    .shadow(color: PMColor.brand.opacity(0.35), radius: 6, y: 2)
                    .pmHoverLift()

                    Button(action: onShuffle) {
                        // 放不下文字时只留图标,悬停有说明。
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 7) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 12))
                                Text("shuffle")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .fixedSize()
                            Image(systemName: "shuffle")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.16), in: .rect(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                    }
                    .buttonStyle(.pmPressable)
                    .help(Text("shuffle"))
                    .pmHoverLift()

                    if let favorite {
                        Button(action: favorite.toggle) {
                            Image(systemName: favorite.isLiked ? "heart.fill" : "heart")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.16), in: .rect(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                        }
                        .buttonStyle(.pmPressable)
                        .help(Text(favorite.isLiked ? "library_favorite_unlike" : "library_favorite_like"))
                        .accessibilityLabel(Text(favorite.isLiked ? "library_favorite_unlike" : "library_favorite_like"))
                        .accessibilityAddTraits(favorite.isLiked ? .isSelected : [])
                        .pmHoverLift()
                    }

                    if showsMoreButton {
                        Button {
                            if moreMenu != nil || makeMoreMenu != nil {
                                showMoreMenu.toggle()
                            } else {
                                onMore()
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.16), in: .rect(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                        }
                        .buttonStyle(.pmPressable)
                        .popover(isPresented: $showMoreMenu, arrowEdge: .bottom) {
                            Group {
                                if let moreMenu {
                                    moreMenu
                                } else if let makeMoreMenu {
                                    makeMoreMenu()
                                }
                            }
                            .focusEffectDisabled()
                        }
                        .pmHoverLift()
                    }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.top, 32)
        .padding(.bottom, 24)
        // 没有简介时内容不到 240，照旧是 240 高、内容贴底；有简介时按内容长高。
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .bottomLeading)
        .background {
            // Keeping the ambient layer in background avoids an offscreen sibling
            // rendering above the header when the view is reused in a split view.
            if artworkBackdrop, coverAlbum != nil || coverArtist != nil {
                artworkBackdropLayer
            } else {
                AmbientBackdrop(accent: accent, darkAccent: darkAccent, strength: 0.4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onBack {
                MacNavigationBackButton(
                    style: .onAccent,
                    accessibilityIdentifier: backAccessibilityIdentifier,
                    action: onBack
                )
                .padding(.top, 32)
                .padding(.trailing, 36)
            }
        }
        .clipped()
    }

    /// 封面虚化成整幅底图。只取一张小图放大再糊开 —— 糊掉之后分辨率看不出来，
    /// 也不必为一张底图解出整幅大图；压暗层保证白字在亮封面上也读得清，
    /// 最底下一小段化进页面底色，头部不再是一刀切的边。
    private var artworkBackdropLayer: some View {
        GeometryReader { geometry in
            let side: CGFloat = 240
            let scale = max(geometry.size.width, geometry.size.height) / side * 1.3
            backdropArtwork(side: side)
                .blur(radius: 14, opaque: true)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(PMColor.ambientDarkBase)
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.34), location: 0),
                    .init(color: .black.opacity(0.58), location: 0.62),
                    .init(color: .black.opacity(0.66), location: 0.9),
                    .init(color: PMColor.bg, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func backdropArtwork(side: CGFloat) -> some View {
        if let album = coverAlbum {
            AlbumArtworkView(album: album, size: side, cornerRadius: 0)
        } else if let artist = coverArtist {
            ArtistArtworkView(artist: artist, size: side, cornerRadius: 0)
        }
    }

    @ViewBuilder
    private var coverArt: some View {
        if let playlist = coverPlaylist {
            PlaylistArtworkView(
                playlist: playlist,
                size: 160,
                cornerRadius: PMRadius.l,
                placeholderIcon: iconSystemName
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        } else if let album = coverAlbum {
            AlbumArtworkView(
                album: album,
                size: coverSide,
                cornerRadius: PMRadius.l,
                presentationRole: .animatedHero
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        } else if let artist = coverArtist {
            ArtistArtworkView(
                artist: artist,
                size: coverSide,
                cornerRadius: coverSide / 2
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        } else if let song = coverSong {
            CachedArtworkView(
                coverRef: song.coverArtFileName, songID: song.id,
                size: 160,
                cornerRadius: PMRadius.l,
                sourceID: song.sourceID, filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        } else {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .fill(.white.opacity(0.12))
                .overlay {
                    Image(systemName: iconSystemName)
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }
}

/// Keeps desktop drill-down navigation inside the panel being navigated.
/// The native window toolbar is reserved for window chrome, not phone-style
/// leading back controls.
struct MacNavigationBackButton: View {
    enum Style {
        case standard
        case onAccent
    }

    var style: Style = .standard
    var accessibilityIdentifier = "macInlineBack"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("back_to_options", systemImage: "chevron.backward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(backgroundColor, in: .rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                }
        }
        .buttonStyle(.pmPressable)
        .help(Text("back_to_options"))
        .accessibilityIdentifier(accessibilityIdentifier)
        .pmHoverLift()
    }

    private var foregroundColor: Color {
        style == .onAccent ? .white : PMColor.text
    }

    private var backgroundColor: Color {
        style == .onAccent ? .white.opacity(0.16) : PMColor.glassBtn
    }

    private var borderColor: Color {
        style == .onAccent ? .white.opacity(0.22) : PMColor.cardBorder
    }
}

/// 设计稿 LibraryHeader 右上角 "更多" 按钮弹出的 PM 风格菜单 —— 歌单 / 专辑
/// 详情页把各自的动作按分组传进来, 点任一项后自动收起 popover。
/// (MacLibraryHeader 的 `moreMenu` 槽接受任意 AnyView, 这里给出统一样式。)
struct MacHeaderMoreMenu: View {
    struct Item: Identifiable {
        let id = UUID()
        var icon: String
        var title: String
        var trailing: String?
        var enabled: Bool
        var isDestructive: Bool
        var action: () -> Void

        init(icon: String, title: String, trailing: String? = nil, enabled: Bool = true,
             isDestructive: Bool = false, action: @escaping () -> Void) {
            self.icon = icon
            self.title = title
            self.trailing = trailing
            self.enabled = enabled
            self.isDestructive = isDestructive
            self.action = action
        }
    }

    /// 每个内层数组是一个分组, 组与组之间画一条细分割线。空组自动跳过。
    let sections: [[Item]]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let groups = sections.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, items in
                if index > 0 {
                    Rectangle()
                        .fill(PMColor.divider)
                        .frame(height: 0.5)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                ForEach(items) { item in
                    row(item)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
    }

    private func row(_ item: Item) -> some View {
        Button {
            dismiss()
            item.action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(item.isDestructive ? PMColor.bad : PMColor.textMuted)
                    .frame(width: 15)
                Text(verbatim: item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.isDestructive ? PMColor.bad : PMColor.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing = item.trailing {
                    Text(verbatim: trailing)
                        .font(.system(size: trailing.contains("-") ? 9.5 : 10.5, design: trailing.contains("-") ? .monospaced : .default))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.4)
    }
}
#endif
