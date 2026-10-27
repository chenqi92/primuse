import PrimuseKit
import SwiftUI

/// Home's first row: "continue" for each way of listening, one card each,
/// newest first. Each card resumes by its own space's rules — the music queue
/// someone left, the last station, the book where it was left — and the
/// space playing right now gets no card: the player bar already is its
/// "continue".
struct HomeContinueSpacesRow: View {
    let books: [(SpokenWordBook, [Song])]
    var openSpace: (ListeningSpace) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(RadioStationsStore.self) private var radioStore
    @Environment(\.homeCoverCardWidth) private var cardWidth

    private struct Card: Identifiable {
        enum Content {
            case music(MusicSessionMemoryStore.Memory)
            case radio(RadioStation)
            case book(SpokenWordBook, [Song])
            case podcast(PodcastEpisode, PodcastShow)
        }
        let space: ListeningSpace
        let content: Content
        var id: ListeningSpace { space }
    }

    var body: some View {
        let cards = makeCards()
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("home_continue_spaces_title")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(cards) { card in
                            cardButton(card)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            }
        }
    }

    private func makeCards() -> [Card] {
        var candidates: [ListeningResumeCandidate] = []
        var contents: [ListeningSpace: Card.Content] = [:]

        // 记下的队列整个落在停用的源里时不出卡片,源重新启用后再出来。
        if let memory = MusicSessionMemoryStore.shared.memory, player.rememberedMusicSessionPlayableCount > 0 {
            candidates.append(.init(space: .music, lastListenedAt: memory.savedAt))
            contents[.music] = .music(memory)
        }
        if let station = radioStore.stations
            .filter({ $0.lastPlayedAt != nil })
            .max(by: { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }),
           let playedAt = station.lastPlayedAt {
            candidates.append(.init(space: .radio, lastListenedAt: playedAt))
            contents[.radio] = .radio(station)
        }
        if let (book, songs) = books.first,
           let listenedAt = book.lastListenedAt {
            candidates.append(.init(space: .spokenWord, lastListenedAt: listenedAt))
            contents[.spokenWord] = .book(book, songs)
        }
        if let recent = PodcastStore.shared.mostRecentInProgress {
            candidates.append(.init(space: .podcast, lastListenedAt: recent.updatedAt))
            contents[.podcast] = .podcast(recent.episode, recent.show)
        }

        let playing = player.isPlaying ? player.currentListeningSpace : nil
        return ListeningResumePolicy.cards(from: candidates, playingSpace: playing, now: Date())
            .compactMap { candidate in
                contents[candidate.space].map { Card(space: candidate.space, content: $0) }
            }
    }

    private func cardButton(_ card: Card) -> some View {
        Button {
            resume(card)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                artwork(card)
                    .frame(width: cardWidth, height: cardWidth)
                    .clipShape(RoundedRectangle(cornerRadius: HomeCoverCardMetrics.cornerRadius, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Label(card.space.title, systemImage: card.space.systemImage)
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.text(on: card.space.tint))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(card.space.tint, in: Capsule())
                            .padding(7)
                    }
                Text(title(card))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(subtitle(card))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: cardWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("home_continue_spaces_hint"))
    }

    @ViewBuilder
    private func artwork(_ card: Card) -> some View {
        switch card.content {
        case .music(let memory):
            CachedArtworkView(
                coverRef: memory.coverRef,
                songID: memory.songID,
                size: cardWidth,
                cornerRadius: HomeCoverCardMetrics.cornerRadius,
                sourceID: memory.sourceID
            )
        case .radio(let station):
            RadioStationArtworkView(station: station, size: cardWidth, cornerRadius: HomeCoverCardMetrics.cornerRadius)
        case .book(_, let songs):
            // 和书架、首页书排同一种书封:竖版封面整张放进方框,两边垫模糊底,不裁。
            SpokenWordBookCover(song: songs.first, width: cardWidth, cornerRadius: HomeCoverCardMetrics.cornerRadius)
        case .podcast(let episode, let show):
            PodcastArtwork(episode: episode, show: show, size: cardWidth, cornerRadius: HomeCoverCardMetrics.cornerRadius)
        }
    }

    private func title(_ card: Card) -> String {
        switch card.content {
        case .music(let memory): memory.title
        case .radio(let station): station.name
        case .book(let book, _): book.title
        case .podcast(let episode, _): episode.title
        }
    }

    private func subtitle(_ card: Card) -> String {
        switch card.content {
        case .music(let memory):
            return memory.subtitle ?? String(localized: "home_continue_music_queue")
        case .radio:
            return String(localized: "home_continue_radio_live")
        case .book(let book, _):
            if let remaining = book.remainingDuration, remaining > 0 {
                return String(
                    format: String(localized: "spoken_word_remaining_format"),
                    ChapterTimeFormatter.string(from: remaining)
                )
            }
            return book.author ?? ""
        case .podcast(let episode, let show):
            if let total = episode.duration,
               let position = SpokenWordStore.shared.position(forSongID: episode.id)?.position,
               total > position {
                return PodcastFormat.remaining(total - position)
            }
            return show.title
        }
    }

    private func resume(_ card: Card) {
        switch card.content {
        case .music:
            Task { await player.resumeMusicSession() }
        case .radio(let station):
            // A station on plain HTTP needs the listener's one-time consent,
            // which the radio page asks for; send them there instead.
            if let url = station.url,
               TrustedHTTPTransport.requiresPlainSocket(for: url),
               let target = TrustedHTTPTransport.trustTarget(for: url),
               !SSLTrustStore.allowsInsecureHTTPHostSync(domain: target) {
                openSpace(.radio)
                return
            }
            Task { _ = await player.play(station: station, within: radioStore.stations) }
        case .book(let book, let songs):
            SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
        case .podcast(let episode, _):
            // 明文 http 的音频要先放行:交给播客页去问。
            PodcastPlaybackLauncher.play(episode, player: player) { _ in openSpace(.podcast) }
        }
    }
}

/// "在听的书" on the home page: covers of the books in progress.
struct HomeBooksInProgressStrip: View {
    let books: [(SpokenWordBook, [Song])]
    /// With one book the "continue" row already offers it; the strip earns
    /// its place from the second book on.
    var minimumCount = 1
    var limit = 12
    var openSpace: (ListeningSpace) -> Void

    var body: some View {
        if books.count >= max(1, minimumCount) {
            VStack(alignment: .leading, spacing: 10) {
                HomeSpaceSectionHeader(
                    titleKey: "home_books_in_progress_title",
                    actionKey: "home_books_open_shelf",
                    action: { openSpace(.spokenWord) }
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(books.prefix(max(limit, 1)), id: \.0.id) { book, songs in
                            HomeBookCard(book: book, songs: songs, showsAuthor: false)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            }
        }
    }
}

/// "电台" on the home page: the shared station strip, or a card inviting the
/// listener to add stations when there are none.
struct HomeRadioSpaceSection: View {
    var limit = RadioStationRecencyPolicy.stripLimit
    var openSpace: (ListeningSpace) -> Void

    @Environment(RadioStationsStore.self) private var radioStore
    @Environment(\.homeCoverCardWidth) private var cardWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if radioStore.stations.isEmpty {
                RadioAddStationCard()
                    .padding(.horizontal, 16)
            } else {
                HomeSpaceSectionHeader(
                    titleKey: "listening_space_radio",
                    actionKey: "home_radio_open_all",
                    action: { openSpace(.radio) }
                )
                // 和上面的分区标题、别的横排一样从 20 起排;台标格和下面的书、播客封面一样大(#349)。
                RadioStationStrip(
                    horizontalInset: 20,
                    limit: limit,
                    tileWidth: cardWidth,
                    tileCornerRadius: HomeCoverCardMetrics.cornerRadius
                )
            }
        }
    }
}

/// 「有声书」on the home page: the books picked for home (or, until any are
/// picked, the most recently heard ones first), in the order chosen in the
/// home editor.
struct HomeAudiobooksSection: View {
    let snapshot: SpokenWordLibrarySnapshot
    var limit = 10
    /// 「在听的书」开着时,没挑过的情况下不再重复放听到一半的书。
    /// 挑过就完全照挑选来。
    var excludesInProgressWhenAutomatic = false
    var openSpace: (ListeningSpace) -> Void

    @AppStorage(HomeSpotlightSelection.booksStorageKey) private var selectionRawValue = ""
    @AppStorage("spokenWord.shelf.order") private var shelfOrderRawValue = ""

    var body: some View {
        let selection = HomeSpotlightSelection.decode(selectionRawValue)
        let entries = snapshot.allEntries(shelfOrder: shelfOrderRawValue)
        let candidates = selection.isAutomatic && excludesInProgressWhenAutomatic
            ? entries.filter { !$0.book.isInProgress }
            : entries
        let resolved = selection.resolve(
            candidates,
            limit: limit,
            id: \.id,
            name: \.book.title,
            lastListenedAt: \.book.lastListenedAt
        )
        if !resolved.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeSpaceSectionHeader(
                    titleKey: "home_section_audiobooks",
                    actionKey: "home_books_open_shelf",
                    action: { openSpace(.spokenWord) }
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(resolved) { entry in
                            bookButton(entry)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            }
        }
    }

    private func bookButton(_ entry: SpokenWordLibrarySnapshot.Entry) -> some View {
        HomeBookCard(book: entry.book, songs: entry.songs)
    }
}

/// 首页「有声书」「在听的书」里的一本书,照「播客」那一排的卡片排(#349):点封面或书名进书的页面,
/// 封面右下角一颗播放 / 暂停键,外圈是听到哪儿的进度,不再在封面下面另画一条进度条。
struct HomeBookCard: View {
    let book: SpokenWordBook
    let songs: [Song]
    var showsAuthor = true

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.homeCoverCardWidth) private var cardWidth

    private var tint: Color { ListeningSpace.spokenWord.tint }

    /// 和播客卡上那颗一样大:跟着封面缩放,手机横屏的小卡上也不小于 30。
    private var playButtonSize: CGFloat {
        min(36, max(30, (cardWidth * 0.23).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            NavigationLink {
                SpokenWordBookDetailView(bookID: book.id)
            } label: {
                SpokenWordBookCover(song: songs.first, width: cardWidth, cornerRadius: HomeCoverCardMetrics.cornerRadius)
                    .overlay(alignment: .topTrailing) {
                        if book.isFinished {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.subheadline)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, tint)
                                .padding(5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomTrailing) {
                playButton
                    .overArtworkKeyBackground()
                    .padding(8)
            }
            NavigationLink {
                SpokenWordBookDetailView(bookID: book.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if showsAuthor, let author = book.author, !author.isEmpty {
                        Text(author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var isCurrentBook: Bool {
        guard let currentID = player.currentSong?.id else { return false }
        return songs.contains { $0.id == currentID }
    }

    private var playButton: some View {
        let isCurrent = isCurrentBook
        let isPlaying = isCurrent && player.isPlaying
        let fraction = CGFloat(book.isFinished ? 1 : min(1, max(0, book.fractionComplete)))
        return Button {
            if isCurrent {
                player.togglePlayPause()
            } else {
                SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
            }
        } label: {
            SpokenWordProgressPlayGlyph(
                fraction: fraction,
                isPlaying: isPlaying,
                isLoading: isCurrent && player.isLoading,
                size: playButtonSize,
                tint: SpokenWordProgressPlayGlyph.overArtworkTint,
                trackOpacity: SpokenWordProgressPlayGlyph.overArtworkTrackOpacity
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isPlaying ? "pause" : (book.canContinue ? "spoken_word_continue" : "spoken_word_start")))
        .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded()))%"))
    }
}

// MARK: - 横排封面卡的尺寸

/// 首页横排封面卡共用的一套尺寸:专辑、歌单、文件夹、接着听、在听的书、有声书、播客单集都按它排,
/// 上下几排的封面才对得齐。电台台标格(`RadioStationStrip`)不在其中:台标多是小图标 fit 进描边格子,
/// 和电台页「最近收听」是同一格,放大到专辑卡那么大只会更糊、一屏露出的台更少。
enum HomeCoverCardMetrics {
    static let cornerRadius: CGFloat = 10

    /// 窄屏下比网格的一半略窄,好让第三张卡露出一角 —— 边缘不留半张卡,用户看不出这一行还能往右滑。
    /// 手机横屏再收一档:一行货架加上标题就要占掉半个视口,后面的区块全落在折叠线以下。
    /// 「小」是原来电台台标格的大小,一屏多露一张卡(#349)。
    static func width(usesPadMetrics: Bool, isCompactHeight: Bool, size: HomeCoverSize = .large) -> CGFloat {
        switch size {
        case .large: usesPadMetrics ? 160 : (isCompactHeight ? 108 : 132)
        case .small: usesPadMetrics ? 128 : (isCompactHeight ? 88 : 104)
        }
    }
}

/// 首页封面卡大一档还是小一档,首页编辑里每块各调各的(存在 `HomeSectionLayoutConfiguration`,
/// 随 iCloud 同步);哪几块、哪种排布能调见 `HomeSectionLayoutPolicy.supportsCoverSize`。
extension HomeCoverSize {
    /// 老版本整个首页一个大小时存的键。没单独调过的块跟着它,所以调成过「小」的人升级后各块仍是小的;
    /// 还没升级的设备也照旧读写它。
    static let legacyStorageKey = "primuse.home.coverSize"

    /// 编辑条上按钮的字:「大封面」「小封面」;挤不下时只留「大」「小」。
    var labelKey: LocalizedStringKey {
        switch self {
        case .large: "home_cover_size_large_label"
        case .small: "home_cover_size_small_label"
        }
    }

    var shortLabelKey: LocalizedStringKey {
        switch self {
        case .large: "home_cover_size_large"
        case .small: "home_cover_size_small"
        }
    }

    var toggled: HomeCoverSize { self == .large ? .small : .large }
}

extension EnvironmentValues {
    /// 首页横排封面卡的边长。`HomeView` 按 iPad / 手机横屏 / iPhone Duo 的口径算好下发给各区块,
    /// 区块别再按尺寸等级自己另算一份 —— 口径一不一致就是一排大一排小。
    @Entry var homeCoverCardWidth: CGFloat = HomeCoverCardMetrics.width(usesPadMetrics: false, isCompactHeight: false)
}

extension HomeSectionKind {
    /// 能挑选「首页放哪些」的区块对应的收听空间。
    var spotlightSpace: ListeningSpace? {
        switch self {
        case .radio: .radio
        case .audiobooks: .spokenWord
        default: nil
        }
    }
}

struct HomeSpaceSectionHeader: View {
    let titleKey: LocalizedStringKey
    let actionKey: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        // 标题前不放空间色的小圆点(#313):跟随封面时几类颜色可能一样,点就分不出什么;
        // 首页别的区块标题也没有点,去掉后标题一致。
        HStack(alignment: .firstTextBaseline) {
            Text(titleKey)
                .font(.title3.weight(.bold))
            Spacer()
            Button(action: action) {
                HStack(spacing: 2) {
                    Text(actionKey)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }
}

/// 首页「电台」「有声书」两排放哪些、按什么顺序。
///
/// 资料库里的台和书可能上千,所以挑选页带搜索,列表是懒加载的 `List`;
/// 已挑中的单独成一段,可以拖动排序、左滑移出。一个都没挑时首页自动取。
struct HomeSpotlightManagementView: View {
    let section: HomeSectionKind

    @Environment(\.dismiss) private var dismiss
    @Environment(RadioStationsStore.self) private var radioStore
    @AppStorage(HomeSpotlightSelection.radioStorageKey) private var radioRawValue = ""
    @AppStorage(HomeSpotlightSelection.booksStorageKey) private var booksRawValue = ""
    @AppStorage("spokenWord.shelf.order") private var shelfOrderRawValue = ""
    @State private var searchText = ""

    private struct Candidate: Identifiable {
        enum Artwork {
            case station(RadioStation)
            case book(Song?)
        }
        let id: String
        let title: String
        let subtitle: String?
        let artwork: Artwork
    }

    private var isRadio: Bool { section == .radio }

    private var selection: HomeSpotlightSelection {
        HomeSpotlightSelection.decode(isRadio ? radioRawValue : booksRawValue)
    }

    private func update(_ change: (inout HomeSpotlightSelection) -> Void) {
        var updated = selection
        change(&updated)
        if isRadio {
            radioRawValue = updated.encoded()
        } else {
            booksRawValue = updated.encoded()
        }
    }

    var body: some View {
        Group {
            if isRadio {
                content(radioCandidates, isPrepared: true)
            } else {
                SpokenWordLibraryContent { snapshot in
                    // 归档的书不在候选里,但仍是书:挑过的不当成已删掉清理,取消归档后回到首页。
                    content(
                        bookCandidates(snapshot),
                        isPrepared: snapshot.isPrepared,
                        retainedIDs: Set(snapshot.archived.map(\.id))
                    )
                }
            }
        }
        .navigationTitle(LocalizedStringKey(isRadio ? "home_spotlight_manage_radio" : "home_spotlight_manage_books"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 勾选、排序方式、「清空」和完成键跟有声书 / 电台自己的颜色,和打开它的书架、电台页一致(#320);
        // 不跟 App 主题色(可能正跟着封面变)。导航栏按钮不一定继承页面的 tint,单独再设一次。
        .tint(spaceTint)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("done") { dismiss() }
                    .tint(spaceTint)
            }
        }
    }

    private var spaceTint: Color? { section.spotlightSpace?.tint }

    private var radioCandidates: [Candidate] {
        radioStore.stations.map { station in
            Candidate(
                id: station.id,
                title: station.name,
                subtitle: station.playbackSubtitle,
                artwork: .station(station)
            )
        }
    }

    private func bookCandidates(_ snapshot: SpokenWordLibrarySnapshot) -> [Candidate] {
        snapshot.allEntries(shelfOrder: shelfOrderRawValue).map { entry in
            Candidate(
                id: entry.id,
                title: entry.book.title,
                subtitle: entry.book.author,
                artwork: .book(entry.songs.first)
            )
        }
    }

    @ViewBuilder
    private func content(_ candidates: [Candidate], isPrepared: Bool, retainedIDs: Set<String> = []) -> some View {
        let current = selection
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 资料库还没装载完时不显示「已不存在」的条目,也不清理 —— 那时查不到不代表没了。
        let pinned = current.pinnedIDs.compactMap { byID[$0] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? candidates
            : candidates.filter {
                $0.title.localizedStandardContains(query)
                    || ($0.subtitle?.localizedStandardContains(query) ?? false)
            }

        List {
            Section {
                Picker("home_spotlight_order", selection: Binding(
                    get: { current.order },
                    set: { order in update { $0.order = order } }
                )) {
                    ForEach(HomeSpotlightSelection.Order.allCases) { order in
                        Label(LocalizedStringKey(order.titleKey), systemImage: order.icon).tag(order)
                    }
                }
            } footer: {
                Text(LocalizedStringKey(
                    current.isAutomatic
                        ? (isRadio ? "home_spotlight_automatic_radio_footer" : "home_spotlight_automatic_books_footer")
                        : "home_spotlight_pinned_footer"
                ))
            }

            if !pinned.isEmpty, query.isEmpty {
                Section {
                    ForEach(pinned) { candidate in
                        row(candidate, isPinned: true, showsToggle: false)
                    }
                    .onMove { source, destination in
                        // 只在全部条目都查得到时才按下标搬 —— 否则可见下标与存档对不上。
                        guard pinned.count == current.pinnedIDs.count else { return }
                        update { $0.movePinned(fromOffsets: source, toOffset: destination) }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { pinned[$0].id }
                        update { selection in
                            for id in ids where selection.isPinned(id) { selection.togglePin(id) }
                        }
                    }
                    .moveDisabled(current.order != .custom)
                } header: {
                    HStack {
                        Text("home_spotlight_pinned_section")
                        Spacer()
                        Button("home_spotlight_clear") {
                            update { $0.pinnedIDs = [] }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }

            Section {
                if !isPrepared {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(filtered) { candidate in
                    row(candidate, isPinned: current.isPinned(candidate.id), showsToggle: true)
                }
            } header: {
                Text(LocalizedStringKey(isRadio ? "home_spotlight_all_radio" : "home_spotlight_all_books"))
            }
        }
        .searchable(text: $searchText)
        #if os(iOS)
        .environment(\.editMode, .constant(pinned.isEmpty || !query.isEmpty ? .inactive : .active))
        #endif
        .onChange(of: isPrepared, initial: true) { _, isPrepared in
            // 已删掉的台 / 书从挑选里清掉,免得「已选 3 个」首页却只出来 1 个。
            guard isPrepared, !candidates.isEmpty else { return }
            let existing = Set(candidates.map(\.id)).union(retainedIDs)
            if current.pinnedIDs.contains(where: { !existing.contains($0) }) {
                update { $0.prune(keeping: existing) }
            }
        }
    }

    private func row(_ candidate: Candidate, isPinned: Bool, showsToggle: Bool) -> some View {
        HStack(spacing: 12) {
            switch candidate.artwork {
            case .station(let station):
                RadioStationArtworkView(station: station, size: 40, cornerRadius: 8)
            case .book(let song):
                SpokenWordBookCover(song: song, width: 30, cornerRadius: 4)
                    .frame(width: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .lineLimit(1)
                if let subtitle = candidate.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showsToggle {
                Button {
                    update { $0.togglePin(candidate.id) }
                } label: {
                    Image(systemName: isPinned ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(LocalizedStringKey(isPinned ? "home_spotlight_remove" : "home_spotlight_add")))
            }
        }
        .contentShape(Rectangle())
    }
}
