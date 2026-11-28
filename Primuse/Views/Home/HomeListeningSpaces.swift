import PrimuseKit
import SwiftUI

@MainActor
struct PodcastResumeItem {
    enum Source {
        case subscription(PodcastEpisode, PodcastShow)
        case library(Song, showID: String, showTitle: String)
    }

    let source: Source
    let position: SpokenWordStore.StoredPosition

    var title: String {
        switch source {
        case .subscription(let episode, _): episode.title
        case .library(let song, _, _): song.title
        }
    }

    var showTitle: String {
        switch source {
        case .subscription(_, let show): show.title
        case .library(_, _, let title): title
        }
    }

    var id: String {
        switch source {
        case .subscription(let episode, _): episode.id
        case .library(let song, _, _): song.id
        }
    }

    static func recent(
        in library: MusicLibrary, limit: Int,
        progress: SpokenWordStore = .shared,
        subscription: @MainActor (String) -> (episode: PodcastEpisode, show: PodcastShow)? = { id in
            let store = PodcastStore.shared
            guard let found = store.episode(id: id), !store.state(for: found.episode).isFinished else { return nil }
            return found
        }
    ) -> [Self] {
        guard limit > 0 else { return [] }
        _ = library.localPodcastContentRevision
        // 书架表只在模型在内存里时有内容;放掉时不读它(读到的是空的,还会记一笔数组读),下面从曲库目录查。
        var showIDs = library.isReady ? library.localPodcastBookIDs : [:]
        var showTitles: [String: String] = [:]
        // 6c: 歌曲模型放掉时 `localPodcastBookIDs` 是空的,本机播客会从「接着听」里消失:听过的那些 id 在哪个节目、
        // 节目叫什么,从曲库目录一批查出来(按 id,只查有进度的)。
        if !library.isReady, let catalog = library.catalogHost?.mirror.readableCatalog,
           let placements = try? catalog.podcastShowPlacements(songIDs: progress.positions.keys) {
            for (songID, placement) in placements {
                showIDs[songID] = placement.showID
                if let title = placement.title { showTitles[songID] = title }
            }
        }
        // 只按听过的播客排序，资料库里的所有单集无需重新分组。
        let positions = progress.positions.filter { showIDs[$0.key] != nil || PodcastIdentity.isEpisodeID($0.key) }
            .sorted {
                if $0.value.updatedAt != $1.value.updatedAt { return $0.value.updatedAt > $1.value.updatedAt }
                let lhsIsFeed = PodcastIdentity.isEpisodeID($0.key)
                if lhsIsFeed != PodcastIdentity.isEpisodeID($1.key) { return lhsIsFeed }
                return $0.key < $1.key
            }
        var items: [Self] = []
        for (id, stored) in positions {
            guard !progress.isFinished(songID: id) else { continue }
            if let showID = showIDs[id] {
                guard !progress.isArchived(bookID: showID),
                      let song = library.unobservedVisibleSong(id: id), song.isPlayable else { continue }
                let title = (library.isReady ? library.localPodcastShowTitle(forSongID: id) : nil)
                    ?? showTitles[id] ?? song.albumTitle ?? song.title
                items.append(Self(source: .library(song, showID: showID, showTitle: title), position: stored))
            } else if let (episode, show) = subscription(id) {
                var position = stored
                position.duration = episode.duration ?? stored.duration
                items.append(Self(source: .subscription(episode, show), position: position))
            }
            if items.count == limit { break }
        }
        return items
    }

    @ViewBuilder
    func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        switch source {
        case .subscription(let episode, let show):
            PodcastArtwork(episode: episode, show: show, size: size, cornerRadius: cornerRadius)
        case .library(let song, _, _):
            CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: size, cornerRadius: cornerRadius,
                              sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat,
                              placeholderIcon: "antenna.radiowaves.left.and.right")
        }
    }

    func resume(player: AudioPlayerService, needsInsecureConsent: @escaping @MainActor (String) -> Void) {
        switch source {
        case .subscription(let episode, _):
            PodcastPlaybackLauncher.play(episode, player: player, needsInsecureConsent: needsInsecureConsent)
        case .library(let song, _, _):
            if player.currentSong?.id == song.id {
                if !player.isPlaying { player.togglePlayPause() }
            } else {
                Task { await player.play(queue: [song], startingAt: 0) }
            }
        }
    }
}

/// Home's first row: "continue" for each way of listening, one card each,
/// newest first. Each card resumes by its own space's rules — the music queue
/// someone left, the last station, the book where it was left — and the
/// non-music space playing right now gets no card. The music queue stays
/// reachable even while an unrelated single song is playing.
struct HomeContinueSpacesRow: View {
    let books: [(SpokenWordBook, [Song])]
    var openSpace: (ListeningSpace) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(RadioStationsStore.self) private var radioStore
    @Environment(\.homeCoverCardWidth) private var cardWidth

    private struct Card: Identifiable {
        enum Content {
            case music(MusicSessionMemoryStore.Memory)
            case radio(RadioStation)
            case book(SpokenWordBook, [Song])
            case podcast(PodcastResumeItem)
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
        if let memory = player.musicSessionMemoryStore.memory, player.hasPlayableRememberedMusicSession {
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
        if let recent = PodcastResumeItem.recent(in: library, limit: 1).first {
            candidates.append(.init(space: .podcast, lastListenedAt: recent.position.updatedAt))
            contents[.podcast] = .podcast(recent)
        }

        let playing = player.isPlaying ? player.currentListeningSpace : nil
        return ListeningResumePolicy.cards(from: candidates, playingSpace: playing == .music ? nil : playing, now: Date())
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
        case .podcast(let recent):
            recent.artwork(size: cardWidth, cornerRadius: HomeCoverCardMetrics.cornerRadius)
        }
    }

    private func title(_ card: Card) -> String {
        switch card.content {
        case .music(let memory): memory.title
        case .radio(let station): station.name
        case .book(let book, _): book.title
        case .podcast(let recent): recent.title
        }
    }

    private func subtitle(_ card: Card) -> String {
        switch card.content {
        case .music:
            return String(localized: "home_continue_music_queue")
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
        case .podcast(let recent):
            let remaining = recent.position.duration - recent.position.position
            if remaining > 0 {
                return PodcastFormat.remaining(remaining)
            }
            return recent.showTitle
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
        case .podcast(let recent):
            recent.resume(player: player) { _ in openSpace(.podcast) }
        }
    }
}

struct HomeBooksInProgressStrip: View {
    let snapshot: SpokenWordLibrarySnapshot
    var limit = 12
    var openSpace: (ListeningSpace) -> Void
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(HomeSectionLayoutConfiguration.storageKey) private var layoutRawValue = ""

    var body: some View {
        let entries = snapshot.listening(to: player.currentBookID).listeningEntries
        if !entries.isEmpty {
            SpokenWordContinueShelf(
                entries: entries,
                style: HomeSectionLayoutConfiguration.decode(layoutRawValue).booksInProgressStyle,
                limit: limit,
                horizontalInset: 20,
                titleKey: "home_books_in_progress_title",
                moreAction: { openSpace(.spokenWord) }
            )
        }
    }
}

struct SpokenWordContinueShelf: View {
    typealias Entry = SpokenWordLibrarySnapshot.Entry
    let entries: [Entry]
    let style: SpokenWordContinueStyle
    var limit = 12
    var horizontalInset: CGFloat = 0
    var titleKey: LocalizedStringKey = "spoken_word_now_listening_section"
    var moreAction: (() -> Void)? = nil
    var contextMenu: ((Entry) -> AnyView)? = nil

    var body: some View {
        let shown = Array(entries.prefix(max(1, limit)))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(titleKey)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if moreAction != nil || shown.count < entries.count {
                        Group {
                            if let moreAction {
                                Button(action: moreAction) { viewAllLabel }
                            } else {
                                NavigationLink {
                                    SpokenWordContinueList(entries: entries, titleKey: titleKey, contextMenu: contextMenu)
                                } label: {
                                    viewAllLabel
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("spokenWord.continue.viewAll")
                    }
                }
                .padding(.horizontal, horizontalInset)

                switch style {
                case .carousel:
                    covers(shown)
                case .featured:
                    if let latest = shown.first {
                        SpokenWordContinueRow(entry: latest, featured: true)
                            .contextMenu { contextMenu?(latest) }
                            .padding(.horizontal, horizontalInset)
                        if shown.count > 1 {
                            covers(Array(shown.dropFirst()))
                        }
                    }
                case .list:
                    LazyVStack(spacing: 12) {
                        ForEach(shown) { entry in
                            SpokenWordContinueRow(entry: entry)
                                .contextMenu { contextMenu?(entry) }
                            if entry.id != shown.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
            }
            .accessibilityIdentifier("spokenWord.continue." + style.rawValue)
        }
    }

    private var viewAllLabel: some View {
        HStack(spacing: 4) {
            Text("home_section_view_all")
            Image(systemName: "chevron.right").font(.caption)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func covers(_ entries: [Entry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(entries) { entry in
                    HomeBookCard(book: entry.book, songs: entry.songs, showsAuthor: false, showsListeningProgress: true,
                                 coverSong: entry.coverSong)
                        .contextMenu { contextMenu?(entry) }
                }
            }
            .padding(.horizontal, horizontalInset)
        }
        .pmStopsAtVerticalBar()
    }
}

private struct SpokenWordContinueList: View {
    let entries: [SpokenWordLibrarySnapshot.Entry]
    let titleKey: LocalizedStringKey
    var contextMenu: ((SpokenWordLibrarySnapshot.Entry) -> AnyView)?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(entries) { entry in
                    SpokenWordContinueRow(entry: entry)
                        .contextMenu { contextMenu?(entry) }
                    if entry.id != entries.last?.id { Divider() }
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("spokenWord.continue.all")
        .navigationTitle(titleKey)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct SpokenWordContinueRow: View {
    let entry: SpokenWordLibrarySnapshot.Entry
    var featured = false
    @Environment(AudioPlayerService.self) private var player
    @ScaledMetric(relativeTo: .body) private var rowCoverWidth: CGFloat = 64

    private var tint: Color { ListeningSpace.spokenWord.tint }
    private var isCurrent: Bool { player.currentBookID == entry.id }

    var body: some View {
        HStack(spacing: 14) {
            SpokenWordBookLink(bookID: entry.id) {
                HStack(alignment: .center, spacing: 12) {
                    SpokenWordBookCover(song: entry.coverSong, width: featured ? 80 : rowCoverWidth, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.book.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let chapter = SpokenWordBookSupport.chapterPosition(
                            entry.book, playingItemID: isCurrent ? player.currentSong?.id : nil
                        ) {
                            Text(chapter).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(SpokenWordPlayerText.bookFraction(entry.book.fractionComplete))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if let remaining = entry.book.remainingDuration {
                            let duration = SpokenWordNowPlayingPolicy.listeningTime(
                                forContent: remaining, rate: player.spokenWordRate(forBookID: entry.id)
                            )
                            Text(String(format: String(localized: "spoken_word_book_remaining_format"),
                                        SpokenWordPlayerText.approximateDuration(duration)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        SpokenWordProgressBar(value: entry.book.fractionComplete, tint: tint)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            Button {
                if isCurrent && player.isPlaying {
                    player.togglePlayPause()
                } else if isCurrent {
                    player.resumeCurrentSpokenWordBook()
                } else {
                    SpokenWordBookSupport.play(entry.book, songs: entry.songs, from: nil, player: player)
                }
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .foregroundStyle(featured ? .white : tint)
                    .background(featured ? tint : tint.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isCurrent && player.isPlaying ? "pause" : "spoken_word_continue"))
            .accessibilityValue(Text(entry.book.title))
        }
        .padding(featured ? 14 : 0)
        .background(featured ? tint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 18))
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
    var showsListeningProgress = false
    /// 封面那首;不给就是第一章(书架的启动快照里 `songs` 是空的)。
    var coverSong: Song? = nil

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
                SpokenWordBookCover(song: coverSong ?? songs.first, width: cardWidth, cornerRadius: HomeCoverCardMetrics.cornerRadius)
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
                    if showsListeningProgress {
                        if let chapter = SpokenWordBookSupport.chapterPosition(
                            book, playingItemID: isCurrentBook ? player.currentSong?.id : nil
                        ) {
                            Text(chapter).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(SpokenWordPlayerText.bookFraction(book.fractionComplete))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
            if isCurrent && player.isPlaying {
                player.togglePlayPause()
            } else if isCurrent {
                player.resumeCurrentSpokenWordBook()
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
        #if os(macOS)
        // Mac 上是自己画的弹框(标题行、搜索与排序、列表、底栏),不套导航栈:
        // 弹框里导航标题不显示,工具栏的搜索框和「完成」会被系统摆得七零八落。
        .frame(width: 480, height: 600)
        .background(PMColor.bg)
        .tint(spaceTint)
        #else
        .navigationTitle(LocalizedStringKey(titleKey))
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
        #endif
    }

    private var titleKey: String {
        isRadio ? "home_spotlight_manage_radio" : "home_spotlight_manage_books"
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

        Group {
            #if os(macOS)
            macContent(current: current, pinned: pinned, query: query, filtered: filtered, isPrepared: isPrepared)
            #else
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
                    Text(LocalizedStringKey(footerKey(current)))
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
            #endif
        }
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

    private func footerKey(_ current: HomeSpotlightSelection) -> String {
        current.isAutomatic
            ? (isRadio ? "home_spotlight_automatic_radio_footer" : "home_spotlight_automatic_books_footer")
            : "home_spotlight_pinned_footer"
    }

    #if os(macOS)
    /// Mac 弹框: 标题行 → 搜索与排序 → 说明 → 「已在首页」(可拖动) 与全部条目 → 底栏「清空」「完成」。
    /// 列表仍用 `List`, 拖动排序靠它; 行、分组标题和底色都换成 Mac 弹框那一套。
    private func macContent(
        current: HomeSpotlightSelection,
        pinned: [Candidate],
        query: String,
        filtered: [Candidate],
        isPrepared: Bool
    ) -> some View {
        VStack(spacing: 0) {
            MacSheetHeader(
                Text(LocalizedStringKey(titleKey)),
                systemImage: isRadio ? "dot.radiowaves.left.and.right" : "house",
                tint: spaceTint,
                onClose: { dismiss() }
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    MacSheetSearchField(text: $searchText, prompt: Text("search_title"), tint: spaceTint)
                    macOrderMenu(current)
                }
                Text(LocalizedStringKey(footerKey(current)))
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, MacSheetMetrics.horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            List {
                if !pinned.isEmpty, query.isEmpty {
                    Section {
                        ForEach(pinned) { candidate in
                            macRow(candidate, isPinned: true, inPinnedSection: true, draggable: current.order == .custom)
                        }
                        .onMove { source, destination in
                            // 只在全部条目都查得到时才按下标搬 —— 否则可见下标与存档对不上。
                            guard pinned.count == current.pinnedIDs.count else { return }
                            update { $0.movePinned(fromOffsets: source, toOffset: destination) }
                        }
                        .moveDisabled(current.order != .custom)
                    } header: {
                        macSectionHeader("home_spotlight_pinned_section", count: pinned.count)
                    }
                }

                Section {
                    if !isPrepared {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(filtered) { candidate in
                        macRow(candidate, isPinned: current.isPinned(candidate.id), inPinnedSection: false, draggable: false)
                    }
                } header: {
                    macSectionHeader(isRadio ? "home_spotlight_all_radio" : "home_spotlight_all_books", count: nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)

            MacSheetFooter {
                if !pinned.isEmpty {
                    Button("home_spotlight_clear") {
                        update { $0.pinnedIDs = [] }
                    }
                    .buttonStyle(.macSheetDestructive)
                }
            } trailing: {
                Button("done") { dismiss() }
                    .buttonStyle(.macSheetPrimary(tint: spaceTint))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func macSectionHeader(_ key: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            MacSheetSectionLabel(LocalizedStringKey(key))
            if let count {
                Text(verbatim: "\(count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(PMColor.textFaint)
            }
            Spacer(minLength: 0)
        }
        // 和行里的封面左边对齐: 系统给分组标题的左边距比行少 24 点(实拍量出来的)。
        .padding(.leading, 24)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// 排序方式: 一颗和搜索框同高的小按钮, 点开是带勾的选项。
    private func macOrderMenu(_ current: HomeSpotlightSelection) -> some View {
        Menu {
            Picker("home_spotlight_order", selection: Binding(
                get: { current.order },
                set: { order in update { $0.order = order } }
            )) {
                ForEach(HomeSpotlightSelection.Order.allCases) { order in
                    Label(LocalizedStringKey(order.titleKey), systemImage: order.icon).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.order.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(LocalizedStringKey(current.order.titleKey))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
            }
            .foregroundStyle(PMColor.text)
            .padding(.horizontal, 10)
            .frame(height: MacSheetMetrics.controlHeight)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: MacSheetMetrics.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MacSheetMetrics.controlRadius, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("home_spotlight_order"))
    }

    /// 整行点下去就是放到首页 / 从首页拿掉; 「已在首页」那一段右边是移除键, 自定义顺序时左边有拖动把手。
    private func macRow(_ candidate: Candidate, isPinned: Bool, inPinnedSection: Bool, draggable: Bool) -> some View {
        Button {
            update { $0.togglePin(candidate.id) }
        } label: {
            HStack(spacing: 10) {
                if draggable {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                        .frame(width: 14)
                }
                Group {
                    switch candidate.artwork {
                    case .station(let station):
                        RadioStationArtworkView(station: station, size: 30, cornerRadius: 6)
                    case .book(let song):
                        SpokenWordBookCover(song: song, width: 24, cornerRadius: 3)
                    }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: candidate.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    if let subtitle = candidate.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: inPinnedSection
                      ? "minus.circle"
                      : (isPinned ? "checkmark.circle.fill" : "plus.circle"))
                    .font(.system(size: 15))
                    .foregroundStyle(isPinned && !inPinnedSection
                                     ? AnyShapeStyle(.tint)
                                     : AnyShapeStyle(PMColor.textFaint))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(Text(verbatim: candidate.title))
        .accessibilityHint(Text(LocalizedStringKey(isPinned ? "home_spotlight_remove" : "home_spotlight_add")))
        .accessibilityAddTraits(isPinned ? .isSelected : [])
        .help(Text(LocalizedStringKey(isPinned ? "home_spotlight_remove" : "home_spotlight_add")))
    }
    #endif
}

struct QueueBookmarkButton: View {
    let player: AudioPlayerService

    /// 在播放页「接下来」那一面里时:横滑从这颗键上起手,松手那一下不算点。别处为 nil。
    @Environment(\.nowPlayingCarouselTapGuard) private var carouselTapGuard

    var body: some View {
        if player.canBookmarkCurrentQueue {
            let isSaved = player.isCurrentQueueBookmarked
            let title = Text(isSaved ? LocalizedStringKey("queue_bookmark_remove") : LocalizedStringKey("queue_bookmark_save"))
            PMScrollingButton {
                carouselTapGuard.perform { Task { await player.toggleCurrentQueueBookmark() } }
            } label: {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    #if os(macOS)
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 22, height: 32)
                    #else
                    .font(.footnote.weight(.semibold))
                    .frame(width: 36, height: 44)
                    #endif
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.accentColor)
            .disabled(player.queueBookmarkStore.isBusy)
            .accessibilityLabel(title)
            #if os(macOS)
            .pmScrollingHelp(title)
            #endif
            .accessibilityIdentifier("queueBookmarkToggle")
        }
    }
}

struct QueueBookmarksSection: View {
    /// 左右留白。Mac 首页外层已经留了边，传 0 和别的区块对齐（同 `StartListeningShelf`）。
    var horizontalInset: CGFloat = 20
    @Environment(AudioPlayerService.self) private var player
    @State private var showsAll = false

    var body: some View {
        let bookmarks = player.queueBookmarkStore.bookmarks
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("queue_bookmarks_title").font(.title3.weight(.bold))
                    Spacer()
                    // 跟着首页一起滚动:macOS 15 上不能用系统按钮,原因见 `PMScrollingButton`。
                    PMScrollingButton { showsAll = true } label: {
                        Text("see_all").foregroundStyle(Color.accentColor)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(bookmarks.prefix(6)) { bookmark in
                            bookmarkButton(bookmark).frame(width: 156)
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalInset)
            .sheet(isPresented: $showsAll) {
                NavigationStack {
                    List(bookmarks) { bookmark in bookmarkButton(bookmark) }
                        .navigationTitle("queue_bookmarks_title")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("close") { showsAll = false }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #endif
            }
        }
    }

    private func bookmarkButton(_ bookmark: QueueBookmarkSummary) -> some View {
        PMScrollingButton {
            Task { if await player.resumeQueueBookmark(bookmark.id) { showsAll = false } }
        } label: {
            HStack(spacing: 10) {
                CachedArtworkView(coverRef: bookmark.coverRef, songID: bookmark.songID,
                                  size: 48, sourceID: bookmark.sourceID)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(bookmark.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(ChapterTimeFormatter.string(from: bookmark.position))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button("queue_bookmark_remove", role: .destructive) {
                if player.queueBookmarkStore.bookmarks.count == 1 { showsAll = false }
                Task { await player.removeQueueBookmark(bookmark.id) }
            }
        }
        .swipeActions {
            Button("queue_bookmark_remove", role: .destructive) {
                if player.queueBookmarkStore.bookmarks.count == 1 { showsAll = false }
                Task { await player.removeQueueBookmark(bookmark.id) }
            }
        }
    }
}

struct RecentPlaybackSection: View {
    var style: HomeSectionLayoutStyle = .grid
    /// 左右留白。Mac 首页外层已经留了边，传 0 和别的区块对齐（同 `StartListeningShelf`）。
    var horizontalInset: CGFloat = 20
    var limit = 12
    var rows = 2
    var startupSongs: [Song] = []
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private enum Content {
        case song(Song), album(Album), playlist(Playlist), smartPlaylist(SmartPlaylist), artist(Artist)

        var title: String {
            switch self {
            case .song(let value): value.title
            case .album(let value): value.title
            case .playlist(let value): value.name
            case .smartPlaylist(let value): value.name
            case .artist(let value): value.name
            }
        }
        var kindTitle: LocalizedStringKey {
            switch self {
            case .song: "tab_songs"
            case .album: "album_label"
            case .playlist, .smartPlaylist: "tab_playlists"
            case .artist: "artist_label"
            }
        }
    }

    private struct Tile: Identifiable {
        let id: String
        let content: Content
    }

    private var tiles: [Tile] {
        if !library.isUsable { // 下面都按 id 取,模型不在内存里时由曲库目录作答;启动时还不可用才摆启动那一份
            return startupSongs.prefix(limit).filter {
                $0.isPlayable && !library.disabledSourceIDs.contains($0.sourceID)
            }.map { Tile(id: "song:\($0.id)", content: .song($0)) }
        }
        var items = RecentPlaybackStore.shared.items
        // Existing listening history supplies singles and recently heard albums
        // on upgrade; playlist/artist identity comes only from explicit entrances.
        for entry in PlayHistoryStore.shared.entries.prefix(100) {
            guard let song = library.visibleSong(id: entry.songID), song.isPlayable,
                  player.listeningSpace(of: song) == .music else { continue }
            items.append(.init(kind: .song, entityID: song.id, playedAt: entry.playedAt))
            if let albumID = song.albumID {
                items.append(.init(kind: .album, entityID: albumID, playedAt: entry.playedAt))
            }
        }
        let playlists = Dictionary(library.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(RecentPlaybackHistory.merging(items).compactMap { item -> Tile? in
            let content: Content?
            switch item.kind {
            case .song:
                content = library.visibleSong(id: item.entityID).flatMap {
                    $0.isPlayable && player.listeningSpace(of: $0) == .music ? .song($0) : nil
                }
            case .album: content = library.visibleAlbum(id: item.entityID).map(Content.album)
            case .playlist:
                content = playlists[item.entityID].map(Content.playlist)
                    ?? library.smartPlaylists.first(where: { $0.id == item.entityID }).map(Content.smartPlaylist)
            case .artist: content = (library.visibleArtist(id: item.entityID) ?? library.visibleAlbumArtist(id: item.entityID)).map(Content.artist)
            }
            return content.map { Tile(id: item.id, content: $0) }
        }.prefix(limit))
    }

    var body: some View {
        let tiles = tiles
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("recently_played").font(.title3.weight(.bold))
                switch style {
                case .carousel:
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(60), spacing: 10),
                                              count: max(1, min(rows, tiles.count))), spacing: 10) {
                            ForEach(tiles) { tile in link(tile).frame(width: 250, height: 60) }
                        }
                    }
                    .pmStopsAtVerticalBar()
                case .grid:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(tiles) { tile in link(tile) }
                    }
                case .list:
                    LazyVStack(spacing: 8) {
                        ForEach(tiles) { tile in link(tile) }
                    }
                }
            }
            .padding(.horizontal, horizontalInset)
        }
    }

    @ViewBuilder
    private func link(_ tile: Tile) -> some View {
        switch tile.content {
        // 跟着首页一起滚动:macOS 15 上不能用系统按钮和 NavigationLink,原因见 `PMScrollingButton`。
        case .song(let song):
            PMScrollingButton { Task { await player.play(queue: [song]) } } label: { label(tile.content) }
        case .album(let album):
            #if os(macOS)
            MacHomeDetailLink(album: album) { label(tile.content) }
            #else
            NavigationLink(value: album) { label(tile.content) }.buttonStyle(.plain)
            #endif
        case .playlist(let playlist):
            #if os(macOS)
            MacHomeDetailLink(playlist: playlist) { label(tile.content) }
            #else
            NavigationLink(value: playlist) { label(tile.content) }.buttonStyle(.plain)
            #endif
        case .smartPlaylist(let playlist):
            #if os(macOS)
            MacHomeDetailLink(smartPlaylist: playlist) { label(tile.content) }
            #else
            NavigationLink(value: playlist) { label(tile.content) }.buttonStyle(.plain)
            #endif
        case .artist(let artist):
            #if os(macOS)
            MacHomeDetailLink(artist: artist) { label(tile.content) }
            #else
            NavigationLink(value: artist) { label(tile.content) }.buttonStyle(.plain)
            #endif
        }
    }

    private func label(_ content: Content) -> some View {
        HStack(spacing: 10) {
            artwork(content).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(content.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(content.kindTitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func artwork(_ content: Content) -> some View {
        switch content {
        case .song(let song):
            CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 48,
                              cornerRadius: 8, sourceID: song.sourceID)
        case .album(let album): AlbumArtworkView(album: album, size: 48, cornerRadius: 8)
        case .playlist(let playlist): PlaylistArtworkView(playlist: playlist, size: 48, cornerRadius: 8)
        case .smartPlaylist:
            Image(systemName: "sparkles").font(.title2).foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .artist(let artist): ArtistArtworkView(artist: artist, size: 48, cornerRadius: 24)
        }
    }
}
