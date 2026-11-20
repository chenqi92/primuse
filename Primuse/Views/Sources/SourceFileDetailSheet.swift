import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 文件页里点开一个音频文件:是哪首歌、能做什么、在哪儿。
/// 改名、删除直接动音乐源上的文件,做完曲库跟着更新。
struct SourceFileDetailSheet: View {
    let source: MusicSource
    let file: SourceFileBrowserPolicy.AudioFile
    let songs: [Song]
    /// 同一层里已入库的歌,点「播放」从这首接着往下。
    let folderQueue: [Song]
    let isInScanScope: Bool
    /// 这个源能不能挪文件(本机、WebDAV、SMB、群晖、SFTP)。
    let canMove: Bool
    let onChanged: () -> Void
    let onDeleted: (String) -> Void
    let onScanFolder: (() -> Void)?
    /// 挪走了:参数是目标文件夹的名字。
    let onMoved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(ScanService.self) private var scanService

    /// 改过名之后这一页显示的是改名后的歌和文件名。
    @State private var displayedSong: Song?
    @State private var displayedName: String
    @State private var canRename = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showsRenamePrompt = false
    @State private var showsDeleteConfirmation = false
    @State private var isWorking = false
    @State private var showsTagEditor = false
    @State private var errorMessage: String?
    @State private var unavailableReason: String?
    @State private var showsMovePicker = false
    @State private var toasts = PMToastPresenter()

    init(
        source: MusicSource,
        file: SourceFileBrowserPolicy.AudioFile,
        songs: [Song],
        folderQueue: [Song],
        isInScanScope: Bool,
        canMove: Bool,
        onChanged: @escaping () -> Void,
        onDeleted: @escaping (String) -> Void,
        onScanFolder: (() -> Void)?,
        onMoved: @escaping (String) -> Void
    ) {
        self.source = source
        self.file = file
        self.songs = songs
        self.folderQueue = folderQueue
        self.isInScanScope = isInScanScope
        self.canMove = canMove
        self.onChanged = onChanged
        self.onDeleted = onDeleted
        self.onScanFolder = onScanFolder
        self.onMoved = onMoved
        _displayedSong = State(initialValue: songs.first)
        _displayedName = State(initialValue: file.entry.name)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SourceFileSummary(file: file, song: displayedSong, name: displayedName, songCount: songs.count)
                }
                .listRowSeparator(.hidden)

                actionSection
                libraryStateSection
                infoSection

                Section {
                    Button(role: .destructive) {
                        requestDelete()
                    } label: {
                        Label("source_file_delete", systemImage: "trash")
                            .foregroundStyle(source.type.supportsFileDeletion ? Color.red : Color.secondary)
                    }
                    .disabled(isWorking)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(displayedName)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
        .task(id: displayedSong?.filePath) {
            guard let song = displayedSong, songs.count == 1 else {
                canRename = false
                return
            }
            canRename = await sourceManager.canRenameSongFile(song)
        }
        .alert("source_file_rename_title", isPresented: $showsRenamePrompt) {
            TextField("source_file_rename_placeholder", text: $renameText)
            Button("cancel", role: .cancel) {}
            Button("playlist_rename") { rename(to: renameText) }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("source_file_rename_message")
        }
        .confirmationDialog(
            String(format: String(localized: "source_file_delete_title_format"), displayedName),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) { deleteFile() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert(
            "source_file_action_failed",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "source_file_unavailable_title",
            isPresented: Binding(get: { unavailableReason != nil }, set: { if !$0 { unavailableReason = nil } })
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(unavailableReason ?? "")
        }
        .sheet(isPresented: $showsMovePicker) {
            SourceFolderPickerSheet(
                source: source,
                itemName: displayedName,
                canPick: { destination in
                    let parent = ((displayedSong?.filePath ?? file.entry.path) as NSString).deletingLastPathComponent
                    return !SourceDirectorySelectionPolicy.isSamePath(parent.isEmpty ? "/" : parent, destination.path)
                },
                onPick: { destination in move(into: destination) }
            )
        }
        .sheet(isPresented: $showsTagEditor) {
            if let song = displayedSong {
                TagEditorView(song: library.song(id: song.id) ?? song, onSave: { saved in
                    displayedSong = saved
                    displayedName = (saved.filePath as NSString).lastPathComponent
                    onChanged()
                })
            }
        }
        .pmToastHost(toasts)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    // MARK: 区块

    private var actionSection: some View {
        Section {
            HStack(spacing: 10) {
                SourceFileActionButton(title: "play", systemImage: "play.fill", isEnabled: displayedSong != nil) {
                    if displayedSong != nil { play() } else { explainNotInLibrary() }
                }
                SourceFileActionButton(title: "tag_editor_menu", systemImage: "tag", isEnabled: displayedSong != nil) {
                    if displayedSong != nil { showsTagEditor = true } else { explainNotInLibrary() }
                }
                SourceFileActionButton(title: "playlist_rename", systemImage: "character.cursor.ibeam", isEnabled: canRename) {
                    requestRename()
                }
                if canMove {
                    let isCueAudio = songs.count > 1 || displayedSong?.isCueTrack == true
                    SourceFileActionButton(title: "source_move_short", systemImage: "folder", isEnabled: !isCueAudio) {
                        if isCueAudio {
                            unavailableReason = String(localized: "source_move_error_cue")
                        } else {
                            showsMovePicker = true
                        }
                    }
                }
            }
            .buttonStyle(.borderless)
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        }
    }

    @ViewBuilder
    private var libraryStateSection: some View {
        Section {
            if let song = displayedSong {
                Label {
                    Text(songs.count > 1
                         ? String(format: String(localized: "source_file_in_library_count_format"), songs.count)
                         : String(localized: "source_file_in_library"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if song.sourceID != AppleMusicLibraryService.systemSourceID {
                    SongOfflineActionButtons(
                        song: song,
                        snapshot: sourceManager.offlineAudioSnapshotEntry(for: song).snapshot
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("source_files_not_in_library", systemImage: "circle.dashed")
                        .foregroundStyle(.orange)
                    Text(notInLibraryHintKey)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isInScanScope, let onScanFolder {
                    Button {
                        onScanFolder()
                        dismiss()
                    } label: {
                        Label("folder_scan_incremental", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var infoSection: some View {
        Section {
            if let lyrics = file.lyrics.first {
                SourceFileInfoRow(title: String(localized: "lyrics_word"), value: lyrics.name)
            }
            if let cover = file.cover {
                SourceFileInfoRow(title: String(localized: "cover"), value: cover.name)
            }
            if source.type.itemPathsCarryFileNames {
                SourceFileInfoRow(title: String(localized: "source_file_path"), value: displayedSong?.filePath ?? file.entry.path)
                    .contextMenu {
                        Button { copy(displayedSong?.filePath ?? file.entry.path) } label: {
                            Label("source_files_copy_path", systemImage: "doc.on.doc")
                        }
                    }
            }
            if let modified = file.entry.modifiedDate {
                SourceFileInfoRow(
                    title: String(localized: "source_file_modified"),
                    value: modified.formatted(date: .abbreviated, time: .shortened)
                )
            }
        }
    }

    private var deleteMessage: String {
        if songs.count > 1 {
            return String(
                format: String(localized: "source_file_delete_message_tracks_format"),
                songs.count, source.name
            )
        }
        return String(format: String(localized: "source_file_delete_message_format"), source.name)
    }

    // MARK: 动作

    private var notInLibraryHintKey: LocalizedStringKey {
        isInScanScope ? "source_file_not_in_library_hint" : "source_file_outside_scope_hint"
    }

    private func explainNotInLibrary() {
        if isInScanScope {
            unavailableReason = String(localized: "source_file_not_in_library_hint")
        } else {
            unavailableReason = String(localized: "source_file_outside_scope_hint")
        }
    }

    private func play() {
        guard let song = displayedSong else { return }
        let queue = folderQueue.isEmpty ? [song] : folderQueue
        let start = queue.firstIndex { $0.id == song.id } ?? 0
        Task { await player.play(queue: queue, startingAt: start) }
    }

    private func requestRename() {
        guard displayedSong != nil else {
            explainNotInLibrary()
            return
        }
        guard canRename else {
            if songs.count > 1 {
                unavailableReason = String(localized: "song_file_rename_cue")
            } else {
                unavailableReason = String(localized: "song_file_rename_unsupported")
            }
            return
        }
        renameText = SourceFileBrowserPolicy.stem(of: displayedName)
        showsRenamePrompt = true
    }

    private func rename(to stem: String, isUndo: Bool = false) {
        guard let song = displayedSong else { return }
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldStem = SourceFileBrowserPolicy.stem(of: displayedName)
        guard !trimmed.isEmpty, trimmed != oldStem else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let result = try await sourceManager.renameSongFile(song, stem: trimmed)
                library.replaceSong(result.song)
                applyRenamed(result.song)
                if let notice = result.notice { errorMessage = notice }
                if !isUndo {
                    toasts.show(PMToastItem(
                        key: "source-file-renamed",
                        message: String(localized: "source_file_renamed"),
                        systemImage: "checkmark.circle.fill",
                        tint: .green,
                        duration: 6,
                        action: PMToastItem.Action(title: String(localized: "undo")) {
                            rename(to: oldStem, isUndo: true)
                        }
                    ))
                }
            } catch SongFileRenameError.partial(let result, let message) {
                library.replaceSong(result.song)
                applyRenamed(result.song)
                errorMessage = message
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyRenamed(_ song: Song) {
        displayedSong = song
        displayedName = (song.filePath as NSString).lastPathComponent
        onChanged()
    }

    private func move(into destination: SourceFolderLocation) {
        let operations = SourceFolderOperations(
            sourceManager: sourceManager, scanService: scanService, library: library,
            sourcesStore: sourcesStore, player: player
        )
        let currentSongs = songs.map { library.song(id: $0.id) ?? $0 }
        let path = displayedSong?.filePath ?? file.entry.path
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                _ = try await operations.move(file: path, songs: currentSongs, in: source, into: destination.path)
                onMoved(destination.title)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func requestDelete() {
        guard source.type.supportsFileDeletion else {
            unavailableReason = String(localized: "source_file_delete_unsupported")
            return
        }
        showsDeleteConfirmation = true
    }

    private func deleteFile() {
        let name = displayedName
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            if songs.isEmpty {
                do {
                    try await sourceManager.connector(for: source).deleteFile(at: file.entry.path)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            } else {
                let current = songs.map { library.song(id: $0.id) ?? $0 }
                if let playing = player.currentSong, current.contains(where: { $0.id == playing.id }) {
                    await player.next()
                }
                let primary = current[0]
                let retained = library.songs.filter {
                    $0.sourceID != primary.sourceID || $0.filePath != primary.filePath
                }
                let result = await sourceManager.deleteSourceFilesAndCaches(
                    for: primary,
                    deleteSidecars: sourceManager.shouldDeleteSidecars(for: primary, retaining: retained)
                )
                guard result.shouldRemoveLibraryRecord else {
                    let detail = result.failedPaths.first?.message
                    errorMessage = [String(localized: "delete_song_failed_message"), detail]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    return
                }
                for other in current.dropFirst() {
                    sourceManager.deleteLocalCaches(for: other)
                }
                let remaining = library.deleteSongs(current, sourceFileDeleted: true)
                for (sourceID, count) in remaining {
                    sourcesStore.updateLocal(sourceID) { $0.songCount = count }
                }
            }
            onDeleted(name)
            dismiss()
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        toasts.show(PMToastItem(
            key: "source-file-copy",
            message: String(localized: "source_files_path_copied"),
            systemImage: "doc.on.doc",
            tint: .secondary
        ))
    }
}

// MARK: - 零件

/// 顶上:封面(没入库时是格式方块)、标题、艺人与专辑、几枚规格标签。
private struct SourceFileSummary: View {
    let file: SourceFileBrowserPolicy.AudioFile
    let song: Song?
    let name: String
    let songCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                if let song {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: 64,
                        cornerRadius: 12,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                    .frame(width: 64, height: 64)
                } else {
                    SourceFormatTile(file: file, size: 64)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(song?.title ?? SourceFileBrowserPolicy.stem(of: name))
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String? {
        guard let song else { return nil }
        let parts = [song.artistName, song.albumTitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var chips: [String] {
        var chips = [(name as NSString).pathExtension.uppercased()]
        if let song, let quality = SourceFileQualityText.make(for: song) { chips.append(quality) }
        if file.entry.size > 0 {
            chips.append(SourceByteText.string(file.entry.size))
        }
        if songCount > 1 {
            chips.append(String(format: String(localized: "source_files_cue_songs_format"), songCount))
        } else if let song, song.duration > 0 {
            chips.append(song.duration.formattedDuration)
        }
        return chips.filter { !$0.isEmpty }
    }
}

/// 三个并排的方块按钮。不可用时画淡,但仍可点 —— 点了说为什么。
private struct SourceFileActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(height: 26)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .background(
                (isEnabled ? Color.accentColor : Color.secondary).opacity(0.1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct SourceFileInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
