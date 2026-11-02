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
        let categories = LibraryReleaseCategoryIndex.shared.categories(for: album, in: library)
        Menu {
            ForEach(AlbumReleaseCategory.allCases) { category in
                Toggle(LocalizedStringKey(category.titleKey), isOn: Binding(
                    get: { categories.contains(category) },
                    set: { selected in
                        let songs = library.songs(forAlbum: album.id)
                        var updated = store.categories(album: album, songs: songs)
                        if selected { updated.insert(category) } else { updated.remove(category) }
                        if !updated.isEmpty {
                            store.set(updated, albumID: album.id, songIDs: songs.map(\.id))
                        }
                    }
                ))
                .disabled(categories == [category])
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
                } else if isReviewing {
                    Section("artist_merge_same_artist") {
                        ForEach(selected.sorted(), id: \.self) { Text($0) }
                    }
                    Section("artist_merge_name") {
                        TextField("artist_merge_name", text: $canonicalName)
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
                        Text("artist_merge_write_notice")
                    }
                } else {
                    Section {
                        TextField("filter_artists_placeholder", text: $query)
                        ForEach(artistNames.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { name in
                            Button {
                                if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
                            } label: {
                                HStack {
                                    Text(name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: selected.contains(name) ? "checkmark.circle.fill" : "circle")
                                }
                            }
                            .accessibilityAddTraits(selected.contains(name) ? .isSelected : [])
                        }
                    }
                }
            }
            .formStyle(.grouped)
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
            .onAppear {
                if !mergeService.isRunning && mergeService.outcome == nil && !initialNames.isEmpty && selected.isEmpty {
                    selected = initialNames
                    prepareReview()
                }
            }
            .onDisappear { preparationTask?.cancel() }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 480)
        #endif
    }

    private func prepareReview() {
        canonicalName = selected.sorted().first ?? ""
        isReviewing = true
        isPreparing = true
        let songs = library.visibleSongs
        let names = selected
        let configuration = library.artistNameConfiguration
        preparationTask?.cancel()
        preparationTask = Task {
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

struct ArtistMergeSuggestionsView: View {
    @Environment(MusicLibrary.self) private var library
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
                        Spacer()
                        Button("artist_merge_different") {
                            var dismissed = (try? JSONDecoder().decode(Set<String>.self, from: dismissedData)) ?? []
                            dismissed.insert(suggestion.id)
                            dismissedData = (try? JSONEncoder().encode(dismissed)) ?? Data()
                            suggestions.removeAll { $0.id == suggestion.id }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("artist_merge_suggestions")
        .task(id: library.visibleSongsVersion) {
            let names = (library.visibleArtists + library.visibleAlbumArtists).map(\.name)
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
