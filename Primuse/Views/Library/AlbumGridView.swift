import SwiftUI
import PrimuseKit

struct AlbumGridView: View {
    @Environment(MusicLibrary.self) private var library
    #if !os(macOS)
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]
    #endif

    var body: some View {
        if library.albums.isEmpty {
            EmptyStateView(
                titleKey: "no_albums",
                descriptionKey: "no_albums_desc",
                systemImage: "square.stack"
            )
        } else {
            #if os(macOS)
            macGrid
            #else
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(library.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            #endif
        }
    }

    #if os(macOS)
    @State private var albumSort: AlbumSortOrder = .year
    @State private var albumFilter: String = ""
    @State private var albumViewMode: AlbumViewMode = .grid

    private enum AlbumViewMode: String, CaseIterable, Hashable {
        case grid, list

        var icon: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }

    /// 设计稿 LIB-02 的排序维度: 发行年(默认) / 标题 / 艺术家 / 曲目数。
    private enum AlbumSortOrder: CaseIterable, Hashable {
        case year, title, artist, songCount

        var label: String {
            switch self {
            case .year: return "发行年"
            case .title: return "标题"
            case .artist: return "艺术家"
            case .songCount: return "曲目数"
            }
        }
    }

    private var filteredAlbums: [Album] {
        let q = albumFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return library.albums }
        return library.albums.filter { album in
            album.title.localizedCaseInsensitiveContains(q)
                || (album.artistName?.localizedCaseInsensitiveContains(q) ?? false)
                || album.year.map(String.init)?.contains(q) == true
        }
    }

    private var sortedAlbums: [Album] {
        switch albumSort {
        case .title:
            return filteredAlbums.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .artist:
            return filteredAlbums.sorted {
                ($0.artistName ?? "").localizedCompare($1.artistName ?? "") == .orderedAscending
            }
        case .year:
            return filteredAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .songCount:
            return filteredAlbums.sorted { $0.songCount > $1.songCount }
        }
    }

    /// 设计稿 LIB-02: 不再用带大封面的 hero header (那是全部歌曲/歌单的样式),
    /// 而是左上角 "资料库 / 专辑" 小标题 + 右上排序, 下面五列封面网格。
    private var macGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                albumsHeader

                if sortedAlbums.isEmpty {
                    ContentUnavailableView.search(text: albumFilter)
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .padding(.horizontal, PMSpace.xxxl)
                } else if albumViewMode == .grid {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 5),
                        alignment: .leading,
                        spacing: 24
                    ) {
                        ForEach(sortedAlbums) { album in
                            NavigationLink(value: album) {
                                GeometryReader { proxy in
                                    macAlbumTile(album, artworkSize: proxy.size.width)
                                }
                                .aspectRatio(0.74, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, PMSpace.xxxl)
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(sortedAlbums) { album in
                            NavigationLink(value: album) {
                                macAlbumListRow(album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, PMSpace.xxxl)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    private var albumsHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("library_title")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                Text("tab_albums")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(PMColor.text)
            }

            Spacer()

            HStack(spacing: 10) {
                Text(verbatim: "\(sortedAlbums.count)/\(library.albums.count) \(String(localized: "albums_count")) · 按\(albumSort.label)")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                albumFilterField
                albumViewSwitcher
                albumSortMenu
            }
        }
        .padding(.horizontal, PMSpace.xxxl)
    }

    private var albumFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            TextField("", text: $albumFilter, prompt: Text(verbatim: "过滤专辑…"))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.text)
                .frame(width: 150)
            if !albumFilter.isEmpty {
                Button { albumFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var albumViewSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(AlbumViewMode.allCases, id: \.self) { mode in
                Button {
                    albumViewMode = mode
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(albumViewMode == mode ? PMColor.text : PMColor.textMuted)
                        .frame(width: 26, height: 22)
                        .background(albumViewMode == mode ? PMColor.bgElev : .clear, in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(Text(mode == .grid ? "grid_view" : "list_view"))
            }
        }
        .padding(2)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var albumSortMenu: some View {
        Menu {
            Picker("sort_by", selection: $albumSort) {
                ForEach(AlbumSortOrder.allCases, id: \.self) { order in
                    Text(verbatim: order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: albumSort.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(PMColor.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func macAlbumTile(_ album: Album, artworkSize: CGFloat) -> some View {
        let song = library.songs(forAlbum: album.id).first
        return VStack(alignment: .leading, spacing: 0) {
            CachedArtworkView(
                coverRef: song?.coverArtFileName,
                songID: song?.id ?? "",
                size: artworkSize,
                cornerRadius: PMRadius.m,
                sourceID: song?.sourceID,
                filePath: song?.filePath
            )
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

            Text(album.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
                .padding(.top, 10)

            if let artist = album.artistName, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .padding(.top, 1)
            }

            Text(verbatim: albumMetaLine(album))
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(width: artworkSize, alignment: .leading)
    }

    private func macAlbumListRow(_ album: Album) -> some View {
        let song = library.songs(forAlbum: album.id).first
        return HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song?.coverArtFileName,
                songID: song?.id ?? "",
                size: 44,
                cornerRadius: 6,
                sourceID: song?.sourceID,
                filePath: song?.filePath
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: [album.artistName, albumMetaLine(album)]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .pmRowBackground(cornerRadius: 6)
        .contentShape(Rectangle())
    }

    private func albumMetaLine(_ album: Album) -> String {
        var parts: [String] = []
        if let year = album.year {
            parts.append("\(year)")
        }
        parts.append("\(album.songCount) \(String(localized: "songs_count"))")
        return parts.joined(separator: " · ")
    }
    #endif
}
