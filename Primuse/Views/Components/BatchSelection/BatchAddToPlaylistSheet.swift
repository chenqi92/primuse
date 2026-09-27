import SwiftUI
import PrimuseKit

/// 把一批歌一次性加进某个歌单。选已有歌单，或者直接输名字新建一个。
///
/// macOS 侧沿用原先「歌曲页 → 加入歌单…」那张表单的视觉，iOS 侧是等价的
/// List 版；两端都是「先选目标、再确认」，避免误触一下就把几百首歌灌进去。
struct BatchAddToPlaylistSheet: View {
    let songs: [Song]
    /// 加入成功后回调，供调用方顺势退出选择模式。
    var onFinish: () -> Void = {}

    @Environment(MusicLibrary.self) private var library
    // 可选: 与 AddToPlaylistSheet 一样, 独立宿主里未必注入。
    @Environment(SourcesStore.self) private var sourcesStore: SourcesStore?
    @Environment(SourceManager.self) private var sourceManager: SourceManager?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlaylistID: String?
    @State private var newPlaylistName = ""
    @State private var isAppending = false
    @State private var appendErrorMessage: String?

    /// 镜像歌单 (Apple Music / 服务端曲库) 会在下次同步时覆盖，不能作为写入
    /// 目标。「我喜欢」仍是本地可编辑歌单，批量加入与逐曲点心形使用同一份成员关系。
    private var targetPlaylists: [Playlist] {
        library.playlists.filter {
            $0.allowsManualSongMembership
        }
    }

    /// 这批歌都来自同一台 Subsonic 系服务器时, 也能加进它上面的歌单(#162)。
    private var serverPlaylists: [Playlist] {
        guard let sourcesStore, sourceManager != nil else { return [] }
        return ServerPlaylistAppendService.targets(for: songs, library: library, sourcesStore: sourcesStore)
    }

    private var serverSectionTitle: String {
        sourcesStore.flatMap { ServerPlaylistAppendService.source(for: songs, sourcesStore: $0)?.name }
            ?? String(localized: "playlist_kind_server_mirror")
    }

    private var appendErrorBinding: Binding<Bool> {
        Binding(
            get: { appendErrorMessage != nil },
            set: { if !$0 { appendErrorMessage = nil } }
        )
    }

    private var trimmedNewName: String {
        newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCommit: Bool {
        !isAppending && (selectedPlaylistID != nil || !trimmedNewName.isEmpty)
    }

    private var songCountText: String {
        String(format: String(localized: "batch_selected_count_format"), songs.count)
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    private func commit() {
        if let selectedPlaylistID, ServerPlaylistIdentity.isMirrorPlaylist(selectedPlaylistID) {
            commitToServerPlaylist(selectedPlaylistID)
            return
        }
        let targetID: String
        if let selectedPlaylistID {
            targetID = selectedPlaylistID
        } else {
            guard !trimmedNewName.isEmpty else { return }
            targetID = library.createPlaylist(name: trimmedNewName).id
        }
        library.add(songIDs: songs.map(\.id), toPlaylist: targetID)
        onFinish()
        dismiss()
    }

    /// 服务端歌单要等服务器确认才算加上, 失败就留在这张表上说明原因。
    private func commitToServerPlaylist(_ playlistID: String) {
        guard !isAppending, let sourcesStore, let sourceManager else { return }
        isAppending = true
        Task { @MainActor in
            defer { isAppending = false }
            do {
                try await ServerPlaylistAppendService.append(
                    songs,
                    toMirrorPlaylist: playlistID,
                    library: library,
                    sourcesStore: sourcesStore,
                    sourceManager: sourceManager
                )
                onFinish()
                dismiss()
            } catch is CancellationError {
            } catch {
                appendErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - iOS

    #if !os(macOS)
    private var iosBody: some View {
        NavigationStack {
            List {
                Section {
                    TextField("playlist_name", text: $newPlaylistName)
                        .onChange(of: newPlaylistName) { _, newValue in
                            // 开始输新名字就取消已选的歌单，两个目标同时高亮
                            // 会让人不确定到底会加进哪个。
                            if !newValue.isEmpty { selectedPlaylistID = nil }
                        }
                } header: {
                    Text("new_playlist")
                }

                Section {
                    if targetPlaylists.isEmpty {
                        ContentUnavailableView {
                            Label(String(localized: "no_playlists"), systemImage: "music.note.list")
                        }
                    } else {
                        ForEach(targetPlaylists) { playlist in
                            Button {
                                selectedPlaylistID = playlist.id
                                newPlaylistName = ""
                            } label: {
                                iosPlaylistRow(playlist)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(playlist.id == MusicLibrary.likedSongsPlaylistID
                                ? "batchPlaylistTarget.liked"
                                : "batchPlaylistTarget.\(playlist.id)")
                        }
                    }
                } header: {
                    Text("playlists_title")
                }

                if !serverPlaylists.isEmpty {
                    Section {
                        ForEach(serverPlaylists) { playlist in
                            Button {
                                selectedPlaylistID = playlist.id
                                newPlaylistName = ""
                            } label: {
                                iosPlaylistRow(playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(verbatim: serverSectionTitle)
                    } footer: {
                        Text("server_playlist_append_footer")
                    }
                }
            }
            .floatingInputPanelClearance()
            .navigationTitle(Text("add_to_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("add_to_playlist")
                            .font(.headline)
                        Text(verbatim: songCountText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isAppending {
                        ProgressView()
                    } else {
                        Button("add", action: commit)
                            .fontWeight(.semibold)
                            .disabled(!canCommit)
                    }
                }
            }
            .alert(String(localized: "server_playlist_append_failed_title"), isPresented: appendErrorBinding) {
                Button(String(localized: "ok"), role: .cancel) {}
            } message: {
                Text(verbatim: appendErrorMessage ?? "")
            }
        }
    }

    private func iosPlaylistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            Image(systemName: playlist.id == MusicLibrary.likedSongsPlaylistID
                ? "heart.fill"
                : "music.note.list")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: playlist.name)
                    .lineLimit(1)
                Text(verbatim: String(
                    format: String(localized: "carplay_playlist_song_count_format"),
                    library.songCount(forPlaylist: playlist.id)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if selectedPlaylistID == playlist.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
    #endif

    // MARK: - macOS

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 34, height: 34)
                    .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("add_to_playlist")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: songCountText)
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                PMRoundBtn(icon: "xmark", size: 26, iconSize: 11, style: .glass,
                           help: "cancel") { dismiss() }
            }
            .padding(18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if targetPlaylists.isEmpty {
                        Text("playlist_picker_empty_hint")
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
                    } else {
                        ForEach(targetPlaylists) { playlist in
                            macPlaylistRow(playlist)
                        }
                    }

                    if !serverPlaylists.isEmpty {
                        Text(verbatim: serverSectionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                            .padding(.top, 4)
                        ForEach(serverPlaylists) { playlist in
                            macPlaylistRow(playlist)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("new_playlist")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                        TextField("playlist_name", text: $newPlaylistName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(PMColor.bgElev, in: .rect(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                            }
                            .onChange(of: newPlaylistName) { _, newValue in
                                if !newValue.isEmpty { selectedPlaylistID = nil }
                            }
                    }
                }
                .padding(18)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Spacer()
                Button("cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                Button("add", action: commit)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(canCommit ? PMColor.brand : PMColor.textFaint, in: .rect(cornerRadius: 6))
                    .disabled(!canCommit)
            }
            .padding(18)
        }
        .frame(width: 420, height: 520)
        .background(PMColor.bg)
        .alert(String(localized: "server_playlist_append_failed_title"), isPresented: appendErrorBinding) {
            Button(String(localized: "ok"), role: .cancel) {}
        } message: {
            Text(verbatim: appendErrorMessage ?? "")
        }
    }

    private func macPlaylistRow(_ playlist: Playlist) -> some View {
        let isSelected = selectedPlaylistID == playlist.id
        return Button {
            selectedPlaylistID = playlist.id
            newPlaylistName = ""
        } label: {
            HStack(spacing: 10) {
                PlaylistArtworkView(playlist: playlist, size: 34, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: playlist.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(verbatim: String(
                        format: String(localized: "carplay_playlist_song_count_format"),
                        library.songCount(forPlaylist: playlist.id)
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(10)
            .background(isSelected ? PMColor.brand.opacity(0.12) : PMColor.bgElev,
                        in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? PMColor.brand.opacity(0.6) : PMColor.cardBorder,
                                  lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
    #endif
}
