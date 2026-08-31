import SwiftUI
import PrimuseKit
#if canImport(UIKit)
import UIKit
#endif

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

#if os(macOS)
private struct SongBatchActionBarPresentation<Bar: View>: View {
    let selection: SongSelectionModel
    private let bar: () -> Bar

    init(
        selection: SongSelectionModel,
        @ViewBuilder bar: @escaping () -> Bar
    ) {
        self.selection = selection
        self.bar = bar
    }

    var body: some View {
        Group {
            if selection.isActive {
                bar()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(true)
            }
        }
        .animation(.snappy(duration: 0.22), value: selection.isActive)
    }
}
#endif

#if os(iOS)
/// Visible song-list pages report selection mode to the app shell so the mini
/// player and a batch toolbar never compete for the same bottom safe area.
struct SongBatchSelectionActivePreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The system bottom bar owns safe-area, rotation, Dynamic Type, and Liquid
/// Glass behavior. Keeping the three actions inside one lightweight child also
/// prevents a selection-mode change from rebuilding the page that hosts it.
private struct IOSBatchActionToolbarContent<MoreActions: View>: View {
    let selection: SongSelectionModel
    let queueFeedback: String?
    let onAddToPlaylist: () -> Void
    let onAddToQueue: () -> Void
    private let moreActions: () -> MoreActions

    init(
        selection: SongSelectionModel,
        queueFeedback: String?,
        onAddToPlaylist: @escaping () -> Void,
        onAddToQueue: @escaping () -> Void,
        @ViewBuilder moreActions: @escaping () -> MoreActions
    ) {
        self.selection = selection
        self.queueFeedback = queueFeedback
        self.onAddToPlaylist = onAddToPlaylist
        self.onAddToQueue = onAddToQueue
        self.moreActions = moreActions
    }

    @ViewBuilder
    var body: some View {
        if selection.isActive {
            HStack(spacing: 0) {
                Button(action: onAddToPlaylist) {
                    actionLabel(
                        Text("add_to_playlist"),
                        systemImage: "text.badge.plus"
                    )
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("batchAction.addToPlaylist")

                Divider()
                    .frame(height: 24)

                Button(action: onAddToQueue) {
                    actionLabel(
                        queueFeedback.map { Text(verbatim: $0) }
                            ?? Text("add_to_queue"),
                        systemImage: queueFeedback == nil
                            ? "text.line.last.and.arrowtriangle.forward"
                            : "checkmark"
                    )
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("batchAction.addToQueue")

                Divider()
                    .frame(height: 24)

                Menu {
                    moreActions()
                } label: {
                    actionLabel(Text("more"), systemImage: "ellipsis")
                }
                .disabled(selection.isEmpty)
                .accessibilityLabel(Text("a11y_more_actions"))
                .accessibilityIdentifier("batchAction.more")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func actionLabel(_ title: Text, systemImage: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label {
                title
            } icon: {
                Image(systemName: systemImage)
            }
            .labelStyle(.titleAndIcon)

            title
        }
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}
#endif

private struct SongBatchActionsModifier: ViewModifier {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(SongBatchRemovalService.self) private var removal
    #if os(iOS)
    @Environment(\.appNavigationMode) private var appNavigationMode
    #endif
    let selection: SongSelectionModel
    let context: SongBatchActionContext
    let orderedIDs: () -> [String]
    let resolve: (String) -> Song?

    @State private var showAddToPlaylist = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var showNoDeletableSourceAlert = false
    @State private var showNoScraperSourceAlert = false
    @State private var queueFeedback: String?
    @State private var queueFeedbackTask: Task<Void, Never>?

    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let mode: SongBatchRemovalService.Mode
        let songs: [Song]
        let skipped: Int
    }

    func body(content: Content) -> some View {
        actionPresentation(content)
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
            .onDisappear {
                queueFeedbackTask?.cancel()
                queueFeedbackTask = nil
            }
    }

    @ViewBuilder
    private func actionPresentation(_ content: Content) -> some View {
        #if os(iOS)
        content
            .preference(
                key: SongBatchSelectionActivePreferenceKey.self,
                value: selection.isActive
            )
            // A selection toolbar and the app tab bar cannot share the same
            // bottom edge on iPhone. On iOS 26 their glass backgrounds overlap
            // and taps can fall through to a tab item. Selection temporarily
            // replaces the tab bar, then restores the parent visibility.
            .toolbar(
                selection.isActive || appNavigationMode == .minimal ? .hidden : .automatic,
                for: .tabBar
            )
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    IOSBatchActionToolbarContent(
                        selection: selection,
                        queueFeedback: queueFeedback,
                        onAddToPlaylist: { showAddToPlaylist = true },
                        onAddToQueue: appendSelectionToQueue
                    ) {
                        moreActions(includesAddToQueue: false)
                    }
                }
            }
        #else
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                SongBatchActionBarPresentation(selection: selection) {
                    macActionBar
                }
            }
            .onExitCommand {
                if selection.isActive {
                    selection.deactivate()
                }
            }
        #endif
    }

    #if os(macOS)
    private var macActionBar: some View {
        HStack(spacing: 10) {
            Button {
                selection.deactivate()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(PMColor.glassBtn, in: .circle)
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

            Button("batch_select_all") {
                selection.selectAll(orderedIDs())
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            if !selection.isEmpty {
                Button("batch_deselect_all") {
                    selection.clear()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Divider()
                .frame(height: 20)

            Button {
                showAddToPlaylist = true
            } label: {
                Label("add_to_playlist", systemImage: "text.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("batchAction.addToPlaylist")

            Button {
                insertSelectionNext()
            } label: {
                Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("batchAction.insertNext")

            Button {
                appendSelectionToQueue()
            } label: {
                Label {
                    queueFeedback.map { Text(verbatim: $0) } ?? Text("add_to_queue")
                } icon: {
                    Image(systemName: queueFeedback == nil
                          ? "text.line.last.and.arrowtriangle.forward"
                          : "checkmark")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("batchAction.addToQueue")

            Menu {
                moreActions(includesAddToQueue: true)
            } label: {
                Label("more", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .disabled(selection.isEmpty)
            .accessibilityLabel(Text("a11y_more_actions"))

            Spacer(minLength: 0)

            Text("Esc")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(PMColor.textFaint)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 4))
                .accessibilityHidden(true)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
    #endif

    @ViewBuilder
    private func moreActions(includesAddToQueue: Bool) -> some View {
        Section {
            if includesAddToQueue {
                Button {
                    appendSelectionToQueue()
                } label: {
                    Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }

            Button {
                insertSelectionNext()
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

    private func appendSelectionToQueue() {
        let songs = playableSelection()
        guard !songs.isEmpty else { return }
        player.appendToQueue(songs)
        presentQueueFeedback(
            songCount: songs.count,
            action: String(localized: "add_to_queue")
        )
    }

    private func insertSelectionNext() {
        let songs = playableSelection()
        guard !songs.isEmpty else { return }
        player.insertNextInQueue(songs)
        presentQueueFeedback(
            songCount: songs.count,
            action: String(localized: "insert_next")
        )
    }

    private func presentQueueFeedback(songCount: Int, action: String) {
        let countMessage = String(
            format: String(localized: "new_songs_added"),
            songCount
        )
        queueFeedback = countMessage

        #if os(iOS)
        let announcement = "\(action), \(countMessage)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: announcement)
        #endif

        queueFeedbackTask?.cancel()
        queueFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            queueFeedback = nil
            queueFeedbackTask = nil
        }
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
