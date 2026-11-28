import SwiftUI
import Observation
import PrimuseKit

@MainActor @Observable
final class LibraryReleaseCategoryIndex {
    static let shared = LibraryReleaseCategoryIndex()
    private struct Request: Equatable {
        let library: ObjectIdentifier
        let store: ObjectIdentifier
        let membershipRevision: UInt64
        let overrideRevision: Int
    }
    @ObservationIgnored private var requested: Request?
    @ObservationIgnored private var completed: Request?
    @ObservationIgnored private var overrides: [String: Set<AlbumReleaseCategory>] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    private var revision = 0

    func categories(
        for album: Album,
        in library: MusicLibrary,
        store: AlbumReleaseCategoryStore = .shared
    ) -> Set<AlbumReleaseCategory> {
        _ = revision
        let automatic = library.automaticReleaseCategories(for: album)
        let snapshot = store.snapshot
        guard !snapshot.isEmpty else {
            task?.cancel()
            task = nil
            requested = nil
            return automatic
        }
        let request = Request(
            library: ObjectIdentifier(library),
            store: ObjectIdentifier(store),
            membershipRevision: library.releaseCategoryMembershipRevision,
            overrideRevision: store.revision
        )
        if requested != request {
            task?.cancel()
            requested = request
            task = Task { [weak self, weak library] in
                guard let library else { return }
                guard let result = await library.resolvedReleaseOverrides(snapshot),
                      !Task.isCancelled, self?.requested == request,
                      library.releaseCategoryMembershipRevision == request.membershipRevision,
                      store.revision == request.overrideRevision else { return }
                guard let self else { return }
                let previous = self.overrides
                self.overrides = result
                self.completed = request
                self.revision &+= 1
                self.task = nil
                Task.detached(priority: .utility) { withExtendedLifetime(previous) {} }
            }
        }
        if completed == request { return overrides[album.id] ?? automatic }
        return store.override(albumID: album.id) ?? automatic
    }

    func waitForPendingResolution() async { await task?.value }
}

struct AlbumReleaseCategoryPicker: View {
    @Binding var selection: String
    var body: some View {
        Picker("release_category", selection: $selection) {
            Text("release_category_all").tag("")
            ForEach(AlbumReleaseCategory.allCases) { category in
                Text(LocalizedStringKey(category.titleKey)).tag(category.rawValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityIdentifier("albums.releaseCategory")
    }
}

struct AlbumReleaseCategoryMenu: View {
    let album: Album
    @Environment(MusicLibrary.self) private var library
    private let store = AlbumReleaseCategoryStore.shared

    var body: some View {
        let categories = ReleaseCategoryCatalog.categories(for: album, in: library)
        Menu {
            ForEach(AlbumReleaseCategory.allCases) { category in
                Toggle(LocalizedStringKey(category.titleKey), isOn: Binding(
                    get: { categories.contains(category) },
                    set: { selected in
                        let songs = library.songs(forAlbum: album.id)
                        var updated = store.categories(album: album, songs: songs)
                        if selected { updated.insert(category) } else { updated.remove(category) }
                        // 点的是唯一勾着的那一项:分类不能清空,改为把它记成手动选的。自动认出的「专辑」
                        // 也就能确认下来(只收了一首的正式专辑,「不列只有单曲或 EP 的人」就按手动的算)。
                        if updated.isEmpty { updated = [category] }
                        store.set(updated, albumID: album.id, songIDs: songs.map(\.id))
                    }
                ))
            }
            Divider()
            Button("release_category_automatic") {
                store.set(nil, albumID: album.id, songIDs: library.songs(forAlbum: album.id).map(\.id))
            }
        } label: {
            Label("release_category", systemImage: "square.grid.2x2")
        }
    }
}

struct ArtistMergeView: View {
    var initialNames: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(AudioPlayerService.self) private var player
    @State private var selected: Set<String> = []
    @State private var canonicalName = ""
    @State private var query = ""
    @State private var isReviewing = false
    @State private var isPreparing = false
    @State private var reviewedSongIDs: [String] = []
    @State private var preparationTask: Task<Void, Never>?
    private var mergeService: ArtistMergeService { .shared }

    private var artistNames: [String] {
        Set((library.visibleArtists + library.visibleAlbumArtists).map(\.name))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var validName: Bool {
        !canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ArtistNameParser.names(rawName: canonicalName, configuration: library.artistNameConfiguration).count == 1
    }

    var body: some View {
        NavigationStack {
            Form {
                if mergeService.isRunning {
                    Section {
                        Text(mergeService.canonicalName)
                        if mergeService.isRetryingWrites {
                            Text("batch_writeback_retrying")
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(mergeService.progress.done), total: Double(max(1, mergeService.progress.total)))
                        Text("\(mergeService.progress.done)/\(mergeService.progress.total)").monospacedDigit()
                        if mergeService.cancellationRequested {
                            Text("local_import_progress_cancelling")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("cancel", role: .destructive) { mergeService.cancel() }
                                .accessibilityIdentifier("artistMerge.cancel")
                        }
                    }
                } else if let outcome = mergeService.outcome {
                    Section {
                        if outcome.wasCancelled { Text("source_address_probe_cancelled") }

                        Text(String(format: String(localized: "artist_merge_result_format"), outcome.applied.count, outcome.localOnlySongIDs.count))
                    }
                    // Which songs those are, the file each one is, and why.
                    BatchWritebackIssuesSection(
                        entries: outcome.localOnlyWrites,
                        rewrittenCount: mergeService.rewrittenCount,
                        isRetrying: mergeService.isRetryingWrites
                    ) {
                        _ = mergeService.retryLocalOnlyWrites(library: library, sourceManager: sourceManager, player: player)
                    }
                } else if isReviewing {
                    Section("artist_merge_same_artist") {
                        ForEach(selected.sorted(), id: \.self) { Text($0) }
                    }
                    Section("artist_merge_name") {
                        #if os(macOS)
                        // 分组标题已经写了名字; Mac 表单里输入框的标题会再变成左边的标签。
                        TextField("", text: $canonicalName, prompt: Text("artist_merge_name"))
                            .labelsHidden()
                            .macSheetField()
                        #else
                        TextField("artist_merge_name", text: $canonicalName)
                        #endif
                        Menu("artist_merge_use_name") {
                            ForEach(selected.sorted(), id: \.self) { name in
                                Button(name) { canonicalName = name }
                            }
                        }
                    }
                    Section {
                        if isPreparing { ProgressView() }
                        else { Text(String(format: String(localized: "artist_merge_song_count_format"), reviewedSongIDs.count)) }
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("artist_merge_write_notice")
                            if !isPreparing {
                                TagWritebackPreflightNote(songIDs: reviewedSongIDs)
                            }
                        }
                    }
                } else {
                    Section {
                        #if os(macOS)
                        MacSheetSearchField(text: $query, prompt: Text("filter_artists_placeholder"))
                        #else
                        TextField("filter_artists_placeholder", text: $query)
                        #endif
                        ForEach(artistNames.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { name in
                            Button {
                                if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
                            } label: {
                                #if os(macOS)
                                // Mac 表单里的按钮默认是一颗带边框的按键; 这里是整行点、右边一个勾。
                                HStack {
                                    Text(name).foregroundStyle(PMColor.text)
                                    Spacer()
                                    Image(systemName: selected.contains(name) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 15))
                                        .foregroundStyle(selected.contains(name) ? PMColor.brand : PMColor.textFaint)
                                }
                                .contentShape(Rectangle())
                                #else
                                HStack {
                                    Text(name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: selected.contains(name) ? "checkmark.circle.fill" : "circle")
                                }
                                #endif
                            }
                            #if os(macOS)
                            .buttonStyle(.plain)
                            #endif
                            .accessibilityAddTraits(selected.contains(name) ? .isSelected : [])
                        }
                    }
                }
            }
            .formStyle(.grouped)
            #if os(macOS)
            // Mac 弹框: 标题行 + 底栏(关掉 / 预览 / 合并), 不用系统的标题栏和底部系统按钮。
            .macFormSheet(
                title: Text("artist_merge_title"),
                subtitle: selected.isEmpty || mergeService.isRunning || mergeService.outcome != nil
                    ? nil
                    : Text(String(format: String(localized: "tag_review_selected_format"), selected.count)),
                systemImage: "person.2"
            ) {
                macDismissButton
                if !mergeService.isRunning && mergeService.outcome == nil {
                    Button(isReviewing ? "artist_merge_confirm" : "batch_edit_review") {
                        if isReviewing { merge() } else { prepareReview() }
                    }
                    .buttonStyle(.macSheetPrimary)
                    .disabled(selected.count < 2 || isPreparing || (isReviewing && (!validName || reviewedSongIDs.isEmpty)))
                    .keyboardShortcut(.defaultAction)
                }
            }
            #else
            .navigationTitle("artist_merge_title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mergeService.isRunning ? "dup_mac_continue_background" : (mergeService.outcome == nil ? "cancel" : "done")) {
                        if !mergeService.isRunning { mergeService.clearResult() }
                        dismiss()
                    }
                    .accessibilityIdentifier("artistMerge.dismiss")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !mergeService.isRunning && mergeService.outcome == nil {
                        Button(isReviewing ? "artist_merge_confirm" : "batch_edit_review") {
                            if isReviewing { merge() } else { prepareReview() }
                        }
                        .disabled(selected.count < 2 || isPreparing || (isReviewing && (!validName || reviewedSongIDs.isEmpty)))
                    }
                }
            }
            #endif
            .onAppear {
                if !mergeService.isRunning && mergeService.outcome == nil && !initialNames.isEmpty && selected.isEmpty {
                    selected = initialNames
                    prepareReview()
                }
            }
            .onDisappear { preparationTask?.cancel() }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 600)
        #endif
    }

    #if os(macOS)
    private var macDismissButton: some View {
        Button(mergeService.isRunning ? "dup_mac_continue_background" : (mergeService.outcome == nil ? "cancel" : "done")) {
            if !mergeService.isRunning { mergeService.clearResult() }
            dismiss()
        }
        .buttonStyle(MacSheetButtonStyle(kind: mergeService.outcome != nil && !mergeService.isRunning ? .primary : .secondary))
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("artistMerge.dismiss")
    }
    #endif

    private func prepareReview() {
        canonicalName = selected.sorted().first ?? ""
        isReviewing = true
        isPreparing = true
        let names = selected
        let configuration = library.artistNameConfiguration
        preparationTask?.cancel()
        preparationTask = Task {
            // 要改的歌从整库里找:歌曲模型放掉了先装回来;答不了时退回选择,不给出「没有要改的歌」。
            guard let songs = await SongModelArrayRead.read(library, { library.visibleSongs }) else {
                isPreparing = false
                isReviewing = false
                preparationTask = nil
                return
            }
            let ids = await Task.detached(priority: .utility) {
                let keys = Set(names.map(ArtistIdentityPolicy.groupingKey))
                return songs.filter { song in
                    let contributors = ArtistNameParser.names(rawName: song.artistName, sourceNames: song.sourceArtistNames, configuration: configuration)
                        + ArtistNameParser.names(rawName: song.albumArtistName, configuration: configuration)
                    return contributors.contains { keys.contains(ArtistIdentityPolicy.groupingKey($0)) }
                }.map(\.id)
            }.value
            guard !Task.isCancelled else { return }
            reviewedSongIDs = ids
            isPreparing = false
            preparationTask = nil
        }
    }

    private func merge() {
        mergeService.start(songIDs: reviewedSongIDs, names: selected, canonicalName: canonicalName,
                           library: library, sourceManager: sourceManager, player: player)
    }

}

/// 艺人页「合并建议」单独弹出的那一层。
struct ArtistMergeSuggestionsSheet: View {
    let onDone: () -> Void

    var body: some View {
        #if os(macOS)
        // Mac 弹框: 页面自己画标题行和关闭键, 不用弹框里系统蓝的工具栏「完成」。
        NavigationStack {
            ArtistMergeSuggestionsView(onClose: onDone)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440, idealHeight: 520)
        #else
        NavigationStack {
            ArtistMergeSuggestionsView()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("done", action: onDone) } }
        }
        #endif
    }
}

struct ArtistMergeSuggestionsView: View {
    /// Mac:单独弹出时(艺人页「合并建议」)标题行的关闭键;为空时是从「整理标签」推进来的,标题行给返回键。
    var onClose: (() -> Void)? = nil
    @Environment(MusicLibrary.self) private var library
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macSheetDismiss) private var sheetDismiss
    #endif
    @State private var suggestions: [ArtistMergePolicy.Suggestion] = []
    @State private var selected: ArtistMergePolicy.Suggestion?
    @AppStorage("library.dismissedArtistMerges.v1") private var dismissedData = Data()

    var body: some View {
        List {
            if suggestions.isEmpty { Text("artist_merge_no_suggestions").foregroundStyle(.secondary) }
            ForEach(suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 10) {
                    Text(suggestion.names.joined(separator: " · "))
                    HStack {
                        Button("artist_merge_review") { selected = suggestion }
                            #if os(macOS)
                            .buttonStyle(.macSheet)
                            #endif
                        Spacer()
                        Button("artist_merge_different") {
                            var dismissed = (try? JSONDecoder().decode(Set<String>.self, from: dismissedData)) ?? []
                            dismissed.insert(suggestion.id)
                            dismissedData = (try? JSONEncoder().encode(dismissed)) ?? Data()
                            suggestions.removeAll { $0.id == suggestion.id }
                        }
                        #if os(macOS)
                        .buttonStyle(.macSheetText())
                        #endif
                    }
                    #if !os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                }
                #if os(macOS)
                .padding(.vertical, 4)
                #endif
            }
        }
        #if os(macOS)
        // Mac 弹框里的一页: 标题行(返回或关闭) → 列表。
        .macSheetPage(
            title: Text("artist_merge_suggestions"),
            systemImage: onClose == nil ? nil : "person.2",
            onBack: onClose == nil ? { dismiss() } : nil,
            onClose: onClose ?? sheetDismiss.macCloseAction
        )
        #else
        .navigationTitle("artist_merge_suggestions")
        #endif
        .task(id: library.visibleSongsVersion) {
            // 建议要整库的艺人名:歌曲模型放掉了先装回来;答不了时不把「没有建议」当成结果。
            guard let names = await SongModelArrayRead.read(library, {
                (library.visibleArtists + library.visibleAlbumArtists).map(\.name)
            }) else { return }
            let dismissed = (try? JSONDecoder().decode(Set<String>.self, from: dismissedData)) ?? []
            let found = await Task.detached(priority: .userInitiated) {
                ArtistMergePolicy.suggestions(names: names, dismissed: dismissed)
            }.value
            guard !Task.isCancelled else { return }
            suggestions = found
        }
        .sheet(item: $selected) { suggestion in ArtistMergeView(initialNames: Set(suggestion.names)) }
    }
}
