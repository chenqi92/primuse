import SwiftUI
import PrimuseKit

/// 歌单里一首「曲库里还没有」的歌。置灰显示在它原来的位置上；规则只够得上「可能是」时
/// 给出候选让用户一键确认，也可以自己在曲库里找。曲库里出现能对上的歌时会自动点亮，
/// 这一行随之变回普通歌曲行。
struct PlaylistPendingEntryRow: View {
    @Environment(MusicLibrary.self) private var library
    let entry: PlaylistPendingEntry
    let playlistID: String
    /// 镜像/文件夹歌单不允许手动改成员。
    let allowsEditing: Bool

    @State private var showMatchSheet = false

    private var suggestion: Song? {
        entry.suggestedSongID.flatMap { library.visibleSong(id: $0) }
    }

    private var detailLine: String {
        [entry.artistLine, entry.album ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !detailLine.isEmpty {
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let suggestion {
                    Text(verbatim: String(
                        format: String(localized: "playlist_pending_suggestion_format"),
                        [suggestion.title, library.artistDisplayName(for: suggestion) ?? ""]
                            .filter { !$0.isEmpty }
                            .joined(separator: " — ")
                    ))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                } else {
                    Text(statusKey)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if allowsEditing {
                if let suggestion {
                    Button {
                        library.resolvePendingEntry(entry.id, inPlaylist: playlistID, with: suggestion.id)
                    } label: {
                        Text("playlist_pending_confirm")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Menu {
                    Button {
                        showMatchSheet = true
                    } label: {
                        Label("playlist_pending_find", systemImage: "magnifyingglass")
                    }
                    Button(role: .destructive) {
                        library.remove(songID: entry.id, fromPlaylist: playlistID)
                    } label: {
                        Label("remove_from_playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel(Text("more"))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityHint(Text("playlist_pending_accessibility_hint"))
        .sheet(isPresented: $showMatchSheet) {
            PlaylistPendingMatchSheet(entry: entry, playlistID: playlistID)
        }
    }

    private var statusKey: LocalizedStringKey {
        entry.origin == "removed-source" ? "playlist_pending_status_removed_source" : "playlist_pending_status"
    }
}

/// 自己在曲库里给一首置灰的歌挑对应的歌曲。
struct PlaylistPendingMatchSheet: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let entry: PlaylistPendingEntry
    let playlistID: String

    @State private var query: String

    init(entry: PlaylistPendingEntry, playlistID: String) {
        self.entry = entry
        self.playlistID = playlistID
        _query = State(initialValue: entry.title)
    }

    private var results: [Song] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return Array(
            library.visibleSongs.lazy.filter { song in
                [song.title, song.artistName ?? "", song.albumTitle ?? ""]
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                    .contains(needle)
            }
            .prefix(60)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.subheadline.weight(.semibold))
                        if !entry.artistLine.isEmpty {
                            Text(entry.artistLine).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if results.isEmpty {
                        Text("playlist_pending_no_results")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { song in
                        Button {
                            library.resolvePendingEntry(entry.id, inPlaylist: playlistID, with: song.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).foregroundStyle(.primary)
                                Text(
                                    [library.artistDisplayName(for: song), song.albumTitle]
                                        .compactMap { $0 }
                                        .joined(separator: " · ")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("playlist_pending_match_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
    }
}

/// 歌单顶部的一句说明：有几首置灰、它们什么时候会亮。
struct PlaylistPendingNotice: View {
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: String(format: String(localized: "playlist_pending_notice_format"), count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}
