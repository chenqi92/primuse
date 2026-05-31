import SwiftUI
import PrimuseKit

struct ArtistListView: View {
    let artists: [Artist]
    @State private var searchText: String = ""

    private var filteredArtists: [Artist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        #if os(macOS)
        macBody
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
            List(filteredArtists) { artist in
                NavigationLink(value: artist) {
                    HStack(spacing: 12) {
                        CachedArtworkView(artistID: artist.id, artistName: artist.name,
                                          size: 44, cornerRadius: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name)
                                .font(.body)

                            Text("\(artist.albumCount) \(String(localized: "albums_count")) · \(artist.songCount) \(String(localized: "songs_count"))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText,
                        placement: .toolbar,
                        prompt: Text("search_artists_prompt"))
        }
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
                        ArtistDetailView(artist: artist)
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
            TextField("", text: $searchText, prompt: Text(verbatim: "过滤艺术家…"))
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
                CachedArtworkView(artistID: artist.id, artistName: artist.name,
                                  size: 36, cornerRadius: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
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
