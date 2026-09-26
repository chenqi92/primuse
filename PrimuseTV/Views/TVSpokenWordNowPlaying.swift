#if os(tvOS)
import SwiftUI
import PrimuseKit

// MARK: - 文案

/// 电视播放页上关于这本书的几行字:书名、正在听的一条、演播者、第几章、还剩多久。
/// 规则与 iPhone / Mac 的 `SpokenWordPlayerText` 一致,只是数据来自 `TVStore`。
@MainActor
enum TVSpokenWordText {
    static func bookTitle(_ store: TVStore) -> String {
        if let title = store.currentSpokenWordBook?.title, !title.isEmpty { return title }
        let np = store.nowPlaying
        return np.album.isEmpty ? np.title : np.album
    }

    static func author(_ store: TVStore) -> String? {
        if let author = store.currentSpokenWordBook?.author, !author.isEmpty { return author }
        let artist = store.nowPlaying.artist
        return artist.isEmpty ? nil : artist
    }

    /// 正在听的这一章:单文件的书是章节标记的标题,多文件的书是文件标题(带章节标记时跟在后面)。
    /// 只会重复书名时不显示。
    static func partTitle(_ store: TVStore) -> String? {
        let isOneFileBook = (store.currentSpokenWordBook?.items.count ?? 1) <= 1
        let chapterTitle = store.currentSpokenWordChapter?.title
        if isOneFileBook, let chapterTitle, !chapterTitle.isEmpty { return chapterTitle }
        var title = store.nowPlaying.title
        if let chapterTitle, !chapterTitle.isEmpty, chapterTitle != title {
            title += " · " + chapterTitle
        }
        return title.isEmpty || title == bookTitle(store) ? nil : title
    }

    static func partPosition(_ store: TVStore) -> String? {
        guard let summary = store.spokenWordNowPlayingSummary,
              let index = summary.partIndex,
              let count = summary.partCount else { return nil }
        return String(format: String(localized: "spoken_word_part_position_format"), index, count)
    }

    static func approximateDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else {
            return String(localized: "spoken_word_under_a_minute")
        }
        return TVSpokenWordBooks.duration((seconds / 60).rounded() * 60)
    }

    /// 「本章还剩约 18 分钟」,按这本书的语速折算。
    static func partRemaining(_ store: TVStore) -> String? {
        guard let content = store.spokenWordPartRemaining else { return nil }
        let remaining = SpokenWordNowPlayingPolicy.listeningTime(
            forContent: content,
            rate: store.currentSpokenWordRate
        )
        return String(
            format: String(localized: "spoken_word_part_remaining_format"),
            approximateDuration(remaining)
        )
    }

    static func sleepLabel(_ store: TVStore) -> String {
        if store.sleepStopAfterChapter != nil { return String(localized: "spoken_word_sleep_chapter_short") }
        if store.sleepStopAfterItemID != nil { return String(localized: "spoken_word_sleep_item_short") }
        if store.sleepStopAfterBookID != nil { return String(localized: "spoken_word_sleep_book_short") }
        return String(localized: "spoken_word_sleep_short")
    }
}

// MARK: - 全书进度与书签刻度

/// 进度条下面那一行:全书百分比、细条、全书还剩多久。
struct TVSpokenWordBookProgressRow: View {
    @Environment(TVStore.self) private var store

    var body: some View {
        if let summary = store.spokenWordNowPlayingSummary,
           summary.partCount != nil || summary.bookRemaining != nil {
            HStack(spacing: 18) {
                Text(String(
                    format: String(localized: "spoken_word_book_fraction_format"),
                    Int((min(1, max(0, summary.bookFraction)) * 100).rounded(.down))
                ))
                .fixedSize()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(TVColor.divider)
                        Capsule().fill(TVColor.textMuted)
                            .frame(width: max(4, geo.size.width * summary.bookFraction))
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
                if let remaining = summary.bookRemaining {
                    Text(String(
                        format: String(localized: "spoken_word_book_remaining_format"),
                        TVSpokenWordText.approximateDuration(SpokenWordNowPlayingPolicy.listeningTime(
                            forContent: remaining,
                            rate: store.currentSpokenWordRate
                        ))
                    ))
                    .fixedSize()
                }
            }
            .tvFont(.meta)
            .monospacedDigit()
            .foregroundStyle(TVColor.textFaint)
            .accessibilityElement(children: .combine)
        }
    }
}

/// 进度条上这一条的书签位置。
struct TVSpokenWordBookmarkTicks: View {
    @Environment(TVStore.self) private var store

    var body: some View {
        let songID = store.nowPlaying.songID
        let fractions = SpokenWordNowPlayingPolicy.bookmarkFractions(
            SpokenWordStore.shared.bookmarks(forSongID: songID),
            duration: store.duration
        )
        GeometryReader { geo in
            ForEach(Array(fractions.enumerated()), id: \.offset) { _, fraction in
                Capsule()
                    .fill(TVColor.text.opacity(0.85))
                    .frame(width: 4, height: 16)
                    .position(x: 16 + (geo.size.width - 32) * fraction, y: geo.size.height / 2 - 12)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 右栏:目录与书签

/// 播放页右栏:这本书的目录,切到「书签」看整本书的书签。选一条就从那里播。
/// 目录列这本书的各个文件;正在播的文件带章节标记时列在它下面,单文件的书直接列标记。
struct TVSpokenWordContentsColumn: View {
    @Environment(TVStore.self) private var store
    var onInteraction: () -> Void = {}

    private enum Tab: Hashable { case contents, bookmarks }
    @State private var tab: Tab = .contents
    @State private var bookmarkFeedback = 0

    var body: some View {
        let spokenStore = SpokenWordStore.shared
        // 读这几张表,位置 / 听完 / 书签一变右栏就跟着刷新。
        _ = spokenStore.positions.count
        _ = spokenStore.finishedAt.count
        _ = spokenStore.bookmarks.count
        let entries = store.currentBookBookmarkEntries
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                TVPillButton(
                    title: String(localized: "spoken_word_contents_title"),
                    systemImage: "list.bullet",
                    style: tab == .contents ? .solid : .glass,
                    isSelected: tab == .contents
                ) {
                    onInteraction()
                    tab = .contents
                }
                TVPillButton(
                    title: entries.isEmpty
                        ? String(localized: "spoken_word_bookmarks_title")
                        : String(format: String(localized: "spoken_word_bookmarks_count_format"), entries.count),
                    systemImage: "bookmark",
                    style: tab == .bookmarks ? .solid : .glass,
                    isSelected: tab == .bookmarks
                ) {
                    onInteraction()
                    tab = .bookmarks
                }
                Spacer(minLength: 0)
            }
            .focusSection()

            switch tab {
            case .contents:
                contentsList
            case .bookmarks:
                bookmarksList(entries)
            }
        }
    }

    private var contentsList: some View {
        let rows = store.spokenWordContentsRows()
        let initial = SpokenWordContentsPolicy.initialRowIndex(
            in: rows,
            resumeItemID: store.currentSpokenWordBook?.resumeItemID
        )
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        contentsRow(row).id(row.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .focusSection()
            .onAppear {
                guard let initial, rows.indices.contains(initial) else { return }
                proxy.scrollTo(rows[initial].id, anchor: .center)
            }
        }
    }

    private func contentsRow(_ row: SpokenWordContentsRow) -> some View {
        TVFocusButton(radius: 16, scale: 1.02, lift: 0, ring: false, action: {
            onInteraction()
            store.openSpokenWordContentsRow(row)
        }) { focused in
            HStack(spacing: 22) {
                Text(verbatim: "\(row.number)")
                    .tvFont(.caption, design: .monospaced)
                    .foregroundStyle(row.isCurrent ? TVColor.spokenWordSpace : TVColor.textFaint)
                    .frame(width: 64, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title.isEmpty ? " " : row.title)
                        .tvFont(.rowTitle)
                        .foregroundStyle(row.state == .finished ? TVColor.textFaint : TVColor.text)
                        .lineLimit(1)
                    if let meta = meta(for: row) {
                        Text(meta)
                            .tvFont(.meta, design: .monospaced)
                            .foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                stateMark(row.state)
                    .frame(width: 30, height: 30)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: row.isNested ? 72 : 84)
            .background(
                focused ? TVColor.surfaceStrong
                    : (row.isCurrent ? TVColor.spokenWordSpace.opacity(0.16) : TVColor.card),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        // 文件自己的章节标记缩进排在它下面。
        .padding(.leading, row.isNested ? 56 : 0)
        .accessibilityElement(children: .combine)
    }

    private func meta(for row: SpokenWordContentsRow) -> String? {
        switch row.state {
        case let .current(fraction), let .inProgress(fraction):
            guard let duration = row.duration, duration > 0 else { return nil }
            let heard = duration * fraction
            return String(
                format: String(localized: "spoken_word_contents_position_format"),
                TVFmt.time(heard),
                TVFmt.time(max(0, duration - heard))
            )
        case .finished:
            return String(localized: "spoken_word_finished")
        case .unplayed:
            return row.duration.map { TVFmt.time($0) }
        }
    }

    @ViewBuilder
    private func stateMark(_ state: SpokenWordContentsRow.State) -> some View {
        switch state {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(TVColor.textFaint)
        case let .current(fraction), let .inProgress(fraction):
            ZStack {
                Circle().stroke(TVColor.divider, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(TVColor.spokenWordSpace, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        case .unplayed:
            Color.clear
        }
    }

    private func bookmarksList(_ entries: [SpokenWordBookBookmarkPolicy.Entry]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                TVPillButton(
                    title: String(localized: "spoken_word_add_bookmark"),
                    systemImage: "bookmark.fill"
                ) {
                    onInteraction()
                    if store.addSpokenWordBookmark() { bookmarkFeedback += 1 }
                }
                .padding(.bottom, 8)

                if entries.isEmpty {
                    Text(String(localized: "spoken_word_bookmarks_empty"))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                        .padding(.horizontal, 6)
                }
                ForEach(entries) { entry in
                    bookmarkRow(entry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .focusSection()
    }

    private func bookmarkRow(_ entry: SpokenWordBookBookmarkPolicy.Entry) -> some View {
        TVFocusButton(radius: 16, scale: 1.02, lift: 0, ring: false, action: {
            onInteraction()
            store.playSpokenWordBookmark(entry.bookmark)
        }) { focused in
            HStack(spacing: 22) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(TVColor.spokenWordSpace)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.bookmark.title).tvFont(.rowTitle).foregroundStyle(TVColor.text).lineLimit(1)
                    Text(whereText(entry)).tvFont(.meta, design: .monospaced).foregroundStyle(TVColor.textFaint)
                }
                Spacer(minLength: 12)
                Text(entry.bookmark.createdAt, format: .dateTime.month().day().hour().minute())
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 84)
            .background(focused ? TVColor.surfaceStrong : TVColor.card,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button(role: .destructive) {
                SpokenWordStore.shared.removeBookmark(id: entry.bookmark.id, songID: entry.bookmark.songID)
            } label: {
                Label(String(localized: "spoken_word_delete_bookmark"), systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func whereText(_ entry: SpokenWordBookBookmarkPolicy.Entry) -> String {
        let time = TVFmt.time(entry.bookmark.position)
        guard let part = entry.partNumber else { return time }
        return String(format: String(localized: "spoken_word_bookmark_where_format"), part, time)
    }
}

// MARK: - 语速与睡眠定时的选择面板

/// 居中卡片里的一列选项(电视弹框的统一写法)。
private struct TVSpokenWordChoicePanel<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: () -> Content
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let colors = store.nowPlayingPresentationColors
        ZStack {
            TVAmbientBackdrop(tint: colors.primary, tint2: colors.secondary, strength: 0.5)
            TVColor.bg.opacity(0.52).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                Text(title).tvFont(.sectionTitle).foregroundStyle(TVColor.text)
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .focusSection()
                if let footnote {
                    Text(footnote).tvFont(.caption).foregroundStyle(TVColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(40)
            .frame(width: 720, alignment: .leading)
            .tvPanel(radius: 24)
        }
        .onExitCommand { dismiss() }
    }
}

private struct TVSpokenWordChoiceRow: View {
    let title: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.03, lift: 0, ring: false, action: action) { focused in
            HStack {
                Text(title).tvFont(.rowTitle)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
            }
            .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
            .padding(.horizontal, 26)
            .frame(height: 72)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surfaceStrong),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 这本书的语速。按书记,和 iPhone / Mac 通过 iCloud 同一份。
struct TVSpokenWordRatePicker: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TVSpokenWordChoicePanel(
            title: String(localized: "spoken_word_book_speed"),
            footnote: store.canChangeSpokenWordRate ? nil : String(localized: "tv_spoken_word_rate_unavailable")
        ) {
            ForEach(SpokenWordPlaybackRatePolicy.presets, id: \.self) { rate in
                TVSpokenWordChoiceRow(
                    title: SpokenWordPlaybackRatePolicy.label(for: rate),
                    isSelected: abs(store.currentSpokenWordRate - rate) < 0.001
                ) {
                    store.setSpokenWordRateForCurrentBook(rate)
                    dismiss()
                }
                .disabled(!store.canChangeSpokenWordRate)
            }
        }
    }
}

/// 听书的睡眠定时:分钟数,或者这一集 / 这一整本听完再停。
struct TVSpokenWordSleepPicker: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TVSpokenWordChoicePanel(title: String(localized: "sleep_timer")) {
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                TVSpokenWordChoiceRow(
                    title: "\(minutes) " + String(localized: "minutes"),
                    isSelected: store.sleepTimerMinutes == minutes
                ) {
                    store.setSleepTimer(minutes: minutes)
                    dismiss()
                }
            }
            if !store.spokenWordChapters.isEmpty {
                TVSpokenWordChoiceRow(
                    title: String(localized: "sleep_at_chapter_end"),
                    isSelected: store.sleepStopAfterChapter != nil
                ) {
                    store.scheduleSleepAtSpokenWordChapterEnd()
                    dismiss()
                }
            }
            TVSpokenWordChoiceRow(
                title: String(localized: "sleep_at_item_end"),
                isSelected: store.sleepStopAfterItemID != nil
            ) {
                store.scheduleSleepAtSpokenWordItemEnd()
                dismiss()
            }
            TVSpokenWordChoiceRow(
                title: String(localized: "sleep_at_book_end"),
                isSelected: store.sleepStopAfterBookID != nil
            ) {
                store.scheduleSleepAtSpokenWordBookEnd()
                dismiss()
            }
            if store.isSleepTimerActive {
                TVSpokenWordChoiceRow(title: String(localized: "cancel_timer")) {
                    store.cancelSleepTimer()
                    dismiss()
                }
            }
        }
    }
}
#endif
