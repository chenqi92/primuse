import SwiftUI
import PrimuseKit
#if os(macOS)
import AppKit
#endif

/// Reference-backed storage prevents AttributeGraph from applying
/// `Array<Song>.==` to the list cache whenever metadata changes. Song's
/// synthesized equality includes lyricsText, so a value-backed SwiftUI state
/// made each background backfill publication walk the full lyrics library.
@MainActor
@Observable
private final class SongListRowModel {
    private final class SongReference {
        let value: Song

        init(_ value: Song) {
            self.value = value
        }
    }

    private var reference: SongReference

    var song: Song { reference.value }

    init(song: Song) {
        reference = SongReference(song)
    }

    func replace(with song: Song) {
        // SongReference deliberately has identity equality. Assigning a new
        // Song value therefore notifies only this row without Observation
        // comparing the complete lyricsText payload first.
        reference = SongReference(song)
    }
}

@MainActor
@Observable
private final class SongListCache {
    /// This is the List's only structural observable value. Metadata patches
    /// never mutate it, so backfill updates cannot rebuild the whole List.
    private(set) var sortedSongIDs: [String] = []

    @ObservationIgnored private var songsByID: [String: Song] = [:]
    @ObservationIgnored private var rowModelsByID: [String: SongListRowModel] = [:]

    func replace(with songs: [Song]) {
        let nextSongsByID = Dictionary(
            songs.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        // Existing row models are already kept current by `patch`. Replacing
        // all previously visited models here would turn an explicit sort into
        // hundreds/thousands of independent row invalidations before the List
        // even applies its new ID order.
        rowModelsByID = rowModelsByID.filter { nextSongsByID[$0.key] != nil }
        songsByID = nextSongsByID
        sortedSongIDs = songs.map(\.id)
    }

    func patch(_ replacements: [String: Song]) {
        guard !replacements.isEmpty else { return }
        for (songID, song) in replacements {
            songsByID[songID] = song
            rowModelsByID[songID]?.replace(with: song)
        }
    }

    func song(id: String) -> Song? {
        songsByID[id]
    }

    func rowModel(id: String) -> SongListRowModel? {
        if let model = rowModelsByID[id] {
            return model
        }
        guard let song = songsByID[id] else { return nil }
        let model = SongListRowModel(song: song)
        rowModelsByID[id] = model
        return model
    }

    func releaseRowModels() {
        rowModelsByID.removeAll(keepingCapacity: false)
    }
}

struct SongListView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    /// Keep only a lightweight scope in the view identity. Storing `[Song]`
    /// here made SwiftUI/AttributeGraph compare every Song (including its full
    /// lyricsText) whenever an ancestor refreshed.
    private let scope: Scope
    @State private var sortOrder: SongSortOrder = .title
    @State private var listCache = SongListCache()
    @State private var searchText: String = ""
    @State private var sortGeneration: Int = 0
    @State private var sortTask: Task<Void, Never>?
    #if os(macOS)
    @State private var macViewMode: MacSongsViewMode = .list
    @State private var macRowDensity: MacSongsRowDensity = .standard
    @State private var visibleColumns: Set<MacSongsColumn> = MacSongsColumn.defaultVisible
    /// 当前选中的数据源过滤 (nil = 全部)。设计稿 SourceFilterChips 是可点切换的。
    @State private var selectedSourceID: String? = nil
    @State private var showViewOptions = false
    @State private var showAddVisibleToPlaylist = false
    @State private var contextSongID: String?
    @State private var showContextAddToPlaylist = false
    @State private var showContextSongInfo = false
    @State private var showContextTagEditor = false
    @State private var exportError: String?
    /// songID → 播放次数, 由 PlayHistory 一次性折叠而来。重建只发生在
    /// onAppear 和 PlayHistory 变更通知时, 而不是每行重算 (否则 LazyVStack
    /// 滚动时每实例化一行都要 O(5000) 折叠+建字典)。
    @State private var playCountsBySongID: [String: Int] = [:]
    #endif

    private enum Scope: Hashable, Sendable {
        case library
        case source(String)
    }

    init(sourceID: String? = nil) {
        scope = sourceID.map(Scope.source) ?? .library
    }

    enum SongSortOrder: String, CaseIterable, Sendable {
        case title, artist, album, dateAdded, format

        var label: LocalizedStringKey {
            switch self {
            case .title: return "sort_title"
            case .artist: return "sort_artist"
            case .album: return "sort_album"
            case .dateAdded: return "sort_date_added"
            case .format: return "sort_format"
            }
        }
    }

    #if os(macOS)
    private enum MacSongsViewMode: String, CaseIterable, Hashable {
        case list, compact, grid

        var title: String {
            switch self {
            case .list: return "列表"
            case .compact: return "紧凑"
            case .grid: return "网格"
            }
        }

        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .compact: return "text.justify"
            case .grid: return "square.grid.3x3"
            }
        }
    }

    private enum MacSongsRowDensity: String, CaseIterable, Hashable {
        case compact, standard, relaxed

        var title: String {
            switch self {
            case .compact: return "紧凑"
            case .standard: return "标准"
            case .relaxed: return "宽松"
            }
        }

        var icon: String {
            switch self {
            case .compact: return "chevron.up"
            case .standard: return "line.3.horizontal"
            case .relaxed: return "chevron.down"
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .compact: return 3
            case .standard: return 6
            case .relaxed: return 10
            }
        }
    }

    private enum MacSongsColumn: String, CaseIterable, Hashable, Identifiable {
        case artist, album, format, duration, plays, source, year, rating, dateAdded, bitRate

        var id: String { rawValue }

        static let defaultVisible: Set<MacSongsColumn> = [.artist, .album, .format, .duration, .plays, .source]

        var title: String {
            switch self {
            case .artist: return "艺术家"
            case .album: return "专辑"
            case .format: return "格式 / 采样率"
            case .duration: return "时长"
            case .plays: return "播放次数"
            case .source: return "源"
            case .year: return "年份"
            case .rating: return "评分"
            case .dateAdded: return "日期添加"
            case .bitRate: return "比特率"
            }
        }
    }
    #endif

    var body: some View {
        content
            .onAppear { scheduleSortedRecompute() }
            .onChange(of: sortOrder) { _, _ in scheduleSortedRecompute() }
            .onChange(of: library.visibleSongCollectionRevision) { _, _ in
                scheduleSortedRecompute(debounced: true)
            }
            .onChange(of: library.songReplacementToken) { _, _ in
                applyLibrarySongReplacements()
            }
            .onDisappear {
                sortTask?.cancel()
                sortTask = nil
                listCache.releaseRowModels()
            }
            #if os(macOS)
            .sheet(isPresented: $showAddVisibleToPlaylist) {
                MacAddVisibleSongsToPlaylistSheet(
                    songs: filteredSongs.filteredPlayable(),
                    onClose: { showAddVisibleToPlaylist = false }
                )
                .frame(width: 420, height: 520)
            }
            .sheet(isPresented: $showContextAddToPlaylist) {
                if let song = selectedContextSong {
                    AddToPlaylistSheet(song: song)
                }
            }
            .sheet(isPresented: $showContextSongInfo) {
                if let song = selectedContextSong {
                    SongInfoSheet(song: song)
                }
            }
            .sheet(isPresented: $showContextTagEditor) {
                if let song = selectedContextSong {
                    TagEditorView(song: song) { updated in
                        player.syncSongMetadata(updated)
                        player.forceRefreshNowPlayingArtwork()
                    }
                }
            }
            .alert("导出失败",
                   isPresented: Binding(get: { exportError != nil },
                                        set: { if !$0 { exportError = nil } })) {
                Button("done", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            #endif
    }

    private var songs: [Song] {
        switch scope {
        case .library:
            library.visibleSongs
        case .source(let sourceID):
            library.visibleSongs(forSourceID: sourceID)
        }
    }

    @ViewBuilder
    private var content: some View {
        if songs.isEmpty {
            EmptyStateView(
                titleKey: "no_songs",
                descriptionKey: "no_songs_desc",
                systemImage: "music.note"
            )
        } else {
            #if os(macOS)
            macSongList
            #else
            iosSongList
            #endif
        }
    }

    private var iosSongList: some View {
        List {
            ForEach(filteredSongIDs, id: \.self) { songID in
                if let model = listCache.rowModel(id: songID) {
                    IOSSongListRow(model: model, onPlay: playSong)
                }
            }
        }
        .listStyle(.plain)
        .toolbar { sortToolbarItem }
    }

    #if os(macOS)
    private var macSongList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MacLibraryHeader(
                    eyebrow: "library_title",
                    title: String(localized: "tab_songs"),
                    subtitle: librarySubtitle,
                    iconSystemName: "music.note",
                    coverSong: songs.first(where: { $0.coverArtFileName?.isEmpty == false }),
                    onPlay: { playLibrary(shuffled: false) },
                    onShuffle: { playLibrary(shuffled: true) },
                    moreMenu: listMoreMenu
                )

                VStack(alignment: .leading, spacing: PMSpace.l) {
                    sourceFilterChips
                    macToolbarRow

                    if filteredSongs.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 48)
                    } else {
                        macSongsContent
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.m14)
            }
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .onAppear { rebuildPlayCounts() }
        .onReceive(NotificationCenter.default.publisher(for: .primuseListeningStatsDidChange)) { _ in
            rebuildPlayCounts()
        }
    }

    private var sourceFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip(title: String(localized: "search_chip_all"),
                           count: songs.count, color: nil,
                           active: selectedSourceID == nil) {
                    selectedSourceID = nil
                }

                ForEach(sourcesStore.allSources.prefix(5), id: \.id) { source in
                    let count = songs.filter { $0.sourceID == source.id }.count
                    if count > 0 {
                        sourceChip(title: source.name, count: count,
                                   color: sourceColor(source),
                                   active: selectedSourceID == source.id) {
                            // 再点一次已选中的源 = 取消过滤回到全部。
                            selectedSourceID = (selectedSourceID == source.id) ? nil : source.id
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func sourceChip(title: String, count: Int, color: Color?, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
                Text(verbatim: title)
                    .lineLimit(1)
                Text(verbatim: count.formatted())
                    .monospacedDigit()
                    .opacity(0.65)
            }
            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? .white : PMColor.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(active ? PMColor.brand : PMColor.glassBtn, in: Capsule())
            .overlay {
                Capsule().strokeBorder(active ? .clear : PMColor.cardBorder, lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sourceColor(_ source: MusicSource) -> Color {
        switch source.type {
        case .baiduPan: return PMColor.brand
        case .appleMusic, .appleMusicLibrary: return Color(red: 0.64, green: 0.48, blue: 0.96)
        case .synology, .qnap, .ugreen, .fnos: return Color(red: 0.31, green: 0.68, blue: 0.95)
        case .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3: return Color(red: 0.45, green: 0.82, blue: 0.56)
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic: return Color(red: 0.98, green: 0.66, blue: 0.28)
        case .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123: return Color(red: 0.42, green: 0.68, blue: 0.96)
        case .local: return PMColor.textFaint
        }
    }

    private var macToolbarRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                TextField("", text: $searchText, prompt: Text("filter_songs_placeholder"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.text)
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 26)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }

            Spacer()

            Text("sort_by")
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textFaint)

            Menu {
                Picker("sort_by", selection: $sortOrder) {
                    ForEach(SongSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Text(sortOrder.label)
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
            // 自己画了 chevron.down, 隐藏系统 Menu 默认的小箭头, 否则两个箭头叠一起。
            .menuIndicator(.hidden)
            .fixedSize()

            viewModeSegment

            PMRoundBtn(icon: "slider.horizontal.3", size: 26, iconSize: 12, style: .glass,
                       help: "视图选项") {
                showViewOptions.toggle()
            }
            .popover(isPresented: $showViewOptions, arrowEdge: .bottom) {
                viewOptionsPopover
            }
        }
        .padding(.top, -4)
    }

    private var viewModeSegment: some View {
        HStack(spacing: 1) {
            ForEach(MacSongsViewMode.allCases, id: \.self) { mode in
                Button {
                    macViewMode = mode
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(macViewMode == mode ? PMColor.brand : PMColor.textMuted)
                        .frame(width: 26, height: 22)
                        .background(macViewMode == mode ? PMColor.bgElev : .clear, in: .rect(cornerRadius: 5))
                        .shadow(color: macViewMode == mode ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: mode.title))
            }
        }
        .padding(2)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))
    }

    private var librarySubtitle: String {
        let playableCount = songs.filter(\.isPlayable).count
        return "\(songs.count) \(String(localized: "songs_count")) · \(playableCount) \(String(localized: "home_playable")) · \(totalDuration.formattedShort)"
    }

    @ViewBuilder
    private var macSongsContent: some View {
        switch macViewMode {
        case .list:
            songTable
        case .compact:
            compactSongList
        case .grid:
            songGrid
        }
    }

    private var songTable: some View {
        VStack(spacing: 0) {
            tableHeader
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(PMColor.bg)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            LazyVStack(spacing: 1) {
                ForEach(Array(filteredSongIDs.enumerated()), id: \.element) { index, songID in
                    if let song = listCache.song(id: songID) {
                        songTableRow(song, index: index)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 设计稿表头 9 列: # / cover / 标题 / 艺术家 / 专辑 / 格式 / 时长 / 播放 / 源
    /// gridTemplateColumns: 32px 32px 1fr 1.2fr 1fr 100px 80px 80px 60px
    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 32, alignment: .leading)
            Color.clear.frame(width: 32, height: 1)
            // 3 个 flex 列等分 — 之前 artist 加 layoutPriority(0.2) 反而导致 SwiftUI
            // 把所有 flexible 空间全分给它, title / album 被压成 0 宽显示空。
            Text("sort_title").frame(maxWidth: .infinity, alignment: .leading)
            if visibleColumns.contains(.artist) {
                Text("sort_artist").frame(maxWidth: .infinity, alignment: .leading)
            }
            if visibleColumns.contains(.album) {
                Text("sort_album").frame(maxWidth: .infinity, alignment: .leading)
            }
            if visibleColumns.contains(.format) {
                Text("sort_format").frame(width: 100, alignment: .leading)
            }
            if visibleColumns.contains(.duration) {
                Text("track_duration_short").frame(width: 80, alignment: .trailing)
            }
            if visibleColumns.contains(.plays) {
                Text("home_playable_count_short").frame(width: 80, alignment: .trailing)
            }
            if visibleColumns.contains(.source) {
                Text("source").frame(width: 60, alignment: .leading)
            }
            if visibleColumns.contains(.year) {
                Text("year_label").frame(width: 54, alignment: .trailing)
            }
            if visibleColumns.contains(.rating) {
                Text("rating").frame(width: 54, alignment: .trailing)
            }
            if visibleColumns.contains(.dateAdded) {
                Text("sort_date_added").frame(width: 92, alignment: .trailing)
            }
            if visibleColumns.contains(.bitRate) {
                Text("Bitrate").frame(width: 70, alignment: .trailing)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(PMColor.textFaint)
    }

    /// 一次性把 PlayHistory 折叠成 songID → count 字典, 避免每行 O(N) 扫描。
    /// 结果写入 @State playCountsBySongID, 仅在 onAppear / 变更通知时调用。
    private func rebuildPlayCounts() {
        var dict: [String: Int] = [:]
        for e in PlayHistoryStore.shared.entries {
            dict[e.songID, default: 0] += 1
        }
        playCountsBySongID = dict
    }

    @ViewBuilder
    private func songTableRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        let liked = playlistContains(song)
        let plays = playCountsBySongID[song.id] ?? 0
        let source = sourcesStore.sources.first(where: { $0.id == song.sourceID })
        Button { playSong(song) } label: {
            HStack(spacing: 12) {
                // # / play indicator
                ZStack {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .frame(width: 32, alignment: .leading)

                // Cover
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 28, cornerRadius: 4,
                    sourceID: song.sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .frame(width: 32, alignment: .leading)

                // Title + (optional heart)
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if liked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PMColor.brand)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if visibleColumns.contains(.artist) {
                    Text(song.artistName ?? "—")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if visibleColumns.contains(.album) {
                    Text(song.albumTitle ?? "—")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if visibleColumns.contains(.format) {
                    HStack(spacing: 6) {
                        PMFormatPill.forFormat(song.fileFormat.displayName)
                        if let sr = song.sampleRate, sr > 0 {
                            Text(verbatim: "\(sr / 1000)k")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(PMColor.textFaint)
                        }
                    }
                    .frame(width: 100, alignment: .leading)
                }

                if visibleColumns.contains(.duration) {
                    Text(song.duration.formattedDuration)
                        .font(.system(size: 11.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 80, alignment: .trailing)
                }

                if visibleColumns.contains(.plays) {
                    playCountText(plays)
                        .frame(width: 80, alignment: .trailing)
                }

                if visibleColumns.contains(.source) {
                    sourceCell(source)
                        .frame(width: 60, alignment: .leading)
                }

                if visibleColumns.contains(.year) {
                    Text(song.year.map(String.init) ?? "—")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 54, alignment: .trailing)
                }

                if visibleColumns.contains(.rating) {
                    Text(verbatim: "—")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                        .frame(width: 54, alignment: .trailing)
                }

                if visibleColumns.contains(.dateAdded) {
                    Text(song.dateAdded, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                        .frame(width: 92, alignment: .trailing)
                }

                if visibleColumns.contains(.bitRate) {
                    Text(song.bitRate.map { "\($0 / 1000)k" } ?? "—")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, macRowDensity.verticalPadding)
            .pmRowBackground(selected: isCurrent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { macSongContextMenu(for: song) }
    }

    /// 用源类型 hash 出稳定彩色点 (跟 sidebar 同算法)。
    @ViewBuilder
    private func playCountText(_ plays: Int) -> some View {
        if plays > 0 {
            Text("\(plays)")
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textMuted)
        } else {
            Text(verbatim: "—")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
        }
    }

    private func sourceCell(_ source: MusicSource?) -> some View {
        HStack(spacing: 5) {
            if let source {
                Circle()
                    .fill(macSourceDotColor(for: source))
                    .frame(width: 6, height: 6)
                Text(verbatim: source.name.components(separatedBy: "·").first?
                    .trimmingCharacters(in: .whitespaces) ?? source.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
            }
        }
    }

    private var compactSongList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(filteredSongIDs.enumerated()), id: \.element) { index, songID in
                if let song = listCache.song(id: songID) {
                    compactSongRow(song, index: index)
                }
            }
        }
        .padding(.top, 8)
    }

    private func compactSongRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        return Button { playSong(song) } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .frame(width: 28, alignment: .leading)

                HStack(spacing: 5) {
                    Text(song.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                        .lineLimit(1)
                    if playlistContains(song) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(PMColor.brand)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(song.artistName ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    PMFormatPill.forFormat(song.fileFormat.displayName)
                    if let sr = song.sampleRate, sr > 0 {
                        Text(verbatim: "\(sr / 1000)k")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .frame(width: 80, alignment: .leading)

                Text(song.duration.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isCurrent ? PMColor.brand.opacity(0.16) : .clear, in: .rect(cornerRadius: 4))
            .overlay(alignment: .bottom) {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { macSongContextMenu(for: song) }
    }

    private var songGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 6),
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(filteredSongIDs, id: \.self) { songID in
                if let song = listCache.song(id: songID) {
                    songGridTile(song, highlighted: player.currentSong?.id == song.id)
                }
            }
        }
        .padding(.top, 12)
    }

    private func songGridTile(_ song: Song, highlighted: Bool) -> some View {
        Button { playSong(song) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        cornerRadius: 8,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                    .aspectRatio(1, contentMode: .fit)

                    if highlighted {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(PMColor.brand, in: .circle)
                            .shadow(color: .black.opacity(0.30), radius: 8, y: 2)
                            .padding(8)
                    }
                }

                Text(song.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(highlighted ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 8)

                Text(song.artistName ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { macSongContextMenu(for: song) }
    }

    private var selectedContextSong: Song? {
        guard let contextSongID else { return nil }
        return library.songs.first { $0.id == contextSongID }
    }

    @ViewBuilder
    private func macSongContextMenu(for song: Song) -> some View {
        Section {
            Button {
                playSong(song)
            } label: {
                Label(String(localized: "play"), systemImage: "play.fill")
            }
            .disabled(!song.isPlayable)

            Button {
                player.insertNextInQueue([song])
            } label: {
                Label("插入下一首", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(!song.isPlayable)

            Button {
                player.appendToQueue([song])
            } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
            }
            .disabled(!song.isPlayable)
        }

        Section {
            Button {
                showSongInfo(for: song)
            } label: {
                Label(String(localized: "song_info"), systemImage: "info.circle")
            }

            Button {
                editTags(for: song)
            } label: {
                Label(String(localized: "tag_editor_menu"), systemImage: "tag")
            }

            Button {
                openScrapeWindow(for: song)
            } label: {
                Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
            }

            Button {
                addToPlaylist(song)
            } label: {
                Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
            }
        }

        Section {
            Button {
                library.toggleLiked(songID: song.id)
            } label: {
                Label(library.isLiked(songID: song.id) ? String(localized: "a11y_unlike") : String(localized: "a11y_like"),
                      systemImage: library.isLiked(songID: song.id) ? "heart.fill" : "heart")
            }

            ShareLink(item: "\(song.title) - \(song.artistName ?? "")") {
                Label(String(localized: "share"), systemImage: "square.and.arrow.up")
            }
        }
    }

    private func latestSong(_ song: Song) -> Song {
        library.songs.first { $0.id == song.id } ?? song
    }

    private func selectContextSong(_ song: Song) {
        contextSongID = song.id
    }

    private func showSongInfo(for song: Song) {
        selectContextSong(song)
        showContextSongInfo = true
    }

    private func editTags(for song: Song) {
        selectContextSong(song)
        showContextTagEditor = true
    }

    private func addToPlaylist(_ song: Song) {
        selectContextSong(song)
        showContextAddToPlaylist = true
    }

    private func openScrapeWindow(for song: Song) {
        let song = latestSong(song)
        ScrapeWindowController.shared.show(song: song) { updated in
            CachedArtworkView.invalidateCache(for: updated.id)
            if let oldRef = song.coverArtFileName {
                CachedArtworkView.invalidateCache(for: oldRef)
            }
            player.syncSongMetadata(updated)
            player.forceRefreshNowPlayingArtwork()
        }
    }

    private var listMoreMenu: AnyView {
        let playable = visiblePlayableSongs
        let visible = filteredSongs
        return AnyView(MacHeaderMoreMenu(sections: [
            [
                .init(icon: "text.line.last.and.arrowtriangle.forward",
                      title: "全部加入队列",
                      trailing: playable.count.formatted(),
                      enabled: !playable.isEmpty) {
                    player.appendToQueue(playable)
                },
                .init(icon: "text.line.first.and.arrowtriangle.forward",
                      title: "插入下一首",
                      enabled: !playable.isEmpty) {
                    player.insertNextInQueue(playable)
                },
                .init(icon: "text.badge.plus",
                      title: "加入歌单…",
                      enabled: !playable.isEmpty) {
                    showAddVisibleToPlaylist = true
                },
            ],
            [
                .init(icon: "shuffle",
                      title: "随机全部",
                      enabled: !playable.isEmpty) {
                    playLibrary(shuffled: true)
                },
            ],
            [
                .init(icon: "wand.and.stars",
                      title: "批量刮削缺失元数据",
                      trailing: visible.count.formatted(),
                      enabled: !visible.isEmpty && !scraperService.isScraping) {
                    scraperService.scrapeMissingMetadata(songs: visible, in: library)
                },
                .init(icon: "square.and.arrow.up",
                      title: "导出 M3U8…",
                      enabled: !playable.isEmpty) {
                    exportVisibleSongs(format: .m3u8)
                },
                .init(icon: "curlybraces",
                      title: "导出 JSON…",
                      enabled: !playable.isEmpty) {
                    exportVisibleSongs(format: .json)
                },
            ],
            [
                .init(icon: "list.bullet.rectangle",
                      title: "列显示设置…") {
                    showViewOptions = true
                },
            ],
        ]))
    }

    private var viewOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "视图选项")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)

            viewOptionsSection("显示方式") {
                segmentedIconPicker(MacSongsViewMode.allCases, selection: $macViewMode)
            }

            // 行高 / 显示列 只作用于「列表」视图 (紧凑、网格是固定密排布局, 不吃这些
            // 设置)。在别的模式下隐藏, 免得勾了列却不生效、看着对不上。
            if macViewMode == .list {
                viewOptionsSection("行高") {
                    segmentedIconPicker(MacSongsRowDensity.allCases, selection: $macRowDensity)
                }

                viewOptionsSection("显示列") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(MacSongsColumn.allCases) { column in
                            Button {
                                if visibleColumns.contains(column) {
                                    visibleColumns.remove(column)
                                } else {
                                    visibleColumns.insert(column)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(visibleColumns.contains(column) ? PMColor.brand : .clear)
                                            .frame(width: 14, height: 14)
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                    .strokeBorder(visibleColumns.contains(column) ? .clear : PMColor.dividerStrong, lineWidth: 1.5)
                                            }
                                        if visibleColumns.contains(column) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    Text(verbatim: column.title)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(visibleColumns.contains(column) ? PMColor.text : PMColor.textMuted)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                // 整行 (含复选框本身) 都可点, 不必非点中文字。
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        // 系统 popover 的半透材质叠在内容后面会让白色选中块显得过亮 / 发灰;
        // 铺一层 flat 不透明底 (不画圆角边框, 系统 chrome 会裁圆角, 不会双框),
        // 选中块就跟工具栏里的视图切换一样是"米色上一块白"的柔和效果。
        .background(PMColor.bg)
    }

    private func viewOptionsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textFaint)
            content()
        }
    }

    private func segmentedIconPicker<T: CaseIterable & Hashable>(_ values: T.AllCases, selection: Binding<T>) -> some View where T.AllCases: RandomAccessCollection {
        HStack(spacing: 2) {
            ForEach(Array(values), id: \.self) { value in
                let item = segmentInfo(for: value)
                Button {
                    selection.wrappedValue = value
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(verbatim: item.title)
                            .font(.system(size: 9, weight: selection.wrappedValue == value ? .semibold : .medium))
                    }
                    .foregroundStyle(selection.wrappedValue == value ? PMColor.brand : PMColor.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(selection.wrappedValue == value ? PMColor.bgElev : .clear, in: .rect(cornerRadius: 6))
                    .shadow(color: selection.wrappedValue == value ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                    // 整段都可点选, 而不是只点中图标/文字才生效。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
    }

    private func segmentInfo<T>(for value: T) -> (title: String, icon: String) {
        if let mode = value as? MacSongsViewMode { return (mode.title, mode.icon) }
        if let density = value as? MacSongsRowDensity { return (density.title, density.icon) }
        return ("", "circle")
    }

    private var visiblePlayableSongs: [Song] {
        filteredSongs.filteredPlayable()
    }

    private func exportVisibleSongs(format: PlaylistExporter.Format) {
        do {
            let playlist = Playlist(name: String(localized: "tab_songs"))
            let url = try PlaylistExporter.export(
                playlist: playlist,
                songs: visiblePlayableSongs,
                format: format,
                sourcesStore: sourcesStore
            )
            try PlaylistExporter.presentSavePanel(for: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func macSourceDotColor(for source: MusicSource) -> Color {
        let palette: [Color] = [
            PMColor.flac, PMColor.dsd, PMColor.warn, PMColor.brand,
            Color(red: 0.4, green: 0.7, blue: 0.95),
            Color(red: 0.7, green: 0.6, blue: 0.95),
        ]
        let h = source.type.rawValue.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return palette[h]
    }

    private func playlistContains(_ song: Song) -> Bool {
        library.isLiked(songID: song.id)
    }

    private func playLibrary(shuffled: Bool) {
        let candidates = filteredSongs.filteredPlayable()
        guard !candidates.isEmpty else { return }
        let queue = shuffled ? candidates.shuffled() : candidates
        guard let first = queue.first else { return }
        player.shuffleEnabled = shuffled
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }
    #endif

    private var sortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("sort_by", selection: $sortOrder) {
                    ForEach(SongSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
    }

    /// The List/ForEach data contains stable lightweight IDs only. Keeping
    /// `Song` values out of the view's structural output is important: SwiftUI
    /// may compare ForEach data when updating a List, and Song equality walks
    /// full lyrics text.
    private var filteredSongIDs: [String] {
        var base = listCache.sortedSongIDs
        #if os(macOS)
        if let selectedSourceID {
            base = base.filter { listCache.song(id: $0)?.sourceID == selectedSourceID }
        }
        #endif
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter { songID in
            guard let song = listCache.song(id: songID) else { return false }
            return song.title.localizedCaseInsensitiveContains(q)
                || (song.artistName?.localizedCaseInsensitiveContains(q) ?? false)
                || (song.albumTitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Materialize Song values only for explicit actions (queue, export,
    /// scrape), never as the List's structural data.
    private var filteredSongs: [Song] {
        filteredSongIDs.compactMap { listCache.song(id: $0) }
    }

    /// Patch only the rows touched by a metadata replacement. Do not reorder
    /// the complete list while background scraping/backfill is publishing:
    /// besides forcing a 10K-row List diff, that could move the row whose
    /// More menu the user is currently operating. The next explicit sort,
    /// collection change, or appearance rebuilds the order from fresh data.
    private func applyLibrarySongReplacements() {
        let replacedIDs = library.lastReplacedSongIDs
        guard !replacedIDs.isEmpty, !listCache.sortedSongIDs.isEmpty else { return }

        var replacements: [String: Song] = [:]
        replacements.reserveCapacity(replacedIDs.count)
        for songID in replacedIDs {
            guard listCache.song(id: songID) != nil,
                  let latest = library.song(id: songID),
                  belongsToCurrentScope(latest)
            else { continue }
            replacements[songID] = latest
        }

        guard !replacements.isEmpty else { return }
        listCache.patch(replacements)
    }

    private func belongsToCurrentScope(_ song: Song) -> Bool {
        switch scope {
        case .library:
            return library.containsVisibleSong(id: song.id)
        case .source(let sourceID):
            return song.sourceID == sourceID && library.containsVisibleSong(id: song.id)
        }
    }

    /// Sorting 10K localized strings can take long enough to drop frames, even
    /// after the array-equality hang is removed. Debounce scan/backfill bursts
    /// and do that CPU work away from the main actor; only publish the finished
    /// copy if it still belongs to the newest generation.
    private func scheduleSortedRecompute(debounced: Bool = false) {
        sortGeneration &+= 1
        let generation = sortGeneration
        let snapshot = songs
        let order = sortOrder

        sortTask?.cancel()
        sortTask = Task { @MainActor in
            if debounced {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let sorted = await Task.detached(priority: .userInitiated) {
                Self.sorted(snapshot, by: order)
            }.value
            guard !Task.isCancelled,
                  sortGeneration == generation,
                  sortOrder == order
            else { return }
            listCache.replace(with: sorted)
        }
    }

    private nonisolated static func sorted(_ songs: [Song], by order: SongSortOrder) -> [Song] {
        switch order {
        case .title:
            songs.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .artist:
            songs.sorted { ($0.artistName ?? "").localizedCompare($1.artistName ?? "") == .orderedAscending }
        case .album:
            songs.sorted { ($0.albumTitle ?? "").localizedCompare($1.albumTitle ?? "") == .orderedAscending }
        case .dateAdded:
            songs.sorted { $0.dateAdded > $1.dateAdded }
        case .format:
            songs.sorted { $0.fileFormat.displayName < $1.fileFormat.displayName }
        }
    }

    private var totalDuration: TimeInterval {
        songs.reduce(0) { $0 + $1.duration.sanitizedDuration }
    }

    private func playSong(_ song: Song) {
        let visibleQueue = filteredSongs
        guard let index = visibleQueue.firstIndex(where: { $0.id == song.id }) else { return }

        let queue = Array(visibleQueue[index...]) + Array(visibleQueue[..<index])
        guard let first = queue.first else { return }
        plog("🎶 SongList setQueue visible=\(visibleQueue.count) queue=\(queue.count) start='\(first.title)'")
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }
}

/// A row-level observation boundary. Metadata/backfill changes replace the
/// model for one song, and only this subtree re-evaluates; the parent List no
/// longer observes Song values or per-row source/backfill state.
private struct IOSSongListRow: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    let model: SongListRowModel
    let onPlay: (Song) -> Void

    var body: some View {
        let song = model.song
        Button {
            onPlay(song)
        } label: {
            SongRowView(
                song: song,
                isPlaying: player.currentSong?.id == song.id,
                context: SongRowView.context(
                    for: song,
                    sourcesStore: sourcesStore,
                    backfill: backfill
                )
            )
        }
        .buttonStyle(.plain)
    }
}

#if os(macOS)
private struct MacAddVisibleSongsToPlaylistSheet: View {
    let songs: [Song]
    let onClose: () -> Void

    @Environment(MusicLibrary.self) private var library
    @State private var selectedPlaylistID: String?
    @State private var newPlaylistName = ""

    private var normalPlaylists: [Playlist] {
        library.playlists.filter {
            !AppleMusicLibraryService.isAppleMusicMirrorPlaylist($0.id)
            && $0.id != MusicLibrary.likedSongsPlaylistID
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 34, height: 34)
                    .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "加入歌单")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: "\(songs.count.formatted()) 首可播放歌曲")
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 26, height: 26)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if normalPlaylists.isEmpty {
                        Text(verbatim: "还没有普通歌单, 可以直接在下方新建。")
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
                    } else {
                        ForEach(normalPlaylists) { playlist in
                            Button {
                                selectedPlaylistID = playlist.id
                            } label: {
                                HStack(spacing: 10) {
                                    StoredCoverArtView(fileName: playlist.coverArtPath, size: 34, cornerRadius: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: playlist.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(PMColor.text)
                                            .lineLimit(1)
                                        Text("\(library.songs(forPlaylist: playlist.id).count) \(String(localized: "songs_count"))")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(PMColor.textFaint)
                                    }
                                    Spacer()
                                    if selectedPlaylistID == playlist.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(PMColor.brand)
                                    }
                                }
                                .padding(10)
                                .background(selectedPlaylistID == playlist.id ? PMColor.brand.opacity(0.12) : PMColor.bgElev, in: .rect(cornerRadius: 9))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(selectedPlaylistID == playlist.id ? PMColor.brand.opacity(0.6) : PMColor.cardBorder, lineWidth: 0.5)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "新建歌单")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                        TextField("playlist_name", text: $newPlaylistName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(PMColor.bgElev, in: .rect(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                            }
                    }
                }
                .padding(18)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            HStack {
                Spacer()
                Button("cancel", action: onClose)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                Button("加入") {
                    addSongs()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(canCommit ? PMColor.brand : PMColor.textFaint, in: .rect(cornerRadius: 6))
                .disabled(!canCommit)
            }
            .padding(18)
        }
        .background(PMColor.bg)
    }

    private var canCommit: Bool {
        selectedPlaylistID != nil || !newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addSongs() {
        let targetID: String
        if let selectedPlaylistID {
            targetID = selectedPlaylistID
        } else {
            let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            targetID = library.createPlaylist(name: name).id
        }
        for song in songs {
            library.add(songID: song.id, toPlaylist: targetID)
        }
        onClose()
    }
}
#endif
