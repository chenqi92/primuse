import PrimuseKit
import SwiftUI

/// The contents of the book that is playing, and its bookmarks.
///
/// Contents are the book's files, or the chapter marks of a one-file book
/// (`SpokenWordContentsPolicy`); the playing file's own marks are listed
/// under it. Bookmarks are the whole book's, in reading order, so a mark
/// made three chapters ago is one tap away. Shown as a sheet on the iPhone
/// and embedded beside the player on the iPad and the Mac.
struct SpokenWordContentsView: View {
    enum Presentation {
        /// A sheet with its own navigation bar.
        case sheet
        /// A pane of the player, drawn in the player's colours.
        case embedded(SpokenWordPlayerPalette)
    }

    enum Tab: Hashable { case contents, bookmarks, text }

    var presentation: Presentation = .sheet
    /// A third tab with the item's timed text (a transcript read as
    /// lyrics), offered only when the item has one.
    var textTab: AnyView?
    /// Called after a row was opened, so a sheet can close.
    var onOpen: (() -> Void)?

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .contents
    @State private var renaming: SpokenWordBookmark?
    @State private var renameText = ""
    @State private var bookmarkFeedbackToken = 0

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private var palette: SpokenWordPlayerPalette? {
        if case let .embedded(palette) = presentation { return palette }
        return nil
    }

    private var isSheet: Bool { palette == nil }

    var body: some View {
        Group {
            if isSheet {
                NavigationStack {
                    content
                        .navigationTitle(SpokenWordPlayerText.bookTitle(player))
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("done") { dismiss() }
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                addBookmarkButton
                            }
                        }
                }
            } else {
                content
            }
        }
        .alert(
            String(localized: "spoken_word_rename_bookmark"),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField(String(localized: "spoken_word_bookmark_name"), text: $renameText)
            Button("cancel", role: .cancel) { renaming = nil }
            Button("done") {
                if let renaming {
                    store.renameBookmark(id: renaming.id, songID: renaming.songID, title: renameText)
                }
                renaming = nil
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker(selection: $tab) {
                Text("spoken_word_contents_title").tag(Tab.contents)
                Text(bookmarksTabTitle).tag(Tab.bookmarks)
                if textTab != nil {
                    Text("spoken_word_text_tab").tag(Tab.text)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            switch tab {
            case .contents:
                contentsList
            case .bookmarks:
                bookmarksList
            case .text:
                if let textTab {
                    textTab
                } else {
                    contentsList
                }
            }
        }
        .onChange(of: textTab == nil) { _, hasNoText in
            if hasNoText, tab == .text { tab = .contents }
        }
    }

    private var bookmarksTabTitle: String {
        let count = bookmarkEntries.count
        return count > 0
            ? String(format: String(localized: "spoken_word_bookmarks_count_format"), count)
            : String(localized: "spoken_word_bookmarks_title")
    }

    private var bookmarkEntries: [SpokenWordBookBookmarkPolicy.Entry] {
        _ = store.bookmarks.count
        return player.currentBookBookmarkEntries
    }

    // MARK: Contents

    private var contentsList: some View {
        // Reading these registers the list with the store, so progress and
        // finished marks refresh while the list is open.
        _ = store.positions.count
        _ = store.finishedAt.count
        let rows = player.spokenWordContentsRows()
        let initial = SpokenWordContentsPolicy.initialRowIndex(
            in: rows,
            resumeItemID: player.currentSpokenWordBook?.resumeItemID
        )
        return ScrollViewReader { proxy in
            List {
                if isSheet, let summary = bookSummaryLine {
                    Text(verbatim: summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { row in
                    Button {
                        player.openSpokenWordContentsRow(row)
                        onOpen?()
                        if isSheet { dismiss() }
                    } label: {
                        SpokenWordContentsRowView(row: row, palette: palette)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .id(row.id)
                    .listRowBackground(rowBackground(row))
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: row.isNested ? 44 : 16,
                        bottom: 0,
                        trailing: 16
                    ))
                    .contextMenu { rowMenu(row) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(isSheet ? .automatic : .hidden)
            .onAppear {
                guard let initial, rows.indices.contains(initial) else { return }
                proxy.scrollTo(rows[initial].id, anchor: .center)
            }
        }
    }

    /// "已听完 11/120 · 剩余 58:12:00" above a sheet's list.
    private var bookSummaryLine: String? {
        guard let book = player.currentSpokenWordBook else { return nil }
        var parts: [String] = []
        if book.chapterCount > 1 {
            parts.append(String(
                format: String(localized: "spoken_word_book_progress_format"),
                book.finishedCount,
                book.chapterCount
            ))
        }
        if let remaining = book.remainingDuration, remaining > 0 {
            parts.append(String(
                format: String(localized: "spoken_word_book_remaining_format"),
                SpokenWordPlayerText.approximateDuration(SpokenWordNowPlayingPolicy.listeningTime(
                    forContent: remaining,
                    rate: player.currentSpokenWordRate
                ))
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func rowBackground(_ row: SpokenWordContentsRow) -> some View {
        let tint = palette?.accent ?? Color.accentColor
        return (row.isCurrent ? tint.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func rowMenu(_ row: SpokenWordContentsRow) -> some View {
        if row.kind == .item {
            if store.isFinished(songID: row.itemID) {
                Button {
                    store.markFinished(false, songIDs: [row.itemID])
                } label: {
                    Label(String(localized: "spoken_word_mark_unfinished"), systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    store.markFinished(true, songIDs: [row.itemID])
                } label: {
                    Label(String(localized: "spoken_word_mark_finished"), systemImage: "checkmark")
                }
            }
        }
    }

    // MARK: Bookmarks

    private var bookmarksList: some View {
        let entries = bookmarkEntries
        return List {
            if entries.isEmpty {
                Text("spoken_word_bookmarks_empty")
                    .font(.footnote)
                    .foregroundStyle(palette?.secondary ?? .secondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(entries) { entry in
                Button {
                    player.playSpokenWordBookmark(entry.bookmark)
                    onOpen?()
                    if isSheet { dismiss() }
                } label: {
                    SpokenWordBookmarkRowView(entry: entry, palette: palette)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .listRowBackground(Color.clear)
                .contextMenu {
                    Button {
                        renameText = entry.bookmark.title
                        renaming = entry.bookmark
                    } label: {
                        Label(String(localized: "spoken_word_rename_bookmark"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        store.removeBookmark(id: entry.bookmark.id, songID: entry.bookmark.songID)
                    } label: {
                        Label(String(localized: "spoken_word_delete_bookmark"), systemImage: "trash")
                    }
                }
                #if os(iOS)
                .swipeActions {
                    Button(role: .destructive) {
                        store.removeBookmark(id: entry.bookmark.id, songID: entry.bookmark.songID)
                    } label: {
                        Label(String(localized: "spoken_word_delete_bookmark"), systemImage: "trash")
                    }
                    Button {
                        renameText = entry.bookmark.title
                        renaming = entry.bookmark
                    } label: {
                        Label(String(localized: "spoken_word_rename_bookmark"), systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                #endif
            }
            if !isSheet {
                addBookmarkButton
                    .buttonStyle(.plain)
                    .foregroundStyle(palette?.accent ?? Color.accentColor)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(isSheet ? .automatic : .hidden)
    }

    private var addBookmarkButton: some View {
        Button {
            if player.addSpokenWordBookmark() { bookmarkFeedbackToken += 1 }
            tab = .bookmarks
        } label: {
            Label(String(localized: "spoken_word_add_bookmark"), systemImage: "bookmark")
                .symbolEffect(.bounce, value: bookmarkFeedbackToken)
        }
        .disabled(player.currentSong == nil || player.isLiveRadio)
        #if os(iOS)
        .sensoryFeedback(.success, trigger: bookmarkFeedbackToken)
        #endif
    }
}

/// One contents row: number, title, length or where the listener is, and
/// a mark for finished / in progress.
struct SpokenWordContentsRowView: View {
    let row: SpokenWordContentsRow
    var palette: SpokenWordPlayerPalette?

    private var primary: Color { palette?.primary ?? .primary }
    private var secondary: Color { palette?.secondary ?? .secondary }
    private var tertiary: Color { palette?.tertiary ?? Color.secondary.opacity(0.75) }
    private var accent: Color { palette?.accent ?? .accentColor }

    private var isFinished: Bool { row.state == .finished }

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(row.number)")
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(row.isCurrent ? accent : (isFinished ? tertiary : secondary))
                .frame(minWidth: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.title.isEmpty ? " " : row.title)
                    .font(row.isNested ? .subheadline : .body)
                    .foregroundStyle(isFinished ? tertiary : primary)
                    .lineLimit(2)
                if let meta {
                    Text(verbatim: meta)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            stateMark
                .frame(width: 22, height: 22)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var meta: String? {
        switch row.state {
        case let .current(fraction), let .inProgress(fraction):
            guard let duration = row.duration, duration > 0 else { return nil }
            let heard = duration * fraction
            return String(
                format: String(localized: "spoken_word_contents_position_format"),
                ChapterTimeFormatter.string(from: heard),
                ChapterTimeFormatter.string(from: max(0, duration - heard))
            )
        case .finished:
            return String(localized: "spoken_word_finished")
        case .unplayed:
            return row.duration.map { ChapterTimeFormatter.string(from: $0) }
        }
    }

    @ViewBuilder
    private var stateMark: some View {
        switch row.state {
        case .finished:
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(tertiary)
        case let .current(fraction):
            ZStack {
                Circle().stroke(tertiary.opacity(0.35), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(2)
            .accessibilityLabel(Text("now_playing"))
        case let .inProgress(fraction):
            ZStack {
                Circle().stroke(tertiary.opacity(0.35), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(2)
        case .unplayed:
            Color.clear
        }
    }
}

struct SpokenWordBookmarkRowView: View {
    let entry: SpokenWordBookBookmarkPolicy.Entry
    var palette: SpokenWordPlayerPalette?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bookmark.fill")
                .font(.footnote)
                .foregroundStyle(palette?.accent ?? Color.accentColor)
                .frame(minWidth: 22)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.bookmark.title)
                    .font(.body)
                    .foregroundStyle(palette?.primary ?? .primary)
                    .lineLimit(2)
                Text(verbatim: whereText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette?.secondary ?? .secondary)
                Text(entry.bookmark.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(palette?.tertiary ?? .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var whereText: String {
        let time = ChapterTimeFormatter.string(from: entry.bookmark.position)
        guard let part = entry.partNumber else { return time }
        return String(format: String(localized: "spoken_word_bookmark_where_format"), part, time)
    }
}

/// Chapter positions run to many hours, so the hour component appears only
/// when it is non-zero rather than always padding the string.
enum ChapterTimeFormatter {
    static func string(from time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
