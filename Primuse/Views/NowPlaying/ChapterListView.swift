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

    enum Tab: Hashable { case contents, bookmarks, text, notes, upNext }

    var presentation: Presentation = .sheet
    /// A third tab with the item's timed text (a transcript read as
    /// lyrics). 播放页旁边那一栏总给这一页,没有文字稿时那一页写明没有、能生成(#314);
    /// 弹出的目录面板不给。
    var textTab: AnyView?
    /// Called after a row was opened, so a sheet can close.
    var onOpen: (() -> Void)?
    /// 播放页要面板翻到哪一页(「接下来」块、队列键)。面板接手后清回 nil,
    /// 常驻右栏的面板再被要一次同一页也能翻过去。
    var requestedTab: Binding<Tab?> = .constant(nil)

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .contents
    @State private var chapterSong: Song?
    @State private var renaming: SpokenWordBookmark?
    @State private var renameText = ""
    @State private var bookmarkFeedbackToken = 0
    /// 播客单集的节目说明,排好版的段落;切到别的单集时重排。
    @State private var notesBlocks: [PodcastShowNotes.Block] = []

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private var palette: SpokenWordPlayerPalette? {
        if case let .embedded(palette) = presentation { return palette }
        return nil
    }

    private var isSheet: Bool { palette == nil }

    var body: some View {
        Group {
            if isSheet {
                #if os(macOS)
                // Mac 弹框: 书名做标题, 「添加书签」在标题右边; 不套导航栈 —— 弹框里导航标题不显示,
                // 工具栏两个按钮会被系统摆到底下、还是系统蓝。
                VStack(spacing: 0) {
                    MacSheetHeader(
                        Text(verbatim: SpokenWordPlayerText.bookTitle(player)),
                        systemImage: "list.bullet",
                        onClose: { dismiss() }
                    ) {
                        addBookmarkButton
                            .buttonStyle(.macSheet)
                    }
                    content
                }
                .frame(minWidth: 380, idealWidth: 420, minHeight: 440, idealHeight: 520)
                // 里面的列表不铺系统白底, 和标题行同一个底色。
                .scrollContentBackground(.hidden)
                .background(PMColor.bg)
                .tint(PMColor.brand)
                #else
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
                #endif
            } else {
                content
            }
        }
        .sheet(item: $chapterSong) { song in
            if let library = player.library, let manager = player.sourceManager {
                SpokenChapterGenerationSheet(
                    song: song,
                    bookSongs: player.currentBookItemIDs.compactMap { library.song(id: $0) },
                    library: library,
                    // 整轨 CUE 分轨读到整个文件那份文稿时只给这一章的、按这一章的时间(#426)。
                    loadTranscript: { chapter in
                        let lines = await LyricsLoader.load(for: chapter, sourceManager: manager, allowsAutomaticOnlineLyrics: false)
                        return CueTrackLyricsTimelinePolicy.presenting(lines, for: chapter)
                    }
                )
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
        let items = tabItems
        return VStack(spacing: 0) {
            PlayerPaneTabBar(
                items: items,
                selection: $tab,
                primary: palette?.primary ?? .primary,
                secondary: palette?.secondary ?? .secondary,
                accent: palette?.accent ?? spokenContentsSheetAccent,
                leadingInset: Self.tabLeadingInset
            )
            // 和目录行之间的分隔线一样,从序号那一列起一直通到栏的右边。
            Rectangle()
                .fill((palette?.tertiary ?? .secondary).opacity(0.25))
                .frame(height: 0.5)
                .padding(.leading, Self.tabLeadingInset)

            if let song = player.currentSong {
                HStack {
                    Spacer()
                    Button { chapterSong = song } label: {
                        Label("spoken_chapters_manage", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            VStack(spacing: 0) {
                switch tab {
                case .contents:
                    contentsPage
                case .bookmarks:
                    bookmarksList
                case .text:
                    if let textTab {
                        textTab
                    } else {
                        contentsPage
                    }
                case .notes:
                    notesPage
                case .upNext:
                    PodcastUpNextList(palette: palette) {
                        onOpen?()
                        if isSheet { dismiss() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .playerPaneTopFade()
        }
        .onChange(of: items.map(\.value)) { _, available in
            if !available.contains(tab) { tab = defaultTab }
        }
        .onChange(of: requestedTab.wrappedValue) { _, _ in applyRequestedTab() }
        .onAppear {
            if tab == .contents { tab = defaultTab }
            applyRequestedTab()
        }
        .task(id: notesSongID) { await loadPodcastNotes() }
    }

    private var offersNotes: Bool { SpokenWordPlayerText.offersPodcastNotes(player) }

    /// 页签左边缘对齐目录的序号那一列:行左边留 16,Mac 的列表自己还要再缩进 8。
    #if os(macOS)
    private static let tabLeadingInset: CGFloat = 24
    #else
    private static let tabLeadingInset: CGFloat = 16
    #endif

    private var tabItems: [PlayerPaneTabBar<Tab>.Item] {
        typealias Item = PlayerPaneTabBar<Tab>.Item
        var items: [Item] = []
        if player.currentListeningSpace == .podcast {
            // 播客:节目说明在前;章节只在单集带章节时有;「接下来」是队列里后面的单集。
            if offersNotes {
                items.append(Item(value: .notes, title: String(localized: "podcast_player_notes_short")))
            }
            if player.hasChapters || !offersNotes {
                items.append(Item(value: .contents, title: String(localized: "podcast_chapters")))
            }
            if textTab != nil {
                items.append(Item(value: .text, title: String(localized: "spoken_word_text_tab")))
            }
            items.append(Item(value: .bookmarks, title: bookmarksTabTitle))
            items.append(Item(value: .upNext, title: String(localized: "podcast_player_up_next_short")))
        } else {
            items.append(Item(value: .contents, title: String(localized: "spoken_word_contents_title")))
            items.append(Item(value: .bookmarks, title: bookmarksTabTitle))
            if textTab != nil {
                items.append(Item(value: .text, title: String(localized: "spoken_word_text_tab")))
            }
        }
        return items
    }

    /// 书先看目录;播客有章节时先看章节,没有就是节目说明。
    private var defaultTab: Tab {
        offersNotes && !player.hasChapters ? .notes : .contents
    }

    private func applyRequestedTab() {
        guard let requested = requestedTab.wrappedValue else { return }
        tab = tabItems.contains { $0.value == requested } ? requested : defaultTab
        requestedTab.wrappedValue = nil
    }

    @ViewBuilder
    private var notesPage: some View {
        if notesBlocks.isEmpty {
            Text("podcast_player_notes_empty")
                .font(.footnote)
                .foregroundStyle(palette?.secondary ?? .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                PodcastShowNotesView(blocks: notesBlocks) { seconds in
                    player.seek(to: seconds, startPlaying: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var notesSongID: String? {
        guard offersNotes, let song = player.currentSong else { return nil }
        if PodcastPlaybackSong.isEpisode(song) {
            return PodcastStore.shared.episode(id: song.id)?.episode.id
        }
        return song.id
    }

    /// 播客单集的节目说明;单集没有章节时面板一打开就是这一页,点里面的时间跳过去。
    private func loadPodcastNotes() async {
        notesBlocks = []
        guard let song = player.currentSong, song.id == notesSongID else { return }
        let notes: String?
        if PodcastPlaybackSong.isEpisode(song) {
            notes = PodcastStore.shared.episode(id: song.id)?.episode.showNotes
        } else {
            notes = await player.sourceManager?.serverPodcastNotes(for: song)
        }
        guard !Task.isCancelled, let notes, !notes.isEmpty else { return }
        let blocks = await Task.detached(priority: .userInitiated) {
            PodcastShowNotes.blocks(from: notes)
        }.value
        guard !Task.isCancelled, player.currentSong?.id == song.id else { return }
        notesBlocks = blocks
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

    /// 目录页单独成一个视图、按值比较输入：播放页每重排一次(Mac 上拖窗口宽度时每一步都是)
    /// 外面这一层就跟着重建,几百章的目录要是一起重建、整份比对,拖一下卡一下(#350)。
    /// 有回调时照常每次重建 —— 回调可能换了,比较里不看它。
    @ViewBuilder
    private var contentsPage: some View {
        let list = SpokenWordContentsList(palette: palette, isSheet: isSheet, onOpen: onOpen)
        if onOpen == nil {
            list.equatable()
        } else {
            list
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
                    .foregroundStyle(palette?.accent ?? spokenContentsSheetAccent)
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

/// 弹出的目录面板(没有播放页配色时)的强调色: Mac 上跟品牌色, 系统的强调色在 Mac 上是另一种颜色。
@MainActor
private var spokenContentsSheetAccent: Color {
    #if os(macOS)
    PMColor.brand
    #else
    Color.accentColor
    #endif
}

/// 正在听的这本书的目录,见 `SpokenWordContentsView.contentsPage`。
private struct SpokenWordContentsList: View, Equatable {
    let palette: SpokenWordPlayerPalette?
    let isSheet: Bool
    let onOpen: (() -> Void)?

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    private var store: SpokenWordStore { SpokenWordStore.shared }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.palette == rhs.palette && lhs.isSheet == rhs.isSheet
    }

    var body: some View {
        // Reading these registers the list with the store, so progress and
        // finished marks refresh while the list is open.
        _ = store.positions.count
        _ = store.finishedAt.count
        let rows = player.spokenWordContentsRows()
        let initial = SpokenWordContentsPolicy.initialRowIndex(
            in: rows,
            resumeItemID: player.currentSpokenWordBook?.resumeItemID
        )
        return VStack(alignment: .leading, spacing: 0) {
            if let summary = bookSummaryLine {
                Text(verbatim: summary)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(palette?.secondary ?? Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            ScrollViewReader { proxy in
                List {
                    ForEach(rows) { row in
                        Button {
                            player.openSpokenWordContentsRow(row)
                            onOpen?()
                            if isSheet { dismiss() }
                        } label: {
                            SpokenWordContentsRowView(
                                row: row,
                                palette: palette,
                                isRepeating: player.isRepeatingSpokenWordRow(row)
                            )
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
    }

    /// "全书 9% · 已听完 11/120 · 剩约 58 小时" above the list.
    private var bookSummaryLine: String? {
        guard player.currentItemIsAudiobook, let book = player.currentSpokenWordBook else { return nil }
        var parts: [String] = []
        if let summary = player.spokenWordNowPlayingSummary(live: false), summary.partCount != nil {
            parts.append(SpokenWordPlayerText.bookFraction(summary.bookFraction))
        }
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
        let tint = palette?.accent ?? spokenContentsSheetAccent
        return (row.isCurrent ? tint.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func rowMenu(_ row: SpokenWordContentsRow) -> some View {
        if player.currentItemIsAudiobook {
            let repeating = player.isRepeatingSpokenWordRow(row)
            Button {
                player.repeatSpokenWordContentsRow(row)
                if !repeating {
                    onOpen?()
                    if isSheet { dismiss() }
                }
            } label: {
                Label(
                    String(localized: repeating
                        ? "spoken_word_repeat_chapter_stop"
                        : "spoken_word_repeat_chapter_play"),
                    systemImage: "repeat.1"
                )
            }
        }
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
}

/// One contents row: number, title, length or where the listener is, and
/// a mark for finished / in progress.
struct SpokenWordContentsRowView: View {
    let row: SpokenWordContentsRow
    var palette: SpokenWordPlayerPalette?
    var isRepeating = false

    private var primary: Color { palette?.primary ?? .primary }
    private var secondary: Color { palette?.secondary ?? .secondary }
    private var tertiary: Color { palette?.tertiary ?? Color.secondary.opacity(0.75) }
    private var accent: Color { palette?.accent ?? spokenContentsSheetAccent }

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

            if isRepeating {
                Image(systemName: "repeat.1")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
                    .accessibilityLabel(Text("spoken_word_repeat_chapter"))
            }

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
                .foregroundStyle(palette?.accent ?? spokenContentsSheetAccent)
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
