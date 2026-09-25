import PrimuseKit
import SwiftUI

/// Home's first row: "continue" for each way of listening, one card each,
/// newest first. Each card resumes by its own space's rules — the music queue
/// someone left, the last station, the book where it was left — and the
/// space playing right now gets no card: the player bar already is its
/// "continue".
struct HomeContinueSpacesRow: View {
    var openSpace: (ListeningSpace) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
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
        _ = SpokenWordStore.shared.revision
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
        if let (book, songs) = HomeSpokenWordBooks.inProgress(in: library).first,
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
    /// With one book the "continue" row already offers it; the strip earns
    /// its place from the second book on.
    var minimumCount = 1
    var openSpace: (ListeningSpace) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        let books = HomeSpokenWordBooks.inProgress(in: library)
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
                        ForEach(books.prefix(12), id: \.0.id) { book, songs in
                            Button {
                                SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    if let cover = songs.first {
                                        CachedArtworkView(
                                            coverRef: cover.coverArtFileName,
                                            songID: cover.id,
                                            size: 104,
                                            cornerRadius: 8,
                                            sourceID: cover.sourceID,
                                            filePath: cover.filePath,
                                            fileFormat: cover.fileFormat
                                        )
                                    }
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
                RadioStationStrip()
            }
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

enum HomeSpokenWordBooks {
    /// Books with listening in progress, most recently listened first, with
    /// their songs in reading order.
    @MainActor
    static func inProgress(in library: MusicLibrary) -> [(SpokenWordBook, [Song])] {
        let store = SpokenWordStore.shared
        _ = store.revision
        let spoken = library.spokenWordSongs
        guard !spoken.isEmpty else { return [] }
        let songsByID = Dictionary(spoken.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let books = SpokenWordBookGrouping.books(
            from: spoken.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
        return books
            .filter(\.isInProgress)
            .map { book in (book, book.items.compactMap { songsByID[$0.id] }) }
    }
}
