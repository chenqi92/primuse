import PrimuseKit
import SwiftUI

/// The chapter marks and the bookmarks of the item that is playing, as a
/// jump list. Chapters come from the file; bookmarks are the listener's own.
/// The entry point is hidden when neither exists, so there is no empty state
/// for the whole sheet — only for a tab that happens to be empty.
struct ChapterListView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable { case chapters, bookmarks }

    @State private var tab: Tab?

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private var bookmarks: [SpokenWordBookmark] {
        _ = store.revision
        guard let songID = player.currentSong?.id else { return [] }
        return store.bookmarks(forSongID: songID)
    }

    private var selectedTab: Tab {
        tab ?? (player.hasChapters ? .chapters : .bookmarks)
    }

    var body: some View {
        NavigationStack {
            List {
                if player.hasChapters {
                    Section {
                        Picker(selection: Binding(get: { selectedTab }, set: { tab = $0 })) {
                            Text("chapters_title").tag(Tab.chapters)
                            Text("spoken_word_bookmarks_title").tag(Tab.bookmarks)
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                switch selectedTab {
                case .chapters:
                    ForEach(Array(player.spokenWordChapters.enumerated()), id: \.offset) { index, chapter in
                        Button {
                            player.seekToChapter(at: index)
                            dismiss()
                        } label: {
                            ChapterRow(
                                chapter: chapter,
                                number: index + 1,
                                isCurrent: index == player.currentChapterIndex
                            )
                        }
                        .buttonStyle(.plain)
                        // buttonStyle(.plain) only reacts to the shape of its
                        // content, so the row's padding would be dead space.
                        .contentShape(Rectangle())
                    }
                case .bookmarks:
                    if bookmarks.isEmpty {
                        Text("spoken_word_bookmarks_empty")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(bookmarks) { bookmark in
                        Button {
                            player.seekToSpokenWordBookmark(bookmark)
                            dismiss()
                        } label: {
                            BookmarkRow(bookmark: bookmark)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeBookmark(id: bookmark.id, songID: bookmark.songID)
                            } label: {
                                Label(String(localized: "spoken_word_delete_bookmark"), systemImage: "trash")
                            }
                        }
                        #if os(iOS)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.removeBookmark(id: bookmark.id, songID: bookmark.songID)
                            } label: {
                                Label(String(localized: "spoken_word_delete_bookmark"), systemImage: "trash")
                            }
                        }
                        #endif
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(selectedTab == .chapters
                ? String(localized: "chapters_title")
                : String(localized: "spoken_word_bookmarks_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
                if player.currentItemIsSpokenWord {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            player.addSpokenWordBookmark()
                            tab = .bookmarks
                        } label: {
                            Label(String(localized: "spoken_word_add_bookmark"), systemImage: "bookmark.fill")
                        }
                    }
                }
            }
        }
    }
}

private struct BookmarkRow: View {
    let bookmark: SpokenWordBookmark

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bookmark.fill")
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .font(.body)
                    .lineLimit(2)
                Text(ChapterTimeFormatter.string(from: bookmark.position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ChapterRow: View {
    let chapter: MediaChapter
    let number: Int
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(minWidth: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(2)
                Text(ChapterTimeFormatter.string(from: chapter.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
