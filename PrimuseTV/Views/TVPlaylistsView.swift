#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 歌单 — 4 列磁贴网格(对应 tvos.jsx 的 TVPlaylistsArtboard)。
struct TVPlaylistsView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}
    /// 新建、重命名歌单的面板开着:顶栏停掉播放快捷键,关掉后焦点由这一页自己放回。
    var onModalPresentationChanged: (Bool) -> Void = { _ in }

    @State private var filter = 0
    @State private var appleMusic = TVAppleMusicCatalog()
    @AppStorage(PlaylistListOrder.storageKey) private var orderRawValue = PlaylistListOrder.custom.rawValue
    /// 设置里的「评分与评论」:关着时电视上不显示星级,按星级聚合的卡片也不出。
    @AppStorage(LibraryReviewPreferences.enabledKey) private var ratingsEnabled = false
    @FocusState private var isOrderMenuFocused: Bool
    @FocusState private var isCreateFocused: Bool
    @State private var showsCreate = false
    private let cols = 4
    private let gap: CGFloat = 36

    var body: some View {
        let stored = store.playlists(ordered: order)
            .filter { filter == 0 || (filter == 2 ? $0.kind == .smart : $0.kind != .smart) }
        // 「5 星」「4 星以上」「3 星以上」排在「我喜欢」后面(看板 PRIM-36);它们是自动聚合的,
        // 和智能歌单归在一起,只看普通歌单时不出现。
        let rated = ratingsEnabled && filter != 1 ? store.ratingPlaylists : []
        let likedCount = stored.prefix { $0.kind == .liked }.count
        let playlists = Array(stored.prefix(likedCount)) + rated + Array(stored.dropFirst(likedCount))
        ZStack {
            TVColor.bg.ignoresSafeArea()
            GeometryReader { geo in
                let contentW = geo.size.width - TVSpace.pageH * 2
                let cell = (contentW - gap * CGFloat(cols - 1)) / CGFloat(cols)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        VStack(alignment: .leading, spacing: 6) {
                            TVEyebrow(text: PMString("ext.tv.playlists.eyebrow"))
                            Text(PMString("ext.tv.playlists.title", stored.count))
                                .tvFont(.pageTitle).foregroundStyle(TVColor.text)
                        }
                        HStack(spacing: 16) {
                            TVSelectionButton(title: PMString("ext.tv.library.filter.all"), selected: filter == 0) { filter = 0 }
                            TVSelectionButton(title: String(localized: "tab_playlists"), selected: filter == 1) { filter = 1 }
                            TVSelectionButton(title: PMString("ext.tv.library.filter.smart"), selected: filter == 2) { filter = 2 }
                            Spacer(minLength: 16)
                            // 只排普通歌单:只看智能歌单、普通歌单不到两个时没得排。
                            if filter != 2, store.normalPlaylists.lazy.filter({ $0.kind == .normal }).count >= 2 {
                                orderMenu
                            }
                            createButton
                        }
                        // 焦点区撑满整行:顶栏「歌单」在页面中部,只有胶囊宽度时往下的搜索
                        // 落不到这一行和下面的歌单,会越过去落在 Apple Music 那一排。
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                        if playlists.isEmpty {
                            TVEmptyState(
                                icon: "music.note.list",
                                title: String(localized: "no_playlists")
                            )
                            .frame(minHeight: 500)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: cols),
                                      alignment: .leading, spacing: gap) {
                                ForEach(playlists) { p in
                                    TVPlaylistCard(
                                        playlist: p,
                                        width: cell,
                                        action: openPlayer,
                                        onModalPresentationChanged: onModalPresentationChanged
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusSection()
                        }
                        appleMusicSection(cell: cell)
                    }
                    .tvPage()
                }
            }
        }
        .task { await appleMusic.loadPlaylists() }
        .fullScreenCover(isPresented: $showsCreate) {
            TVPlaylistNameView(mode: .create)
                .environment(store)
        }
        .onChange(of: showsCreate) { _, shows in onModalPresentationChanged(shows) }
        .onDisappear {
            if showsCreate { onModalPresentationChanged(false) }
        }
    }

    /// 筛选行最右端的「新建歌单」(看板 PRIM-35)。电视上只建、改名;往里加歌还在 iPhone、iPad、Mac 上。
    private var createButton: some View {
        Button {
            showsCreate = true
        } label: {
            TVFilterChipLabel(
                title: String(localized: "new_playlist"),
                systemImage: "plus",
                isFocused: isCreateFocused
            )
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($isCreateFocused)
        .focusEffectDisabled()
        .accessibilityIdentifier("tv.playlists.create")
    }

    private var order: PlaylistListOrder { .resolved(orderRawValue) }

    /// 筛选行右端的排序菜单, 和手机歌单页一样分两段: 先选按什么排(最前面是自定义顺序),
    /// 再选升序还是降序。外观同资料库筛选行右端的菜单按钮, 选项用 `Toggle`, 当前那一项带勾。
    private var orderMenu: some View {
        Menu {
            Section(String(localized: "sort_by")) {
                orderToggle(nil)
                ForEach(PlaylistListOrder.Criterion.allCases, id: \.self) { criterion in
                    orderToggle(criterion)
                }
            }
            if order != .custom {
                Section(String(localized: "smart_sort_direction")) {
                    directionToggle(ascending: true)
                    directionToggle(ascending: false)
                }
            }
        } label: {
            TVFilterChipLabel(
                title: order.label,
                systemImage: "arrow.up.arrow.down",
                isFocused: isOrderMenuFocused
            )
        }
        .menuStyle(.button)
        .buttonStyle(TVBareButtonStyle())
        .focused($isOrderMenuFocused)
        .focusEffectDisabled()
        .accessibilityLabel(Text("sort_by"))
        .accessibilityValue(Text(order.label))
        .accessibilityIdentifier("tv.playlists.order")
    }

    private func orderToggle(_ criterion: PlaylistListOrder.Criterion?) -> some View {
        Toggle(isOn: Binding(
            get: { order.criterion == criterion },
            set: { _ in orderRawValue = order.selecting(criterion).rawValue }
        )) {
            Label(
                PlaylistListOrder.defaultOrder(for: criterion).label,
                systemImage: PlaylistListOrder.systemImage(for: criterion)
            )
        }
    }

    private func directionToggle(ascending: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { order.isAscending == ascending },
            set: { _ in orderRawValue = order.withAscending(ascending).rawValue }
        )) {
            Label(
                String(localized: ascending ? "smart_sort_ascending" : "smart_sort_descending"),
                systemImage: ascending ? "arrow.up" : "arrow.down"
            )
        }
    }

    /// Apple Music 上的歌单单独成段:它们不进本机曲库,按下去由系统播放器整条播放,
    /// 与本地歌单的编辑、智能规则无关,混进同一个网格只会让人以为能改。
    @ViewBuilder
    private func appleMusicSection(cell: CGFloat) -> some View {
        if !appleMusic.playlists.isEmpty || appleMusic.isLoadingPlaylists {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    TVEyebrow(text: PMString("ext.tv.playlists.appleMusic"))
                    if appleMusic.isLoadingPlaylists {
                        ProgressView().tint(TVColor.brand)
                    }
                }
                if appleMusic.playlists.isEmpty {
                    Text(PMString("ext.tv.playlists.appleMusicLoading"))
                        .tvFont(.caption).foregroundStyle(TVColor.textFaint)
                } else {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top),
                            count: cols
                        ),
                        alignment: .leading,
                        spacing: gap
                    ) {
                        ForEach(appleMusic.playlists) { playlist in
                            TVAppleMusicTileCard(
                                title: playlist.name,
                                subtitle: playlist.curatorName.isEmpty
                                    ? PMString("ext.tv.search.appleMusicBadge")
                                    : playlist.curatorName,
                                artworkURL: playlist.artworkURL,
                                glyph: "music.note.list",
                                width: cell,
                                action: {
                                    store.playAppleMusicPlaylist(playlist)
                                    openPlayer()
                                }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            .padding(.top, 12)
        }
    }
}

extension PlaylistListOrder {
    var label: String {
        switch criterion {
        case nil: return String(localized: "playlist_sort_custom")
        case .name: return String(localized: "playlist_sort_name")
        case .dateAdded: return String(localized: "playlist_sort_date_added")
        case .dateUpdated: return String(localized: "playlist_sort_date_updated")
        case .songCount: return String(localized: "playlist_sort_song_count")
        }
    }

    static func systemImage(for criterion: Criterion?) -> String {
        switch criterion {
        case nil: return "line.3.horizontal"
        // 不用 textformat:它在中文环境下被系统换成「格式」两个字。
        case .name: return "abc"
        case .dateAdded: return "calendar"
        case .dateUpdated: return "clock"
        case .songCount: return "music.note.list"
        }
    }
}

/// 歌单磁贴 — 智能歌单右上角标、我喜欢的整块爱心覆层。
struct TVPlaylistCard: View {
    @Environment(TVStore.self) private var store
    let playlist: TVPlaylist
    @State private var pendingMedleyIDs: [String]?
    @State private var showsRename = false
    var width: CGFloat = 300
    var action: () -> Void = {}
    var onModalPresentationChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let h = width * 0.8
        TVFocusButton(ring: false,
                      action: { playTapped() }) { focused in
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    TVPlaylistArtworkView(playlist: playlist, size: width, height: h)
                    if playlist.kind == .smart {
                        VStack {
                            HStack {
                                Spacer()
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles").font(.system(size: 20))
                                    Text(PMString("ext.tv.playlists.smart")).tvFont(.meta, weight: .medium)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.5), in: Capsule())
                            }
                            Spacer()
                        }
                        .padding(12)
                    }
                    if playlist.kind == .rated {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "star.fill").font(.system(size: 20))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.black.opacity(0.5), in: Capsule())
                            }
                            Spacer()
                        }
                        .padding(12)
                        .accessibilityHidden(true)
                    }
                    if playlist.kind == .liked {
                        LinearGradient(colors: [TVColor.brand.opacity(0.8), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "heart.fill").font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .frame(width: width, height: h)
                .tvCardFocus(focused, radius: TVRadius.cover)
                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text).lineLimit(2, reservesSpace: true)
                    Text(PMString("ext.tv.songsCount", playlist.count)).tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
        .contextMenu {
            Button("medley_play_selection", systemImage: "shuffle") {
                pendingMedleyIDs = store.medleyPlaylistSongIDs(playlist)
            }
            .disabled(!store.canPlayMedley(playlist: playlist))
            // 自己建的歌单能改名(看板 PRIM-35);镜像、文件夹歌单和「我喜欢」的名字不归这里管。
            if store.canRename(playlist) {
                Button("playlist_rename", systemImage: "pencil") {
                    showsRename = true
                }
            }
        }
        .fullScreenCover(isPresented: $showsRename) {
            TVPlaylistNameView(mode: .rename(playlist))
                .environment(store)
        }
        .onChange(of: showsRename) { _, shows in onModalPresentationChanged(shows) }
        .onDisappear {
            if showsRename { onModalPresentationChanged(false) }
        }
        .modifier(TVMedleyConfirmation(pendingIDs: $pendingMedleyIDs, onStarted: action))
        .accessibilityLabel(Text(playlist.name))
        .accessibilityValue(Text(PMString("ext.tv.songsCount", playlist.count)))
    }

    /// 点击歌单卡片播放歌单自身的求值结果，包括普通、喜欢与智能歌单。
    private func playTapped() {
        guard store.play(playlist: playlist) else { return }
        action()
    }
}

/// 电视上新建、重命名歌单(看板 PRIM-35),和电台改名同一套面板。取消或名字是空的不建、不改,
/// 改名不动歌单里的曲目和顺序。
struct TVPlaylistNameView: View {
    enum Mode {
        case create
        case rename(TVPlaylist)
    }

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var name: String
    @FocusState private var fieldFocused: Bool

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create: _name = State(initialValue: "")
        case .rename(let playlist): _name = State(initialValue: playlist.name)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.35)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text(isCreating ? String(localized: "new_playlist") : String(localized: "playlist_rename_title"))
                    .tvFont(.sectionTitle)
                    .foregroundStyle(TVColor.text)
                    .lineLimit(2)
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "playlist_name"))
                        .tvFont(.caption)
                        .foregroundStyle(fieldFocused ? TVColor.text : TVColor.textFaint)
                    TVTextFieldBox {
                        TextField("", text: $name)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityLabel(Text("playlist_name"))
                    }
                }
                HStack(spacing: 18) {
                    TVPillButton(
                        title: isCreating ? String(localized: "create") : PMString("ext.tv.sources.form.save"),
                        systemImage: "checkmark",
                        style: .solid,
                        action: save
                    )
                    .disabled(trimmedName.isEmpty)
                    TVPillButton(title: PMString("ext.tv.sources.cancel"), systemImage: "xmark") {
                        dismiss()
                    }
                }
                .padding(.top, 8)
            }
            .padding(40)
            .frame(width: 900, alignment: .leading)
            .tvPanel(radius: 22)
        }
        .onExitCommand { dismiss() }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        switch mode {
        case .create:
            store.createPlaylist(named: trimmedName)
        case .rename(let playlist):
            if trimmedName != playlist.name {
                store.renamePlaylist(id: playlist.id, to: trimmedName)
            }
        }
        dismiss()
    }
}

/// tvOS consumes the same deterministic PrimuseKit plan as the phone and Mac,
/// but resolves each entry with its target-specific cache/client loader.
private struct TVPlaylistArtworkView: View {
    @Environment(TVStore.self) private var store
    let playlist: TVPlaylist
    let size: CGFloat
    let height: CGFloat

    @State private var image: UIImage?
    @State private var reloadRevision = 0

    private var overrideResolution: LibraryArtworkOverrideResolution {
        store.library.artworkPresentation(
            for: LibraryArtworkOwner(kind: .playlist, id: playlist.id)
        ).resolution
    }

    private var overrideIdentity: String {
        switch overrideResolution {
        case .automatic: return "automatic"
        case .selectedSong(let songID): return "song:\(songID)"
        case .uploaded(let contentID): return "upload:\(contentID)"
        }
    }

    private var loadIdentity: String {
        "\(playlist.artworkSignature)#\(overrideIdentity)#\(store.library.artworkOverrideRevision)#\(reloadRevision)"
    }

    var body: some View {
        ZStack {
            TVMusicPlaceholder(
                tint: TVColor.brand,
                tint2: .black,
                kind: .playlist,
                size: size,
                height: height
            )
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: height)
                    .clipped()
            }
        }
        .frame(width: size, height: height)
        .task(id: loadIdentity) {
            let identity = loadIdentity
            image = nil
            switch overrideResolution {
            case .uploaded(let contentID):
                if let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID),
                   let customImage = await Self.decodeImage(data) {
                    guard !Task.isCancelled, loadIdentity == identity else { return }
                    image = customImage
                    return
                }
            case .selectedSong(let songID):
                if let song = store.library.song(id: songID) {
                    if let data = await store.songArtworkData(
                        songID: song.id,
                        coverRef: song.coverArtFileName
                    ), let selectedImage = await Self.decodeImage(data) {
                        guard !Task.isCancelled, loadIdentity == identity else { return }
                        image = selectedImage
                        return
                    }
                }
            case .automatic:
                break
            }
            let corePlan = PlaylistArtworkResolutionPlan(
                signature: playlist.artworkSignature,
                candidates: playlist.artworkCandidates.map {
                    PlaylistArtworkCandidate(
                        kind: $0.kind,
                        id: $0.id,
                        songID: $0.songID,
                        artworkReference: $0.coverRef
                    )
                }
            )
            let dedicatedSourceID = playlist.artworkCandidates.first { $0.kind == .dedicated }?.sourceID
            let resolved: PlaylistArtworkResolution<UIImage>? = await PlaylistArtworkResolver
                .resolve(plan: corePlan) { candidate -> UIImage? in
                guard let songID = candidate.songID else { return nil }
                guard let data = await store.songArtworkData(
                    songID: songID,
                    coverRef: candidate.artworkReference,
                    sourceID: candidate.kind == .dedicated ? dedicatedSourceID : nil
                ) else { return nil }
                return await Self.decodeImage(data)
            }
            guard !Task.isCancelled, loadIdentity == identity else { return }
            image = resolved?.value
            if image == nil {
                try? await Task.sleep(
                    nanoseconds: UInt64(TVArtworkLoader.negativeCacheTTL * 1_000_000_000)
                )
                guard !Task.isCancelled, loadIdentity == identity, image == nil else { return }
                reloadRevision &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard notificationAffectsPlaylist(note) else { return }
            reloadRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            guard notificationAffectsPlaylist(note) else { return }
            reloadRevision &+= 1
        }
    }

    private func notificationAffectsPlaylist(_ note: Notification) -> Bool {
        if note.userInfo?["all"] as? Bool == true { return true }
        if let batch = ArtworkInvalidationBatch.from(note) {
            let overrideToken: String? = switch overrideResolution {
            case .automatic: nil
            case .selectedSong(let songID): songID
            case .uploaded(let contentID): contentID
            }
            return playlist.artworkCandidates.contains { candidate in
                batch.songIDs.contains(candidate.songID)
                    || candidate.coverRef.map(batch.references.contains) == true
            } || overrideToken.map(batch.contains) == true
        }
        let songIDs = Set(playlist.artworkCandidates.map(\.songID))
        if let songID = note.object as? String, songIDs.contains(songID) { return true }
        if let songID = note.userInfo?["songID"] as? String, songIDs.contains(songID) {
            return true
        }
        if let changed = note.userInfo?["songIDs"] as? [String],
           changed.contains(where: songIDs.contains) {
            return true
        }
        let references = Set(playlist.artworkCandidates.compactMap(\.coverRef))
        if let tokens = note.userInfo?["tokens"] as? [String],
           tokens.contains(where: { references.contains($0) || overrideIdentity.contains($0) }) {
            return true
        }
        return false
    }

    private static func decodeImage(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) {
            UIImage(data: data)
        }.value
    }
}
#endif
