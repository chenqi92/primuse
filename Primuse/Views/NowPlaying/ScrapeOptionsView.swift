import SwiftUI
import PrimuseKit

struct ScrapeOptionsView: View {
    let song: Song
    var onComplete: ((Song) -> Void)?

    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ScrapeMode = .options
    @State private var previewSource: ScrapeMode = .options
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
        var lyricsLines: [LyricLine]?
        // Scraped values (always show these)
        var scrapedTitle: String?
        var scrapedArtist: String?
        var scrapedAlbum: String?
        var scrapedYear: Int?
        var scrapedGenre: String?
        var hasCover: Bool
        var hasLyrics: Bool
    }

    struct SearchResultItem: Identifiable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let durationMs: Int?
        let coverUrl: String?
        let externalId: String
        let sourceConfig: ScraperSourceConfig

        var source: String { sourceConfig.displayName }

        var durationText: String? {
            guard let ms = durationMs else { return nil }
            let s = ms / 1000
            return String(format: "%d:%02d", s / 60, s % 60)
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
                    CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 56, cornerRadius: 8, sourceID: song.sourceID, filePath: song.filePath)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                        Text(song.artistName ?? "").font(.caption).foregroundStyle(Color(.systemGray)).lineLimit(1)
                        if song.duration.sanitizedDuration > 0 {
                            Text(formatDuration(song.duration)).font(.caption2).foregroundStyle(Color(.systemGray2))
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
                // Always show all scraped fields
                Section("select_changes") {
                    // Title
                    fieldToggle(
                        isOn: $applyTitle,
                        label: "title",
                        localValue: song.title,
                        scrapedValue: preview.scrapedTitle,
                        isChanged: preview.scrapedTitle != nil && preview.scrapedTitle != song.title
                    )

                    // Artist
                    fieldToggle(
                        isOn: $applyArtist,
                        label: "artist",
                        localValue: song.artistName ?? "-",
                        scrapedValue: preview.scrapedArtist,
                        isChanged: preview.scrapedArtist != nil && preview.scrapedArtist != song.artistName
                    )

                    // Album
                    fieldToggle(
                        isOn: $applyAlbum,
                        label: "album",
                        localValue: song.albumTitle ?? "-",
                        scrapedValue: preview.scrapedAlbum,
                        isChanged: preview.scrapedAlbum != nil && preview.scrapedAlbum != song.albumTitle
                    )

                    // Year
                    fieldToggle(
                        isOn: $applyYear,
                        label: "year",
                        localValue: song.year.map { "\($0)" } ?? "-",
                        scrapedValue: preview.scrapedYear.map { "\($0)" },
                        isChanged: preview.scrapedYear != nil && preview.scrapedYear != song.year
                    )

                    // Genre
                    fieldToggle(
                        isOn: $applyGenre,
                        label: "genre",
                        localValue: song.genre ?? "-",
                        scrapedValue: preview.scrapedGenre,
                        isChanged: preview.scrapedGenre != nil && preview.scrapedGenre != song.genre
                    )

                    // Cover — show thumbnails for comparison
                    if preview.hasCover {
                        Toggle(isOn: $applyCover) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("cover").font(.caption).foregroundStyle(Color(.systemGray))
                                HStack(spacing: 8) {
                                    // Current cover
                                    VStack(spacing: 2) {
                                        CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 56, cornerRadius: 6, sourceID: song.sourceID, filePath: song.filePath)
                                        Text("current").font(.system(size: 9)).foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                    // New cover (from in-memory data)
                                    VStack(spacing: 2) {
                                        if let data = preview.coverData, let img = UIImage(data: data) {
                                            Image(uiImage: img)
                                                .resizable().aspectRatio(contentMode: .fill)
                                                .frame(width: 56, height: 56)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        } else {
                                            CachedArtworkView(coverRef: preview.updatedSong.coverArtFileName, songID: preview.updatedSong.id, size: 56, cornerRadius: 6, sourceID: song.sourceID, filePath: song.filePath)
                                        }
                                        Text("new").font(.system(size: 9)).foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }

                    // Lyrics
                    if preview.hasLyrics {
                        Toggle(isOn: $applyLyrics) {
                            HStack(spacing: 6) {
                                Text("lyrics_word").font(.caption).foregroundStyle(Color(.systemGray)).frame(width: 45, alignment: .leading)
                                statusBadge(hasLocal: song.lyricsFileName != nil, hasScraped: true,
                                            isChanged: preview.updatedSong.lyricsFileName != song.lyricsFileName)
                                if preview.lyricsCount > 0 {
                                    Text("(\(preview.lyricsCount))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !hasAnyScrapeResult(preview) {
                        Label(String(localized: "scrape_no_changes"), systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if previewSource == .manual {
                        Button { mode = .manual } label: {
                            Text(String(localized: "back_to_results"))
                        }
                    }
                    Button { mode = .options } label: { Text("back_to_options") }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("apply_changes") {
                    applySelectedChanges()
                }
                .fontWeight(.semibold)
                .disabled(!hasAnySelectedChange)
            }
        }
    }

    @ViewBuilder
    private func fieldToggle(isOn: Binding<Bool>, label: LocalizedStringKey, localValue: String, scrapedValue: String?, isChanged: Bool) -> some View {
        if let scraped = scrapedValue {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(Color(.systemGray))
                    if isChanged {
                        HStack(spacing: 4) {
                            Text(localValue).font(.caption2).foregroundStyle(Color(.systemGray)).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(Color(.systemGray2))
                            Text(scraped).font(.caption2).fontWeight(.medium).foregroundStyle(.green).lineLimit(1)
                        }
                    } else {
                        Text(scraped).font(.caption2).foregroundStyle(.primary).lineLimit(1)
                    }
                }
            }
            .tint(isChanged ? .green : Color(.systemGray))
        }
    }

    @ViewBuilder
    private func statusBadge(hasLocal: Bool, hasScraped: Bool, isChanged: Bool) -> some View {
        if isChanged {
            HStack(spacing: 3) {
                Image(systemName: hasLocal ? "checkmark" : "xmark")
                    .font(.caption2).foregroundStyle(Color(.systemGray))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8)).foregroundStyle(Color(.systemGray2))
                Image(systemName: "checkmark")
                    .font(.caption2).foregroundStyle(.green)
            }
        } else {
            Text(String(localized: "unchanged")).font(.caption2).foregroundStyle(Color(.systemGray2))
        }
    }

    private func hasAnyScrapeResult(_ p: ScrapePreview) -> Bool {
        p.scrapedTitle != nil || p.scrapedArtist != nil || p.scrapedAlbum != nil ||
        p.scrapedYear != nil || p.scrapedGenre != nil || p.hasCover || p.hasLyrics
    }

    private var hasAnySelectedChange: Bool {
        guard let p = previewResult else { return false }
        let titleChanged = p.scrapedTitle != nil && p.scrapedTitle != song.title
        let artistChanged = p.scrapedArtist != nil && p.scrapedArtist != song.artistName
        let albumChanged = p.scrapedAlbum != nil && p.scrapedAlbum != song.albumTitle
        let yearChanged = p.scrapedYear != nil && p.scrapedYear != song.year
        let genreChanged = p.scrapedGenre != nil && p.scrapedGenre != song.genre

        return (titleChanged && applyTitle) || (artistChanged && applyArtist) ||
               (albumChanged && applyAlbum) || (yearChanged && applyYear) ||
               (genreChanged && applyGenre) || (p.hasCover && applyCover) ||
               (p.hasLyrics && applyLyrics)
    }

    // MARK: - Manual Search

    private var manualSearchView: some View {
        List {
            if searchResults.isEmpty && !isSearching {
                ContentUnavailableView("no_results", systemImage: "magnifyingglass",
                    description: Text("no_scrape_results_desc"))
            } else {
                ForEach(searchResults) { item in
                    Button {
                        Task { await selectManualResult(item) }
                    } label: {
                        HStack(spacing: 10) {
                            // Cover art thumbnail
                            ScraperCoverThumbnail(
                                urlString: item.coverUrl,
                                externalId: item.externalId,
                                sourceConfig: item.sourceConfig
                            )

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
                                        Text(artist).font(.caption).foregroundStyle(Color(.systemGray))
                                    }
                                    if let album = item.album {
                                        Text("·").font(.caption).foregroundStyle(Color(.systemGray2))
                                        Text(album).font(.caption).foregroundStyle(Color(.systemGray2))
                                    }
                                }
                                .lineLimit(1)
                                Text(item.source).font(.caption2).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .searchable(text: $manualSearchQuery, prompt: Text("search_query"))
        .onSubmit(of: .search) {
            Task { await performManualSearch() }
        }
        .overlay {
            if isSearching {
                ProgressView("searching").padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("back_to_options") { mode = .options }
            }
        }
    }

    // MARK: - Logic

    private func autoScrape() async {
        isScraping = true
        errorMessage = nil

        do {
            let (updated, coverData, lyricsLines) = try await scraperService.scrapeSingle(song: song, in: library, dryRun: true)
            isScraping = false

            let lyricsCount = lyricsLines?.count ?? 0

            previewResult = ScrapePreview(
                updatedSong: updated, coverData: coverData, lyricsCount: lyricsCount,
                lyricsLines: lyricsLines,
                scrapedTitle: updated.title != song.title ? updated.title : updated.title,
                scrapedArtist: updated.artistName,
                scrapedAlbum: updated.albumTitle,
                scrapedYear: updated.year,
                scrapedGenre: updated.genre,
                hasCover: coverData != nil,
                hasLyrics: lyricsLines != nil && !lyricsLines!.isEmpty
            )

            // Default all toggles to on for changed fields, off for unchanged
            applyTitle = updated.title != song.title
            applyArtist = updated.artistName != song.artistName
            applyAlbum = updated.albumTitle != song.albumTitle
            applyYear = updated.year != song.year && updated.year != nil
            applyGenre = updated.genre != song.genre && updated.genre != nil
            applyCover = true
            applyLyrics = true

            previewSource = .options
            mode = .preview
        } catch {
            isScraping = false
            errorMessage = error.localizedDescription
        }
    }

    private func manualSearch() async {
        manualSearchQuery = ScraperManager.searchTitle(song.title, artist: song.artistName)
        if let artist = song.artistName,
           !artist.isEmpty,
           ScraperManager.shouldAppendArtist(to: manualSearchQuery, artist: artist) {
            manualSearchQuery += " \(artist)"
        }
        mode = .manual
        await performManualSearch()
    }

    private func performManualSearch() async {
        isSearching = true
        searchResults = []
        errorMessage = nil
        var aggregatedResults: [SearchResultItem] = []

        let settings = ScraperSettings.load()
        plog("🔍 Manual search query='\(manualSearchQuery)' enabled sources: \(settings.enabledSources.map { $0.type.rawValue })")

        for config in settings.enabledSources {
            guard canUseSourceInManualSearch(config) else { continue }
            do {
                let scraper = MusicScraperFactory.create(for: config)
                let result = try await scraper.search(
                    query: manualSearchQuery, artist: nil, album: nil, limit: 30
                )
                for item in result.items {
                    plog("🔍 Search result: \(config.type.rawValue) '\(item.title)' coverUrl=\(item.coverUrl ?? "nil")")
                    aggregatedResults.append(SearchResultItem(
                        id: "\(config.type.rawValue)_\(item.externalId)",
                        title: item.title,
                        artist: item.artist,
                        album: item.album,
                        durationMs: item.durationMs,
                        coverUrl: item.coverUrl,
                        externalId: item.externalId,
                        sourceConfig: config
                    ))
                }
            } catch {
                plog("⚠️ Search failed for \(config.type.rawValue): \(ConfigurableScraper.describeNetworkError(error))")
            }
        }

        // Sort by duration match
        if song.duration.sanitizedDuration > 0 {
            let targetMs = Int((song.duration.sanitizedDuration * 1000).rounded(.down))
            aggregatedResults.sort { a, b in
                let diffA = abs((a.durationMs ?? 0) - targetMs)
                let diffB = abs((b.durationMs ?? 0) - targetMs)
                return diffA < diffB
            }
        }

        searchResults = aggregatedResults
        isSearching = false
        mode = .manual
    }

    private func selectManualResult(_ item: SearchResultItem) async {
        isScraping = true

        do {
            let scraper = MusicScraperFactory.create(for: item.sourceConfig)
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
                    lyricsFileName: song.lyricsFileName,
                    revision: song.revision
                )
            }

            // Download cover art if available (keep in memory, don't store to disk yet)
            var hasCover = false
            var coverData: Data?
            // Prefer search result's coverUrl if detail doesn't have one
            let coverUrl = detail?.coverUrl ?? item.coverUrl
            if let coverUrl,
               let data = try? await ConfigurableScraper.downloadResource(
                from: coverUrl,
                sourceConfig: item.sourceConfig,
                timeout: 10
               ) {
                coverData = data
                hasCover = true
            }

            // Download lyrics if available (keep in memory, don't store to disk yet)
            var hasLyrics = false
            var lyricsCount = 0
            var lyricsLines: [LyricLine]?
            if let lyricsResult = try? await scraper.getLyrics(externalId: item.externalId),
               lyricsResult.hasLyrics,
               let lrc = lyricsResult.lrcContent, !lrc.isEmpty {
                let parsed = LyricsParser.parse(lrc)
                if !parsed.isEmpty {
                    lyricsLines = parsed
                    hasLyrics = true
                    lyricsCount = parsed.count
                }
            }

            isScraping = false

            previewResult = ScrapePreview(
                updatedSong: updated, coverData: coverData, lyricsCount: lyricsCount,
                lyricsLines: lyricsLines,
                scrapedTitle: updated.title,
                scrapedArtist: updated.artistName,
                scrapedAlbum: updated.albumTitle,
                scrapedYear: updated.year,
                scrapedGenre: updated.genre,
                hasCover: hasCover,
                hasLyrics: hasLyrics
            )
            applyTitle = updated.title != song.title
            applyArtist = updated.artistName != song.artistName
            applyAlbum = updated.albumTitle != song.albumTitle
            applyYear = updated.year != song.year && updated.year != nil
            applyGenre = updated.genre != song.genre && updated.genre != nil
            applyCover = hasCover
            applyLyrics = hasLyrics
            previewSource = .manual
            mode = .preview
        } catch {
            isScraping = false
            errorMessage = error.localizedDescription
        }
    }

    private func applySelectedChanges() {
        guard let preview = previewResult else { return }
        let u = preview.updatedSong

        let titleChanged = preview.scrapedTitle != nil && preview.scrapedTitle != song.title
        let artistChanged = preview.scrapedArtist != nil && preview.scrapedArtist != song.artistName
        let albumChanged = preview.scrapedAlbum != nil && preview.scrapedAlbum != song.albumTitle
        let yearChanged = preview.scrapedYear != nil && preview.scrapedYear != song.year
        let genreChanged = preview.scrapedGenre != nil && preview.scrapedGenre != song.genre

        // Store cover and lyrics to disk NOW (only on apply, not during preview)
        var coverFileName = song.coverArtFileName
        var lyricsFileName = song.lyricsFileName

        if preview.hasCover && applyCover, let data = preview.coverData {
            Task {
                if let name = await MetadataAssetStore.shared.storeCover(data, for: song.id) {
                    coverFileName = name
                }
            }
            // Synchronous fallback: generate expected filename
            coverFileName = MetadataAssetStore.shared.expectedCoverFileName(for: song.id)
            // Store synchronously for immediate availability
            MetadataAssetStore.shared.storeCoverSync(data, for: song.id)
            // Invalidate memory cache so UI picks up the new cover
            CachedArtworkView.invalidateCache(for: coverFileName!)
        }

        if preview.hasLyrics && applyLyrics, let lines = preview.lyricsLines {
            MetadataAssetStore.shared.storeLyricsSync(lines, for: song.id)
            lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
        }

        // Build final song with only selected changes applied
        let final = Song(
            id: song.id,
            title: (titleChanged && applyTitle) ? u.title : song.title,
            albumID: song.albumID, artistID: song.artistID,
            albumTitle: (albumChanged && applyAlbum) ? u.albumTitle : song.albumTitle,
            artistName: (artistChanged && applyArtist) ? u.artistName : song.artistName,
            trackNumber: u.trackNumber ?? song.trackNumber,
            discNumber: u.discNumber ?? song.discNumber,
            duration: u.duration > 0 ? u.duration : song.duration,
            fileFormat: song.fileFormat,
            filePath: song.filePath, sourceID: song.sourceID,
            fileSize: song.fileSize,
            bitRate: u.bitRate ?? song.bitRate,
            sampleRate: u.sampleRate ?? song.sampleRate,
            bitDepth: u.bitDepth ?? song.bitDepth,
            genre: (genreChanged && applyGenre) ? u.genre : song.genre,
            year: (yearChanged && applyYear) ? u.year : song.year,
            dateAdded: song.dateAdded,
            coverArtFileName: coverFileName,
            lyricsFileName: lyricsFileName,
            revision: song.revision
        )

        library.replaceSong(final)

        // Write sidecar files (cover.jpg, .lrc) back to NAS source
        let coverDataToWrite = (preview.hasCover && applyCover) ? preview.coverData : nil
        let lyricsToWrite = (preview.hasLyrics && applyLyrics) ? preview.lyricsLines : nil
        if coverDataToWrite != nil || lyricsToWrite != nil {
            let songForWrite = final
            let songID = final.id
            let sm = sourceManager
            let lib = library
            Task { @MainActor in
                do {
                    plog("📝 Sidecar: writing back to source for '\(songForWrite.title)'")
                    let connector = try await sm.auxiliaryConnector(for: songForWrite)
                    let writeResult = await SidecarWriteService.shared.writeSidecars(
                        for: songForWrite, using: connector,
                        coverData: coverDataToWrite, lyricsLines: lyricsToWrite
                    )
                    plog("📝 Sidecar: result cover=\(writeResult.coverWritten) lyrics=\(writeResult.lyricsWritten)")

                    let songDir = (songForWrite.filePath as NSString).deletingLastPathComponent
                    let baseNameNoExt = ((songForWrite.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                    var refSong = songForWrite
                    var needsUpdate = false

                    if writeResult.coverWritten {
                        let coverPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt)-cover.jpg")
                        refSong.coverArtFileName = coverPath
                        await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
                        needsUpdate = true
                    }
                    if writeResult.lyricsWritten {
                        let lrcPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt).lrc")
                        refSong.lyricsFileName = lrcPath
                        needsUpdate = true
                    }
                    if needsUpdate {
                        lib.replaceSong(refSong)
                    }
                    if !writeResult.errors.isEmpty {
                        plog("⚠️ Sidecar write errors: \(writeResult.errors)")
                    }
                } catch {
                    plog("⚠️ Sidecar write failed for '\(songForWrite.title)': \(error.localizedDescription)")
                }
            }
        }

        onComplete?(final)
        dismiss()
    }

    // MARK: - Helpers

    private func formatDuration(_ t: TimeInterval) -> String {
        t.formattedDuration
    }

    private func canUseSourceInManualSearch(_ sourceConfig: ScraperSourceConfig) -> Bool {
        switch sourceConfig.type {
        case .custom(let configID):
            guard let config = ScraperConfigStore.shared.config(for: configID) else {
                plog("⚠️ Manual search skipping \(sourceConfig.type.rawValue): config '\(configID)' not found")
                return false
            }
            let canSearch = config.search != nil
            if !canSearch {
                plog("⚠️ Manual search skipping \(sourceConfig.type.rawValue): search endpoint missing")
            }
            return canSearch
        default:
            return sourceConfig.type.supportsMetadata
        }
    }
}

// MARK: - Scraper Cover Thumbnail

/// Loads cover thumbnails through the same config-aware request path as manual scraping.
private struct ScraperCoverThumbnail: View {
    let urlString: String?
    let externalId: String
    let sourceConfig: ScraperSourceConfig

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "music.note").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(sourceConfig.id)|\(urlString ?? "")") {
            image = nil
            let resolvedURL = await resolveThumbnailURL()
            guard let resolvedURL, !resolvedURL.isEmpty else { return }

            if let data = try? await ConfigurableScraper.downloadResource(
                from: resolvedURL,
                sourceConfig: sourceConfig,
                timeout: 10
            ),
               let loaded = UIImage(data: data) {
                image = loaded
            }
        }
    }

    private func resolveThumbnailURL() async -> String? {
        if let urlString, !urlString.isEmpty {
            return urlString
        }

        let scraper = MusicScraperFactory.create(for: sourceConfig)
        if let cover = try? await scraper.getCoverArt(externalId: externalId).first {
            let fallbackURL = cover.thumbnailUrl ?? cover.coverUrl
            plog("🖼️ Thumbnail fallback via getCoverArt for \(sourceConfig.type.rawValue): \(fallbackURL)")
            return fallbackURL
        }

        if let detail = try? await scraper.getDetail(externalId: externalId),
           let fallbackURL = detail.coverUrl {
            plog("🖼️ Thumbnail fallback via getDetail for \(sourceConfig.type.rawValue): \(fallbackURL)")
            return fallbackURL
        }

        return nil
    }
}
