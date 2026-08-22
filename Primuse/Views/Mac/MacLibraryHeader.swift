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
    var showsMoreButton = true

    @State private var showMoreMenu = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            coverArt
                .frame(width: 160, height: 160)

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

                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                            Text("play")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(PMColor.brand, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .shadow(color: PMColor.brand.opacity(0.35), radius: 6, y: 2)

                    Button(action: onShuffle) {
                        HStack(spacing: 7) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 12))
                            Text("shuffle")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.16), in: .rect(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain)

                    if showsMoreButton {
                        Button {
                            if moreMenu != nil {
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
                        .buttonStyle(.plain)
                        .popover(isPresented: $showMoreMenu, arrowEdge: .bottom) {
                            if let moreMenu {
                                moreMenu
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background {
            // Keeping the ambient layer in background avoids an offscreen sibling
            // rendering above the header when the view is reused in a split view.
            AmbientBackdrop(accent: accent, darkAccent: darkAccent, strength: 0.4)
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
        .frame(height: 240)
        .clipped()
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
                size: 160,
                cornerRadius: PMRadius.l
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        } else if let artist = coverArtist {
            CachedArtworkView(
                artistID: artist.id,
                artistName: artist.name,
                artworkReference: artist.thumbnailPath,
                size: 160,
                cornerRadius: 80
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
        .buttonStyle(.plain)
        .help(Text("back_to_options"))
        .accessibilityIdentifier(accessibilityIdentifier)
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
