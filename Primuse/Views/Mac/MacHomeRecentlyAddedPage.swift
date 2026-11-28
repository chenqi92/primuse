#if os(macOS)
import SwiftUI
import PrimuseKit

/// Mac 首页「最近添加」的「查看全部」(UB):从曲库目录按页列出,顺序与成员同首页那一排
/// (`MacHomeRecentlyAddedQuery`,每首歌按自己的加入时间、「显示外部专辑」开关),歌曲模型在不在内存里都马上打开,
/// 首页快照不必留着全部专辑。只在曲库目录答不了时显示加载(`MacHomeCollectionLoading`)。
struct MacHomeRecentlyAddedPage: View {
    let includingExternalSongs: Bool
    /// 首页快照里的总张数:第一页行号到之前标题旁先显示它。
    let knownTotal: Int
    @Binding var showsExternalAlbums: Bool
    let onBack: () -> Void
    @Environment(MusicLibrary.self) private var library
    @State private var list: LibraryListModel<MacHomeRecentlyAddedQuery>?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                MacHomeCollectionHeader(
                    eyebrow: "library_title",
                    title: LocalizedStringKey(HomeDiscoveryText.string("recent_albums")),
                    detail: LibraryCountText.albums(shownTotal),
                    onBack: onBack
                )

                if let list, list.lastError == nil, !list.isLoading || list.count > 0 {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 5),
                        alignment: .leading,
                        spacing: 24
                    ) {
                        ForEach(0..<list.count, id: \.self) { index in
                            if let album = list.item(at: index) {
                                MacHomeDetailLink(album: album) {
                                    MacHomeAlbumCard(album: album)
                                }
                                .contextMenu { Toggle("home_show_preview_albums", isOn: $showsExternalAlbums) }
                            } else {
                                // 那一页还没取到:与一张卡同样的方块。
                                Color.clear.aspectRatio(0.78, contentMode: .fit)
                            }
                        }
                    }
                    .padding(.horizontal, PMSpace.xxxl)
                } else {
                    MacHomeCollectionLoading()
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .task(id: includingExternalSongs) { start() }
        .onDisappear {
            list?.deactivate()
            list = nil
        }
    }

    private var shownTotal: Int {
        guard let list, list.lastError == nil, !list.isLoading else { return knownTotal }
        return list.count
    }

    /// 换了「显示外部专辑」就换一份列表。没有曲库目录时不建(页面显示加载)。
    private func start() {
        list?.deactivate()
        guard let host = library.catalogHost else {
            list = nil
            return
        }
        let model = LibraryListModel(
            query: MacHomeRecentlyAddedQuery(includingExternalSongs: includingExternalSongs),
            reader: host.reader, revisions: host.revisions
        )
        model.activate()
        list = model
    }
}

/// 首页「最近添加」的一张专辑卡(首页那一排与「查看全部」共用)。
struct MacHomeAlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(album: album, cornerRadius: PMRadius.m)
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
            Text(LibraryCountText.songs(album.songCount))
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
        }
    }
}

/// 首页「查看全部」那几页的页头:小标题、大标题、数目与返回键。
struct MacHomeCollectionHeader: View {
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let detail: String
    let onBack: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            Spacer(minLength: 16)
            MacNavigationBackButton(
                accessibilityIdentifier: "homeSectionInlineBack",
                action: onBack
            )
        }
        .padding(.horizontal, PMSpace.xxxl)
    }
}
#endif
