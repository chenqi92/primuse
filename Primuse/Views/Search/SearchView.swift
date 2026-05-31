import SwiftUI
import MusicKit
import PrimuseKit

struct SearchView: View {
    private static let recentSearchesKey = "search_recent_queries"
    private static let recentSearchLimit = 12

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(AppleMusicService.self) private var appleMusic
    @Binding var searchText: String
    @State private var searchResults: [LibrarySearchResult] = []
    @State private var matchingAlbums: [PrimuseKit.Album] = []
    @State private var recentSearches: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var lyricsSearchCache = LibrarySearchCache()
    /// 是否正在跑一次搜索 (含 debounce + detached worker)。用来在结果还没
    /// 出来时显示 loading 占位, 避免 200ms+ 窗口里先闪一下 "无匹配" 再
    /// 跳到结果。
    @State private var isSearching: Bool = false
    /// 当前已经渲染的结果对应的 query。如果它与 searchText 不一致, 说明
    /// 屏幕上还是上一轮的旧结果, ContentUnavailableView 不该出来。
    @State private var renderedQuery: String = ""
    /// 自增 generation token — 防止旧 task 的 defer 覆盖新一轮 performSearch
    /// 设的 isSearching 状态。task 完成时只在 gen 还匹配时才 reset。
    @State private var searchGeneration: Int = 0

    var body: some View {
        // macOS: 不再自带 NavigationStack —— SearchView 已经渲染在
        // MacDetailContainer 的栈里, 点专辑/艺术家结果时直接 push 到主栈,
        // 跟从专辑网格点进去走同一条导航 (返回按钮 / 路由复位都一致), 不会
        // 被困在搜索页自己的嵌套栈里。iOS 仍需要自己的 NavigationStack。
        Group {
            #if os(macOS)
            macBody
            #else
            NavigationStack {
                iosBody
            }
            #endif
        }
        .onAppear(perform: loadRecentSearches)
        .onReceive(NotificationCenter.default.publisher(for: CloudKVSSync.externalChangeNotification)) { note in
            guard let key = note.userInfo?["key"] as? String,
                  key == Self.recentSearchesKey else { return }
            loadRecentSearches()
        }
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
            appleMusic.search(query: newValue)
        }
        .onChange(of: library.searchRevision) { _, _ in
            lyricsSearchCache = LibrarySearchCache()
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var iosBody: some View {
        Group {
            if searchText.isEmpty {
                if library.visibleSongs.isEmpty {
                    EmptyStateView(
                        titleKey: "search_empty_library",
                        descriptionKey: "search_empty_library_desc",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    recentSearchView
                }
            } else if searchResults.isEmpty && matchingAlbums.isEmpty && appleMusic.searchResults.isEmpty {
                if isSearching || renderedQuery != searchText {
                    searchingPlaceholder
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                searchResultsView
            }
        }
        .navigationTitle("search_title")
        .toolbarTitleDisplayMode(.inlineLarge)
        .searchable(text: $searchText, prompt: Text("search_prompt"))
        .onSubmit(of: .search) { addRecentSearch(searchText) }
        .navigationDestination(for: PrimuseKit.Album.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: PrimuseKit.Artist.self) { ArtistDetailView(artist: $0) }
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            macSearchHeader
            macSearchContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .onSubmit(of: .search) { addRecentSearch(searchText) }
        // 注意: Album/Artist 的 navigationDestination 由 MacDetailContainer 的
        // NavigationStack 统一注册, 这里不再重复声明 (否则会重复 destination)。
    }

    /// 顶部 48pt 圆角搜索框 + 过滤芯片。搜索框其实绑在主窗口 PMTitleBar 上, 这里
    /// 仅展示当前查询并提供快速清除入口, 视觉上跟设计稿 S-01 对齐。
    private var macSearchHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(PMColor.brand)

                if searchText.isEmpty {
                    Text("search_placeholder_universal")
                        .font(.system(size: 14))
                        .foregroundStyle(PMColor.textFaint)
                } else {
                    Text(verbatim: searchText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                }

                Spacer()

                Text(verbatim: "本地 · Apple Music")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(PMColor.glassBtn, in: Capsule())
                    .overlay { Capsule().strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }

                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .pmCard(cornerRadius: 12)

            HStack(spacing: 8) {
                chipText("\(String(localized: "search_chip_all")) · \(macTotalResultCount)", active: true)
                chipText("\(String(localized: "tab_songs")) · \(searchResults.count)", active: false)
                chipText("\(String(localized: "tab_albums")) · \(matchingAlbums.count)", active: false)
                chipText("\(String(localized: "tab_artists")) · \(matchingArtistCount)", active: false)
                chipText("歌词命中 · \(searchResults.filter { $0.matchKind == .lyrics }.count)", active: false)
                chipText("Apple Music · \(appleMusic.searchResults.count)", active: false)
                Spacer()
            }
        }
        .padding(.horizontal, PMSpace.xxxl)
        .padding(.top, PMSpace.l)
        .padding(.bottom, PMSpace.m)
    }

    @ViewBuilder
    private var macSearchContent: some View {
        if searchText.isEmpty {
            if library.visibleSongs.isEmpty {
                EmptyStateView(
                    titleKey: "search_empty_library",
                    descriptionKey: "search_empty_library_desc",
                    systemImage: "magnifyingglass"
                )
            } else {
                macRecentSearchView
            }
        } else if searchResults.isEmpty && matchingAlbums.isEmpty && appleMusic.searchResults.isEmpty {
            if isSearching || renderedQuery != searchText {
                macSearchingPlaceholder
            } else {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            macSearchResultsView
        }
    }

    private var macRecentSearchView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    macSectionLabel("recent_searches")
                    if recentSearches.isEmpty {
                        Text("search_prompt")
                            .font(.system(size: 12.5))
                            .foregroundStyle(PMColor.textFaint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pmCard(cornerRadius: 10)
                    } else {
                        HStack(alignment: .top) {
                            MacSearchFlowLayout(spacing: 8, rowSpacing: 8) {
                                ForEach(recentSearches, id: \.self) { query in
                                    macRecentSearchChip(query)
                                }
                            }
                            Spacer(minLength: 16)
                            Button("clear_all", role: .destructive, action: clearRecentSearches)
                                .font(.system(size: 11.5))
                                .buttonStyle(.plain)
                                .foregroundStyle(PMColor.bad)
                        }
                    }
                }

                HStack(spacing: 14) {
                    macSummaryTile(value: "\(library.visibleSongs.count)", label: "tab_songs", icon: "music.note")
                    macSummaryTile(value: "\(library.albums.count)", label: "tab_albums", icon: "square.stack")
                    macSummaryTile(value: "\(library.artists.count)", label: "tab_artists", icon: "music.mic")
                }
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.bottom, 100)
        }
        .background(PMColor.bg)
    }

    private var macSearchResultsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 32, alignment: .top),
                          GridItem(.flexible(), spacing: 32, alignment: .top)],
                alignment: .leading,
                spacing: 24
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    macTopMatchSection
                    macSongBucket(kind: .metadata, title: "search_section_metadata")
                    macSongBucket(kind: .lyrics, title: "search_section_lyrics")
                    macSongBucket(kind: .fuzzy, title: "search_section_fuzzy")
                }

                VStack(alignment: .leading, spacing: 24) {
                    macAlbumsSection
                    macAppleMusicSection
                    macRecentSearchInlineSection
                }
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.bottom, 100)
        }
        .background(PMColor.bg)
    }

    private var macSearchingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("search_running")
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PMColor.bg)
    }

    private var macTopMatchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            macSectionLabelText("顶部匹配")
            if let album = matchingAlbums.first {
                NavigationLink(value: album) {
                    macTopCard(title: album.title,
                               subtitle: "\(album.artistName ?? "") · \(String(localized: "tab_albums"))",
                               systemImage: "square.stack",
                               album: album)
                }
                .buttonStyle(.plain)
            } else if let result = searchResults.first {
                Button {
                    playSong(result.song, lyricsHint: result.lyricSnippet, matchKind: result.matchKind)
                } label: {
                    macTopCard(title: result.song.title,
                               subtitle: result.song.artistName ?? "",
                               systemImage: "music.note",
                               song: result.song)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var macAlbumsSection: some View {
        if !matchingAlbums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                macSectionLabel("tab_albums")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(Array(matchingAlbums.prefix(6))) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 7) {
                                CachedArtworkView(albumID: album.id,
                                                  albumTitle: album.title,
                                                  artistName: album.artistName,
                                                  size: nil,
                                                  cornerRadius: 6)
                                    .aspectRatio(1, contentMode: .fit)
                                Text(album.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(PMColor.text)
                                    .lineLimit(1)
                                Text(album.artistName ?? "")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(PMColor.textFaint)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var macAppleMusicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            macSectionLabelText("Apple Music · Catalog")
            HStack(spacing: 10) {
                Image(systemName: "applelogo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color(red: 0.98, green: 0.14, blue: 0.23), in: .rect(cornerRadius: 4))
                Text(appleMusicStatusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                Spacer()
            }
            .padding(14)
            .pmCard(cornerRadius: 10)

            ForEach(appleMusic.searchResults.prefix(5), id: \.id) { song in
                Button {
                    Task { await appleMusic.play(song) }
                } label: {
                    HStack(spacing: 10) {
                        AsyncImage(url: song.artwork?.url(width: 64, height: 64)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                RoundedRectangle(cornerRadius: 5).fill(PMColor.rowHover)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(PMColor.text)
                                .lineLimit(1)
                            Text(song.artistName)
                                .font(.system(size: 10.5))
                                .foregroundStyle(PMColor.textFaint)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .pmRowBackground(cornerRadius: 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var macRecentSearchInlineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            macSectionLabel("recent_searches")
            MacSearchFlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(recentSearches.prefix(8), id: \.self) { query in
                    macRecentSearchChip(query)
                }
            }
        }
    }

    private func macRecentSearchChip(_ query: String) -> some View {
        HStack(spacing: 6) {
            Button {
                addRecentSearch(query)
                searchText = query
            } label: {
                Text(verbatim: query)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Button {
                removeRecentSearch(query)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 12, height: 12)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("delete"))
        }
        .font(.system(size: 11))
        .foregroundStyle(PMColor.textMuted)
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 24)
        .background(PMColor.glassBtn, in: Capsule())
        .overlay { Capsule().strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }
    }

    @ViewBuilder
    private func macSongBucket(kind: LibrarySearchMatchKind, title: LocalizedStringKey) -> some View {
        let bucket = Array(searchResults.filter { $0.matchKind == kind }.prefix(kind == .lyrics ? 3 : 6))
        if !bucket.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                macSectionLabel(title)
                ForEach(bucket) { result in
                    if kind == .lyrics, let snippet = result.lyricSnippet {
                        macLyricsResultCard(result: result, snippet: snippet)
                    } else {
                        macSongResultRow(result)
                    }
                }
            }
        }
    }

    private func macTopCard(title: String,
                            subtitle: String,
                            systemImage: String,
                            album: PrimuseKit.Album? = nil,
                            song: PrimuseKit.Song? = nil) -> some View {
        HStack(spacing: 16) {
            Group {
                if let song {
                    CachedArtworkView(coverRef: song.coverArtFileName,
                                      songID: song.id,
                                      size: 80,
                                      cornerRadius: 40,
                                      sourceID: song.sourceID,
                                      filePath: song.filePath)
                } else if let album {
                    CachedArtworkView(albumID: album.id,
                                      albumTitle: album.title,
                                      artistName: album.artistName,
                                      size: 80,
                                      cornerRadius: 40)
                } else {
                    Circle()
                        .fill(PMColor.rowHover)
                        .frame(width: 80, height: 80)
                        .overlay { Image(systemName: systemImage).foregroundStyle(PMColor.textFaint) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(PMColor.brand, in: Circle())
        }
        .padding(16)
        .pmCard(cornerRadius: 12)
    }

    private func macSongResultRow(_ result: LibrarySearchResult) -> some View {
        Button {
            playSong(result.song, lyricsHint: result.lyricSnippet, matchKind: result.matchKind)
        } label: {
            HStack(spacing: 12) {
                CachedArtworkView(coverRef: result.song.coverArtFileName,
                                  songID: result.song.id,
                                  size: 32,
                                  cornerRadius: 5,
                                  sourceID: result.song.sourceID,
                                  filePath: result.song.filePath)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.song.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(result.song.artistName ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
                Spacer()
                Text(formatSearchTime(result.song.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textMuted)
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .pmRowBackground(cornerRadius: 6)
        }
        .buttonStyle(.plain)
    }

    private func macLyricsResultCard(result: LibrarySearchResult, snippet: String) -> some View {
        Button {
            playSong(result.song, lyricsHint: snippet, matchKind: .lyrics)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(result.song.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(snippet)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(2)
                Text("跳到歌词上下文")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                if let timestamp = result.lyricTimestamp {
                    Text(verbatim: "命中 \(formatSearchTime(timestamp))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PMColor.rowHover, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func macSummaryTile(value: String, label: LocalizedStringKey, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.brand)
            Text(verbatim: value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(PMColor.text)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pmCard(cornerRadius: 12)
    }

    private func macSectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    private func macSectionLabelText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    private func chipText(_ title: String, active: Bool) -> some View {
        Text(verbatim: title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? .white : PMColor.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                active ? AnyShapeStyle(PMColor.brand) : AnyShapeStyle(PMColor.glassBtn),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(active ? .clear : PMColor.cardBorder, lineWidth: 0.5)
            }
    }

    private var macTotalResultCount: Int {
        searchResults.count + matchingAlbums.count + matchingArtistCount + appleMusic.searchResults.count
    }

    /// 从搜索结果歌曲里反推 distinct 艺术家数 — 没有专用 artist search 结果时
    /// 用这个近似值给搜索芯片显示计数。
    private var matchingArtistCount: Int {
        var seen = Set<String>()
        var distinct = 0
        for r in searchResults {
            let name = r.song.artistName ?? ""
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            distinct += 1
        }
        return distinct
    }

    private var appleMusicStatusText: String {
        switch appleMusic.authState {
        case .notDetermined:
            return String(localized: "apple_music_notice_notDetermined")
        case .denied, .restricted:
            return String(localized: "apple_music_notice_denied")
        case .authorized:
            guard AppleMusicFeatureSettings.catalogSearchEnabled else {
                return "Apple Music · Catalog 搜索已关闭"
            }
            if appleMusic.isSearching {
                return String(localized: "search_apple_music_loading")
            }
            if let error = appleMusic.lastSearchError {
                return error
            }
            return "已订阅 · 同步用户库 · \(appleMusic.searchResults.count) 个结果"
        }
    }

    #endif

    private func formatSearchTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var recentSearchView: some View {
        List {
            if !recentSearches.isEmpty {
                Section {
                    ForEach(recentSearches, id: \.self) { query in
                        Button {
                            addRecentSearch(query)
                            searchText = query
                        } label: {
                            Label(query, systemImage: "clock")
                        }
                    }
                    .onDelete(perform: deleteRecentSearches)
                } header: {
                    HStack {
                        Text("recent_searches")
                        Spacer()
                        Button("clear_all", role: .destructive, action: clearRecentSearches)
                            .font(.caption)
                    }
                }
            }

            Section {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                    Text("\(library.visibleSongs.count) \(String(localized: "tab_songs"))")
                    Spacer()
                    Text("\(library.albums.count) \(String(localized: "tab_albums"))")
                    Text("·")
                    Text("\(library.artists.count) \(String(localized: "tab_artists"))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("library")
            }
        }
    }

    private var searchResultsView: some View {
        List {
            // 旧结果仍在屏上, 但新一轮搜索还在跑 — 顶部加一条细 progress,
            // 让用户知道结果会刷新, 而不是误以为屏幕卡住。
            if isSearching && renderedQuery != searchText {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("search_running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Albums matching — 点 row 跳到 AlbumDetailView (整张专辑曲目列表)。
            if !matchingAlbums.isEmpty {
                Section("tab_albums") {
                    ForEach(matchingAlbums.prefix(5)) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                CachedArtworkView(albumID: album.id, albumTitle: album.title,
                                                  artistName: album.artistName, size: 44, cornerRadius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).font(.subheadline).lineLimit(1)
                                    Text(album.artistName ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            // Songs grouped by match kind — 用户能一眼区分"标题/艺术家精确命中"、
            // "歌词命中"和"拼音/模糊命中", 类似 Apple Music 搜索的分组。
            // 每组限 40 条 (worker 整体也限 120), 防止单组撑满屏。
            songSection(kind: .metadata, titleKey: "search_section_metadata")
            songSection(kind: .lyrics, titleKey: "search_section_lyrics")
            songSection(kind: .fuzzy, titleKey: "search_section_fuzzy")

            // Apple Music — 即使没结果也显示 section 标题, 让用户一眼看到
            // "为什么没有 Apple Music 推荐" (未授权 / 搜索失败 / 真没结果)。
            appleMusicSection
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var appleMusicSection: some View {
        Section {
            switch appleMusic.authState {
            case .notDetermined:
                Label("apple_music_notice_notDetermined", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            case .denied, .restricted:
                Label("apple_music_notice_denied", systemImage: "lock.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .authorized:
                if appleMusic.isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("search_apple_music_loading").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let err = appleMusic.lastSearchError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                } else if appleMusic.searchResults.isEmpty {
                    if appleMusic.lastSearchHitCount == 0 {
                        Label("apple_music_notice_no_results", systemImage: "magnifyingglass")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // hitCount == -1 表示还没搜过, 不显示状态 (避免空 section)
                } else {
                    ForEach(appleMusic.searchResults, id: \.id) { song in
                        appleMusicRow(song)
                    }
                }
                if let err = appleMusic.lastPlaybackError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            HStack {
                Image(systemName: "applelogo")
                Text("search_section_apple_music")
            }
        }
    }

    /// 一组按 matchKind 过滤的歌曲 Section。空组直接 noop, 不显示标题。
    @ViewBuilder
    private func songSection(kind: LibrarySearchMatchKind, titleKey: LocalizedStringKey) -> some View {
        let bucket = searchResults.filter { $0.matchKind == kind }.prefix(40)
        if !bucket.isEmpty {
            Section {
                ForEach(Array(bucket)) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        SongRowView(
                            song: result.song,
                            isPlaying: player.currentSong?.id == result.song.id,
                            context: SongRowView.context(for: result.song, sourcesStore: sourcesStore, backfill: backfill)
                        )
                        if result.matchKind == .lyrics, let snippet = result.lyricSnippet {
                            // 歌词命中: 把命中的句子(含上下文)展开, 让用户一眼看到为什么命中。
                            VStack(alignment: .leading, spacing: 3) {
                                if let timestamp = result.lyricTimestamp {
                                    Text(verbatim: "命中 \(formatSearchTime(timestamp))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tint)
                                }
                                Text(snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 54)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playSong(result.song, lyricsHint: result.lyricSnippet, matchKind: result.matchKind)
                    }
                }
            } header: {
                Text(titleKey)
            }
        }
    }

    private func appleMusicRow(_ song: MusicKit.Song) -> some View {
        Button {
            Task { await appleMusic.play(song) }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: song.artwork?.url(width: 88, height: 88)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.subheadline).lineLimit(1)
                    Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "applelogo").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            searchResults = []
            matchingAlbums = []
            isSearching = false
            renderedQuery = ""
            return
        }

        let songsSnapshot = library.visibleSongs
        let albumsSnapshot = library.visibleAlbums
        let cacheSnapshot = lyricsSearchCache

        searchGeneration += 1
        let myGen = searchGeneration
        isSearching = true

        searchTask = Task {
            // 不管成功 / 取消 / 出错都要把 isSearching 关回去, 否则 UI 卡在
            // loading 状态。用 generation 防止旧 task 的 defer 覆盖新一轮
            // performSearch 设的状态 — 新 task 已 bump generation 时, 旧 task
            // defer 看到 gen 不匹配就不动 state。
            defer {
                if myGen == searchGeneration {
                    isSearching = false
                }
            }
            // Debounce 200ms
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let worker = Task.detached(priority: .userInitiated) {
                LibrarySearchWorker.compute(
                    query: query,
                    songs: songsSnapshot,
                    albums: albumsSnapshot,
                    cache: cacheSnapshot
                )
            }
            let output = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            searchResults = output.songResults
            matchingAlbums = output.albumResults
            lyricsSearchCache = output.cache
            renderedQuery = query
            isSearching = false
        }
    }

    private var searchingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("search_running")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(.systemBackground))
        #else
        .background(Color(NSColor.windowBackgroundColor))
        #endif
    }

    private func playSong(_ song: PrimuseKit.Song, lyricsHint: String? = nil, matchKind: LibrarySearchMatchKind? = nil) {
        let queue = searchResults.map(\.song).filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        // 歌词命中: 让 NowPlayingView 加载完歌词后自动 seek 到那行;
        // 同时打开全屏 NowPlayingView 让用户能立刻看到上下文。
        if matchKind == .lyrics, let snippet = lyricsHint, !snippet.isEmpty {
            player.requestLyricsJump(songID: song.id, snippet: snippet)
            NotificationCenter.default.post(name: .primuseRequestShowNowPlaying, object: nil)
        }
        Task { await player.play(song: song) }
        addRecentSearch(searchText)
    }

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? []
    }

    private func addRecentSearch(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }

        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
        recentSearches.insert(trimmedQuery, at: 0)

        if recentSearches.count > Self.recentSearchLimit {
            recentSearches = Array(recentSearches.prefix(Self.recentSearchLimit))
        }

        saveRecentSearches()
    }

    private func deleteRecentSearches(at offsets: IndexSet) {
        recentSearches.remove(atOffsets: offsets)
        saveRecentSearches()
    }

    private func clearRecentSearches() {
        recentSearches.removeAll()
        saveRecentSearches()
    }

    private func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        saveRecentSearches()
    }

    private func saveRecentSearches() {
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchesKey)
        CloudKVSSync.shared.markChanged(key: Self.recentSearchesKey)
    }
}

#if os(macOS)
private struct MacSearchFlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 480
        let rows = rows(in: maxWidth, subviews: subviews)
        return CGSize(width: maxWidth, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + rowSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func rows(in maxWidth: CGFloat, subviews: Subviews) -> (height: CGFloat, count: Int) {
        guard subviews.isEmpty == false else { return (0, 0) }

        var x: CGFloat = 0
        var height: CGFloat = 0
        var lineHeight: CGFloat = 0
        var count = 1

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                height += lineHeight + rowSpacing
                x = 0
                lineHeight = 0
                count += 1
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        height += lineHeight
        return (height, count)
    }
}
#endif
