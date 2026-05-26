import SwiftUI
import PrimuseKit

struct SongListView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicLibrary.self) private var library
    let songs: [Song]
    @State private var sortOrder: SongSortOrder = .title
    @State private var cachedSortedSongs: [Song] = []
    @State private var searchText: String = ""
    /// ID set the cached order was built from. When `songs` changes by
    /// metadata only (backfill filling in title/duration on existing IDs)
    /// we update each row in-place instead of re-running localizedCompare
    /// across the whole list. Without this, every backfilled track would
    /// trigger an O(N log N) re-sort on the main thread, and a 1k-song
    /// list mid-scan would be visibly stuttery.
    @State private var lastSortedIDSet: Set<String> = []

    enum SongSortOrder: String, CaseIterable {
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

    var body: some View {
        content
            .onAppear { recomputeSorted() }
            .onChange(of: sortOrder) { _, _ in recomputeSorted() }
            .onChange(of: songs) { _, _ in updateSortedSongsIfNeeded() }
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
            ForEach(filteredSongs) { song in
                songButton(song)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText,
                    placement: .toolbar,
                    prompt: Text("search_songs_prompt"))
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
                    onShuffle: { playLibrary(shuffled: true) }
                )

                VStack(alignment: .leading, spacing: PMSpace.l) {
                    sourceFilterChips
                    macToolbarRow

                    if filteredSongs.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 48)
                    } else {
                        songTable
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.m14)
            }
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    private var sourceFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip(title: String(localized: "search_chip_all"), count: songs.count, color: nil, active: true)

                ForEach(sourcesStore.allSources.prefix(5), id: \.id) { source in
                    let count = songs.filter { $0.sourceID == source.id }.count
                    if count > 0 {
                        sourceChip(title: source.name, count: count, color: sourceColor(source), active: false)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func sourceChip(title: String, count: Int, color: Color?, active: Bool) -> some View {
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
    }

    private func sourceColor(_ source: MusicSource) -> Color {
        switch source.type {
        case .baiduPan: return PMColor.brand
        case .appleMusic, .appleMusicLibrary: return Color(red: 0.64, green: 0.48, blue: 0.96)
        case .synology, .qnap, .ugreen, .fnos: return Color(red: 0.31, green: 0.68, blue: 0.95)
        case .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3: return Color(red: 0.45, green: 0.82, blue: 0.56)
        case .jellyfin, .emby, .plex: return Color(red: 0.98, green: 0.66, blue: 0.28)
        case .aliyunDrive, .googleDrive, .oneDrive, .dropbox: return Color(red: 0.42, green: 0.68, blue: 0.96)
        case .local: return PMColor.textFaint
        }
    }

    private var macToolbarRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                TextField("", text: $searchText, prompt: Text(verbatim: "过滤..."))
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
            .fixedSize()

            PMRoundBtn(icon: "music.note.list", size: 26, iconSize: 12, style: .glass,
                       help: "library_title") {}
        }
        .padding(.top, -4)
    }

    private var librarySubtitle: String {
        let playableCount = songs.filter(\.isPlayable).count
        return "\(songs.count) \(String(localized: "songs_count")) · \(playableCount) \(String(localized: "home_playable")) · \(totalDuration.formattedShort)"
    }

    private var songTable: some View {
        VStack(spacing: 0) {
            tableHeader
                .padding(.horizontal, PMSpace.s8)
                .padding(.vertical, 6)
                .background(PMColor.bg)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            LazyVStack(spacing: 1) {
                ForEach(Array(filteredSongs.enumerated()), id: \.element.id) { index, song in
                    songTableRow(song, index: index)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var tableHeader: some View {
        HStack(spacing: PMSpace.s10) {
            Text("#")
                .frame(width: 28, alignment: .center)
            Color.clear.frame(width: 36)   // cover col
            Text("sort_title").frame(maxWidth: .infinity, alignment: .leading)
            Text("sort_artist").frame(width: 180, alignment: .leading)
            Text("sort_album").frame(width: 180, alignment: .leading)
            Text("sort_format").frame(width: 64, alignment: .leading)
            Text("track_duration_short").frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.5)
        .textCase(.uppercase)
        .foregroundStyle(PMColor.textFaint)
    }

    @ViewBuilder
    private func songTableRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        let liked = playlistContains(song)
        Button { playSong(song) } label: {
            HStack(spacing: PMSpace.s10) {
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
                .frame(width: 28, alignment: .center)

                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 32, cornerRadius: PMRadius.xs,
                    sourceID: song.sourceID, filePath: song.filePath
                )

                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                        .lineLimit(1)
                    if liked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PMColor.brand)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(song.artistName ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

                Text(song.albumTitle ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

                PMFormatPill.forFormat(song.fileFormat.displayName)
                    .frame(width: 64, alignment: .leading)

                Text(song.duration.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, PMSpace.s8)
            .padding(.vertical, 6)
            .pmRowBackground(selected: isCurrent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func songButton(_ song: Song) -> some View {
        Button {
            playSong(song)
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

    /// 当前用搜索过滤后的歌曲列表;空字符串时返回完整 cachedSortedSongs。
    /// 大小写无关,匹配标题/艺术家/专辑任一字段。
    private var filteredSongs: [Song] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return cachedSortedSongs }
        return cachedSortedSongs.filter {
            $0.title.localizedCaseInsensitiveContains(q)
            || ($0.artistName?.localizedCaseInsensitiveContains(q) ?? false)
            || ($0.albumTitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Decide whether `songs` changed structurally (added/removed), in
    /// metadata that affects the active sort field, or in metadata that
    /// doesn't. Only the first two warrant a re-sort:
    ///
    /// - ID set changed → re-sort.
    /// - ID set same, but at least one row's `sortKey` changed (e.g.
    ///   backfill filled in a previously-empty title while sorted by
    ///   title) → re-sort, otherwise the visible order would silently
    ///   diverge from the chosen sort.
    /// - ID set same, no sortKey changes → in-place patch, preserving
    ///   order to avoid an O(N log N) localizedCompare on every
    ///   backfill tick.
    private func updateSortedSongsIfNeeded() {
        let newIDSet = Set(songs.map(\.id))
        guard newIDSet == lastSortedIDSet else {
            recomputeSorted()
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let sortKeyChanged = cachedSortedSongs.contains { old in
            guard let new = byID[old.id] else { return false }
            return sortKey(for: new) != sortKey(for: old)
        }
        if sortKeyChanged {
            recomputeSorted()
        } else {
            cachedSortedSongs = cachedSortedSongs.compactMap { byID[$0.id] }
        }
    }

    /// The string representation of whichever song field drives the
    /// active sort. Compared to detect when an in-place metadata update
    /// invalidates the cached order. `.dateAdded` and `.format` rarely
    /// change after creation, so those sorts almost always stay on the
    /// fast path; `.title` / `.artist` / `.album` re-sort during
    /// backfill, which is exactly the correctness boundary we want.
    private func sortKey(for song: Song) -> String {
        switch sortOrder {
        case .title: return song.title
        case .artist: return song.artistName ?? ""
        case .album: return song.albumTitle ?? ""
        case .dateAdded: return String(song.dateAdded.timeIntervalSince1970)
        case .format: return song.fileFormat.displayName
        }
    }

    private func recomputeSorted() {
        switch sortOrder {
        case .title:
            cachedSortedSongs = songs.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .artist:
            cachedSortedSongs = songs.sorted { ($0.artistName ?? "").localizedCompare($1.artistName ?? "") == .orderedAscending }
        case .album:
            cachedSortedSongs = songs.sorted { ($0.albumTitle ?? "").localizedCompare($1.albumTitle ?? "") == .orderedAscending }
        case .dateAdded:
            cachedSortedSongs = songs.sorted { $0.dateAdded > $1.dateAdded }
        case .format:
            cachedSortedSongs = songs.sorted { $0.fileFormat.displayName < $1.fileFormat.displayName }
        }
        lastSortedIDSet = Set(cachedSortedSongs.map(\.id))
    }

    private var totalDuration: TimeInterval {
        songs.reduce(0) { $0 + $1.duration.sanitizedDuration }
    }

    private func playSong(_ song: Song) {
        let queue = cachedSortedSongs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }
}
