#if os(tvOS)
import PrimuseKit
import SwiftUI
import UIKit

/// 「匹配信息」要打开的歌,给 `fullScreenCover(item:)` 用。
struct TVSongMatchTarget: Identifiable, Hashable {
    let id: String
}

// MARK: - 单曲匹配

/// Apple TV 的「匹配信息」:用遥控器键盘改搜索词,在启用的刮削源里搜候选,选一条看
/// 预览,勾选标签 / 封面 / 歌词后应用。候选排序与详情合并和 iPhone 刮削页同一套规则;
/// 结果只写这台 Apple TV,不写回音乐源。
struct TVSongMatchView: View {
    let songID: String

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum SearchState: Equatable {
        case idle
        case searching
        case finished
        /// 一个能按关键词搜的刮削源都没启用。
        case noSource
    }

    private enum Field: Hashable { case query }

    @State private var query = ""
    @State private var candidates: [TVScrapeCandidate] = []
    @State private var searchState: SearchState = .idle
    @State private var searchTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var loadingCandidateID: String?
    @State private var preview: TVScrapePreview?
    @State private var previewImage: UIImage?
    @State private var applyTags = false
    @State private var applyCover = false
    @State private var applyLyrics = false
    @State private var isApplying = false
    @State private var notice: String?
    @State private var didStart = false
    @State private var debugOpensFirstCandidate = false
    @State private var debugAppliesPreview = false
    @FocusState private var focusedField: Field?

    private var song: Song? { store.library.song(id: songID) }

    var body: some View {
        let colors = store.nowPlayingPresentationColors
        ZStack {
            TVAmbientBackdrop(tint: colors.primary, tint2: colors.secondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            card
                .padding(.horizontal, 90)
                .padding(.vertical, 50)
        }
        .onAppear(perform: start)
        .onExitCommand(perform: handleExit)
        .onDisappear {
            searchTask?.cancel()
            previewTask?.cancel()
        }
        .accessibilityIdentifier("tv.scrape.match")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(TVColor.divider)
                .frame(height: 1)
                .padding(.top, 24).padding(.bottom, 26)

            Group {
                if let preview {
                    previewContent(preview)
                } else {
                    searchContent
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .padding(.horizontal, 60).padding(.vertical, 46)
        .frame(maxWidth: 1320, maxHeight: .infinity, alignment: .topLeading)
        .tvPanel(radius: 26)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "tv_scrape_match_title"))
                    .tvFont(.pageTitle)
                    .foregroundStyle(TVColor.text)
                Text(verbatim: songLine)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            TVPillButton(title: String(localized: "cancel"), systemImage: "xmark") { dismiss() }
        }
        .focusSection()
    }

    private var songLine: String {
        guard let song else { return "" }
        return [song.title, song.artistName, song.albumTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: notice == nil ? "appletv" : "exclamationmark.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(notice == nil ? TVColor.textFaint : TVColor.warn)
            Text(notice ?? String(localized: "tv_scrape_local_only_note"))
                .tvFont(.caption)
                .foregroundStyle(notice == nil ? TVColor.textFaint : TVColor.warn)
                .lineLimit(2)
        }
        .padding(.top, 20)
    }

    // MARK: 搜索

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(String(localized: "search_query"), icon: "magnifyingglass", active: focusedField == .query)
            HStack(spacing: 18) {
                TVTextFieldBox {
                    TextField("", text: $query)
                        .focused($focusedField, equals: .query)
                        .submitLabel(.search)
                        .onSubmit(search)
                        .accessibilityLabel(Text(String(localized: "search_query")))
                }
                TVPillButton(
                    title: String(localized: "search_title"),
                    systemImage: "magnifyingglass",
                    style: .solid,
                    action: search
                )
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .focusSection()

            searchResults
                .padding(.top, 22)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch searchState {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 16) {
                ProgressView()
                Text(String(localized: "scrape_candidates_searching"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
            }
            .padding(.top, 10)
        case .noSource:
            statusLine(
                String(localized: "scraper_no_source_message"),
                icon: "exclamationmark.triangle",
                tint: TVColor.warn
            )
        case .finished where candidates.isEmpty:
            statusLine(
                String(localized: "scrape_candidates_empty") + " · " + String(localized: "no_scrape_results_desc"),
                icon: "magnifyingglass"
            )
        case .finished:
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }
            .focusSection()
        }
    }

    private func candidateRow(_ candidate: TVScrapeCandidate) -> some View {
        let isLoading = loadingCandidateID == candidate.id
        let detail = detailText(for: candidate)
        return TVFocusButton(radius: 16, scale: 1.01, lift: 0, action: { select(candidate) }) { focused in
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: candidate.item.title)
                        .tvFont(.rowTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(1)
                    Text(verbatim: detail.isEmpty ? " " : detail)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                ProgressView()
                    .opacity(isLoading ? 1 : 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(verbatim: candidate.confidence.formatted(.percent.precision(.fractionLength(0))))
                        .tvFont(.caption, weight: .semibold)
                        .foregroundStyle(confidenceTint(candidate.confidence))
                    Text(verbatim: candidate.sourceName)
                        .tvFont(.meta)
                        .foregroundStyle(focused ? TVColor.text : TVColor.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(Text(verbatim: candidate.item.title))
        .accessibilityValue(Text(verbatim: detail))
    }

    private func detailText(for candidate: TVScrapeCandidate) -> String {
        var parts: [String] = []
        if let artist = candidate.item.artist, !artist.isEmpty { parts.append(artist) }
        if let album = candidate.item.album, !album.isEmpty { parts.append(album) }
        if let year = candidate.item.year, year > 0 { parts.append(String(year)) }
        if let ms = candidate.item.durationMs, ms > 0 { parts.append(TVFmt.time(Double(ms) / 1000)) }
        return parts.joined(separator: " · ")
    }

    private func confidenceTint(_ confidence: Double) -> Color {
        if confidence >= 0.8 { return TVColor.ok }
        if confidence >= 0.5 { return TVColor.text }
        return TVColor.textFaint
    }

    // MARK: 预览

    private func previewContent(_ preview: TVScrapePreview) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 44) {
                coverView
                VStack(alignment: .leading, spacing: 14) {
                    comparisonRow(String(localized: "title_label"),
                                  preview.original.title, preview.proposed.title)
                    comparisonRow(String(localized: "artist_label"),
                                  preview.original.artist, preview.proposed.artist)
                    comparisonRow(String(localized: "album_label"),
                                  preview.original.albumTitle, preview.proposed.albumTitle)
                    comparisonRow(String(localized: "year_label"),
                                  preview.original.year.map { String($0) }, preview.proposed.year.map { String($0) })
                    comparisonRow(String(localized: "genre_label"),
                                  preview.original.genre, preview.proposed.genre)
                    comparisonRow(String(localized: "track_label"),
                                  preview.original.trackNumber.map { String($0) },
                                  preview.proposed.trackNumber.map { String($0) })
                    lyricsSummary(preview.lyrics)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 18) {
                optionToggle("tag", String(localized: "tv_scrape_apply_tags"),
                             isOn: $applyTags, isAvailable: preview.tagsChanged)
                optionToggle("photo", String(localized: "cover"),
                             isOn: $applyCover, isAvailable: preview.coverData != nil)
                optionToggle("text.quote", String(localized: "lyrics_word"),
                             isOn: $applyLyrics, isAvailable: preview.lyrics?.isEmpty == false)
            }
            .focusSection()

            HStack(spacing: 18) {
                TVPillButton(
                    title: String(localized: "apply_changes"),
                    systemImage: "checkmark",
                    style: .solid,
                    action: apply
                )
                .disabled(isApplying || !(applyTags || applyCover || applyLyrics))
                TVPillButton(
                    title: String(localized: "back_to_results"),
                    systemImage: "chevron.left",
                    action: backToResults
                )
            }
            .focusSection()
        }
    }

    private var coverView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(TVColor.surface)
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 52, weight: .regular))
                        .foregroundStyle(TVColor.textGhost)
                    Text(String(localized: "tv_scrape_no_cover"))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                }
            }
        }
        .frame(width: 320, height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    private func comparisonRow(_ label: String, _ current: String?, _ proposed: String?) -> some View {
        let currentText = displayValue(current)
        let proposedText = displayValue(proposed)
        let changed = currentText != proposedText
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label)
                .tvFont(.caption)
                .foregroundStyle(TVColor.textFaint)
                .frame(width: 150, alignment: .leading)
            Text(verbatim: currentText)
                .tvFont(.body)
                .foregroundStyle(changed ? TVColor.textMuted : TVColor.text)
                .lineLimit(1)
            if changed {
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TVColor.textFaint)
                Text(verbatim: proposedText)
                    .tvFont(.body, weight: .semibold)
                    .foregroundStyle(TVColor.brand)
                    .lineLimit(1)
            }
        }
    }

    private func lyricsSummary(_ lyrics: [LyricLine]?) -> some View {
        let text: String
        if let lyrics, !lyrics.isEmpty {
            let lines = String(format: String(localized: "tv_scrape_lyrics_lines_format"), lyrics.count)
            text = lyrics.contains(where: \.isWordLevel)
                ? lines + String(localized: "scrape_word_level_suffix")
                : lines
        } else {
            text = String(localized: "tv_scrape_no_lyrics")
        }
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(String(localized: "lyrics_word"))
                .tvFont(.caption)
                .foregroundStyle(TVColor.textFaint)
                .frame(width: 150, alignment: .leading)
            Text(verbatim: text)
                .tvFont(.body)
                .foregroundStyle(lyrics?.isEmpty == false ? TVColor.text : TVColor.textMuted)
        }
    }

    private func optionToggle(
        _ icon: String,
        _ title: String,
        isOn: Binding<Bool>,
        isAvailable: Bool
    ) -> some View {
        TVSwitchRow(icon: icon, title: title, isOn: isOn, maxWidth: 380)
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0.45)
    }

    private func displayValue(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(localized: "scrape_value_empty") : trimmed
    }

    // MARK: 动作

    private func start() {
        guard !didStart, let song else { return }
        didStart = true
        query = TVMetadataScrapeService.suggestedQuery(title: song.title, artist: song.artistName)
        #if DEBUG
        // 截图 / 取证:演示曲库在线搜不到东西,可以换一个搜索词;要看预览页再让它自动选第一条。
        let environment = ProcessInfo.processInfo.environment
        if let debugQuery = environment["TV_SCRAPE_DEBUG_QUERY"], !debugQuery.isEmpty {
            query = debugQuery
        }
        debugOpensFirstCandidate = environment["TV_SCRAPE_DEBUG_PREVIEW"] == "1"
            || environment["TV_SCRAPE_DEBUG_PREVIEW"] == "apply"
        debugAppliesPreview = environment["TV_SCRAPE_DEBUG_PREVIEW"] == "apply"
        #endif
        focusedField = .query
        search()
    }

    private func search() {
        guard let song else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        previewTask?.cancel()
        loadingCandidateID = nil
        notice = nil
        searchState = .searching
        let scraper = store.metadataScraper
        searchTask = Task { @MainActor in
            let outcome = await scraper.searchCandidates(for: song, query: text)
            guard !Task.isCancelled else { return }
            candidates = outcome.candidates
            searchState = outcome.searchedSourceCount == 0 ? .noSource : .finished
            if debugOpensFirstCandidate, let first = candidates.first {
                debugOpensFirstCandidate = false
                select(first)
            }
        }
    }

    private func select(_ candidate: TVScrapeCandidate) {
        guard loadingCandidateID == nil, let song else { return }
        loadingCandidateID = candidate.id
        notice = nil
        let scraper = store.metadataScraper
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do {
                let result = try await scraper.preview(candidate, for: song)
                guard !Task.isCancelled else { return }
                loadingCandidateID = nil
                // 下载回来的不是能显示的图片(错误页、残缺文件)就当没有封面,也不能应用。
                let image = result.coverData.flatMap(UIImage.init(data:))
                previewImage = image
                applyTags = result.tagsChanged
                applyCover = image != nil
                applyLyrics = result.lyrics?.isEmpty == false
                preview = image == nil ? result.droppingCover() : result
                if debugAppliesPreview {
                    debugAppliesPreview = false
                    apply()
                }
            } catch {
                guard !Task.isCancelled else { return }
                loadingCandidateID = nil
                notice = String(localized: "scrape_song_failed")
            }
        }
    }

    private func apply() {
        guard let preview, !isApplying else { return }
        isApplying = true
        notice = nil
        let scraper = store.metadataScraper
        let (tags, cover, lyrics) = (applyTags, applyCover, applyLyrics)
        Task { @MainActor in
            let changed = await scraper.apply(preview, tags: tags, cover: cover, lyrics: lyrics)
            isApplying = false
            if changed {
                dismiss()
            } else {
                notice = String(localized: "scrape_no_changes")
            }
        }
    }

    private func backToResults() {
        preview = nil
        previewImage = nil
        notice = nil
    }

    private func handleExit() {
        if preview != nil {
            backToResults()
        } else {
            dismiss()
        }
    }

    private func fieldLabel(_ title: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                .foregroundStyle(active ? TVColor.brand : TVColor.textFaint)
                .frame(width: 26)
            Text(title)
                .tvFont(.caption)
                .foregroundStyle(active ? TVColor.text : TVColor.textFaint)
        }
        .padding(.bottom, 10)
    }

    private func statusLine(_ text: String, icon: String, tint: Color = TVColor.textMuted) -> some View {
        Label(text, systemImage: icon)
            .tvFont(.caption)
            .foregroundStyle(tint)
            .padding(.top, 10)
    }
}

// MARK: - 整张专辑补全

/// 为一张专辑补全缺失的标签、封面和歌词的面板。专辑详情页这样打开:
///
///     .fullScreenCover(isPresented: $showsAlbumScrape) {
///         TVAlbumScrapeView(albumID: album.id).environment(store)
///     }
///
/// 规则跟着刮削设置走:「只补全缺失字段」开着时只填空着的,关着时用可信的在线结果覆盖。
/// 改了专辑名的话这张专辑可能换一个 id,关掉面板后详情页按需要重新取专辑。
struct TVAlbumScrapeView: View {
    let albumID: String

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case idle
        case running(TVAlbumScrapeProgress?)
        case finished(TVAlbumScrapeResult)
    }

    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?
    @State private var albumTitle = ""
    @State private var albumArtist = ""
    @State private var trackCount = 0
    @State private var didLoad = false

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            card
                .padding(.horizontal, 90)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear(perform: load)
        .onExitCommand(perform: close)
        .onDisappear {
            task?.cancel()
            task = nil
        }
        .accessibilityIdentifier("tv.scrape.album")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "tv_scrape_album_title"))
                    .tvFont(.pageTitle)
                    .foregroundStyle(TVColor.text)
                Text(verbatim: [albumTitle, albumArtist].filter { !$0.isEmpty }.joined(separator: " · "))
                    .tvFont(.cardTitle)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
            }
            Text(bodyText)
                .tvFont(.body)
                .foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            status

            buttons
                .focusSection()

            Label(String(localized: "tv_scrape_local_only_note"), systemImage: "appletv")
                .tvFont(.caption)
                .foregroundStyle(TVColor.textFaint)
        }
        .padding(.horizontal, 60).padding(.vertical, 46)
        .frame(maxWidth: 1100, alignment: .leading)
        .tvPanel(radius: 26)
    }

    private var bodyText: String {
        let format = store.scraperSettings.onlyFillMissingFields
            ? String(localized: "tv_scrape_album_body_fill_format")
            : String(localized: "tv_scrape_album_body_overwrite_format")
        return String(format: format, trackCount)
    }

    private var hasEnabledSource: Bool {
        !store.scraperSettings.enabledSources.isEmpty
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            if !hasEnabledSource {
                Label(String(localized: "scraper_no_source_message"), systemImage: "exclamationmark.triangle")
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.warn)
            }
        case .running(let progress):
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(
                    value: Double(max((progress?.index ?? 1) - 1, 0)),
                    total: Double(max(progress?.total ?? trackCount, 1))
                )
                Text(verbatim: progress.map {
                    String(
                        format: String(localized: "tv_scrape_album_progress_format"),
                        $0.index, $0.total, $0.songTitle
                    )
                } ?? " ")
                .tvFont(.caption)
                .foregroundStyle(TVColor.textMuted)
                .lineLimit(1)
            }
        case .finished(let result):
            Label(resultText(result), systemImage: result.noEnabledSource
                ? "exclamationmark.triangle" : "checkmark.circle")
                .tvFont(.body)
                .foregroundStyle(result.noEnabledSource ? TVColor.warn : TVColor.text)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 18) {
            switch phase {
            case .idle:
                TVPillButton(
                    title: String(localized: "tv_scrape_album_start"),
                    systemImage: "wand.and.stars",
                    style: .solid,
                    action: start
                )
                .disabled(trackCount == 0 || !hasEnabledSource)
                TVPillButton(title: String(localized: "cancel"), systemImage: "xmark", action: close)
            case .running:
                TVPillButton(title: String(localized: "tv_scrape_album_stop"), systemImage: "stop.circle", action: stop)
            case .finished:
                TVPillButton(title: String(localized: "done"), systemImage: "checkmark", style: .solid, action: close)
            }
        }
    }

    private func resultText(_ result: TVAlbumScrapeResult) -> String {
        if result.noEnabledSource { return String(localized: "scraper_no_source_message") }
        let counts = String(
            format: String(localized: "tv_scrape_album_result_format"),
            result.updated,
            result.unchanged
        )
        return result.cancelled ? counts + " · " + String(localized: "tv_scrape_album_stopped") : counts
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let songs = store.library.songs(forAlbum: albumID)
        trackCount = songs.count
        if let album = store.album(albumID) {
            albumTitle = album.title
            albumArtist = album.artist
        } else {
            albumTitle = songs.first?.albumTitle ?? ""
            albumArtist = songs.first?.albumArtistName ?? songs.first?.artistName ?? ""
        }
    }

    private func start() {
        guard task == nil else { return }
        phase = .running(nil)
        let scraper = store.metadataScraper
        let albumID = albumID
        task = Task { @MainActor in
            let result = await scraper.scrapeMissingMetadata(albumID: albumID) { progress in
                if case .running = phase { phase = .running(progress) }
            }
            task = nil
            phase = .finished(result)
        }
    }

    private func stop() {
        task?.cancel()
    }

    private func close() {
        task?.cancel()
        task = nil
        dismiss()
    }
}
#endif
