import SwiftUI
import PrimuseKit

struct ScrapeOptionsView: View {
    let song: Song
    var onComplete: ((Song) -> Void)?

    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ScrapeMode = .options
    @State private var scrapeMetadata = true
    @State private var scrapeCover = true
    @State private var scrapeLyrics = true
    @State private var isScraping = false
    @State private var previewResult: ScrapePreview?
    @State private var searchResults: [SearchResultItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var manualSearchQuery = ""

    // Per-field apply toggles (for preview)
    @State private var applyTitle = true
    @State private var applyArtist = true
    @State private var applyAlbum = true
    @State private var applyYear = true
    @State private var applyGenre = true
    @State private var applyCover = true
    @State private var applyLyrics = true

    enum ScrapeMode {
        case options
        case preview
        case manual
    }

    struct ScrapePreview {
        var updatedSong: Song
        var coverData: Data?
        var lyricsCount: Int
        var titleChanged: Bool
        var artistChanged: Bool
        var albumChanged: Bool
        var yearChanged: Bool
        var genreChanged: Bool
        var coverChanged: Bool
        var lyricsChanged: Bool
    }

    struct SearchResultItem: Identifiable {
        let id: String
        let source: String
        let title: String
        let artist: String?
        let album: String?
        let durationMs: Int?
        let coverUrl: String?
        let externalId: String
        let scraperType: MusicScraperType

        var durationText: String? {
            guard let ms = durationMs else { return nil }
            let s = ms / 1000
            return String(format: "%d:%02d", s / 60, s % 60)
        }

        var matchScore: String {
            // Simple duration match indicator
            return durationText ?? ""
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .options: optionsView
                case .preview: previewView
                case .manual: manualSearchView
                }
            }
            .navigationTitle("scrape_song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Options (what to scrape)

    private var optionsView: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CachedArtworkView(coverFileName: song.coverArtFileName, size: 56, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                        Text(song.artistName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if song.duration > 0 {
                            Text(formatDuration(song.duration)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section("scrape_options") {
                Toggle("scrape_metadata_toggle", isOn: $scrapeMetadata)
                Toggle("scrape_cover_toggle", isOn: $scrapeCover)
                Toggle("scrape_lyrics_toggle", isOn: $scrapeLyrics)
            }

            Section {
                // Auto scrape (preview before apply)
                Button {
                    Task { await autoScrape() }
                } label: {
                    HStack {
                        Label("auto_scrape", systemImage: "wand.and.stars")
                            .fontWeight(.medium)
                        Spacer()
                        if isScraping { ProgressView() }
                    }
                }
                .disabled(isScraping || (!scrapeMetadata && !scrapeCover && !scrapeLyrics))

                // Manual search
                Button {
                    Task { await manualSearch() }
                } label: {
                    HStack {
                        Label("manual_scrape", systemImage: "magnifyingglass")
                        Spacer()
                        if isSearching { ProgressView() }
                    }
                }
                .disabled(isSearching)
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Preview (confirm before applying)

    private var previewView: some View {
        Form {
            if let preview = previewResult {
                // Select which changes to apply
                Section("select_changes") {
                    if preview.titleChanged {
                        Toggle(isOn: $applyTitle) {
                            changeRow("title", old: song.title, new: preview.updatedSong.title)
                        }
                    }
                    if preview.artistChanged {
                        Toggle(isOn: $applyArtist) {
                            changeRow("artist", old: song.artistName ?? "-", new: preview.updatedSong.artistName ?? "-")
                        }
                    }
                    if preview.albumChanged {
                        Toggle(isOn: $applyAlbum) {
                            changeRow("album", old: song.albumTitle ?? "-", new: preview.updatedSong.albumTitle ?? "-")
                        }
                    }
                    if preview.yearChanged {
                        Toggle(isOn: $applyYear) {
                            changeRow("year", old: song.year.map { "\($0)" } ?? "-", new: preview.updatedSong.year.map { "\($0)" } ?? "-")
                        }
                    }
                    if preview.genreChanged {
                        Toggle(isOn: $applyGenre) {
                            changeRow("genre", old: song.genre ?? "-", new: preview.updatedSong.genre ?? "-")
                        }
                    }
                    if preview.coverChanged {
                        Toggle(isOn: $applyCover) {
                            HStack {
                                Text("cover").font(.caption).foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
                                Image(systemName: song.coverArtFileName != nil ? "checkmark" : "xmark")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green)
                            }
                        }
                    }
                    if preview.lyricsChanged {
                        Toggle(isOn: $applyLyrics) {
                            HStack {
                                Text("lyrics_word").font(.caption).foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
                                Image(systemName: song.lyricsFileName != nil ? "checkmark" : "xmark")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text("✓ (\(preview.lyricsCount))").font(.caption2).foregroundStyle(.green)
                            }
                        }
                    }

                    if !hasAnyChange(preview) {
                        Label(String(localized: "scrape_no_changes"), systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        applySelectedChanges()
                    } label: {
                        Label("apply_changes", systemImage: "checkmark")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasAnySelectedChange)

                    Button { mode = .options } label: { Text("back_to_options") }
                }
            }
        }
    }

    private func changeRow(_ label: LocalizedStringKey, old: String, new: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(old).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(new).font(.caption2).fontWeight(.medium).foregroundStyle(old != new ? Color.accentColor : .primary).lineLimit(1)
            }
        }
    }

    private func hasAnyChange(_ p: ScrapePreview) -> Bool {
        p.titleChanged || p.artistChanged || p.albumChanged || p.yearChanged || p.genreChanged || p.coverChanged || p.lyricsChanged
    }

    private var hasAnySelectedChange: Bool {
        guard let p = previewResult else { return false }
        return (p.titleChanged && applyTitle) || (p.artistChanged && applyArtist) ||
               (p.albumChanged && applyAlbum) || (p.yearChanged && applyYear) ||
               (p.genreChanged && applyGenre) || (p.coverChanged && applyCover) ||
               (p.lyricsChanged && applyLyrics)
    }

    // MARK: - Manual Search (multiple results)

    private var manualSearchView: some View {
        List {
            // Editable search field
            Section {
                HStack {
                    TextField("search_query", text: $manualSearchQuery)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await performManualSearch() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(manualSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
            }

            if searchResults.isEmpty && !isSearching {
                ContentUnavailableView("no_results", systemImage: "magnifyingglass",
                    description: Text("no_scrape_results_desc"))
            } else {
                ForEach(searchResults) { item in
                    Button {
                        Task { await selectManualResult(item) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                Spacer()
                                if let dur = item.durationText {
                                    Text(dur).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            HStack(spacing: 4) {
                                if let artist = item.artist {
                                    Text(artist).font(.caption).foregroundStyle(.secondary)
                                }
                                if let album = item.album {
                                    Text("·").font(.caption).foregroundStyle(.tertiary)
                                    Text(album).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .lineLimit(1)
                            Text(item.source).font(.caption2).foregroundStyle(.tint)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Button {
                    mode = .options
                } label: {
                    Text("back_to_options")
                }
            }
        }
        .overlay {
            if isSearching {
                ProgressView("searching").padding()
            }
        }
    }

    // MARK: - Logic

    private func autoScrape() async {
        isScraping = true
        errorMessage = nil

        do {
            let updated = try await scraperService.scrapeSingle(song: song, in: library, dryRun: true)
            isScraping = false

            let lyricsCount = await MetadataAssetStore.shared.lyrics(named: updated.lyricsFileName)?.count ?? 0

            previewResult = ScrapePreview(
                updatedSong: updated, coverData: nil, lyricsCount: lyricsCount,
                titleChanged: updated.title != song.title,
                artistChanged: updated.artistName != song.artistName,
                albumChanged: updated.albumTitle != song.albumTitle,
                yearChanged: updated.year != song.year && updated.year != nil,
                genreChanged: updated.genre != song.genre && updated.genre != nil,
                coverChanged: updated.coverArtFileName != song.coverArtFileName && updated.coverArtFileName != nil,
                lyricsChanged: updated.lyricsFileName != song.lyricsFileName && updated.lyricsFileName != nil
            )

            // Default all toggles to on
            applyTitle = true; applyArtist = true; applyAlbum = true
            applyYear = true; applyGenre = true; applyCover = true; applyLyrics = true

            mode = .preview
        } catch {
            isScraping = false
            errorMessage = error.localizedDescription
        }
    }

    private func manualSearch() async {
        // Initialize search query with cleaned title
        manualSearchQuery = source_bScraper.cleanTitle(song.title)
        if let artist = song.artistName, !artist.isEmpty {
            manualSearchQuery += " \(artist)"
        }
        mode = .manual
        await performManualSearch()
    }

    private func performManualSearch() async {
        isSearching = true
        searchResults = []
        errorMessage = nil

        let settings = ScraperSettings.load()

        for config in settings.enabledSources where config.type.supportsMetadata {
            do {
                let scraper = MusicScraperFactory.create(for: config)
                let result = try await scraper.search(
                    query: manualSearchQuery, artist: nil, album: nil, limit: 10
                )
                for item in result.items {
                    searchResults.append(SearchResultItem(
                        id: "\(config.type.rawValue)_\(item.externalId)",
                        source: config.type.displayName,
                        title: item.title,
                        artist: item.artist,
                        album: item.album,
                        durationMs: item.durationMs,
                        coverUrl: item.coverUrl,
                        externalId: item.externalId,
                        scraperType: config.type
                    ))
                }
            } catch {
                // skip failed sources
            }
        }

        // Sort by duration match
        if song.duration > 0 {
            let targetMs = Int(song.duration * 1000)
            searchResults.sort { a, b in
                let diffA = abs((a.durationMs ?? 0) - targetMs)
                let diffB = abs((b.durationMs ?? 0) - targetMs)
                return diffA < diffB
            }
        }

        isSearching = false
        mode = .manual
    }

    private func selectManualResult(_ item: SearchResultItem) async {
        // TODO: fetch detail for selected item and show preview
        // For now, apply the basic metadata
        mode = .options
        isScraping = true

        do {
            let config = ScraperSourceConfig(id: "manual", type: item.scraperType, isEnabled: true, priority: 0)
            let scraper = MusicScraperFactory.create(for: config)
            let detail = try await scraper.getDetail(externalId: item.externalId)

            var updated = song
            if let detail {
                updated = Song(
                    id: song.id, title: detail.title,
                    albumID: song.albumID, artistID: song.artistID,
                    albumTitle: detail.album ?? song.albumTitle,
                    artistName: detail.artist ?? song.artistName,
                    trackNumber: detail.trackNumber ?? song.trackNumber,
                    discNumber: detail.discNumber ?? song.discNumber,
                    duration: song.duration, fileFormat: song.fileFormat,
                    filePath: song.filePath, sourceID: song.sourceID,
                    fileSize: song.fileSize, bitRate: song.bitRate,
                    sampleRate: song.sampleRate, bitDepth: song.bitDepth,
                    genre: detail.genres?.prefix(3).joined(separator: ", ") ?? song.genre,
                    year: detail.year ?? song.year,
                    dateAdded: song.dateAdded,
                    coverArtFileName: song.coverArtFileName,
                    lyricsFileName: song.lyricsFileName
                )
            }

            isScraping = false

            previewResult = ScrapePreview(
                updatedSong: updated, coverData: nil, lyricsCount: 0,
                titleChanged: updated.title != song.title,
                artistChanged: updated.artistName != song.artistName,
                albumChanged: updated.albumTitle != song.albumTitle,
                yearChanged: updated.year != song.year && updated.year != nil,
                genreChanged: updated.genre != song.genre && updated.genre != nil,
                coverChanged: false, lyricsChanged: false
            )
            applyTitle = true; applyArtist = true; applyAlbum = true
            applyYear = true; applyGenre = true; applyCover = true; applyLyrics = true
            mode = .preview
        } catch {
            isScraping = false
            errorMessage = error.localizedDescription
        }
    }

    private func applySelectedChanges() {
        guard let preview = previewResult else { return }
        let u = preview.updatedSong

        // Build final song with only selected changes applied
        let final = Song(
            id: song.id,
            title: (preview.titleChanged && applyTitle) ? u.title : song.title,
            albumID: song.albumID, artistID: song.artistID,
            albumTitle: (preview.albumChanged && applyAlbum) ? u.albumTitle : song.albumTitle,
            artistName: (preview.artistChanged && applyArtist) ? u.artistName : song.artistName,
            trackNumber: u.trackNumber ?? song.trackNumber,
            discNumber: u.discNumber ?? song.discNumber,
            duration: u.duration > 0 ? u.duration : song.duration,
            fileFormat: song.fileFormat,
            filePath: song.filePath, sourceID: song.sourceID,
            fileSize: song.fileSize,
            bitRate: u.bitRate ?? song.bitRate,
            sampleRate: u.sampleRate ?? song.sampleRate,
            bitDepth: u.bitDepth ?? song.bitDepth,
            genre: (preview.genreChanged && applyGenre) ? u.genre : song.genre,
            year: (preview.yearChanged && applyYear) ? u.year : song.year,
            dateAdded: song.dateAdded,
            coverArtFileName: (preview.coverChanged && applyCover) ? u.coverArtFileName : song.coverArtFileName,
            lyricsFileName: (preview.lyricsChanged && applyLyrics) ? u.lyricsFileName : song.lyricsFileName
        )

        library.replaceSong(final)
        onComplete?(final)
        dismiss()
    }

    // MARK: - Helpers

    private func compareRow(_ label: LocalizedStringKey, old: String?, new: String?) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(old ?? "-").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text(new ?? "-").font(.caption).fontWeight(old != new ? .semibold : .regular)
                .foregroundStyle(old != new ? Color.accentColor : .primary).lineLimit(1)
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
