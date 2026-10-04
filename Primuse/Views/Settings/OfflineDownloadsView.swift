import PrimuseKit
import SwiftUI

/// 一次「移除离线下载」要做的事。歌还被开着「始终保持离线」的歌单保持着时,
/// 单独删掉会被马上重新下载, 所以连那些歌单的开关一起关掉。
struct OfflineDownloadRemovalRequest: Identifiable {
    let id = UUID()
    let songs: [Song]
    let byteCount: Int64
    /// 要一并关掉「始终保持离线」的歌单。
    let playlistIDs: Set<String>

    static func make(
        for items: [SourceManager.OfflineDownloadItem],
        enabledPlaylistIDs: Set<String>
    ) -> OfflineDownloadRemovalRequest {
        OfflineDownloadRemovalRequest(
            songs: items.map(\.song),
            byteCount: items.reduce(0) { $0 + $1.byteCount },
            playlistIDs: items.reduce(into: Set<String>()) { owners, item in
                owners.formUnion(item.playlistIDs.intersection(enabledPlaylistIDs))
            }
        )
    }

    @MainActor
    func perform(sourceManager: SourceManager) {
        for playlistID in playlistIDs {
            AppServices.shared.alwaysDownload.setEnabled(false, for: playlistID)
        }
        sourceManager.removeOfflineDownloads(songs)
    }
}

/// 存储管理里的「离线下载」: 单独存放、不计入缓存上限的那些歌, 可以逐首或多选移除。
struct OfflineDownloadsView: View {
    /// Mac 上以表单弹出, 需要自己的「完成」按钮。
    var showsDoneButton = false

    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var items: [SourceManager.OfflineDownloadItem] = []
    @State private var hasLoaded = false
    @State private var selection = Set<String>()
    @State private var pendingRemoval: OfflineDownloadRemovalRequest?
    @State private var reloadTask: Task<Void, Never>?
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        content
            .navigationTitle("offline_downloads")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            #if os(macOS)
            .safeAreaInset(edge: .bottom) { macActionBar }
            #endif
            .task { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: .primuseAudioCacheFilesDidChange)) { _ in
                scheduleReload()
            }
            .onDisappear { reloadTask?.cancel() }
            .confirmationDialog(
                pendingRemoval.map(confirmationTitle) ?? "",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { request in
                Button(
                    request.playlistIDs.isEmpty
                        ? String(localized: "offline_downloads_remove")
                        : String(localized: "offline_downloads_owned_confirm"),
                    role: .destructive
                ) {
                    perform(request)
                }
                Button("cancel", role: .cancel) {}
            } message: { request in
                Text(verbatim: confirmationMessage(request))
            }
            #if os(iOS)
            // 放在最外层: 工具栏里的「编辑」按钮和列表都要读到同一个编辑状态。
            .environment(\.editMode, $editMode)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            EmptyStateView(
                titleKey: "offline_downloads_empty",
                descriptionKey: "offline_downloads_empty_hint",
                systemImage: "arrow.down.circle"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                Section {
                    ForEach(items) { item in
                        row(item)
                            .tag(item.id)
                            #if os(iOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    requestRemoval([item], confirmsPlainRemoval: false)
                                } label: {
                                    Label("offline_downloads_remove", systemImage: "trash")
                                }
                            }
                            #endif
                            .contextMenu {
                                Button(role: .destructive) {
                                    requestRemoval([item], confirmsPlainRemoval: false)
                                } label: {
                                    Label("offline_downloads_remove", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(verbatim: Self.summaryText(
                        songCount: items.count,
                        byteCount: items.reduce(0) { $0 + $1.byteCount }
                    ))
                } footer: {
                    Text("offline_downloads_footer")
                }
            }
        }
    }

    private func row(_ item: SourceManager.OfflineDownloadItem) -> some View {
        HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: item.song.coverArtFileName,
                songID: item.song.id,
                size: 40,
                cornerRadius: 6,
                sourceID: item.song.sourceID,
                filePath: item.song.filePath,
                fileFormat: item.song.fileFormat
            )
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.song.title)
                    .lineLimit(1)
                if let artist = item.song.artistName, !artist.isEmpty {
                    Text(verbatim: artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let owners = ownerNames(item) {
                    Label(
                        String(format: String(localized: "offline_downloads_kept_by_format"), owners),
                        systemImage: "pin.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.byteCount > 0 {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        if !items.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        if editMode.isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("offline_downloads_remove_all", role: .destructive) {
                    requestRemoval(items, confirmsPlainRemoval: true)
                }
                Spacer()
                Button(role: .destructive) {
                    requestRemoval(selectedItems, confirmsPlainRemoval: true)
                } label: {
                    Text(verbatim: removeSelectedTitle)
                }
                .disabled(selection.isEmpty)
            }
        }
        #else
        if showsDoneButton {
            ToolbarItem(placement: .confirmationAction) {
                Button("done") { dismiss() }
            }
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var macActionBar: some View {
        if !items.isEmpty {
            HStack {
                Button("offline_downloads_remove_all", role: .destructive) {
                    requestRemoval(items, confirmsPlainRemoval: true)
                }
                Spacer()
                Button(role: .destructive) {
                    requestRemoval(selectedItems, confirmsPlainRemoval: true)
                } label: {
                    Text(verbatim: removeSelectedTitle)
                }
                .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
    #endif

    private var selectedItems: [SourceManager.OfflineDownloadItem] {
        items.filter { selection.contains($0.id) }
    }

    private var removeSelectedTitle: String {
        String(format: String(localized: "offline_downloads_remove_selected_format"), selection.count)
    }

    /// 只显示还开着「始终保持离线」的歌单: 刚关掉的那些在下一轮对账前还挂在记录上。
    private func ownerNames(_ item: SourceManager.OfflineDownloadItem) -> String? {
        let enabled = AppServices.shared.alwaysDownload.enabledPlaylistIDs
        let names = item.playlistIDs
            .intersection(enabled)
            .compactMap { library.playlist(id: $0)?.name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: names)
    }

    private func requestRemoval(
        _ targets: [SourceManager.OfflineDownloadItem],
        confirmsPlainRemoval: Bool
    ) {
        guard !targets.isEmpty else { return }
        let request = OfflineDownloadRemovalRequest.make(
            for: targets,
            enabledPlaylistIDs: AppServices.shared.alwaysDownload.enabledPlaylistIDs
        )
        if request.playlistIDs.isEmpty && !confirmsPlainRemoval {
            perform(request)
        } else {
            pendingRemoval = request
        }
    }

    private func perform(_ request: OfflineDownloadRemovalRequest) {
        request.perform(sourceManager: sourceManager)
        let removed = Set(request.songs.map(\.id))
        pmWithAnimation(.list) {
            items.removeAll { removed.contains($0.id) }
            selection.subtract(removed)
        }
        #if os(iOS)
        if items.isEmpty { editMode = .inactive }
        #endif
        // 关掉的歌单里其他歌要等下一轮对账才转为普通缓存, 稍后再刷新一次。
        scheduleReload(after: .seconds(1))
    }

    private func confirmationTitle(_ request: OfflineDownloadRemovalRequest) -> String {
        request.playlistIDs.isEmpty
            ? String(format: String(localized: "offline_downloads_remove_confirm_title_format"), request.songs.count)
            : String(localized: "offline_downloads_owned_title")
    }

    private func confirmationMessage(_ request: OfflineDownloadRemovalRequest) -> String {
        guard !request.playlistIDs.isEmpty else {
            return String(
                format: String(localized: "offline_downloads_remove_confirm_message_format"),
                ByteCountFormatter.string(fromByteCount: request.byteCount, countStyle: .file)
            )
        }
        let names = request.playlistIDs
            .compactMap { library.playlist(id: $0)?.name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return String(
            format: String(localized: "offline_downloads_owned_message_format"),
            ListFormatter.localizedString(byJoining: names)
        )
    }

    private func scheduleReload(after delay: Duration = .milliseconds(500)) {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func reload() async {
        let loaded = await sourceManager.offlineDownloadItems(in: library.songs)
        guard !Task.isCancelled else { return }
        items = loaded
        selection.formIntersection(Set(loaded.map(\.id)))
        hasLoaded = true
    }

    static func summaryText(songCount: Int, byteCount: Int64) -> String {
        String(
            format: String(localized: "offline_downloads_summary_format"),
            songCount,
            ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        )
    }
}
