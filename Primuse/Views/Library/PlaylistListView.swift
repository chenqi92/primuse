import SwiftUI
import PrimuseKit

struct PlaylistListView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistDescription = ""
    @State private var showSmartEditor = false
    @State private var showNoScraperSourceAlert = false
    /// 歌单批量管理态。普通态和管理态用两个独立的列表 —— 在同一个 List 上
    /// 混 NavigationLink 与 selection，点一下到底是进歌单还是勾选会变得不确定。
    @State private var isManagingPlaylists = false
    @State private var playlistSelection: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    /// 系统歌单（Apple Music 镜像 / 「我喜欢」）不参与批量删除，理由同
    /// `isSystemPlaylist`：删完下次 sync 或 heart toggle 又会重建。
    private var deletablePlaylistIDs: Set<String> {
        playlistSelection.filter { !isSystemPlaylist($0) }
    }

    // liked 系统歌单已作为「资料库 · 我喜欢的」固定入口展示, 歌单总览里不再重复列出。
    private var playlists: [Playlist] {
        library.playlists.filter { $0.id != MusicLibrary.likedSongsPlaylistID }
    }
    private var smartPlaylists: [SmartPlaylist] { library.smartPlaylists }

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isManagingPlaylists {
                playlistManageBar
            }
        }
        .alert("delete_playlist", isPresented: $showBatchDeleteConfirm) {
            Button("cancel", role: .cancel) {}
            Button("delete", role: .destructive) { deleteSelectedPlaylists() }
        } message: {
            Text(verbatim: String(
                format: String(localized: "batch_playlists_delete_confirm_format"),
                deletablePlaylistIDs.count
            ))
        }
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
    }

    @ViewBuilder
    private var iosBody: some View {
        Group {
            if playlists.isEmpty && smartPlaylists.isEmpty {
                EmptyStateView(
                    titleKey: "no_playlists",
                    descriptionKey: "no_playlists_desc",
                    systemImage: "music.note.list",
                    actionLabel: "new_playlist",
                    action: { showNewPlaylist = true }
                )
            } else if isManagingPlaylists {
                playlistManageList
            } else {
                List {
                    if !smartPlaylists.isEmpty {
                        Section {
                            ForEach(smartPlaylists) { smart in
                                NavigationLink(value: smart) {
                                    smartPlaylistRow(smart)
                                }
                            }
                            .onDelete(perform: deleteSmartPlaylists)
                        } header: {
                            Text("smart_playlists_section")
                        }
                    }

                    if !playlists.isEmpty {
                        Section {
                            ForEach(playlists) { playlist in
                                NavigationLink(value: playlist) {
                                    playlistRow(playlist)
                                }
                                // 用 swipeActions 而不是 .onDelete ── 后者无法
                                // 按行条件禁用, 之前在 deletePlaylists 里 continue
                                // 跳过 system 歌单时 SwiftUI 已经做了消失动画
                                // 等下一帧数据刷回来又出现, 用户看到"删了又回来"。
                                // 改成 swipeActions 让 system 歌单根本没有 swipe
                                // 入口, 视觉一致。
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if !isSystemPlaylist(playlist.id) {
                                        Button(role: .destructive) {
                                            library.deletePlaylist(id: playlist.id)
                                        } label: {
                                            Label("delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            // 只有一类时不显示 header, 跟原版视觉一致;
                            // 两类都有时才显示 "歌单" header 区分。
                            if !smartPlaylists.isEmpty {
                                Text("playlists_section")
                            } else {
                                EmptyView()
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isManagingPlaylists {
                    Button("done") {
                        isManagingPlaylists = false
                        playlistSelection = []
                    }
                } else {
                    Menu {
                        Button {
                            showNewPlaylist = true
                        } label: {
                            Label("new_playlist", systemImage: "music.note.list")
                        }
                        Button {
                            showSmartEditor = true
                        } label: {
                            Label("new_smart_playlist", systemImage: "sparkles")
                        }
                        if !playlists.isEmpty {
                            Divider()
                            Button {
                                isManagingPlaylists = true
                            } label: {
                                Label("batch_select", systemImage: "checkmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .alert("new_playlist", isPresented: $showNewPlaylist) {
            TextField("playlist_name", text: $newPlaylistName)
            Button("cancel", role: .cancel) { newPlaylistName = "" }
            Button("create") { createPlaylist() }
        }
        .sheet(isPresented: $showSmartEditor) {
            SmartPlaylistEditorView(existing: nil)
        }
        .navigationDestination(for: SmartPlaylist.self) { smart in
            SmartPlaylistDetailView(smartPlaylistID: smart.id)
        }
    }

    /// 管理态的多选列表。`editMode` 常开 —— 用户点「选择」就是来批量处理的，
    /// 再要求他在里面点一次才出现勾选圈，中间那个状态看着像坏了。
    private var playlistManageList: some View {
        List(selection: $playlistSelection) {
            Section {
                ForEach(playlists) { playlist in
                    playlistRow(playlist)
                        .tag(playlist.id)
                        .selectionDisabled(isSystemPlaylist(playlist.id))
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private var playlistManageBar: some View {
        HStack(spacing: 12) {
            Text(verbatim: String(
                format: String(localized: "batch_playlists_selected_count_format"),
                deletablePlaylistIDs.count
            ))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()

            Spacer(minLength: 8)

            Button("batch_select_all") {
                playlistSelection = Set(playlists.map(\.id).filter { !isSystemPlaylist($0) })
            }
            .font(.subheadline)

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("delete", systemImage: "trash")
            }
            .disabled(deletablePlaylistIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func deleteSelectedPlaylists() {
        for playlistID in deletablePlaylistIDs {
            library.deletePlaylist(id: playlistID)
        }
        playlistSelection = []
        isManagingPlaylists = false
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        // 歌单封面始终用第一首歌的封面 ── 跟其他地方的 cover 渲染同源 (NAS /
        // URL / Apple Music ArtworkImage 都自动适配), 而且歌单重排后封面立刻
        // 跟着变。playlist.coverArtPath 字段保留 (replacePlaylistSongs 内部
        // 仍写它, 不破坏 schema / sync), 但 UI 渲染不再读, 避免老的 path 跟
        // 实际歌曲不同步。
        let summary = library.songSummary(forPlaylist: playlist.id)
        let firstSong = summary.first
        return HStack(spacing: 12) {
            Group {
                if let song = firstSong {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: 48,
                        cornerRadius: 8,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                } else {
                    StoredCoverArtView(fileName: nil, size: 48, cornerRadius: 8)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.body)
                HStack(spacing: 4) {
                    Text(String(
                        format: String(localized: "carplay_playlist_song_count_format"),
                        summary.count
                    ))
                    Text("·")
                    Text(playlist.updatedAt, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func smartPlaylistRow(_ smart: SmartPlaylist) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [.purple.opacity(0.7), .blue.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(smart.name).font(.body)
                Text("\(smart.rules.count) \(String(localized: "rules_count"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var macBody: some View {
        Group {
            if playlists.isEmpty && smartPlaylists.isEmpty {
                ContentUnavailableView {
                    Label("no_playlists", systemImage: "music.note.list")
                } description: {
                    Text("no_playlists_desc")
                } actions: {
                    Button("new_playlist") {
                        showNewPlaylist = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        macPlaylistsHeader
                        playlistOverview

                        if !smartPlaylists.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                macSubsectionTitle("smart_playlists_section")
                                LazyVStack(spacing: 10) {
                                    ForEach(smartPlaylists) { smart in
                                        NavigationLink(value: smart) {
                                            smartPlaylistCard(smart)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if !playlists.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                if !smartPlaylists.isEmpty {
                                    macSubsectionTitle("playlists_section")
                                }

                                LazyVStack(spacing: 10) {
                                    ForEach(playlists) { playlist in
                                        if isManagingPlaylists {
                                            playlistCard(playlist)
                                                .opacity(isSystemPlaylist(playlist.id) ? 0.45 : 1)
                                                .overlay(alignment: .topTrailing) {
                                                    if !isSystemPlaylist(playlist.id) {
                                                        SongSelectionCheckmark(
                                                            isSelected: playlistSelection.contains(playlist.id)
                                                        )
                                                        .padding(10)
                                                    }
                                                }
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    guard !isSystemPlaylist(playlist.id) else { return }
                                                    if playlistSelection.contains(playlist.id) {
                                                        playlistSelection.remove(playlist.id)
                                                    } else {
                                                        playlistSelection.insert(playlist.id)
                                                    }
                                                }
                                        } else {
                                            NavigationLink(value: playlist) {
                                                playlistCard(playlist)
                                            }
                                            .buttonStyle(.plain)
                                            .contextMenu {
                                                playlistContextMenu(for: playlist)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 32)
                    .padding(.bottom, 112)
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(PMColor.bg.ignoresSafeArea())
            }
        }
        .navigationDestination(for: SmartPlaylist.self) { smart in
            SmartPlaylistDetailView(smartPlaylistID: smart.id)
        }
        .sheet(isPresented: $showNewPlaylist) {
            MacNewPlaylistSheet(
                name: $newPlaylistName,
                description: $newPlaylistDescription,
                onCancel: {
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                    showNewPlaylist = false
                },
                onCreate: { name in
                    _ = library.createPlaylist(name: name)
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                    showNewPlaylist = false
                }
            )
        }
        .sheet(isPresented: $showSmartEditor) {
            SmartPlaylistEditorView(existing: nil)
        }
    }

    private var macPlaylistsHeader: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("library")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                Text("tab_playlists")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(PMColor.text)
            }
            Spacer()
            Button {
                showNewPlaylist = true
            } label: {
                Label("new_playlist", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(PMColor.brand, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button {
                showSmartEditor = true
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .frame(width: 32, height: 32)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .help(Text("new_smart_playlist"))

            if !playlists.isEmpty {
                Button {
                    isManagingPlaylists.toggle()
                    if !isManagingPlaylists { playlistSelection = [] }
                } label: {
                    Image(systemName: isManagingPlaylists ? "xmark" : "checkmark.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isManagingPlaylists ? .white : PMColor.text)
                        .frame(width: 32, height: 32)
                        .background(isManagingPlaylists ? PMColor.brand : PMColor.glassBtn,
                                    in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isManagingPlaylists ? .clear : PMColor.cardBorder,
                                              lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .help(Text(isManagingPlaylists ? "done" : "batch_select"))
            }
        }
    }

    private var playlistOverview: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 52, height: 52)
                .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("tab_playlists")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("\(playlists.count) \(String(localized: "playlists_section")) · \(smartPlaylists.count) \(String(localized: "smart_playlists_section")) · \(totalPlaylistSongs) \(String(localized: "songs_count"))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var totalPlaylistSongs: Int {
        playlists.reduce(0) { partialResult, playlist in
            partialResult + library.songCount(forPlaylist: playlist.id)
        }
    }

    private func macSubsectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
            .padding(.horizontal, 2)
    }

    private func smartPlaylistCard(_ smart: SmartPlaylist) -> some View {
        let count = SmartPlaylistEngine.match(smart, in: library, history: PlayHistoryStore.shared).count
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [PMColor.brand.opacity(0.92), Color(red: 0.36, green: 0.45, blue: 0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(smart.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)

                Text("\(count) \(String(localized: "songs_count")) · \(smart.rules.count + (smart.ruleGroups?.flatMap(\.rules).count ?? 0)) \(String(localized: "rules_count"))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(PMColor.card.opacity(0.72), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        let count = library.songCount(forPlaylist: playlist.id)
        return HStack(spacing: 14) {
            StoredCoverArtView(fileName: playlist.coverArtPath, size: 58, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text("\(count) \(String(localized: "songs_count"))")
                    Text("·")
                    Text(playlist.updatedAt, style: .date)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(PMColor.card.opacity(0.72), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func playlistContextMenu(for playlist: Playlist) -> some View {
        let playlistSongs = library.songs(forPlaylist: playlist.id)
        let playable = playlistSongs.filteredPlayable()

        Button {
            playPlaylist(playlist)
        } label: {
            Label("play_all", systemImage: "play.fill")
        }
        .disabled(playable.isEmpty)

        Button {
            playPlaylist(playlist, shuffled: true)
        } label: {
            Label("shuffle", systemImage: "shuffle")
        }
        .disabled(playable.isEmpty)

        Button {
            player.appendToQueue(playable)
        } label: {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        .disabled(playable.isEmpty)

        Button {
            player.insertNextInQueue(playable)
        } label: {
            Label("up_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(playable.isEmpty)

        Button {
            guard scraperSettings.hasEnabledSource else {
                showNoScraperSourceAlert = true
                return
            }
            scraperService.scrapeMissingMetadata(songs: playlistSongs, in: library)
        } label: {
            Label("scrape_missing_metadata", systemImage: "wand.and.stars")
        }
        .disabled(playlistSongs.isEmpty || scraperService.isScraping)

        if !isSystemPlaylist(playlist.id) {
            Divider()
            Button(role: .destructive) {
                library.deletePlaylist(id: playlist.id)
            } label: {
                Label("delete_playlist", systemImage: "trash")
            }
        }
    }
    #endif

    private func createPlaylist() {
        let trimmedName = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        _ = library.createPlaylist(name: trimmedName)
        newPlaylistName = ""
    }

    /// system 歌单 (Apple Music 镜像 / 「我喜欢」) 不允许从这里删:
    /// - AM 镜像下次 sync 自动重建, "删了又出现"
    /// - 「我喜欢」heart toggle 又会触发 ensure 重建
    /// 真想清空都得从内容侧操作 (取消 Apple Music 资料库同步 / 进歌单逐条移除)。
    private func isSystemPlaylist(_ playlistID: String) -> Bool {
        AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlistID)
            || playlistID == MusicLibrary.likedSongsPlaylistID
    }

    private func deleteSmartPlaylists(at offsets: IndexSet) {
        for index in offsets {
            library.deleteSmartPlaylist(id: smartPlaylists[index].id)
        }
    }

    private func playPlaylist(_ playlist: Playlist, shuffled: Bool = false) {
        let playable = library.songs(forPlaylist: playlist.id).filteredPlayable()
        let queue = shuffled ? playable.shuffled() : playable
        guard let first = queue.first else { return }
        if shuffled { player.shuffleEnabled = true }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }
}

#if os(macOS)
struct MacNewPlaylistSheet: View {
    @Binding var name: String
    @Binding var description: String
    var onCancel: () -> Void
    var onCreate: (String) -> Void

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("new_playlist")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 26, height: 26)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            VStack(alignment: .center, spacing: 16) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PMColor.rowHover)
                    .frame(width: 120, height: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(PMColor.dividerStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                            Text("playlist_drop_cover")
                                .font(.system(size: 10.5))
                            Text("playlist_use_first_song_cover")
                                .font(.system(size: 9))
                                .opacity(0.70)
                        }
                        .foregroundStyle(PMColor.textFaint)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text("smart_playlist_name")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                    TextField("", text: $name, prompt: Text("playlist_name_example"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(PMColor.bgElev, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(PMColor.brand, lineWidth: 1.5)
                        }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("playlist_description_optional")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                    TextEditor(text: $description)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(height: 64)
                        .background(PMColor.bgElev, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                        }
                }
            }
            .padding(20)

            Spacer(minLength: 0)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            HStack {
                Spacer()
                Button("cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                Button("create") {
                    onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(canCreate ? PMColor.brand : PMColor.textFaint, in: .rect(cornerRadius: 6))
                .disabled(!canCreate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 460)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PMColor.bg.opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }
}
#endif
