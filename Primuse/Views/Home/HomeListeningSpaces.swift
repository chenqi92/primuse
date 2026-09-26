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

    private struct Card: Identifiable {
        enum Content {
            case music(MusicSessionMemoryStore.Memory)
            case radio(RadioStation)
            case book(SpokenWordBook, [Song])
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

        if let memory = MusicSessionMemoryStore.shared.memory {
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
                    .frame(width: 136, height: 136)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Label(card.space.title, systemImage: card.space.systemImage)
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.white)
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
            .frame(width: 136, alignment: .leading)
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
                size: 136,
                cornerRadius: 12,
                sourceID: memory.sourceID
            )
        case .radio(let station):
            RadioStationArtworkView(station: station, size: 136, cornerRadius: 12)
        case .book(_, let songs):
            if let cover = songs.first {
                CachedArtworkView(
                    coverRef: cover.coverArtFileName,
                    songID: cover.id,
                    size: 136,
                    cornerRadius: 12,
                    sourceID: cover.sourceID,
                    filePath: cover.filePath,
                    fileFormat: cover.fileFormat
                )
            }
        }
    }

    private func title(_ card: Card) -> String {
        switch card.content {
        case .music(let memory): memory.title
        case .radio(let station): station.name
        case .book(let book, _): book.title
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

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        if books.count >= max(1, minimumCount) {
            VStack(alignment: .leading, spacing: 10) {
                HomeSpaceSectionHeader(
                    titleKey: "home_books_in_progress_title",
                    space: .spokenWord,
                    actionKey: "home_books_open_shelf",
                    action: { openSpace(.spokenWord) }
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(books.prefix(max(limit, 1)), id: \.0.id) { book, songs in
                            Button {
                                SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    SpokenWordBookCover(song: songs.first, width: 104, cornerRadius: 8)
                                    ProgressView(value: book.fractionComplete)
                                        .progressViewStyle(.linear)
                                        .tint(ListeningSpace.spokenWord.tint)
                                    Text(book.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                                .frame(width: 104, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if radioStore.stations.isEmpty {
                RadioAddStationCard()
                    .padding(.horizontal, 16)
            } else {
                HomeSpaceSectionHeader(
                    titleKey: "listening_space_radio",
                    space: .radio,
                    actionKey: "home_radio_open_all",
                    action: { openSpace(.radio) }
                )
                RadioStationStrip(limit: limit)
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

    @Environment(AudioPlayerService.self) private var player
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
                    space: .spokenWord,
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
        let book = entry.book
        return Button {
            SpokenWordBookSupport.play(book, songs: entry.songs, from: nil, player: player)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                SpokenWordBookCover(song: entry.songs.first, width: 104, cornerRadius: 8)
                    .overlay(alignment: .topTrailing) {
                        if book.isFinished {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.subheadline)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, ListeningSpace.spokenWord.tint)
                                .padding(5)
                        }
                    }
                if book.isInProgress {
                    ProgressView(value: book.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(ListeningSpace.spokenWord.tint)
                }
                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 104, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
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
    let space: ListeningSpace
    let actionKey: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(space.tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
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
                    content(bookCandidates(snapshot), isPrepared: snapshot.isPrepared)
                }
            }
        }
        .navigationTitle(LocalizedStringKey(isRadio ? "home_spotlight_manage_radio" : "home_spotlight_manage_books"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("done") { dismiss() }
            }
        }
    }

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
    private func content(_ candidates: [Candidate], isPrepared: Bool) -> some View {
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
            let existing = Set(candidates.map(\.id))
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
