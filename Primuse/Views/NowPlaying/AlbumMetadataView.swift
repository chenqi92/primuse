import SwiftUI
import PrimuseKit

struct AlbumMetadataGroup: Identifiable {
    let id: String
    let title: String
    let artist: String?
    let songs: [Song]

    static func groups(for songs: [Song]) -> [Self] {
        var seen = Set<String>()
        let songs = songs.filter { $0.sourceID != AppleMusicLibraryService.systemSourceID && seen.insert($0.id).inserted }
        let grouped = Dictionary(grouping: songs) { song in
            if let album = nonempty(song.albumTitle) {
                return song.sourceID + "|album|" + album + "|" + (nonempty(song.albumArtistName) ?? "")
                    + "|folder|" + albumFolder(song.filePath)
            }
            return song.sourceID + "|folder|" + albumFolder(song.filePath)
        }
        return grouped.map { id, songs in
            let first = songs[0]
            let folder = albumFolder(first.filePath)
            return Self(id: id,
                        title: nonempty(first.albumTitle) ?? (folder as NSString).lastPathComponent,
                        artist: nonempty(first.albumArtistName) ?? nonempty(first.artistName)
                            ?? nonempty(((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent),
                        songs: songs.sorted {
                            if ($0.discNumber ?? 1) != ($1.discNumber ?? 1) { return ($0.discNumber ?? 1) < ($1.discNumber ?? 1) }
                            if ($0.trackNumber ?? 0) != ($1.trackNumber ?? 0) { return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
                            return $0.filePath.localizedStandardCompare($1.filePath) == .orderedAscending
                        })
        }.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func albumFolder(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        if (folder as NSString).lastPathComponent.range(of: #"(?i)^(cd|disc|disk)[\s._-]*\d+$"#, options: .regularExpression) != nil {
            return (folder as NSString).deletingLastPathComponent
        }
        return folder
    }
}

struct AlbumMetadataView: View {
    let songs: [Song]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let groups = AlbumMetadataGroup.groups(for: songs)
        NavigationStack {
            Group {
                if groups.count == 1, let group = groups.first {
                    AlbumMetadataSearchView(group: group)
                } else {
                    List(groups) { group in
                        NavigationLink {
                            AlbumMetadataSearchView(group: group)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: group.title)
                                Text(verbatim: [group.artist, String(group.songs.count)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle("album_metadata_search")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 700, minHeight: 540, idealHeight: 700)
        #endif
    }
}

private struct AlbumMetadataSearchView: View {
    let group: AlbumMetadataGroup
    @Environment(MusicLibrary.self) private var library
    @State private var title: String
    @State private var artist: String
    @State private var candidates: [Candidate] = []
    @State private var selectedAlbum: ScraperAlbum?
    @State private var tracks: [ScraperDetail] = []
    @State private var assignments: [String: String] = [:]
    @State private var isLoading = false
    @State private var didSearch = false
    @State private var errorMessage: String?
    @State private var request: Task<Void, Never>?
    @State private var review: TagChangeReviewInput?

    private struct Candidate: Identifiable {
        let album: ScraperAlbum
        let config: ScraperSourceConfig
        var id: String { config.id + ":" + album.id }
    }

    init(group: AlbumMetadataGroup) {
        self.group = group
        _title = State(initialValue: group.title)
        _artist = State(initialValue: group.artist ?? "")
    }

    var body: some View {
        List {
            Section {
                TextField("tag_editor_album", text: $title)
                TextField("tag_editor_artist", text: $artist)
                Button("album_metadata_search", systemImage: "magnifyingglass") { search() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
            if isLoading { ProgressView().frame(maxWidth: .infinity) }
            if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.secondary) }
            if let album = selectedAlbum {
                Section {
                    Text(verbatim: album.title).font(.headline)
                    Text(verbatim: [album.artist, album.year.map(String.init), album.edition].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(format: String(localized: "album_metadata_matched_format"), assignments.count, group.songs.count, tracks.count))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("album_metadata_review") { makeReview() }
                        .disabled(assignments.isEmpty || isLoading)
                    Button("back_to_results") {
                        selectedAlbum = nil
                        tracks = []
                        assignments = [:]
                    }
                }
                Section("album_metadata_match") {
                    ForEach(Array(group.songs.enumerated()), id: \.element.id) { index, song in
                        AlbumMetadataTrackRow(song: song, ordinal: index + 1, tracks: tracks, assignments: $assignments)
                    }
                }
            } else {
                ForEach(candidates) { candidate in
                    Button { load(candidate) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: candidate.album.title).foregroundStyle(.primary)
                            Text(verbatim: [candidate.album.artist, candidate.album.year.map(String.init),
                                            candidate.album.edition, candidate.config.displayName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if let count = candidate.album.trackCount {
                                Text(String(format: String(localized: "album_metadata_tracks_format"), count))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isLoading)
                }
                if didSearch && !isLoading && candidates.isEmpty && errorMessage == nil { Text("no_results") }
            }
        }
        .navigationTitle("album_metadata_search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $review) { input in
            TagChangeReviewView(input: input, onFinished: { review = nil })
        }
        .onDisappear { request?.cancel() }
    }

    private func search() {
        request?.cancel()
        candidates = []; selectedAlbum = nil; tracks = []; assignments = [:]; errorMessage = nil
        let sources = ScraperSettings.load().enabledSources.filter { $0.type == .itunes || $0.type == .musicBrainz }
        guard !sources.isEmpty else {
            errorMessage = String(localized: "album_metadata_sources_required")
            return
        }
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistQuery = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true; didSearch = true
        request = Task { @MainActor in
            defer { isLoading = false }
            var failures: [String] = []
            for config in sources {
                guard !Task.isCancelled else { return }
                guard let scraper = MusicScraperFactory.create(for: config) as? any AlbumMusicScraper else { continue }
                do {
                    let albums = try await scraper.searchAlbums(title: query, artist: artistQuery.isEmpty ? nil : artistQuery, limit: 20)
                    guard !Task.isCancelled else { return }
                    var seen = Set(candidates.map(\.id))
                    candidates += albums.map { Candidate(album: $0, config: config) }.filter { seen.insert($0.id).inserted }
                } catch {
                    guard !Task.isCancelled else { return }
                    failures.append(config.displayName + ": " + error.localizedDescription)
                }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    private func load(_ candidate: Candidate) {
        request?.cancel()
        isLoading = true; errorMessage = nil
        request = Task { @MainActor in
            defer { isLoading = false }
            do {
                guard let scraper = MusicScraperFactory.create(for: candidate.config) as? any AlbumMusicScraper else { return }
                let found = try await scraper.albumTracks(externalID: candidate.album.externalID)
                guard !Task.isCancelled else { return }
                var seen = Set<String>()
                tracks = found.filter { seen.insert($0.externalId).inserted }
                selectedAlbum = candidate.album
                assignments = AlbumMetadataMatching.assignments(songs: group.songs, tracks: tracks)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func makeReview() {
        let byID = Dictionary(tracks.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })
        let matched = group.songs.map { library.song(id: $0.id) ?? $0 }
            .filter { assignments[$0.id].flatMap { byID[$0] } != nil }
        let proposals = matched.flatMap { song in
            AlbumMetadataMatching.proposals(song: song, track: byID[assignments[song.id]!]!)
        }
        review = TagChangeReviewInput(songs: matched, proposals: proposals, coverData: nil, showsReasons: false)
    }
}

struct AlbumMetadataTrackRow: View {
    let song: Song
    let ordinal: Int
    let tracks: [ScraperDetail]
    @Binding var assignments: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(ordinal.formatted()). \(song.title)")
            Text(verbatim: song.filePath.split(separator: "/").suffix(2).joined(separator: "/"))
                .font(.caption).foregroundStyle(.secondary)
            Picker("album_metadata_match", selection: Binding(
                get: { assignments[song.id] ?? "" },
                set: { trackID in
                    assignments = assignments.filter { $0.key != song.id && $0.value != trackID }
                    if !trackID.isEmpty { assignments[song.id] = trackID }
                }
            )) {
                Text("album_metadata_unmatched").tag("")
                ForEach(tracks, id: \.externalId) { track in
                    Text(verbatim: "\(track.discNumber ?? 1).\(track.trackNumber ?? 0)  \(track.title)")
                        .tag(track.externalId)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
