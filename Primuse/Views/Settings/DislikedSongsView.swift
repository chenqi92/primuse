import PrimuseKit
import SwiftUI

/// 「不喜欢的歌曲」清单(#193):看标过哪些,撤销点错的。iPhone 从「设置 › 播放」进,
/// Mac 从设置「播放」页的「管理」以弹窗打开。这里撤销等于在歌曲菜单里点「取消不喜欢」。
struct DislikedSongsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// Mac 以弹窗打开时给一个「完成」。
    var showsDoneButton = false

    var body: some View {
        let songs = library.dislikedSongs
        List {
            if !songs.isEmpty {
                Section {
                    ForEach(songs) { song in
                        DislikedSongRow(
                            song: song,
                            artistName: library.artistDisplayName(for: song) ?? song.artistName
                        ) {
                            library.setDisliked(songID: song.id, isDisliked: false)
                        }
                    }
                } footer: {
                    Text("disliked_songs_footer")
                }
            }
        }
        .overlay {
            if songs.isEmpty {
                ContentUnavailableView {
                    Label("disliked_songs_empty", systemImage: "hand.thumbsdown")
                } description: {
                    Text("disliked_songs_footer")
                }
            }
        }
        .navigationTitle("playlist_disliked_name")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
    }
}

private struct DislikedSongRow: View {
    let song: Song
    let artistName: String?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 40,
                cornerRadius: 6,
                sourceID: song.sourceID,
                filePath: song.filePath
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: song.title)
                    .lineLimit(1)
                if let artistName, !artistName.isEmpty {
                    Text(verbatim: artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Text("song_undislike")
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: String(localized: "song_undislike") + " " + song.title))
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(action: onRemove) {
                Label(String(localized: "song_undislike"), systemImage: "arrow.uturn.backward")
            }
            .tint(.accentColor)
        }
    }
}

/// 「设置 › 播放」里的入口:不喜欢了几首,点进去看清单。
struct DislikedSongsSettingsSection: View {
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        Section {
            NavigationLink {
                DislikedSongsView()
            } label: {
                LabeledContent {
                    Text(verbatim: "\(library.dislikedSongs.count)")
                        .monospacedDigit()
                } label: {
                    Label("playlist_disliked_name", systemImage: "hand.thumbsdown")
                }
            }
        } footer: {
            Text("disliked_songs_footer")
        }
    }
}
