import SwiftUI
import PrimuseKit

/// iPhone / iPad 上艺术家页的版式。Mac 走 master-detail，不参与这个开关。
enum ArtistLayoutMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var titleKey: String.LocalizationValue {
        switch self {
        case .grid: return "artist_layout_grid"
        case .list: return "artist_layout_list"
        }
    }

    var icon: String {
        switch self {
        case .grid: return "circle.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    static let storageKey = "artist.layoutMode"
}

struct ArtistListView: View {
    let artists: [Artist]
    @State private var searchText: String = ""

    @Environment(\.pmHeightClass) private var heightClass
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge

    @AppStorage(ArtistLayoutMode.storageKey)
    private var layoutModeRaw = ArtistLayoutMode.grid.rawValue

    private var layoutMode: ArtistLayoutMode {
        ArtistLayoutMode(rawValue: layoutModeRaw) ?? .grid
    }

    private var filteredArtists: [Artist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func displayName(for artist: Artist) -> String {
        let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "unknown_artist") : name
    }

    var body: some View {
        #if os(macOS)
        macBody
            .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenArtist)) { note in
                guard let artist = note.object as? Artist,
                      artists.contains(where: { $0.id == artist.id }) else { return }
                searchText = ""
                selectedArtistID = artist.id
            }
        #else
        iosBody
        #endif
    }

    @ViewBuilder
    private var iosBody: some View {
        if artists.isEmpty {
            EmptyStateView(
                titleKey: "no_artists",
                descriptionKey: "no_artists_desc",
                systemImage: "music.mic"
            )
        } else {
            Group {
                switch layoutMode {
                case .grid: artistGrid.pmAppearFade()
                case .list: artistList.pmAppearFade()
                }
            }
            .overlay {
                if filteredArtists.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            #if os(iOS)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("filter_artists_placeholder")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ArtistLayoutToolbarButton(titled: verticalBarEdge != nil)
                }
            }
            #endif
        }
    }

    /// 圆形头像网格。`.adaptive` 让 iPhone 落到两列、iPad 自然摊开更多列,
    /// 和专辑网格用的是同一套断点 —— 手机横屏下的下限也一起收到 100。
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: heightClass.value(150, compact: 100)), spacing: 16)]
    }

    private var artistGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: heightClass.value(24, compact: 16)) {
                ForEach(filteredArtists) { artist in
                    NavigationLink(value: artist) {
                        artistGridCell(artist)
                    }
                    .buttonStyle(.pmPressable)
                    .mediaZoomSource(.artist, id: artist.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .pmExtendsUnderVerticalBar()
    }

    private func artistGridCell(_ artist: Artist) -> some View {
        VStack(spacing: 10) {
            ArtistArtworkView(artist: artist, cornerRadius: 0)
                .clipShape(Circle())
                // 浅色照片在浅色背景上会糊掉边界,补一圈发丝线。
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }

            Text(displayName(for: artist))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
    }

    private var artistList: some View {
        List(filteredArtists) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    ArtistArtworkView(
                        artist: artist,
                        size: 44,
                        cornerRadius: 22
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: artist))
                            .font(.body)

                        Text("\(artist.albumCount) \(String(localized: "albums_count")) · \(artist.songCount) \(String(localized: "songs_count"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .mediaZoomSource(.artist, id: artist.id)
        }
        .listStyle(.plain)
        .pmExtendsUnderVerticalBar()
    }

    #if os(macOS)
    /// 当前选中的艺术家 (nil → 取过滤后列表第一个), 驱动右侧详情。
    @State private var selectedArtistID: String?

    private var selectedArtist: Artist? {
        if let id = selectedArtistID,
           let match = filteredArtists.first(where: { $0.id == id }) {
            return match
        }
        return filteredArtists.first
    }

    /// 设计稿 LIB-03: 左侧 280pt 艺术家列表 + 右侧选中艺术家的详情, 一体的
    /// master-detail, 而不是之前的大 hero + 卡片网格。
    @ViewBuilder
    private var macBody: some View {
        if artists.isEmpty {
            ContentUnavailableView(
                "no_artists",
                systemImage: "music.mic",
                description: Text("no_artists_desc")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PMColor.bg.ignoresSafeArea())
        } else {
            HStack(spacing: 0) {
                artistListPane
                    .frame(width: 280)

                Rectangle()
                    .fill(PMColor.divider)
                    .frame(width: 0.5)

                Group {
                    if let artist = selectedArtist {
                        // 只在重建后淡入: 详情页一次 body 要过滤整库专辑,
                        // 不能把它拉进交叉淡入的事务里。
                        ArtistDetailView(artist: artist)
                            .pmAppearFade()
                            .id(artist.id)
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PMColor.bg.ignoresSafeArea())
        }
    }

    private var artistListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("tab_artists")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                artistFilterField
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if filteredArtists.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredArtists) { artist in
                            artistRow(artist)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PMColor.bg)
    }

    private var artistFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            TextField("", text: $searchText, prompt: Text("filter_artists_placeholder"))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.text)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func artistRow(_ artist: Artist) -> some View {
        let isSelected = selectedArtist?.id == artist.id
        return Button {
            selectedArtistID = artist.id
        } label: {
            HStack(spacing: 10) {
                ArtistArtworkView(
                    artist: artist,
                    size: 36,
                    cornerRadius: 18
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: artist))
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text("\(artist.songCount) \(String(localized: "songs_count"))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .pmRowBackground(selected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif
}

#if os(iOS)
/// 只有网格/列表两种版式, 与其点开菜单再选, 不如按一下就换 —— 图标画的是「按下去
/// 会变成的那种」, 当前版式留给旁白读。
/// 工具栏条目跑在自己的视图图里, 所以这里只读 `@AppStorage`, 不读环境。
private struct ArtistLayoutToolbarButton: View {
    @AppStorage(ArtistLayoutMode.storageKey)
    private var layoutModeRaw = ArtistLayoutMode.grid.rawValue
    /// 系统竖栏里带上标题(收进溢出菜单时要用),其它时候仍是纯图标。
    var titled = false

    private var layoutMode: ArtistLayoutMode {
        ArtistLayoutMode(rawValue: layoutModeRaw) ?? .grid
    }

    private var nextMode: ArtistLayoutMode {
        layoutMode == .grid ? .list : .grid
    }

    var body: some View {
        Button {
            layoutModeRaw = nextMode.rawValue
        } label: {
            PMToolbarItemLabel(verbatim: String(localized: nextMode.titleKey), systemImage: nextMode.icon, titled: titled)
        }
        .accessibilityLabel(Text(String(localized: nextMode.titleKey)))
        .accessibilityValue(Text(String(localized: layoutMode.titleKey)))
        .accessibilityIdentifier("artistLayout.toggle")
    }
}
#endif
