import SwiftUI
import PrimuseKit

/// 批量操作栏的上下文。决定哪些动作对当前页面有意义。
struct SongBatchActionContext {
    /// 非 nil 时多出「从该歌单移除」。
    var playlistID: String?
    /// Apple Music 镜像歌单里的条目移除后下次 sync 又会回来，视觉上就是
    /// "删了又出现"，所以整页不给移除入口。
    var allowsRemoveFromPlaylist = true
    var allowsLibraryRemoval = true
    var allowsSourceFileDeletion = true

    static let library = SongBatchActionContext()
    static let readOnly = SongBatchActionContext(
        allowsRemoveFromPlaylist: false,
        allowsLibraryRemoval: false,
        allowsSourceFileDeletion: false
    )

    static func playlist(id: String, allowsRemoval: Bool) -> Self {
        SongBatchActionContext(playlistID: id, allowsRemoveFromPlaylist: allowsRemoval)
    }
}

extension View {
    /// 给一个歌曲列表页挂上批量操作栏（以及它的表单和确认弹窗）。
    ///
    /// 弹窗宿主是页面而不是操作栏本身 —— 操作栏会随 `selection.deactivate()`
    /// 一起消失，挂在它上面的 sheet 会被半路掐断。
    ///
    /// - Parameters:
    ///   - orderedIDs: 列表当前顺序，用于全选和还原选中项的顺序。
    ///   - resolve: ID → Song。性能敏感的页面传自己的免观察查找。
    func songBatchActions(
        selection: SongSelectionModel,
        context: SongBatchActionContext = .library,
        orderedIDs: @escaping () -> [String],
        resolve: @escaping (String) -> Song?
    ) -> some View {
        modifier(SongBatchActionsModifier(
            selection: selection,
            context: context,
            orderedIDs: orderedIDs,
            resolve: resolve
        ))
    }
}

private struct SongBatchActionsModifier: ViewModifier {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(SongBatchRemovalService.self) private var removal
    #if os(iOS)
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    let selection: SongSelectionModel
    let context: SongBatchActionContext
    let orderedIDs: () -> [String]
    let resolve: (String) -> Song?

    @State private var showAddToPlaylist = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var showNoDeletableSourceAlert = false
    @State private var showNoScraperSourceAlert = false

    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let mode: SongBatchRemovalService.Mode
        let songs: [Song]
        let skipped: Int
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                actionBar
                    .padding(.bottom, actionBarBottomClearance)
                    .opacity(selection.isActive ? 1 : 0)
                    .offset(y: selection.isActive ? 0 : 12)
                    .allowsHitTesting(selection.isActive)
                    .accessibilityHidden(!selection.isActive)
            }
            .animation(.snappy(duration: 0.22), value: selection.isActive)
            .sheet(isPresented: $showAddToPlaylist) {
                BatchAddToPlaylistSheet(songs: selectedSongs()) {
                    selection.deactivate()
                }
                #if !os(macOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
            }
            .alert(
                deletionAlertTitle,
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { pending in
                Button("cancel", role: .cancel) {}
                Button("delete", role: .destructive) { performDeletion(pending) }
            } message: { pending in
                Text(verbatim: deletionMessage(pending))
            }
            .alert("batch_delete_source_files", isPresented: $showNoDeletableSourceAlert) {
                Button("done", role: .cancel) {}
            } message: {
                Text("batch_delete_no_deletable_source")
            }
            .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
    }

    // MARK: - Bar

    private var actionBarBottomClearance: CGFloat {
        #if os(iOS)
        guard player.currentSong != nil || appleMusic.nowPlayingSong != nil else {
            return 0
        }
        // The legacy mini player is an outer ContentView overlay, so a page-
        // local safe-area inset otherwise lands underneath it and cannot be
        // tapped. iOS 26.1's native tab accessory already contributes its own
        // safe area; regular-width layouts continue to use the legacy overlay.
        if horizontalSizeClass == .regular { return 68 }
        if #available(iOS 26.1, *) { return 0 }
        return 52
        #else
        return 0
        #endif
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            Button {
                selection.deactivate()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: .circle)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("done"))

            Text(verbatim: String(
                format: String(localized: "batch_selected_count_format"),
                selection.count
            ))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)

            Spacer(minLength: 4)

            Button("batch_select_all") {
                selection.selectAll(orderedIDs())
            }
            .font(.subheadline)
            #endif

            Button {
                showAddToPlaylist = true
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(selection.isEmpty)
            .accessibilityLabel(Text("add_to_playlist"))

            Button {
                player.appendToQueue(playableSelection())
            } label: {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(selection.isEmpty)
            .accessibilityLabel(Text("add_to_queue"))

            Button {
                player.insertNextInQueue(playableSelection())
            } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(selection.isEmpty)
            .accessibilityLabel(Text("insert_next"))

            Menu {
                moreActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            #if os(macOS)
            // Mac 上系统 Menu 默认自带箭头和一大片按钮底，跟这条自绘的条子
            // 不搭；iOS 的默认样式本来就是干净的图标按钮。
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
            .disabled(selection.isEmpty)
            .accessibilityLabel(Text("a11y_more_actions"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private var moreActions: some View {
        Section {
            Button {
                player.appendToQueue(playableSelection())
            } label: {
                Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }

            Button {
                player.insertNextInQueue(playableSelection())
            } label: {
                Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }

        Section {
            Button {
                sourceManager.downloadForOffline(songs: playableSelection())
            } label: {
                Label("offline_download", systemImage: "arrow.down.circle")
            }

            Button {
                startScrape()
            } label: {
                Label("scrape_missing_metadata", systemImage: "wand.and.stars")
            }
            .disabled(scraperService.isScraping)

            #if os(macOS)
            Button {
                selection.clear()
            } label: {
                Label("batch_deselect_all", systemImage: "circle.dashed")
            }
            #endif
        }

        if let playlistID = context.playlistID, context.allowsRemoveFromPlaylist {
            Section {
                Button(role: .destructive) {
                    library.remove(songIDs: Array(selection.selectedIDs), fromPlaylist: playlistID)
                    selection.deactivate()
                } label: {
                    Label("remove_from_playlist", systemImage: "minus.circle")
                }
            }
        }

        if context.allowsLibraryRemoval && !selectionContainsAppleMusic {
            Section {
                Button(role: .destructive) {
                    prepareDeletion(mode: .libraryOnly)
                } label: {
                    Label("batch_remove_from_library", systemImage: "trash")
                }
                .disabled(removal.isBusy)
            }
        }

        if context.allowsSourceFileDeletion && hasDeletableSourceSelection {
            Section {
                Button(role: .destructive) {
                    prepareDeletion(mode: .sourceFiles)
                } label: {
                    Label("batch_delete_source_files", systemImage: "trash.slash")
                }
                .disabled(removal.isBusy)
            }
        }
    }

    // MARK: - Actions

    private func selectedSongs() -> [Song] {
        selection.orderedSongs(in: orderedIDs(), resolve: resolve)
    }

    private func playableSelection() -> [Song] {
        selectedSongs().filteredPlayable()
    }

    private var selectionContainsAppleMusic: Bool {
        selectedSongs().contains {
            $0.sourceID == AppleMusicLibraryIdentity.sourceID
        }
    }

    private var hasDeletableSourceSelection: Bool {
        let typesByID = Dictionary(
            sourcesStore.allSources.map { ($0.id, $0.type) },
            uniquingKeysWith: { current, _ in current }
        )
        return selectedSongs().contains {
            SourceFileDeletionPolicy.shouldShowDeleteAction(for: typesByID[$0.sourceID])
        }
    }

    private func startScrape() {
        let songs = selectedSongs()
        guard !songs.isEmpty else { return }
        guard scraperSettings.hasEnabledSource else {
            showNoScraperSourceAlert = true
            return
        }
        scraperService.scrapeMissingMetadata(songs: songs, in: library)
        selection.deactivate()
    }

    private func prepareDeletion(mode: SongBatchRemovalService.Mode) {
        guard !removal.isBusy else { return }
        let songs = selectedSongs()
        guard !songs.isEmpty else { return }

        switch mode {
        case .libraryOnly:
            pendingDeletion = PendingDeletion(mode: mode, songs: songs, skipped: 0)
        case .sourceFiles:
            let typesByID = Dictionary(
                sourcesStore.allSources.map { ($0.id, $0.type) },
                uniquingKeysWith: { current, _ in current }
            )
            let partition = SongBatchRemovalService.partitionForSourceDeletion(
                songs,
                sourceTypesByID: typesByID
            )
            guard !partition.deletable.isEmpty else {
                showNoDeletableSourceAlert = true
                return
            }
            pendingDeletion = PendingDeletion(
                mode: mode,
                songs: partition.deletable,
                skipped: partition.skipped.count
            )
        }
    }

    private func performDeletion(_ pending: PendingDeletion) {
        guard removal.remove(pending.songs, mode: pending.mode, skipped: pending.skipped) != nil else {
            return
        }
        selection.deactivate()
    }

    private var deletionAlertTitle: Text {
        switch pendingDeletion?.mode {
        case .sourceFiles:
            return Text("batch_delete_source_files")
        default:
            return Text("batch_remove_from_library")
        }
    }

    private func deletionMessage(_ pending: PendingDeletion) -> String {
        var message: String
        switch pending.mode {
        case .libraryOnly:
            message = String(
                format: String(localized: "batch_remove_from_library_message_format"),
                pending.songs.count
            )
        case .sourceFiles:
            message = String(
                format: String(localized: "batch_delete_source_files_message_format"),
                pending.songs.count
            )
        }
        if pending.skipped > 0 {
            message += "\n" + String(
                format: String(localized: "batch_delete_skipped_format"),
                pending.skipped
            )
        }
        return message
    }
}
