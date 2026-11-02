import SwiftUI
import PrimuseKit

@MainActor
final class LibraryReleaseCategoryIndex {
    static let shared = LibraryReleaseCategoryIndex()
    private weak var library: MusicLibrary?
    private var version: MusicLibrary.VisibleSongsVersion?
    private var albumsRevision: Int?
    private var overrideRevision = -1
    private var categories: [String: Set<AlbumReleaseCategory>] = [:]

    func categories(for album: Album, in library: MusicLibrary) -> Set<AlbumReleaseCategory> {
        let store = AlbumReleaseCategoryStore.shared
        if self.library !== library || version != library.visibleSongsVersion
            || albumsRevision != library.visibleAlbumsRevision || overrideRevision != store.revision {
            categories = store.classifications(albums: library.visibleAlbums, songs: library.visibleSongs)
            self.library = library
            version = library.visibleSongsVersion
            albumsRevision = library.visibleAlbumsRevision
            overrideRevision = store.revision
        }
        return categories[album.id] ?? [.album]
    }
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
        .pickerStyle(.segmented)
        .accessibilityIdentifier("albums.releaseCategory")
    }
}

struct AlbumReleaseCategoryMenu: View {
    let album: Album
    @Environment(MusicLibrary.self) private var library
    private let store = AlbumReleaseCategoryStore.shared

    var body: some View {
        let songs = library.songs(forAlbum: album.id)
        let categories = store.categories(album: album, songs: songs)
        Menu {
            ForEach(AlbumReleaseCategory.allCases) { category in
                Toggle(LocalizedStringKey(category.titleKey), isOn: Binding(
                    get: { categories.contains(category) },
                    set: { selected in
                        var updated = categories
                        if selected { updated.insert(category) } else { updated.remove(category) }
                        if !updated.isEmpty { store.set(updated, albumID: album.id, songIDs: songs.map(\.id)) }
                    }
                ))
                .disabled(categories == [category])
            }
            Divider()
            Button("release_category_automatic") {
                store.set(nil, albumID: album.id, songIDs: songs.map(\.id))
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
    @State private var progress: (Int, Int)?
    @State private var outcome: BatchTagEditService.Outcome?

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
                if let outcome {
                    Section {
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
                        if let progress {
                            ProgressView(value: Double(progress.0), total: Double(max(1, progress.1)))
                            Text("\(progress.0)/\(progress.1)").monospacedDigit()
                        }
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
                    Button(outcome == nil ? "cancel" : "done") { dismiss() }
                        .disabled(progress != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if outcome == nil {
                        Button(isReviewing ? "artist_merge_confirm" : "batch_edit_review") {
                            if isReviewing { merge() } else { prepareReview() }
                        }
                        .disabled(selected.count < 2 || isPreparing || progress != nil || (isReviewing && (!validName || reviewedSongIDs.isEmpty)))
                    }
                }
            }
            .disabled(progress != nil)
            .interactiveDismissDisabled(progress != nil)
            .onAppear {
                if !initialNames.isEmpty && selected.isEmpty {
                    selected = initialNames
                    prepareReview()
                }
            }
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
        Task {
            let ids = await Task.detached(priority: .userInitiated) {
                let keys = Set(names.map(ArtistIdentityPolicy.groupingKey))
                return songs.filter { song in
                    let contributors = ArtistNameParser.names(rawName: song.artistName, sourceNames: song.sourceArtistNames, configuration: configuration)
                        + ArtistNameParser.names(rawName: song.albumArtistName, configuration: configuration)
                    return contributors.contains { keys.contains(ArtistIdentityPolicy.groupingKey($0)) }
                }.map(\.id)
            }.value
            reviewedSongIDs = ids
            isPreparing = false
        }
    }

    private func merge() {
        let changes = reviewedSongIDs.compactMap { id -> (original: Song, updated: Song)? in
            guard let original = library.song(id: id) else { return nil }
            let updated = ArtistMergePolicy.applying(to: original, names: selected, canonicalName: canonicalName, configuration: library.artistNameConfiguration)
            return (original, updated)
        }
        progress = (0, changes.count)
        Task {
            outcome = await BatchTagEditService.apply(changes, coverData: nil, sourceManager: sourceManager, library: library, player: player, keepsLocalEditsOnWriteFailure: true) { done, total in
                progress = (done, total)
            }
            progress = nil
        }
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
