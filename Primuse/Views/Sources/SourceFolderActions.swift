import SwiftUI
import PrimuseKit

// MARK: - 执行

/// 文件页上对一个目录的改名与删除。先动音乐源上的目录,再让曲库、扫描索引、播放队列、
/// 本机缓存跟上:改名后歌曲 ID 不变(播放记录、歌单都还在),删除后这些歌从曲库移除。
@MainActor
struct SourceFolderOperations {
    let sourceManager: SourceManager
    let scanService: ScanService
    let library: MusicLibrary
    let sourcesStore: SourcesStore
    let player: AudioPlayerService

    /// 改名,返回新路径。
    func rename(folder path: String, in source: MusicSource, to rawName: String) async throws -> String {
        guard let name = SourceFolderRelocationPolicy.validatedFolderName(rawName) else {
            throw SourceFolderMutationError.invalidName
        }
        guard !SourceFolderRelocationPolicy.touchesScanRoots(
            path, selections: source.scannedDirectories, sourceType: source.type
        ) else {
            throw SourceFolderMutationError.containsScanRoots
        }
        let newPath = SourceFolderRelocationPolicy.siblingPath(of: path, named: name)
        guard SourceFolderRelocationPolicy.relocatedPath(newPath, from: path, to: path) == nil else {
            return path
        }
        let connector = sourceManager.connector(for: source)
        guard await connector.canMutateDirectories() else { throw SourceFolderMutationError.unsupported }

        // 正在放的就在这个目录里:先停在原处,改完接着放新路径上的同一首。
        var resumePlayback: ((Song) -> Void)?
        var playing: Song?
        if let current = player.currentSong, current.sourceID == source.id,
           SourceFolderRelocationPolicy.relocatedPath(current.filePath, from: path, to: newPath) != nil {
            do {
                resumePlayback = try player.prepareForSourceFileRename(current)
            } catch {
                throw SourceFolderMutationError.playbackBusy
            }
            playing = current
        }

        do {
            try await scanService.prepareForFileRename(sourceID: source.id)
            try await connector.renameDirectory(at: path, to: newPath)
        } catch {
            if let playing { resumePlayback?(playing) }
            throw error
        }
        plog("📁 Folder renamed source=\(source.id.prefix(8))…")
        let moved: [Song]
        do {
            moved = try await scanService.recordFolderRelocation(
                sourceID: source.id, from: path, to: newPath, in: library
            )
        } catch {
            // 音乐源上已经改好了,曲库没跟上:下次扫描会按新路径重新认。
            plog("⚠️ Folder relocation not recorded: \(error.localizedDescription)")
            if let playing { resumePlayback?(playing) }
            throw error
        }
        player.applySourceFolderRelocation(moved)
        if let playing {
            resumePlayback?(moved.first { $0.id == playing.id } ?? playing)
        }
        // 目录上打的「有声」标签跟着走。
        let tags = SpokenWordStore.shared
        if tags.isSpokenWordFolder(sourceID: source.id, path: path) {
            tags.setSpokenWordFolder(true, sourceID: source.id, path: newPath)
            tags.setSpokenWordFolder(false, sourceID: source.id, path: path)
        }
        return newPath
    }

    /// 删除整个目录,返回从曲库移除了几首。
    func delete(folder path: String, in source: MusicSource) async throws -> Int {
        let connector = sourceManager.connector(for: source)
        guard await connector.canMutateDirectories() else { throw SourceFolderMutationError.unsupported }
        let songs = songs(under: path, in: source)
        if let current = player.currentSong, songs.contains(where: { $0.id == current.id }) {
            await player.next()
        }
        try await scanService.prepareForFileRename(sourceID: source.id)
        try await connector.deleteDirectory(at: path)
        plog("📁 Folder deleted source=\(source.id.prefix(8))… songs=\(songs.count)")
        if !songs.isEmpty {
            let remaining = library.deleteSongs(songs, sourceFileDeleted: true)
            for (sourceID, count) in remaining {
                sourcesStore.updateLocal(sourceID) { $0.songCount = count }
            }
        }
        // 删的就是扫描目录(或者里面有):从勾选里拿掉,免得下次扫描找不到它。
        if let current = sourcesStore.source(id: source.id) {
            let selections = current.scannedDirectories
            let kept = selections.filter { !SourceDirectorySelectionPolicy.covers(path, $0, for: current.type) }
            if kept.count != selections.count {
                sourcesStore.update(current.id) {
                    $0.extraConfig = MusicSource.encodeScannedDirectories(kept, into: $0.extraConfig, type: $0.type)
                }
            }
        }
        return songs.count
    }

    /// 删除前给用户看的影响。
    func deletionImpact(folder path: String, in source: MusicSource) -> SourceFolderDeletionImpact {
        let songs = songs(under: path, in: source)
        let ids = Set(songs.map(\.id))
        let offline = songs.filter {
            sourceManager.offlineAudioSnapshotEntry(for: $0).state == .pinned
        }.count
        let playlists = ids.isEmpty ? 0 : library.playlists.filter { playlist in
            !playlist.isDeleted && library.songIDs(forPlaylist: playlist.id).contains(where: ids.contains)
        }.count
        return SourceFolderDeletionImpact(
            songCount: songs.count,
            offlineCount: offline,
            playlistCount: playlists,
            isScanRoot: SourceFolderRelocationPolicy.touchesScanRoots(
                path, selections: source.scannedDirectories, sourceType: source.type
            )
        )
    }

    private func songs(under path: String, in source: MusicSource) -> [Song] {
        library.songs.filter {
            $0.sourceID == source.id
                && SourceFolderRelocationPolicy.relocatedPath($0.filePath, from: path, to: path) != nil
        }
    }
}

struct SourceFolderDeletionImpact: Equatable {
    var songCount: Int
    var offlineCount: Int
    var playlistCount: Int
    var isScanRoot: Bool
}

extension AudioPlayerService {
    /// 目录改名后,队列里这个目录的歌换成新路径;正在放的那首由改名前后的暂停与续播处理。
    func applySourceFolderRelocation(_ relocated: [Song]) {
        guard !relocated.isEmpty else { return }
        let byID = Dictionary(relocated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in queueEntries.indices {
            guard let updated = byID[queueEntries[index].song.id] else { continue }
            queueEntries[index].song.filePath = updated.filePath
            queueEntries[index].song.lyricsFileName = updated.lyricsFileName
            queueEntries[index].song.coverArtFileName = updated.coverArtFileName
            queueEntries[index].song.mvPath = updated.mvPath
            queueEntries[index].song.cueSheetPath = updated.cueSheetPath
        }
    }
}

// MARK: - 界面

enum SourceFolderAction: Equatable {
    case rename(SourceFolderLocation)
    case delete(SourceFolderLocation)
}

/// 文件页上目录的改名框、删除确认,以及做完之后的提示。
struct SourceFolderActionsModifier: ViewModifier {
    let source: MusicSource
    @Binding var action: SourceFolderAction?
    /// 做完了:页面重新列目录、重建入库索引,并说一句结果。
    let onFinished: (String) -> Void

    @Environment(SourceManager.self) private var sourceManager
    @Environment(ScanService.self) private var scanService
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(AudioPlayerService.self) private var player

    @State private var renameTarget: SourceFolderLocation?
    @State private var renameText = ""
    @State private var deleteTarget: SourceFolderLocation?
    @State private var errorMessage: String?

    private var operations: SourceFolderOperations {
        SourceFolderOperations(
            sourceManager: sourceManager,
            scanService: scanService,
            library: library,
            sourcesStore: sourcesStore,
            player: player
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: action) { _, newValue in
                guard let newValue else { return }
                switch newValue {
                case .rename(let folder):
                    renameText = folder.title
                    renameTarget = folder
                case .delete(let folder):
                    deleteTarget = folder
                }
                action = nil
            }
            .alert(
                "source_folder_rename_title",
                isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
            ) {
                TextField("source_file_rename_placeholder", text: $renameText)
                Button("cancel", role: .cancel) { renameTarget = nil }
                Button("playlist_rename") { rename() }
                    .disabled(SourceFolderRelocationPolicy.validatedFolderName(renameText) == nil)
            } message: {
                Text("source_folder_rename_message")
            }
            .sheet(item: $deleteTarget) { folder in
                SourceFolderDeleteSheet(
                    source: source,
                    folder: folder,
                    impact: operations.deletionImpact(folder: folder.path, in: currentSource),
                    perform: { try await operations.delete(folder: folder.path, in: currentSource) },
                    onDeleted: {
                        onFinished(String(format: String(localized: "source_file_deleted_format"), folder.title))
                    }
                )
            }
            .alert(
                "source_file_action_failed",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var currentSource: MusicSource {
        sourcesStore.source(id: source.id) ?? source
    }

    private func rename() {
        guard let folder = renameTarget else { return }
        let name = renameText
        renameTarget = nil
        Task { @MainActor in
            do {
                _ = try await operations.rename(folder: folder.path, in: currentSource, to: name)
                onFinished(String(localized: "source_folder_renamed"))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension View {
    func sourceFolderActions(
        source: MusicSource,
        action: Binding<SourceFolderAction?>,
        onFinished: @escaping (String) -> Void
    ) -> some View {
        modifier(SourceFolderActionsModifier(source: source, action: action, onFinished: onFinished))
    }
}

/// 删除目录前的确认页:列出会发生什么,再要求把文件夹名照着输一遍。
private struct SourceFolderDeleteSheet: View {
    let source: MusicSource
    let folder: SourceFolderLocation
    let impact: SourceFolderDeletionImpact
    let perform: () async throws -> Int
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "trash")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(width: 56, height: 56)
                            .background(Color.red.opacity(0.12), in: Circle())
                            .accessibilityHidden(true)
                        Text(String(format: String(localized: "source_folder_delete_title_format"), folder.title))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(String(format: String(localized: "source_folder_delete_message_format"), source.name))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowSeparator(.hidden)

                Section {
                    SourceFolderImpactRow(
                        systemImage: "music.note.list",
                        text: String(format: String(localized: "source_folder_delete_impact_songs_format"), impact.songCount)
                    )
                    if impact.offlineCount > 0 {
                        SourceFolderImpactRow(
                            systemImage: "arrow.down.circle",
                            text: String(format: String(localized: "source_folder_delete_impact_offline_format"), impact.offlineCount)
                        )
                    }
                    if impact.playlistCount > 0 {
                        SourceFolderImpactRow(
                            systemImage: "text.badge.minus",
                            text: String(format: String(localized: "source_folder_delete_impact_playlists_format"), impact.playlistCount)
                        )
                    }
                    if impact.isScanRoot {
                        SourceFolderImpactRow(
                            systemImage: "scope",
                            text: String(localized: "source_folder_delete_impact_scan_root")
                        )
                    }
                }

                Section {
                    TextField(folder.title, text: $typedName)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text(String(format: String(localized: "source_folder_delete_prompt_format"), folder.title))
                        .textCase(nil)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        delete()
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text("source_folder_delete_action").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canDelete)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private var canDelete: Bool {
        !isDeleting && typedName.trimmingCharacters(in: .whitespacesAndNewlines) == folder.title
    }

    private func delete() {
        guard canDelete else { return }
        isDeleting = true
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await perform()
                onDeleted()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isDeleting = false
            }
        }
    }
}

private struct SourceFolderImpactRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
    }
}
